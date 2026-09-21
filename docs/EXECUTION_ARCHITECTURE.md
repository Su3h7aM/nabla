# Execution state machine

Status: required target. Read for request execution, async operations, tools,
steering, cancellation, suspension, or teardown. This is the single execution
contract used by [tools](TOOLS_MCP_ARCHITECTURE.md), [Code Mode](CODE_MODE_ARCHITECTURE.md),
and future [subagents](SUBAGENT_ARCHITECTURE.md). It specifies semantic states and
boundaries, not a mandatory enum for every row.

## Ownership and vocabulary

A session owns durable history and at most one active foreground turn. A turn begins
with accepted user input and ends once as Completed, Failed, or Cancelled. A logical
request uses one prepared input and a bounded attempt chain. Each attempt is one
provider operation, including a setup-only failure. A tool batch answers one accepted
model response. A job is one admitted tool call, optionally with a parent call.

Only the session owner changes execution state or writes SQLite. Workers own stable
execution inputs and publish owned observations. They do not hold `Chat_Session`,
store pointers, or mutable references into the owner's collections. A provider
callback may decode and deliver facts; it cannot decide retries, launch tools,
finalize a turn, or install a checkpoint.

Use three procedures with separate responsibilities, not a reusable framework:

- Collect external observations and transfer their ownership to the owner.
- Apply one typed event to state, checking identity and transition legality.
- Select the next effect from state. Selection reads only, including no clocks,
  locks, logging, allocation, counter increments, or hidden completion adoption.

The driver claims that effect through an explicit transition before performing it.
The claim records that a write, launch, or resume is in progress. Repeated selection
may return the same proposal; repeated application of an already claimed proposal
must fail or do nothing. This reconciles a pure selector with at-most-once launch.
Do not rely on every caller remembering to call `advance` exactly once.

An effect is a small tagged value naming data by identity. Only variants that need
owned payloads carry them. Ordinary decisions need no allocator or owned error string.
A terminal error belongs to the turn until its consumer has read it.

Time and random samples enter as observed values. Separate stable durable identities
from runtime operation identities. Reused slots require a generation; monotonic IDs
in a non-reusing bounded table do not need an extra generation by default. Reject
stale/duplicate events without leaking their payloads.

## Request stages and validators

The owner must be able to pause between the following stages. Short stages can run
as named synchronous helpers; waiting stages retain explicit state.

| Stage | Input and output | Gate before proceeding |
| --- | --- | --- |
| Boundary | Settled prior work -> effective selection, accepted input, installed checkpoint | No unanswered calls or active foreground operation; writes succeeded |
| Prepare | Committed snapshot and context -> owned projection and per-part sizes | Instruction provenance, replay compatibility, complete call/result grouping |
| Admit | Projection and model capacity -> output allowance or typed refusal | Input plus margin and output fit; argument/schema and retained-byte bounds |
| Freeze | Admitted projection -> immutable encoded bytes and settings | API encoding succeeds; endpoint, credentials, inventory and bytes have chain lifetime |
| Begin attempt | Frozen request -> durable request row and runtime identity | Attempt budget available; cancellation checked; row committed before network work |
| Await provider | One-send operation -> bounded stream observations and terminal evidence | Identity match; exposure recorded before publication; completion validated by API |
| Validate response | Complete observed response -> accepted response/batch or rejection | Completion semantics, call identities, count, names, arguments and admission capacity |
| Commit response | Validated artifact -> durable response and calls | Atomic accepted batch; no executable intent from partial or failed output |
| Execute tools | Committed calls -> committed results and retired jobs | Tool lifecycle below; all root answers complete |
| Continue or finish | Settled result barrier -> next boundary or terminal | Turn step budget, stop cause, storage health |

Failure names its stage. Preparation failure is not a transport failure. Encoding
failure creates no fictitious sent request. Rejection before call commit can produce
bounded, durable harness feedback and another logical request under the turn budget;
it is not a retry of the failed provider operation. Preserve invalid response evidence
outside executable call history. See [errors](ERROR_RETRY_ARCHITECTURE.md).

The request path must not hide preparation, compaction, backoff, transport selection
and response commit in one blocking effect. Conversely, introducing `Encoding` and
`Admitting` enum members around the same monolithic body changes nothing. Extract
artifacts and validators first, then store only the stage that must survive a return.

## Turn progression

The conceptual progression is:

```text
Idle -> Preparing -> Awaiting_Model -> Validating -> Executing_Tools
          ^                              |               |
          |                              +-> Finishing   |
          +----------------------------------------------+
Finishing -> Idle
any active phase -> Stopping -> Finishing
```

A response with no calls goes from validation/commit to finishing. Rejected output
can return to preparing with recorded feedback. Retry backoff is request state under
Awaiting_Model, not a nested agent loop. Streaming is progress within the active
attempt; retain a separate Streaming phase only if it changes scheduling behavior.
A display label alone does not need another control state.

Stopping latches a cause, refuses new work, and drains existing work. Keep one
terminal decision with structured contributing failures. User cancellation controls
user-facing turn status when it caused the stop; storage failure still poisons the
session and must remain diagnosable. Never clear a fatal storage condition because a
cancel arrived later. A finished tool result keeps the outcome actually observed.

A terminal notification is emitted once after terminal persistence succeeds, or as
an explicitly non-durable failure when persistence failed. The next turn cannot
start while a previous producer still owns shared session resources.

## Event collection and waiting

Use one bounded owner mailbox plus wake primitive for input/control, provider facts,
tool completions, and compaction completion. Use `core:sync` and existing `core:nbio`
facilities rather than a futures runtime or a scheduler package. The mailbox is an
I/O adapter; readiness and recovery policy remain in the machine.

The driver runs to quiescence by performing one selected effect at a time. Its
priority is:

1. Latch stop/storage failure and adopt available terminal observations.
2. Settle pending durable writes and refuse work that cannot launch.
3. Retire producers and deliver committed child results.
4. Advance request preparation/recovery or launch eligible tool work in stable order.
5. Run one bounded Lua slice.
6. Await a wakeup or the nearest actual deadline.

Bound each collection pass and Lua slice so one source cannot starve control. A
wakeup is a hint to inspect predicates under synchronization, not the sole record of
a completion. Check the predicate and enter the wait under the same synchronization
protocol to prevent a lost wake. Cancellation must wake the owner even when no tool
or provider event arrives. Deadline expiry is an event, not a periodic idle tick.

Reserve a terminal slot for each admitted producer. Progress may be coalesced;
terminal outcomes cannot be dropped because a queue is full. Bound streaming buffers
and apply cancellable backpressure. Keep exposure semantics conservative when output
has been handed to a frontend even if it has not rendered it yet.

For the existing blocking provider API, a single concrete request worker is the
simplest first adapter. It owns its transport on its creating thread, receives frozen
input, and returns events. If a persistent connection is used, that worker owns it
across operations and retires it on selection/shutdown commands. The session owner
never concurrently operates its socket. A direct nonblocking adapter on the owner is
also valid if it uses the existing I/O facility and preserves the same event contract;
do not implement both merely for flexibility. No thread per stream chunk.

Compaction is a separate, at-most-one session job. It returns through the same owner
wake path. Root may enqueue work but cannot independently poll or install compaction.
Retry delay and idle compaction do not justify additional timers or polling threads.
Bounded shutdown probing can remain a last-resort process mechanism, not the ordinary
execution model.

## Tool lifecycle and ordering

Represent these independent facts explicitly:

- Execution: queued, running, waiting for a child, or stopped.
- Durability: call committed, dispatch committed, result absent or committed.
- Ownership: which producer/consumer may still reference execution storage.

Do not create a Cartesian-product enum or parallel flags that restate these facts.
Use a small job phase plus placement-specific data and a separate worker handoff
record where synchronization requires it. A zero job is inactive. Derive lane
occupancy and barrier readiness by scanning the bounded table unless measurement
justifies cached counts.

```text
call committed -> queued -> dispatch committed -> started
     |              |                              |
     +--------------+-> refusal observed           +-> result observed
                              |                            |
                              +------> result committed <--+
                                            |
                                 producer/consumers retired
                                            |
                                          release
```

Dispatch intent is written before start and is not proof of start. A stop after
that write but before launch may record Not_Executed while the process has that
evidence; after a crash the same dispatch without a result is conservatively Unknown.

Completion, commit and retirement are separate. A result can commit before its
producer exits. Result delivery may then make a parent runnable, but releasing job
storage still requires producer retirement. Publication must include the last wake
access in the lifetime protocol: setting `published` before a worker touches the
mailbox for the last time is not retirement proof.

There is no global parent-plus-child submission-order commit rule. It deadlocks a
parent waiting for a later-submitted child. Instead:

- Root results and their model-context budget are ordered by model call ordinal.
- A child commits before its result is delivered to its parent.
- A parent terminal result follows settlement of its children.
- Child records remain hidden from the provider projection and retain actual durable
  order. The initial sequential Code Mode needs no dependency graph.

Start direct root calls serially by default. Future explicit Lua concurrency may
start independent children under the same worker and lane bounds. Result observation
order is not provider projection order. Do not infer data dependence from tool names
or read-only annotations. A model-authored edit after a read in one response was
already authored without seeing the read result; serialization cannot fix that.

## Cancellation, suspension and restart

Cancellation is a per-turn control object with a monotonic stop request. Jobs may
have a local stop and borrow a stable ancestor control. Do not reset a process-global
token while an old worker may still read it. Tool deadlines and Lua budgets are
separate from cancellation; model deliberation has no implicit harness deadline.

A suspended Lua coroutine is process-local state. Only the owner resumes it, and
only after the awaited child result commits. A callback never calls a continuation.
Steering, a completed summary, and UI input cannot resume a stopped script.

Restart reconstructs history, not execution stacks. Settle undispatched calls as
Not_Executed and dispatched unanswered calls as Unknown, including nested calls.
Close interrupted request/turn rows. Never replay a script, tool, scheduled retry,
or in-flight model request. A later user prompt starts new work from that history.
Durable human-approval suspension would require an explicit persisted question and
answer; it is future work, not serialization of a coroutine.

### A worker that will not stop

A patience deadline bounds how long the harness waits, not how long arbitrary native
code can execute. After that deadline, it may record Unknown, but the producer still
owns every object it can access. The minimal target is to mark the runtime unusable
for further work and ask root to exit after bounded cleanup. Retain reachable memory,
registry bindings, logger, and synchronization objects until process exit. Do not
claim graceful retirement or reuse a busy backend.

Do not continue normal turns by marking a worker Stuck and handing it one allocation
while freeing its borrowed workspace, skill catalog, backend or log sink. Supporting
continued service would need a detached, fully owned execution capsule and retained
backend authority, which is more machinery than this prototype needs. Use process
isolation for a backend that requires reliable forcible termination. Process groups
and reaping are part of that backend's contract; a new flag cannot kill a thread safely.

## Input and selection boundaries

Queued steering is input for the next request boundary of the current turn, after
all tool answers settle. Cancellation is immediate control, not steering. A waiting
tool does not authorize a new model request or a mid-call registry replacement.

One agent-owned bounded input queue defines disposition. Frontends report queued,
applied or unapplied input; they do not reinterpret a failed turn's leftover steering
as a new prompt or execute its text as a command. On any terminal outcome, return
unapplied steering to the caller explicitly. Starting a follow-up turn requires a
separate accepted prompt. This avoids surprising work after cancellation or failure.

Pending provider/model/effort changes apply at the next ordinary request boundary,
not during a retry chain. Validate a candidate before replacing the usable selection.
Retire invalidated connections/compaction and keep their borrowed configuration alive
until they stop. Tool inventory stays frozen through the turn. Configuration changes
are diagnostics/request metadata, not invented conversation messages.

Reliable input across process restart is a future capability. If added, persist one
bounded inbox with stable input IDs, explicit next-turn/next-boundary targets, and
atomic consumption with the corresponding conversation append. Acknowledge durable
acceptance only after that write. Unapplied turn-targeted input never silently moves
to another turn. Do not implement inbox schemas or auto-wake policies just to prepare
for hooks or subagents.

## Acceptance

Transition tests supply events, clock values and effect outcomes without I/O. Cover
repeated selection/application, stale identity, cancellation before every start,
commit failure, request retry/backoff, child-before-parent settlement, and terminal
notification exactly once. Integration fixtures prove the contracts pure tests cannot:
last-producer access before release, bounded queues, no dropped terminal event,
blocking-provider responsiveness, storage recovery, and stopped-worker process exit.
Test empty successful data separately from allocation/encoding failure. Use allocator
tracking and supported sanitizers on asynchronous and Lua boundaries.
