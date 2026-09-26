# Nabla technical architecture

Status: target architecture. This is the implementation contract for the finished harness: its structure, responsibilities, data and execution flow, and constraints. Where current code disagrees, this document wins, and section 29 lists the current mechanisms it replaces. Each rule has one home here: change it where it is written.

Terms: "must" is a hard rule, "default" is a named, tunable value. Every numeric default is collected in section 27. Section 2 decides which limits may exist at all.

## 1. Invariants

1. One owner thread mutates a live session and commits its durable state. Everything else produces observations.
2. Durable intent is committed before any external effect whose occurrence matters after a crash: provider send, tool start, Lua child start, Task start, subagent start.
3. No consumer (model request, Lua parent, frontend terminal report, next turn) reads a result before it is committed.
4. An effect that may have executed is never replayed automatically. Unknown is a recorded outcome, not a reason to retry.
5. Cancellation is intent, completion is an observation, commit is durability, retirement is proof that borrows ended. None substitutes for another.
6. The journal is the only execution record. Runtime tables hold in-flight work. Provider requests, frontend transcripts, and diagnostics are projections.
7. Session history is an append-only tree. Nothing deletes, copies, or rewrites a committed node.
8. Validation, repair, policy, hooks, bounds, and journaling apply identically to direct calls, Lua children, Tasks, MCP tools, and subagents. No path is privileged.
9. Repair changes representation only, is unambiguous, and is journaled. It never supplies semantic intent.
10. Every live work item has an owner, a release point, and a cancellation path. Its limits are the external ones in section 2.1; the harness adds none.
11. Idle means zero periodic wakeups in every thread the process owns.
12. A failure the model can act on is fed back to the model and the turn continues (section 2.2). Only the user, or a model that cannot be reached, ends a turn.
13. Native data stays typed. JSON exists only at provider, MCP, ACP, journal payload, and export boundaries.
14. The resolved model catalog is the only runtime source of model facts.
15. Configuration is live. Admitted work keeps the immutable snapshot it was admitted with; new work uses the newest valid snapshot.
16. Only a main session creates subagents. Delegation depth is one.
17. The zero value of every runtime struct is inert: no owned resources, no pending work, unknown rather than false where the difference matters.

## 2. Limits, failures, and resources

The harness gets out of the model's way. It adds no limit of its own, and it turns every failure the model can act on into feedback instead of a stop.

### 2.1 Limits come from outside

A limit exists only when an external constraint imposes it: the provider or its API (request size, rate, error responses), the model (context window, maximum output), a protocol (a frame format, a JSON-RPC rule), or the operating system (memory, file descriptors, process limits). Nabla and its packages never invent a cap on tool arguments, tool output, calls per response, requests per turn, retries, script size, instruction counts, or execution time. `http`, `sse`, `ai`, `mcp`, and `acp` report what the peer sent in full; they do not refuse data for being large.

- A limit is data from its source: a catalog fact (`context_window`, `max_output`), a provider refusal classified by `ai`, or an OS error. A constant in source that caps model-driven work is a defect.
- The context window is the one limit the harness applies before sending, because it is the model's own. Large content is kept whole and projected within it through previews and handles (section 14.3); the bytes are never discarded.
- A timeout is a default the model may override with any value, never a maximum. A model-supplied timeout is honored as given.
- Internal buffers (view queue, diagnostic ring, journal batch) size memory, not work. When one fills, the producer degrades its own output (drops a redraw delta and resyncs, drops a diagnostic line and counts it) and never refuses or truncates model-visible data.
- Hooks, config, and material metadata run user code on the owner or the watcher. Their wall-time bound (section 17) keeps those threads responsive; it is a system constraint on the harness's own threads, not a limit on the model.

### 2.2 Failures are feedback

When a request, a response, or a tool fails, the next step is to tell the model what happened and let it correct itself. The work loop never stops because something went wrong while the model can still be reached.

| Failure | What the model receives | Turn |
| --- | --- | --- |
| tool failure, invalid arguments, denial, timeout, unknown outcome | the typed result for that call (section 14.3) | continues |
| response that cannot be decoded, is incomplete, is truncated at the output limit, or has defective calls | a `Notice` node saying what was wrong and that nothing ran | continues |
| provider refusal caused by the request content (too large, invalid) | a `Notice` node naming the provider's limit and message, after a checkpoint when the context is the cause | continues |
| transient provider or network failure | nothing; the request is resent with backoff while the model send is provably not entered, otherwise a `Notice` | continues |
| authentication, quota, missing model, configuration error | nothing: the model cannot be reached | ends, reported to the user with the provider's message |
| user cancel, storage failure | nothing | ends |

- Feedback is actionable: it names the failing call or response, the cause, the external limit with its value when one applies, and what was not executed.
- A notice is committed as a node, so resume, forks, and the cache see the same bytes.
- A failure recorded in the journal is always also visible where it matters: to the model when it can act, to the user when only the user can.

### 2.3 Resources

- Blocking waits only. Every waiting thread sleeps in a futex, `read`, `poll`/`ppoll`, `waitid`, or `thread.join` with either no timeout or a timeout equal to a real deadline. No sleep loops, no poll intervals, no heartbeat timers.
- Resident memory is the working set. Durable history lives in the journal and is loaded by bounded ranges. The resident conversation is the active projection only (section 11), which is bounded by the model window.
- Large transient data (request preparation, models.dev parsing, compaction snapshots, job output) lives in a `virtual.Arena` owned by that lifetime and is released with `virtual.arena_destroy`, which returns pages to the OS. Small long-lived data uses the heap allocator.
- Concurrency exists where work is independent and blocking or CPU-bound. Blocking jobs get a thread each, created on admission and joined on completion, bounded by `BLOCKING_JOBS_MAX_RUNNING`. A CPU-bound native operation that splits into independent pieces creates a `thread.Pool` sized `min(os.get_processor_core_count(), pieces)` for that operation and destroys it before returning. No process-lifetime worker pool.
- An optimization stays only with a measured end-to-end gain (section 26). Complexity without one is deleted.

## 3. Odin implementation rules

### 3.1 Data

- Concrete structs, enums, `bit_set`, enumerated arrays (`[Enum]T`), tagged unions, `Maybe(T)`, `distinct` integer IDs, slices, and small fixed arrays. Closed control domains use a union or enum with an exhaustive `switch`; `#partial switch` only where the ignored cases are listed in a comment.
- Stable wire names use enumerated-array tables (`[Record_Kind]string`), never enum formatting.
- No `any`, `rawptr`, property maps, or string-typed fields where the shape is known. `rawptr` is confined to FFI (Lua, SQLite) and to procedure-pointer executor boundaries.
- No service locators, interfaces for single implementations, generic reducers, event buses, plugin lifecycles, or allocator wrappers per component. Procedure pointers exist only at real substitution boundaries: provider API family in `ai`, MCP backend, journal writer sink for tests, frontend output writer.
- Fixed-size temporary data uses fixed arrays (`[2]db.Value`), not dynamic arrays in scratch.

### 3.2 Errors

- Errors are trailing return values. Each package defines `Error`: an enum of local causes, or `union #shared_nil { Local_Error, os.Error, mem.Allocator_Error, ... }` when it composes lower errors. Propagate with `or_return`; default with `or_else`.
- Constructors and state-changing procedures are `@(require_results)`.
- A harness failure recorded in the journal is `Failure :: struct { stage: Stage, kind: Failure_Kind, detail: string }` with the full `detail` the source reported. `Stage` names where it happened (Prepare, Encode, Admit, Send, Stream, Validate, Commit, Dispatch, Execute, Persist, Hook, Recover).
- `assert` checks internal invariants in debug; `ensure` checks invariants whose violation would corrupt durable state. Neither handles input, transport, tool, or storage errors. No `panic` on external input.
- Allocation failure is an explicit error. An operation that builds an owned value uses a local, a `defer if !transferred { destroy(&v) }`, and sets `transferred` only after the owner accepts it. Empty success, zero-length success, and allocation failure are distinct.

### 3.3 Allocators and lifetimes

- Allocating procedures take a trailing `allocator := context.allocator`, or a required allocator when the result outlives the call. A procedure that returns an owning slice documents the allocator in the owner that frees it; callers free with `delete(s, allocator)`.
- Arenas are initialized in place at their final address before any allocator handle to them is created. An arena is never copied or moved after `arena_init_*`.
- `context.temp_allocator` is released only by its owner: the owner loop iteration (section 6.2) and worker entry procedures. Helpers use `runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()` with `ignore = allocator == context.temp_allocator` when returning into a caller-provided allocator. No bare `free_all(context.temp_allocator)` outside an owner.
- File buffers transfer ownership (`string(bytes)`) instead of cloning.
- Allocator resize uses `mem.resize` / `mem.resize_non_zeroed`, never allocate-copy-free.

| Lifetime | Allocator | Released |
| --- | --- | --- |
| Process (root state, journal connection, watcher) | heap | exit |
| Config and catalog snapshot | own `virtual.Arena` | last user releases (section 13) |
| Session (state, registry, projection) | heap, session allocator | session close |
| Turn (batch tables, turn scratch) | turn `virtual.Arena` | turn finish, after all turn jobs retired |
| Request chain (projection copy, encoded body) | chain `virtual.Arena` | after the last attempt job retired |
| Job (input copy, output, stream bytes) | job `virtual.Arena` | job retire |
| Lua execution | Lua allocator over heap with quota | execution end, after children retired |
| Owner loop iteration | `context.temp_allocator` | iteration end |
| Worker scratch | worker thread temp allocator | thread exit |

### 3.4 Context

- `context` carries only `allocator`, `temp_allocator`, `logger`, and the random generator. Session state, cancellation, authority, and snapshots are explicit parameters. `context.user_ptr` is unused.
- Threads and C callbacks do not inherit the creator's context. Every thread entry and every Lua/SQLite callback sets `allocator` and `logger` explicitly. Never copy the owner's whole context into a worker.
- `context.logger` is the journal diagnostic logger (section 8.5). `core:log` calls anywhere become bounded `runtime.message` records.

### 3.5 Threads and synchronization

- `core:thread` for threads. The owner creates worker threads with `context.allocator` set to the owner's heap allocator, so the owner is the only thread that ever frees a `^thread.Thread`. No `self_cleanup` threads.
- `core:sync`: `Futex` for the owner wake, `Mutex` with `sync.mutex_guard` for plain critical sections, atomics for single-word flags and counters. Manual lock/unlock only where a procedure hands off ownership mid-scope.
- A condition broadcast is not a retained notification. Every wait uses a sequence or predicate that closes the check-to-sleep window (section 6.3).
- Signal handlers only perform atomic stores/adds and `sync.futex_broadcast` (both async-signal-safe). No locks, no allocation, no I/O.
- Operating-system access goes through Odin's portable packages first: `core:os` for files, processes, and environment, `core:sync`, `core:thread`, `core:time`, `core:net`, `core:nbio`, and `core:sys/posix` where POSIX covers the need. Linux is the only platform built today, and macOS and the BSDs are expected; a facility with no portable interface (`inotify`, `eventfd`, `pidfd_open`, `prctl`, `/proc`) is reached through a package-local procedure implemented in a `_linux.odin` file, so a new platform adds a file and changes no caller. No branches for platforms that are not built.
- The post-fork child path is allocation-free and lock-free (raw syscalls only).

### 3.6 Serialization

- `core:encoding/json` at external boundaries only. Native tool arguments and outputs are typed structs; Lua values convert directly to and from those structs.
- Canonical JSON (sorted keys, no insignificant whitespace) for everything that enters a provider request prefix: tool schemas and harness-generated JSON. Encoded once, stored as bytes, reused verbatim.
- Journal payloads are one level of JSON (a JSON object column, never JSON inside a JSON string). Exact external bytes (tool arguments as sent, provider replay items, rendered tool results, text) go in a `body` BLOB column.
- `core:crypto/hash` (SHA-256) for digests.

### 3.7 Source

- One subject per file, roughly 2000 lines maximum. Names carry meaning; comments state ownership, lifetime, thread, and failure contracts only.

## 4. Package map

```text
foundation   text  input  term  layout  tui  tui/widgets
libraries    dns  tls  http  http/client  sse  websocket  ai  mcp  acp  db  db/sqlite
harness      agent  agent/journal  agent/material  root package (nabla executable)
```

| Package | Owns | Must not contain |
| --- | --- | --- |
| foundation | text, input, terminal, layout, immediate-mode UI | anything about models, sessions, HTTP |
| `dns` `tls` `http` `http/client` `sse` `websocket` | protocols, transfer phases, byte and delivery facts | retries of model work, provider knowledge, harness logging policy |
| `ai` | provider API families, encoding with caller-owned encode cache, stream decoding, failure classification, delivery evidence, one-send operations, Responses WebSocket connection | turn control, retry authorization, catalog policy, storage |
| `mcp` | MCP client protocol over stdio, delivery state | tool policy, naming policy |
| `acp` | ACP framing, JSON-RPC, payload shapes for both agent and client roles, writer | sessions, turns, Nabla concepts |
| `db` `db/sqlite` | engine-neutral SQL facility and the SQLite binding | harness record semantics |
| `agent/journal` | journal schema, record and node types, append/commit, claims, recovery queries, bounded reads, migrations | execution types from `agent`, model execution, filesystem discovery |
| `agent/material` | `.agents/` and user material formats: skills, rules, commands, Task metadata, frontmatter subset, bounded discovery, verified loads | sessions, models, permissions |
| `agent` | owner loop, state machine, jobs, tools, repair, policy, hooks, Lua runtime, Tasks, subagents, projection, compaction, catalog resolution, config parsing and validation | terminal, rendering, process-global UI state, file watching |
| root | process lifetime, signals, config discovery and file watching, catalog refresh thread, TUI, headless, ACP server, diagnostics and export commands | a second copy of any `agent` policy |

Rules: dependencies point inward; only root imports both foundation and `agent`; `agent/journal` imports only `db`, `db/sqlite`, and `core:`; `agent/material` imports only `core:`. `agent/material` replaces `agent/skills`; `agent/journal` replaces `agent/session`. No further packages without a second consumer.

## 5. Identities and vocabulary

```odin
Run_Id       :: distinct [16]u8  // one process run
Session_Id   :: distinct [16]u8
Branch_Id    :: distinct u32     // per session, monotonic from 1
Node_Id      :: distinct u64     // per session, monotonic from 1
Journal_Seq  :: distinct i64     // global commit order (SQLite rowid)
Turn_Id      :: distinct u32     // per session
Request_Id   :: distinct u32     // per session, one logical request
Attempt_No   :: distinct u8      // per request
Job_Id       :: distinct u64     // per process, monotonic, never reused
Call_Id      :: distinct u64     // per session; provider call ids are stored separately as strings
Snapshot_Gen :: distinct u64     // config/catalog snapshot generation
```

Zero means absent for every ID. IDs render as lowercase hex or decimal only at boundaries.

| Term | Meaning |
| --- | --- |
| State | what the owner currently knows (`Session_State`) |
| Event | one observed fact applied to state |
| Effect | one unit of work selected from state |
| Job | one bounded live asynchronous execution with a handoff record |
| Record | one journal fact |
| Node | one committed conversational step in the session tree |
| Task | one stored reusable Lua program |
| Tool call | one invocation of a registered capability |
| Subagent | one delegated execution in a child process |

## 6. Runtime

### 6.1 Threads and processes

| Thread or process | Count | Blocks in (idle) | Owns |
| --- | --- | --- | --- |
| main (TUI, headless, or ACP writer) | 1 | `ppoll(tty or stdin, view eventfd)` | terminal or protocol stream, frontend state |
| ACP reader | 1 in `nabla acp` | `read(stdin)` | frame decoding |
| owner | 1 per live session | `futex_wait(wake.seq)` | `Session_State`, journal writes for the session |
| config watcher | 1 | `ppoll(inotify fd, shutdown eventfd)` | snapshot construction |
| catalog refresh | 0 or 1, on demand, exits when done | network I/O | provider listing and models.dev fetch |
| job worker | 0..`BLOCKING_JOBS_MAX_RUNNING` | the blocking operation | one job's input and output |
| MCP server | per configured server, started lazily | (external) | its own process |
| subagent child | 0..`SUBAGENTS_MAX_RUNNING` | (external) | its own session |

An idle process has the main, owner, and watcher threads (plus the ACP reader) asleep in the calls above and nothing else.

### 6.2 Owner loop

```odin
owner_run :: proc(o: ^Owner) {
	for o.state.lifecycle != .Closed {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		seen := sync.atomic_load(&o.wake.seq)       // load before collecting: closes the lost-wake window
		now  := time.tick_now()
		owner_collect(o, now)                        // commands, job handoffs, snapshots, interrupt -> owner_apply
		for _ in 0..<OWNER_EFFECTS_PER_PASS {
			effect := owner_select(&o.state, now)    // reads state only: no clock, lock, I/O, allocation, counter
			if effect == nil do break
			owner_perform(o, effect)                 // claim, then start or complete work
			owner_collect(o, now)
		}
		journal_flush_due(&o.journal, now)           // observation batch (section 8.3)
		owner_wait(&o.wake, u32(seen), owner_nearest_deadline(&o.state, &o.journal))
	}
}
```

- `owner_collect` turns external facts into typed `Event` values and calls `owner_apply(state, event)`. Apply checks identity (turn, request, attempt, job) and transition legality; stale events are dropped with a debug record and their payload is freed.
- `owner_select` is pure. `owner_perform` first applies a claim transition (for example `Send_Attempt` moves the attempt to `Claimed`), so repeated selection cannot launch twice.
- `owner_perform` never blocks on network, process, or filesystem I/O. Allowed blocking inside the owner: journal commit (fsync), owner-placed tools (journal reads), one Lua slice, one hook run. All are bounded.
- `Effect` is a closed union; `owner_perform` switches exhaustively.

```odin
Effect :: union {
	Adopt_Snapshot, Start_Turn, Record_Input, Prepare_Request, Send_Attempt, Commit_Response,
	Reject_Response, Admit_Call, Start_Job, Resume_Lua, Commit_Result, Retire_Job, Stop_Jobs,
	Abandon_Job, Start_Compaction, Install_Checkpoint, Finish_Turn, Recover,
}
```

Selection priority, first match wins:

1. Latch stop and storage failure; adopt terminal job observations.
2. Commit pending durable results and responses; refuse work that can no longer start.
3. Retire joined producers; deliver committed child results to Lua parents.
4. Adopt a published snapshot if no turn is active.
5. Advance the request chain, or admit and start eligible jobs in model call order.
6. Run one Lua slice.
7. Nothing: wait.

### 6.3 Owner wake

```odin
Owner_Wake :: struct { seq: sync.Futex }   // monotonic; producers never reset it

owner_wake_signal :: proc "contextless" (w: ^Owner_Wake) {
	sync.atomic_add(&w.seq, 1)
	sync.futex_broadcast(&w.seq)
}

owner_wait :: proc(w: ^Owner_Wake, seen: u32, deadline: Maybe(time.Tick)) {
	d, has := deadline.?
	if !has { sync.futex_wait(&w.seq, seen); return }
	if left := time.tick_diff(time.tick_now(), d); left > 0 {
		sync.futex_wait_with_timeout(&w.seq, seen, left)
	}
}
```

Every producer writes its fact first, then calls `owner_wake_signal`: job workers, the command queue, the watcher, catalog refresh, and the SIGINT/SIGTERM handler. Because the owner loaded `seq` before collecting, any publication after that load changes `seq` and the futex wait returns immediately. `owner_nearest_deadline` is the minimum of: running job deadlines, stop-patience deadlines, retry due time, Lua wall deadlines, compaction backoff, and the journal batch age limit when records are pending. With nothing pending it is `nil`.

### 6.4 Owner inputs

- Frontend commands: a mutex-guarded bounded queue (`OWNER_COMMAND_QUEUE`) of `Command` values. A full queue refuses the command to the frontend; it never blocks the owner.
- Cancel: `session.control.cancel_requested` atomic plus wake. Works with a full queue and from a signal handler (the process `interrupt` atomic maps to the active session's cancel).
- Job handoffs: section 7.2. Each job owns its terminal slot, so terminal outcomes cannot be dropped.
- Snapshots: the watcher and catalog thread publish `^Config_Snapshot` / `^Catalog_Snapshot` into a single-slot atomic "latest" per kind and wake every owner.

```odin
Command :: union {
	Prompt, Steer, Cancel_Turn, Fork, Select_Branch, Select_Model, Set_Effort, Compact,
	Rate, Run_Command, Permission_Answer, Reload, Close,
}
```

### 6.5 Session and turn state

```odin
Session_State :: struct {
	id:         Session_Id,
	role:       Session_Role,        // Main, Subagent
	health:     Session_Health,      // Ok, Storage_Failed, Poisoned
	lifecycle:  Lifecycle,           // Open, Closing, Closed
	branch:     Branch_Id,
	head:       Node_Id,
	selection:  Selection,           // provider, model, effort; validated against the catalog
	config:     ^Config_Snapshot,    // newest adopted
	catalog:    ^Catalog_Snapshot,
	turn:       Maybe(Turn),         // at most one foreground turn
	jobs:       Job_Table,
	compaction: Compaction,
	projection: Projection,          // active ancestry working set, section 11
	view:       ^View_Queue,
}

Turn :: struct {
	id:        Turn_Id,
	phase:     Turn_Phase,           // Preparing, Awaiting_Model, Executing_Tools, Stopping, Finishing
	stop:      Stop,
	config:    ^Config_Snapshot,     // acquired at Start_Turn, released at Finish_Turn
	catalog:   ^Catalog_Snapshot,
	chain:     Maybe(Request_Chain),
	batch:     Maybe(Tool_Batch),
	requests:  int,                  // logical requests made, for accounting
	continues: int,                  // hook-driven continuations, <= the user's hook setting
	arena:     virtual.Arena,        // initialized in place after the Maybe is set
	outcome:   Turn_Outcome,         // Completed, Failed(Failure), Cancelled, Interrupted
}
```

Turn progression:

```text
Idle -> Preparing -> Awaiting_Model -> Executing_Tools -> Preparing ...   (after results commit)
                          |
                          +-> Finishing   (no calls, no unanswered input)
any active phase -> Stopping -> Finishing -> Idle
```

- A response without calls finishes the turn unless steering input was recorded after it, which returns to `Preparing`.
- An unusable response (undecodable, incomplete, cut off at the model's output limit, or with defective call identities) is committed as audit data plus a harness `Notice` node, executes nothing, and returns to `Preparing` (section 2.2). A turn has no request count limit: it ends when the model answers without calls, the user cancels, or the model cannot be reached.
- `Stopping` latches one cause, refuses new work, requests stop on every job, and waits for commit and retirement. User cancel wins the user-facing status; storage failure still poisons the session.
- Steering: frontend lines queue in `Steer_Queue` and become `User` nodes with origin `Steering` only at a settled boundary. A line leaves the queue only when its node commits.
- `Finish_Turn` commits `turn.completed` (barrier), releases snapshot references, destroys the turn arena, and emits the terminal view event once.

## 7. Jobs and concurrency

### 7.1 Job record

```odin
Job_Kind  :: enum u8 { Attempt, Tool, Lua, Subagent, Compaction }
Job_Phase :: enum u8 { Queued, Awaiting_Decision, Running, Waiting_Children, Stopping, Published, Committed, Retired, Abandoned }

Job :: struct {
	id:       Job_Id,
	kind:     Job_Kind,
	phase:    Job_Phase,             // owner-only
	parent:   Job_Id,                // Lua or Task parent, or zero
	call:     Call_Id,
	access:   Access,
	start:    time.Tick,
	deadline: Maybe(time.Tick),      // start + effective timeout, fixed at Start_Job
	stop_at:  Maybe(time.Tick),      // when stop was requested; + STOP_PATIENCE is a deadline
	stop:     Stop,                  // atomic flag the worker polls; the worker also reads turn.stop
	input:    Job_Input,             // union, immutable after Start_Job, stored in the arena
	handoff:  Job_Handoff,           // the only memory a worker writes
	thread:   ^thread.Thread,        // created and destroyed by the owner
	arena:    virtual.Arena,
	usage:    Job_Usage,             // cpu time, retained bytes, tokens where relevant
}

Job_Handoff :: struct {
	mu:        sync.Mutex,
	stream:    [dynamic]u8,          // Attempt: appended text and reasoning chunks, job arena
	progress:  u32,                  // atomic; bumped with each stream append
	published: bool,                 // atomic; set once, after result is complete
	result:    Job_Result,           // union; valid when published
}
```

Job records are heap-allocated individually (stable addresses) into `Job_Table.slots: [dynamic]^Job`, allocated on admission and freed on retirement. The table grows with the work the model asks for; `BLOCKING_JOBS_MAX_RUNNING` only decides how many run at once. Lua jobs have no thread; they run as owner slices.

### 7.2 Ownership protocol

1. The owner builds `input` in the job arena and commits intent, then creates the thread with the job pointer as data.
2. The worker sets its context, reads `input`, executes, writes `result` into the job arena under `handoff.mu`, stores `published = true`, calls `owner_wake_signal`, and returns. It touches nothing after the wake.
3. The owner sees `published`, commits the result (barrier), delivers it, then calls `thread.join` and `thread.destroy` (join is the retirement proof), then destroys the arena and frees the record.
4. A worker that does not publish within `STOP_PATIENCE` after a stop request: the owner commits `Unknown` for the call, moves the job to `Abandoned`, sets `health = .Poisoned`, and never frees that job, its arena, its thread handle, or anything the worker can reach. A poisoned session admits no turns; root exits after bounded cleanup and leaves the remainder to process exit.

There is one lifetime rule: the owner frees job memory, and only after join. No self-cleanup, orphan flags, or worker-side frees.

### 7.3 Access classes and scheduling

```odin
Access_Class :: enum u8 { None, Session, Read, Write, Process, External }
Access :: struct {
	class: Access_Class,
	paths: []string,   // canonical absolute paths; nil with Read means the whole workspace
	lane:  u32,        // External: MCP client
}
```

| Class | Used by | Conflicts with |
| --- | --- | --- |
| None | Lua and Task parents | nothing (children carry their own access) |
| Session | owner-placed tools | nothing (run inline, serialized by the owner) |
| Read | read, skill load, read-only subagent | Write on an overlapping path, Process |
| Write | write, patch | Read or Write on an overlapping path, Process |
| Process | shell, write-scope subagent, external harness | Read, Write, Process |
| External | MCP tool | External on the same lane |

A queued job starts when no earlier-admitted, unretired job conflicts with it and running blocking jobs are below `BLOCKING_JOBS_MAX_RUNNING`. Earlier means admission order, which is model call order for root calls. The owner scans the bounded table; there are no cached occupancy counts. Lua parents hold no access and no worker slot, so a parent waiting on children cannot deadlock them. Access comes from typed admitted arguments, never from MCP annotations or tool names.

### 7.4 Deadlines and cancellation

- The effective timeout is resolved once at admission: `args.timeout` when the model gave one, else `definition.default`, else none. There is no maximum. The clock starts at `Start_Job`, not at admission. A timed-out job returns `Timed_Out` with its partial output, so the model can rerun it with a longer timeout.
- Outcomes distinguish `Timed_Out` (own deadline), `Cancelled` (turn or job stop), and `Unknown` (stop not confirmed).
- `Stop` is per turn and per job. Workers check `job.stop` and `turn.stop` (the turn outlives every job it owns). There is no process-global token that gets reset.
- Provider attempts receive cancellation only; model deliberation has no harness deadline.

## 8. Journal

### 8.1 Contract

`agent/journal` is the durable execution record and the only home of SQLite knowledge. Core `agent` code calls its procedures; the package API is the storage boundary. There is no separate diagnostic log.

```odin
open          :: proc(path: string, mode: Open_Mode, allocator := context.allocator) -> (Journal, Error)
claim         :: proc(j: ^Journal, s: Session_Id) -> Error               // exclusive flock per session
append        :: proc(j: ^Journal, r: Record)                            // buffered, owner-only
append_node   :: proc(j: ^Journal, n: Node)                              // buffered, committed by the next commit
commit        :: proc(j: ^Journal) -> (Journal_Seq, Error)               // durable barrier; flushes the buffer
read_records  :: proc(j: ^Journal, f: Filter, after: Journal_Seq, page: int, allocator: mem.Allocator) -> ([]Record, Journal_Seq, Error)
read_ancestry :: proc(j: ^Journal, s: Session_Id, head: Node_Id, allocator: mem.Allocator) -> ([]Node, Error) // stops at the covering checkpoint
recover       :: proc(j: ^Journal, s: Session_Id, allocator: mem.Allocator) -> (Recovery, Error)
```

Records and nodes are journal-owned plain data (strings, integers, enums). `agent` maps its execution types to them; `agent/journal` never imports `agent`.

### 8.2 Schema

```sql
records(seq INTEGER PRIMARY KEY, time_ms INTEGER NOT NULL, mono_ns INTEGER NOT NULL,
        run BLOB NOT NULL, kind TEXT NOT NULL, session BLOB, branch INTEGER, node INTEGER,
        turn INTEGER, request INTEGER, attempt INTEGER, job INTEGER, call INTEGER,
        parent_call INTEGER, task TEXT, subagent BLOB, hook TEXT, provider TEXT, model TEXT,
        data TEXT, body BLOB) STRICT
nodes(session BLOB, node INTEGER, parent INTEGER, branch INTEGER, kind TEXT, turn INTEGER,
      seq INTEGER NOT NULL, data TEXT, body BLOB, PRIMARY KEY(session, node)) STRICT
branches(session BLOB, branch INTEGER, base_node INTEGER, seq INTEGER NOT NULL,
         PRIMARY KEY(session, branch)) STRICT
sessions(session BLOB PRIMARY KEY, created_ms INTEGER, workspace TEXT,
         parent_session BLOB, parent_call INTEGER, role TEXT) STRICT
artifacts(digest BLOB PRIMARY KEY, kind TEXT, created_ms INTEGER, bytes BLOB) STRICT
schema(version INTEGER)
```

- Every table is append-only. Mutable facts (title, active branch, selection, ratings) are the latest record of their kind. A branch head is `max(node) WHERE branch = b`.
- Indexes: `records(session, seq)`, `records(session, call) WHERE call IS NOT NULL`, `records(session, kind, seq)`, `nodes(session, branch, node)`.
- `data` is one JSON object per record, shaped by a versioned struct per kind (`v` field). `body` holds exact bytes. Diagnostics queries use SQLite JSON functions over `data`; analysis needs no custom decoder.
- WAL, `synchronous = FULL`, `busy_timeout`, private 0700 directory and 0600 files. Several processes (TUI, subagent children, diagnostics readers) share the file; each session has one writer claim.
- Migrations are explicit steps stamped in the same transaction. A newer schema is refused. Corrupt or unreadable data is a typed error naming the session and seq; the harness never guesses.

### 8.3 Durability classes and write path

| Class | Kinds (examples) | Rule |
| --- | --- | --- |
| Barrier | `session.created`, `branch.created`, `user.input`, `request.sent`, `response.committed`, `tool.admitted`, `tool.decision`, `tool.completed`, `lua.started`, `task.started`, `subagent.started`, `*.completed`, `checkpoint.installed`, `hook.applied` (when it changes model input), `rating.recorded`, `turn.completed` | `commit` before the dependent effect proceeds |
| Observation | `request.prepared`, `request.admitted`, `provider.observed`, `tool.validation_failed`, `tool.repaired`, `retry.scheduled`, `cache.observed`, `resource.observed`, `hook.failed`, `runtime.message` | buffered; written in the next barrier transaction or when the batch reaches `JOURNAL_BATCH_RECORDS`, `JOURNAL_BATCH_BYTES`, or `JOURNAL_BATCH_AGE` |

The owner is the only writer for its session. A commit is one short immediate transaction; no transaction spans a network operation or a wait. Results that publish together commit together. A failed commit latches `Storage_Failed`: admission stops, cleanup continues without the journal. A crash may lose buffered observations, never barriers.

### 8.4 Record kinds

`Record_Kind` is a closed enum with a stable-name table. Names are never changed or reused; new kinds are appended.

```text
run.started run.finished
session.created session.titled session.recovered session.claimed session.released
branch.created branch.selected
user.input node.committed
turn.started turn.completed
request.prepared request.admitted request.sent provider.observed response.committed response.rejected request.interrupted
retry.scheduled retry.completed
tool.proposed tool.validation_failed tool.repaired tool.admitted tool.decision tool.started tool.completed
lua.started lua.completed
task.started task.completed
subagent.started subagent.completed
hook.applied hook.failed
compaction.started compaction.completed checkpoint.installed
config.published config.rejected catalog.published
cache.observed resource.observed
rating.recorded rating.cleared assessment.recorded
runtime.message runtime.poisoned
```

Every record fills the correlation columns that exist at that point: session, branch, node, turn, request, attempt, job, call, parent call, task, subagent, hook, provider, model. A record states one fact at the boundary that observed it, once. Summaries are computed by readers.

`turn.started` carries the digests of what the turn runs with: instruction snapshot, tool schema set, active rules, hooks, config snapshot generation, model, and effort. Offline analysis joins on these.

### 8.5 Diagnostics from other threads

Workers and library code log through `context.logger`, which writes into a process-wide `Diag_Ring`: a mutex-guarded fixed array of `DIAG_RING_ENTRIES` entries, each with inline fixed-size text (`DIAG_TEXT_MAX`), level, thread id, and correlation copied from the logger binding. Producers never allocate and never block; a full ring increments a dropped counter. Owners drain the ring into observation records. Process-scope facts (a watcher error, catalog refresh failure) are drained by any owner, or by root into a process-scope record when no session is open.

Payload capture (full provider request bodies, raw response streams, MCP lines) is opt-in (`diagnostics.capture = true`). Captures are `artifacts` rows keyed by SHA-256, referenced from records by digest, bounded per session and by retention (section 27). Credentials, headers, and environment are never captured.

## 9. Recovery

On claiming a session, in one transaction:

| Durable facts found | Recorded outcome |
| --- | --- |
| `turn.started` without `turn.completed` | `turn.completed{Interrupted}` |
| `request.sent` without terminal | `request.interrupted`; never resent |
| `tool.proposed` (committed response) without `tool.admitted` | `tool.completed{Not_Executed}` |
| `tool.admitted` without `tool.completed` | `tool.completed{Unknown, "execution may have happened"}` (roots and Lua children) |
| `lua.started`, `task.started`, `subagent.started` without completion | `*.completed{Unknown}`; scripts are never resumed |
| `Assistant` node with calls and no `Results` node | `Results` node built from committed and recovered results |
| compaction output without `checkpoint.installed` | nothing; audit data only |

Then `session.recovered{counts}`. Recovery reconstructs history, not stacks: no replay of provider requests, tools, Lua, Tasks, hooks, or scheduled retries. Unknown results enter the projection as ordinary results, so the model sees the uncertainty. A subagent child whose parent died receives `SIGKILL` through `PR_SET_PDEATHSIG` and recovers its own session when next opened.

## 10. Session tree

### 10.1 Nodes

| Node kind | Body | Settled fork point |
| --- | --- | --- |
| `User` | input text; origin `Prompt`, `Steering`, or `Command{name, digest}` | yes |
| `Assistant` | text, reasoning replay items, native replay bytes, calls | only without calls |
| `Results` | ordered call ids answering the preceding `Assistant` node | yes |
| `Context` | harness-inserted model input: rule activation, hook continuation | yes |
| `Notice` | harness feedback for a rejected response | yes |
| `Checkpoint` | summary text; `covers: Node_Id` | yes |

A node's `parent` is the previous node on its branch. The owner allocates node ids in commit order. `Journal_Seq` gives global order, `Node_Id` gives tree position, and a later node may have an older parent.

### 10.2 Branches and forks

- `branch.created{base_node}` creates a branch; its first node has `parent = base_node`. The initial branch has `base_node = 0`.
- `Fork{node}` requires a settled node on any branch and no active turn. Existing descendants are untouched.
- `branch.selected` makes a branch active, at a turn boundary only.
- Frontends list branches with head, base, and last user text through a journal query.

### 10.3 Checkpoints in a tree

A checkpoint is a node on the branch where it is installed: `parent = head at install`, `covers = F`, where `F` is an ancestor of its parent. Projection from a head walks parents until it meets a `Checkpoint` node `K`, emits `K`'s summary, then emits only the nodes after `F` up to and including `K.parent`, then stops. Branches forked from before `K` never see it. Original nodes are never removed.

## 11. Projection and provider requests

### 11.1 Projection

`Projection` is the owner's resident working set: the active ancestry as `[dynamic]Node_Ref` (node id, kind, byte range into cached bodies) plus the encode cache. It is loaded with `read_ancestry` when a session opens, a branch is selected, or a checkpoint is installed, and extended in memory as nodes commit. The covering checkpoint keeps it below the compaction trigger, so the model window bounds it.

### 11.2 Request layout

Deterministic order, placed by the `ai` encoder into the API's fields:

1. Instruction snapshot: base prompt, `AGENTS.md` sources, `always` rules, model-matched rules, material catalog metadata. Stored once as an artifact by digest.
2. Tool definitions of the turn's registry, sorted by name, schema bytes verbatim from the registry.
3. Ancestry projection in node order.
4. Transient suffix: hook guidance for this request, the compaction directive for compaction requests. Never part of history.

Parts 1 and 2 contain no timestamps, request ids, random ordering, or mutable lists. Tool definitions are encoded once per registry build. Unused skill and Task bodies never enter a request. The provider cache key derives from `Session_Id` only, so retries, branches, and reconnects share it. Legitimate prefix changes (snapshot adoption at a turn boundary, model or effort change, checkpoint install) are recorded with their cause in `request.prepared`.

Replay: provider-native opaque items (encrypted reasoning, Responses output) are replayed only to the same API family and model; otherwise neutral text and calls are projected. Repaired calls project their effective arguments, never the original. Partial output is never projected as a complete message.

### 11.3 Chain, freeze, send

- `Prepare_Request` copies the projection and encodes into the chain arena, runs `request.prepare` hooks, checks capacity (section 23), then freezes: the encoded body is immutable for every attempt of this request.
- `Send_Attempt` commits `request.sent{attempt, body digest, sizes}` (barrier), then starts an `Attempt` job that borrows the frozen bytes and streams into its handoff.
- The owner forwards new stream bytes to the view queue as progress. Completion is validated (identities, count, argument sizes) before `Commit_Response` writes the `Assistant` node and `tool.proposed` records in one barrier.
- Recovery authorization lives only in `agent`, and every branch keeps the turn going unless section 2.2 says it ends. Order: end on cancel or storage failure; accept a validated completion; answer an unusable or partially exposed response with a `Notice` and a new request; for proven context overflow, install a checkpoint and rebuild; for a refusal of the request content (invalid request, payload too large, content policy), a `Notice` carrying the provider's code, message, and stated limit, then a new request; resend a transient class (rate limited, unavailable, incomplete stream) only while delivery evidence proves the model send was not entered, otherwise a `Notice`; end only on authentication, quota, missing model, or configuration errors, reporting the provider's message to the user.
- Backoff: `ceiling = min(RETRY_BACKOFF_CEILING, 500 ms * 2^(n-1))`, `delay = max(uniform(ceiling/2, ceiling), retry_after)`. Transient resends have no attempt count and honor any provider-requested delay; a network outage while the user is away delays the turn instead of ending it. The wait is an owner deadline, not a sleep, and cancel ends it.
- Transport: per provider `http | websocket | auto`. `auto` uses WebSocket for APIs that implement it and falls back to HTTP for the affinity only on evidence that no model message was sent. The WebSocket connection is session-owned, used by one attempt at a time, and destroyed on affinity change or any unsuccessful operation.

### 11.4 Usage and cache accounting

`provider.observed` records input, output, cache-read, cache-write, and reasoning tokens, each with presence. Missing is unknown, never zero. Within one attempt the latest cumulative value wins; attempts sum.

```text
paired_input = sum(input where input and cache_read are both reported)
paired_read  = sum(cache_read for the same rows)
hit_rate     = paired_read / paired_input
coverage     = paired_input / sum(all reported input)
```

## 12. Model catalog

- Sources in precedence order: user configuration, provider discovery (`GET /models`, disk-cached), models.dev (disk-cached). A present higher-precedence value is final; only absence is enriched. False, zero, and empty are present values. Lists replace, never merge. `disabled` is a tombstone.
- Identity is `(provider_id, model_id)`. API-family behavior lives in `ai`; the catalog carries data only.

```odin
Model_Facts :: struct {
	provider, model, display_name: string,
	api:            ai.Api_Family,
	transport:      ai.Transport,
	context_window: Maybe(int),
	max_output:     Maybe(int),
	tools:          Maybe(bool),
	input_modalities, output_modalities: bit_set[Modality],
	reasoning:      Maybe(Reasoning_Facts),  // supported, toggle, valid effort levels
	flags:          bit_set[Model_Flag],
	capacity:       Capacity,                // computed once, section 23
}
```

- `Catalog_Snapshot` is immutable, built in its own arena, and published like config (section 13). Frontends, request construction, tool exposure, transport selection, subagent model choice, and capacity all read the same snapshot. No code derives capabilities from model names.
- Refresh runs on the catalog thread: on demand (model menu, ACP config request) at most once per `CATALOG_REFRESH_COOLDOWN`, and at startup when a cache is older than `CATALOG_CACHE_TTL`. models.dev is parsed into a temporary arena, extracted into compact tables, and the arena is destroyed. A provider that fails keeps its previous listing.

## 13. Live configuration

### 13.1 Sources

| Source | Scope |
| --- | --- |
| `$XDG_CONFIG_HOME/nabla/config.lua` (default `~/.config/nabla/`) | providers, credential references, models, MCP servers, external agents, policy, diagnostics, tool exposure |
| `$XDG_CONFIG_HOME/nabla/{skills,rules,commands,tasks,hooks}/` | user material and hooks |
| `~/.agents/skills/`, `~/.agents/AGENTS.md` | personal material |
| `<workspace>/.agents/{skills,rules,commands,tasks}/`, `<workspace>/AGENTS.md` | project material; `instructions.project = false` disables it |

Project definitions win over user definitions of the same name. No ancestor walk, no VCS inspection, no `.nabla/`. Hooks load from the user configuration directory only; repository files cannot install policy.

### 13.2 Reload pipeline

1. The watcher holds inotify watches on every source directory and each discovered material directory; discovery skips a directory whose device and inode it already visited, so symlink cycles end the walk without a depth cap. `IN_CREATE` of a directory adds a watch. If the watch limit is reached, the watcher reports the degradation and reload falls back to the explicit `Reload` command.
2. Events are coalesced: after the first event the watcher waits for quiet with `ppoll` timeout `CONFIG_DEBOUNCE`, then rebuilds.
3. Build on the watcher thread in a fresh arena: evaluate `config.lua` (restricted Lua, section 17), discover material metadata, read instruction files, compile hooks, render the instruction snapshot, encode tool schemas, compute digests. Credential references resolve at connection creation, not here.
4. Validate completely. On failure the previous snapshot stays current, `config.rejected{source, error}` goes through the diag ring, and the view shows the error.
5. Publish: store the pointer in the "latest" slot atomically and wake every owner. When provider configuration changed, the watcher also re-resolves the catalog against cached sources.

### 13.3 Adoption and lifetime

```odin
Config_Snapshot :: struct {
	gen:          Snapshot_Gen,
	users:        int,                  // atomic reference count
	arena:        virtual.Arena,
	config:       Config,               // validated plain data
	instructions: Instruction_Snapshot, // rendered bytes, digest, manifest
	registry:     Tool_Registry,        // native and MCP definitions with schema bytes
	material:     Material_Catalog,     // skills, rules, commands, Task metadata
	hooks:        Hook_Set,
	policy:       Policy,
	digests:      Snapshot_Digests,
}
```

- An owner adopts the latest snapshot when no turn is active; a running turn keeps its own. Every turn, job, compaction, and subagent launch acquires a reference and releases it at retire. The "latest" slot holds one reference. The last release destroys the arena.
- MCP changes apply the same way: a new snapshot carries new bindings; old bindings live until the last user releases.
- Adoption records `config.published{gen, digests}` and updates the view (model list, commands, errors).

## 14. Tools

### 14.1 Definitions and registry

```odin
Tool_Kind :: enum u8 { Read, Write, Patch, Shell, Code, Catalog_Search, Skill_Load, Task_Run, Agent_Spawn, Result_Read, Compact, MCP }
Placement :: enum u8 { Owner, Worker, Lua, Child_Process }

Tool_Definition :: struct {
	name:        string,           // [A-Za-z_][A-Za-z0-9_]{0,63}, not a Lua keyword
	kind:        Tool_Kind,
	placement:   Placement,
	description: string,
	schema:      []u8,             // canonical JSON, advertised verbatim
	timeout:     Maybe(time.Duration), // default when the model gives none
	mcp:         ^MCP_Binding,     // kind == .MCP only
}

Tool_Args   :: union { Read_Args, Write_Args, Patch_Args, Shell_Args, Code_Args, Search_Args, Skill_Load_Args, Task_Run_Args, Spawn_Args, Result_Read_Args, Compact_Args, MCP_Args }
Tool_Output :: union { Read_Output, Write_Output, Patch_Output, Shell_Output, Code_Output, Search_Output, Skill_Output, Task_Output, Spawn_Output, Result_Read_Output, Compact_Output, MCP_Output }
```

The registry is built, validated (names, schemas, collisions), and sorted inside the config snapshot, and is immutable. Advertisement, Lua `tools.*`, and admission read the same registry. Exposure filters (model without tool support, subagent scope, `tools.expose` in config) apply to advertisement and admission alike.

| Tool | Access | Placement |
| --- | --- | --- |
| `builtin_read` | Read(path) | Worker |
| `builtin_write` | Write(path) | Worker |
| `builtin_patch` | Write(paths) | Worker |
| `builtin_shell` | Process | Worker |
| `builtin_code` | None | Lua |
| `catalog_search` (skill and Task metadata) | Session | Owner |
| `skill_load` | Read(skill file) | Worker |
| `task_run` | None | Lua |
| `agent_spawn` (main sessions only) | Read(all) or Process, by scope | Child_Process |
| `context_read_result` | Session | Owner |
| `context_compact` | Session | Owner |
| MCP tools `<server>_<tool>` | External(client lane) | Worker |

### 14.2 Admission pipeline

Every call, whatever its source, runs:

```text
decode (provider JSON or Lua value) -> validate -> [repair -> revalidate] -> hook tool.before_admit
  -> policy (allow | ask | deny) -> commit tool.admitted (barrier: effective args, repairs, access)
  -> hook tool.after_admit -> schedule (section 7.3) -> hook tool.before_execute -> Start_Job
```

- Decode adapters: `args_from_json(kind, json.Value)` for provider input, after a strict parse with duplicate-key and depth checks, and `args_from_lua(kind, L, idx)` for Lua. Both produce `Tool_Args`. `args_validate(kind, &args)` is the single semantic validator (paths, ranges, types). Argument size is not validated: the model's output limit is the only bound. MCP args stay a `json.Value`; the server validates their semantics.
- A call that fails any step gets a committed result (`Invalid_Arguments`, `Unavailable`, `Denied`, `Not_Executed`) and its siblings proceed. A defective response (missing or duplicate call ids, empty names) executes no call and becomes a `Notice` (section 2.2). There is no call count limit per response.
- Policy: config `policy.tools = { name = "allow" | "ask" | "deny" }`, default allow. `ask` moves the job to `Awaiting_Decision` and emits a permission view event (TUI prompt, ACP `session/request_permission`). The answer arrives as `Permission_Answer` and commits `tool.decision` before execution. A crash while waiting yields `Not_Executed`.
- A Lua child commits before its result is delivered; a parent's result commits after all its children settle.

### 14.3 Results

- `Outcome`: `Success`, `Tool_Failed`, `Invalid_Arguments`, `Denied`, `Unavailable`, `Not_Executed`, `Transport_Failed` (proven undelivered), `Cancelled`, `Timed_Out`, `Unknown`. An outcome requires its evidence; lacking evidence it is `Unknown`.
- `Tool_Result :: struct { outcome: Outcome, failure: Maybe(Failure), output: Tool_Output }` is typed and lives in the job arena until committed.
- At commit the owner renders the model-visible bytes once with the tool's `render` procedure and stores them in the `tool.completed` body; typed fields go to `data`. The projection uses those stored bytes from then on, so resume and cache stay byte-stable. Lua parents receive typed values converted from `Tool_Output`, never the rendering.
- Rendering format: first line `ok` or `error <kind>: <message>`, then tool-specific `key: value` lines, then a blank line and the raw body (file text, stdout and stderr sections). Raw text avoids JSON escaping inside provider JSON; the format is kept only while measured tokens per successful task confirm it.
- Retention: the journal keeps every result whole. Output beyond `TOOL_RESULT_INLINE_BYTES` is stored as an artifact and referenced from the record; the tool streams it there instead of holding it in memory.
- Context budget: a batch charges root results in call order against the room left in the context, reserving `TOOL_RESULT_HANDLE_TOKENS` for each later result. A result that does not fit projects a head and tail preview within its allowance plus a handle line naming the call and total bytes. `context_read_result{call, offset}` pages the retained bytes in UTF-8-safe windows. The allowance is stored with the result, so later requests project identical bytes.

### 14.4 Native tools

- Read: open once, `fstat` that descriptor; text only (no NUL, valid UTF-8); the model chooses the line window, and the result is projected through the context budget like any other.
- Write: validate, temp file in the same directory, write, fsync, rename; refuse symlinks and non-regular targets; keep the mode.
- Shell: `$SHELL -c` (fallback `/bin/sh` only when exec failed), fresh process group, stdin closed, inherited environment, raw-syscall child path, both pipes drained under `poll`, TERM then KILL after `SHELL_KILL_GRACE`, reap, exec failure distinct from exit 127, UTF-8-sanitized output retained whole and projected through the context budget. The timeout is the model's value when given, else the default; there is no maximum.
- MCP: one shared executor; one request at a time per client lane. Delivery state maps to `Transport_Failed` (not delivered) or `Unknown` (delivered, no reply). Non-text blocks are described, not dumped.

## 15. Deterministic repair

Repairs run only after a validation failure and only from a closed set. Each application commits `tool.repaired{kind, before_digest, after_digest}`; each failure commits `tool.validation_failed{field, reason}`.

```odin
Repair_Kind :: enum u8 {
	Control_Bytes_In_String,   // raw control bytes inside a JSON string literal become escapes
	Double_Encoded_Object,     // schema expects an object; value is a string holding exactly one valid object
	Numeric_String,            // field marked coercible; string is an exact integer or finite number
	Line_Endings,              // write or patch text normalized to the target file's line-ending convention
	Patch_Trailing_Whitespace, // hunk matches exactly one location when trailing whitespace is ignored
	Patch_Missing_End_Marker,  // patch lacks only its final end marker
}
```

A repair is valid only if exactly one interpretation exists, the result passes full revalidation, and policy and hooks then run on the repaired value. Never: invent a missing argument, pick a file, map an unknown tool name to a similar one, change a value that looks wrong, or bypass validation. JSON syntax repair applies only to provider JSON; Lua values are never repaired.

## 16. Patch contract

`builtin_patch{patch}` replaces old/new edits:

```text
*** Begin Patch
*** Add File: <path>
+<line>
*** Delete File: <path>
*** Update File: <path>
*** Move to: <path>
@@ <optional anchor line>
 <context line>
-<removed line>
+<added line>
*** End Patch
```

- Paths are workspace-relative or absolute and are canonicalized once; they become the call's `Write` access set.
- Per file: read the current bytes and locate each hunk (context plus removed lines) searching forward from the previous hunk's end, after the `@@` anchor when given. Exactly one match is required; zero or several fail that hunk.
- All files are computed in memory first. If any hunk fails, nothing is written. Writes then go file by file through temp-plus-rename. A rename failure after earlier renames reports `Tool_Failed` with the list of applied files, because POSIX has no multi-file atomicity.
- Failure output names the file, hunk index, reason (`not_found`, `ambiguous{count, lines}`, `file_missing`, `file_exists`), and the nearest candidate lines, so the model can correct without rereading the file.

## 17. Lua runtime

One embedded `vendor:lua/5.4` runtime serves Code Mode, Tasks, hooks, config evaluation, and Task metadata. Each execution gets a fresh state; states are never shared or pooled.

| Profile | Memory | Wall | Capabilities |
| --- | --- | --- | --- |
| Code Mode | system memory | the model's `timeout`, else none | `tools.*`, `job.*`, `print`, `json.null` |
| Task | as Code Mode | as Code Mode | as Code Mode, plus `args` |
| Hook | `LUA_HOOK_MEMORY` | `LUA_HOOK_WALL` | its input value only |
| Config | `LUA_CONFIG_MEMORY` | `LUA_CONFIG_WALL` | `os.getenv` only |
| Task metadata | `LUA_META_MEMORY` | `LUA_META_WALL` | none |

Code Mode and Tasks run model-written programs, so they carry only external limits (section 2.1). Hooks, config, and metadata run user code on the owner or the watcher, so their quotas keep those threads responsive.

- Libraries by allowlist: base without `load`, `loadfile`, `dofile`, `collectgarbage`, `setmetatable`, `getmetatable`, `rawset`, `pcall`, `xpcall`; `string` without `dump`; `table`, `math`, `utf8`. No `io`, `os` (except config's `getenv`), `package`, `debug`, `coroutine`.
- Allocator: `lua_Alloc` over the heap using `mem.resize_non_zeroed`, accounting live requested bytes. Profiles with a memory quota check a resize against `live - old + new`; Code Mode and Tasks have none, so only an OS allocation failure refuses. Refusal returns nil as Lua requires; shrinking never fails. `LUA_HOST_RESERVE` is added while the host pushes values.
- Scheduling is suspension: a count hook yields every `LUA_SLICE_INSTRUCTIONS` so the owner stays responsive; the owner checks stop, deadlines, and quotas between slices and never resumes a stopped run. The slice size is a scheduling quantum, not a limit on work. Every allocation-capable host entry runs protected. Callbacks hold no Odin resources that depend on `defer`.
- Code Mode and Tasks run on the owner, one slice per `Resume_Lua` effect, so several scripts interleave and none holds the owner longer than a slice. Hooks run to completion on the owner within their small limits; config and metadata run on the watcher.

### 17.1 Code Mode API

```lua
local h1 = job.start("builtin_read", {path = "a.odin"})
local h2 = job.start("builtin_shell", {command = "odin check ."})
local a, b = job.wait(h1), job.wait(h2)
local c = tools.builtin_read({path = "b.odin"})   -- equals job.wait(job.start(...))
return {ok = a.outcome == "success", errors = b.output.stderr}
```

- `job.start` yields a host request; the owner admits a child through section 14.2 and returns an integer handle. `job.wait(h)` yields until that child's result commits and returns its typed table (`outcome`, `message`, `output`). An unknown or already consumed handle raises a Lua error.
- A script may hold any number of unfinished children. They queue in the job table and run as access and `BLOCKING_JOBS_MAX_RUNNING` allow.
- When a script ends with unconsumed children, they are stopped, awaited, and reported in the parent result.
- `builtin_code` and `task_run` are not callable from Lua (nesting depth one). `agent_spawn` is callable from Lua in a main session.
- Value conversion is one checked path in both directions: finite, exactly representable numbers; UTF-8 strings; dense 1-based arrays; string-keyed tables; the `json.null` sentinel. Cycles, sparse or mixed tables, functions, threads, and userdata are refused with a bounded path. Raw table access only.
- Parent result: the return value, the print log, and the child list, projected through the context budget like any tool result; or a typed failure kind (`syntax_error` with line and message, `runtime_error` with traceback, `invalid_value` with the value path, `out_of_memory`, `cancelled`, `timed_out`) with the list of children already executed. Every failure is returned to the model, which may fix the script and run it again.

## 18. Tasks

One Lua file per Task, `<name>.lua` in `.agents/tasks/` or `$XDG_CONFIG_HOME/nabla/tasks/`. Name rules match skills.

```lua
return {
  description = "Run tests for one package and summarize failures",
  params = { package = "string", verbose = "boolean?" },
  run = function(args)
    local r = tools.builtin_shell({command = "odin test " .. args.package})
    return {failed = r.output.exit_code ~= 0, stderr = r.output.stderr}
  end,
}
```

- Discovery evaluates the file under the metadata profile and keeps only `description` and `params`. The digest is SHA-256 of the file bytes.
- `task_run{name, args}` validates `args` against `params` (types `string`, `integer`, `number`, `boolean`, `table`; a trailing `?` marks optional), commits `task.started{name, scope, digest, args}`, and runs `run(args)` in a fresh Code Mode-profile state with the Code Mode job machinery. The file is reread at invocation; a changed digest runs and records the new version.
- Task bodies never enter model context through discovery. There is no Task interpreter beyond the Lua runtime.

## 19. Skills, rules, commands

All use `agent/material`: a documented frontmatter subset (plain, quoted, literal, and folded scalars; no flow collections, anchors, or tags), discovery in bytewise order, and verified loads (one descriptor, `fstat` before and after, digest match).

| Kind | Location | Metadata | Disclosure |
| --- | --- | --- | --- |
| Skill | `skills/<name>/SKILL.md` | `name`, `description` | metadata in the instruction snapshot (inline if the catalog fits `SKILL_INLINE_CATALOG`, else `catalog_search`); body through `skill_load` |
| Rule | `rules/<name>.md` | `description`; `applies: always`, `paths`, or `model`; `paths` (space-separated globs) or `model` (glob) | `always` and matching `model` rules in the instruction snapshot; `paths` rules on activation |
| Command | `commands/<name>.md` | `description`, optional `arguments` hint | explicit invocation; body template with `$ARGUMENTS` and `$1`..`$9` |
| Task | `tasks/<name>.lua` | section 18 | metadata only |

- A `paths` rule activates when a committed call's admitted access paths match one of its globs. Activation appends a `Context` node holding the rule body before the next request, once per ancestry (skipped when the ancestry already holds the same rule digest). Appending keeps the prefix stable.
- A command expands into a `User` node with origin `Command{name, digest}`. Built-in frontend commands win a name collision, and the collision is reported.
- Native subagents are not defined by files. Unknown frontmatter fields grant nothing.

## 20. Hooks

Hooks are user-configured Lua files in `$XDG_CONFIG_HOME/nabla/hooks/`, each returning `{point = "<name>", order = <int>, run = function(input) ... end}`. The snapshot stores compiled chunks sorted by `order`, then file name. Each invocation gets a fresh Hook-profile state, a bounded copy of its input, and returns a typed decision. Hooks get no session, journal, tools, or credentials.

| Point | Input | Allowed result | On hook error |
| --- | --- | --- | --- |
| `request.prepare` | model, turn, estimate, tool names, last user text | `{}`, `{guidance = s}` (transient suffix), `{stop = reason}` | stop turn |
| `request.before_send` | frozen request digest and sizes | `{}`, `{stop = reason}` | stop turn |
| `response.received` | text, call names and args | `{}`, `{reject = reason}` (Notice node, new request) | reject |
| `tool.before_admit` | call name, typed args table | `{}`, `{deny = reason}`, `{args = t}` (full revalidation) | deny |
| `tool.after_admit` | admitted call | observe only | record, continue |
| `tool.before_execute` | admitted call, access | `{}`, `{deny = reason}` (`Not_Executed`) | deny |
| `tool.after_execute` | outcome, typed output summary | `{}`, `{content = s}` (replaces rendered bytes; outcome unchanged) | keep content |
| `turn.before_finish` | final text, turn stats | `{}`, `{continue = message}` (`Context` node; at most `hooks.max_continues` per turn) | finish |
| `turn.finished` | turn summary | observe only | record, continue |

- A hook cannot widen authority, raise a bound, authorize a retry, clear cancellation, rewrite committed history, or turn an effect into success. Native validation runs again after every modifying result.
- Hooks run once per boundary; frozen retries do not rerun them. A modification commits `hook.applied{hook, point, digest, effect}` before its result is used; a failure records `hook.failed`.

## 21. Subagents

### 21.1 Invocation

`agent_spawn` exists only in sessions with `Session_Role.Main`. Child sessions have role `Subagent`; the tool is absent from their registry and refused at admission.

```odin
Spawn_Args :: struct {
	instruction: string,
	harness:     string,             // "nabla" or a configured external agent id
	model:       Maybe(string),      // resolved through the catalog; default: parent selection
	effort:      Maybe(string),
	context:     Maybe(string),      // parent-selected text
	scope:       Spawn_Scope,        // Read_Only, Workspace_Write
	timeout:     Maybe(time.Duration),
}
```

The child receives only the instruction and selected context, never the parent conversation. `Read_Only` gives the child read-only tools and Code Mode over them, with access class Read(all). `Workspace_Write` gives the child its default registry, with access class Process.

### 21.2 Execution

- Every subagent is a child process driven over ACP by a supervising `Subagent` job worker. Native subagents run `nabla acp --subagent`; external harnesses (Codex, Claude Code) run their configured ACP command from `config.lua` `agents = { {id, command, args, env} }`. One adapter serves both.
- Spawn: private process group, `PR_SET_PDEATHSIG = SIGKILL` in the child (the supervising thread lives until it reaps the child), stdin and stdout pipes, stderr drained into a diagnostic artifact. Then `initialize`, `session/new{cwd, _meta.nabla: {model, effort, scope, parent_session, parent_call}}`, `session/prompt`.
- The parent commits `subagent.started{child_session}` before prompting. Native children write their own session to the same journal with `parent_session` and `parent_call`.
- Child permission requests (`session/request_permission`) reach the owner as job observations and are answered by the parent's `tool.before_execute` hooks and policy. Nabla advertises the ACP client `fs` methods and serves them through its own read and write tools, so file access through them is validated and journaled. Actions an external harness takes without asking are governed by its own policy and by the Process access class.
- Progress updates become view events only; they never enter the parent's context.
- Result: final text (projected through the parent's context budget), outcome, child session id, tokens from `usage_update`, CPU and memory from `wait4` rusage. Outcomes distinguish completed, reported failure, malformed or missing terminal, abnormal exit, cancelled, and timed out.
- Cancellation: ACP `session/cancel`; after `STOP_PATIENCE`, `SIGTERM` to the group; after `SHELL_KILL_GRACE`, `SIGKILL`; then reap. An unconfirmed stop is `Unknown`.
- Concurrency: up to `SUBAGENTS_MAX_RUNNING`, subject to access conflicts. Several `Read_Only` children run in parallel; `Workspace_Write` children serialize with each other and with parent writes.

## 22. Frontends and ACP

- Frontends own no agent semantics. They send `Command` values and consume view events. TUI, headless, and the ACP server are peers over the same owner.
- `View_Queue`: owner to frontend, bounded by `VIEW_QUEUE_BYTES`, mutex-guarded, signalled by an `eventfd` the frontend includes in its `ppoll`. Events: user text, assistant text delta (entry id, bytes), tool admitted, tool settled, permission request, usage, retry, notice, turn state, config and catalog changes, branch changes. On overflow the owner drops deltas and sets `resync`; the frontend then rebuilds its recent transcript from a bounded read-only journal page. The owner never performs frontend I/O and never blocks on a frontend.
- TUI: immediate-mode `layout` and `term` rendering; its own display transcript bounded by `TRANSCRIPT_MAX_BYTES`; `ppoll` with no timeout when idle and `SPINNER_INTERVAL` only while a turn runs. Commands: `/new`, `/resume`, `/fork`, `/branch`, `/model`, `/effort`, `/compact`, `/rate`, `/reload`, `/status`, `/help`, `/quit`, plus material commands.
- Headless (`nabla --prompt`): the main thread consumes view events, writes the final answer to stdout and everything else to stderr.
- ACP server (`nabla acp`): the reader thread decodes frames into commands; the main thread turns view events into `session/update` frames. One owner per open ACP session, up to `ACP_MAX_SESSIONS`. `session/fork` maps to `Fork`, permission requests to `session/request_permission`, and `_nabla/rate` and `_nabla/branches` are extension methods. `acp` also implements the client role used by subagents.

## 23. Context, capacity, compaction

### 23.1 Capacity

Computed once per model into `Capacity` in the catalog snapshot:

```text
W       = context_window, or CONTEXT_WINDOW_ASSUMED flagged as assumed; a stated 0 or negative refuses requests
M       = max(W / 10, 1024)               estimator margin
F       = min(1024, max_output)           minimum useful answer
ceiling = W - M - F                       admission limit for the input estimate
trigger = max(ceiling - W / 5, 0)         compaction pressure point
output  = min(W - M - estimate, max_output)
```

The estimate is bytes / 4 plus 8 per message, reported per part (instructions, tools, conversation). Provider-reported input tokens update the displayed estimate, never admission.

### 23.2 Compaction

- At most one per session: a `Compaction` job (tool-free provider request) over a frozen prefix through `F`, keeping the newest `COMPACT_KEEP_MESSAGES` and never splitting an assistant/results pair.
- Compaction runs in the background and never pauses the agent. While the job runs, the turn keeps sending requests over the unchanged projection, so the provider prefix and its cache stay intact. Install swaps only the prefix through `F` for the summary: every node committed after `F`, including the steps the agent took while the summary was computed, stays in the projection after the checkpoint (section 10.3).
- Triggers: estimate at `trigger`, explicit command or `context_compact`, proven provider overflow. Triggers coalesce. Automatic starts require new nodes since the last attempt and respect `COMPACT_COOLDOWN`. Auth, quota, and invalid-request failures suppress automatic starts until configuration or explicit intent changes.
- A summary is accepted only with a normal stop reason, no tool calls, non-empty text, and a saving of at least `COMPACT_MIN_REDUCTION` tokens.
- Install at a request boundary or while idle: verify base and coverage, commit the `Checkpoint` node (section 10.3) and `checkpoint.installed` in one transaction, reload the projection, reset the encode cache.
- The foreground does not wait for a summary it does not need. When admission refuses, a ready candidate is installed and admission reruns; without one, the turn waits for a compaction and continues after the install. The turn ends with `Context_Exhausted` only when nothing a checkpoint can remove would make room, which is the model's window refusing the instructions and tools themselves; the user is told which part is too large.
- The summary directive asks for goals, constraints, decisions with evidence, exact identifiers, current and pending work, failures, and unknowns, and tells the model to reload skills before relying on their details.

### 23.3 Encode cache

The `ai` encode cache keeps encoded fragments of unchanged messages. It is bounded by `ENCODE_CACHE_MAX_BYTES` and reset on checkpoint install, on a model or API change, and when its retained bytes exceed twice the last request body.

## 24. Ratings and assessments

- `Rate{node, value, note}` commits `rating.recorded{node, value: positive | negative, note}` against an `Assistant` node. No rating means no record. `rating.cleared{node}` withdraws; the latest record wins.
- Offline evaluators write `assessment.recorded{node or turn, evaluator, evaluator_version, score, label, note}` through `nabla assess import`, never as ratings. Assessments are annotations: they need no session claim and change no session state.

## 25. Diagnostics and offline improvement

- Diagnostics are read-only views over the journal: SQL views in the schema (`v_requests`, `v_tool_calls`, `v_repairs`, `v_turns`, `v_cache`, `v_resources`) plus formatters. `nabla diagnostics [session] [--turn N] [--request N] [--metrics] [--export DIR [--artifacts]]`. Readers open read-only: no claim, no migration, no writes.
- Metrics, per session, per turn, and per successful turn: provider requests, attempts, retries by class, tool calls by outcome, validation failures, repairs and repair success rate, cache hit rate and coverage, input/output/cache tokens, latency distributions (first byte, request, tool, turn), subagent usage, hook interventions, failure categories, stop latency, peak RSS, retained bytes, idle wakeups, ratings.
- `nabla export --dataset DIR [--since T] [--rated]` writes per-turn trajectories as JSONL: snapshot digests, request sizes, calls with effective args, outcomes and repairs, usage, latencies, final response, ratings, assessments.
- Improvement is offline. A proposed change edits configuration or material files; the live harness sees it only as an ordinary snapshot, and the recorded digests attribute outcomes to the exact variant. The foreground never rewrites prompts, tools, rules, or hooks from its own observations.

## 26. Resource accounting

| Measurement | Source | Recorded in |
| --- | --- | --- |
| RSS and peak RSS | `/proc/self/status` `VmRSS`, `VmHWM` (reset through `/proc/self/clear_refs` value `5` at turn start) | `resource.observed` at turn end |
| process CPU | `getrusage(RUSAGE_SELF)` deltas | turn end; idle CPU is the delta over the preceding idle interval |
| job CPU | `clock_gettime(CLOCK_THREAD_CPUTIME_ID)` at worker exit | `tool.completed`, `subagent.completed` |
| child process CPU and memory | `wait4` rusage | shell and subagent completion |
| owner wakeups and idle wakeups | owner loop counters; a wakeup that applies no event is idle | turn end and session close |
| retained bytes | job arenas, stream buffers, encode cache, projection | turn end, with peaks |
| stop latency | cancel command to `turn.completed` | turn record |

Acceptance: an idle session shows zero idle wakeups over 60 s; a redraw-only TUI and a session of tiny answers keep flat RSS; after a large turn RSS returns within `IDLE_RSS_SLACK` of its baseline because large buffers lived in destroyed arenas.

## 27. Defaults

These values schedule work, size internal buffers, and time the harness's own threads. None of them limits what the model may ask for (section 2.1): no value here caps arguments, output, calls, requests, retries, scripts, or execution time.

| Name | Default | Kind |
| --- | --- | --- |
| `OWNER_EFFECTS_PER_PASS` | 64 | scheduling quantum; the rest run on the next pass |
| `OWNER_COMMAND_QUEUE` | 64 | frontend input buffer |
| `VIEW_QUEUE_BYTES` | 1 MiB | frontend buffer; overflow resyncs |
| `TRANSCRIPT_MAX_BYTES` | 1 MiB | TUI display memory; older lines reload from the journal |
| `SPINNER_INTERVAL` | 100 ms | redraw while busy |
| `BLOCKING_JOBS_MAX_RUNNING` | `max(4, core count)` | concurrency; excess jobs queue |
| `SUBAGENTS_MAX_RUNNING` | 4 | concurrency; excess children queue |
| `ACP_MAX_SESSIONS` | 8 | concurrency; excess sessions wait for a free owner |
| `RETRY_BACKOFF_CEILING` | 60 s | resend spacing |
| `STOP_PATIENCE` | 10 s | time to confirm a requested stop |
| `SHELL_KILL_GRACE` | 500 ms | TERM to KILL |
| shell timeout | 120 s | default when the model gives none; no maximum |
| read window | 2000 lines | default when the model gives none; no maximum |
| `TOOL_RESULT_INLINE_BYTES` | 64 KiB | journal row versus artifact storage |
| `TOOL_RESULT_HANDLE_TOKENS` | 64 | context reserved per later result in a batch |
| `LUA_SLICE_INSTRUCTIONS` | 10,000 | scheduling quantum |
| `LUA_HOST_RESERVE` | 64 KiB | host headroom inside a quota |
| `LUA_HOOK_MEMORY` / `_WALL` | 4 MiB / 100 ms | keeps the owner responsive |
| `LUA_CONFIG_MEMORY` / `_WALL` | 8 MiB / 1 s | keeps the watcher responsive |
| `LUA_META_MEMORY` / `_WALL` | 1 MiB / 100 ms | keeps the watcher responsive |
| `hooks.max_continues` | 3 | user setting for hook-driven continuations |
| `CONFIG_DEBOUNCE` | 100 ms | reload coalescing |
| `SKILL_INLINE_CATALOG` | 16 KiB | inline catalog versus `catalog_search` |
| `CATALOG_REFRESH_COOLDOWN` / `CATALOG_CACHE_TTL` | 10 min / 24 h | network use |
| `CONTEXT_WINDOW_ASSUMED` | 131072 | used only when the catalog has no window, and flagged |
| `COMPACT_KEEP_MESSAGES` / `_MIN_REDUCTION` / `_COOLDOWN` | 10 / 1024 tokens / 30 s | compaction policy |
| `ENCODE_CACHE_MAX_BYTES` | 16 MiB | cache memory |
| `JOURNAL_BATCH_RECORDS` / `_BYTES` / `_AGE` | 256 / 1 MiB / 1 s | write batching |
| `DIAG_RING_ENTRIES` / `DIAG_TEXT_MAX` | 512 / 512 B | diagnostic memory; overflow counts drops |
| capture per session / artifact retention | 64 MiB / 14 days | opt-in diagnostic disk use |
| `IDLE_RSS_SLACK` | 8 MiB | acceptance check |

A default changes only with a measurement from the journal or a benchmark test. A new entry that would cap model-driven work is refused by section 2.1.

## 28. Testing rules

- `owner_apply` and `owner_select` are tested with supplied events and clock values and no I/O: repeated selection, stale identities, cancel before every start, commit failure, retry and backoff, child-before-parent commit, exactly-once terminal.
- Integration fixtures count actual provider sends and tool executions for: failure before write, partial write, head then truncation, visible output, malformed completion, cancel during backoff, crash after each barrier (reopen and recover), abandoned worker, patch ambiguity, access conflicts, subagent kill.
- Lua: allocator-failure tests on every host entry, infinite loops, conversion edge cases, stop while waiting on children.
- Suites run with `ODIN_TEST_FAIL_ON_BAD_MEMORY` in release and `-debug`; tests pass explicit allocators where ownership is the subject.
- Tests assert outcomes and counts, not layouts, colors, or field order. Process-global state (signals, interrupt) runs in `test_isolate_process` children.

## 29. Current mechanisms this design replaces

| Current | Target |
| --- | --- |
| `agent/session` tables `turns`, `requests`, `entries`; JSON strings inside JSON | `agent/journal` records, nodes, branches; typed columns, one-level JSON `data`, exact `body` |
| JSONL run logs, segments, retention, `log_read` | journal records, diag ring, SQL views, artifacts |
| `chat_wake` condition broadcast, 64-slot mailbox, root 50 ms idle poll, TUI 50 ms poll | futex-sequence owner wake, per-job handoff with terminal slot, `ppoll` with eventfd |
| process-global `chat_cancel` reset per turn | per-turn and per-job `Stop`; the signal maps to the active session |
| orphan and `Self_Cleanup` job retirement | owner frees after join; abandoned jobs retained and the session poisoned |
| admission deadline plus a separate shell budget | one effective timeout from job start |
| 64 KiB tool-argument cap in `ai`; failed responses end the turn | no harness caps; unusable responses and refusals become `Notice` feedback |
| attempt counts, request caps, Code Mode instruction and wall limits, result retention caps | external limits only (section 2.1) |
| one native lane, serial Code Mode children | access-class scheduler, `job.start` / `job.wait` |
| JSON envelope for native results and Lua transport | typed `Tool_Args` / `Tool_Output`, rendered once at commit |
| `builtin_edit` old/new replacements | `builtin_patch` |
| instruction snapshot frozen per session | snapshot per turn from live config, digests recorded |
| `Chat_Observer` callbacks on the owner thread | `View_Queue` consumed by frontends |
| linear entries, no fork | session tree with branches and checkpoint nodes |
| no hooks, Tasks, rules, commands, subagents, ratings, policy | sections 14.2 and 18 to 24 |

## 30. Admission test for new features

A feature enters the core only with answers to:

1. Which records or nodes does it create or read?
2. Which Event, Effect, Job kind, or projection does it use?
3. Who owns its memory, in which arena, released when?
4. Which external limit (provider, model, protocol, OS) applies to it, and does it add none of its own?
5. When it fails, what feedback does the model receive, and how does the turn continue?
6. How is it cancelled, and what is its outcome when a stop is not confirmed?
7. What does recovery record if the process dies midway?
8. Does it keep provider prefix bytes stable, and if not, which recorded cause explains the change?
9. Which existing path does it reuse instead of adding a subsystem?
10. Which metric in section 25 does it improve?

If an answer needs a framework, a registry, a bus, a second loop, or a second history, simplify the design first.

Non-goals: generic workflow engine, plugin framework, service registry, event bus, recursive agent trees, prompt-only enforcement of deterministic rules, runtime self-modification, a second in-memory conversation store, HTTP/2 or HTTP/3, sandboxing inside the harness (use OS isolation), PTY terminals, LSP, browser automation.
