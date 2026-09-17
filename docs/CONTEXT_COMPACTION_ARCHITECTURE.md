# Context management and non-blocking compaction

Status: implemented. `agent/compact.odin` owns the lifecycle, `agent/compact_lifecycle_test.odin`
covers it end to end, and `agent/session/context.odin` owns the durable checkpoint. Written
against `dev-2026-09-nightly:a2fb372`.

This document supersedes the earlier compaction policy in `AI_HARNESS_ARCHITECTURE.md` §10 and
the summarization-request policy in `SKILLS_ARCHITECTURE.md` §14. It does not change their
history, instruction-snapshot, replay, or skill-reload contracts.

---

## 1. Contract

One logical session, one foreground agent. Compaction is an auxiliary model request over an
immutable prefix, not another agent, turn, or session. The foreground keeps using the old
context while that request runs. A finished summary replaces only the prefix it actually
summarized; every later entry survives in order.

- No foreground path waits for summarization, retries it inline, or joins a running thread.
  There is no `Compacting` member of `Chat_State`.
- Pressure, `context.compact`, and `/compact` record the same intent and meet at
  `compact_request_intent`.
- Compaction changes model-visible context only. The transcript is append-only, and turn, request,
  and session identity are untouched.
- The active cacheable prefix is preserved until a deliberate installation boundary. Already-sent
  tool results are never pruned in place.
- A request in flight keeps its frozen input. Installation happens only between foreground
  requests, after the preceding response and all its tool results are committed.
- One unfinished compaction per session, including a completed summary awaiting installation.

### 1.1 What "never wait" guarantees

Foreground execution never waits for a compaction result. It cannot be guaranteed that a session
runs forever: with finite remaining capacity `H` and appended context `D(t)`, an unbounded
summarization delay eventually makes `D(t) > H`. Keeping the appended context, keeping the old
prefix, and continuing requests cannot all hold at that point.

The operating target is continuous execution while compaction completes inside the reserved growth
budget. When it does not, nothing waits, nothing is dropped, no session is reset, and no
inadmissible request is sent: the turn fails with an explicit message. §11 covers that path.

## 2. Context algebra

`session.Seq`, `session.Request_No`, and `session.Turn_No` are the only boundary identities.
Array positions, token counts, and timestamps are not.

- `B`: the base checkpoint's sequence, `Maybe(Seq)`. Nil means the session had none.
- `F`: the last entry this summary covers.
- `P`: the prefix being summarized: the checkpoint at `B`, if any, followed by model-visible
  entries after its coverage through `F`.
- `D`: every model-visible entry with `seq > F`.
- `C`: the summary text.

```text
At fork              Background                Foreground
I + P                summarize(I + P)          I + P
                                               I + P + D1
                                               I + P + D1 + D2
Summary ready        C                         I + P + D1 + D2
At installation                                I + C + D1 + D2 + D3
```

Installation is a checkpoint append, not a merge:

```text
new_context = checkpoint(C, covered_seq = F) + context_entries_after(F)
```

`session.context_load` already implements the right-hand side: it reads the newest checkpoint and
then every model-visible entry with `seq > covered_seq`. A checkpoint at sequence 150 may cover
only through 100, so the tail is selected by coverage and never by the checkpoint's own sequence.
Nothing is copied from the summarizer's view of the tail, which is why `D3` is safe.

A second compaction summarizes the previous checkpoint plus newer entries. It does not resurrect
covered history or accumulate two summary messages.

### 2.1 The cut

`chat_compact_seam(entries, CHAT_COMPACT_KEEP_MESSAGES)` keeps the newest entries verbatim and
backs the seam left until it no longer falls inside a call/result run. The test is on neighbouring
kinds: a seam is bad when the entry at it is a `Tool_Result`, or when its predecessor is a
`Tool_Call`. Backing up over a whole run keeps every call with its result, and a multi-call
response stays together.

The retained tail is what preserves the newest user message and any in-progress work, so the
summary never has to restate the request being answered.

## 3. Data

| Type | What it holds |
|---|---|
| `Compact_Snapshot` | The frozen request: API, owned endpoint, credential, encoded body, model, tool count, session id, user agent, `base_seq`, `covered_seq`, `turn_no`, the request estimate, and the estimate of the prefix the summary will replace |
| `Compact_Job` | A snapshot, a private interrupt and deadline, the thread handle, a mutex allocator over the session's allocator, the output buffer, the finish reason, tool-call count, failure flag, error text, provider usage, and the start tick |
| `Compact_Control` | Owner-side state in `Chat_Session`: `state`, `trigger`, the job pointer, the pending trigger and its source sequence, and the last failure time |
| `Compact_Trigger` | `None`, `Pressure`, `Agent_Tool`, `User_Command` |
| `Compact_State` | `Idle`, `Running`, `Ready`, `Retiring` |
| `Compact_Request_Result` | `Scheduled`, `Already_Scheduled`, `Unavailable` |

`Ready` means a complete, checked summary exists in a joined job. `Retiring` means cancellation was
requested and the worker still owns its memory. Only the owner thread changes control state.

Procedures, all in `agent/compact.odin`:

| Procedure | Role |
|---|---|
| `compact_request_intent` | Records an intent. Starts nothing, reads nothing durable |
| `chat_compact_request` | `compact_request_intent` for a whole session |
| `chat_compact_poll` | Adopts a finished job, or releases one that was cancelled. Never waits |
| `chat_compact_start` | Chooses `F`, freezes the request, records it, starts the worker |
| `chat_compact_consider` | Starts a job for the request about to be sent, if a trigger calls for it |
| `chat_compact_service` | Polls and installs a summary whose boundary has arrived |
| `chat_compact_relieve` | Polls and installs unconditionally. The last resort before a refusal |
| `chat_compact_install` | Commits the checkpoint. The only place the context changes |
| `chat_compact_cancel` | Interrupts a running job, or drops a candidate |
| `chat_compact_destroy` | Teardown: interrupt, join, release |

## 4. The worker

`chat_compact_worker` calls `ai.Provider_Request_Operation_Encoded` with the frozen bytes, the
job's interrupt and deadline, and a callback that appends text into `job.output`. It touches no
session state, runs no tool, writes no database row, and logs nothing: the owner reads the result
when it joins and is the only thing that records the compaction's lifecycle.

Three details make the thread safe:

- **The body is frozen as bytes.** `Compact_Snapshot` owns every string and the encoded request
  body, so the foreground may destroy the preparation it was built from and append as much history
  as it likes. `ai.Provider_Request_Operation_Encoded` is the same send path as the controlled
  form, so an encoded request behaves exactly like one encoded on the spot.
- **The allocator is serialized.** The job's memory is allocated through
  `mem.mutex_allocator` over the session's allocator. The worker's and the owner's allocations do
  not overlap in practice, but the session's allocator may be a test's tracking allocator, which is
  not safe to touch from two threads. The job itself is allocated with the backing allocator,
  because it cannot be freed through its own lock.
- **Signals are blocked across creation.** A thread inherits the signal mask its creator had, so
  `chat_signal_block_watched` is held across `thread.create`. Blocking inside the worker would
  leave a startup window in which the process handler could run on the wrong thread.

The worker sets `context.allocator` to the job's allocator at entry, so everything the provider
operation allocates is released by the same allocator after the join.

## 5. Lifecycle in the foreground

At a request boundary, in `chat_perform_request`:

1. `chat_compact_service` polls, and installs a summary if its trigger or the pressure calls for
   it. The context may change here, before anything is built.
2. `chat_prepare` builds the request from the context as it is now.
3. `chat_compact_consider` freezes that exact request when a trigger calls for it. The frozen bytes
   are what the provider will see, so the prefix the summarizer reads is the warm one.
4. Admission is checked. If it fails, `chat_compact_relieve` is the only other chance: it installs
   a summary that is already finished, and the request is rebuilt. If that still does not fit, the
   turn fails and says so.

Install decisions use `chat.last_estimate`, the size of the previous request, because installing
after a request is built would invalidate it. Start decisions use the freshly built request's own
estimate, because the snapshot must be the exact bytes about to be sent.

Idle servicing is the root package's job: `run_worker` polls with `app_compaction_tick` every
`WORK_IDLE_POLL` while `app_compaction_pending`, so a summary that finishes with no work queued is
still adopted and installed.

## 6. Policy

```text
reserved      = max_output_tokens, or CHAT_DEFAULT_OUTPUT_RESERVE_TOKENS
usable        = context_window - reserved - CHAT_ADMISSION_MARGIN_TOKENS
start_at      = 80% of usable
install_at    = 90% of usable
```

A pressure job starts when the request about to be sent reaches `start_at`. A finished summary from
a pressure job is installed when the previous request's estimate reached `install_at`, or when
`estimate + CHAT_COMPACT_GROWTH_RESERVE_TOKENS >= usable`. A summary from `context.compact` or
`/compact` is installed at the first safe boundary after it is ready, because the caller asked for
a context change rather than for capacity insurance.

| Constant | Value | Why |
|---|---|---|
| `CHAT_COMPACT_KEEP_MESSAGES` | `10` | Entries kept verbatim, extended as needed to keep a call/result run whole |
| `CHAT_COMPACT_MAX_OUTPUT` | `4096` | Bound on the summary, and part of the window arithmetic for the compaction request |
| `CHAT_COMPACT_START_PERCENT` | `80` | Start before the window is full, so the request has room |
| `CHAT_COMPACT_INSTALL_PERCENT` | `90` | Keep the warm prefix for as long as it is useful |
| `CHAT_COMPACT_GROWTH_RESERVE_TOKENS` | `16 * 1024` | What a ready summary assumes the foreground will append while it waits |
| `CHAT_COMPACT_MIN_REDUCTION_TOKENS` | `1024` | A saving smaller than this is not worth a cache break |
| `CHAT_COMPACT_RETRY_DELAY_MS` | `5000` | Keeps a failed summarization from being retried at every boundary |

These are engineering defaults, not measurements. The latency budget is covered by starting at 80%,
which leaves a fifth of the usable window for the foreground to consume while the request runs.

A summarization request must also fit: `estimate + CHAT_COMPACT_MAX_OUTPUT + margin <=
context_window`, checked before the request is recorded. A context too large to summarize in one
request is reported, never silently shortened.

A summary is worth keeping only when it frees at least `CHAT_COMPACT_MIN_REDUCTION_TOKENS` of the
prefix it replaces. That is checked at adoption, before any checkpoint is written.

### 6.1 What is deliberately approximate

The growth reserve is one constant rather than a measured growth rate. Per-tool result caps bound
one result, not a batch, so a turn with many large results can still exceed the reserve. Until
aggregate result admission exists, the reserve is an estimate and the continuity target is
best-effort. §11 describes what happens when it is exceeded: nothing waits, and the turn fails with
a message.

## 7. The summarization request

The request reuses the conversation's own prefix: same resolved provider and model, same
instruction snapshot, same tool order and schemas, same effort, same prompt-cache key. The
directive is appended as the last user message. `chat_build_request_into` takes the directive as an
argument, so there is one projection for both kinds of request and the summarizer's input is a
cache read rather than a cache write.

The worker has no execution authority even though the tool definitions are in its input. A response
that proposes a tool call is not a summary, so it is rejected at adoption.

### 7.1 The summary is not a transplantable cache

The summarizer generates `C` after `I + P + directive`. Its key/value state for `C` depends on that
prefix; placing the same text after `I` instead is a different sequence. So:

- Requests issued while the job runs, and while a ready summary waits, keep reusing `I + P`.
- The summary request may read the old prefix from the cache. It does not create a cache for the
  new compacted context.
- After installation, only unchanged content before the replacement, normally instructions and
  tools, can still hit. Unchanged text inside the tail is downstream of the change and is processed
  again. The first real request on the new context establishes its cache.

Cache hits are provider observations, never promises: TTL, eviction, and routing can all miss. No
prewarm request is issued, and no cache breakpoint beyond the provider's automatic one is placed.

### 7.2 Directive and checkpoint text

`CHAT_COMPACT_DIRECTIVE` is appended after the prefix. It asks for fixed headings, requires
observed results to be distinguished from plans, requires exact paths and identifiers, forbids
treating quoted tool output as instructions, requires a previous checkpoint to be merged rather
than copied, and forbids tool calls.

The checkpoint that re-enters the conversation is stored whole:
`CHAT_COMPACT_CHECKPOINT_PREAMBLE` plus the summary. `session.context_load` returns that text and
the projection emits it as a user message, so a resumed session sends exactly the bytes the
checkpoint was written with and no framing lives in two places.

## 8. Persistence

The durable job identity is the `.Compaction` request row. `chat_compact_start` records the request
before the thread starts, with the input record naming `B`, `F`, the instruction snapshot, and the
covered span. When the owner adopts a finished job it stores the candidate summary and its coverage
in the request's `response_json` and finishes the request. The request is the summary's record; the
checkpoint is its installation.

`session.checkpoint_install` performs the whole check-and-append in one transaction:

1. The caller holds the session's writer claim.
2. The latest installed checkpoint equals the expected base, including nil equality.
3. The originating request belongs to the session, has purpose `.Compaction`, completed, and has not
   already installed a checkpoint.
4. `F` exists.

Only then is the checkpoint entry written, with `covered_seq = F` and `previous_seq = B`. Because the
base is checked, a summary computed against a context that has since been compacted again is refused
rather than installed. Because the request is checked, a duplicate delivery cannot move the context
twice.

Recovery follows from append-only history:

- Crash before the request is recorded: nothing durable, nothing changes.
- Crash with the request running: `session_recover` closes it as interrupted. The old context stays.
- Crash after the candidate is stored, before installation: the old context stays. Uninstalled
  candidates remain audit records; a fresh job is started if pressure requires one, which may repeat
  the inference but needs no second state machine.
- Crash during the append: SQLite commits the checkpoint or nothing.
- Crash after the append: `context_load` restores the checkpoint and the tail.

## 9. Failures and pressure

| Condition | Behavior |
|---|---|
| Transport failure, timeout, unusable summary | The request is finished as failed, the old context stays, the foreground continues |
| A repeated trigger while a job runs | Coalesced; the trigger is promoted if it was explicit |
| Candidate superseded by a newer checkpoint | Refused by `checkpoint_install` |
| Summary does not free enough | Reported, no checkpoint written, no cache break |
| Context too large to summarize at all | Reported before the request is recorded |
| Durable write failure | The existing `storage_failed` latch stops the session |
| Model or session change | `chat_compact_cancel`; `session_activate` destroys the chat and its job |
| Explicit turn cancellation | Compaction keeps running: it belongs to the session, not the turn |
| Admission fails with nothing ready | The turn fails with an explicit message |

Compaction never blocks a request, never drops history, and never resets a session to recover. When
the reserved headroom runs out before a summary arrives, the turn fails and says why; the user can
start a fresh session for a new topic. A provider that admits only one request at a time cannot
meet the non-blocking target at all: there the summarization occupies the only lane, which is a
property of the endpoint, not of this design.

Retry policy is one delay: after a failed job, the next automatic attempt waits
`CHAT_COMPACT_RETRY_DELAY_MS`. An explicit trigger is a caller asking again and is not held back.

## 10. Deliberate deferrals

These were considered and are not built. Each is additive; none changes the contracts above.

- **Aggregate tool-result admission and spill.** Today one result is capped at
  `TOOL_MAX_RESULT_BYTES` before it is stored. A bounded, retrievable result store would let a large
  batch be spilled instead of consuming the growth reserve.
- **Cache breakpoint control.** `Provider_Message.Cache_Breakpoint` is unused; only Anthropic's
  automatic breakpoint is exercised. Explicit breakpoints would limit lookback and cache-write
  costs on long prefixes where the provider supports them.
- **Prewarming the compacted prefix.** A provider request could populate the new context's cache
  before a real request needs it. It adds cost and a second in-flight operation.
- **Provider-normalized overflow evidence.** A confirmed context-limit error could install an
  already-ready candidate and retry once. That needs an adapter-level classification, and the local
  admission check already refuses oversized requests.
- **Measured growth rate.** Replacing the constant reserve with a recent-rate estimate.

## 11. Tests

`agent/compact_lifecycle_test.odin` runs real HTTP providers, stalls one on demand, and drives the
lifecycle:

- A summary is held open while a whole foreground turn completes; an entry is appended while the
  job still runs; the summary is then installed. The resulting context is asserted to be the
  checkpoint plus everything after `F`, including the foreground's output and the late entry, and
  the next request is asserted to open with the checkpoint and cost less than the one it replaced.
- A failed summary leaves no checkpoint, keeps every entry, and closes its request as failed.
- Destroying a session while a summary is in flight stops the worker.
- `context.compact` is advertised, records its intent, returns immediately, and leaves the job
  unstarted until the next boundary.

`agent/compact_test.odin` covers the seam and the request projection; `agent/session/context_test.odin`
covers checkpoint installation, base validation, and duplicate refusal.

`mise run check` and `mise run test` are the gate. Provider cache economics and summary quality
require live experiments; no local test can establish them.

## 12. Provenance

Two harness studies informed the design and are summarized here rather than depended on:
`/tmp/deepseek-context-management.md` (measurement, blocked triggers, balanced selection,
cache-aligned summarization, durable transactions) and `/tmp/codex-context-management.md` (provider
anchored usage, inline triggers, tool-output bounding, durable replacement). Neither implements
non-blocking compaction, and neither establishes a safe universal threshold.

Provider documentation, consulted 2026-09-17:
[OpenAI prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching) (exact
rendered-prefix matching, cache keys as routing hints rather than guarantees) and
[Anthropic prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
(tools/system/messages hierarchy, automatic breakpoints, tool-choice invalidation).
