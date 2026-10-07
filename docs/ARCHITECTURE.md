# Nabla technical architecture

Status: target architecture. This is the implementation contract for the finished harness: its structure, responsibilities, data and execution flow, and constraints. Where current code disagrees, this document wins, and section 29 lists the known differences so that nobody copies them. Each rule has one home here: change it where it is written.

Terms: "must" is a hard rule, "default" is a named, tunable value. Every numeric default is collected in section 27. Section 2 decides which limits may exist at all.

## 1. Invariants

1. One owner thread mutates a live session and commits its durable state. Everything else produces observations.
2. Durable intent is committed before any external effect whose occurrence matters after a crash: provider send, tool start, Lua child start, Task start, subagent start.
3. No consumer (model request, Lua parent, frontend terminal report, next turn) reads a result before it is committed.
4. An effect that may have executed is never replayed automatically. Unknown is a recorded outcome, not a reason to retry.
5. Cancellation is intent, completion is an observation, commit is durability, retirement is proof that borrows ended. None substitutes for another.
6. The journal is the only execution record. Runtime tables hold in-flight work. Provider requests and frontend transcripts are projections.
7. Session history is an append-only tree. Nothing deletes, copies, or rewrites a committed node.
8. Validation, repair, policy, hooks, bounds, and journaling apply identically to direct calls, Lua children, Tasks, MCP tools, and subagents. No path is privileged.
9. Repair changes representation only, is unambiguous, and is journaled. It never supplies semantic intent.
10. Every live work item has an owner, a release point, and a cancellation path. Its limits are the external ones in section 2.1; the harness adds none.
11. Idle means zero periodic wakeups in every thread the process owns.
12. The model decides when its work is done. A failure the model can act on is fed back to the model and the turn continues (section 2.2). Only the model finishing, the user, or a model that cannot be reached ends a turn; an external failure never does.
13. Native data stays typed. JSON exists only at provider, MCP, ACP, journal payload, and export boundaries.
14. The resolved model catalog is the only runtime source of model facts.
15. Configuration is live. Admitted work keeps the immutable snapshot it was admitted with; new work uses the newest valid snapshot.
16. Only a main session creates subagents. Delegation depth is one.
17. The zero value of every runtime struct is inert: no owned resources, no pending work, unknown rather than false where the difference matters.
18. Behavior never branches on a model identity, and branches on a provider identity only as a last resort. It branches on the API family, a catalog fact, or what the provider reported (section 12).

## 2. Limits, failures, and resources

The harness gets out of the model's way. It adds no limit of its own, turns every mistake the model can correct into feedback for the model, and handles every other failure itself: it retries, repairs, or stops and tells the user.

### 2.1 Limits come from outside

A limit exists only when an external constraint imposes it: the provider or its API (request size, rate, error responses), the model (context window, maximum output), a protocol (a frame format, a JSON-RPC rule), or the operating system (memory, file descriptors, process limits). Nabla and its packages never invent a cap on tool arguments, tool output, calls per response, requests per turn, script size, instruction counts, or execution time. `http`, `sse`, `ai`, `mcp`, and `acp` report what the peer sent in full; they do not refuse data for being large. The one bounded schedule is the resend of a failed provider request (section 11.3): it is not model work, and a failure that outlasts it is not a passing one. A stream idle timeout exists only when the user configures one for a provider (section 11.3).

- A limit is data from its source: a catalog fact (`context_window`, `max_output`), a provider refusal classified by `ai`, or an OS error. A constant in source that caps model-driven work is a defect.
- The context window is the one limit the harness applies before sending, because it is the model's own. Large content is kept whole in a file and the model is shown a preview that names it (section 14.3); the bytes are never discarded.
- A timeout is a default the model may override with any value, never a maximum. A model-supplied timeout is honored as given.
- Internal buffers (journal batch, ACP writer queue) size memory, not work, and never refuse or truncate model-visible data.
- Hooks, config, and material metadata run user code on the owner or the watcher. Their wall-time bound (section 17) keeps those threads responsive; it is a system constraint on the harness's own threads, not a limit on the model.

### 2.2 Feedback goes to whoever can act

A failure is reported to whoever can correct it. The model is told about what it sent: a tool call, its arguments, or a response it cut short or malformed. Everything else, the request, the provider, the transport, the harness itself, is the harness's to handle: it retries, repairs, or stops (section 11.3), and the user is the one told. The model never receives a notice about a failure it cannot correct, and the work loop stops only when nothing is left to try without the user.

| Failure | Model | User | Turn |
| --- | --- | --- | --- |
| tool failure, invalid arguments, denial, timeout, unknown outcome | the typed result for that call (section 14.3) | the result | continues |
| repaired tool call | the result, naming what was repaired | the result | continues |
| response truncated at the output limit, or with defective calls | a `Notice` node saying what was wrong and that nothing ran | the notice | continues |
| response that filled the context window (`model_context_window_exceeded`) | a `Notice` node saying the window filled and that nothing ran, and a compaction request | the notice | continues; a context that still does not fit meets the overflow handling |
| transient provider or network failure, a stream cut off or unreadable, a failure nothing names | nothing | each retry and its wait | continues; the request is resent on the fixed schedule, then the turn ends |
| request the harness can repair: context overflow, payload too large, or an invalid request carrying optional features | nothing | the repair | continues after optional-feature resends or one checkpoint repair |
| authentication, quota, missing model, content policy, untrusted peer, an invalid request nothing can repair | nothing | the provider's message and what would fix it | ends |
| user cancel, storage failure, a response the harness could not hold | nothing | the reason | ends |

- Feedback is actionable: it names the failing call or response, the cause, the external limit with its value when one applies, and what was not executed.
- The request is the harness's, so a refusal of it is never the model's to fix. The harness decides from documented facts alone (status, the API's error type and code, the provider's retry headers), never from a guess about who caused it.
- A malformed call is feedback, not an error path: an unknown tool, arguments that are not JSON, a missing or mistyped field, or a value outside the schema returns a result that names the field, what was expected, and what was received, so the model can correct the call and retry.
- Every layer of the loop handles its failures: the state machine, the request path, tool dispatch, and each tool map an error to one row of this table. No failure escapes as a panic, an unhandled return value, or a silent stop.
- A notice is committed as a node, so resume, forks, and the cache see the same bytes.
- A failure recorded in the journal is always also visible where it matters: to the model when it can act, to the user when only the user can.

### 2.3 Resources

- Blocking waits only. Every waiting thread sleeps in a futex, `read`, `poll`/`ppoll`, `waitid`, or `thread.join` with either no timeout or a timeout equal to a real deadline. No sleep loops, no poll intervals, no heartbeat timers. The one periodic wake is the TUI spinner (`SPINNER_INTERVAL`), and only while a turn runs, because it animates visible progress; an idle process has none (invariant 11).
- Resident memory is the working set. Durable history lives in the journal and is loaded by bounded ranges. The conversation is read from the journal for each request (section 11.1) and released with it; the covering checkpoint bounds that read by the model window.
- Large transient data (request preparation, models.dev parsing, compaction snapshots, job output) lives in a `virtual.Arena` owned by that lifetime and is released with `virtual.arena_destroy`, which returns pages to the OS. Small long-lived data uses the heap allocator.
- Files follow the XDG Base Directory categories, each under a `nabla/` directory created owner-only (`agent/xdg.odin`). `$XDG_CONFIG_HOME` holds what the user writes (section 13.1). `$XDG_STATE_HOME` holds the journal, which is the session history and the logs, the two things the specification names as state. `$XDG_CACHE_HOME` holds what can be deleted at any time without breaking anything: catalog listings, which are fetched again, and kept tool outputs (section 14.3), whose loss only makes a later read of them fail. `$XDG_RUNTIME_DIR` holds what means nothing once its process exits: session claim locks (section 8.1). It is never used for large files, since it may live in memory. Nothing belongs in `$XDG_DATA_HOME` yet.
- Concurrency exists where work is independent and blocking or CPU-bound. Blocking jobs get a thread each, created on admission and joined on completion, bounded by `TOOL_JOBS_MAX_ACTIVE`. A CPU-bound native operation that splits into independent pieces creates a `thread.Pool` sized `min(os.get_processor_core_count(), pieces)` for that operation and destroys it before returning. No process-lifetime worker pool.
- An optimization stays only with a measured end-to-end gain (section 26). Complexity without one is deleted.

### 2.4 Robustness

The harness keeps running for as long as it reasonably can. Robustness comes first from prevention: small, simple, idiomatic code with errors as values has fewer places to fail. What still fails is contained to the work it touched, and the recovery for it stays proportionate.

- A non-critical failure degrades only its own work. A failed tool, request, hook, config reload, catalog refresh, MCP server, or subagent is recovered or reported to whoever can act (section 2.2), or recorded as a diagnostic, and the session and process continue.
- A worker that stops responding costs only its own resources. It is abandoned (section 7.2): its call reports `Unknown`, its memory leaks, and the session keeps admitting turns.
- No non-critical failure blocks the agent permanently. Every wait on another job ends when that job commits, times out, or is abandoned, and an abandoned job's worker slot and native lane pass to the next job that needs them. Letting new work take over from stuck work is preferred over holding the agent back.
- A thread is never killed. `thread.terminate` cancels at an arbitrary point, possibly while it holds a `sync.Mutex` or is inside an allocator, and `core:sync` locks have no owner-death recovery, so every later waiter would deadlock. Stopping is cooperative through `Stop` tokens (section 7.4).
- A lock guards only plain memory access. No `Mutex` is held across I/O, a blocking wait, a callback, or a call into Lua, SQLite, or another package, so a slow or stuck holder never stalls another thread. Data crosses threads by ownership handoff and atomics where they suffice.
- Threads share one address space, so a panic, failed assertion, bounds-check trap, or memory fault on any thread ends the process. No code tries to survive one in-process. The crash boundary is the child process: shell commands, MCP servers, and ACP subagents run in their own processes, and their crash is a tool result. Native subagents run in-process (section 21.1). A harness crash is answered by the journal, which recovers every session on its next open (section 9).
- A critical failure stops the work that depends on it and says why. Journal storage failure is critical because intent can no longer be committed before effects (invariant 2): it latches `Storage_Failed` (section 8.3).
- Recovery is written only when it costs less than the failure it handles. A rare failure whose recovery would need a new mechanism, a second state machine, or broad bookkeeping ends the affected turn, or the process, with a clear message, and journal recovery takes over.

## 3. Odin implementation rules

Write every package to the standard of Odin's own `core:` packages. Before writing a type or procedure, find the nearest `core:` package that solves a similar problem and copy its shape: names, signatures, error type, allocator parameter, `init`/`destroy` pairing, and doc comments. The rules below are project decisions on top of that; where `core:` does something more than one way, they pick one.

### 3.1 Data

- Concrete structs, enums, `bit_set`, enumerated arrays (`[Enum]T`), tagged unions, `Maybe(T)`, `distinct` integer IDs, slices, and small fixed arrays. Closed control domains use a union or enum with an exhaustive `switch`; `#partial switch` only where the ignored cases are listed in a comment.
- Zero is inert (invariant 17), not necessarily ready. A type that owns resources has an explicit `<subject>_init` (in place) or `<subject>_make` (returned value) and a `<subject>_destroy`, as `core:strings.Builder` and `core:container/queue` do, and destroying a zero value is a no-op. A type that owns nothing needs neither.
- Stable wire names use enumerated-array tables (`[Record_Kind]string`), never enum formatting.
- C types (`core:c`, `posix.FD`, `posix.pid_t`, `linux.Fd`, errno enums) stay inside the procedure or platform file that makes the foreign call. What that code exposes to the rest of the codebase uses Odin types (`int`, `bool`, `^os.File`, `os.Error`, a local enum), converted at that boundary.
- No `any`, `rawptr`, property maps, or string-typed fields where the shape is known. `rawptr` is confined to FFI (Lua, SQLite) and to procedure-pointer executor boundaries.
- No service locators, interfaces for single implementations, generic reducers, event buses, plugin lifecycles, or allocator wrappers per component. Procedure pointers exist only at real substitution boundaries: provider API family in `ai`, MCP backend, journal writer sink for tests, frontend output writer. A callback is a procedure value plus a `user_data: rawptr`, as in `core:thread`.
- Fixed-size temporary data uses fixed arrays (`[2]db.Value`), not dynamic arrays in scratch.

### 3.2 Errors

- Errors are trailing return values, in the form `core:` would choose for what the caller must decide. `ok: bool` when there is one way to fail (a lookup, a parse whose only failure is "not this form"). A package `Error` enum, first member `None`, when callers distinguish several local causes. `Error :: union #shared_nil { Local_Error, os.Error, mem.Allocator_Error }` when the package passes lower errors through. Propagate with `or_return`; default with `or_else`; branch with `or_break`/`or_continue` or an explicit check.
- Every error is handled: propagated, converted into feedback or a `Failure`, or acted on. Discarding one with `_ =` is allowed only in cleanup whose failure changes no outcome, such as closing a descriptor that is being abandoned.
- `@(require_results)` goes on every procedure that returns an error, an `ok`, or a value the caller must own or release, so the compiler rejects a dropped failure or a leaked allocation and enforces the previous rule. A cleanup discard is then written `_ =` with its reason. A procedure whose result is optional information, such as a count of bytes drawn, does not carry it.
- A harness failure recorded in the journal is `Failure :: struct { stage: Stage, kind: Failure_Kind, detail: string }` with the full `detail` the source reported. `Stage` names where it happened (Prepare, Encode, Admit, Send, Stream, Validate, Commit, Dispatch, Execute, Persist, Hook, Recover).
- A database error's message belongs to its connection: it is valid until the connection closes. A holder that keeps an error past that clones it with `db.error_clone`; the journal does so for the failure it latches.
- `assert` checks internal invariants in debug; `ensure` checks invariants whose violation would corrupt durable state. Neither handles input, transport, tool, or storage errors. No `panic` on external input.
- Allocation failure is an explicit error. This is stricter than much of `core:`, which may ignore it, and it is deliberate: the Lua quota allocator and arenas do fail, and a failure must become feedback rather than a corrupt result. An operation that builds an owned value uses a local, a `defer if !transferred { destroy(&value) }`, and sets `transferred` only after the owner accepts it. Empty success, zero-length success, and allocation failure are distinct.

### 3.3 Allocators and lifetimes

- Allocating procedures take a trailing `allocator := context.allocator`, or a required allocator when the result outlives the call. A procedure that returns an owning slice documents the allocator in the owner that frees it; callers free with `delete(slice, allocator)`.
- Borrowing is the default: a returned string or slice is a view into its argument or its owner unless the procedure takes an allocator. A procedure that allocates says so in its signature, and one that borrows says what the view's lifetime is tied to in its doc comment. Clone once, at the boundary where the borrow would end.
- Arenas are initialized in place at their final address before any allocator handle to them is created. An arena is never copied or moved after `arena_init_*`.
- `context.temp_allocator` is per thread and is reset by the loop that owns the thread, with `free_all(context.temp_allocator)` once per unit of work: each owner loop iteration (section 6.2), each item of a worker or frontend loop, and a thread's exit. Nothing allocated in temp survives that point.
- A procedure below the owning loop never calls `free_all` on the temp allocator, because its caller may still hold temp data. When it needs scratch that should not accumulate until the loop resets, it takes a scoped mark with `runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()`, passing `ignore = allocator == context.temp_allocator` when its result goes into a caller-provided allocator.
- An arena a procedure owns outright (a connection's arena, a job arena) is reset with `free_all` on that arena by its owner, independently of the thread's temp allocator.
- File buffers transfer ownership (`string(bytes)`) instead of cloning.
- Allocator resize uses `mem.resize` / `mem.resize_non_zeroed`, never allocate-copy-free.

| Lifetime | Allocator | Released |
| --- | --- | --- |
| Process (root state, journal connection, watcher) | heap | exit |
| Config and catalog snapshot | own `virtual.Arena` | last user releases (section 13) |
| Session (state, registry, projection) | heap, session allocator | session close |
| Turn (batch tables, turn scratch) | turn `virtual.Arena` | turn finish, after all turn jobs retired |
| Request chain (projection copy, encoded body) | chain `virtual.Arena` | after the last attempt job retired |
| Job (record, input copy, output) | process heap, never the session's allocator | job retire, or reclaim after abandonment |
| Lua execution | Lua allocator over heap with quota | execution end, after children retired |
| Owner loop iteration | `context.temp_allocator` | iteration end |
| Worker scratch | worker thread temp allocator | thread exit |

### 3.4 Context

- `context` carries only `allocator`, `temp_allocator`, and the random generator. Session state, cancellation, authority, and snapshots are explicit parameters. `context.user_ptr` is unused.
- Threads and C callbacks do not inherit the creator's context. Every thread entry and every Lua/SQLite callback sets `allocator` explicitly. Never copy the owner's whole context into a worker.
- The harness installs no `context.logger`. `core:log` calls in a library (the `http` packages) do nothing, and harness code never calls `core:log`. A process diagnostic is a `runtime.message` record (section 8.5).

### 3.5 Threads and synchronization

- `core:thread` for threads. The owner creates worker threads with `context.allocator` set to the owner's heap allocator, so the owner is the only thread that ever frees a `^thread.Thread`. No `self_cleanup` threads.
- `core:sync`: `Futex` for the owner wake, `Mutex` with `sync.mutex_guard` for plain critical sections, atomics for single-word flags and counters. Manual lock/unlock only where a procedure hands off ownership mid-scope.
- A condition broadcast is not a retained notification. Every wait uses a sequence or predicate that closes the check-to-sleep window (section 6.3).
- Signal handlers only perform atomic stores/adds and `sync.futex_broadcast` (both async-signal-safe). No locks, no allocation, no I/O.
- Operating-system access goes through Odin's portable packages first: `core:os` for files, processes, and environment, `core:sync`, `core:thread`, `core:time`, `core:net`, `core:nbio`, and `core:sys/posix` where POSIX covers the need. Linux is the only platform built today, and macOS and the BSDs are expected; a facility with no portable interface (`inotify`, `eventfd`, `pidfd_open`, `prctl`, `/proc`) is reached through a package-local procedure implemented in a `_linux.odin` file, so a new platform adds a file and changes no caller. No branches for platforms that are not built.
- The post-fork child path is allocation-free and lock-free: between `fork` and `exec` it makes only async-signal-safe `core:sys/posix` calls and leaves through `_exit`.

### 3.6 Serialization

- `core:encoding/json` at external boundaries only. Native tool arguments and outputs are typed structs. A Lua child's arguments are the one JSON path inside the process: they are written as JSON text because they are journaled as the proposed arguments and admitted through the same decoder as a provider call (section 17.1). Typed outputs are pushed to Lua directly.
- Canonical JSON (sorted keys, no insignificant whitespace) for everything that enters a provider request prefix: tool schemas and harness-generated JSON. Encoded once, stored as bytes, reused verbatim.
- Journal payloads are one level of JSON (a JSON object column, never JSON inside a JSON string). Exact external bytes (tool arguments as sent, provider replay items, rendered tool results, text) go in a `body` BLOB column.
- `core:crypto/hash` (SHA-256) for digests.

### 3.7 Source

- One subject per file, named for the subject; split a file when it holds a second subject, not when it grows. Platform code sits in `_linux.odin` (later `_darwin.odin`, `_bsd.odin`) files beside the portable file.
- Prefer the `core:os` and other `core:` abstractions. Code that needs raw system calls lives only in a platform file behind a small platform-neutral procedure surface, with an `_unsupported.odin` stub beside it, so a new platform adds one file. Portable files import neither `core:sys/linux` nor `core:sys/posix`, and no package imports `system:c`-backed `core:sys/posix` or `core:c/libc`. Constants the toolchain lacks, such as termios requests, are defined locally in the platform file.
- Every package has a `doc.odin` with the package overview. Naming and comment rules are in `AGENTS.md`.
- `mise run check` builds with `-vet -strict-style -disallow-do -warnings-as-errors`; code and examples in this document follow the same rules.

## 4. Package map

```text
foundation   text  markdown  input  term  layout  tui  tui/widgets
libraries    dns  tls  http  http/client  sse  websocket  subprocess  ai  mcp  acp  db  db/sqlite
harness      agent  agent/journal  agent/material  root package (nabla executable)
```

| Package | Owns | Must not contain |
| --- | --- | --- |
| foundation | text, Markdown parsing, input, terminal, layout, immediate-mode UI | anything about models, sessions, HTTP |
| `dns` `tls` `http` `http/client` `sse` `websocket` | protocols, transfer phases, byte and delivery facts | retries of model work, provider knowledge, harness logging policy |
| `subprocess` | starting a child in its own process group, exit watching, group termination (SIGTERM, grace, SIGKILL), readiness polling | what the child is for, pipes policy, output capture |
| `ai` | provider API families, encoding with caller-owned encode cache, stream decoding, failure classification, delivery evidence, one-send operations, Responses WebSocket connection | turn control, retry authorization, catalog policy, storage |
| `mcp` | MCP client protocol over stdio, delivery state | tool policy, naming policy |
| `acp` | ACP framing, JSON-RPC, payload shapes for both agent and client roles, writer | sessions, turns, Nabla concepts |
| `db` `db/sqlite` | engine-neutral SQL facility and the SQLite binding | harness record semantics |
| `agent/journal` | journal schema, record and node types, append/commit, claims, recovery queries, bounded reads, migrations | execution types from `agent`, model execution, filesystem discovery |
| `agent/material` | `.agents/` and user material formats: skills, rules, commands, Task metadata, frontmatter subset, bounded discovery, verified loads | sessions, models, permissions |
| `agent` | owner loop, state machine, jobs, tools, repair, policy, hooks, Lua runtime, Tasks, subagents, projection, compaction, catalog resolution, config parsing and validation | terminal, rendering, process-global UI state, file watching |
| root | process lifetime, signals, config discovery and file watching, catalog refresh thread, TUI, headless, ACP server, export command | a second copy of any `agent` policy |

Rules: dependencies point inward; only root imports both foundation and `agent`; `agent/journal` imports only `db`, `db/sqlite`, and `core:`; `agent/material` and `markdown` import only `core:`. `agent/material` replaces `agent/skills`. No further packages without a second consumer.

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
Digest       :: distinct [32]u8  // SHA-256 of one artifact's bytes
```

Zero means absent for every ID. IDs render as lowercase hex or decimal only at boundaries.

| Term | Meaning |
| --- | --- |
| State | what the owner currently knows (`Session_State`) |
| Event | one observed fact applied to state |
| Effect | one unit of work selected from state |
| Job | one bounded live worker thread: a tool call, a provider attempt, or a compaction (section 7.1) |
| Record | one journal fact |
| Node | one committed conversational step in the session tree |
| Task | one stored reusable Lua program |
| Tool call | one invocation of a registered capability |
| Subagent | one delegated execution in its own session: native in-process, or an ACP program in a child process |

## 6. Runtime

### 6.1 Threads and processes

| Thread or process | Count | Blocks in (idle) | Owns |
| --- | --- | --- | --- |
| main (TUI, headless, or ACP) | 1 | `poll(tty, wake eventfd)` (TUI), `read(stdin)` (ACP) | terminal or protocol stream, frontend state |
| ACP reader | 1 in `nabla acp` | `read(stdin)` | frame decoding |
| ACP writer | 1 per `acp.Writer` | `write(stdout)`, or its queue's condition when idle | the output stream |
| owner | 1 per live session | `futex_wait(wake.seq)` | `Session_State`, journal writes for the session |
| config watcher | 1 | `ppoll(inotify fd, shutdown eventfd)` | snapshot construction |
| session watcher | 0..1 | `ppoll(inotify fd, stop eventfd)` | owner wakes for shared sessions (section 8.6) |
| catalog refresh | 0 or 1, on demand, exits when done | network I/O | provider listing and models.dev fetch |
| job worker (tool call, provider attempt, compaction) | per session: 0..`TOOL_JOBS_MAX_ACTIVE` tool jobs, at most one attempt, at most one compaction | the blocking operation | its kind's record: input and output |
| MCP server | per configured server, started lazily | (external) | its own process, started and stopped through `subprocess` |
| native subagent owner | 0..`subagents_max_running` | as owner | its own session |
| ACP subagent | 0..`subagents_max_running`, shared with native | (external) | its own process and session |

An idle process has the main, owner, and watcher threads (plus the ACP reader) asleep in the calls above and nothing else. The table names the Linux mechanisms; another platform supplies its equivalents behind the same package-local procedures (section 3.5).

### 6.2 Owner loop

```odin
owner_run :: proc(owner: ^Owner) {
	for owner.state.lifecycle != .Closed {
		seen := sync.atomic_load(&owner.wake.seq)   // load before collecting: closes the lost-wake window
		now := time.tick_now()
		owner_collect(owner, now)                    // commands, job handoffs, snapshots, interrupt -> owner_apply
		performed := 0
		for ; performed < OWNER_EFFECTS_PER_PASS; performed += 1 {
			effect := owner_select(&owner.state, now) // reads state only: no clock, lock, I/O, allocation, counter
			if effect == nil {
				break
			}
			owner_perform(owner, effect)             // claim, then start or complete work
			owner_collect(owner, now)
		}
		journal_flush_due(&owner.journal, now)       // observation batch (section 8.3)
		free_all(context.temp_allocator)             // nothing in temp outlives an iteration
		if performed < OWNER_EFFECTS_PER_PASS {      // an exhausted quantum means work remains: loop without waiting
			owner_wait(&owner.wake, u32(seen), owner_nearest_deadline(&owner.state, &owner.journal))
		}
	}
}
```

- `owner_collect` turns external facts into typed `Event` values and calls `owner_apply(state, event)`. Apply checks identity (turn, request, attempt, job) and transition legality; stale events are dropped with a debug record and their payload is freed.
- `owner_select` is pure. `owner_perform` first applies a claim transition (for example `Send_Attempt` moves the attempt to `Claimed`), so repeated selection cannot launch twice.
- `owner_perform` never blocks on network, process, or filesystem I/O. Allowed blocking inside the owner: journal commit (fsync), owner-placed tools (journal reads), one Lua slice, one hook run. All are bounded.
- Effects are closed sets, and `owner_perform` switches exhaustively. In the code the sets are per subject. `Chat_Effect_Kind` selects the turn's next step (`Start_Request`, `Send_Attempt`, `Await_Provider`, `Wait_Retry`, `Repair_Context`, `Commit_Response`, `Run_Tools`, `Step_Tools`, `Wait_Tools`, `Finish_Tools`, `Turn_Finished`), and `Step_Tools` carries one `Tool_Job_Effect` (`Commit`, `Refuse`, `Abandon`, `Retire`, `Dispatch`, `Wait`, `Done`). Starting, retiring, and abandoning a worker is part of the effect that owns its kind, through the `Job` procedures of section 7.1; there is no separate `Start_Job`, `Retire_Job`, or `Abandon_Job`.

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

owner_wake_signal :: proc "contextless" (wake: ^Owner_Wake) {
	sync.atomic_add(&wake.seq, 1)
	sync.futex_broadcast(&wake.seq)
}

owner_wait :: proc(wake: ^Owner_Wake, seen: u32, deadline: Maybe(time.Tick)) {
	due, has_deadline := deadline.?
	if !has_deadline {
		sync.futex_wait(&wake.seq, seen)
		return
	}
	if left := time.tick_diff(time.tick_now(), due); left > 0 {
		sync.futex_wait_with_timeout(&wake.seq, seen, left)
	}
}
```

Every producer writes its fact first, then calls `owner_wake_signal`: job workers, the command queue, the watcher, catalog refresh, and the SIGINT/SIGTERM handler. Because the owner loaded `seq` before collecting, any publication after that load changes `seq` and the futex wait returns immediately. `owner_nearest_deadline` is the minimum of: running job deadlines, stop-patience deadlines, retry due time, Lua wall deadlines, compaction backoff, and the journal batch age limit when records are pending. With nothing pending it is `nil`.

### 6.4 Owner inputs

- Frontend commands: a mutex-guarded bounded queue (`OWNER_COMMAND_QUEUE`) of `Command` values. A full queue refuses the command to the frontend; it never blocks the owner.
- Cancel: `session.control.cancel_requested` atomic plus wake. Works with a full queue and from a signal handler (the process `interrupt` atomic maps to the active session's cancel).
- Job publication: section 7.2. Each job publishes through its own `published` flag and record, so terminal outcomes cannot be dropped.
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
	health:     Session_Health,      // Ok, Storage_Failed
	lifecycle:  Lifecycle,           // Open, Closing, Closed
	branch:     Branch_Id,
	head:       Node_Id,
	selection:  Selection,           // provider, model, effort; validated against the catalog
	config:     ^Config_Snapshot,    // newest adopted
	catalog:    ^Catalog_Snapshot,
	turn:       Maybe(Turn),         // at most one foreground turn
	jobs:       Tool_Jobs,           // the active batch's tool jobs; the attempt is in chain and compaction in compact
	abandoned:  [dynamic]^Job,       // abandoned workers of every kind, reclaimed when they publish (section 7.2)
	compaction: Compaction,
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
- `Stopping` latches one cause, refuses new work, requests stop on every job, and waits for commit and retirement or abandonment. User cancel wins the user-facing status; storage failure still latches `Storage_Failed`.
- Steering: a line typed while a turn runs is committed as a `user.input` record (barrier, text in the body) before the frontend acknowledges it, and becomes a `User` node with origin `Steering`, naming that record's seq, at the next settled boundary. A line committed but not delivered when its turn ends or the process dies is delivered before the next turn's prompt; recovery never starts a turn (section 8.6).
- `Finish_Turn` commits `turn.completed` (barrier), releases snapshot references, destroys the turn arena, and reports the turn's end to the frontend once.

## 7. Jobs and concurrency

### 7.1 Job record

Compaction, tool calls, and provider attempts each run one worker thread, and the three share one small record, `Job` (`agent/job.odin`). A kind embeds it as the first field of its own record, so a pointer to the record is a pointer to the `Job` and back. The `Job` holds only what every worker needs, and the kind keeps its own input, output, and commit step beside it.

```odin
Job_Phase :: enum u8 { Idle, Running, Retired, Abandoned }   // owner-only

Job :: struct {
	kind:      journal.Job_Kind,      // Tool, Provider_Attempt, Compaction, Subagent
	phase:     Job_Phase,             // owner-only
	run:       proc(job: ^Job),       // the worker body; job_main publishes after it returns
	allocator: mem.Allocator,         // the process heap: the record and every payload the worker reads or allocates
	thread:    ^thread.Thread,
	published: bool,                  // atomic; the worker's last write
	stop_at:   Maybe(time.Tick),      // the owner's first sight that the worker should stop
	record:    journal.Record,        // request, attempt, call, or subagent, for job.abandoned and job.reclaimed
}
```

The procedures are owner-only. `job_main`, the thread procedure, is private to `agent/job.odin`:

| Procedure | Does |
| --- | --- |
| `job_launch` | creates the thread with the watched signals blocked, starts it, sets `Running`; reports false when the thread cannot be created |
| `job_published` | atomic load of `published` |
| `job_note_stop` | records `stop_at` at the owner's first sight of a stop on a running job, which starts the patience |
| `job_overdue` | true once the worker has ignored its stop for `TOOL_JOBS_STOP_PATIENCE` |
| `job_stop_deadline` | `stop_at` plus the patience, for waits and `owner_nearest_deadline` |
| `job_wait_published` | waits on the owner wake until the worker publishes or a deadline passes |
| `job_retire` | asserts `published`, calls `thread.destroy`, sets `Retired` |
| `job_abandon` | sets `Abandoned`, records `job.abandoned`, and lists the job in `chat.abandoned` |
| `job_reclaim` | for each listed job whose worker has published: destroys the thread, records `job.reclaimed`, and releases the kind's record |

Each kind adds its own state:

- A tool job (`Tool_Job`) keeps its call, arguments, result, placement, and lane. A batch drives its jobs with its own machine, `Tool_Job_Phase` (`Queued`, `Dispatching`, `Running`, `Waiting`, `Result_Ready`, `Committing`, `Retiring`, `Retired`, `Unrecorded`, `Abandoned`), which says what step the call owes next, whatever its thread is doing. `tool_jobs_commit` records the earliest uncommitted result. A Lua parent is a tool job with `Lua` placement and no thread of its own: it runs as owner slices and waits on the child jobs it started.
- A provider attempt (`Chat_Request_Worker`) keeps the frozen request it borrows from the chain, an `Owner_Mailbox` of events, and a `terminal` (the operation error and the finish reason). The chain (`Chat_Request_Chain`) owns the rest: `chat_chain_settle` turns the terminal into the next stage (commit, resend after backoff, repair, or stop), and `chat_chain_commit` records the response. Retry and backoff belong to the chain, not to the worker (section 11.3).
- Compaction (`Compact_Job`) embeds the `Job` and keeps its snapshot, output, and usage. Its owner-side `Compact_State` (`Idle`, `Running`, `Ready`, `Backoff`, `Retiring`) says whether a summary is running, waiting to be installed, waiting out a backoff with no worker, or being stopped.

A subagent has a `Job_Kind` for the journal but keeps its own list and has not moved onto `Job`.

A job's record and payloads come from the process heap, never from the session's allocator, because an abandoned worker outlives anything the session releases. There is no job table with ids and no per-job arena. A tool batch owns a table of its `Tool_Job` records (`Tool_Jobs`), and a record is allocated individually, so its address is stable while the worker holds it.

### 7.2 Ownership protocol

1. The owner builds the kind's record, with its input and `allocator`, and commits intent. `job_launch` then creates the thread with the record as its data.
2. The worker runs `run`, which writes the kind's output into its own record: a tool result, an attempt `terminal`, or a compaction summary. `job_main` then makes the atomic `published` store, signals the owner wake (`owner_wake_signal`), and touches nothing after that. The owner reads the output only once `published` is set.
   A fact the worker cannot hand over, because an allocation for it failed, sets `lost` on the mailbox instead (`output_lost` on a compaction). Setting a flag cannot fail the way the handoff did, so the owner always learns of the loss: an attempt with a lost fact is an unusable response (section 6.5), never a complete one.
3. An attempt also streams events through its `Owner_Mailbox` before it publishes. A push signals the wake, and the mailbox mutex guards only the append and the owner's swap of the queue. The owner takes the publication first, then the events, then the terminal, so every fact the worker observed arrives before the decision.
4. The owner sees `published`, commits the result (barrier) as the kind requires, and calls `job_retire`. `thread.destroy` is the join, and it returns at once because the worker has stored `published` and touches nothing else. No owner or teardown path joins a worker that has not published.
5. A worker that does not publish within `TOOL_JOBS_STOP_PATIENCE` of the owner's first sight of its stop is overdue, and the owner abandons it. `job_abandon` records `job.abandoned` and lists the job in `chat.abandoned`; the kind first answers its own open work:
   - a tool call commits `Unknown`, saying the operation may still be running, and gives back its worker slot and, for the native lane, the lane, so later native work takes over;
   - an attempt is answered with the cancellation that asked it to stop, and it takes over the session's WebSocket if it was sending through it, so the next WebSocket request opens a fresh one;
   - a compaction closes its open send row as cancelled and frees the session's one compaction slot.

   The owner frees nothing the worker can reach: the record, its payloads, its thread handle, and the borrowed stop token. For an attempt that includes the chain's scratch arena, which holds the frozen bytes and the mailbox and moves into the attempt record when the chain is released.
6. Teardown waits the same patience, through `job_wait_published`, before it abandons: `tool_jobs_destroy` and `chat_compact_destroy` request every stop first, then wait out the remaining patience for each worker, and `chat_chain_release` does the same for an attempt it finds still running. Each retires the workers that publish and abandons the rest.
7. `chat.abandoned` is one session-wide list. `job_reclaim` runs wherever the owner observes (`chat_session_observe_at`, `chat_compact_poll`, `chat_compact_destroy`, and `chat_session_workers_outstanding`). When an abandoned worker has published, it records `job.reclaimed`, discards the result (the call already has its outcome), destroys the thread, and releases the kind's record. It leaves a tool job alone while its batch's table still holds it (`tabled`), and an attempt while the chain that abandoned it still holds it. If the worker never publishes, the memory leaks until process exit, which never joins abandoned threads. Session teardown does not wait for it: the list is deleted and the records stay allocated.

There is one lifetime rule: the owner frees job memory, and only after the join. No self-cleanup, orphan flags, or worker-side frees.

### 7.3 Scheduling

A tool call is placed by its tool definition (`Tool_Placement`) and its lane:

- `Worker` jobs run on a thread. At most `jobs.max_active` run at once, which is `TOOL_JOBS_MAX_ACTIVE` raised to the processor core count.
- `Owner` jobs run inline on the owner.
- `Lua` jobs are Code Mode parents. They run as owner slices, hold no worker slot, and never wait for a lane, so a parent waiting on its children cannot deadlock them.

A lane is a serialization domain: two calls with the same lane never run at once. Every native tool shares one lane (`lane` is nil). Each MCP server has a lane of its own, its client, because one stdio stream cannot serve two calls at once. A blocking subagent call is its own lane. Occupancy is derived from the batch's table, not counted: a lane is busy while one of its jobs is `Dispatching` or `Running`.

`tool_jobs_runnable` starts the earliest queued job whose lane is free and, for a worker, while a slot is free. A later job may start ahead of an earlier one that waits for its lane. Results are still recorded in submission order. An abandoned job gives up its slot and the native lane. An abandoned MCP lane stays held: a queued call on it is answered `Unavailable` and not executed, because the stuck worker may still be using that backend. Placement and lane come from the tool definition, never from MCP annotations or tool names.

Target: access classes (read, write, process, and similar) that let calls on overlapping paths run apart or in parallel by what they touch. They are added only when a measured gain justifies them (section 26).

### 7.4 Deadlines and cancellation

- The effective timeout is resolved once at admission: `args.timeout` when the model gave one, else `definition.default`, else none. There is no maximum. The clock starts when the job starts, not at admission. A timed-out job returns `Timed_Out` with its partial output, so the model can rerun it with a longer timeout.
- Outcomes distinguish `Timed_Out` (own deadline), `Cancelled` (turn or job stop), and `Unknown` (stop not confirmed).
- `Stop` is per turn and per job. Each token chains to the wider one that owns it: a job's stop to its turn's, the turn's to the front-end's control, and that to the process interrupt, so a check anywhere sees every stop above it without the owner relaying it. The turn outlives every job it owns, and no token is ever reset while work still reads it.
- A worker blocked in a wait wakes for its stop: the owner signals the job's wake pipe when it requests the stop, and the worker includes that pipe in the same `poll` as its I/O.
- Provider attempts receive cancellation, and a stream idle timeout only when the user configured one (section 11.3). No deadline or total-duration bound applies to an attempt or a compaction summary; model deliberation has no harness deadline. The patience of an attempt starts only when a stop is seen, and a wait on one has no deadline until then.

## 8. Journal

### 8.1 Contract

`agent/journal` is the durable execution record and the only home of SQLite knowledge. Core `agent` code calls its procedures; the package API is the storage boundary. There is no separate diagnostic log.

```odin
open           :: proc(journal: ^Journal, directory, locks: string, run: Run_Id, mode: Open_Mode, allocator := context.allocator) -> Error
close          :: proc(journal: ^Journal) -> Error
create_session :: proc(journal: ^Journal, new_session: New_Session) -> (Session_Id, Error) // claims new_session.id, or a fresh id when zero; buffers the row, session.created, session.claimed, branch 1
claim          :: proc(journal: ^Journal, session: Session_Id) -> (Counters, Error)        // exclusive flock per session; buffers session.claimed
release        :: proc(journal: ^Journal) -> Error
append_record  :: proc(journal: ^Journal, header: Record, data: $Payload, body: []u8 = nil) // buffered, owner-only
append_node    :: proc(journal: ^Journal, node: Node, data: $Payload, body: []u8 = nil) -> Node_Id
append_branch  :: proc(journal: ^Journal, base: Node_Id) -> Branch_Id
put_artifact   :: proc(journal: ^Journal, kind: string, bytes: []u8) -> Digest         // buffered; INSERT OR IGNORE by SHA-256
next_turn      :: proc(journal: ^Journal) -> Turn_Id                                  // also next_request, next_call
commit         :: proc(journal: ^Journal) -> (Journal_Seq, Error)                      // durable barrier; flushes the buffer
flush_due      :: proc(journal: ^Journal, now: time.Tick) -> Error                     // commits observations past a batch limit
flush_deadline :: proc(journal: ^Journal) -> Maybe(time.Tick)
read_records   :: proc(journal: ^Journal, filter: Filter, after: Journal_Seq, page: int, allocator: mem.Allocator) -> ([]Record, Journal_Seq, Error)
read_latest    :: proc(journal: ^Journal, filter: Filter, allocator: mem.Allocator) -> (Record, bool, Error) // the matching record with the highest seq
read_ancestry  :: proc(journal: ^Journal, session: Session_Id, head: Node_Id, allocator: mem.Allocator) -> ([]Node, Error) // stops at the covering checkpoint
read_last_node :: proc(journal: ^Journal, session: Session_Id, kind: Node_Kind, allocator: mem.Allocator) -> (Node, bool, Error) // newest node of a kind on any branch, e.g. a child's last Assistant text
read_artifact  :: proc(journal: ^Journal, digest: Digest, allocator: mem.Allocator) -> ([]u8, bool, Error)
session_head   :: proc(journal: ^Journal, session: Session_Id) -> (Branch_Id, Node_Id, Error)
last_delivered_message :: proc(journal: ^Journal, session: Session_Id) -> (Journal_Seq, Error) // highest subagent.message a User node delivered
usage_totals   :: proc(journal: ^Journal, session: Session_Id) -> (Usage_Totals, Error)
cache_hit_rate :: proc(totals: Usage_Totals) -> (rate: f64, measured: bool)
cache_coverage :: proc(totals: Usage_Totals) -> (share: f64, measured: bool)
list_sessions  :: proc(journal: ^Journal, filter: Session_Filter, allocator: mem.Allocator) -> ([]Session_Summary, Error)
list_branches  :: proc(journal: ^Journal, session: Session_Id, allocator: mem.Allocator) -> ([]Branch_Summary, Error)
recover        :: proc(journal: ^Journal, kept_directory := "") -> (Recovery, Error)   // the claimed session, one transaction
payload_decode :: proc(data: string, payload: ^$Payload, allocator: mem.Allocator, corruption_journal: ^Journal = nil, session: Session_Id = {}, seq: Journal_Seq = 0) -> Error // Corrupt on malformed data or unsupported version
error_text     :: proc(error: Error, allocator := context.allocator) -> string
```

Records and nodes are journal-owned plain data (strings, integers, enums). `agent` maps its execution types to them; `agent/journal` never imports `agent`. The identities of section 5 are declared in `agent/journal`, the innermost package that stores them, and `agent` uses them from there.

- The journal lives at `$XDG_STATE_HOME/nabla/journal.db`. Claims are `flock`s on `$XDG_RUNTIME_DIR/nabla/locks/<session>.lock`, which the kernel drops when the process dies; the files are never deleted by the harness, carry the sticky bit so periodic clean-up of the runtime directory skips them, and disappear at logout or reboot. When `XDG_RUNTIME_DIR` is not an absolute path, the specification's replacement rule applies: the locks go to `$XDG_STATE_HOME/nabla/locks/` and the launch prints a warning. Read-only journals take no lock directory.
- A `Journal` is one connection used by one thread at a time. The main thread opens, claims, and recovers it, hands it to the session worker for the run, and takes it back for teardown after the worker stops; a handoff happens only with no result set or transaction open. Each owner opens its own and claims one session. A follower of a session another process runs (section 8.6) opens a writable journal without a claim and appends only `user.input`; readers open `Read_Only` journals that never claim, migrate, or write.
- A main session is created by its first prompt, under an id chosen when the session opened, so a session nobody prompted is never recorded. Switching sessions opens the target in a second `Journal` while the running one stays claimed, and the running one is closed only once the target is claimed and recovered.
- `selection.changed` records carry no session: the latest one is the user's default model, provider, and effort for the next launch.
- The journal fills `time_ms`, `mono_ns`, and `run` on every record. The caller fills the correlation columns.
- `data` is encoded from a typed payload struct declared in `agent/journal`, one per kind, named after it (`Tool_Completed` for `tool.completed`). Records and nodes are copied into a batch arena at append, so the caller's memory is borrowed only for the call.
- The journal allocates `Node_Id` and `Branch_Id` at append, and turn, request, and call ids through `next_turn`, `next_request`, and `next_call`, all from the counters loaded by `claim`, so the owner continues numbering after a restart.
- Each node append also writes a `node.committed` record in the same transaction, and the node's `seq` is that record's seq. Branches (`branch.created`) and sessions (`session.created`) follow the same rule, so the records table is the one global order.
- `append_record`, `append_node`, `append_branch`, and `put_artifact` return no error. An encoding or allocation failure latches in `journal.failure` and is returned by the next `commit`. A failed commit rolls back and latches its cause the same way: the session is `Storage_Failed`, every later append is dropped, and every later commit returns that cause. The exception is another writer holding the database past the busy timeout (`error_is_busy`): nothing was written, the records stay pending for the next commit, and only the turn that needed the commit ends. Appending through a read-only journal or for a session the journal did not claim is a programming error and asserts.
- Corrupt or unreadable data returns `.Corrupt`, and the journal keeps the session and seq of the offending row in `journal.corrupt` for the message.

### 8.2 Schema

```sql
records(seq INTEGER PRIMARY KEY, time_ms INTEGER NOT NULL, mono_ns INTEGER NOT NULL,
        run BLOB NOT NULL, kind TEXT NOT NULL, session BLOB, branch INTEGER, node INTEGER,
        turn INTEGER, request INTEGER, attempt INTEGER, job INTEGER, call INTEGER,
        parent_call INTEGER, task TEXT, subagent BLOB, hook TEXT, provider TEXT, model TEXT,
        data TEXT, body BLOB) STRICT
nodes(session BLOB, node INTEGER, parent INTEGER, branch INTEGER, kind TEXT, turn INTEGER,
      covers INTEGER, seq INTEGER NOT NULL, data TEXT, body BLOB, PRIMARY KEY(session, node)) STRICT
branches(session BLOB, branch INTEGER, base_node INTEGER, seq INTEGER NOT NULL,
         PRIMARY KEY(session, branch)) STRICT
sessions(session BLOB PRIMARY KEY, created_ms INTEGER, workspace TEXT,
         parent_session BLOB, parent_call INTEGER, role TEXT) STRICT
artifacts(digest BLOB PRIMARY KEY, kind TEXT, created_ms INTEGER, bytes BLOB) STRICT
-- the schema version is PRAGMA user_version
```

- Every table is append-only. Mutable facts (title, active branch, selection, ratings) are the latest record of their kind. A branch head is the highest `node` on that branch.
- Indexes: `records(session, seq)`, `records(session, call) WHERE call IS NOT NULL`, `records(session, kind, seq)`, `records(session, node) WHERE node IS NOT NULL`, `records(session, request) WHERE request IS NOT NULL`, `nodes(session, branch, node)`.
- `data` is one JSON object per record, shaped by a versioned struct per kind (`version` field). `body` holds exact bytes. Queries use SQLite JSON functions over `data`; analysis needs no custom decoder.
- `body` holds what the model sees: a `User` node's is the user's text, an `Assistant` node's is the model's visible text, `tool.proposed`'s is the argument document exactly as the model sent it, `tool.admitted`'s is the arguments the tool runs with, `tool.completed`'s is the rendered result, and `response.committed`'s is the endpoint's native output items when it returned any. A `Checkpoint` node's body is its summary and a `Notice` node's is the feedback text. A Lua child's records carry a parent call and no node, so they never enter the projection or a `Results` node.
- WAL, `synchronous = FULL`, `busy_timeout`, private 0700 directory and 0600 files. A writable open narrows an existing directory or file with wider modes to these. Several processes share the file, and SQLite serializes their write transactions, so no other journal mode is needed. Each session has one claim, held by the process that runs its turns (section 8.6).
- Migrations are explicit steps stamped in the same transaction. A newer schema is refused. Corrupt or unreadable data is a typed error naming the session and seq; the harness never guesses.

### 8.3 Durability classes and write path

| Class | Kinds (examples) | Rule |
| --- | --- | --- |
| Barrier | `session.created`, `branch.created`, `user.input`, `request.sent`, `response.committed`, `tool.admitted`, `tool.completed`, `lua.started`, `task.started`, `subagent.started`, `subagent.message`, `*.completed`, `checkpoint.installed`, `hook.applied` (when it changes model input), `rating.recorded`, `selection.fit`, `selection.applied`, `turn.completed` | `commit` before the dependent effect proceeds |
| Observation | `run.started`, `run.finished`, `session.claimed`, `session.released`, `request.prepared`, `request.admitted`, `provider.observed`, `tool.started`, `retry.scheduled`, `retry.completed`, `compaction.started`, `job.abandoned`, `job.reclaimed`, `cache.observed`, `resource.observed`, `hook.failed`, `runtime.message` | buffered; written in the next barrier transaction or when the batch reaches `JOURNAL_BATCH_RECORDS`, `JOURNAL_BATCH_BYTES`, or `JOURNAL_BATCH_AGE` |

The owner is the only writer for its session, except that any process following it appends `user.input` (section 8.6). A commit is one short immediate transaction; no transaction spans a network operation or a wait. Results that publish together commit together. A failed commit latches `Storage_Failed`: admission stops, cleanup continues without the journal. A crash may lose buffered observations, never barriers.

The journal writes `session.claimed` itself when `claim` or `create_session` takes a claim, so every session, subagents included, records it, and `session.released` when `close` closes a journal that holds a claim, committed with every pending item before the claim drops. If that commit fails, `close` still releases and closes, and returns the commit failure only when nothing else failed. The owner commits `run.finished` just before it closes the journal, so a run's end is durable when the journal closes. `run.started` is buffered in the launch's first journal and reaches disk with that journal's first commit, and `session.claimed` with the commit after the claim: a resumed session's recovery, a new session's first prompt. A `run.started` with no `run.finished`, or a `session.claimed` with no `session.released`, reads as a process that ended abruptly. `tool.started` is recorded at the owner's dispatch, after `tool.admitted` is durable and before the executor begins, whichever thread the executor runs on.

### 8.4 Record kinds

`Record_Kind` is a closed enum with a stable-name table. Names are never changed or reused; new kinds are appended.

`tool.validation_failed` and `tool.repaired` are declared and never written, and their names are never reused: `tool.admitted` carries a call's repairs and `tool.completed` carries a validation failure's outcome and detail, so a record of either would state a fact twice.

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
runtime.message job.abandoned job.reclaimed
selection.changed selection.fit selection.applied
subagent.message
```

Every record fills the correlation columns that exist at that point: session, branch, node, turn, request, attempt, job, call, parent call, task, subagent, hook, provider, model. A record states one fact at the boundary that observed it, once. Summaries are computed by readers.

`turn.started` carries the digests of what the turn runs with: instruction snapshot, tool schema set, active rules, hooks, config snapshot generation, model, and effort. Offline analysis joins on these.

### 8.5 Diagnostics

A process diagnostic is a `runtime.message` record with a `level` (`warning` or `error`) and `text`. Only the thread that owns a journal writes one, through `chat_runtime_message`, and the record takes its session, turn, request, and time from the ordinary columns. Worker threads never write the journal: they report to their owner through the mailbox or the job result, and a failure the owner already learns that way, or that the user is already told, leaves no record. A failure before the terminal is taken, or one that has no journal to hold it, goes to stderr. There is no ring, no log level, and no payload capture; a statistics system reads the journal directly.

### 8.6 Shared sessions

Any number of processes may open the same session at once: several TUIs, ACP connections, and headless runs, in one person's hands or several. The journal is the queue between them, so none of them needs to reach another directly.

- Input: a follower commits the user's line as a `user.input` record, and that commit is the acknowledgment; the runner's own prompt starts its turn directly. Lines sent at the same moment are two records in seq order, and undelivered lines reach the model in seq order.
- Runner: the process holding the session's claim runs its turns and is its one owner (invariant 1). Turn, request, and call ids, recovery, compaction, jobs, and subagents stay the runner's alone, so two processes never run a turn of one session. With the session idle, an undelivered `user.input` committed after the runner claimed starts a turn; one older than the claim waits for the next prompt unless the claimant wrote it, so a takeover never runs a turn nobody is waiting for. A line that arrives during a turn is delivered as steering at the next settled boundary (section 6.5).
- Follower: a process that opens a session another process runs does not claim it, does not run recovery, and allocates no ids. It shows the conversation by reading the records after the last seq it saw, through the same observer callbacks a runner's frontend uses, and it appends only `user.input`. A follower sees whole messages and tool results as they commit, not streamed deltas, and shows the session as working between `turn.started` and `turn.completed`. Stopping a turn, answering a permission request, and changing the selection act only in the runner's process; a follower refuses them with a notice and never records a selection. Attachment captures the replay head, follow cursor, and queued inputs in one read snapshot, so catch-up neither repeats nor omits a line. Local quit and process signals detach a follower without waiting for the runner or cancelling its turn.
- Wake: after each commit, the committing process updates the timestamp of its open descriptor on the session's lock file (`futimens`), which raises `IN_ATTRIB` for every inotify watch on that file. Runner and followers each watch the lock file of every session they show, for `IN_ATTRIB` and for closes, from one watcher thread per process that waits in `ppoll` on the inotify descriptor and a stop eventfd and turns each event into an owner wake. The timestamp changes only after the commit returned, so a woken reader always sees it; the database's own files are never watched. A wake says only that the session changed or a claim dropped; the reader decides what is new by seq, and it arms the watch before its first read so no commit falls between them.
- Takeover: the kernel drops a dead runner's claim when its descriptor closes, which wakes every follower. Each follower then retries `flock` on the lock descriptor it already holds (reopening would raise close events for the others); the one that wins runs recovery (section 9), keeps its transcript, and becomes the runner with its own selection, and the others stay followers.
- `--resume`: no flag starts a new session, `--resume SESSION` opens that session, and `--resume` alone opens the newest main session for the directory, whether another process runs it or not. Opening a running session makes the process a follower. A subagent's session opens by its id like any other and is the same agent its orchestrator ran (section 21.4); `/resume` lists it under the main session that started it, indented, with the name that session's `subagent.started` gave it, and `/resume` takes its id or a prefix of it. Resume-latest never picks a child. A headless `--prompt` on a running session commits its line as a follower, waits for the `turn.completed` of the turn whose User node delivered it (the node's `message` is the line's seq), prints that turn's assistant messages to stdout and everything else to stderr, and exits 0 when the turn completed and non-zero when it did not. It never claims the session: when the runner's claim drops it keeps waiting for the next runner, and only an interrupt ends the wait early.

## 9. Recovery

On claiming a session, in one transaction:

| Durable facts found | Recorded outcome |
| --- | --- |
| `turn.started` without `turn.completed` | `turn.completed{Interrupted}` |
| `request.sent` without terminal | `request.interrupted`; never resent |
| `tool.proposed` (committed response) without `tool.admitted` | `tool.completed{Not_Executed}` |
| `tool.admitted` without `tool.completed` | `tool.completed{Unknown, "it may have taken effect"}` (roots and Lua children) |
| `lua.started`, `task.started`, `subagent.started` without completion | `*.completed{Unknown}`; scripts are never resumed. A native child whose session row was never created gets `subagent.completed{Not_Executed}`, since it never ran |
| `Assistant` node with calls and no `Results` node | `Results` node built from committed and recovered results |
| compaction output without `checkpoint.installed` | nothing; audit data only |

Every `Unknown` settled here, whatever rule settles it, also names with their sizes the kept shell stream files that exist for its call id under the session's tool-output directory (section 14.4), so the model can read the output produced so far. Then `session.recovered{counts}`. Recovery is all or nothing: a query or decode failure partway latches the journal's failure, so `close` writes none of the outcomes already staged and the session does not open; the next claim runs recovery again from the same facts. Recovery reconstructs history, not stacks: no replay of provider requests, tools, Lua, Tasks, hooks, or scheduled retries. Unknown results enter the projection as ordinary results, so the model sees the uncertainty. A native subagent's session is recovered by the same transaction when it is next claimed, which is when its orchestrator continues it with `agent_send` (section 21.4); until then it stays as its run left it. An ACP subagent whose parent died receives `SIGKILL` through `PR_SET_PDEATHSIG`.

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

The projection is rebuilt for each request: `read_ancestry` from the branch head back to the covering checkpoint, plus the records its nodes name, into the request chain's arena, which releases it with the chain. Nothing about the conversation stays resident between requests except the encode cache (section 23.4), so unchanged messages are not encoded again. The read is one indexed range per request; a resident copy kept in step with every commit would be a second source of truth, and it stays out until a measurement shows the read matters (section 2.3). The covering checkpoint keeps the read below the compaction trigger, so the model window bounds it.

### 11.2 Request layout

Deterministic order, placed by the `ai` encoder into the API's fields:

1. Instruction snapshot: base prompt, `AGENTS.md` sources, `always` rules, model-matched rules, material catalog metadata. Stored once as an artifact by digest.
2. Tool definitions of the turn's registry, sorted by name, schema bytes verbatim from the registry.
3. Ancestry projection in node order.
4. Transient suffix: hook guidance for this request, the compaction directive for compaction requests. Never part of history.

Parts 1 and 2 contain no timestamps, request ids, random ordering, or mutable lists. Tool definitions are encoded once per registry build. Unused skill and Task bodies never enter a request. The provider cache key derives from `Session_Id` only, so retries, branches, and reconnects share it. Legitimate prefix changes (snapshot adoption at a turn boundary, model or effort change, checkpoint install) are recorded with their cause in `request.prepared`.

Replay: provider-native opaque items (encrypted reasoning, signed or redacted thinking blocks, Responses output) are replayed only to the same API family, provider, and model recorded on the response; otherwise neutral text and calls are projected. Repaired calls project their effective arguments, never the original. Partial output is never projected as a complete message.

### 11.3 Chain, freeze, send

- `Prepare_Request` copies the projection and encodes into the chain arena, runs `request.prepare` hooks, checks capacity (section 23), then freezes: the encoded body is immutable for every attempt of this request.
- `Send_Attempt` commits `request.sent{attempt, body digest, sizes}` (barrier), then launches an attempt job that borrows the frozen bytes and streams its events through its mailbox.
- The owner forwards new stream bytes to the view queue as progress. Completion is validated (identities, count, argument sizes) before `Commit_Response` writes the `Assistant` node and `tool.proposed` records in one barrier.
- Recovery authorization lives only in `agent` (`agent/retry.odin`), and it is one table from the failure class `ai` names to one recovery: resend, repair, or stop. Order: end on cancel or storage failure; end on a response the harness failed itself; accept a validated completion, including one a later transport failure followed; then the class decides, overridden by the provider's `x-should-retry` directive where it gave one. The header is an SDK convention that the official OpenAI and Anthropic SDKs obey and neither API documents. `false` stops a retried class. `true` retries a stopped class only for not-found, never for quota, billing, authentication, content or refused-request classes, which OpenAI documents as not fixed by retrying.
- Resend: rate limited, provider or connection unavailable, a stream cut off or unreadable, a response the provider ended without a usable answer, and a failure nothing names. The same frozen bytes are sent again after each wait of the doubling schedule `CHAT_RETRY_DELAYS` (1 s, 2 s, 4 s, 8 s, 16 s: five resends over about half a minute), or after the provider's `retry-after` when it is longer; once the schedule is spent the turn ends. A resend is safe after the stream started: nothing in a response runs before it is committed, so the partial answer is dropped and the front-end closes what it showed of it.
- Stream idle timeout: a provider entry may set `stream_idle_timeout_ms`, the longest a response may go with no byte received. It is off by default (0): no provider documents an idle limit, and a long request or compaction summary can stay quiet for many minutes. Any byte restarts it, pings and SSE comments included, over HTTP and the Responses WebSocket, from the end of the request write; it never bounds total duration. On expiry the attempt fails as a cut stream (`Incomplete_Stream`) and the resend schedule applies.
- Repair: for context overflow or a payload too large, or for a request admission refused while a summary was still running, install a checkpoint (waiting for the running summary first) and rebuild once. For an invalid request carrying optional features, omit one feature per immediate resend in enum order: adaptive thinking, then cache hints (cache breakpoint, cache key, cache options). Every Messages API request asks for adaptive thinking, so a model that cannot take it costs one refused request per selection. A successful resend leaves each omitted feature out of later requests for the model selection. If the chain still ends with an invalid request after omissions, restore every feature omitted in that chain because none caused the final refusal. A background compaction does not resend: a refused summary request marks the feature refused and ends, the next compaction is built without it, and a later compaction still refused as invalid restores what compaction omitted.
- Overflow is recognized only from a documented error: `context_length_exceeded` (OpenAI and OpenRouter), or Anthropic's `prompt is too long` and `model_context_window_exceeded`. A `length` finish reason, or a Responses `incomplete` with `max_output_tokens`, always means the output limit. OpenRouter documents that its Responses API may turn `context_length_exceeded` into a successful `finish_reason: "length"`; that response cannot be told from a real output cut, so it is handled as one (a `Truncated` notice) and nothing guesses overflow from it.
- Stop and tell the user what failed and what would fix it: authentication, quota, a model the provider does not serve, content policy, an untrusted peer, an invalid request nothing can repair, and a spent schedule. The model is never sent a notice about any of these.
- Every retry is reported to the front-end as it is scheduled. The failed send's `response.rejected` row carries its evidence and recovery decision; buffered `retry.scheduled` and `retry.completed` observations mark the wait's start and its end (`resent` or `cancelled`). The wait is an owner deadline, not a sleep, and cancel ends it.
- Transport: per provider `http | websocket | auto`. `auto` uses WebSocket for APIs that implement it and falls back to HTTP for the affinity only on evidence that no model message was sent. The WebSocket connection is session-owned, used by one attempt at a time, and destroyed on affinity change or any unsuccessful operation.

### 11.4 Usage and cache accounting

`provider.observed` records input, output, cache-read, cache-write, and reasoning tokens, each with presence. Missing is unknown, never zero. Within one attempt the latest cumulative value wins; attempts sum. Every attempt's terminal record carries that attempt's usage and cost: `response.committed` for the accepted one, `response.rejected` or `request.interrupted` for one that failed or was cancelled, and `compaction.completed` for an accepted compaction summary, because a provider bills an attempt it answered whatever the harness did with the answer. Session totals sum all four kinds.

```text
paired_input = sum(input where input and cache_read are both reported)
paired_read  = sum(cache_read for the same rows)
hit_rate     = paired_read / paired_input
coverage     = paired_input / sum(all reported input)
```

Cost is priced once, when an attempt's terminal record is written, from the model's catalog price in US dollars per million tokens (section 12), and stored in the record as `cost`. Input counts include cache reads and writes in every API family, so the uncached share is `input - cache_read - cache_write`; a cache price the model does not state is charged at its input price. A response whose input or output count, or whose model's input or output price, is missing has no cost. Storing the price paid means a later price change never rewrites history. The session cost is the sum of the recorded costs, and a status that sums fewer responses than the session made says it is partial.

## 12. Model catalog

- Sources in precedence order: user configuration, provider discovery (`GET /models`, disk-cached), models.dev (disk-cached). A present higher-precedence value is final; only absence is enriched. False, zero, and empty are present values. Lists replace, never merge. `disabled` is a tombstone. Each price in `cost` is its own field, so a user who states only input and output prices still gets the cache prices from models.dev; in `config.lua` a model states `cost = { input = 3, output = 15, cache_read = 0.3, cache_write = 3.75 }`, any member optional.
- Identity is `(provider_id, model_id)`. API-family behavior lives in `ai`; the catalog carries data only.
- A difference between providers or models is expressed as data: a catalog fact the user can also set in configuration, or a classification of what the provider returned (status, error body, headers). Data takes effect on the next snapshot, with no rebuild and no new session. No code compares a model id, name, or name prefix.
- Provider-specific code is allowed only for a wire difference that neither an API family nor a fact can express. It stays in `ai`, is keyed on a named provider behavior rather than on scattered id checks, and carries a comment naming the difference.

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
	cost:           Cost,                    // USD per million tokens: input, output, cache_read, cache_write, each optional
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
| `$XDG_CONFIG_HOME/nabla/config.lua` (default `~/.config/nabla/`) | providers, credential references, models, MCP servers, external agents, policy, tool exposure |
| `$XDG_CONFIG_HOME/nabla/{skills,rules,commands,tasks,hooks}/` | user material and hooks |
| `~/.agents/skills/`, `~/.agents/AGENTS.md` | personal material |
| `<workspace>/.agents/{skills,rules,commands,tasks}/`, `<workspace>/AGENTS.md` | project material; `instructions.project = false` disables it |

Project definitions win over user definitions of the same name. No ancestor walk, no VCS inspection, no `.nabla/`. Hooks load from the user configuration directory only; repository files cannot install policy.

Top-level options in `config.lua` that tune the harness, each read at launch: `compact_on_switch` (boolean, section 23.3), `instructions.project` (boolean), and `subagents_max_running` (positive integer, default `SUBAGENTS_MAX_RUNNING`, the number of subagents that run at once, section 21.1). A value that is not of the stated type, or an integer below one, fails validation with `<option>: expected <type>, got <lua type>`, like every other option.

A provider entry may set `stream_idle_timeout_ms`, a non-negative integer, where 0 or absence means no timeout (section 11.3). It is read from the live catalog at each request.

### 13.2 Reload pipeline

1. The watcher holds inotify watches on every source directory and each discovered material directory; discovery skips a directory whose device and inode it already visited, so symlink cycles end the walk without a depth cap. `IN_CREATE` of a directory adds a watch. If the watch limit is reached, the watcher reports the degradation and reload falls back to the explicit `Reload` command.
2. Events are coalesced: after the first event the watcher waits for quiet with `ppoll` timeout `CONFIG_DEBOUNCE`, then rebuilds.
3. Build on the watcher thread in a fresh arena: evaluate `config.lua` (restricted Lua, section 17), discover material metadata, read instruction files, compile hooks, render the instruction snapshot, encode tool schemas, compute digests. Credential references resolve at connection creation, not here.
4. Validate completely. On failure the previous snapshot stays current and the view shows the error.
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

A `Tool_Definition` (`agent/tool.odin`) holds a tool's name, `Tool_Kind`, description, input schema, behavior hints, `Tool_Placement` (`Worker`, `Owner`, or `Lua`), default timeout, execute procedure, and, for an MCP tool, its adapter state and lane. `Tool_Kind` (`agent/tool_args.odin`) tells `tool_args_decode` which `Tool_Args` variant a call's arguments are read into; `Custom` marks arguments the harness does not read itself.

The registry is built, validated (names, schemas, collisions), and sorted inside the config snapshot, and is immutable. Advertisement, Lua `tools.*`, and admission read the same registry. Exposure filters (model without tool support, subagent scope, `tools.expose` in config) apply to advertisement and admission alike.

| Tool | Access | Placement |
| --- | --- | --- |
| `builtin_read` | Read(path) | Worker |
| `builtin_write` | Write(path) | Worker |
| `builtin_patch` | Write(paths) | Worker |
| `builtin_shell` | Process | Worker |
| `builtin_codemode` | None | Lua |
| `builtin_list_skills` | Session | Worker |
| `builtin_load_skill` | Read(skill file) | Worker |
| `agent_spawn` (main sessions only) | Read(all) or Process, by scope | Worker |
| `agent_send` | Session | Owner |
| `agent_stop` (main sessions only) | Session | Owner |
| `agent_status` (main sessions only, read-only) | Session | Owner |
| `context_compact` | Session | Owner |
| MCP tools `<server>_<tool>` | External(client lane) | Worker |

`catalog_search` and `task_run` (section 18) are not built. Each native tool's description and schema are constants in its own file (`TOOL_<NAME>_DESCRIPTION`, `TOOL_<NAME>_SCHEMA`), except the shell's description, which `tool_shell_description` builds for the shell the process runs. A description states what the tool does, when to use it instead of another tool, the exact shape of its result, and the facts a call gets wrong; each statement must match the code.

### 14.2 Admission pipeline

Every call, whatever its source, runs:

```text
decode (provider JSON or Lua value) -> validate -> [repair -> revalidate] -> hook tool.before_admit
  -> policy (allow | ask | deny) -> commit tool.admitted (barrier: effective args, repairs, access)
  -> hook tool.after_admit -> schedule (section 7.3) -> hook tool.before_execute -> start the job
```

- Decode: `args_from_json(kind, json.Value)` after a strict parse with duplicate-key checks produces `Tool_Args`. It is the only decoder: Lua children arrive as JSON text (section 17.1). `args_validate(kind, &args)` is the single semantic validator (paths, ranges, types). Argument size and nesting are not validated: the model's output limit is the only bound. MCP args stay a `json.Value`; the server validates their semantics.
- A call that fails any step gets a committed result (`Invalid_Arguments`, `Unavailable`, `Denied`, `Not_Executed`) and its siblings proceed. A defective response (missing or duplicate call ids, empty names) executes no call and becomes a `Notice` (section 2.2). There is no call count limit per response.
- Policy: config `policy.tools = { name = "allow" | "ask" | "deny" }`, default allow. The decision comes before admission, so a call waiting for it holds nothing durable beyond its `tool.proposed`. `ask` asks the frontend (TUI prompt, ACP `session/request_permission`). The permission wait belongs to the tool-policy feature, which section 29 lists as not built. The answer arrives as `Permission_Answer`: an allow commits `tool.admitted` with `asked = true`, a refusal commits `tool.completed{Denied}`. A crash while waiting leaves `tool.proposed` without `tool.admitted`, which recovery closes as `Not_Executed` (section 9). `tool.decision` is declared and never written.
- Cancellation is checked before `tool.admitted` is committed, not after: a call the turn stopped before admission completes as `Not_Executed` and leaves no admission that recovery would have to call `Unknown`.
- A Lua child commits before its result is delivered; a parent's result commits after all its children settle.

### 14.3 Results

- `Outcome`: `Success`, `Tool_Failed`, `Invalid_Arguments`, `Denied`, `Unavailable`, `Not_Executed`, `Transport_Failed` (proven undelivered), `Cancelled`, `Timed_Out`, `Unknown`. An outcome requires its evidence; lacking evidence it is `Unknown`.
- `Tool_Result :: struct { outcome: Outcome, failure: Maybe(Failure), output: Tool_Output, content: string }` lives in the job's memory until committed.
- The executor renders the model-visible bytes once with the tool's `render` procedure when it builds the result, while it holds the typed output. At commit the owner adds any repair note, applies retention, and stores those bytes in the `tool.completed` body. The projection uses the stored bytes from then on, so resume and cache stay byte-stable. Lua parents receive typed values converted from `Tool_Output`, never the rendering.
- Rendering format: first line `ok` or `error <kind>: <message>`, then tool-specific `key: value` lines, then a blank line and the raw body (file text, stdout and stderr sections). Raw text avoids JSON escaping inside provider JSON; the format is kept only while measured tokens per successful task confirm it.
- Retention: a result is never discarded. One larger than what the model is shown is written whole to `$XDG_CACHE_HOME/nabla/tool-output/<session>/<call>.txt`, which outlives the process so a resumed session can still read it. The journal stores the text the model was shown, so the file is non-essential: when the user clears the cache, a read of it fails as ordinary feedback. If the file cannot be written, the result is sent whole instead.
- Preview: the model is shown at most `TOOL_RESULT_PREVIEW_BYTES` of one result, cut at a line break, followed by a notice with the shown and total byte counts and the file path. For a `builtin_read` result the notice also gives the complete lines of the read that were shown and the `offset` that continues the file, taken from the result's `first_line`, so the model reads the next window of the original file. The model reads the rest of any other result from the kept file with `builtin_read`; there is no separate result-reading tool.
- Context budget: a batch charges root results in call order against the room left in the context, reserving `TOOL_RESULT_NOTICE_TOKENS` for each later result, and a result's preview shrinks to its allowance, down to the notice alone. The decision is stored with the result, so later requests project identical bytes.

### 14.4 Native tools

- Read: open once, `fstat` that descriptor; text only (no NUL, valid UTF-8); the model chooses the line window, and the result is projected through the context budget like any other.
- Write: validate, temp file in the same directory, write, fsync, rename; refuse symlinks and non-regular targets; keep the mode.
- Shell: `$SHELL -c` (fallback `/bin/sh` only when exec failed), fresh process group, stdin closed, inherited environment, async-signal-safe child path, one `poll` over both pipes, the child's exit handle, and the job's stop wake with the deadline as its timeout, TERM to the group then KILL after `SHELL_KILL_GRACE`, reap, exec failure distinct from exit 127, UTF-8-sanitized output retained whole: each stream is written as it arrives to `<call>.stdout.txt` or `<call>.stderr.txt` beside the other kept outputs, and held in memory up to `TOOL_STREAM_MEMORY_BYTES`. A stream that stayed within memory is whole in the result and its file is removed when the call ends; a larger stream keeps its file, named in the result, with only its beginning in the result. A call whose process ends mid-run therefore leaves the output it produced so far in those files, which recovery names (section 9). A file that cannot be created leaves its stream in memory. The timeout is the model's value when given, else the default; there is no maximum.
- MCP: one shared executor; one request at a time per client lane. Delivery state maps to `Transport_Failed` (not delivered) or `Unknown` (delivered, no reply). Non-text blocks are described, not dumped.

## 15. Deterministic repair

A call the model got slightly wrong is repaired whenever its intent has exactly one reading, and refused only when it has none or more than one. Repair is part of admission, not a per-tool feature: every call, whether from the provider, a Lua script, a Task, or MCP, passes through the same two places, so a new tool gets every repair by using the shared readers.

- Document repairs, in `tool_arguments_prepare`, run on the argument text before it is admitted: empty or `null` arguments are the empty object; a raw control byte inside a string literal is its escape; a document that is one JSON string whose content is an object is that object; a comma after the last value of an object or array is blanked with a space, which keeps every other byte in place so a remaining defect is reported where the model wrote it. A comma after another comma or after an opening bracket has no one reading and is refused. A Lua table always writes a well-formed document, so these only ever change provider text.
- Value repairs, in the shared field readers, run while a tool reads its declared fields, because only the reader knows the declared type: an integer field accepts a whole number within 2^53 and a string holding exactly one decimal integer (optional leading minus, no leading zero, nothing else). The reader writes the integer back into the document. For a tool whose arguments the harness does not read (MCP and custom tools), the registry reads the top-level fields whose schema type accepts an integer but neither a string nor a number, and admission applies the same repair to them; every other value travels as sent for the tool to judge.

Admission also refuses a number the parser cannot hold as written, an integer past the 64-bit range or a float that overflows to infinity, because the parser would otherwise wrap or saturate it and run the call with a number the model never sent.

```odin
Tool_Repair :: enum {
	Escaped_Control_Characters,
	Empty_Arguments,
	Double_Encoded_Object,
	Integer_From_String,
	Integer_From_Float,
	Trailing_Comma,
}
Tool_Repairs :: bit_set[Tool_Repair]
```

The set of repairs a call needed is committed with `tool.admitted` beside the effective arguments (today the dispatch record carries both), and no other record states it again: `tool.repaired` is declared and never written. When a value repair rewrote the document, the effective arguments are the document written again from the repaired value with sorted keys. Projection replays the effective arguments, so the model sees the corrected form. A repaired value then passes full validation, and policy and hooks run on it. A new repair joins the enum only if its input has one reading and every other input is still refused with its own defect.

The committed result of a repaired call names every repair it needed in a `repaired:` line after its first line, for every outcome, failures included. Projection shows the corrected arguments, so without this line the model would never learn it sent something wrong. A repair recorded only in the journal or shown only to the frontend does not count as reported.

Content repairs belong to the tool that knows the content, because they depend on the target file, and they are reported in that tool's output: a patch hunk that matches exactly one location when surrounding whitespace is ignored (section 16). Normalizing line endings to the target file's convention and reading loose patch formatting with one reading are content repairs of the same kind that do not exist yet.

Never: invent a missing argument, drop or rename an unknown field, pick a file, map an unknown tool name to a similar one, change a value that looks wrong, choose between two values of a repeated field, or bypass validation.

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
- Parsing accepts every form with one reading, because models of every size must be able to edit: text before the first file header and after `*** End Patch`, a missing envelope, a closing code fence or heredoc terminator, marker letter case, context lines without their leading space, added files without `+` prefixes, unified diffs (`---`/`+++` headers, `/dev/null`, `a/` and `b/` prefixes, `@@ -l,n +l,n @@`), and empty lines trailing a hunk. What has no single reading is `Invalid_Arguments` naming the line. A file header after `*** End Patch` is one of those, because a stray end marker would otherwise drop the sections after it without a word.
- Per file: read the current bytes and locate each hunk's old lines (context plus removed) in the whole file, at three levels tried in order: exact, ignoring trailing whitespace, ignoring surrounding whitespace. At the first level with any match, the candidates are narrowed by each hint that leaves at least one: after the previous hunk, after the `@@` anchor, at the end of the file for `*** End of File`, and at a unified diff's old line number. Exactly one candidate must remain; several fail the hunk as ambiguous. Hints never reject a unique match, so an anchor that is wrong or hunks out of order still apply. A hunk matched by ignoring indentation has its added lines moved to the file's indentation. A hunk with only added lines goes after its anchor, at its line number, or at the end of the file. Hunks may not overlap.
- `Update File` of a missing file whose hunks only add lines creates it.
- Unchanged lines keep the file's bytes, added lines take the file's line ending, and a file without a final newline keeps it that way.
- A path may appear in one section only, counting `Move to` targets.
- All files are computed in memory first. If any hunk fails, nothing is written. Writes then go file by file through temp-plus-rename. A rename failure after earlier renames reports `Tool_Failed` with the list of applied files, because POSIX has no multi-file atomicity.
- A malformed patch is `Invalid_Arguments` naming the first bad line. A patch that does not apply is `Tool_Failed` naming the file, hunk index, reason (`not_found`, `ambiguous{count, lines}`, `overlap`, `file_missing`, `file_exists`, `repeated_path`, `not_writable`, `unreadable`, `invalid_path`), and the nearest candidate lines, or that the hunk's new lines are already present, so the model can correct without rereading the file. The result counts hunks that matched only by ignoring whitespace.

## 17. Lua runtime

One embedded `vendor:lua/5.4` runtime serves Code Mode, Tasks, hooks, config evaluation, and Task metadata. Each execution gets a fresh state; states are never shared or pooled.

| Profile | Memory | Run bound | Capabilities |
| --- | --- | --- | --- |
| Code Mode | system memory | the model's `timeout_ms`, else none | `tools.*`, `job.*`, `print`, `json.*` |
| Task | as Code Mode | as Code Mode | as Code Mode, plus `args` |
| Hook | `LUA_HOOK_MEMORY` | `LUA_HOOK_WALL` | its input value only |
| Config | system memory | `CONFIG_INSTRUCTIONS` VM instructions | `os.getenv` only |
| Task metadata | `LUA_META_MEMORY` | `LUA_META_WALL` | none |

Code Mode and Tasks run model-written programs, so they carry only external limits (section 2.1). Hooks, config, and metadata run user code on the owner or the watcher, so their quotas keep those threads responsive.

- Libraries by allowlist: base without `load`, `loadfile`, `dofile`, `require`, `collectgarbage`, `warn`; `string` without `dump`; `table`, `math`, `utf8`; `os.clock`, `os.date`, `os.difftime`, `os.time`. No `io`, the rest of `os` (config gets `getenv` only), `package`, `debug`, `coroutine`: files and processes are reached through tools, and a script coroutine would receive the host's yields. Hooks, config, and metadata keep the narrow set without `setmetatable`, `pcall`, or `os`.
- `setmetatable` refuses a metatable with `__gc`, because a finalizer runs with hooks off and again when the state closes. Every other metamethod runs as script code under the count hook, and the host reads values raw, so it never runs script code.
- Allocator: `lua_Alloc` over the heap using `mem.resize_non_zeroed`, accounting live requested bytes. Profiles with a memory quota check a resize against `live - old + new`; Code Mode and Tasks have none, so only an OS allocation failure refuses. Refusal returns nil as Lua requires; shrinking never fails. `LUA_HOST_RESERVE` is added while the host pushes values.
- Scheduling is suspension: a count hook yields every `LUA_SLICE_INSTRUCTIONS` so the owner stays responsive; the owner checks stop, deadlines, and quotas between slices and never resumes a stopped run. Where the script cannot yield (inside a C call such as a `table.sort` comparator), the hook raises once the run should stop and then fires on every instruction, so a `pcall` that catches the raise ends at its next yield. The slice size is a scheduling quantum, not a limit on work. Every allocation-capable host entry runs protected. Callbacks hold no Odin resources that depend on `defer`.
- The count hook sees Lua instructions only. One library call (`string.rep`, `table.concat`, a pattern match) runs to completion inside its slice, bounded by its own input and, for the quota profiles, by the memory quota. This gap is accepted; preempting C code would need a second mechanism that costs more than the rare long call.
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
- A script may hold any number of unfinished children. They queue in the batch's job table and run as their lanes and `TOOL_JOBS_MAX_ACTIVE` allow.
- When a script ends with unconsumed children, they are stopped, awaited, and reported in the parent result. A background `agent_spawn` (`wait` left false) is not stopped: its call returns at once, and the subagent it starts outlives the script, so `job.start` without `job.wait` is enough to start one.
- `builtin_codemode` and `task_run` are not callable from Lua (nesting depth one). `agent_spawn` is callable from Lua in a main session.
- A refusal the script can fix (an unknown tool name, which lists the tools; a bad handle; arguments that are not one table of named fields; a nested `builtin_codemode`) is a Lua error at the calling line, which `pcall` can catch. Reading a name that is not a tool from `tools` raises the same error; `rawget(tools, name)` tests for one.
- The owner never pushes onto a suspended script. It records an answer (a handle, a kept result, or an error message), and the host function's continuation pushes it inside the resume, where a Lua error is caught. A committed child result is built into a Lua table under `lua_pcall`, so a lack of memory fails the parent as `out_of_memory` instead of aborting. Host callbacks allocate from a per-run scratch arena reset after each resume, because a Lua error unwinds them without running defers.
- Value conversion is one checked walk over the Lua value that writes text directly: a Lua literal for the returned value and `print`, JSON for a child's arguments (admitted through section 14.2 like a provider call) and `json.encode`. It accepts finite numbers; UTF-8 strings; dense 1-based arrays; string-keyed tables, written in name order; the `json.null` sentinel. Cycles, sparse or mixed tables, functions, threads, and userdata are refused with a bounded path. Raw table access only. `json.decode` and a tool output's typed fields are pushed as Lua values without an intermediate document, except a field that holds a peer's JSON.
- Parent result: the return value, the print log, and the child list, projected through the context budget like any tool result; or a typed failure kind (`syntax_error` with line and message, `runtime_error` with the message as the result message and the traceback as its own section, `invalid_value` with the value path, `out_of_memory`, `cancelled`, `timed_out`) with the print log and the list of children already executed. A non-string error value is written as its Lua literal. Every failure is returned to the model, which may fix the script and run it again.

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

### 21.1 Native foundation

`agent_status` observes without entering the child's conversation or changing its work. With no `agent` it lists each child's stable name, status, and session id. With a name it reports status, session, the provider/model/effort of the last turn, the newest journal record and its age, the last turn outcome and failure, the last committed Assistant text marked partial when applicable, and unread messages. A finished native child includes the exact `agent_send` call that resumes it. Unknown names list known children. The age helps tell a slow child from a stalled one. This is a separate read-only owner-placed tool because observation must not send a message to the child, and journal-backed lookup works for children no longer in memory. Status and continuation share one scan of the parent's delegation records.

A native subagent uses Nabla's provider catalog, request state machine, and agent loop. Native children run in the parent process, each as the owner of its own session. A panic or memory fault in one ends the process, and journal recovery restores every session (section 2.4); a process per child would add a protocol and a supervisor to handle a failure that recovery already covers. Section 21.3 covers subagents that are other ACP programs.

`agent_spawn{instruction, prompt, model?, provider?, effort?, wait?}` creates a fresh child session. `prompt` is required, and the model normally passes only `instruction` and `prompt`: the defaults are the parent's model, one effort level below the parent's, and a background run. The child receives its own instruction and task, the shared harness instructions, and instructions discovered in the workspace. It inherits neither the parent's conversation nor its client-specific instructions. The caller must supply everything else the child needs or tell it where to find it. There are no agent definition files.

An omitted model inherits the parent's selection. A model override resolves through the live catalog; `provider` disambiguates providers. An omitted effort and an effort the selected model does not state take the same path: the child runs one level below the parent's effort, and the lowest level stays where it is. When the child model lacks that level, the next lower level both models state is used, and failing that the child's lowest level. A child thinks whenever its parent does; only a parent without effort, or a model that states no levels, leaves the provider default. An unsupported effort is reported in the call's result as a repair.

Each child has its own store connection, session, instruction snapshot, request state, and tool registry. Its provider requests carry `x-parent-session-id` and use the parent session's cache key. The shared harness instructions remain a common prefix. Child registries exclude `agent_spawn`, `agent_stop`, and `agent_status`, including access through Code Mode. Their executors also reject child callers. Delegation has one level.

A call runs its child in the background unless it sets `wait`: it returns an agent id at once, `agent-<spawn call id>` with the call's decimal id in the parent's session, so the name is stable across restarts, the child runs in parallel with the parent, and its final answer reaches the parent as a journal record delivered like steering. A call with `wait` blocks and returns the child's final answer. Every `agent_spawn` result, started or waited, carries the child's Nabla session id as `session` (the hex of its `Session_Id`), so the orchestrator can find the child's journal; an ACP child's own session id is the separate field `acp_session`. At most `subagents_max_running` children run at once (default `SUBAGENTS_MAX_RUNNING`; a Lua option read at launch and copied with the orchestrator's parent state, so a spawn uses the value its orchestrator holds): a background child beyond the bound is queued, reported as `queued`, and started in spawn order as a slot frees, and stopping it before it starts reports it stopped without running. A `wait` child runs at once on its caller's worker and counts toward the bound, since its caller already holds a tool slot. `agent_send{agent?, message?, model?, provider?, effort?, compact?}` lets the parent address a child and lets a child message its parent; sibling delivery is refused, and `model`, `provider`, `effort`, and `compact` are the parent's. `message` is required unless `compact` is true. Messages follow steering: each enters context at the next settled boundary, and one recorded after the final answer continues the turn. The parent controls a running child as the user controls the main session. A selection is resolved at dispatch with the rules above, so a name that does not exist is refused and records nothing, and is held as the child's one pending control under `team.mutex` together with a compaction flag; the newest selection replaces an unapplied one, and the call's result says what was queued. The child's turn takes the control through a `Steer_Context`: `observe` copies the compaction flag under the lock and, outside it, makes the same `.User_Command` compaction request as `/compact`, and `apply` runs the main session's selection service at each request boundary, and again before the child accepts its next message. That is `chat_selection_check` (fit check, `compact_on_switch`, recheck after the compaction installs) and then the install of the main session's `selection_install` (`chat_session_select`, compaction cancelled and the WebSocket session dropped on a changed serving identity, `selection.applied` recorded). The frozen request keeps its selection. The selection a switch replaces is retired with the member, not freed, because a request or summary in flight may still read its connection. A switch the fit check refuses after dispatch is reported to the parent as a `subagent.message` from the child, so it reaches the parent's inbox like any other child message. A child never closes its inbox. When a background child completes, the reap that records its outcome first reads the child's inbox past its last delivered message; one that arrived after the child's last read reopens the same record on a new thread with the same `parent_call` and no completion, so no message is lost. A failed or stopped child, a `wait` child, and an ACP child are not reopened that way, and the message waits in the journal for the child's next resume. A send to a child that has finished reopens its session instead of being refused (section 21.4). `agent_stop` requests cancellation and the child reports its stopped outcome. A background child never holds its parent: only `wait` blocks. The TUI and an ACP V2 client start a turn for a child report while idle, after any queued user input. An ACP V1 prompt is answered when its own turn ends; V1 cannot carry a turn the client did not request, so reports wait in the journal for the next prompt's turn. A report committed before this process claimed the session waits for the next prompt too, so recovery never starts a turn. Headless waits for outstanding children before it exits, since exiting would lose their reports.

The team owns the parent snapshot and child records. Teardown closes admission, requests cancellation, and waits using the existing worker stop patience. Unresponsive workers and everything they may reach stay allocated until process exit. A child whose own workers were abandoned is still reaped: its completion is recorded and it leaves the team, but its record is not freed, because those workers may still reach it, and it is never reopened. Abandonment remains visible after session teardown so callers do not free shared tool backends. Shared MCP clients refuse overlapping requests, and backend refresh waits until child and abandoned workers no longer use the bindings. Concurrent native children share the workspace; this stage does not provide access scopes or serialize conflicting file edits. Until it does, the prompts carry the rule: the `agent_spawn` description tells the parent not to redo delegated work, to give concurrent children disjoint files, and to tell each child that others share its workspace, and the subagent role tells a child to edit only its own files and to leave changes it did not make alone.

### 21.2 Required later work

- Coordination through the journal. Child start, messages, and outcomes become journal records committed before their effects (invariant 2), so a crash loses no report or message: recovery settles each child the dead process ran, and its outcome reaches the parent's model like any report. The queue of children waiting for a slot stays in memory, because their `subagent.started` records already name them. The protocol:
  - The child's `Session_Id` names the delegation and fills the `subagent` column of every record about it; an ACP child gets one too, though it has no Nabla session. The parent's owner chooses it and commits `subagent.started{name, program, provider, model, effort, background}` (as the call asked; `name` is the agent id the call returns; `background` is true unless it set `wait`) with the child's instruction in `body`, so the record alone defines the child, in the same transaction as the call's `tool.admitted`; the child passes the same id to `create_session` with `parent_session` and `parent_call`. A call that starts no child commits `subagent.completed{not_executed}` with its result. An `agent_send` that reopens a finished child commits a further `subagent.started{name, provider, model, effort, background: true}` for the send call, with the child's instruction in `body` and the same child `Session_Id`, in the barrier of that call's `tool.admitted`, followed by the call's `subagent.message`; provider, model, and effort are what the send named, "" where the child keeps its last turn's. The delegation it opens is paired with its own `subagent.completed` by call id, like the first.
  - A message is a `subagent.message` record in the sender's session, with the text in `body` and the child's name, committed with the call's `tool.admitted`, before the receiver is woken.
  - A session's inbox is `read_inbox(session, after)`: its own `user.input` records, the background `subagent.completed` records of its children (a completion whose spawn call already reported a failure is skipped, since the call's result told the model), and the `subagent.message` records sent to it, in seq order after `last_delivered_message`. The owner delivers each as a `User` node (origin `Steering` for `user.input`, `Agent` otherwise) whose payload names the record's seq, at a settled boundary. Delivery commits with the node, so a restart neither loses nor repeats an item.
  - The parent commits `subagent.completed` for its call whatever the outcome: `outcome`, the turn's cause in `detail` (empty on success), and in `body` the text of the child's last committed `Assistant` node, read from the child's session when its run ends. That is the final answer on success; for a failed or stopped child it is the partial text its failed turn kept (a `partial` node) or, when that turn streamed none, the last text it committed before. The report the parent's model reads (`inbox_text`) names the child, its session id, the cause, and that text, and a `wait` result carries the same `session`, cause, and text. A parent's children are `list_sessions(Session_Filter{parent = parent})`.
  - Threads wake each other through the owner wake after the commit; nothing polls the database.
- Access and policy. Child permission requests, ACP ones included, should reach the parent's `tool.before_execute` hooks and policy, and children may get access scopes such as read-only.
- Workspace isolation. Children that write need their own workspace so concurrent edits cannot collide. The mechanism (a Jujutsu workspace, a Git worktree, or another copy) and how a child's changes return to the parent are still open. Until then children share the parent's workspace.

### 21.3 ACP subagents

Any program that speaks the Agent Client Protocol can run as a subagent. No program is named in code. The user lists the programs in `config.lua`, each under a name with its command (an absolute path or a name found on `PATH`), the arguments that start it in ACP mode, and an optional description:

```lua
agents = {
	goose = { command = "goose", arguments = { "acp" }, description = "Goose, general coding agent" },
}
```

The `agent_spawn` description lists the configured names and descriptions, so the model discovers them without another call, and `acp_agent` names the one to run. An unknown name fails the start with the configured names. Without `acp_agent` the subagent is native (section 21.1). Everything else is shared: background and waiting runs, reports, steering, stop, and one delegation level.

- Process: private process group, `PR_SET_PDEATHSIG = SIGKILL` bound to the supervising thread, which lives until it reaps the child. stdin is one end of a Unix socket pair written with `MSG_NOSIGNAL`, so an agent that exits cannot raise `SIGPIPE` here. stdout carries ACP frames. The end of stderr is kept to explain a failure.
- One thread drives the connection. It sends one request at a time and reads until the answer, handling notifications and agent requests in between. JSON stays at this boundary: every message is decoded once into typed structs.
- Versions: `initialize` asks for version 2 and accepts 1. An agent that answers version 2 in version 1's shape, without `info`, is treated as version 1. Version 1 ends a turn with the `session/prompt` answer's `stopReason`. Version 2 acknowledges the prompt and ends the turn with an idle `state_update`, and a `stopReason` in the acknowledgement is also accepted.
- Session: `session/new{cwd, mcpServers: []}`. The client offers no file system and no terminal; the agent uses its own tools. `model` picks a value of the `model` config option by value or name, or a model from the pre-standard `models` list; a model the agent does not offer fails the start with the models it does offer. Effort follows section 21.1 against the `thought_level` option's values. When the agent shares no level with the parent, the agent's default stays, because its lowest level may turn reasoning off. `session/set_config_option` sends `configId`, and `type: "id"` in version 2.
- Answer: the text of the agent's latest message after its last tool call. A new `messageId` or a tool call starts it over, and a whole-message update replaces it. The program has no Nabla session, so no committed node holds it; `session` in a result is the id the delegation uses, and the agent's own session id is `acp_session`.
- Permissions: `session/request_permission` is granted once (`allow_once`, else `allow_always`), as a native subagent runs its tools without asking. After a stop it is answered `cancelled`. Other agent requests get method-not-found.
- Messages from the parent are sent as the next prompt once the current turn ends, since ACP has no way to add input to a running turn.
- Stop: `session/cancel`, then the stop patience for the turn to end, then `SIGTERM` to the group, the kill grace, `SIGKILL`, and reap.
- Continuation: `subagent.completed` records the agent's session id as `acp_session`, its selected model and effort, and the last consumed inbox sequence. `agent_status` shows the external session id. `agent_send` restarts the program and initializes it, then uses `session/resume` in version 2 or when version 1 advertises `sessionCapabilities.resume`. Otherwise version 1 uses `session/load` only when `loadSession` is advertised, discarding its replayed updates. An agent without either capability is refused with the reason. The same session-open path applies the requested model and effort before sending the new message.
- Live model and effort switches use `session/set_config_option` between prompts. A refused switch reports its reason to the parent's inbox without ending the child's work. ACP agents choose their own provider. ACP has no compaction method, so `compact` is refused with `ACP agents manage their own context`.

### 21.4 Recovery and continuation

A child is an ordinary journal session, so continuing one is running `subagent_run` on its session id again through the same claim, `recover`, session head, `chat_session_init`, selection, compaction, and inbox delivery as any session. The same holds when a person opens it: `chat_session_role_setup` reads the session's role from its journal row and gives a `Subagent` session `SUBAGENT_ROLE` followed by the instruction in its parent's newest `subagent.started` for it, its tools without `agent_spawn`, `agent_stop`, and `agent_status` (the registry it is given is copied, never consumed), and no team. `subagent_run` and the root package's `session_install` both call it, so a child opened with `--resume` or `/resume` is the agent the orchestrator ran, and its selection is the one of its last `turn.started`. A live child holds the session's claim, so a person who opens it follows it instead of running it (section 8.6). A model switch of a running child installs through `chat_selection_install`, the procedure the main session's selection uses. There is no state machine and no record kind for it. The parent's journal is the registry of children (`subagent.started`, `subagent.message`, `subagent.completed`); a child's state is read from its own records; the in-memory `Subagent` record holds only work that is live. Nothing resumes by itself after a failure or a crash: recovery settles the dead process's delegations (section 9), the orchestrator hears of each, and it decides.

Continuing is `agent_send` to a child that is not live:

1. Dispatch reaps first, so every finished child's outcome is committed before the call. A child still in the team, running, queued, or just finished, is live: its message is recorded as before, and `model`, `provider`, `effort`, and `compact` are queued as live control (section 21.1) instead of being refused.
2. Otherwise the owner finds the child by `name` in the newest `subagent.started` of that name and refuses what cannot continue: a name the journal does not know lists the children it does with how each ended (`running`, `completed`, `failed`, `stopped`, `interrupted`, `never started`); an ACP child continues through the capability-gated session-open path in section 21.3; a child that never created its session is refused. A continuation that itself never started leaves the child as it was.
3. It services pending control before a child finishes and reads the child's newest `selection.applied` or `turn.started` (provider, model, effort) as the default selection and resolves the call's `model`, `provider`, and `effort` over it with the selection rules of section 21.1: a model alone finds its provider, a provider alone needs a model unless it is the child's, and an unknown provider names the configured ones. An effort the model does not state falls back to the child's last effort, or the model's lowest level, with the repair reported as for a start. A call whose selection does not resolve is refused before anything is recorded, so a refused call leaves no message in the child's inbox. There is no fit gate: a smaller model than the history needs is handled by admission, which compacts and continues (section 23.2), and a refused request by checkpoint repair (section 11.3).
4. The barrier commits the call's `tool.admitted`, the new `subagent.started`, and the `subagent.message` (invariant 2). The executor starts a member with the same name and the continuation's selection, launches it as any background child, which counts toward `subagents_max_running` and may queue, and answers `resumed` or `queued` with `session`, `model`, and `effort`. A start that then fails commits `subagent.completed{not_executed}` with the call's result.
5. The member's thread claims the child's session. A session another process holds is refused by the claim, and the child's failure report carries the reason; its message stays in the child's inbox and is delivered, with any later one, when the session is next continued. On success it runs `recover`, which settles work the dead run left open in the child (an interrupted turn, an unanswered request, a call with an unknown outcome), takes the head, and installs the role's instructions and tools and the selection. Its first step is `chat_session_accept_message` with an empty text and the inbox first, which delivers the `subagent.message` as a `User` node through the same path as steering. The child then runs as any child does, and its completion reaches the orchestrator as a background report.

6. `compact: true` asks for the child's context to be compacted as it reopens. A live child queues it as live control, and an ACP child refuses it with `ACP agents manage their own context`. After the selection is installed, the child's thread calls `chat_compact_request(chat, .User_Command)`. With a message, the child starts working at once and the summary installs at a request boundary as for any session. Without a message nothing is recorded in the child's inbox and the child delivers nothing: it services its compaction as an idle session does (`chat_compact_idle_service` and `owner_wake_wait`) until none is running, waiting, or recorded, then ends normally and its completion reaches the orchestrator. Nothing bounds that wait, since a summary may take many minutes; `agent_stop` ends it.

A failed child's partial text is committed and reported with the failure, but projection never replays a partial message (section 11.2), so a continued child resumes from its last complete context and its new message.

## 22. Frontends and ACP

- Frontends own no agent semantics. They send `Command` values and observe the owner through `Chat_Observer` callbacks. TUI, headless, and the ACP server are peers over the same owner.
- TUI handoff: the observer updates a shared snapshot under a lock that guards only that memory, bumps its generation, and writes the TUI's wake `eventfd`. The TUI thread renders from the snapshot, so the owner never performs terminal I/O and never waits for a redraw. The resize and interrupt signal handlers write the same `eventfd`.
- TUI: immediate-mode `layout` and `term` rendering; its own display transcript bounded by `TRANSCRIPT_MAX_BYTES`; `poll` on the tty and the wake `eventfd` with no timeout when idle and `SPINNER_INTERVAL` only while a turn runs. Commands: `/new`, `/resume`, `/fork`, `/branch`, `/model`, `/effort`, `/compact`, `/rate`, `/reload`, `/status`, `/help`, `/quit`, plus material commands.
- TUI colors: Nabla has no theme. The terminal's theme is Nabla's theme, so a user who changes the terminal theme recolors Nabla with no Nabla setting. A theme reliably defines the default foreground and background and the 16 ANSI palette entries (0 to 7 normal, 8 to 15 bright); entries 16 to 255 are a fixed xterm cube and grayscale in most themes, and truecolor bypasses the theme entirely. The TUI therefore draws with the default colors, ANSI indices 1 to 6 for semantic accents (each meaning one fixed index, such as red for failure and cyan for code), and the attributes bold, dim, italic, underline, reverse, and strikethrough. It never emits RGB colors or indices above 15, and it avoids 0, 7, and 15 as foregrounds because their contrast against an unknown background is unknown. It does not query the terminal's colors (OSC 4, 10, 11), because replies add latency, support varies, and multiplexers can block them.
- Headless (`nabla --prompt`): the observer writes the final answer to stdout and everything else to stderr on the owner thread. Those streams are the run's only consumer, so a reader that stops reading should hold the run back; the answer is never dropped to keep the owner moving.
- ACP server (`nabla acp`): the reader thread routes commands by session id to an independent owner and worker for each open session, up to `ACP_MAX_SESSIONS` per connection. Opening another session does not replace an existing one or invalidate it when the open fails. A full connection closes its least recently used idle session to make room; if every session has a turn or request in progress, the new open is refused. An evicted session can be loaded again from the journal. Prompts within one session run one at a time: a prompt that arrives during a turn is queued for a later turn (V2) or refused as busy (V1), while other sessions keep running. Sharing a session across connections remains a target under section 8.6; until then, the ACP server refuses a session another connection or process claims. The target also includes `session/fork` mapped to `Fork`, permission requests mapped to `session/request_permission`, and `_nabla/rate` and `_nabla/branches` as extension methods. `acp` implements the client role used by subagents.
- ACP protocol rules the server keeps: `initialize` advertises exactly the methods and content it implements (`loadSession`, the session list capability for `session/list`, embedded context, stdio MCP), since a client treats an omitted capability as unsupported; every `session/update` of a prompt is queued before that prompt's response; a cancelled turn ends with `stopReason: cancelled` (V1) or an idle state carrying the cancelled reason (V2), after its pending updates; `session/load` replays the conversation as updates before its response.
- ACP output: the owner hands ACP frames to a writer queue. The owner's observer encodes a whole frame and appends it under a lock that guards only the append, never the write; one writer thread writes the queue in order. The owner therefore never blocks on the client. The queue has no bound, since a harness limit would drop protocol frames. An update that reports a durable outcome (a message, a finished tool call) is queued only after the journal commit that records it, so the stream is a view of the journal: a client that stops reading loses nothing that `session/load` cannot replay. Shutdown drains the queue within `SHUTDOWN_JOIN_PATIENCE`; a writer still blocked in a write is abandoned and keeps what it can reach.

## 23. Context, capacity, compaction

### 23.1 Capacity

Computed once per model into `Capacity` in the catalog snapshot:

```text
W       = context_window, or CHAT_DEFAULT_CONTEXT_WINDOW flagged as assumed; a stated 0 or negative refuses requests
M       = max(W / 20, 1024)               estimator margin
F       = min(1024, max_output)           minimum useful answer
ceiling = W - M - F                       admission limit for the input estimate
trigger = max(ceiling - W / 10, 0)        compaction pressure point
output  = min(W - M - estimate, max_output)
```

For W = 200k this admits about 189k of input and starts compaction at 169k (about 85%); for W = 1M, 949k and 849k. The `W / 10` between the trigger and the ceiling is the room the turn keeps working in while the background summary is written.

The raw estimate is bytes / 4 plus 8 per message, reported per part (instructions, tools, conversation). It is wrong in both directions: code and JSON run denser than four bytes a token, and opaque replay items (encrypted reasoning, native output items) count far fewer tokens than their bytes. The provider's own count corrects it. Each attempt keeps the raw estimate of the body it sent; when the provider reports that attempt's input tokens, the session keeps the pair `(measured, estimated)` for its current selection, and every later estimate is `raw * measured / estimated`. A selection change (provider, model, or API) drops the pair, and the raw estimate is used until the next report. Admission, the trigger, and the output bound all read the calibrated estimate, so one number decides all three. An estimate that is still short is caught by the provider's overflow refusal, which the harness repairs (section 2.2).

### 23.2 Compaction

- At most one per session: a `Compaction` job (tool-free provider request) over a frozen prefix through `F`, keeping the newest `COMPACT_KEEP_MESSAGES` and never splitting an assistant/results pair.
- Compaction runs in the background and never pauses the agent. While the job runs, the turn keeps sending requests over the unchanged projection, so the provider prefix and its cache stay intact. Install swaps only the prefix through `F` for the summary: every node committed after `F`, including the steps the agent took while the summary was computed, stays in the projection after the checkpoint (section 10.3).
- Triggers: estimate at `trigger`, explicit command or `context_compact`, proven provider overflow, pending selection that needs a smaller context. Triggers coalesce. Automatic starts require new nodes since the last attempt and respect `COMPACT_COOLDOWN`. Auth, quota, and invalid-request failures suppress automatic starts until configuration or explicit intent changes.
- Explicit commands wake the owner and start from committed history at its next collection step, including during provider work, tool work, or retry backoff. They do not wait in the turn's ordinary command queue or wait for a request boundary. Agent tool intent is serviced by the same collection step. All existing start checks still apply; only installation waits for a safe boundary.
- A summary is accepted only with a normal stop reason, no tool calls, non-empty text, and a saving of at least `COMPACT_MIN_REDUCTION` tokens. A pending selection accepts any strictly positive saving; the target fit check determines whether another summary is useful.
- Install at a request boundary or while idle: verify base and coverage, commit the `Checkpoint` node (section 10.3) and `checkpoint.installed` in one transaction, reload the projection, reset the encode cache.
- The foreground does not wait for a summary it does not need. When admission refuses, a ready candidate is installed and admission reruns; without one, the turn waits for a compaction and continues after the install. The turn ends with `Context_Exhausted` only when nothing a checkpoint can remove would make room, which is the model's window refusing the instructions and tools themselves; the user is told which part is too large.
- The summary directive asks for goals, constraints, decisions with evidence, exact identifiers, current and pending work, failures, and unknowns, and tells the model to reload skills before relying on their details.

### 23.3 Session selection changes

Model, provider, and API changes use one owner-controlled selection path. A frozen request keeps its original selection and connection until its borrows end; a new selection applies at a settled request boundary or while idle. Provider-native replay follows section 11.2, so switching APIs retains neutral conversation content without sending opaque replay to a different endpoint.

Before applying a target, project the current instructions, tools, and conversation for the target API, provider, and model, and check its capacity with the same estimator and admission arithmetic used for requests. A refused switch leaves the current selection and foreground work unchanged. `selection.fit` records the target, API, estimate, window, output allowance, margin, and decision before the switch or compaction effect; a session whose first prompt has not created it yet has no row to carry one, and its first turn records the selection it starts with instead.

An installed selection is recorded as session-scoped `selection.applied` before reporting success. The process-wide `selection.changed` default remains separate, so a change in an ACP session does not become the next interactive launch's default.

The top-level Lua configuration option `compact_on_switch` defaults to false and is read at launch. When a target does not fit, the user receives a warning and the switch is refused. When enabled, keep the target pending and request the existing background compaction on the current selection. The foreground keeps working. After checkpoint installation, check the target again against the summary and all steps committed while compaction ran. Apply only if that second check fits. Another compaction is allowed only while the target estimate decreases; no progress or compaction failure refuses the pending switch and reports why, without stopping foreground work. Instructions and tools that cannot fit even without conversation refuse the switch without starting compaction.

A newer selection request supersedes the pending target. It does not cancel a shared compaction that may still help the current selection. An effort-only change does not require compaction when the request representation and capacity are unchanged.

### 23.4 Encode cache

The `ai` encode cache keeps encoded fragments of unchanged messages. It is bounded by `ENCODE_CACHE_MAX_BYTES` and reset on checkpoint install, on a model or API change, and when its retained bytes exceed twice the last request body.

## 24. Ratings and assessments

- `Rate{node, value, note}` commits `rating.recorded{node, value: positive | negative, note}` against an `Assistant` node. No rating means no record. `rating.cleared{node}` withdraws; the latest record wins.
- Offline evaluators write `assessment.recorded{node or turn, evaluator, evaluator_version, score, label, note}` through `nabla assess import`, never as ratings. Assessments are annotations: they need no session claim and change no session state.

## 25. Statistics and offline improvement

- Statistics are read-only views over the journal, computed by a reader that opens it read-only: no claim, no migration, no writes. No diagnostics command exists.
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

These values schedule work, size internal buffers, and time the harness's own threads. None of them limits what the model may ask for (section 2.1): no value here caps arguments, output, calls, requests, scripts, or execution time. The resend schedule is the one bound, and it applies to the harness's own requests, not to model work.

| Name | Default | Kind |
| --- | --- | --- |
| `TRANSCRIPT_MAX_BYTES` | 1 MiB | TUI display memory; older lines reload from the journal |
| `SPINNER_INTERVAL` | 100 ms | redraw while busy |
| `TOOL_JOBS_MAX_ACTIVE` | `max(4, core count)` | concurrency; excess jobs queue |
| `SUBAGENTS_MAX_RUNNING` | 4 | default of the `subagents_max_running` option; concurrency, excess children queue |
| `STREAM_IDLE_TIMEOUT_DEFAULT` | 0 (none) | default of the provider option `stream_idle_timeout_ms` (section 11.3) |
| `ACP_MAX_SESSIONS` | 8 | sessions one connection runs at once; a new open evicts the least recently used idle session, or is refused if all sessions are busy |
| `CHAT_RETRY_DELAYS` | 1, 2, 4, 8, 16 s | resend schedule of a failed provider request (section 11.3) |
| `TOOL_JOBS_STOP_PATIENCE` | 10 s | time to confirm a requested stop, for every job kind |
| `TOOL_KILL_GRACE` | 500 ms | TERM to KILL |
| `TOOL_SHELL_DEFAULT_TIMEOUT` | 120 s | default when the model gives none; no maximum |
| `TOOL_READ_DEFAULT_LINES` | 2000 lines | default when the model gives none; no maximum |
| `TOOL_RESULT_PREVIEW_BYTES` | 32 KiB | what one result shows the model; the rest is kept in a file |
| `TOOL_RESULT_NOTICE_TOKENS` | 128 | context reserved per later result in a batch |
| `TOOL_STREAM_MEMORY_BYTES` | 1 MiB | shell output held in memory per stream; the rest goes to its kept file (section 14.4) |
| `LUA_SLICE_INSTRUCTIONS` | 10,000 | scheduling quantum |
| `CONFIG_INSTRUCTIONS` | 200,000 | config Lua run length; keeps the thread that evaluates it responsive |
| `SKILL_INLINE_CATALOG_BYTES` | 16 KiB | inline catalog versus `builtin_list_skills` |
| `CATALOG_REFRESH_COOLDOWN` | 10 min | network use |
| `CHAT_DEFAULT_CONTEXT_WINDOW` | 131072 | used only when the catalog has no window, and flagged |
| `CHAT_DEFAULT_OUTPUT_TOKENS` | 4096 | output a request asks for when the catalog states no maximum; the window bound (section 23.1) still applies |
| `CHAT_COMPACT_KEEP_MESSAGES` / `CHAT_COMPACT_MIN_REDUCTION_TOKENS` / `CHAT_COMPACT_COOLDOWN` | 10 / 1024 tokens / 30 s | compaction policy |
| `JOURNAL_BATCH_RECORDS` / `JOURNAL_BATCH_BYTES` / `JOURNAL_BATCH_AGE` | 256 / 1 MiB / 1 s | write batching |
| `TOOL_LIST_SKILLS_DEFAULT_LIMIT` | 20 | skills returned when the model gives no limit |
| `TOOL_STREAM_READ_BYTES` | 4 KiB | shell stream read buffer |
| `MAX_MESSAGE_DEPTH` | 256 | MCP JSON nesting depth admitted by the parser |
| `MAX_STDERR_TAIL_BYTES` | 32 KiB | recent MCP server stderr kept for diagnostics |
| `SUBAGENT_ACP_STDERR_TAIL_BYTES` | 32 KiB | recent ACP subagent stderr kept for diagnostics |
| `CHAT_TITLE_MAX_BYTES` | 80 bytes | derived session title length |
| `BUSY_TIMEOUT_MS` | 5000 ms | journal commit wait for another process's write lock |

A default changes only with a measurement from the journal or a benchmark test. A new entry that would cap model-driven work is refused by section 2.1.

## 28. Testing rules

- `owner_apply` and `owner_select` are tested with supplied events and clock values and no I/O: repeated selection, stale identities, cancel before every start, commit failure, retry and backoff, child-before-parent commit, exactly-once terminal.
- Integration fixtures count actual provider sends and tool executions for: failure before write, partial write, head then truncation, visible output, malformed completion, cancel during backoff, crash after each barrier (reopen and recover), abandoned worker, patch ambiguity, access conflicts, subagent kill.
- Lua: allocator-failure tests on every host entry, infinite loops, conversion edge cases, stop while waiting on children.
- Suites run with `ODIN_TEST_FAIL_ON_BAD_MEMORY` in release and `-debug`; tests pass explicit allocators where ownership is the subject.
- Tests assert outcomes and counts, not layouts, colors, or field order. Process-global state (signals, interrupt) runs in `test_isolate_process` children.

## 29. Known differences in current code

These mechanisms exist in the code today and are replaced by the named target. Do not copy them into new code; when you touch one, move it toward the target.

| Current | Target |
| --- | --- |
| the ACP server refuses a session another process runs | ACP connections follow it by the rule of section 8.6 |
| catalog replaced under a mutex and the old one destroyed; selection reapplied mid-turn | immutable reference-counted snapshots, kept by admitted work (section 13.3) |
| tool jobs scheduled by placement and lane, with no access classes | access classes when a measured gain justifies them (sections 7.3 and 26) |
| `agent/skills` with skill list and load tools | `agent/material` (sections 18, 19) |
| no hooks, Tasks, rules, commands, tool policy, fork or branch selection, ratings, resource measurements | sections 10.2, 14.2, 18 to 24, and 26 |

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
