# Memory

Status: implementation plan, not an architectural contract. It records what was
measured, what the harness keeps resident, and the order in which that should
change. Delete a step as it lands; keep the measurements current, because they
are what the plan exists to justify.

The harness asked for this because a run's RSS climbed steadily while its
conversation stayed small. The growth is real, it is not the model context, and
by the end of this document's first round of work it was still there.

## What was measured

Method, and what not to trust:

- A scripted mock provider (`/tmp` only, never in the repository) drives turns
  through the TUI in `tmux` and records `/proc/PID/status` while they run. The
  same script writes one row per encoding event (`provider.encoded`, with
  `body_bytes`) into the run log, so RSS can be compared with the bytes the
  session actually built.
- Do not run these measurements with a `malloc` interposer or a tracking
  allocator loaded. Both hold their own tables and their own backtraces, and on
  a fast workload that growth dwarfs the harness's. An early round of numbers in
  this document was wrong for exactly that reason: RSS "growing 7 MiB per turn"
  was the tracker's tables becoming resident.
- `malloc_trim(0)` called from a preloaded timer is the way to tell a heap the
  allocator is holding from memory that is still live. It recovers part of the
  growth, never all of it.

| Fact | Value |
| --- | --- |
| Fresh TUI, real configuration, before this round | `VmRSS` 21.2 MiB |
| Fresh TUI, real configuration, after step 1 and step 2 | `VmRSS` 15.2 MiB |
| Peak RSS at startup (`VmHWM`) | about 105 to 113 MiB |
| `layout.storage_size(CONVERSATION_CAPACITIES)` before step 1 | 16.10 MiB |
| The same after step 1 | 0.55 MiB |
| A live hour-and-a-half session | `VmRSS` 23 MiB to 279 MiB |
| Request bodies that session had encoded (287 of them) | 260.2 MiB total |
| Scripted repro, 16 turns of a 200 KiB answer each | `VmRSS` 18 MiB to 54 MiB |
| The same workload with the encode buffer reused (step 3) | 18 MiB to 49 MiB |
| The same workload with `malloc_trim` running every 2 s | 18 MiB to 37 MiB |
| Scripted repro, 12 turns with a 100-byte answer each | 18 MiB, flat |

The startup peak is the models.dev document: 4.9 MiB of JSON parsed into a tree
several times that size inside a `virtual.Arena` that is unmapped when
extraction ends. It is a spike, not a leak, and it is already handled.

## What grows

The short answer: RSS tracks the bytes the session has *processed*, not the
bytes it is holding. A session that has sent 260 MiB of request bodies sits near
279 MiB of RSS, and one that sent 26.5 MiB of them sits near 54 MiB. Idle RSS is
flat; a session that only renders, however often, does not grow; threads do not
accumulate. Growth needs turns, and it scales with the size of the text in them.

Where those bytes go, from a run with one 200 KiB answer per turn and an
instrumented event log:

| Between | `VmRSS` gained |
| --- | --- |
| `request.prepared` and `request.recorded` | 196 KiB |
| `request.recorded` and `attempt.finished` | 720 to 1316 KiB |
| `attempt.finished` and `request.finished` | 744 to 868 KiB |
| `tool.call_received` and the next `request.prepared` | 388 to 1468 KiB |

Each increment is a small multiple of the message text that phase handles, and
they sum to about ten copies of it per turn. `VmRSS` minus the live `malloc`
bytes is most of that total, and a trim returns only part of it: the rest is
freed memory the allocator cannot hand back because it sits under live
allocations in a heap it will not unmap.

1. **Per-turn copies of the same text.** The prepared request, the encoded body,
   the store's payload JSON, the response accumulator, and the transcript entry
   each build their own buffer for the same message, then free it. Step 3
   removed two of those per request. The rest are still there.
2. **The layout budget.** Was `layout.storage_size(CONVERSATION_CAPACITIES)`,
   one block of 16.10 MiB, held for the process lifetime. Landed as step 1.
3. **The resident transcript.** `Snapshot.entries` was append-only. Landed as
   step 2.
4. **Worker-thread scratch.** A thread created without `init_context` gets the
   default context, so its `context.allocator` is the process heap allocator
   (`base/runtime/heap_allocator_unix.odin`, which is libc `malloc`). Requests
   and tool calls each run on their own thread, and their large transients land
   there. This is why an explicit-allocator reading of the code cannot see them.

## What the language already provides

The plan is built from facilities that exist today, so no new mechanism is
introduced:

- `layout.reserve` is the documented recovery from exhaustion.
  `layout/context_test.odin` asserts it: a frame reports
  `Frame_Error.Capacity_Exhausted`, `layout.diagnostics` names the exhausted
  pool, and `reserve` raises it. `reserve` only grows, is transactional, and
  leaves the context usable when it fails. Only a context created by
  `layout.init` can grow, because it owns its storage.
- `core:mem/virtual.Arena` is the phase-scratch allocator. `arena_destroy`
  unmaps, so a phase's pages actually return to the OS. The repo already uses it
  this way in `agent/models_dev_parse.odin` and `agent/discovery.odin`.
- `context.allocator` is the documented way to give a thread its allocator.
  Every worker in the repo already assigns `context.logger` at its entry for the
  same reason.
- `mem.Tracking_Allocator` is the standard leak and retention check for tests.

## Steps

### 1. Raise the layout budget on demand

Landed. `tui.odin` starts from a capacity set sized to the viewport, creates the
context with `layout.init` so it owns its storage, and on `Capacity_Exhausted`
reads the pool from `layout.diagnostics`, doubles it with `layout.reserve`, and
solves again, bounded to a few attempts. `Frame_Storage` records the current
capacities. The `layout_storage` field and its `delete` are gone.

Effect on a fresh launch: budget 16.10 MiB to 0.55 MiB, `VmRSS` 17.3 to
14.2 MiB, reserved address space down 26 MiB. The RSS saving is smaller than the
budget saving because untouched pages of the old allocation were never resident.

### 2. Bound the resident transcript

Landed. `Snapshot.entries` holds a byte budget (`TRANSCRIPT_MAX_BYTES`), and the
oldest entries are dropped with a notice once it is reached. An entry is charged
its slot cost plus the capacity of its text, so short lines are bounded by the
same budget. `Entry` carries an id that the renderer tags each tool box with, so
a mouse report still names the entry it hit after older entries are gone.

Deliberately not done: a limit on the number of entries. The budget bounds the
bytes, which is the quantity that matters, and an entry count would be a second
limit saying nothing new.

### 3. Reuse the request body buffer

Landed. `Provider_Encode_Cache` holds the body buffer and every request encoded
through it is written into that buffer instead of into a fresh builder that was
then cloned for the caller. `Provider_Encoded_Request.Body_Borrowed` says which
bodies a caller owns and which it must leave alone.

Effect on the repro: 54 MiB to 49 MiB. Less than expected, and the measurement
is why: the body was only two of about ten copies of a message per turn.

This replaced the earlier plan of bounding the encode cache. With the buffer
reused, the cache costs one request's bytes rather than one per turn, and the
size hint that only existed to make a fresh allocation affordable on the first
try is gone with it.

### 4. Stop copying the same text per phase

Where: the prepared request (`agent/chat_request.odin`), the store's payload
JSON (`agent/session/*`), the response accumulator, and the transcript append
(`app_worker.odin`).

Why: this is the remaining per-turn growth, about eight copies of each message
per turn, each allocated fresh and freed. The allocator keeps the pages.

How: reuse one buffer per phase for the life of a session or a turn, as step 3
did for the encode body. The transcript append is the cheapest of these: the
entry's `[dynamic]u8` grows by doubling as deltas arrive, and a text that is
replaced rather than appended can be written once.

Verification: the scripted repro in this document's method section, before and
after, and the store's own `sum(length(payload_json))` as the denominator.

### 5. One arena per request chain

Where: `agent/chat_chain.odin` (`Chat_Request_Chain` and `chat_chain_release`),
the prepared request, and the worker that encodes it.

Why: this is the systematic version of step 4: one arena for the turn's scratch,
destroyed once, returns every page in one unmap instead of leaving the allocator
to decide. Step 3 removed the largest single allocation from it, so measure
after step 4 before taking this on.

How: give the chain a `virtual.Arena`, allocate turn scratch from
`virtual.arena_allocator`, and destroy it in `chat_chain_release` after the
worker is joined. The rule that keeps it safe: the arena may only back data
whose lifetime ends at that release. Published `Chat_Event`s stay on the session
allocator, because the owner reads them after the worker exits.

### 6. Name the allocator every worker uses

Where: the worker entry points that already assign `context.logger`:
`agent/chat_chain.odin`, `agent/chat_worker.odin`, `agent/tool_job.odin`,
`agent/compact.odin`, `app_worker.odin`, `app_catalog.odin`,
`app_watchdog.odin`, `acp_server.odin`.

Why: a thread created without `init_context` gets the default context, so its
`context.allocator` is the process default. Today that is the same libc `malloc`
the run already uses, so this saves nothing on its own. It makes ownership
explicit where the thread starts, makes every worker allocation visible to a
tracking allocator, and keeps the invariant true if the run allocator changes.

How: one assignment beside the existing logger assignment, using the owner's
allocator.

### 7. Later: page ACP replay

`acp_replay_session` loads the whole retained history through `history_load`. It
is temp-allocated and freed, so it is a spike rather than steady growth. Page it
by sequence order only if long-session replay becomes a problem.

## Non-goals

- No custom allocator layer, no global arena for everything, no reference
  counting, no pooling framework.
- `agent`'s explicit `allocator := context.allocator` parameters stay. They are
  already the right shape and this plan builds on them.
- The `DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE` define stays.
- No cap on how long a session runs or how much work it does. Growth comes from
  the sizes and lifetimes of the buffers, never from a limit on the session.

## Order and expected effect

1. Layout budget. Landed.
2. Transcript budget. Landed.
3. Encode body reuse. Landed.
4. Per-phase copies of message text. This is where the measured growth lives.
5. Chain arena, if 4 leaves a residual.
6. Worker allocators: makes what is left attributable.

Expected result once step 4 lands: a session's RSS tracks the largest message it
handles rather than the sum of every message it ever handled.

## Re-measuring

The probe lives in `/tmp`, not in the repository: a mock provider, a wrapper
that launches the built harness in `tmux`, and a sampling loop over
`/proc/PID/status`, `/proc/PID/smaps`, and the run log's `provider.encoded`
events. Three habits keep the result honest:

- Read `VmRSS`, `RssAnon`, and `VmHWM` from `/proc`, and compare the numbers
  against the sum of `body_bytes` in the run log. If they do not move together,
  the workload is not doing what the measurement assumes.
- Load no tracker unless the question is about live blocks. A tracker measures
  itself.
- Check the *controls*: a run with one tiny answer per turn, and a run that only
  redraws. Both must stay flat. If they do not, the measurement is picking up
  something other than the workload.

The repository keeps only the tests: the layout growth case from step 1, the
transcript bound from step 2, and the encode agreement cases in `ai` that hold
step 3 to identical bytes.
