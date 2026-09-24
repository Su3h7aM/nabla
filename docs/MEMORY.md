# Memory

Status: implementation plan, not an architectural contract. It records what was
measured, what the harness keeps resident, and the order in which that should
change. Delete a step as it lands; keep the measurements current, because they
are what the plan exists to justify.

The harness asked for this because a run's RSS climbed steadily while its
conversation stayed small. The growth was real, but it was not the model
context.

## What was measured

Method: a throwaway copy of the root package in `/tmp` with `NABLA_TRACK=1`
installing `mem.Tracking_Allocator` on the main context, run in `tmux` against a
local mock provider that streams 60 KiB answers in 512-byte chunks and calls
`builtin_shell` with a 60 KiB result. A `malloc` interposer tracked allocations
that never reached the tracked allocator. Maps, `VmRSS`, and `VmHWM` came from
`/proc`.

| Fact | Value |
| --- | --- |
| Steady RSS after startup | 17 to 22 MiB |
| `layout.storage_size(CONVERSATION_CAPACITIES)` | 16.10 MiB |
| The same with `nodes = 1024` | 0.72 MiB |
| Peak RSS at startup (`VmHWM`) | about 108 MiB |
| Growth per 60 KiB turn | 340 to 450 KiB |
| Of that, allocated through `app.run.alloc` | about 95 KiB |
| Of that, on the thread default allocator | the remainder |

The startup peak is the models.dev document: 4.9 MiB of JSON parsed into a tree
several times that size inside a `virtual.Arena` that is unmapped when
extraction ends. It is a spike, not a leak, and it is already handled.

## Where the memory goes

1. **The layout budget.** `frame_storage_new` (`tui.odin`) allocates
   `layout.storage_size(CONVERSATION_CAPACITIES)`, one block of 16.10 MiB, held
   for the process lifetime. `nodes = 16384` costs 10.74 MiB of it on its own.
   The reservation is sized "at ~131k transcript words", which no terminal
   renders. This is roughly 70 percent of the baseline.
2. **The resident transcript.** `Snapshot.entries` is append-only and cleared
   only by `snapshot_clear` on `/new` or `/resume`. It is a second copy of what
   `sessions.db` already holds. Its tracked share was about 32 KiB per turn.
3. **The encode cache.** `Provider_Encode_Cache` holds, per request text, the
   text and the bytes it was written as, about twice the request body, for the
   life of the session. Its tracked share was about 40 KiB per turn.
4. **Worker-thread scratch.** A thread created without `init_context` gets the
   default context, so its `context.allocator` is the process heap allocator
   (`base/runtime/heap_allocator_unix.odin`, which is libc `malloc`). Requests
   and tool calls each run on their own thread, and their large transients land
   there. This is the biggest part of the per-turn growth and the part an
   explicit-allocator reading of the code cannot see.

## What the language already provides

The plan is built from four facilities that exist today, so no new mechanism is
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
- `core:container/queue` is the standard ring buffer, and
  `mem.Tracking_Allocator` is the standard leak and retention check. Tests
  already use the latter (`app_test.odin`).

## Steps

### 1. Raise the layout budget on demand

Where: `tui.odin`: `CONVERSATION_CAPACITIES`, `Frame_Storage`,
`frame_storage_new`, `frame_storage_destroy`, `draw_conversation`.

Why: 16.10 MiB is reserved for a transcript nobody displays. The budget should
start at what a screen holds and grow to what a session actually used.

How: start from a small capacity set sized to the viewport. Create the context
with `layout.init` so it owns its storage. When a frame reports
`Capacity_Exhausted`, read the pool from `layout.diagnostics`, double it with
`layout.reserve`, and solve again, bounded to a few attempts. Record the current
capacities on `Frame_Storage` so the raise has a base. `layout_storage` and its
`delete` disappear, so the struct gets smaller.

The existing `ponytail` comment on `CONVERSATION_CAPACITIES` names this exact
upgrade path and goes away with it.

Effect, measured on a fresh launch of the built harness: the allocated budget
falls from 16.10 MiB to 0.55 MiB, `VmRSS` from about 17.3 MiB to 14.2 MiB, and
reserved address space by 26 MiB. The RSS saving is smaller than the budget
saving because the untouched pages of the old allocation were never resident;
the 16.10 MiB was committed and addressable, not all of it touched.

Verification: a `conversation_test.odin` case renders a transcript larger than
the initial capacities and asserts the frame solved, that the budget grew, and
that the initial budget is under a mebibyte.

### 2. Bound the resident transcript

Where: `app.odin` `Snapshot.entries` and its two release sites,
`app_worker.odin` (`snapshot_clear`, `snap_append_locked`, `obs_assistant_begin`,
`obs_assistant_text`, `obs_assistant_end`, `snap_append_tool`), and the readers
in `tui.odin` (`draw_conversation`) and `app_input.odin`
(`tool_box_entry_at`, `tool_box_scroll`).

Why: the transcript duplicates the session the store already keeps, and it
grows for the life of the process.

How: hold the entries in a `queue.Queue(Entry)` with a byte budget
(`TRANSCRIPT_MAX_BYTES`). Appending adds the entry's size; eviction pops from
the front and frees its text. `Entry` gains a `bytes` field so eviction does not
re-measure. Readers use `queue.get` and `queue.get_ptr` instead of indexing.
`snapshot_clear` frees each entry and clears the queue. Report eviction once, so
the behavior is not silent.

Deliberately not doing: paging older entries in on scroll. That needs a
scroll-to-sequence mapping and reads per frame. The store is the record and
`/resume` rebuilds the view from it, so a bounded window is enough.

Verification: with a tracking allocator installed, append many entries and
assert the resident bytes stop at the budget and that retained bytes stop
growing.

### 3. Bound the encode cache

Where: `ai/encode.odin`: `Provider_Encode_Cache`, `encode_slot_for`,
`encode_slot_store`, `encode_finish`, `encode_body_store`.

Why: the cache keeps each request text and its encoded bytes for the session,
which is about twice the request body, next to a store that already has the
conversation.

How: add a body-size bound. Once `body_bytes` exceeds it, `encode_slot_for`
returns nil without advancing the cursor, so the adapter writes directly, which
it already does when the cache is absent. `encode_finish` already truncates
slots to the cursor, so the cache keeps the stable prefix and drops the rest.
The cache is documented as an accelerator that never changes what is sent, so
bypassing it is safe by construction.

Verification: an `ai` test encodes one body above the bound with and without a
cache and asserts the bytes are equal and the cache kept no slots past the
bypass point.

### 4. One arena per request chain

Where: `agent/chat_chain.odin` (`Chat_Request_Chain` and `chat_chain_release`),
`agent/chat_request.odin` (the prepared request and the encoded body), and the
worker entry that encodes them.

Why: these are the largest per-turn transients and they currently land in the
heap, where the pages stay after the individual frees. One arena per chain
returns them in a single unmap, and one destroy replaces several frees.

How: give the chain a `virtual.Arena`, allocate the prepared request and the
encoded body from `virtual.arena_allocator`, and destroy it in
`chat_chain_release` after the worker is joined. The rule that keeps it safe:
the arena may only back data whose lifetime ends at that release. Published
`Chat_Event`s stay on the session allocator, because the owner reads them after
the worker exits.

This is the only step that touches concurrency lifetimes. Land it after 1 to 3,
re-measure, and skip it if the residual does not justify it.

### 5. Name the allocator every worker uses

Where: the worker entry points that already assign `context.logger`:
`agent/chat_chain.odin`, `agent/chat_worker.odin`, `agent/tool_job.odin`,
`agent/compact.odin`, `app_worker.odin`, `app_catalog.odin`,
`app_watchdog.odin`, `acp_server.odin`.

Why: a thread created without `init_context` gets the default context, so its
`context.allocator` is the process default. Today that is the same libc `malloc`
the run already uses, so this saves nothing on its own. It makes ownership
explicit at the point the thread starts, makes every worker allocation visible
to a tracking allocator, and keeps the invariant true if the run allocator ever
changes.

How: one assignment beside the existing logger assignment, using the owner's
allocator.

### 6. Optional: fewer allocations for transcript text

Only if a measurement asks for it. The bounded ring already caps the total; the
next step would be one byte buffer plus offsets instead of one `[dynamic]u8`
per entry.

### 7. Later: page ACP replay

`acp_replay_session` loads the whole retained history through `history_load`. It
is temp-allocated and freed, so it is a spike rather than steady growth. Page it
by sequence order only if long-session replay becomes a problem.

## Non-goals

- No custom allocator layer, no global arena for everything, no reference
  counting, no pooling framework.
- `agent`'s explicit `allocator := context.allocator` parameters stay. They are
  already the right shape and this plan builds on them.
- The encode cache is bounded, not removed. Remove it only if the bound makes it
  useless and a measurement says it does not pay.
- The `DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE` define stays.

## Order and expected effect

1. Layout budget: 16.10 MiB of budget down to 0.55 MiB, about 3 MiB of RSS, and
   a smaller `Frame_Storage`. Landed.
2. Transcript budget: the transcript term becomes a constant.
3. Encode-cache bound: the request-sized duplicate becomes a constant.
4. Chain arena: the remaining per-turn pages return to the OS.
5. Worker allocators: the remaining growth stays attributable.

Expected result for a session like the measured one: baseline from 17 to 22 MiB
down to roughly 4 to 6 MiB, and RSS that plateaus at the transcript and cache
budgets instead of climbing by hundreds of kilobytes per turn.

## Re-measuring

The probe lives in `/tmp`, not in the repository: a copy of the root package
with an env-gated `mem.Tracking_Allocator`, plus the mock provider, driving
turns through `tmux`. Two habits keep the result honest: read `VmRSS` and
`VmHWM` from `/proc` rather than trusting a single sample, and check the
tracked accounts and the malloc interposer separately, because allocations made
on a thread's default allocator do not appear in the tracked ones.

The repository keeps only the tests: the layout growth case from step 1, the
transcript bound from step 2, and the encode bound from step 3.
