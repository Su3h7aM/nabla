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
- `runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()` is the scope-scratch release for a
  procedure. It is `#force_inline`, marks the calling thread's default temp arena,
  and ends the mark at scope exit, so it releases exactly what that scope took from
  temp memory. It does nothing when the temp allocator is not the default one. Core
  uses it the same way, in 29 places (`json/marshal`, `json/unparse`, `image/png`,
  `log`, `path/slashpath`, `nbio`, `os/process`), and its `ignore` parameter is part
  of the idiom rather than an option: a scope that builds its result with the
  allocator it was handed has to pass
  `ignore = allocator == context.temp_allocator`, or it releases what the caller is
  keeping. A test that asked `xdg_directory` for its answer in temp memory failed on
  exactly that, and `acp_serve.odin` and `app_diagnostics.odin` ask the same way.
- `free_all(context.temp_allocator)` is the loop-scratch release, and the runtime
  documents it for that: the default temp allocator is "typically called with
  `free_all(context.temp_allocator)` once per frame-loop to prevent it from
  leaking". Every long-lived loop in this repo already does it: `run_worker` after
  each work item, plus `app_catalog`, `app_watchdog`, `acp_server`, `acp_serve`, and
  `tui.odin`. The agent's own worker threads run one operation and exit, so their
  arena dies with the thread and needs no reset. The per-phase guards below lower
  the peak inside a loop iteration; the loop reset is what bounds what is retained.
- `os.TEMP_ALLOCATOR_GUARD({allocator})` is the other scratch idiom and the more
  common one in core, 110 uses to 29. It hands the scope one of two thread-local
  arenas of its own, takes the caller's allocator as a collision so the two cannot
  be the same arena, and the scope passes that allocator explicitly to the calls
  that need scratch. It is the right tool when a scope must not touch the caller's
  arena at all. It is not used here because it means threading a scratch allocator
  through the record helpers, and `ignore` covers the case these procedures have.

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

### 4. Release the scratch a phase uses

Where: every procedure that allocates from `context.temp_allocator`.

The temp allocator is a per-thread arena that grows by adding a memory block
whenever the current one cannot serve a request. Nothing in `agent` released it,
so each phase of each turn left its block behind: 64 KiB to 512 KiB per turn, on
every turn, for the life of the session. Measured on the scripted repro, the
arena on the session thread went from 64 KiB to 5.57 MiB over ten turns.

How: `runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()` at the top of the scope that
chose temp memory. It is the runtime's own mechanism, documented on the
allocator: the temp allocator "is typically called with `free_all` once per
frame-loop to prevent it from leaking". The guard releases what the scope
allocated and leaves the arena reusing one block. A standalone check confirms
the difference: guarded calls return the same address and the block never
advances, unguarded ones advance it by the request size every call.

Landed: `insert_entry` and `entry_append` (`agent/session/history.odin`) and
`context_load` (`agent/session/context.odin`), the two per-entry writes and the
per-request read: 5.57 MiB to 0.85 MiB on the same ten turns. Then the phases a
turn writes with: `chat_record_attempt` (`agent/chat_chain.odin`),
`chat_finish_request` (`agent/chat.odin`), `chat_record_tool_result`
(`agent/chat_tools.odin`), and `chat_append_entries` (`agent/chat_request.odin`):
0.85 MiB to 0.44 MiB.

A guard is a mark and a reset, so it also removes the block mapping the next turn
would otherwise take. It is a performance change as much as a memory one, and it
states the lifetime where the memory is chosen rather than adding a rule
somewhere else. The aim is the memory each phase actually needs, not the smallest
number a run can be pushed to: a buffer that is reused and one that is bounded
both cost what they use, and a computation that needs its scratch keeps it.

Remaining, same mechanism, each one per turn or per request: the settle path in
`chat.odin`, `chat_command.odin`, `chat_instructions.odin`, `instructions.odin`,
`compact.odin` (`chat_compact_start`, `chat_compact_install`, and the compaction
record), `log_capture.odin`, `config.odin`, `config_mcp.odin`,
`discovery.odin`, the `tool_*.odin` validators, and the `store.odin` helpers
that take paths. The session release path also allocates 2.5 MiB of temp memory
at teardown: a one-off, and the same mistake.

Those in `chat_record.odin` and `log_capture.odin` are the awkward ones: they
*return* temp-allocated strings, so the guard belongs at the caller that
consumes the value, or the procedure takes an explicit allocator like every
other allocating procedure in the harness. That choice is worth making once for
the file rather than per call.

### 5. Borrow the text instead of copying it per phase

Where: the prepared request and its projection into provider messages
(`agent/chat_request.odin`), the response accumulator, and the transcript
append (`app_worker.odin`).

Why: beyond the temp arena, each phase still copies the conversation on the
heap, and the allocator holds what it is given back. An entry's text already
lives for the whole request, so a message can point at it instead of cloning
it.

How: keep one buffer per phase for the life of the session or the turn, as step
3 did for the encode body, and pass slices rather than clones wherever the
source outlives the use. The transcript append is the cheapest of these: the
entry's `[dynamic]u8` doubles as deltas arrive, and a text that is replaced
rather than appended can be written once.

Landed: the streamed answer was a fresh byte buffer per request, grown by
doubling as the fragments arrived and released when the answer was committed, so
every request allocated and copied the answer again. The session now empties that
buffer and keeps it (`chat_partial_assistant_clear`), and only session release
frees it, so the longest answer of the session sizes it once.

The projection already borrowed: `chat_append_entries` points provider messages
at the entry text rather than cloning it, so there was nothing to fix there. The
per-request tool catalog copy in `chat_record.odin` is not waste either: the row
records what was sent, tools included, and the store owns it.

Remaining, and the largest item of this step: every request loads the whole
conversation from the store with `context_load` and frees it when the request
ends, so the conversation is built on the heap once per request. That is the copy
step 6 should move into one arena per chain, where it is one allocation and one
unmap instead of a load, a copy, and a release per request.

This change is an allocation traffic reduction in the tens to hundreds of
kilobytes per turn, below what the repro's RSS sampling resolves, so it is argued
from the allocation counts in the code rather than from a measured difference.

Verification: the scripted repro in this document's method section, before and
after, with the store's own `sum(length(payload_json))` as the denominator.

### 6. One arena per request chain

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

### 7. Name the allocator every worker uses

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

### 8. Later: page ACP replay

`acp_replay_session` loads the whole retained history through `history_load`. It
is temp-allocated and freed, so it is a spike rather than steady growth. Page it
by sequence order only if long-session replay becomes a problem.

## Non-goals

- No custom allocator layer, no global arena for everything, no reference
  counting, no pooling framework.
- No `free_all(context.temp_allocator)` call sites. A guard states where the
  memory a phase used is released; a bare `free_all` states only that someone
  decided to wipe the thread's arena here.
- `agent`'s explicit `allocator := context.allocator` parameters stay. They are
  already the right shape and this plan builds on them.
- The `DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE` define stays.
- No cap on how long a session runs or how much work it does. Growth comes from
  the sizes and lifetimes of the buffers, never from a limit on the session.

## Toolchain note

The harness is verified with two Odin builds. `~/.local/bin/odin` is the fork,
and `mise`'s install is the baseline. Both compile against `ODIN_ROOT`, which is
exported as `~/Projects/Odin` in this shell, so the runtime in both cases is the
fork's slab allocator.

That allocator asserts while running the `agent` suite, which blocks the gate:

```
base/runtime/heap_allocator_implementation.odin(814:2) runtime assertion:
The heap allocator miscalculated the number of bins for a new slab.
[FATAL] Caught signal to stop test #110 agent.test_capture_keeps_a_prefix_and_says_so
```

It is the runtime rather than the frontend: it reproduces with the mise compiler
against the same root, and it reproduces with one test thread as well as sixteen.
The same test alone passes, so it depends on what the suite did before it. Until
it is fixed, the harness suites are verified with `ODIN_ROOT` unset, which uses
the install's own heap allocator.

## Order and expected effect

1. Layout budget. Landed.
2. Transcript budget. Landed.
3. Encode body reuse. Landed.
4. Temp arena release where a phase ends. Landed for the session layer; the rest
   of `agent` listed above still grows a block per turn.
5. Borrow instead of copying per phase. This is where the remaining per-turn
   growth is.
6. Chain arena, if 5 leaves a residual.
7. Worker allocators: makes what is left attributable.

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
