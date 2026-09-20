# Lua Code Mode and asynchronous tool execution

Status: proposed architecture, not implemented. This document records the target
and its implementation gates. Existing source identifiers describe integration
points, not APIs that have already been added.

Code Mode requires changes to tool execution, session recording, and the driver.
The current synchronous tool signature and blocking turn loop are not constraints
on this design. Preserve useful guarantees, not interfaces that prevent correct
suspension, cancellation, or ownership.

This document supersedes the exclusion of Code Mode and asynchronous tool execution
in [Tool and MCP architecture](TOOLS_MCP_ARCHITECTURE.md). It extends the lifecycle
in [AI harness architecture](AI_HARNESS_ARCHITECTURE.md) and supplies the shared
execution lifecycle for the planned [subagent tool](SUBAGENT_ARCHITECTURE.md).
Nothing here changes the implemented behavior until the corresponding work lands.

## 1. Decision

Add `builtin_code`, which executes a Lua 5.4 chunk in a fresh, restricted state.
Scripts compose existing native and MCP tools, inspect intermediate results, and
return only the information the model needs.

Build an owner-driven asynchronous tool state machine for both direct model calls
and Lua calls. A tool starts, remains pending without occupying the session owner,
and reports a completion event. Explicit transitions require the result to be
recorded before making the waiting script runnable or advancing to the next model
request. State structs hold facts; step procedures decide effects; the driver
performs those effects and feeds their outcomes back as events.

Use the embedded `vendor:lua/5.4` runtime. Do not introduce JavaScript, another Lua
implementation, an external scripting dependency, or a custom language interpreter.

The first complete implementation includes:

- Fresh Lua state per Code Mode call, with no persistent globals or session KV.
- Ordinary sequential Lua calls that suspend while their tools run.
- Explicit, bounded concurrency through tool task handles.
- The same tool admission, execution, recording, and cancellation path for direct
  and nested calls.
- Durable parent-child call relationships, with nested records excluded from the
  model conversation.
- A responsive session owner while tools are pending, including cancellation,
  retirement, and bounded Lua execution slices.

No persistent cells, model-facing `wait` tool, detached jobs, script replay,
workflow engine, remote runtime service, or general plugin framework is required.

## 2. Reference and current implementation

Three reference studies were read in full:

- `/home/su3h7am/Projects/refs/harness/code-mode-study.md`
- `/home/su3h7am/Projects/refs/harness/tool-calls-study.md`
- `/home/su3h7am/Projects/refs/harness/state-machine-study.md`

Those paths are local research references, not repository dependencies. The decisions
needed to implement Nabla are recorded here so the document stands on its own.

The useful precedents are:

| Reference | Adopt | Do not copy without a separate requirement |
| --- | --- | --- |
| Cloudflare | One execution entry, host-held authority, discovery separate from invocation | Durable workflows and replay |
| Opencode | Fresh execution data, searchable inventory, call and output budgets | A custom language interpreter and extension framework |
| Codex | Nested calls routed through the host, explicit execution identity and retirement, a shared/exclusive gate for parallel work | Remote runtime protocol, session cells, `exec`/`wait` |
| Goose | Cancellation propagated to nested dispatch and cleanup, one applicable step at a time, answers kept complete under cancellation | Its operation catalogue and runtime lock |
| DeepSeek | Explicit phase set, events that arrive from outside the machine, bounded wakeups | An inbox and wake-budget system before anything needs one |
| Zaly, MiniMax, fx, mini-swe-agent | Contrasts: placeholder tasks, injected completion messages, admission pipelines, single-threaded loops | Placeholder handles, polling tools, and a vendored inner agent loop |

Cloudflare's TypeScript training and token measurements are not evidence for Lua
performance or model reliability. Evaluate Lua scripts against Nabla's actual models.
The expected benefit is fewer model round trips and smaller intermediate context,
not a claim that Lua runs host tools faster.

The two later studies changed three decisions from the first draft of this document:
work is bounded by explicit lanes rather than by a per-server lock, readiness and
settlement order are specified rather than left to iteration order, and a cancelled
turn must settle every committed call before it finalizes. Section 6 states those
rules.

Current implementation facts:

| Location | Current behavior | Required change |
| --- | --- | --- |
| `agent/tool.odin` | `Tool_Definition.placement` separates worker, owner, and Lua execution; `Tool_Context` has local and inherited stop control | Add configuration and filtered advertisement |
| `agent/chat_tools.odin` | Session-owned jobs drive top-level and sequential child calls through the same bounded effects | Add task-handle concurrency later |
| `agent/agent.odin` | `chat_session_advance` selects one bounded tool effect, drains jobs while cancelling, and counts only top-level results at the turn barrier | No change required for sequential Code Mode |
| `agent/chat.odin` | The driver performs each selected tool effect and returns to `chat_session_advance` | Move the outer worker to a general event pump if more owner events need service |
| `app_worker.odin` | The root worker owns the store and drives the turn state machine | Wake the driver directly on tool completion instead of relying on the bounded wait slice |
| `agent/config.odin` | Lua 5.4 text-only execution and an instruction hook, no opened standard libraries | Reuse the binding, not the config VM, limits, or conversion routines |
| `agent/tool_mcp.odin` | MCP definitions use one executor and the ordinary result envelope | Retain the adapter; schedule calls through a per-client serialization lane |
| `app_mcp.odin` | Registry refresh and backend replacement happen between turns | Keep each borrowed generation alive through job retirement |
| `agent/session` | Schema version 5 records `parent_call_seq`; provider projection omits child calls, dispatches, and results | No change required for sequential Code Mode |
| `agent/chat_request.odin` | Registered definitions are advertised; stored top-level calls become provider messages and child records are omitted | Add configuration-driven Code Mode advertisement |

The existing result envelope, intent-before-effect recording, immutable turn
inventory, and single session writer are useful guarantees. None requires the
session owner to block while a tool executes.

## 3. What asynchronous means

Three different capabilities must not be confused:

1. Host-side suspension. A tool is pending, the agent makes no model request, and
   the session owner waits for an event while remaining able to process control
   messages. This is required for the first implementation.
2. Concurrent tool work. A Lua script explicitly starts independent calls and
   later awaits their results. This is included with bounds and backend lanes.
3. Detached work. The model receives a handle, continues a conversation, and reads
   a job in a later turn. This is not included.

The owner is genuinely idle while a tool runs: it sleeps on the event queue with the
nearest deadline as its wakeup time, makes no model request, and polls nothing. CPU is
spent only by the worker doing the work.

Detached work is excluded because it needs a policy this harness does not have yet:
what may start a turn the user did not ask for, how many such turns a completion may
open before the harness stops itself, and how a completed job is later read without
re-doing its effect. Code Mode does not need any of that. Its benefit comes from
composing calls inside one turn, and its long-running case is still one turn waiting
for one result. The state machine is already shaped for the upgrade if it is ever
wanted: a session with pending jobs stays `Idle` at the chat level, and a completion
would arrive as an event that starts a new turn from committed history, exactly as a
user prompt does.

An ordinary model tool call already means "produce this result before continuing".
It need not expose a future or a polling tool to the model. Internally, the owner
submits it and suspends the turn until its completion event arrives. Then the owner
commits its result and schedules the next agent step.

A Lua coroutine suspends at an await. A worker thread or asynchronous backend may
continue executing the tool, but no Lua thread blocks waiting for it. Once a result
is committed, the owner marks that Lua execution runnable. Resume never occurs on a
worker thread or directly inside a completion callback.

Asynchronous execution is not crash isolation and cannot forcibly stop arbitrary
blocking native code. Section 13 defines the actual termination guarantees.

## 4. Public Code Mode contract

### 4.1 Invocation and sequential calls

Register one model tool:

```text
builtin_code({ code: string })
```

The input is a Lua chunk, not a file, Markdown fence, or named function.

```lua
local result = tools.builtin_read({ path = "README.md", limit = 100 })
if result.status ~= "success" then
    return result
end

return {
    first_line = result.data.first_line,
    content = result.data.content,
}
```

A wrapper takes exactly one argument object, with zero arguments normalized to an
empty object. More than one argument is invalid. Its call submits a child and awaits
it before returning. The script looks sequential; the host does not block.

The chunk returns zero or one value. No return becomes JSON null. Multiple returned
values fail explicitly. Script globals live only until this invocation retires.
Effects already performed by tools survive script failure. There is no rollback.

Canonical names are flat Lua identifiers, so wrappers use ordinary field syntax:
`tools.fff_grep({...})` and `tools.github_create_issue({...})`. The underscore between
namespace and local name is part of the one canonical provider name, not a hierarchy
the runtime later parses. MCP bindings retain the exact remote name separately. A
remote name containing dots, hyphens, or other punctuation needs an explicit valid
local alias before it enters the registry. No lossy Lua-side normalization occurs.
A string such as `__proto__` remains an ordinary JSON object key at the value
boundary; JavaScript prototype filtering does not apply.

### 4.2 Explicit concurrency

Expose only the operations needed to compose independent tool calls:

```lua
local first = tasks.start("builtin_read", { path = "README.md" })
local second = tasks.start("builtin_read", { path = "AGENTS.md" })

local a = tasks.await(first)
local b = tasks.await(second)

return { readme = a, instructions = b }
```

`tasks.start` yields long enough for the owner to admit and record the child, then
returns an opaque execution-local handle without waiting for the tool result.
Admission or lookup refusals produce completed handles whose await returns the
ordinary failure envelope. Malformed Lua boundary values are script errors.

`tasks.await` yields only while a result is unavailable. `tasks.cancel` requests
cancellation and awaits retirement, returning the observed terminal result. A job
that already completed keeps its result. Awaiting a completed handle again returns
an equivalent value without another execution.

Handles belong to one Code Mode execution. They cannot be serialized, passed as tool
arguments, reconstructed from integers, or used by another execution. Scripts have
no access to raw job pointers or general coroutine scheduling.

Every started handle must be awaited or cancelled before successful return. Returning
with unconsumed handles produces `unfinished_tasks`, cancels remaining work, records
its outcomes, and waits for retirement before completing the parent. This rule also
applies to an already completed but unconsumed handle, so fast completion does not
make a broken script appear correct by chance.

Script errors, limits, and turn cancellation cancel all still-running children. The
parent is not released while a child can still reference it. This is structured
ownership, not a background job service.

### 4.3 Advertisement and visibility

Introduce an opt-in Code Mode setting. With it disabled, retain direct tools. With
it enabled, advertise `builtin_code`, `context_compact`, and `context_read_result`.
Expose ordinary native and enabled MCP tools in Lua. Keep `context_compact`
direct-only initially because it asks for a conversation boundary; allow
`context_read_result` through both paths.

Keep one executable registry. Advertisement and Lua availability are filtered views,
not duplicate registries. Enforce invocation eligibility at admission, not just in
the advertised schema. Reject Code Mode recursion even if a script guesses its name.
Do not invent per-server exclusions until a concrete incompatible tool needs one.

A rollout flag changes how the model invokes tools, not their authority. A model
with tools disabled gets neither Code Mode nor an indirect route to tools.

## 5. Discovery and instructions

Provide bounded `catalog.search({query, offset, limit})` and
`catalog.describe(name)` helpers inside Lua. They inspect the same frozen inventory
used by dispatch. Search is deterministic over exact names and descriptions; no
embedding service or generated filesystem catalog is needed.

Search returns names, short descriptions, exact callable expressions, and a paging
cursor. Describe returns the full description, input JSON Schema, invocation
eligibility, and the common result contract. Limit and paginate descriptor output
rather than silently omitting an argument constraint.

`Tool_Definition` currently has no output schema. Do not infer a return type from
prose or pretend every MCP tool returns an object of known shape. An output schema
can be retained later when a concrete consumer needs it. No Lua type generator or
JSON Schema-to-TypeScript machinery is needed.

The execution description explains Lua syntax, suspension, task handles, resource
limits, result envelopes, and the restricted libraries. Include small native
examples and discovery guidance instead of every MCP schema. Put any generated
inventory guidance after the existing frozen instruction snapshot, and record the
exact prepared instructions in the request. Do not mutate the skills snapshot.
A full bounded guidance section is enough initially; catalog deltas are unnecessary.

Skill loaders remain ordinary tools. A body loaded inside Lua is not automatically
visible to the model: the script must return it before the model can follow its
instructions. Do not encourage a script to load instructions and immediately run an
action that was authored without seeing them.

## 6. State machine model

Nabla is a state machine, not an agent loop. The existing `Chat_State` plus
`advance -> Effect` split already works this way; this section extends those rules
to work that cannot finish inside a single effect. Everything in this document
follows them, and an implementation that contradicts one of them is wrong even if
it passes a functional test.

### 6.1 Ownership and data

One owner thread holds every piece of mutable execution state. Worker threads own
only their execution input and output and never read or write session state. The
database is written by the owner alone.

Use ordinary Odin data:

| Data | Holds |
| --- | --- |
| `Tool_Job` | Identity and phase, immutable execution input, stop control, backend state, and result ownership |
| `Tool_Lane` | A named serialization lane: key, capacity, and how much of it is in use |
| `Lua_Run` | Coroutine reference and phase, awaited job, pending host request, budgets, and terminal cause |
| `Tool_Event` | An observed fact: call recorded, dispatch committed, backend reported, result committed, backend stopped, stop requested |
| `Tool_Effect` | A requested action: record call, record dispatch, start worker, run a Lua slice, record result, stop backend, release storage, wait for events |
| `Tool_Event_Source` | Session and turn identity, job identity, and a generation that makes a reused slot detectable |

Records live in a flat array with a free list; an identity is an index plus a
generation, so a stale event names something that is no longer the job it meant.
Use `distinct` types for identities and phases the way the session package already
does for `Seq` and `Turn_No`, so one cannot be passed where another is expected.
Phases are enums and every switch over one is exhaustive, so adding a phase produces
a compile error at each decision instead of a silent fall-through to a default.
Zero is initialization: an inactive record must be inert, and it must not be able to
emit an effect. A record enters an active phase only after its identity and its owned
input exist.

### 6.2 Events, effects, and advancement

An event is an observation. An effect is a command. Transitions are procedures over
those two, and they do no I/O: no Lua, no executor call, no database, no thread API,
and no direct clock read. Time enters as a deadline observation, so a transition test
can supply it instead of sleeping.

`advance` selects at most one bounded effect from the current state. The driver
performs that effect and feeds the observed outcome back as the next event. The
separation is what makes the expensive parts replaceable and the decisions testable
without threads, transport, or an interpreter.

Rules:

- **One bounded effect per advance.** A step never loops internally over jobs.
  Running to quiescence is the driver calling `advance` repeatedly, each time from
  the state the previous effect produced.
- **Readiness is ordered and fixed.** When several effects could be chosen, the order
  is part of the design, not an accident of iteration: terminal stop and storage
  failure first, then settling events (dispatch and result commits, backend reports),
  then result delivery to waiters, then new launches in submission order, then Lua
  slices for runnable executions, then a wait. Settling work is never starved behind
  new work.
- **A phase records a pending write.** A trigger that has a durable consequence moves
to a phase that cannot repeat it, so calling `advance` again cannot write twice or
start a backend twice.
- **Effects never retain pointers into growable storage.** They carry identities, and
the driver resolves them. Worker-visible context is stable, job-owned allocation, not
a stack frame.
- **Nothing durable depends on memory alone.** Where a later step must know what
happened, the journal records it. The in-memory table is a cache of work in flight.

A completion event carries owned data, and the driver transfers that ownership into
owner state rather than copying it. Per-step scratch comes from a reset arena, not
from fresh allocation in a loop; a busy turn must not grow the heap with each event.

Workers get an explicit logger binding or return facts for the owner to log. They
never rely on an inherited `context`, because a worker thread does not share the
owner's context, allocator, or temporary state.

Odin's `defer` runs at scope exit, and a suspended execution has no live scope to
exit. Anything that must survive a suspension is allocated and owned by its job and
released on a path the state machine drives. A `Tool_Context`, a result reader, or a
logging binding cannot be borrowed across a suspension boundary, because the frame
that held it is gone.

### 6.3 Terminal latch and answer completeness

Two invariants make suspension safe to reason about.

**Terminal latch.** Cancellation, an expired deadline, and a storage failure are
latched facts, not flags to recheck. Once one is latched, the machine admits nothing
new and emits only settling effects: stop backends, drain terminal events, commit
what is already committed, record refusals for what never ran, release storage.
A latched stop can never be cleared by a script, a backend, or a later event.

**Answer completeness.** Every committed call ends the turn with exactly one recorded
result. A model-visible call must be answered before the next request is built, and a
child must be settled before its parent may complete. A cancelled turn still settles
its calls, which is why its history stays well formed and a later request has no
dangling call. Recovery performs the same closure at session open for a turn that
never got the chance.

Settling is honest about what was observed. A call that never launched is
`Not_Executed`. One that was dispatched without a result is `Unknown`, because the
harness cannot say it did not take effect. `Cancelled` is recorded only when there is
evidence the work stopped. A completed effect is never rewritten because a stop
arrived afterward, and `Unknown` is never upgraded to a guess.

### 6.4 In-memory state over the durable record

The journal is authoritative. The job table is the work in flight; recovery closes
whatever the journal left open, and the next turn then proceeds from committed
history alone. This mirrors the existing recovery contract and extends it to a
running turn: the same closing logic runs whether the process died or a stop was
requested.

Consequences to accept deliberately:

- **No cursor and no continuation.** Nothing serializes a Lua stack, a coroutine, a
job table, or an await position. After a restart an interrupted script is not
resumed; it is recorded as stopped, with its children settled. Persisting a resumable
program would require a durable scheduler and a replayable effect model, and it would
let an effect run twice. Scripts are not durable, and that is the design.
- **A rebuilt machine reaches the same conclusion.** Because past decisions are
written down (the call entry, the dispatch entry with the exact admitted bytes, the
result entry), re-reading the journal is enough to decide what may run next. A
decision that exists only in a boolean in memory, and that a later step depends on,
is a bug waiting for a restart.
- **Resumption after an external pause is a new step, not a woken future.** If a
future feature suspends a turn on a person's answer, it re-enters the machine with the
answer already recorded, exactly as Goose does, rather than keeping a suspended call
stack to resume. Nothing in this design needs that yet, and building it now would add
a scheduler with no user.

### 6.5 What not to build

No futures or promises, no channel passed to a tool as its return value, no closure
that carries session state, no actor per tool, no per-tool event loop, no generic
state-machine framework, and no reusable scheduler library. The driver's event pump
is an I/O adapter that performs effects and collects facts; it holds no policy about
turns, readiness, barriers, or stopping. Policy lives in the state and in the
transitions, where it can be read in one place and tested without a thread.

### 6.6 Relationship to the reference harnesses

Goose derives its next step from the persisted conversation and applies an effect
list; DeepSeek keeps an explicit phase and advances from inbox events. Nabla keeps
small explicit phases over a durable journal, which is a defensible middle: the
phases make control flow readable in Odin, and the journal keeps the durability rules
the harness already relies on. What is borrowed is the discipline, not the machinery:
ordered readiness with first-applicable-wins, answers kept complete under
cancellation, and all state changes going through a separate effect application step.

## 7. Owner-driven tool jobs

### 7.1 Data and execution placement

Keep the tool definition as data plus an executor. Replace the assumption that every
executor runs synchronously on the owner with a small tagged execution choice:

| Placement | Use | Contract |
| --- | --- | --- |
| Worker | Existing blocking file, shell, skill, and MCP procedures | Run against owned job context; publish a result; never access the session store |
| Owner | Short session-control operations such as result lookup and compaction intent | Run on the owner; no long external work or blocking waits |
| Lua | Code Mode | Owner advances a private coroutine in bounded slices; host requests become child jobs |

Existing `Tool_Execute` procedures can remain the worker adapter's implementation
interface. They are no longer the orchestration interface for the entire system.
The registry validates the executor variant and its required data. Use a closed
set of variants rather than a general start/poll/cancel/destroy plugin vtable.
If a future native nonblocking backend needs another variant, add it with that use.

The owner-side runtime needs a bounded table of stable job records and a lane rule.
The table holds the records; a lane is a backend identity, and what a lane serializes is
derived from which jobs are running in it, so there is no second structure to keep in
sync (section 14.2). Each job carries:

- Unique runtime identity, session/turn identity, and registry generation.
- Durable call sequence, optional parent call sequence, and submission ordinal.
- Admitted argument bytes and execution context with an explicit lifetime.
- Definition/backend reference held until retirement.
- Execution state, parent cancellation link, local cancellation, and deadline.
- Placement-specific state: worker handle, immediate owner operation, or Lua run.
- A result awaiting commit or a committed result reference.

Illustrative lifecycle after the call record exists:

```text
Queued -> Dispatching -> Running -> Result_Ready -> Committing -> Retiring -> Retired
   |           |           |
   +-----------+-----------+-> stop/refusal -> Result_Ready
```

`Dispatching` means a durable dispatch write is outstanding, not that a backend has
started. `Committing` means a result write is outstanding. `Retiring` means a result
has committed but execution resources or consumers may still need release. A refused
call can reach `Result_Ready` without a dispatch. Failure of either durable write
enters session failure and drains resources without claiming a successful commit.

Cancellation is a latched request, not proof of retirement. Only the owner changes
job state and writes history. Worker completion is a message with owned data, not a
mutation of `Chat_Session`.

### 7.2 Job phases

A job's phase says what is durable, what is executing, and what has been released.
The table is the complete transition set for the first implementation; a new phase or
event means a new row and an explicit decision about its cancellation and retirement
behavior. An owner-side operation that finishes immediately still reports a result
event and goes through the same commit transition as a worker.

Job transitions:

| State and event | Guard and next state | Effect or scheduling consequence |
| --- | --- | --- |
| Call recorded and arguments admitted | Create `Queued` job | Consider a lane slot |
| `Queued`, slot available | No stop, transition to `Dispatching` | Record dispatch with admitted bytes |
| `Dispatching`, dispatch committed | No stop, transition to `Running` | Start the selected executor once |
| `Queued` or `Dispatching`, stop before launch | No external execution, then `Result_Ready` once outstanding writes settle | Produce `Not_Executed` |
| `Running`, backend completed | Matching identity, transfer result to `Result_Ready` | Finalize on owner, then schedule result write |
| `Result_Ready`, advance | Transition to `Committing` | Record finalized result |
| `Committing`, result committed | Transition to `Retiring` | Make result eligible for await; retain resources still in use |
| `Retiring`, backend stopped and execution borrows released | Transition to `Retired` | Free execution storage; keep only bounded result identity |
| Any live state, cancellation requested | Latch cause; stop admission for its descendants | Request stop once for running backends |
| Any live state, storage failed | Session failure latched | Cancel/drain; never deliver uncommitted results |

A backend may retire before its result commits; retain that fact in its backend
state and join the two conditions at release. Do not confuse completed computation,
committed output, and released resources. Cancellation races are resolved from
observed facts, not whichever callback happened to mutate a flag first.

Retirement releases executable state, not the right to read a committed result. A
bounded task record keeps its call sequence and settled outcome until the Lua run
ends, and repeated await reads the journal through an owner effect. It must not keep
a worker, its argument buffers, or its registry generation alive. A parent that waits
for child retirement must not hold a child execution reference that itself prevents
that retirement; the parent observes child state through identities the owner
resolves.

### 7.3 Lua run phases

A Lua run has its own small phase enum:

| Lua phase | Event or observation | Next phase |
| --- | --- | --- |
| `Ready` | Driver runs a bounded slice; hook yields its quantum | `Ready`, queued behind pending control/completion work |
| `Ready` | Coroutine yields a host request | `Host_Request` |
| `Host_Request` | Call-and-await submitted, or await/cancel names a job whose wait condition is unmet | `Waiting_Job` |
| `Host_Request` | Start handle, catalog result, print acknowledgement, or an already satisfied wait condition | `Ready` |
| `Waiting_Job` | The named job reaches the condition being waited on: result committed for await, retirement for cancel | `Ready` |
| `Ready` | Chunk returns or fails | `Draining` |
| Any live phase | Terminal stop requested | `Draining`, never resume user code |
| `Draining` | Children retired and output constructed | `Done` |

Only an emitted Lua-slice effect calls `lua_resume`. Its return becomes an event;
it does not recursively call advance, execute a tool, or invoke the chat driver.
`Waiting_Job` owns an identity, a wait condition, and suspended Lua state, not an Odin
stack frame waiting on a callback. `Draining` is required even on successful return,
because result availability can precede backend retirement.

The driver may run a short event pump to perform effects and collect external
facts. That pump is an I/O adapter, not a second agent policy loop: turn decisions,
runnable work, barriers, and stop behavior are represented in explicit state.

### 7.4 Submission and completion

For a child request:

1. Validate origin, name, boundary data, size, call budget, and eligibility.
2. Allocate an identity and append its call entry before admitting executable work.
3. Prepare arguments using the shared structural admission rules.
4. Queue the job under global and backend-specific concurrency bounds.
5. When a slot is available, append the dispatch entry with the exact admitted
   bytes, then recheck stop control before launching work.
6. Execute the existing native procedure or MCP adapter once.
7. Accept the terminal event, finalize the result, and append it to the journal.
8. Make the result available to Lua or the top-level response barrier.
9. Release execution storage once the backend stops and execution borrows end;
   a result handle keeps identity, not executable state.

Top-level model calls enter the same lifecycle after their response and call entries
have committed. Do not introduce a second Lua-only dispatcher or recursively call
`chat_run_tools`. Split its current responsibilities into submission, start,
completion, and result-projection procedures.

A dispatch write failure prevents launch. A result write failure latches session
failure, stops all new admissions, cancels active jobs, and never resumes Lua with
that uncommitted result. Continue retirement even when storage is unavailable.
Recovery later records uncertainty; logs must not pretend the missing result was
committed.

### 7.5 Scheduling and backend lanes

Use a small bounded set of worker threads, initially at most four active worker
jobs. A thread per active job is sufficient for the first implementation; there is
no need for a reusable worker pool yet. Queued jobs are also bounded. Waiting on a
backend lane must not consume a worker slot.

A Code Mode parent never occupies a worker slot while waiting for children. Otherwise
several parents could exhaust the slots and prevent their own children from starting.
Runnable Lua executions receive bounded instruction slices, interleaved with control
and completion events. The owner sleeps on a wakeup or nearest deadline when no work
is runnable, rather than spinning or repeatedly asking the model what to do.

Keep direct calls in model response order for the initial rollout. Concurrency is
explicit through `tasks.start`, not inferred from behavior hints. The script author
is responsible for choosing independent work. Read-only hints are not a proof of
thread safety, and a tool described as a read can still touch a shared backend.

Concurrency is bounded by lanes. A lane is a named serialization domain with a
capacity, and a job runs in the lane its definition names. Initially: all native
tools share one lane, each MCP client is its own lane, and the Lua runner is in no
lane at all because it runs on the owner in slices. Native tools therefore run one at
a time, calls to different servers can overlap, and calls to the same server queue
outside the client. Raising a lane's capacity, or giving a tool a lane of its own, is
a per-executor decision that follows an audit rather than a global switch.

Do not add concurrent reads of a client's stdio stream, and never hold a blocking
call under a mutex on the owner; queue in the lane instead. Discovery, shutdown, and
refresh follow the same lane ownership and cannot race an active call. A job whose
lane is busy occupies no worker and is not a reason to block the owner: it stays
`Queued` until the lane frees.

Audit each native executor before its lane becomes more than capacity one. Shared
mutable process state must either become job-local or keep the lane it has. Never use
process-wide `chdir`. Existing shell fork/exec rules, process groups, and
allocation-free child paths remain relevant when launch occurs on a worker.

Completion events carry execution identity, not just a provider operation ID. Reject
stale or duplicate transitions, but still reclaim their message storage and retire
any tracked backend. A stale event is not permission to leak a job. Reserve room
for one terminal result per admitted job; progress may be coalesced, terminal events
may not be dropped. Shutdown keeps draining until producers have retired.

## 8. Chat state machine integration

Extend the effects produced by `chat_session_advance` and the event-feeding
procedures instead of installing a new agent loop. Replace the blocking `.Run_Tools`
implementation with bounded effects that submit work, advance runnable executions,
and await external events. Exact effect names are an implementation choice; the
Separation between state transition and effect execution is not.

A chat phase answers one question: what kind of work is next for this turn. Job and
Lua phases answer a different one: whether a specific piece of work can make progress.
Keeping the two levels separate is what stops this design from growing a second
scheduler, and section 6 gives both levels the same rules.

```text
Preparing -> Requesting -> Streaming
                              |
                   response and calls committed
                              v
                      Executing_Tools
                              |
              tool events and bounded tool effects
               [runnable jobs or suspended jobs]
                              |
                all top-level results committed,
                all owned child work retired
                              v
                          Preparing
```

Keep `Executing_Tools` as the chat phase for both runnable and suspended tool work.
Waiting is already explicit in tool-job and Lua phases; duplicating it in a chat
`Waiting_Tools` member would require keeping two descriptions of the same fact in
sync. When no execution is runnable, advance produces an await-events effect. That
effect lets the owner sleep until a completion, control message, or nearest deadline.
This is a design choice to avoid redundant state, not a compatibility restriction.

Representative chat transitions:

| Chat state and input | Condition | Result |
| --- | --- | --- |
| `Streaming`, completed tool response | Response and call intent committed | `Executing_Tools`, submit top-level jobs |
| `Executing_Tools`, runnable tool state | No terminal stop | Emit one bounded tool effect; remain in state |
| `Executing_Tools`, no runnable tool state | Outstanding jobs or writes | Await events; remain in state |
| `Executing_Tools`, tool result committed | Barrier still incomplete | Make eligible Lua continuation runnable; remain in state |
| `Executing_Tools`, barrier satisfied | All top-level results committed and owned work retired | `Preparing` |
| Any active phase, turn cancellation | Matching turn | `Cancelling`, stop admission and request child stops |
| `Cancelling`, retirement barrier satisfied | Every owned producer stopped and results settled as far as storage permits | `Finalizing` |
| Any active phase, durable write failure | Storage failure latched | Enter failure/drain path; no next model request |

A completion wakes the driver, which feeds an event and performs only the effect the
state machine selects. The backend does not call `chat_session_advance` or resume
Lua itself. `Preparing` rebuilds the next request from committed conversation.
Top-level result accounting remains separate from nested job accounting. Do not
advance from a result count alone while a producer can still reference turn storage.

The driver keeps its present shape: wait for the next event, advance once, perform
one effect. It becomes an event pump rather than a call stack in one respect only:
an effect may leave work pending and return before the turn is finished. The turn
ends when the phase reaches a terminal state, not when a function returns. A chat
phase is set by a transition, never inferred from job state at the call site, so the
same entry point serves a fresh turn, a completion wakeup, and a stop request.

`Cancelling` stops admission, requests cancellation throughout the child tree, drains
terminal events, and retires resources. Finalization waits for all owned jobs, not
just the provider operation. Session switch, destruction, and registry replacement
obey the same lifetime boundary. The root worker must service completions and stop
requests while a turn is waiting; headless execution uses the same driver.

Ordinary steering still applies between model requests. Cancellation is immediate
control, not queued steering. A waiting tool is not a new boundary at which model
selection, instructions, or active registry definitions may change. No second user
turn or model request starts while the current response has unanswered calls.

Background compaction may finish while tools run, but installation remains at the
next safe request boundary. Code Mode neither waits for a summary nor exposes
compaction as a nested operation in the first version.

## 9. Durable calls, recovery, and provider projection

Extend the existing journal rather than introduce a separate Code Mode database.
Add an optional `parent_call_seq` relationship for call entries. Following the
existing schema's treatment of identity and correlation, make it a column with a
same-session foreign key. Require an earlier parent call in the same turn; enforce
that only call rows can carry the parent relationship. Dispatch and result rows
continue to reference their own call through `related_seq`.

A model call has no parent. A Lua child points to its Code Mode call. Internal child
IDs include the parent identity and a monotonically increasing ordinal, and cannot
collide with provider IDs. Child submission order and completion order are separate
facts. Do not rewrite completion order to make a concurrent execution look serial.

Reuse `Tool_Call_Entry`, `Tool_Dispatch_Entry`, and `Tool_Result_Entry`, with their
contracts expanded to include host-program calls. Dispatch is durable intent, not a
claim that execution definitely started. A crash after dispatch but before launch
is conservatively unknown, just as in the current design.

Provider projection includes only top-level model calls and their results. Child
calls and results are execution records, not fabricated assistant messages. Filter
both sides of the relationship, including when loading a context tail whose parent
lies before a checkpoint. Do not infer child visibility only from parents present
in that tail. Recovery still settles all calls, including hidden children.

Keep provider call/result grouping valid. If direct-call concurrency is later added,
assemble the model-visible batch in original call order after the barrier rather
than projecting arbitrary completion order. Preserve opaque provider replay items
and ensure they never acquire synthetic child tool calls.

Compaction sees the same model-visible projection. Its seam cannot divide a
Code Mode call/result pair; a child sequence is not an independent conversation
boundary. Nested results do not consume model-context budget individually. Their
storage is bounded by call count and per-result limits, not by hiding them behind
model-visible spill handles.

`context_read_result` may retrieve a finalized child result by call sequence. The
parent's compact call summary provides those sequences. Keep full native/MCP raw
payload policies unchanged; a stored finalized result does not recover bytes that
an adapter intentionally omitted or truncated.

On restart, undispatched calls become `Not_Executed`; dispatched calls without
results become `Unknown`. Recover the parent and children independently. Never
resume a Lua stack, replay a script, or retry effects automatically. Previously
completed child effects remain visible in the journal even if the parent is unknown.

## 10. Lua runtime and ownership

Use one fresh main state and a registry-rooted private coroutine per execution.
Run Lua only on the session owner. The embedded library is shared, states are not.
There is no global Lua lock and no VM reused from configuration loading.

The runtime holds source identity, hook and allocator accounting, terminal cause,
coroutine reference, bounded logs, task handles, and one pending host request.
It borrows the frozen registry generation through the job lifetime, not a pointer
into a replaceable dynamic array.

Tool wrappers yield a small host request. After `lua_resume` returns, the owner
copies and validates arguments, submits the child, and later resumes with the
recorded envelope. A host-request kind distinguishes call-and-await, start, await,
cancel, discovery, and logging. This is an in-process tagged value, not a wire
protocol or a reusable RPC framework.

Do not execute tools or write the database inside Lua C callbacks. Lua errors and
yields can transfer control without running Odin `defer`. Keep callbacks free of
Odin-owned resources requiring stack unwinding. Install callback context explicitly;
foreign callbacks must not assume they inherit the owner's allocator or logger.

All allocation-capable Lua entry paths need protection, including initialization,
compilation, helper installation, result conversion, and error formatting. A protected
user chunk alone does not make out-of-memory during result injection safe. Use the
installed binding's protected-call mechanisms and prove the trampoline paths before
building the integration around them. Do not rely on a Lua panic handler to recover
from unprotected errors.

Copy Lua strings by explicit length. Never keep pointers into Lua-owned strings
across mutation or collection. Worker jobs own arguments and context data through
retirement; a stack-allocated `Tool_Context`, `Result_Reader`, or logging binding
cannot be handed to asynchronous work. Keep result lookup and compaction control
on the owner, and remove their store/control pointers from worker contexts.

Worker allocation must be thread-safe even when a test supplies a tracking allocator.
Use job-owned allocation or the existing synchronized-allocator approach from
compaction. Transfer result ownership once, and release on the allocator that
created it. Worker scratch is local to the job, not the owner's temporary arena.
Keep the completion channel and registry generation alive until every producer exits.

## 11. Boundary values and tool results

Use one Lua/JSON conversion contract for arguments, results, discovery, and output:

| Value | Contract |
| --- | --- |
| Boolean | Preserve |
| String | Copy by explicit length; require valid UTF-8 at the JSON boundary; embedded NUL is escaped, never silently cut |
| Number | Finite, representable without silent rounding through both Lua and the actual JSON representation |
| Object | String-keyed table; empty plain table means object |
| Array | Dense one-based table; explicit `json.array({})` for an empty array |
| Null | Host-owned `json.null` sentinel, distinct from a missing Lua field |
| Function, thread, task handle, arbitrary userdata | Reject at the data boundary |
| Cycle, sparse array, mixed keys | Reject with a bounded path diagnostic |
| Script metatable | Reject; serialization must not invoke script code |

Provide bounded `json.encode`, `json.decode`, `json.array`, and `json.null` helpers.
Preserve array/object identity when converting received JSON, including empty
arrays. Copy shared acyclic tables as values; reject cycles. Bound expanded output
and traversal work so repeated references cannot cause exponential resource use.
Use raw table iteration and host-owned type markers inaccessible to script mutation.

Verify `core:encoding/json` numeric behavior before selecting a supported numeric
range. Lua's 64-bit integer does not guarantee that a JSON parser preserves it.
Reject unsupported numbers before rounding, including in incoming JSON, rather than
claim lossless conversion after precision was already lost.

Lua conversion produces JSON bytes that pass through existing structural argument
admission. Native tools keep their field validation, and MCP keeps its current
adapter/server validation. Schemas are documentation, not a new general validation
engine introduced as part of Code Mode.

Every child returns the same envelope as a direct tool:

```lua
{
    status = "success",
    message = "",
    data = { ... },
}
```

Return the whole envelope, not just `data`. A tool's failure remains a value the
script can inspect. Do not opportunistically parse text output as JSON.

For MCP, use `tool_mcp_execute` and its existing conversion. Structured output stays
under `data.structured_content`; `isError` maps to the existing outcome; non-text
content retains the current omission descriptions. Do not expose raw protocol
metadata or credentials and do not build a second MCP client in Lua. An ambiguous
MCP delivery stays `Unknown`; no scheduler retry is authorized by a lost reply.

## 12. Errors and output

Distinguish script failures, tool outcomes, execution control, and driver failures.

- Child tool failures return ordinary envelopes, including `Unknown` and refusals.
- Lua syntax/runtime errors and invalid boundary values become outer tool failures
  with a bounded diagnostic and source line when available.
- A valid chunk may handle a failed child and complete successfully. The child
  outcome remains independently recorded.
- Turn cancellation and execution timeout stop admission and resume no further
  user code. Their outer outcomes are `Cancelled` and `Timed_Out` respectively.
- A storage failure stops the turn and prevents continuation from uncommitted data.

Code Mode diagnostic kinds include `syntax_error`, `runtime_error`, `invalid_value`,
`memory_limit`, `instruction_limit`, `tool_call_limit`, `output_limit`, and
`unfinished_tasks`. They live inside the ordinary result envelope, not in a second
persisted outcome vocabulary. Outer `Invalid_Arguments` is reserved for refusal
before effects. A failure after child effects is not an argument refusal.

On completion, return the selected value, bounded printed logs, truncation facts,
and compact child-call summaries containing call sequence, name, and outcome.
Never append every child's output to the parent. Retain summaries of admitted calls
on failure, including calls settled during cancellation. If the selected value
cannot fit the envelope, report `output_limit`; do not silently turn it into a
truncated string. Logs can retain a prefix with an explicit truncation flag.

The parent result passes through ordinary finalization and aggregate context-budget
admission. Preserve outcome if finalization replaces a malformed envelope. The
runtime should construct a valid bounded envelope before that last-resort boundary.

Logs and observer events identify parent, child, turn, and execution. Report start,
queued, completion, and retirement facts without raw payloads by default. The root
package chooses presentation; `agent` emits data. Keep full argument/source capture
under the existing diagnostic capture policy, not an unconditional execution trace.

## 13. Bounds, cancellation, and security

### 13.1 Initial policy values

The Lua boundary implements the first four rows and the log bound as
`lua_limits_default` and its constants (`LUA_MEMORY_DEFAULT`,
`LUA_INSTRUCTIONS_DEFAULT`, `LUA_SLICE_DEFAULT`, `LUA_DURATION_DEFAULT`,
`LUA_MAX_LOG_BYTES`). The remaining rows arrive with the job, lane, and provider
steps; until then they are the values those steps must use:

| Resource | Initial bound |
| --- | --- |
| Source | 32 KiB and the existing 64 KiB JSON argument-document limit after escaping |
| Lua-managed memory | 32 MiB per execution |
| Lua instructions | 10 million per execution |
| Instruction slice | 10,000 instructions before returning control to the owner |
| Parent execution deadline | 120 seconds, starting at admission and including queued/child time |
| Child call attempts | 32 per execution, including refused attempts |
| Active worker calls | Four in the runtime, never more than four per execution |
| Lane capacity | All native tools share one lane; each MCP client is its own lane; one active call per lane |
| Retained print logs | 8 KiB inside the parent result budget |
| Final parent/child result | Existing 64 KiB envelope limit |
| Conversion depth | Existing argument-depth limit |

Also bound runnable Code Mode states, queued jobs, catalog pages, handle storage,
Odin-owned conversion bytes, and progress events. Start at one active top-level
Code Mode call per response under serial direct-call scheduling. A per-script call
limit does not bound a long model turn: add an explicit configurable total tool-job
admission limit per turn, initially 256, counting outer and child attempts. Exhaustion
stops new work and reports the limit rather than opening another request to evade it.
Reserve result capacity for already admitted calls when enforcing any limit.

Keep all limits in one harness policy with named defaults. Scripts cannot raise
them. Lua memory accounting does not bound Odin allocations, backend output, or
kernel resources; each owner retains its own limit.

### 13.2 Stop control and retirement

Give each job local cancellation and inherited parent/turn cancellation. The current
single interrupt pointer is insufficient for cancelling one child without cancelling
its siblings. Replace it with a concrete parent-linked control record, kept alive
until descendants retire. Check the chain without allocating.

Track stop cause explicitly. `tool_control_cancelled` currently merges an expired
inherited deadline into cancellation; do not preserve that ambiguity. Compute the
earliest parent/tool deadline and keep cancellation distinct from timeout. A
confirmed completed effect is not rewritten because cancellation arrived afterward.

Cancellation of queued work prevents launch and records `Not_Executed`, with the
reason explaining cancellation or queue expiry. Cancellation of running work requests
backend shutdown. Shell keeps group termination, escalation, and reaping. MCP keeps
its protocol cancellation and delivery-aware uncertainty; a local stop cannot prove
that a remote effect was rolled back. Record the child outcome supported by evidence,
while the parent independently reports its own cancellation or timeout.

At each Lua slice, host request, launch boundary, and completion, check terminal
control. Cancellation, deadline, instruction, and memory exhaustion must not be
neutralized by anything the script can call. The boundary answers this by not raising
at all: the count hook yields to the owner, terminal causes are latched outside Lua,
and a stopped run is never resumed. `pcall` and `xpcall` are absent from the
environment in that step, so a memory refusal cannot be swallowed by the script that
caused it either; if they are ever exposed, the stop path has to keep this property.

Yieldability through protected calls and native-library boundaries is an implementation
gate. Do not ship a hook error that a script can catch forever. Restrict non-yieldable
callback-taking library functions until the chosen hook path is proved safe. The
boundary checks `lua_isyieldable` before every yield and defers a stop to the next
firing that can yield, which leaves the instruction budget bounding Lua code rather
than time inside a C function (section 14.1). Keep the exposed library set small for
that reason, and bound the inputs to its expensive operations. If the embedded runtime
cannot meet the contract, revise execution placement or the exposed library set rather
than hide the limitation in a comment.

A deadline stops new execution; retirement can take longer while a backend cleans
up. A worker thread keeps the owner responsive but cannot safely be killed in an
arbitrary filesystem syscall. Do not free its storage or claim it retired. Report
stopping/stuck work and retain ownership. A strict bounded process-shutdown guarantee
for arbitrary native code requires process isolation, not another cancellation flag.

### 13.3 Restricted Lua, not an OS sandbox

Start from an allowlist rather than `L_openlibs`. Expose selected base, string,
table, math, and UTF-8 operations, bounded JSON helpers, catalog, tools, tasks, and
captured print. No `io`, `os`, `package`, `debug`, `require`, dynamic loading,
`loadfile`, `dofile`, bytecode loading/dumping, public coroutine control, arbitrary
metatable mutation, or user finalizers.

Audit individual native library operations. Instruction hooks do not bound work
inside C functions, including expensive pattern matching, formatting, or callback
loops. Bound inputs, expose bounded alternatives, or omit those operations. Protect
error formatting and cleanup from user code. Use text-only source loading.

Credentials stay in host clients, not Lua globals. The frozen inventory determines
which tool capabilities a script receives. Existing filesystem and shell tools
are not a workspace sandbox; shell can read inherited environment variables. Code
Mode does not make those tools less powerful or promise secret isolation from tools
that already have that authority.

In-process Lua is not memory-corruption isolation. A separate Linux child running
the same embedded Lua is the upgrade path if untrusted-code isolation or forcible
termination becomes a requirement. That would add IPC and supervision, not another
scripting language. It is not needed merely to make tool calls asynchronous.

## 14. Implementation sequence and review gates

1. Prove the Lua boundary independently. Test protected initialization and result
   injection, coroutine suspension, count-hook slices, protected calls, terminal
   limits, memory failure, and bounded native operations against the installed
   `vendor:lua/5.4`. No production registration yet.
2. Introduce owned tool jobs and asynchronous direct execution. Split submission
   from completion, add worker/owner placement, bounded terminal events, local stop
   control, and backend lanes. Adapt the root and headless drivers. Preserve direct
   tool semantics before adding Lua. Land the transition tests with this step, not
   after it: the phases, readiness order, terminal latch, and answer-completeness
   rules from sections 6 and 7 are what the later Lua work builds on.
3. Add nested journal relationships and projection filtering. Migrate storage,
   expand validation and recovery, preserve old sessions, and test partial history
   and compaction cuts. Reuse result lookup for children.
4. Add the Lua executor, conversion, and sequential call-and-await. Dispatch through
   the shared jobs. No callback service that synchronously runs the entire child
   lifecycle, and no worker slot held by a waiting Lua parent.
5. Add `tasks.start/await/cancel` and bounded concurrency. Verify resource lanes,
   sibling cancellation, completion ordering, handle validation, and draining after
   script failure. This completes the target runtime, not a detached-job system.
6. Add discovery, filtered advertisement, instruction guidance, config, observer
   events, and opt-in rollout. Interactive and headless entry points share behavior.
7. Evaluate representative models and workloads. Measure valid Lua generation,
   discovery overhead, round trips, context savings, latency, and cancellation.
   Enable by default only after correctness and model usability gates pass.

Keep harness-specific runtime code in `agent`, initially as focused files such as
`tool_job.odin`, `code_mode.odin`, `code_mode_lua.odin`, `code_mode_value.odin`,
and `code_mode_catalog.odin`. Keep durable relationships in `agent/session`. Root
owns process lifetime and presentation. `mcp` remains a protocol library; `ai`
remains a model client; foundation packages import neither this runtime nor its
policy. Do not create a new package solely to hold these files, and do not split the
state structs from the transitions that read them: a reader should see the phases, the
events, and the effects in one place. Keep each file under the repository's size
hint, splitting by subject (jobs, Lua runtime, values, catalog) rather than by layer.

Tests must cover observable guarantees:

- State transitions independently of I/O. Drive fake events with a supplied clock:
  duplicate `advance` calls cannot emit a second launch or a second write, readiness
  order is deterministic, a latched stop admits nothing new, and a stale identity
  cannot wake or mutate the execution it does not name. No sleeps and no threads in
  a transition test.
- Answer completeness. A cancelled or failed turn still ends with exactly one result
  per committed call, children included, and recovery reaches the same closure by
  re-reading the journal alone.
- Direct async completion resumes the agent without polling the model; owner control
  remains responsive while a tool is pending.
- Sequential dependencies and independent parallel calls both see committed results.
- Same-client MCP calls serialize; different lanes overlap without sharing stream reads.
- No parent/child worker-slot deadlock, lost terminal event, duplicate completion,
  stale-event mutation, or release before producer retirement.
- Cancellation before launch, during Lua, during shell/MCP work, and during cleanup;
  timeout remains distinct from turn cancellation and remote outcome uncertainty.
- Syntax failure, runtime failure after an effect, caught Lua errors, memory failure,
  infinite loops, output floods, and unfinished tasks.
- JSON nulls, empty arrays/objects, embedded NUL, UTF-8, numeric limits, cycles,
  sparse/mixed keys, metatables, task handles, and adversarial conversion work.
- Failure to write call intent, dispatch, or result; no effect before durable intent
  and no continuation from uncommitted output.
- Process death during a child, conservative recovery, no automatic replay, and child
  output accessible by call sequence.
- Provider projection for every supported API, opaque replay items, compaction,
  context-budget spill, and context tails whose parent lies outside the loaded range.
- State isolation, idle-only registry replacement, session switch, and shutdown.
- Lane behavior: a queued job on a busy lane holds no worker, claims its lane in
  submission order, and does not block the owner while it waits.

Run `mise run check`, focused `agent` and `agent/session` tests, and the full
`mise run test` gate during implementation. Add sanitizer coverage for FFI and worker
ownership where supported. Use process-level test harnesses for crash and forced-stop
cases rather than pretending they are ordinary in-process unit tests.

### 14.1 Phase 1 results

Step 1 landed as `agent/code_mode_lua.odin` with `agent/code_mode_lua_test.odin`. One
fresh restricted state per execution, a private coroutine for the chunk, a count hook
that yields to the owner, and tool wrappers that suspend on a request. No production
registration yet. The work settled several mechanics the proposal had left open.

**A stop is a suspension, not an error.** The reference manual restricts hook yields:
only count and line events may yield, and the hook must finish by calling `lua_yield`
with no results. In the other direction, an unguarded yield inside a C frame raises
`attempt to yield across a C-call boundary` into the script, where it is catchable.
A raised error is therefore the wrong stop mechanism, and the boundary does not use
one: the hook yields, the owner latches the cause in its own struct, and a stopped run
is never resumed. The coroutine dies with the state.

**Yieldability is per firing.** `lua_isyieldable` is checked before every yield. Inside
a C frame the stop stays latched and is taken at the next firing that can yield, so the
instruction budget bounds Lua code and not the time a library call spends inside C. The
run counts those firings (`non_yieldable`) so the property is observable rather than
assumed; `lua_stop_in_a_c_frame_defers` exercises it with a `table.sort` comparator.

**Failures are values.** A chunk that does not compile reports `compiled = false` with a
bounded message. A runtime error comes back as `lua_resume`'s status. A refused
allocation reaches the owner as `ERRMEM` and is reported as `Failed` with
`Lua_Failure.Memory`. Nothing is thrown into Odin, and no Lua error unwinds Odin frames.

**Lua 5.4's allocator contract.** `frealloc(ud, NULL, x, s)` creates a new block "no
matter `x`", so the third argument is not a size for a fresh allocation; a measurement
saw it non-zero 358 times while the standard libraries were opened. The boundary counts
a fresh block by its requested size and a reallocation or free by the recorded size,
which keeps the reported byte count exact: after `lua_close`, every tracked byte is
released and the tracking map is empty (`lua_destroy_returns_every_byte`). An allocator
that placed a header before each block aborted inside `luaopen_base`, so the boundary
passes the caller's allocator through and keeps its own count instead.

**Lua writes are ordered deliberately, because a mistake aborts the process.** The host
path uses unprotected C API calls, so nothing may guess: `luaL_ref` takes the registry
index, the key precedes the value for `lua_settable`, a closure's upvalue is pushed
before the closure, the table index is computed before the pushes rather than relative
to a changing top, and a registry reference is released before `lua_close` frees the
registry it lives in. Delivery raises the memory budget by `LUA_HOST_RESERVE` while the
owner pushes, so a script that spent its budget cannot make the harness abort during a
result. A wrong host-side index is still a crash and no panic handler is installed; the
mitigations are small functions and review, and later steps inherit that rule for every
new host operation.

**The environment is an allowlist.** Base minus `load`, `loadfile`, `dofile`,
`require`, `collectgarbage`, `warn`, `setmetatable`, `getmetatable`, `rawset`,
`pcall`, `xpcall`, and `print`; string minus `dump`; plus table, math, and utf8. The
metatable and raw-write functions are absent so host-side conversion can never run
script code, and `pcall`/`xpcall` are absent because a tool outcome is a value, which
leaves nothing to catch and keeps a memory refusal out of the script's reach. `print`
is the harness's and appends to the run's bounded log.

Measured here with the default limits: opening the restricted libraries and compiling a
small chunk costs about 15 KiB of Lua-managed memory, and a first run that builds a
thousand-element table peaks under 32 KiB. Both are far below the 32 MiB budget, which
is the point: the budget exists for scripts that compute, not for the interpreter.

### 14.2 Phase 2 results

Step 2 kept direct tool semantics and landed the job machinery under them:
`agent/tool_job.odin` with `agent/tool_job_test.odin`, a definition's `placement`, and
`chat_run_tools` reduced to the effect loop that drives the table. The phases are the
ones section 7.2 lists. The decisions are `tool_jobs_next` (a function of the phases
and the clock, with no I/O and no executor call) and the effects are separate
procedures, so the transition order is tested without running a tool. The suite covers
where a call runs, what a lane serializes, the worker bound, a stop that still answers
every call, an owner-placed operation among busy workers, and release of every thread
and byte.

Decisions the implementation settled beyond the proposal:

- **A lane is a backend identity, and occupancy is derived.** A job's lane is the
definition's borrowed backend pointer; nil is the lane every native tool shares. A
lane is busy while another job with the same key is dispatching or running, which
means the table itself answers the question and no lane bookkeeping can be left
stuck by a job that was released. A queued job is retried in submission order, so
the per-lane queue is the job order rather than a second structure.
- **Job-owned storage comes from the process heap.** A worker allocates its admitted
arguments, its context, and its result from the heap, and the owner releases them
with the same allocator. The session's allocator is deliberately not shared with a
worker, because it may be a wrapper the owner is writing through at the same time.
`tool_jobs_init` takes that allocator explicitly, which is also how a test holds the
batch to releasing every byte it took.
- **Results are recorded in submission order.** The earliest job that has not been
released is the only one that may commit, so the context budget is spent in the order
the response asked for results and a batch built later sends the same bytes in the
same order. A slow first call therefore delays a later ready one, which costs
nothing: the batch waits for every result before the next request either way.
- **A stop refuses and still answers.** The turn's cancellation reaches a running call
through the inherited parent token in `Tool_Control`, not only through a check
between calls. A queued call that the stop reached is refused as `Not_Executed` and
recorded like any other result, so a cancelled turn's answers stay complete. A
storage failure is the one case where a result is not recorded: those jobs are
released as `Unrecorded`, and recovery is what records uncertainty for them.
- **A worker never runs the process handler.** The watched signals are blocked across
thread creation, the way compaction does it, so a tool thread is ineligible for the
handler that cancels its own turn.

The final slice of step 2 moved the table from the driver's frame onto `Chat_Session`.
`chat_session_advance` now selects `Run_Tools` (admission), one `Step_Tools` effect,
`Wait_Tools`, or `Finish_Tools`; the driver performs that effect and asks again. Two
advances before effect application select the same action and launch or write nothing.
The `.Cancelling` state uses the same selector until every committed call is answered
and every producer retires. `chat_run_tools` remains only as a synchronous package
adapter for focused tests and callers without an event pump.

This is enough for a Lua execution to suspend without keeping a driver frame alive:
the pending jobs and their wait state are now session data. Completion currently wakes
through a condition variable plus the 50 ms bounded wait slice. A root-level wakeup
channel can remove that latency when the outer worker becomes a general event pump; it
is an optimization, not a prerequisite for child calls.

### 14.3 Phase 3 results

Schema version 5 adds `parent_call_seq` to `entries`. Only a `tool_call` may carry it,
the parent must be an earlier tool call in the same session and turn, and ordinary
`related_seq` relationships continue to connect each child dispatch and result to the
child call. The migration copies every older row with a null parent, so existing
sessions preserve their provider-visible history.

`context_load` now filters both sides of the relationship. It omits a child call by its
own parent column and omits a child dispatch or result by looking through
`related_seq` to that call. The full history loader, recovery queries, and
`tool_result_read` do not filter, so children remain durable execution records and an
interrupted session settles them independently. Tests cover same-turn validation,
full-history retention, and a provider context containing only the Code Mode parent
call, dispatch, and result.

### 14.4 Phase 4 results

The first executor slice implements the value boundary in `agent/code_mode_value.odin`.
A pending Lua wrapper argument is copied into the existing `json.Value` model and then
encoded with `core:encoding/json`; a completed tool's JSON envelope is parsed through
the same model and pushed as the wrapper's single Lua return value. No parallel tool
argument or result representation was introduced.

The conversion accepts the host-owned `json.null` sentinel, booleans, strings, Lua
integers, finite JSON numbers, string-keyed objects, and dense one-based arrays. An
empty table is an object. It
rejects unsupported Lua types, cycles, mixed tables, sparse arrays, excessive depth,
and more than 16,384 traversed values. Lua strings retain their explicit length, and
JSON encoding remains the boundary that validates whether the copied value can be
represented. Result construction runs inside the Lua boundary's reserved host memory.
JSON null is delivered as the same `json.null` identity rather than Lua nil, so null
object fields and array elements remain present.
Focused tests cover nested arguments, complete result-envelope delivery, and cycle
rejection.

`builtin_code` now uses a `Lua` placement in the same session-owned job table as every
other call. Its first dispatch creates a bounded Lua run and installs wrappers for the
session registry except `builtin_code` itself. A wrapper request records a child
`tool_call` with `parent_call_seq`, admits a normal child job, and moves the parent to
`Waiting`. The waiting parent occupies no worker slot and is skipped only in favor of
its own child, so unrelated top-level results cannot pass it. Once the child result is
durable, the complete envelope is retained, pushed into Lua, and execution resumes.
This repeats for sequential calls until the script returns, fails, reaches a policy
limit, or is cancelled.

Nested results remain outside the provider context budget and do not increment the
turn's top-level result barrier. They still pass through normal admission, dispatch,
execution, result finalization, durable recording, observer reporting, and retirement.
The parent result contains its string return value and bounded `print` log. The
integration test executes two sequential child calls, verifies both parent relations,
and verifies that three durable results satisfy one provider-call barrier.

## 15. Decisions deliberately left open

The runtime direction is settled by this proposal; these choices need implementation
evidence, not another architecture framework:

- The precise JSON numeric range supported by the installed parser without loss.
- Final default limits after measured workloads, including the turn-wide job budget.
- The library set once scripts are written against it: the allowlist is settled as a
  policy (section 14.1), and adding a library reopens the non-yieldable-callback
  question for it.
- Whether later deployments require a subprocess security boundary or hard stop for
  filesystem work. Threads do not satisfy that requirement.
- A future model-facing detached-job contract, persistent values, or concurrent model
  requests. None is implied by the asynchronous tool lifecycle described here. Adding
  one means first deciding what may open a turn on its own, with what wake budget, and
  how its result is read later; the job state machine and the journal are the parts it
  would reuse.

Do not make persistent state, a general scheduler framework, or a durable
continuation format a prerequisite for Code Mode. Equally, do not preserve blocking
execution merely because it is what Nabla currently implements. The target is one
explicit state machine for tool work that the agent, Lua, and any later backend share,
with the journal as the record and the in-flight job table as a cache of it.
