# Harness logging and diagnostics architecture

Status: phases 1 and 2 are implemented, together with phase 3 apart from compaction
requests and the session release record, the provider observation of phase 4, and the
reader of phase 6; the rest is planned.

This plan is based on the complete *Nabla Logging Reference Study: goose + opencode*,
including its appendices, at
`/home/su3h7am/.opencode/plan/nabla-logging-reference-study.md`. The research describes
local source trees, not promises about upstream releases. The relevant code was checked
directly while preparing this plan. The reference decisions and source paths below make
the design understandable without that machine-local file.

## 0. Ownership in one paragraph

Logging is harness behaviour. Session identity, turn structure, request retries, tool
dispatch, model selection, recovery, and retention are all harness concepts, so the log
implementation lives in `agent`, next to the state machine that produces those facts, and
the process wiring lives in the root `nabla` package that owns the process. No new package
is created. The reusable libraries below `agent` stay reusable: `http` and `http/client`
own the HTTP protocol, `sse` owns event-stream framing, `ai` owns provider wire protocols
and the operation that performs one, and `mcp` owns the MCP protocol. Each of those may
expose facts about its own operation in its own vocabulary, and none of them may contain a
log level, a log file, a session, a turn, a retention policy, or a Nabla-specific rule.

## 1. What the system must answer

Given a session and a failed request, identify:

- Which process, turn, logical request, retry attempt, and operation performed it.
- What model and tool inventory were prepared, encoded, and handed to transport.
- Whether failure occurred during preparation, DNS, connect, TLS, write, response headers,
  body framing, SSE parsing, provider decoding, dispatch, or persistence.
- Which tool identity the model returned, which canonical identity Nabla selected, and
  which remote MCP name and JSON-RPC request were actually sent.
- Whether execution started, whether a result was observed, and whether that result
  committed to SQLite. These are three different facts.
- What evidence is absent because capture was disabled, bounded, expired, or failed.

A record is a statement about what a process observed at a named boundary. Missing
completion is not proof of failure, a completed local write is not proof of remote receipt,
and a diagnostic record is never authoritative over the session database.

Diagnostics never change retry, admission, recovery, or tool execution policy. In
particular, no fixed provider-request byte limit is introduced as a logging safeguard.

## 2. What the reference study establishes, and what does not transfer

| Reference | Keep | Change for Nabla |
|---|---|---|
| Goose study §§1.2–1.4: diagnostics, request captures, and the session DB are distinct | Separate responsibilities and lifetimes | Every record and artifact carries explicit run/request correlation; never select evidence only by recency |
| Goose §1.2: one file per process, JSON events | Isolate writers; use JSONL | Add size bounds as well as age retention; a timestamp is not a unique filename |
| Goose §1.3: UUID temporary request files, promoted on completion | Keep incomplete captures distinguishable | No shared numbered rename chain; a bounded artifact stays associated with its original attempt |
| Goose §1.5: bounded diagnostics bundle | An explicit export command | Select by session and run keys, report omissions, and exclude configuration wholesale |
| OpenCode §§2.2, 2.5: run ID and byte accounting | Explicit process identity and byte accounting | No machine-shared writable file and no in-place truncation race |
| OpenCode §2.3: transactional sequence and durable product events | Commit order is authoritative | Reuse Nabla's existing entries and requests instead of adding a second durable event bus |
| OpenCode §2.3: subscribe before backfill | Correct principle for live replay | No live subscription service in this implementation; bounded file scans suffice |
| Both: best-effort diagnostic sinks | Logging failure must not abort useful work | Latch and expose logging health instead of silently claiming complete evidence |

Placement does not transfer. Goose keeps logging in a generic crate module and OpenCode
keeps it in a shared utility package, because both treat it as infrastructure shared across
several products and processes. Nabla has one product and one harness. The same code cannot
be described without naming sessions, turns, requests, retries, tools, and providers, so it
does not belong in a reusable library, and it is not worth a package of its own.

Also not transferred: Rust subscriber layers, `tracing` spans, Effect services, task-local
stacks, global registries, destructor-driven flush, and reflective attribute handling.
Odin needs none of those mechanisms here.

Checked source anchors:

- Goose `crates/goose/src/logging.rs`: directory preparation, 14-day cleanup,
  `Rotation::NEVER`, JSON subscriber.
- Goose `crates/goose/src/providers/utils.rs`: `RequestLog`, ten numbered captures,
  temporary file creation and `finish`/`Drop` behavior.
- OpenCode `packages/util/src/observability/logging.ts`: shared append file, 50/25 MiB
  trim, hourly cleanup, documented truncate race.
- OpenCode `packages/core/src/bus.ts`: transactional projector, sequence and event writes,
  and subscribe-before-read in `log`.

## 3. Where the code goes

### 3.1 Existing packages and what stays out of them

| Package | Subject it owns | What it may observe | What must never appear |
|---|---|---|---|
| `http`, `http/client` | the HTTP protocol | transfer phases, plaintext byte counts, status, declared length, failure kinds | sessions, turns, requests, providers, models, log levels, file paths, retention, a hook named after the harness |
| `sse` | text/event-stream framing | unchanged in this plan | harness policy |
| `ai` | provider wire protocols and one provider operation | the encoded request body it just built, the response body stream it already receives, provider operation outcomes | log levels, log files, session correlation, retention, `agent` types, per-provider logging rules |
| `mcp` | the MCP protocol | unchanged in this plan | harness policy |
| `agent` | the harness: turns, requests, retries, admission, compaction, tool dispatch, durability | everything that decides what is recorded: the record model, categories, levels, correlation, capture, rotation, retention, and the readers | anything from the root package, the terminal, or the TUI |
| root `nabla` | the process: launch, config, terminal, CLI | writer lifetime, options from argv and environment, health presentation, the `diagnostics` command | the log format itself, which belongs to `agent` |

Two consequences are worth stating because they are the easy mistakes:

- No provider-specific logging goes in `http` or `sse`. "OpenAI request body" is not an
  HTTP fact. The body and its digest are `ai` facts; the wire bytes are transport facts.
- No transport type reaches `agent` for logging. `agent` talks to `ai`; `ai` talks to
  `sse.post` and `http/client`. A hook is a value passed down, never a lower layer calling
  upward into harness code.

### 3.2 No new package

A package here is a standalone library another Odin project can use: `http` is an HTTP
library, `layout` is a layout solver, `tui` is a terminal UI toolkit, `ai` is a provider
client. Code that only this harness uses, and that cannot be described without naming
sessions, turns, tools, or the Nabla model catalog, is harness code and belongs in `agent`.
A `diagnostics` package would be a harness package with a library name, which is worse than
putting it in `agent` where its callers already live.

Nothing in the build or test tooling changes either: no new package means no
`scripts/test`, `scripts/check`, or `scripts/build` registration, and the existing
`mise run test agent` gate covers the work.

If a future need is genuinely reusable, the test is one question: could an unrelated Odin
program use it without knowing what a session is? Until that is true, extend `agent`.

### 3.3 Files

Inside `agent`, beside the state machine:

| File | Contents |
|---|---|
| `agent/log.odin` | record model, levels, categories, `Log`, `log_open`, `log_close`, JSONL encoding, sequence, rollover, health |
| `agent/log_lock.odin`, `agent/log_lock_linux.odin` | the exclusive file lock a lease and the cleanup lock are built on; the platform file holds the one call no core package abstracts |
| `agent/log_retention.odin` | run directories, leases, bounded cleanup |
| `agent/log_capture.odin` | opt-in payload capture: admission, chunk append, digests, sidecar metadata, abort |
| `agent/log_read.odin` | parsing and scanning a run directory for diagnosis and export |
| `agent/log_bridge.odin` | the scope a record is emitted against, and the log's names for enums other packages define |
| `agent/log_provider.odin` | the provider observation: what one operation encoded and what came back |
| `agent/chat.odin`, `agent/chat_session.odin`, `agent/compact.odin`, `agent/tool*.odin` | emit calls at the boundaries they already own |
| `agent/log_test.odin`, `agent/log_events_test.odin`, `agent/log_retention_test.odin`, `agent/log_read_test.odin` | unit tests |

Inside the root package:

| File | Contents |
|---|---|
| `app_log.odin` | the level from the environment, `log_open`/`log_close` around the run, `run.started` and `run.finished` |
| `app_diagnostics.odin` | `nabla diagnostics <session-id>`: the reader's records to stdout, what was read and what could not be to stderr |
| `main.odin` | the `diagnostics` subcommand, alongside `chat_cli_parse` |
| `app_command_test.odin` | CLI parsing tests |

Inside the libraries, only where a fact currently cannot leave the layer:

| File | Change |
|---|---|
| `http/client/control.odin` | optional `Transfer_Observer` in `Options` |
| `http/client/client.odin` | call the observer at phase boundaries |
| `ai/request.odin` | optional `Provider_Operation_Observer` in `Provider_Operation_Options` |
| `ai/http.odin` | bridge the transport observer into provider operation reports |

### 3.4 Observation chain

```text
http/client.Transfer_Observer            HTTP protocol facts
        -> ai/http.odin                  provider operation facts
ai.Provider_Operation_Observer           encoded request body, response stream, outcome
        -> agent/log_bridge.odin         records and captures
agent.Log                                format, sequence, rotation, retention
        -> app_log.odin                  lifetime, options, health
```

Every arrow points inward. `ai` knows nothing about who observes it, and the observer may
be a zero value at every step.

## 4. What already exists, and what is actually missing

Most of the evidence a full turn needs already leaves the layers it belongs to. The plan
adds only what does not.

| Evidence | Already available from | New work |
|---|---|---|
| session, turn, request, attempt identity | `agent/session` schema, `Chat_Session.turn_no`, `chat.active_request`, the `attempts` counter in `chat_perform_request` | none |
| operation identity and staleness | `Chat_Session.next_operation_id`, `Chat_Event_Source` | none |
| failure kind, status, detail | `ai.Provider_Operation_Error`, `http/client.Failure` mapped through `ai/http.odin` | none |
| provider response bytes | `client.Chunk_Callback`, already forwarded by `ai/http.odin:http_post_sse` into `provider_http_chunk` | a capture sink |
| provider usage, finish reason, tool calls | `ai.Provider_Event` callbacks | none |
| the exact encoded request body | built in `Provider_Request_Operation_Controlled`, deleted before it returns | a borrowed report from `ai` |
| bytes handed to the transport, declared length | not exposed | `http/client` phase observation |
| MCP delivery state | `mcp.Error.delivery` (`Delivery_State`) | none |
| MCP server stderr excerpt | `TOOL_MCP_STDERR_EXCERPT` in `agent/tool_mcp.odin` | none |
| process start and end | not recorded | `run.started` and `run.finished` |
| storage commit results | `agent/session` returns | emit calls only |

Constraints the design must respect:

- `agent/session/schema.odin` is schema version 4. `requests` and `entries` already record
  prepared input, provider, model, API, outcome, usage, and dispatch/result linkage. The
  log does not duplicate that schema and does not change it.
- `session.Session_Id` is 32 hexadecimal characters. `Turn_No`, `Request_No`, and `Seq` are
  distinct per-session `i64` counters. `Chat_Operation.id` is a per-session monotonic
  `u64`.
- `agent/session/store.odin` owns one SQLite connection, a busy timeout, WAL, and Linux
  advisory claims. It is not thread-safe, and logging never touches it.
- `session_recover` marks unfinished requests interrupted and never reissues a tool. The
  log must agree with that outcome rather than replace it.
- `Provider_Validate_Request` already rejects a missing or empty model with
  `.Missing_Model`, and `Provider_Encode_Request` re-validates. An empty model cannot reach
  the wire from this harness. The log records the model it encoded; it does not add a
  redundant second validation.
- `http/client` reads at most `HTTP_MAX_ERROR_BYTES` (4096) of an error response and
  exposes at most `HTTP_MAX_ERROR_EXCERPT` (2000) bytes in `Failure.detail`. That response
  is not fully read, and the log says so.
- `app_worker.odin` runs work serially on one worker thread, so agent and store calls are
  single-threaded. The root UI runs on another thread and already synchronizes through its
  own mutex.
- `agent/xdg.odin` resolves the XDG directories. The log root hangs off the state
  directory it already computes.
- `agent/observer.odin` is the borrowed presentation handoff. It stays presentation only;
  log records do not travel through it.

## 5. Data model

### 5.1 Records

```odin
// Level selects which records are emitted. Disabled is the zero value, so a zero
// Log_Options emits nothing.
Level :: enum u8 {
	Disabled,
	Error,
	Warn,
	Info,
	Debug,
	Trace,
}

// Category names the part of the harness a record came from. Values are written
// out by name, never by ordinal.
Category :: enum {
	Runtime,
	Session,
	Agent,
	Provider,
	Transport,
	Tool,
	MCP,
	Storage,
	Diagnostics,
}

// Value is the closed set of types a field may carry. A nested object, a raw JSON
// fragment, or a blob is not a field: it belongs in a capture or nowhere.
Log_Value :: union {
	bool,
	i64,
	u64,
	string,
}

// Log_Field is one named scalar. The key is a producer-owned literal, and the
// value is borrowed for the duration of the emit call.
Log_Field :: struct {
	key:   string,
	value: Log_Value,
}

// Log_Record is one event. Fields are borrowed for the duration of the emit call
// and never retained.
Log_Record :: struct {
	level:    Log_Level,
	category: Log_Category,
	event:    string,
	fields:   []Log_Field,
}

// Log_Context is the correlation a record is emitted against. Every identity in
// it already exists in the harness, so this is not a second identity to keep in
// sync. log is the borrowed writer the record goes to.
Log_Context :: struct {
	log:          ^Log,
	session_id:   session.Session_Id,
	turn_no:      session.Turn_No,
	request_no:   session.Request_No,
	attempt:      int,
	operation_id: u64,
	call_id:      string,
}

// Log_Emit_Result says what became of one record. Disabled is the zero value:
// a zero scope writes nothing.
Log_Emit_Result :: enum {
	Disabled,
	Filtered,
	Oversized,
	Rejected,
	Written,
	Failed,
}

log_emit :: proc(scope: Log_Context, record: Log_Record) -> Log_Emit_Result
```

`Log_Emit_Result` exists so a call site that needs to know can check, while the common
case ignores it. `log_emit` never panics and never emits a record about its own failure; it
updates `Log_Health` instead. A `Log_Context` whose `log` is nil, or whose `Log` was never
opened, emits nothing and returns `.Disabled`, so a call site needs no enabled check and
the harness behaves identically with diagnostics off.

`log_emit` consumes every borrowed value synchronously. It never stores a `Log_Record`, a
`Log_Context`, a field slice, or a field string. Field names and event names are literals
owned by the producing module. Strings are length plus bytes, not C strings. JSON escaping
handles NUL, quotes, backslashes, control characters, and invalid UTF-8 through one
explicit replacement policy. Binary data goes to a capture, never into a string field.
A field key that repeats another key, or that collides with a reserved envelope name, is
rejected. `Log_Value` grows when a producer needs a type it does not have.

Domain values keep their types until the last conversion: the writer never reinterprets an
integer as a session sequence, and a helper that builds fields takes
`session.Session_Id` rather than `string`. No `any`, no reflective map walking, and no
format string derived from remote content.

### 5.2 Owned state

Phase 1 implements `Log_Options`, `Log`, `Log_Health`, and the plain-field additions
below. The capture types arrive with phase 4.

| Type | Stored data | Owner and release |
|---|---|---|
| `Log_Options` | directory, level | copied into `Log` at open; immutable afterwards |
| `Log` | allocator, owned run directory, run ID, `open` flag, current segment file, run lease, segment number and byte count, rollover bound, sequence, `sync.Mutex`, fixed record scratch, `Log_Health`, monotonic start tick and start time | declared by root, opened once, lives at one stable address, released by `log_close` after all borrowers retire |
| `Log_Health` | failed flag, first error kind and platform error, written and omitted counts | inside `Log`; read through `log_health` under the mutex |
| `Capture` | borrowed `Log`, kind, open fd, storage allowance, observed and stored byte counts, observed and stored SHA-256 contexts, truncated and failed flags, generated basename, owned correlation copy | owned by one operation; `log_capture_finish` or `log_capture_abort` closes it exactly once |
| `Capture_Summary` | identity, counts, digests, completeness and truncation facts | value result with fixed-size ids and digests, no borrowed capture state |

`Capture_Mode :: enum { Off, Payloads }` has `Off` as zero. `Capture_Kind :: enum {
Invalid, Provider_Request, Provider_Response, MCP_Request, MCP_Response, MCP_Stderr }`.
`Run_Seq :: distinct u64` inside the package.

Digests use `core:crypto/sha2`: `Context_256`, `init_256`, `update`, `final(ctx,
hash[:])`, with `DIGEST_SIZE_256` of 32 bytes. Digests are stored as `[32]u8` and rendered
as hexadecimal only at serialization time.

A `Capture` copies its correlation at `begin`, because its metadata may be written after
the state it describes has moved on. That copy is freed at finish or abort. No other
diagnostic path retains caller memory.

Root holds `Log` by value in its run setup, the `Run_Setup` the launch builds, and
releases it through the same teardown path as the store, matching the existing `Store`
pattern in `agent/session/store.odin`.

### 5.3 Envelope and sequence

One valid UTF-8 JSON object per line:

```json
{"version":1,"run_id":"128-bit-lowercase-hex","seq":42,"time_unix_ns":1789550000000000000,"elapsed_ns":123456,"thread_id":8123,"level":"info","category":"provider","event":"provider.encoded","session_id":"32-hex","turn_no":3,"request_no":6,"attempt":1,"operation_id":12,"call_id":"call_abc","api":"openai_chat_completions","model":"some-model","body_bytes":174381,"body_sha256":"..."}
```

The ids and timestamp above are illustrative; actual values must pass validation. Envelope
keys are reserved. Enum values are written by explicit stable name, never by ordinal.
Readers retain unknown event names and fields. An unsupported major version is reported,
not interpreted. Additive fields do not require a version bump. An event name or field
meaning is never changed in place.

`run_id` is 128 random bits generated once at launch, with exclusive directory creation and
collision retry. If randomness cannot be obtained, diagnostics are disabled with a warning
rather than falling back to a PID-only identity. PID, build, and schema version are fields
of `run.started`, not identity.

`seq` is a `u64` assigned under the writer mutex after filtering and before encoding. It
spans segment rollover. A failed write can leave a gap; filtered records do not consume a
number. No cross-process sequence is claimed.

Wall time supports human lookup. `elapsed_ns` measures duration within one process from the
monotonic start tick, sampled with the sequence. Timestamps are never subtracted across
runs to derive a duration.

### 5.4 Correlation fields

| Field | Meaning and availability |
|---|---|
| `session_id` | present when a session is known, including a failed claim; does not assert a database row exists |
| `turn_no` | only after a turn exists; compaction performed outside a turn has none |
| `request_no` | the durable logical request number, only after `request_begin` succeeds |
| `attempt` | the loop counter `chat_perform_request` already keeps, one-based, reset per logical request |
| `operation_id` | the value of `Chat_Session.next_operation_id` for the active operation, absent when no operation is running |
| `entry_seq`, `call_seq`, `dispatch_seq`, `result_seq` | committed entry identities, taken from what the store returned, never predicted |
| `call_id` | the provider call id, scoped to one session and request |
| `server_id`, `server_instance` | configured MCP namespace and a run-local launch counter |
| `artifact_id` | writer-generated capture identity inside the run; never a user-supplied path |

Operation identity is allocated before request preparation, so a failure before the
database insert still has one. A retry keeps the request number and increments `attempt`; it
does not begin a new operation. Admission compaction is its own logical request with its own
purpose, not a retry of the response request.

Correlation is built explicitly on the calling stack. A `Log_Context` lives until the
synchronous work it describes returns. Nothing is cached across a session switch, and
nothing is propagated through `context.user_ptr` or a thread-local.

## 6. Levels, categories and events

The default threshold is Info. Debug adds decisions and inventory detail. Trace adds
bounded frame metadata, never raw content automatically. Capture is a separate permission,
not a consequence of selecting Trace.

`Error` means the operation that emitted it failed. Cancellation is normally Info.
Malformed remote traffic or a retryable failure is Warn. A final failed request is Error.
Lower layers name the stage; the owner records the terminal outcome. One failure is not
logged as a final error at every layer.

Category is one of the enum values in §5.1. Configuration supports one global threshold
first; per-category overrides are added only when measured volume justifies them. There is
no filter expression language.

Minimum event contracts:

| Events | Level | Facts beyond correlation |
|---|---|---|
| `run.started`, `run.finished` | Info | build id, PID, schema version, effective diagnostic policy; close outcome |
| `session.claimed` | Info | whether the launch resumed rather than started fresh |
| `session.recovered` | Info | interrupted turns and requests, calls whose outcome is unknown, and calls that never ran; emitted only when there was something to settle |
| `storage.failed` | Error | the local operation that failed, the store's error kind, and the error detail length |
| `turn.started`, `turn.finished` | Info | prompt size at the start; outcome, whether the outcome landed, request and call counts at the end |
| `agent.event_ignored` | Debug | reason, supplied turn and operation, current operation |
| `request.prepared`, `request.recorded` | Info | purpose, model, provider, API, token estimate, context window, message and tool counts; the record marks the durable row separately from the prepare |
| `request.admission`, `compaction.started`, `compaction.finished` | Info | estimate, budget, decision, covered sequence, checkpoint commit result |
| `attempt.started`, `attempt.finished` | Info | attempt, remaining deadline; error kind, finish reason, status, error detail length, response byte count, duration |
| `request.retry` | Warn | error kind, next attempt, delay |
| `provider.encoded` | Info | body length and digest, api, model, tool count |
| `provider.response_head` | Debug | deferred with the transport observer |
| `transport.phase`, `transport.bytes` | Debug | deferred with the transport observer |
| `provider.decode_failed` | Warn | deferred; the stream failure already reaches the caller as an error kind |
| `provider.completion_received`, `provider.completion_delivered` | Debug | deferred; the completion event already reaches the caller |
| `request.finished`, `request.commit_failed` | Info, Error | outcome, attempts, finish reason; the storage failure is `storage.failed` |
| `tools.refresh_started`, `tools.refresh_finished` | Info | generation, discovered, accepted, disabled and rejected counts |
| `tool.name_resolved` | Info | the name the model sent and the name the harness resolved it to |
| `tool.call_received` | Info | the canonical tool name and the argument byte count |
| `tool.arguments_prepared` | Debug | admission status, repair classification, effective byte count |
| `tool.dispatch_committed`, `tool.result_committed` | Info | the entry sequence the dispatch and the result were stored as, and the outcome |
| `tool.execution_started`, `tool.execution_finished` | Info | the tool and the outcome it produced |
| `mcp.started`, `mcp.negotiated`, `mcp.stopped` | Info | server instance, protocol revision, capability summary, exit status when observed |
| `mcp.exchange_started`, `mcp.exchange_finished` | Info | method, remote name for a call, delivery state from `mcp.Error.delivery`, duration |
| `mcp.stderr` | Warn | tail length, exit status, error kind; the tail itself only under capture |
| `capture.finished`, `capture.failed`, `retention.finished` | Info, Warn | completeness, bounds, digests, deletion counts, omitted evidence |

Required fields are documented beside the procedure that emits the event and tested at the
real boundary. There is no single union enumerating every application event; the scalar
union bounds serialization types, and producer helpers plus tests enforce each contract.

## 7. The session database stays authoritative

No diagnostics table, log-offset column, trigger, or second transaction is added to
`agent/session`. Diagnostic retention never deletes conversations, and deleting a session
never silently deletes its diagnostics.

Records and rows are joined on `(session_id, request_no)` and on the committed entry
sequences. A run may touch several sessions and a session spans many runs, so an exporter
scans the run files it can find rather than guessing the newest process. A session
identifier alone does not locate the run that produced a record; that is what makes
`session_id` an on-record field rather than a directory name.

`requests.input_json` is the prepared semantic input, not the exact provider body and not
the HTTP bytes. That stays as it is. Wire digests and optional body captures live in the
log, and diagnostic events never enter model-visible history.

Tool commit order, which the log mirrors rather than participates in:

```text
provider proposal accepted
  -> call entry committed
  -> arguments admitted or repaired
  -> dispatch entry committed        -> tool.dispatch_committed
  -> execution starts                -> tool.execution_started
  -> execute once                    -> tool.execution_finished
  -> result envelope finalized
  -> result entry committed          -> tool.result_committed
```

If execution finished but the result entry did not commit, the log may hold the observed
outcome while recovery correctly reports the durable outcome as unknown. If a commit
succeeded just before a crash, the row is right and the missing record is not evidence
against it. There is no atomicity across SQLite and a log file, and none is promised.

## 8. Observation APIs, layer by layer

### 8.1 `http/client`: transport facts

```odin
// Transfer_Phase names a stage of one HTTP transfer, in protocol terms.
Transfer_Phase :: enum {
	Resolve,
	Connect,
	Handshake,
	Write_Head,
	Write_Body,
	Read_Head,
	Read_Body,
	Complete,
}

// Transfer_Report is one observation of a transfer's own progress. It reports
// accounting, never payload: body bytes for a capture come from the buffer the
// provider encoded and from the response chunks it already receives, so the
// transport does not hand the same bytes out a second time.
//
// bytes counts plaintext payload for the whole transfer: request body bytes for
// the write phases, response body bytes for the read phases. It excludes the
// request line, the status line, and the header block, and it excludes TLS
// ciphertext. declared_length is what the response head stated, kept separate
// from what was actually read.
Transfer_Report :: struct {
	phase:                   Transfer_Phase,
	bytes:                   u64,
	status:                  u16,
	declared_length:         u64,
	declared_length_present: bool,
	error:                   Error,
}

Transfer_Observer :: struct {
	user_data: rawptr,
	report:    proc(user_data: rawptr, report: Transfer_Report),
}
```

`Options` gains `observer: Transfer_Observer`, alongside `probe`, `ca_file`, and
`nameservers`. A zero observer observes nothing.

This stays inside HTTP's subject: phases, byte counts, status, and declared length are
facts about an HTTP transfer that any HTTP consumer could want. The hook contains no log
level, no path, no filename, no session, no provider name, and no model. It never receives
header text, so the `authorization` header cannot be captured here.

`bytes` is reported for what the transport actually handled. When a write reports
completion without a count, the report carries the previous count and no invented number;
if partial-write evidence is needed, `connection_write_all` is extended to return it rather
than the count being guessed.

### 8.2 `ai`: provider operation facts

```odin
// Provider_Operation_Stage names what one provider operation has produced.
//
// Encoded carries the exact request body the operation is about to send, which is
// the only moment it exists: the operation frees it when it returns. Response_Body
// carries a plaintext response chunk as it arrives, before it is parsed.
Provider_Operation_Stage :: enum {
	Encoded,
	Response_Body,
}

// Provider_Operation_Report is one observation of a provider operation. body and
// chunk are borrowed for the duration of the call and never retained; an observer
// that wants them beyond that must copy them itself.
Provider_Operation_Report :: struct {
	stage: Provider_Operation_Stage,
	api:   API_Kind,
	// model and tools describe the request the body was built from, and are zero
	// for a response chunk.
	model: string,
	tools: int,
	body:  []u8,
	chunk: []u8,
	// bytes is the running plaintext response byte count for the operation.
	bytes: u64,
}

Provider_Operation_Observer :: struct {
	user_data: rawptr,
	report:    proc(user_data: rawptr, report: Provider_Operation_Report),
}
```

`Provider_Operation_Options` gains `observer: Provider_Operation_Observer`.

`Provider_Request_Operation_Controlled` reports `Encoded` immediately after
`Provider_Encode_Request` succeeds and before `http_post_sse`, over the exact owned buffer
that is about to be sent. `Response_Body` is reported from the chunk callback the
operation already passes to `http_post_sse`, which is the one place the plaintext response
bytes pass through. The operation's failure and completion are not reported: the caller
already receives them as the return value and as the completion event, and a second
channel for one fact is one too many. The hook is generic over APIs; `ai` gains no
per-provider branch.

The report carries the model and the tool count the body was built from rather than a value
decoded back out of it. `Provider_Validate_Request` has already refused a request whose
model is missing or empty, and `Provider_Encode_Request` validates again, so a body without
a model cannot be produced here; the body digest covers the bytes themselves.

This is provider protocol work, which is what `ai` is: the encoded body of a provider
request is an `ai` fact, and no other layer can observe it before it is freed.

The transport-level facts that `ai` does not own, the plaintext bytes actually handed to
the socket and the declared response length, need an observer inside `http/client`. They
are deliberately deferred: the encoded digest, the response byte count, and the
transport failure kind already answer whether a request was sent and whether anything came
back, and an observer in the HTTP library is only worth adding when a question needs it.

### 8.3 What deliberately does not change

- `sse` gains nothing. An SSE parse failure already reaches `ai` as an error and leaves as
  `Provider_Operation_Error` with kind `.Stream`, and `provider_http_chunk` already sees
  every plaintext body chunk, so a byte offset can be counted where the chunks arrive.
- `mcp` gains nothing in this version. `mcp.Error.delivery` already distinguishes delivered
  from not delivered, `agent/tool_mcp.odin` already receives a bounded stderr excerpt, and
  the remote tool name at dispatch is chosen by `agent`, so it knows it by construction. If
  correlation with a server's own logs later requires the JSON-RPC id, that is added inside
  `client_exchange`, where the id is assigned, in MCP vocabulary, and not before.

### 8.4 Bridging

`agent/log_provider.odin` holds the state one provider operation reports into
(`Provider_Log`: the scope its records carry and the running response byte count) and the
observer that turns each report into a record. The state lives in the frame of
`chat_perform_request`, so it outlives the operation and never outlives the turn.

Rules for the bridge, which are the reason it is its own file:

- A report is borrowed for the call and never retained: the bridge hashes the body and
  writes values, so nothing points into memory the operation frees. A test that copied the
  body into a thread's temporary allocator was caught by the address sanitizer, which is
  the rule enforced rather than stated.
- The bridge holds no policy that belongs to a lower layer and no transport type.
- The callback does not mutate what it observes. Odin slices are mutable; the contract is
  read-only, and the buffer owner stays alive until the operation retires.

### 8.5 Byte accounting

The log distinguishes these quantities and never presents one as another:

1. encoded request body bytes, hashed over the exact buffer handed to transport;
2. request body bytes the transport reports as written, deferred with the transport
   observer;
3. response body bytes received and passed to framing and parsing, counted per attempt;
4. bytes stored in a capture, which may be a bounded prefix of (1) or (3), and arrives with
   capture support.

`Content-Length` is reported as the declared value and separately from the body bytes
actually observed. Response capture is the de-framed body byte stream before SSE parsing,
not TCP packets, and it does not assume one event per chunk.

A successful local write does not mean the remote received anything. The transport cannot
prove remote receipt, and no record claims it.

For a non-2xx response, `http/client` stops reading at `HTTP_MAX_ERROR_BYTES`, so the
response is not fully observed: such a capture records `observed_complete=false` and
`stop_reason=error_reader_limit`, and the bounded excerpt continues to reach the caller
through `Failure.detail` unchanged. Draining extra remote bytes only to complete a capture
is not done, because it would change error semantics for a diagnostic.

## 9. Lifetime, threading, startup and shutdown

Root owns one `Log` in its run setup, opens it before the session store and before any MCP
process is launched, and closes it after the worker has stopped. The writer reaches the
harness through `Chat_Session.log`, a borrowed field set when the session is built: every
procedure that acts on a session already receives the session, so no call site has to
thread a writer of its own. It is not a package-level variable, and it is not smuggled
through `context.user_ptr`. A nil log, or one that was never opened, makes every emit a
no-op, so the harness runs identically with diagnostics off.

Serialization happens entirely under the writer mutex into writer-owned scratch, then one
write per record with EINTR and short-write handling. There is no logging thread, no queue,
and no batch timer. This is what keeps a string allocated on `context.temp_allocator` or
owned by a provider callback from being retained past its lifetime.

I/O is synchronous and can stall on a broken filesystem. That is an accepted limit of the
first version, not a claim that logging cannot block. Recommended storage is local state.
A bounded writer queue is added only if measurement shows unacceptable stalls, and it would
need owned messages and an explicit drop policy.

No diagnostics call acquires a store lock, invokes an application callback, or emits while
holding the writer mutex. Call sites emit outside `app.run.mu` and never from a signal
handler, which only sets the existing cancellation state.

Startup order:

```text
resolve state directory and diagnostic options
  -> take the cleanup lock
  -> make the private run directory, take its lease, open the first segment
  -> remove closed runs until the retention bounds hold
  -> release the cleanup lock
  -> run.started
  -> open store, configuration, and MCP clients
  -> start the worker with a borrowed Log
```

A pass that removed anything records `retention.finished` before `run.started`, so the
first record of a run that collected nothing is still the run's own header.

Shutdown order:

```text
request stop -> worker observes cancellation -> durable work settles
  -> finish or abort operation captures -> stop and join producers
  -> destroy clients, session, store -> run.finished
  -> close the segment and release the lease
```

Failed initialization unwinds in the same reverse order for the resources that were
actually acquired. Nothing is released on the strength of a cancellation request alone, as
`Chat_Operation_State` already states.

## 10. Storage, capture and privacy

Default root: the existing resolved state directory plus `logs/`, normally
`~/.local/state/nabla/logs/`, resolved through `agent/xdg.odin` with `XDG_Kind.State`.
There is one definition of that precedence, not two.

```text
logs/
  cleanup.lock
  runs/
    <run-id>/
      lease
      events-000001.jsonl
      events-000002.jsonl
      captures/
        000012-request.body.part
        000012-request.body.json
        000031-response.body
        000031-response.body.json
```

Directories are 0700 and files 0600. Descriptors are close-on-exec. Creation is exclusive
and symlinks are not followed. A prefix on a capture file is written by the writer and
contains a numeric artifact id and a fixed kind name; no model, tool, URL, or session text
appears in a path.

Default records omit prompts, instructions, tool arguments, file contents, command text,
tool output, environment values, raw exceptions, and configuration dumps. Endpoints are
recorded as provider id plus sanitized origin and path, never userinfo, query, fragment, or
credentials. Response headers are not recorded wholesale; a status, a declared length, and
a provider request id when it is specifically needed are allowlisted and capped. The
`authorization` header and every other credential never enter a record or a capture.

Provider error text is recorded. A refused request is diagnosed by the peer's own message,
and the transport already bounds what it reads (`HTTP_MAX_ERROR_BYTES`, and
`HTTP_MAX_ERROR_EXCERPT` for the text it keeps), so a record carries bounded text rather
than a body. That text can echo part of the request, so a record is not safe to publish
unreviewed: the file is owner-only, credentials are never part of a response body, and the
capture policy below still governs the full bytes.

Capture policy, first version, read only by root:

- `NABLA_LOG_LEVEL=off|error|warn|info|debug|trace`, default `info`.
- `NABLA_LOG_CAPTURE=off|payloads`, default `off`.

An invalid value warns once and falls back to the safe default; it never enables capture.
Capture does not override `off` logging. There is no provider-specific setting, and a later
Lua setting reuses the same `Log_Options` rather than adding a second parser.

`payloads` is explicit consent to sensitive local content: provider request and response
bodies, MCP payloads, and MCP stderr. It does not capture authentication headers or the
process environment. Captured bodies can themselves contain secrets. Raw bytes and
guaranteed redaction are incompatible, so the mode is not described as safe, and enabling it
prints one local warning through the normal notice path.

Each capture owns its fd and two incremental SHA-256 contexts, one for observed bytes and
one for stored bytes. It borrows its `Log` only for quota and summary updates, and it
consumes chunks synchronously. After the storage allowance is exhausted, it keeps counting
and hashing observed bytes without storing them. A digest therefore describes what was
observed, never bytes that were never delivered to the hook.

`log_capture_finish` closes the payload, then writes a bounded metadata sidecar through a
temporary file and a rename. The sidecar, capped at `MAX_RECORD_BYTES`, carries the format
version, full correlation, kind, observed and stored counts, observed and stored digests,
and the completeness, truncation, and error facts. A stored artifact can be a complete
observation and a truncated copy at the same time; the two flags are separate.

A crash between payload and sidecar leaves a `.part` file or a final file with no sidecar.
Readers never infer completion from a filename, and an orphan is never promoted to a
successful request. A failed capture cannot fail the model request or stop stream
consumption.

A capture never splices a head and a tail into something presented as exact input. It
stores a prefix and reports the absent suffix length. An exporter may produce a preview
with explicit omitted ranges, but that preview is never named an exact body.

## 11. Bounds, rotation and retention

| Limit | Value | Meaning |
|---|---:|---|
| `MAX_RECORD_BYTES` | 64 KiB | one encoded record including its newline |
| `MAX_FIELD_STRING_BYTES` | 4 KiB | scalar text cap before escaping |
| `SEGMENT_BYTES` | 8 MiB | rotate before a record would cross the boundary |
| `SEGMENTS_PER_RUN` | 4 | current segment plus three preceding |
| `CAPTURE_BYTES` | 8 MiB | stored bytes per artifact |
| `CAPTURE_BYTES_PER_RUN` | 64 MiB | stored payload per run, sidecar metadata excluded |
| `CAPTURES_PER_RUN` | 128 | artifact slots per run, incomplete files included |
| `CLOSED_RUN_BYTES` | 256 MiB | cleanup target across inactive runs |
| `CLOSED_RUN_COUNT` | 128 | binds small-run directory proliferation |
| `RETENTION_AGE` | 14 days | closed runs expire at cleanup |

Rotation closes the current segment and opens the next increasing number. A numbered
segment is never renamed onto another. The oldest segment is deleted only after the new one
is open, and the removed sequence range is recorded in the new segment so a reader can
report a gap. One run therefore holds at most about 32 MiB of records plus bounded captures,
and every record fits inside one segment.

Capture admission reserves per-run bytes and one artifact slot under the writer mutex. Once
the quota is exhausted, later captures are declined and one warning plus counters are
emitted; a live capture is never evicted and nothing grows without bound. Metadata summaries
remain available after payload admission is exhausted.

Cleanup runs once per launch, while the run directory is being created and the cleanup
lock is held. There is no background thread and no periodic pass: a run bounds its own
segments as it writes them, and what other launches left behind is collected by the next
launch. Run-local rollover holds its bounds even during a very long turn; global retention
is eventual and skips live runs, so total usage can exceed `CLOSED_RUN_BYTES` while many
processes are active. That is stated rather than promised away.

Liveness is an exclusive lock, not a timestamp and not a process id:

1. A run holds an exclusive lock on its own `lease` for its whole life. The kernel releases
   it when the process dies, so a crashed run is collectable without any cleanup step.
2. A cleanup pass holds the exclusive `cleanup.lock` for the whole pass. Creating a run
   takes the same lock, blocking, so a cleaner can never meet a run directory that has no
   lease yet. The lock file is never unlinked: replacing a locked inode would let two
   processes hold what each believes is the same lock.
3. Under that lock, each candidate's lease is probed with a non-blocking lock. A lease that
   cannot be taken means the run is alive and is kept; a run whose lease is missing or free
   is closed or orphaned and is collectable. Symlinks and names that are not run ids are
   left alone rather than followed.
4. Expired runs are removed first, then the oldest until the count and byte targets hold. A
   future timestamp does not block size-based eviction, because the count and byte bounds
   are evaluated independently of age.
5. Failures are counted and reported, not fatal. Directory iteration is bounded to 4096 runs
   per pass, so a huge or hostile directory cannot stall a launch.

An existing run directory is never adopted by a new writer, and PID existence is never used
as proof that a run is alive.

## 12. Failure and durability contracts

- A record is written immediately to the operating system, without a userspace delay. It is
  not fsynced per line. A process crash normally preserves completed writes; machine or
  power failure can lose them. Neither JSONL nor captures are a write-ahead log.
- `log_close` reports flush and close errors. An explicit export may fsync its own finished
  files and directory when asked; it cannot make old records durable retroactively.
- EINTR retries and short writes advance by the actual count. An unrecoverable error
  disables the event sink and latches the failure, and no further record is appended after a
  broken line.
- There is no automatic reopen loop on disk-full or permission failure. Root shows one
  warning and status reports diagnostics unavailable; a later process may try again.
- A capture failure disables that capture only. A retention failure does not stop writing
  while space remains.
- Allocation failure in a diagnostics path drops the record and counts it. Initialization
  fails gracefully. No diagnostic path allocates merely to discover that a record is too
  large.
- No records are written from a fatal signal handler. SIGKILL may leave no final record, and
  a missing `run.finished` means an unclean end of unknown cause, not a diagnosed one.
- A malformed final line is ignored with a truncation warning. A malformed interior line is
  reported with segment and offset and skipped, never executed.
- Cancellation is recorded as requested and observed when both are known. Terminal
  classification follows the existing rules, including deadline and cancel precedence.
- A partial record followed by an unrecoverable error leaves the sink disabled rather than
  emitting a second half-line.

## 13. Reading a session

One command reads the logs, parsed beside the existing `chat_cli_options`:

```text
nabla diagnostics <session-id>
```

`agent/log_read.odin` holds the reader: it walks the run directories oldest first, reads
whole segments, parses each line far enough to know which session it belongs to, and calls
a visitor with the record as it was written. It parses the line rather than searching it,
because a record may carry text a peer sent and that text must not be able to name another
session. Records are selected by the session field rather than by a file name, so a session
that spans runs is read across all of them, and a run that holds several sessions
contributes only the records that belong to the one asked for.

The command lives in root, which already resolves the logs directory and imports the
reader. Records go to stdout exactly as written, so a caller can pipe them into `jq`, and
the count of what was read goes to stderr together with everything the reader could not
read: an unlistable run directory, an unreadable segment, or a line that does not parse.
That distinction is the point. A diagnostic view that silently omits evidence is worse than
one that names it. The command exits 1 when the session left nothing, and 2 for a bad
argument.

Run framing (`run.started`, `retention.finished`, `run.finished`) carries no session and is
not part of a session's stream; the run a record came from is a field of the record, and
its own directory holds the framing. Including it is a later step, not a silent omission.

Still to build in this phase:

- the join with the session database, so a request's stored outcome and usage appear
  beside its records, through a read-only connection rather than the store's writable one
- an export bundle with a manifest, bounded pages, and an opt-in for payloads and session
  content
- a `--request <number>` selection, and a level threshold so a reader can skip debug records
  without `jq`

The reader is batch-only. If follow mode is ever needed, it uses the cursor `(run_id, seq)`
and rescans new segments, and it never claims atomic live replay across SQLite and JSONL.

The export bundle, when it exists, is laid out as:

```text
manifest.json
session.jsonl
runs/<run-id>/events.jsonl
runs/<run-id>/captures/<artifacts, only with explicit inclusion>
```

The manifest records build and format versions, the selection, the snapshot time, per-file
length and digest, retained sequence ranges, and every missing, truncated, or disabled piece
of evidence. It states the privacy policy in force. Destination creation is exclusive with
0700 and 0600 permissions. The default export contains correlated metadata only. Session
prompt and content fields are sensitive too, so they are omitted unless
`--include-payloads` is given, which is the same flag that includes raw artifacts.

The default total export cap is 32 MiB. The manifest and the failure-centered metadata go
first, then the selected request and entry summaries, then opted-in artifacts within the
remaining budget. Every omission is recorded with its reason, and unrelated recent requests
are never added to fill a quota. Inactive run leases are pinned while copying; an active
writer is append-only, so a segment is read only up to its initial size and its incomplete
tail is ignored. A rotation race produces an explicit missing-file notice.

## 14. Walkthroughs

**A remote error about an unknown or blank model.** Find the logical request in the
database, then its `provider.encoded` record: api, model, tool count, body length, digest,
and the response byte count on the `attempt.finished` that followed it. `ai` rejects a
missing or empty model before encoding, so a record cannot show an empty model unless the
harness itself is broken, and the digest makes the encoded bytes checkable rather than
inferred. A response byte count of zero with a transport failure says nothing was received,
while a count with a status says the peer answered. The bounded excerpt already reaches the
caller through `Failure.detail`. What the log cannot establish is how a gateway routed a
model it received; it records which model it sent and when.

**A rejected tool name.** Compare the canonical name, the advertised wire name, the encoded
inventory recorded at `provider.encoded`, the name in `tool.call_received`, and the resolved
canonical name in `tool.name_resolved`. Native Responses replay is inspected separately from
projected historical calls. This shows whether the harness advertised, sent, or resolved the
wrong name, without assuming which layer was at fault.

**An MCP server reporting an unknown tool.** Follow `call_seq` to the server id and instance,
then compare the discovery remote name, the binding name, and the name sent in `tools/call`.
Record generation changes and restarts. Delivery state comes from `mcp.Error.delivery`, and a
missing result is reported as unknown rather than as failure.

**A crash during a tool.** A committed dispatch with no committed result stays unknown even
if the log holds an observed result. The report shows both the observed diagnostic outcome
and the durable recovered outcome, and the tool is never retried on the strength of missing
records.

## 15. Implementation sequence

Each phase is one scoped change. Unrelated tool or request-shape fixes do not ride along.

### Phase 1: the writer in `agent`

`agent/log.odin` with `Log`, `Log_Options`, `Log_Level`, `Log_Category`, `Log_Value`,
`Log_Field`, `Log_Record`, `Log_Context`, `Log_Health`, `Log_Error`, zero-safe open and
close, run identity, synchronous escaped JSONL, sequence, health, and size rollover. The
flat scalar encoder is written directly rather than through `core:encoding/json`, which
allocates an object tree for a record that must be encoded into a fixed buffer with no
allocation at all.

Tests: quote, backslash, control byte, and invalid UTF-8 escaping; a record that repeats a
key or shadows an envelope key is rejected; a zero `Log_Context` emits nothing; the
sequence increases with every record; an injected write failure disables the sink exactly
once; an oversized record becomes the omission record; rollover keeps the configured
window; the run directory and its segments are owner-only. Run `mise run test agent` and
`mise run check`.

### Phase 2: run lifecycle and retention

`agent/log_lock.odin` with `agent/log_lock_linux.odin` behind it holds the one operation
no core package abstracts, and `agent/log_retention.odin` holds the policy: a lease per
run and one bounded cleanup pass per launch. `app_log.odin` reads the level from the
environment, opens and closes the writer around the run, and records `run.started` and
`run.finished`. A launch whose log cannot be opened reports it once on stderr and carries
on without one; no record is ever written to stdout or the terminal.

Tests: a leased run is kept even when it is past every bound; an expired closed run is
removed; an unleased orphan is removed; the count and byte bounds keep the newest runs; the
level names round trip. Run `mise run test agent` and `mise run test .`.

### Phase 3: harness correlation and events

`agent/log_bridge.odin` holds the scope a record is emitted against and the log's names
for the enums other packages define. The request lifecycle is recorded from
`agent/chat.odin`: `request.prepared`, `request.recorded`, `attempt.started`,
`attempt.finished`, `request.retry`, `request.finished`, and `tool.name_resolved` where
the name the model sent becomes the name the harness resolves. `agent/chat_session.odin`
records `turn.started`, `turn.finished`, `agent.event_ignored`, and `storage.failed` at
the single place a durable write failure lands. `agent/chat_tools.odin` records a tool call
from `tool.call_received` through `tool.dispatch_committed`, `tool.execution_started`, and
`tool.execution_finished` to `tool.result_committed`, each under the call's own id.

The writer travels in `Chat_Session.log`, borrowed and set once when the session is built,
so no call site threads one of its own. No new identity is introduced: `chat.turn_no`,
`chat.active_request`, `chat.request_attempts`, and `chat.active_operation_id` are what the
records carry, and the schema stays at version 4.

Tests: a cancelled turn records its own start and end with the session and durable turn; an
event from a superseded turn is recorded with the reason it was refused; a tool call is
recorded from the proposal through the dispatch and execution to the committed result, in
that order and under its own call id; and a turn driven with a writer records the same
durable entries and call count as the same turn driven without one, which is the property
that logging observes a turn rather than taking part in it. Root records
`session.claimed` and `session.recovered` where it claims the session and settles what an
earlier run left. Run `mise run test agent`, `mise run test .`, and `mise run check`.

Still to record: compaction requests, which run outside a turn, and the session release
that root performs at teardown.

### Phase 4: provider observation, transport accounting, and capture

The provider observation is implemented: `Provider_Operation_Observer` in
`ai/request.odin`, reported at encode time and from the response chunk callback, and the
bridge in `agent/log_provider.odin` that turns it into `provider.encoded` and a response
byte count on the attempt that ends. The report borrows its bytes for the call only, so the
bridge hashes the body and records values rather than keeping a pointer, and a test that
kept one was caught by the address sanitizer.

Tests: the transport fixture reports what one operation encoded and received, and the bridge
records the digest of those exact bytes, checked against a digest computed outside the code
under test. Run `mise run test ai`, `mise run test agent`, and `mise run test .`.

Still to build in this phase, when a question needs it: the `Transfer_Observer` in
`http/client` for the bytes actually handed to the socket and the declared response length,
and `agent/log_capture.odin` with its quotas, sidecar metadata, and the
`NABLA_LOG_CAPTURE` switch. A capture would store the same borrowed body the bridge hashes,
so the pieces that exist are the ones it needs.

### Phase 5: MCP and tool evidence

Emit `mcp.started`, `mcp.negotiated`, `mcp.stopped`, and the refresh events from
`app_mcp.odin`, which owns launching clients and keeping the binding generations. Emit
`mcp.exchange_started`, `mcp.exchange_finished`, and `mcp.stderr` from
`agent/tool_mcp.odin`, which owns the call and the outcome it receives. `mcp` itself is
unchanged: delivery comes from `mcp.Error.delivery` rather than being inferred, and the
remote name being sent is the one `agent` chose. `tools/call` is never automatically
retried, and the log preserves that.

Tests: a remote name containing underscores and dots; a renamed local alias; a disabled
discovery entry; a server restart; a malformed reply; a timeout after send; stderr
containing a newline and a secret; an unavailable tool. Assert that the encoded remote name,
the wire name, and the canonical name appear only in the fields that mean them. Run
`mise run test mcp`, `mise run test agent`, and `mise run test .`.

### Phase 6: reading and export

The first slice is implemented: `agent/log_read.odin` walks the runs oldest first and
visits the records of one session, and `app_diagnostics.odin` prints them as they were
written while reporting what could not be read. Tests hold the reader to records the writer
produced: only the session's own records are visited, runs are read oldest first, an
unparseable line is counted rather than passed off as a record, and only the writer's own
file names are read.

Still to build: the join with the session database, the export bundle with its manifest,
`--request`, and a level threshold. Each is described in §13.

Run `mise run test agent`, `mise run test .`, and `mise run check`.

`mise run check` accompanies code changes, and `mise run fmt` formats Odin. The full
monorepo suite is not the per-change gate; a change that stays inside `agent` is covered by
`mise run test agent`.

## 16. Deliberate limits

The first usable version is phases 1 through 5. Given a failed request with capture off, it
reconstructs the phase, attempt, correlation, encoded model and body evidence, tool
resolution, and durable commit state. With capture on it states exactly which observed bytes
were kept and which were not. Phase 6 makes that evidence usable from the command line.

Not included: OTLP, remote upload, metrics backends, a live event bus, a trace-tree UI,
per-token Info records, a global logger, a logging thread, a second SQLite event store, and
a diagnostics package. Not promised: power-loss durability, a hard quota across unlimited
concurrent processes, and safety to publish metadata or captures without review.

Extend only when a debugging need is observed. The structure above follows one request from
preparation through transport, tool execution, and committed recovery state without making
diagnostics a second execution system.
