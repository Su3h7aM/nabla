# Harness logging and diagnostics architecture

Status: authoritative architecture, implemented. The writer, context migration,
correlation, lifecycle records, provider and MCP capture, transport accounting, reader,
export, and the request join are all in place. Section 4.1 records what the migration
closed and what was decided against; section 15 records what each phase now contains and
the gate this work was held to. Follow mode is the one explicit non-goal.

This plan is based on the complete *Nabla Logging Reference Study: goose + opencode*,
including its appendices, at
`/home/su3h7am/.opencode/plan/nabla-logging-reference-study.md`. The research describes
local source trees, not promises about upstream releases. The relevant code was checked
directly while preparing this plan. The reference decisions and source paths below make
the design understandable without that machine-local file.

## 0. Ownership in one paragraph

Diagnostic policy is harness behaviour; logger dispatch is already provided by Odin.
Session identity, turn structure, request retries, tool dispatch, model selection,
recovery, and retention are all harness concepts, so the log
implementation lives in `agent`, next to the state machine that produces those facts, and
the process wiring lives in the root `nabla` package that owns the process. No new package
is created. The reusable libraries below `agent` stay reusable: `http` and `http/client`
own the HTTP protocol, `sse` owns event-stream framing, `ai` owns provider wire protocols
and the operation that performs one, and `mcp` owns the MCP protocol. Each of those may
expose facts about its own operation in its own vocabulary. Libraries may use `core:log`
for ordinary diagnostics through the caller's `context.logger`. They must not contain
Nabla thresholds, file destinations, sessions, turns, retention, or capture policy.

### 0.1 Start with Odin

Before adding a mechanism, inspect the installed `core:` and `base:` APIs and source.
Use the standard mechanism when it meets the contract; document the missing requirement
when custom code remains. A language facility is not a global registry or a framework.
`context.logger` is Odin's scoped, implicit parameter for logger dispatch.

Verified against `odin version dev-2026-09-nightly:a2fb372` and the source under
`odin root`:

- [Official logging documentation](https://pkg.odin-lang.org/core/log/) and
  [implicit context documentation](https://odin-lang.org/docs/overview/#implicit-context-system).
- `base/runtime/core.odin`: `Logger`, `Logger_Proc`, `Logger_Level`, and `Context`.
  `Logger` contains `procedure`, `data`, `lowest_level`, and `options`.
- `core/log/log.odin`: `log` and `logf` check for a nil/no-op logger and filter before
  formatting. They format with the temporary allocator, then synchronously call
  `Logger_Proc`. The callback receives level, text, options, and caller location, not
  typed event fields. `fatal` logs; `panic` and failed assertion helpers also abort.
- `core/log/file_console_logger.odin`: the stock sinks format human-readable lines,
  do not implement our health or retention contracts, and do not provide the writer
  synchronization required here. The console sink also writes lower levels to stdout.
- `core/thread/thread.odin`: a thread with no `init_context` receives
  `runtime.default_context()`, not its creator's modified context. Explicit initial
  contexts also change responsibility for temporary allocator cleanup.
- `core/encoding/json/marshal.odin`: `marshal_to_writer` can serialize directly to
  `io.Writer`; JSON serialization does not inherently require an object tree.
- `core/io/util.odin` and `core/unicode/utf8/utf8.odin`: standard UTF-8 decoding is
  available. In this version, `io.write_quoted_string` emits `\xNN` for invalid bytes
  even with `for_json = true`, so it cannot directly implement our replacement policy.

The design uses a custom `log.Logger` callback backed by the existing `agent.Log`.
Keep only the parts `core:log` does not supply: typed diagnostic fields, correlation,
bounded JSONL encoding, sink health, private storage, rotation, retention, and capture.
There is no replacement logger interface, subscriber system, or package-global logger.
Recheck these APIs against the installed compiler before implementing the migration.

## 1. What the system must answer

Given a session and a failed request, identify:

- Which process, turn, logical request, retry attempt, and operation performed it.
- What model and tool inventory were prepared and encoded, and how many plaintext request
  bytes the HTTP transport or TLS layer accepted.
- Whether failure occurred during preparation, DNS, connect, TLS, write, response headers,
  body framing, SSE parsing, provider decoding, dispatch, or persistence.
- Which tool identity the model returned, which canonical identity Nabla selected, and
  which remote MCP name and JSON-RPC line were encoded, with `Delivery_State` kept
  separately.
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
| `http`, `http/client` | the HTTP protocol | transfer phases, plaintext byte counts, status, declared length, failure kinds | sessions, turns, harness requests, providers, models, Nabla logging policy, log destinations, retention, a hook named after the harness |
| `sse` | text/event-stream framing | unchanged in this plan | harness policy |
| `ai` | provider wire protocols and one provider operation | the encoded request body it just built, the response body stream it already receives, provider operation outcomes | Nabla thresholds, log files, session correlation, retention, `agent` types, per-provider logging rules |
| `mcp` | the MCP protocol | exact framed messages borrowed by an optional operation observer | harness policy, log files, session correlation, capture quotas |
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

No new package means no `scripts/test`, `scripts/check`, or `scripts/build` registration.
Use the existing affected-package tasks and the full gate specified in section 15.

If a future need is genuinely reusable, the test is one question: could an unrelated Odin
program use it without knowing what a session is? Until that is true, extend `agent`.

### 3.3 Files

Inside `agent`, beside the state machine:

| File | Contents |
|---|---|
| `agent/log.odin` | typed records using `log.Level`, categories, `Log`, open/close, bounded JSONL encoding, sequence, rollover, health |
| `agent/log_lock.odin`, `agent/log_lock_linux.odin` | the exclusive file lock a lease and the cleanup lock are built on; the platform file holds the one call no core package abstracts |
| `agent/log_retention.odin` | run directories, leases, bounded cleanup |
| `agent/log_capture.odin` | opt-in payload capture: admission, chunk append, digests, sidecar metadata, abort |
| `agent/log_read.odin` | parsing and scanning a run directory for diagnosis and export |
| `agent/log_bridge.odin` | `core:log` adapter, scoped correlation bindings, structured emission entry point, stable names for domain enums |
| `agent/log_provider.odin` | provider and transport observations for one attempt: what was encoded, what the HTTP client accepted, where it stopped, and what came back |
| `agent/log_mcp.odin` | MCP exchange records and the bridge from borrowed wire messages to opt-in captures |
| `agent/chat.odin`, `agent/chat_session.odin`, `agent/compact.odin`, `agent/tool*.odin` | emit calls at the boundaries they already own |
| `agent/log_test.odin`, `agent/log_events_test.odin`, `agent/log_retention_test.odin`, `agent/log_read_test.odin` | unit tests |

Inside the root package:

| File | Contents |
|---|---|
| `app_log.odin` | environment policy, writer lifetime, run-level logger binding, health notices, `run.started` and `run.finished` |
| `app_worker.odin` | install the worker's logger without replacing its allocator context |
| `app_diagnostics.odin` | `nabla diagnostics <session-id>`: the reader's records to stdout, what was read and what could not be to stderr |
| `main.odin` | the `diagnostics` subcommand, alongside `chat_cli_parse` |
| `app_command_test.odin` | CLI parsing tests |

Inside the libraries, only where a fact currently cannot leave the layer:

| File | Change |
|---|---|
| `http/client/control.odin` | optional final `Transfer_Observer` in `Options` |
| `http/client/client.odin`, `http/client/connection.odin` | collect one transfer summary and report accepted plaintext request bytes without exposing headers or bodies |
| `ai/request.odin` | carry the provider-owned form of the transfer summary through the existing operation observer |
| `ai/http.odin` | map the HTTP summary into provider vocabulary |
| `mcp/control.odin` | operation-scoped `Operation_Options` carrying the existing control and an optional `Wire_Observer` |
| `mcp/client.odin` | report complete outgoing and incoming JSON-RPC lines while they are borrowed |
| `db/sqlite/sqlite.odin` | explicit read-only open mode using `SQLITE_OPEN_READONLY` |
| `agent/session/store.odin` | non-creating, non-migrating `store_open_read_only` |

### 3.4 Observation chain

```text
http/client.Transfer_Observer            one final HTTP transfer summary
        -> ai/http.odin                  provider-owned transfer facts
ai.Provider_Operation_Observer           transfer summary, encoded body, response chunks
        -> agent/log_provider.odin       attempt records and provider captures

mcp.Wire_Observer                        borrowed complete JSON-RPC lines
        -> agent/log_mcp.odin            MCP metadata and opt-in captures

context.logger binding                   scoped correlation and sink selection
        -> agent.Log                     format, sequence, rotation, retention

core:log calls in any package
        -> context.logger.procedure     ordinary messages with caller location
        -> the same agent.Log           one sequence, mutex, health, and destination

root owns Log, logger bindings, startup, shutdown, and health presentation
```

This is runtime data flow, not an import graph. Callback dispatch does not make a library
import its caller. `ai` knows nothing about who observes it, and the observer may be zero.
Ordinary logging needs no new observer API. Observers remain only for typed protocol facts
and borrowed payloads that text logging cannot carry.

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
| the exact encoded request body | implemented borrowed report from `Provider_Request_Operation_Controlled` before deletion | preserve the report; migrate the bridge |
| HTTP stop phase, accepted plaintext request bytes, declared response length | not exposed | one final `http/client` transfer summary, mapped through `ai` |
| MCP delivery state | `mcp.Error.delivery` (`Delivery_State`) | none |
| exact MCP JSON-RPC messages | encoded and framed inside `mcp/client.odin`, then released or decoded | operation-scoped borrowed wire observation and opt-in capture |
| MCP server stderr excerpt | `TOOL_MCP_STDERR_EXCERPT` in `agent/tool_mcp.odin` | metadata only; raw stderr capture is rejected |
| process start and end | implemented `run.started` and `run.finished` | correct lifetime coverage and report sink/close failures |
| storage commit results | `agent/session` returns | emit calls only |

### 4.1 What the migration closed, and what was decided against

Closed by the migration and the phases that followed:

| Gap | How it was closed |
|---|---|
| No assignment to `context.logger`; a custom writer passed through session and tool state | `Log_Binding` holds the sink and the correlation, `log_logger` turns it into a `core:log.Logger`, and the scope that owns the run installs it. `Chat_Session.log`, `Tool_Context.log`, and `Log_Context` are gone |
| Custom reversed `Log_Level` with `Disabled` and unused `Trace` | Severity is `core:log.Level`; enablement is a separate fact; the unused level is gone |
| `Provider_Log` created outside the retry loop | The observation is created per attempt, so a retry that receives nothing reports zero and `provider.encoded` carries its own attempt |
| Operation identity promised before it existed | Correlation is recorded when each identity exists; preparation and a failed insert invent nothing |
| Writer validated UTF-8 continuation shape only | `core:unicode/utf8` decoding, so overlong, surrogate, and out-of-range sequences are replaced |
| `Log_Value` permitted nil | An unset value is rejected; JSON null is not part of the field contract |
| No scalar cap; the encoder kept scanning after overflow | The scalar and field caps are enforced before encoding, and encoding stops when scratch fills |
| Rotation omitted deleted sequence ranges | The writer keeps a bounded ring of closed segment spans and writes `log.segment_removed` with the range and whether deletion succeeded |
| Retention counted failed deletions as removed; a lease-probe error read as inactive | A run counts as removed only once its directory is gone; unknown liveness is kept and reported; nested capture payloads count toward the byte bound |
| Root ignored `log_close` errors and never surfaced latched failure | The close error is reported on stderr after the terminal is gone, and a latched write failure is surfaced once at a work boundary |
| Reader accepted any matching object and only six-digit segment names | The envelope's version and run id are checked before its contents are believed; segment order comes from the parsed number; a symlink is never followed; a segment is read only up to the size it had when the read began |
| Existing open paths did not enforce the full no-symlink contract | Segment reads use `lstat` and never follow a link |
| The transport could not say how far a request got | `http/client` reports one summary per request: the stopping phase, accepted plaintext bytes, request completeness, status, and declared length. `ai` maps it and `attempt.finished` carries it |
| Nothing could observe an MCP message before it left or after it arrived | `mcp.Operation_Options` carries an operation-scoped observer that borrows complete JSON-RPC lines; `agent` captures each line as its own artifact |
| The session database could only be opened for writing | `sqlite.Open_Mode` and `session.store_open_read_only` read it without a claim, creation, or migration; `diagnostics --request` reports the row and the export writes `request.json` |
| A library diagnostic that reaches `context.logger` now reaches a file | The `http` producers carry structural facts rather than request targets, request and header lines, and file paths. Reviewed: what remains interpolates only error enums, socket numbers, byte counts, and the request method |
| `storage.failed` carried the store's raw message | It records the classification and the detail's length; the text stays in the session's own last error, which the front-end shows |

Decided against, and why:

| Item | Decision |
|---|---|
| MCP stderr capture | Not implemented. Stderr belongs to the server process rather than to one JSON-RPC operation, and the drainer runs on another thread with no request correlation. The bounded excerpt and byte count on failure stay as they were |
| Follow mode and live replay | Not implemented. Batch read and bounded export answer the current debugging need, and a live tail would need its own rotation and retention contract. The `(run_id, seq)` cursor is in the format if a later feature wants one |
| Non-2xx response body capture | Not implemented. The transport already reads a bounded excerpt for `Failure.detail`, and draining more would change transport work for diagnostics |
| SQLite `immutable=1` for the read-only reader | Not used. A harness may be writing the write-ahead log at the same time, and immutable mode disables the change and locking checks that make that safe |

Redaction does not belong in the sink, because formatted text has already lost its field
boundaries. A UI notice, command stdout, and a diagnostic record remain three different
destinations.

### 4.2 Constraints

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
  exposes at most `HTTP_MAX_ERROR_EXCERPT` (2000) bytes of excerpt in `Failure.detail`.
  The error reader may stop before the body ends; do not claim complete observation
  without a protocol fact establishing it.
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
import "core:log"

// A zero options value opens nothing. Severity is Odin's type, not a second enum.
Log_Options :: struct {
	directory: string,
	enabled:   bool,
	lowest:    log.Level,
}

// Category names the part of the harness a record came from. Values are written
// out by name, never by ordinal.
Log_Category :: enum {
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
	level:    log.Level,
	category: Log_Category,
	event:    string,
	fields:   []Log_Field,
}

// Identifiers are borrowed for one synchronous scope, never a second identity store.
Log_Correlation :: struct {
	session_id:   session.Session_Id,
	turn_no:      session.Turn_No,
	request_no:   session.Request_No,
	attempt:      int,
	operation_id: u64,
	call_id:      string,
}

// Caller-owned at a stable address until the logger scope ends. Does not own sink.
Log_Binding :: struct {
	sink:        ^Log,
	correlation: Log_Correlation,
}

// API signatures; definitions live in agent, not in a new package.
log_logger :: proc(binding: ^Log_Binding) -> log.Logger
log_emit :: proc(record: Log_Record)
```

`log_emit` has no result: diagnostics never decide whether useful work continues.
Rejects, omissions, writes, and sink failures update `Log_Health`. Remove the existing
`Log_Emit_Result` once its tests check output and health instead. Open, close, read, and
capture admission still return concrete errors or result data because their owners need
to decide how to proceed.

A nil binding, zero `Log_Binding`, nil sink, or unopened sink produces `log.nil_logger()`. Zero
correlation means a run-level record, not disabled logging. `log_logger` returns a value
that borrows the binding; it does not allocate or take ownership of the sink.

`log_emit` consumes every borrowed value synchronously. It never stores a `Log_Record`, a
correlation value, a field slice, or a field string. Field names and event names are literals
owned by the producing module. Strings are length plus bytes, not C strings. JSON escaping
handles NUL, quotes, backslashes, control characters, and invalid UTF-8 through one
explicit replacement policy. Binary data goes to a capture, never into a string field.
A field key that repeats another key, or that collides with a reserved envelope name, is
rejected. An unset `Log_Value` is rejected too; JSON null is not part of the field contract.
`Log_Value` grows when a producer needs a type it does not have.

Domain values keep their types until the last conversion: the writer never reinterprets an
integer as a session sequence, and a helper that builds fields takes
`session.Session_Id` rather than `string`. The structured API does not accept `any` or
reflective maps. Standard `core:log` formatting uses `any` internally; that is its existing
boundary, not a reason to duplicate it. Never use remote content as a format string.

### 5.2 Dispatch and correlation binding

There is one `Log` sink and two deliberately different entry points:

1. `core:log` handles ordinary text diagnostics. The adapter callback writes a
   `runtime.message` record with a bounded `message` and caller location. It treats text
   as text even when it looks like JSON. It never parses messages as structured events.
   The callback uses its supplied `data`, not an unchecked cast of the ambient logger.
   JSON envelope fields are fixed by the schema; terminal-color/header options cannot
   change them. Store caller location as separate fields, with no ANSI formatting.
2. `agent.log_emit` accepts typed fields for harness evidence. It checks that
   `context.logger.procedure` is exactly the Nabla adapter and `data` is non-nil before
   casting `data` to `^Log_Binding`. It then calls the same private sink writer directly.
   This check and the constructor's lifetime contract are the boundary for the raw pointer.

A foreign, nil, or multi-logger is valid for ordinary `core:log` calls, but does not opt
into Nabla's structured records. `log_emit` is a no-op with such a logger. It must not
cast arbitrary logger data, unwrap other implementations, or overwrite a caller's logger.
Embedders wanting the structured stream install the Nabla adapter explicitly. Transparent
structured dispatch through arbitrary text loggers is not a requirement, and no registry,
magic message prefix, or encode-then-parse fallback is added to simulate it.

Both paths use the active `log.Logger.lowest_level`: reject a record when its level is
less than the threshold, before encoding or hashing. `log_logger` initializes that field
from immutable run policy; the sink does not keep a second filtering convention. The
adapter never calls `core:log` to report a sink failure, which would recurse.

At a synchronous session, request, attempt, or tool boundary, build a caller-owned binding
with correlation derived from existing state. Replace correlation as a whole rather than
merging old fields into the next operation. Install the resulting logger in the actual
calling scope:

```odin
binding := agent.Log_Binding{sink = &setup.log}
context.logger = agent.log_logger(&binding)
// Calls here inherit the logger. Leaving this scope restores the previous context.
```

Root creates the run binding. Inside `agent`, one private checked binding accessor can
copy the active sink into a stack binding with new correlation. If the active logger is
foreign or disabled, leave it unchanged. Preserve the active logger's threshold and options
when rebinding correlation. Do not mutate an ancestor binding through its pointer or return
a logger pointing to a helper's local variable. A helper returns a binding by value or
borrows caller-owned binding storage; assigning `context.logger` only inside a
helper does not configure its caller. Bind after each identity-changing transition and
before emitting or calling libraries. Section 5.5 defines when identities exist.

Remove `Chat_Session.log`, the logging parameter to `chat_session_init`, and
`Tool_Context.log`. Tool identity needed for execution stays in `Tool_Context`; sink
selection and diagnostic correlation flow through `context.logger`. No scope stack,
`context.user_ptr`, thread-local registry, or owned context clone is introduced.

### 5.3 Owned state

Phases 0 and 1 update the existing options, sink, and health types and add stack bindings.
Capture types arrive with phase 4. Opening with `enabled=false` succeeds without resources;
an enabled open requires a valid directory and returns a concrete error otherwise.

| Type | Stored data | Owner and release |
|---|---|---|
| `Log_Options` | directory, enabled, lowest standard level | directory borrowed for open; effective policy copied into `Log` and immutable |
| `Log` | allocator, owned run directory, run ID, `open` flag, policy, segment file, run lease, segment number and byte count, bounded segment sequence ranges, rollover bound, sequence, `sync.Mutex`, fixed record scratch, `Log_Health`, monotonic start tick | declared by root, opened once, lives at one stable address, released by `log_close` after all borrowers retire |
| `Log_Health` | failed flag, first typed sink error, written/omitted counts, cleanup failures and scan-limit status | inside `Log`; read through `log_health` under the mutex |
| `Log_Binding` | borrowed sink and correlation | root or synchronous caller stack; outlives all calls using its `log.Logger`; no allocation or destruction |
| `Capture_Descriptor` | optional bounded server id, operation name, and external numeric id for a protocol artifact | borrowed by `log_capture_open`, copied only when present, released with the capture |
| `Capture` | borrowed `Log`, kind, open fd, storage allowance, observed and stored byte counts, observed and stored SHA-256 contexts, truncated and failed flags, generated basename, owned correlation and descriptor copies | owned by one operation; `log_capture_finish` or `log_capture_abort` closes it exactly once |
| `Capture_Summary` | identity, counts, digests, completeness and truncation facts | value result with fixed-size ids and digests, no borrowed capture state |

`Capture_Mode :: enum { Off, Payloads }` has `Off` as zero. `Capture_Kind` is
`{ Invalid, Provider_Request, Provider_Response, MCP_Outgoing, MCP_Incoming }`. `Run_Seq :: distinct u64` inside the package.

Digests use `core:crypto/sha2`: `Context_256`, `init_256`, `update`, `final(ctx,
hash[:])`, with `DIGEST_SIZE_256` of 32 bytes. Digests are stored as `[32]u8` and rendered
as hexadecimal only at serialization time.

A `Capture` copies its correlation at `begin`, because its metadata may be written after
the state it describes has moved on. That copy is freed at finish or abort. No other
diagnostic path retains caller memory.

Root holds `Log` by value in its run setup, the `Run_Setup` the launch builds, and
releases it through the same teardown path as the store, matching the existing `Store`
pattern in `agent/session/store.odin`.

### 5.4 Envelope and sequence

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

`seq` is a `u64` assigned under the writer mutex after filtering and rollover planning,
in physical write order including any internal rollover record. Bounded sizing may precede
final encoding; never write a later sequence before the triggering record's lower sequence.
It spans segment rollover. A failed write can leave a gap; filtered records do not consume a
number. No cross-process sequence is claimed.

Wall time supports human lookup. `elapsed_ns` measures duration within one process from the
monotonic start tick, sampled with the sequence. Timestamps are never subtracted across
runs to derive a duration.

### 5.5 Correlation fields

| Field | Meaning and availability |
|---|---|
| `session_id` | present when a session is known, including a failed claim; does not assert a database row exists |
| `turn_no` | only after a turn exists; compaction performed outside a turn has none |
| `request_no` | the durable logical request number, only after `request_begin` succeeds |
| `attempt` | the loop counter `chat_perform_request` already keeps, one-based, reset per logical request |
| `operation_id` | `Chat_Session.active_operation_id`, absent when no operation is running; never predict it from `next_operation_id` |
| `entry_seq`, `call_seq`, `dispatch_seq`, `result_seq` | committed entry identities, taken from what the store returned, never predicted |
| `call_id` | the provider call id, scoped to one session and request |
| `server_id`, `server_instance` | configured MCP namespace and a run-local launch counter |
| `artifact_id` | writer-generated capture identity inside the run; never a user-supplied path |

Operation identity begins when the existing state machine begins the operation, currently
after `request_begin` for a response request. Preparation and a failed insert carry the
known session and turn, but no invented request or operation number. Do not move execution
or deadline boundaries just to supply a diagnostic ID. A retry keeps the request and
operation numbers and increments `attempt`. Admission compaction has its own purpose and
logical request, not the response request's correlation.

Build fresh correlation at preparation, durable request creation, operation start, each
attempt, and tool dispatch. Clear obsolete fields when leaving those boundaries.
`request.finished` retains the completed request number, while operation and attempt are
absent after retirement unless explicitly captured as facts about that completed work.
A new session must never inherit the old session's identifiers. Correlation travels in
stack bindings through `context.logger`, not through session fields or a thread-local.

## 6. Levels, categories and events

Use `core:log.Level`: `.Debug`, `.Info`, `.Warning`, `.Error`, and `.Fatal`, in increasing
severity. Serialize explicit stable names `debug`, `info`, `warn`, `error`, and `fatal`.
The default threshold is `.Info`. Enablement is separate from severity so zero
`Log_Options` remains disabled. There is no custom `Log_Level`, `Disabled` severity, or
`Trace` severity. Capture is a separate permission, never implied by verbosity.

Debug adds decisions, inventory, and bounded frame metadata where needed. Fatal messages
from ordinary library logging can be recorded; the sink never aborts the program. A caller
using `log.panic` or assertion helpers owns the termination behavior.

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
| `run.started`, `run.finished` | Info | build id, PID, schema version, effective policy; health before close, not a predicted close outcome |
| `runtime.message` | caller's standard level | bounded text and caller file, line, procedure; current correlation when installed |
| `session.claimed` | Info | whether adoption resumed rather than started fresh, including session switches |
| `session.released` | Info | released session identity, emitted after successful release, including switches |
| `session.recovered` | Info | interrupted turns and requests, calls whose outcome is unknown, and calls that never ran; emitted only when there was something to settle |
| `storage.failed` | Error | the local operation that failed, the store's error kind, and the error detail length |
| `turn.started`, `turn.finished` | Info | prompt size at the start; outcome, whether the outcome landed, request and call counts at the end |
| `agent.event_ignored` | Debug | reason, supplied turn and operation, current operation |
| `request.prepared`, `request.recorded` | Info | purpose, model, provider, API, token estimate, context window, message and tool counts; the record marks the durable row separately from the prepare |
| `request.admission`, `compaction.started`, `compaction.finished` | Info | estimate, budget, decision, covered sequence, checkpoint commit result |
| `attempt.started`, `attempt.finished` | Info | attempt, remaining deadline; error kind, finish reason, status, bounded error detail, HTTP stop phase, accepted request-body bytes, request completeness, response-head and declared-length presence, observed streaming response bytes, duration |
| `request.retry` | Warn | error kind, next attempt, delay |
| `provider.encoded` | Info | body length and digest, api, model, tool count |
| `request.finished` | Info or Error | committed outcome, attempts, finish reason; failed requests use Error; failed persistence is recorded once as `storage.failed` |
| `tools.refresh_started`, `tools.refresh_finished` | Info | generation, discovery/admission counts, unavailable servers, installed flag, duration |
| `tool.binding` | Debug | candidate generation, remote and canonical names; refresh result establishes installation |
| `tool.name_resolved` | Info | the name the model sent and the name the harness resolved it to |
| `tool.call_received` | Info | the canonical tool name and the argument byte count |
| `tool.arguments_prepared` | Debug | admission status, repair classification, effective byte count |
| `tool.dispatch_committed`, `tool.result_committed` | Info | the entry sequence the dispatch and the result were stored as, and the outcome |
| `tool.execution_started`, `tool.execution_finished` | Info | the tool and the outcome it produced |
| `mcp.started`, `mcp.negotiated`, `mcp.stopped` | Info | server instance, protocol revision, capability summary, stop reason |
| `mcp.exchange_started`, `mcp.exchange_finished` | Info | method, remote name for a call, delivery state from `mcp.Error.delivery`, duration |
| `mcp.stderr` | Warn | bounded tail length and error kind; raw stderr is never captured |
| `capture.finished`, `capture.failed` | Info, Warning | artifact id and kind, observed and stored bytes, completeness, truncation, failure; optional server, operation, and external id descriptor |
| `retention.finished` | Info | deletion counts, freed bytes, failures, unmeasured runs, incomplete scan |
| `log.segment_removed` | Info, internal | segment number and removed first/last sequence; the private writer bypasses filtering for this metadata so rollover evidence is retained |

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

### 7.1 Read-only join path

The join uses a second SQLite connection opened for reading. It never borrows the running
harness's `Store`, takes a session claim, starts a transaction, changes a pragma that writes,
or runs schema migration.

`sqlite.Config` gains a zero-safe mode:

```odin
Open_Mode :: enum {
	Read_Write_Create,
	Read_Only,
}

Config :: struct {
	path:            string,
	busy_timeout_ms: int,
	foreign_keys:    bool,
	mode:            Open_Mode,
}
```

The zero mode preserves today's behavior. `Read_Only` uses `SQLITE_OPEN_READONLY`; it does
not emulate read-only operation with `PRAGMA query_only`, because that pragma does not make
the connection itself read-only. The mode refuses a missing database and never creates
one. Do not use SQLite's `immutable=1`: the harness may be writing the WAL at the same time,
and immutable mode disables the change and locking checks needed to see that safely.
SQLite 3.22 and later support read-only WAL access when the WAL and shared-memory files are
readable or their directory is writable, as documented in SQLite's
[`sqlite3_open_v2`](https://sqlite.org/c3ref/open.html) and
[WAL](https://sqlite.org/wal.html) references. This project links the system SQLite; the
checked development system reports SQLite 3.53.4. The implementation is still tested
against a concurrent writer rather than relying on the version claim alone.

`session.store_open_read_only` validates with `lstat` that the directory and database are
the expected types and owner-private. It does not create them or repair permissions. It
opens the connection, checks `PRAGMA user_version`, and requires exactly
`SCHEMA_VERSION`. An older database needs one normal harness open to migrate; a newer one
is refused. Exact version matching keeps every public read procedure safe when future
schemas change a column shape. `Store` records that it is read-only, and
`require_writable` refuses before SQLite does, so a caller gets the package's normal
`.Invalid_State` contract rather than a backend-dependent error.

The diagnostics command opens this store only when `--request` is present. It calls the
existing `request_load`, closes the store before scanning files, and treats the row as the
authoritative request result. stdout remains original JSONL records only. stderr prints a
bounded summary containing request number, purpose, outcome, provider, requested and
resolved model, API, timestamps, and each reported usage bucket. Missing usage is printed
as unreported, never zero.

Export adds `request.json` beside `session.jsonl` when `--request` is present. It contains
the same metadata with explicit presence booleans for optional timestamps and usage. It
does not contain `config_json`, `input_json`, `response_json`, or `error_json`, even with
`--include-payloads`; that flag controls diagnostic wire artifacts, not a second export of
the durable conversation. The file counts against the 32 MiB export bound and appears in
the manifest with its length and digest. Its schema is fixed and flat:

```text
version, session_id, request_no
turn_no_present, turn_no, purpose
started_at_ms, finished_at_ms_present, finished_at_ms, outcome
provider, model_requested, model_resolved, api
input_tokens_present, input_tokens
output_tokens_present, output_tokens
cache_read_tokens_present, cache_read_tokens
cache_write_tokens_present, cache_write_tokens
```

If the join fails, normal diagnostics still prints the log records but exits 1, while
export records the omission and exits 1 after writing a manifest that says the bundle is
incomplete.

Tests cover a missing database without creation, symlink refusal, broad permissions,
read-only write refusal, exact schema checks, a reader open beside a WAL writer, a request
committed after the reader opens, absent usage, a missing request, stdout purity, and the
manifest entry and digest for `request.json`.

## 8. Observation APIs, layer by layer

### 8.1 `http/client`: one final transfer summary

```odin
// Transfer_Phase is where a request stopped. Complete means the response body
// framing finished without a transport error.
Transfer_Phase :: enum {
	Validate,
	Resolve,
	Connect,
	TLS,
	Request_Write,
	Response_Head,
	Response_Body,
	Complete,
}

// Transfer_Summary contains protocol facts only. Accepted means the plaintext
// bytes were accepted by the socket or TLS layer. It does not mean the peer
// received, parsed, or acted on them.
Transfer_Summary :: struct {
	stopped_at:                    Transfer_Phase,
	error:                         Error,
	request_bytes_accepted:        u64,
	request_body_bytes_accepted:   u64,
	request_complete:              bool,
	response_head_received:        bool,
	status:                        int,
	declared_body_bytes:           u64,
	declared_body_bytes_present:   bool,
}

Transfer_Observer :: struct {
	user_data: rawptr,
	complete:  proc(user_data: rawptr, summary: Transfer_Summary),
}
```

`Options` gains `observer: Transfer_Observer`. A zero observer does nothing. The client
calls it exactly once after validation has begun, on success and on every error path. A
single completion report is enough because the caller needs the last boundary reached and
the accumulated counts, not a second event stream.

`stream_request` keeps the summary on its stack and uses its named failure result when the
deferred callback runs. `connection_write_all` returns both accepted bytes and `Error`.
`format_request` returns the body offset, so a partial write can distinguish bytes from the
request line and headers from body bytes. For TLS, accepted bytes are plaintext accepted by
`SSL_write`; this still does not prove a kernel send or peer receipt. Names and comments
must use `accepted`, never `sent` or `delivered`.

The response head sets status and the declared body length when a valid `Content-Length`
exists. Chunked and close-delimited responses leave `declared_body_bytes_present=false`.
The observer receives no URL, request target, header, body, endpoint, provider, model, or
session. It cannot expose credentials by construction.

Tests cover invalid URL, resolution failure, connect failure, TLS failure, a partial plain
write, TLS acceptance accounting, a received non-2xx head, a declared length, chunked
framing, a truncated body, cancellation in each blocking phase, and success. The observer is called
once in every case and changing it from zero to non-zero does not change the transfer.

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
	Transfer,
}

Provider_Transfer_Phase :: enum {
	Validate,
	Resolve,
	Connect,
	TLS,
	Request_Write,
	Response_Head,
	Response_Body,
	Complete,
}

Provider_Transfer_Summary :: struct {
	stopped_at:                  Provider_Transfer_Phase,
	request_bytes_accepted:      u64,
	request_body_bytes_accepted: u64,
	request_complete:            bool,
	response_head_received:      bool,
	status:                      int,
	declared_body_bytes:         u64,
	declared_body_bytes_present: bool,
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

	// transfer is set only for the final Transfer report. It uses ai's own
	// vocabulary, not an http/client type, so agent never imports transport.
	transfer: Provider_Transfer_Summary,
}

Provider_Operation_Observer :: struct {
	user_data: rawptr,
	report:    proc(user_data: rawptr, report: Provider_Operation_Report),
}
```

`Provider_Operation_Options` gains `observer: Provider_Operation_Observer`.

`Provider_Request_Operation_Controlled` encodes and then delegates to
`Provider_Request_Operation_Encoded`, which reports `Encoded` before `http_post_sse` over
the exact owned buffer that is about to be sent. A caller that froze the bytes earlier,
such as a background compaction, runs the same path, so the report is made in one place. `Response_Body` is reported from the chunk callback the
operation already passes to `http_post_sse`, which is the one place the plaintext response
bytes pass through. `Transfer` is reported once by `ai/http.odin` after mapping the HTTP
summary into `Provider_Transfer_Summary`. The operation's error still returns through the
normal result; the transfer report adds the boundary and accounting that result does not
carry. The hook stays generic over APIs; `ai` gains no per-provider branch.

The report carries the model and the tool count the body was built from rather than a value
decoded back out of it. `Provider_Validate_Request` has already refused a request whose
model is missing or empty, and `Provider_Encode_Request` validates again, so a body without
a model cannot be produced here; the body digest covers the bytes themselves.

This is provider protocol work, which is what `ai` is: the encoded body of a provider
request is an `ai` fact, and no other layer can observe it before it is freed.

`Provider_Transfer_Summary` mirrors only the fields `agent` needs: stopping phase, accepted
request and body bytes, request completeness, response-head presence, status, and declared
length. `ai/http.odin` owns the exhaustive mapping from `client.Transfer_Phase`; a new HTTP
phase therefore produces a compile error until `ai` decides what it means. Do not infer
transport acceptance from `provider.encoded`, and do not rename acceptance to delivery.

### 8.3 MCP wire observation

`sse` gains nothing. An SSE parse failure already reaches `ai` as an error and leaves as
`Provider_Operation_Error` with kind `.Stream`. The provider chunk callback remains the
owner of response-body capture.

MCP gains one operation-scoped observer because the exact JSON-RPC line otherwise exists
only between encoding and the stdio call, or between a framed read and decoding:

```odin
Wire_Direction :: enum {
	Outgoing,
	Incoming,
}

// message excludes the framing newline and is borrowed until report returns.
// operation and request_id name the client exchange the line belongs to. An
// operation-scoped notification has request_id zero.
Wire_Report :: struct {
	direction:  Wire_Direction,
	operation:  string,
	request_id: i64,
	message:    []u8,
}

Wire_Observer :: struct {
	user_data: rawptr,
	report:    proc(user_data: rawptr, report: Wire_Report),
}

Operation_Options :: struct {
	control:  Control,
	observer: Wire_Observer,
}
```

Do not put observation inside `mcp.Control`; that type owns cancellation and deadline
policy. Add `Operation_Options {control: Control, observer: Wire_Observer}` and pass it to
discovery, initialization, listing, and tool calls. Internal stdio waits receive only its
`control` field. Both fields are borrowed for one synchronous operation, and a zero options
value preserves today's unbounded, unobserved behavior.

`client_exchange` reports the encoded request before `stdio_write_line`, every complete
incoming line before decoding, and client-generated replies to server requests. The
initialized notification is reported from `client_notify`. The observer sees a complete
JSON-RPC line or nothing; it never sees a partial pipe write or the mutable decoder tree.
`mcp.Error.delivery` remains authoritative for whether a complete operation request was
written. Observation does not replace it.

`agent/log_mcp.odin` provides `MCP_Log` and an observer constructor. Root creates a local
`MCP_Log` with the server id for discovery and listing; the tool executor creates one under
the call correlation. When capture is off, no observer is attached. When it is on, each
line becomes one bounded artifact containing the exact framed bytes, including the newline.
The capture kinds are `MCP_Outgoing` and `MCP_Incoming`. The bridge passes a bounded
`Capture_Descriptor` with server id, operation, and request id to `log_capture_open`.
`capture.finished` and the sidecar include those fields when present, so the link survives
an Error logging threshold and does not depend on a second event. The generic metadata
still carries correlation, counts, digests, truncation, and completeness.

Raw MCP stderr is not captured. It is a process stream drained on another thread, may be
written between operations, and cannot honestly inherit the current request or call. The
bounded tail remains attached to failures, and `mcp.stderr` continues to record its size
and error kind. Remove `MCP_Stderr` from `Capture_Kind` rather than leaving a mode that can
never produce an artifact.

Tests use the stdio harness to prove exact outgoing and incoming bytes, notification and
server-request coverage, zero-observer behavior, quota refusal, truncation, correlation,
and no change to retries or `Delivery_State`. A malicious line containing a secret appears
only in the opted-in artifact, never in the metadata record.

### 8.4 Bridging

`agent/log_provider.odin` holds the state one attempt reports into: response byte count,
transfer summary, and capture handles. Create it afresh inside each retry iteration.
Install the attempt's logger binding before calling the provider operation. The observer
is synchronous and uses that context for records, so `Provider_Log` needs no copy of the
writer or correlation. A retry that fails before its first chunk reports zero bytes and
its own transfer phase, never values from the previous attempt.

`attempt.finished` gains the transport stopping phase, accepted request-body bytes,
request completeness, response-head presence, and declared length presence/value. Keep
the existing provider error, status, observed streaming bytes, and elapsed time. Presence
booleans stay separate from zero because an absent length and a declared empty body are
different facts.

Only attach the observer when metadata or capture policy needs it. Check whether
`provider.encoded` is enabled before computing its digest; disabled or filtered logging
must not hash the request just to discard the result. Capture may independently require
hashing when explicitly enabled. Avoid hashing the same bytes twice.

Rules for the bridge, which are the reason it is its own file:

- A report is borrowed for the call and never retained: the bridge hashes the body and
  writes values, so nothing points into memory the operation frees. A test that copied the
  body into a thread's temporary allocator was caught by the address sanitizer, which is
  the rule enforced rather than stated.
- The bridge holds no policy that belongs to a lower layer and no `http/client` type.
- The callback does not mutate what it observes. Odin slices are mutable; the contract is
  read-only, and the buffer owner stays alive until the operation retires.

### 8.5 Byte accounting

The log distinguishes these quantities and never presents one as another:

1. encoded request body bytes, hashed over the exact buffer handed to transport;
2. plaintext request and request-body bytes accepted by the socket or TLS layer;
3. response body bytes received on the successful streaming path and passed to parsing;
4. declared response body bytes, when a valid `Content-Length` exists;
5. bytes stored in a capture, which may be a bounded prefix of an observed payload.

`Content-Length` is reported as the declared value and separately from the body bytes
actually observed. Response capture is the de-framed body byte stream before SSE parsing,
not TCP packets, and it does not assume one event per chunk.

A successful local write or TLS acceptance does not mean the remote received anything.
The transport cannot prove remote receipt, and no record uses `sent` or `delivered` for
these HTTP counts.

The provider chunk callback observes only a successful streaming body. A non-2xx response
has `response_head_received=true`, its status, and the bounded `Failure.detail`; its
`response_bytes` remains the explicitly named observed streaming-body count. Do not read or
retain additional error-body bytes for capture. The existing 4096-byte error reader and
2000-byte detail already answer why a provider refused the request, and draining more would
change transport work for diagnostics. The capture contract names this omission instead of
calling zero streaming bytes an empty response.

## 9. Lifetime, threading, startup and shutdown

Root owns one `Log` in `Run_Setup` at a stable address. Open it as soon as state location
and logging options are available, before store/catalog work and MCP launch that the run
intends to diagnose. Configuration needed to locate or enable logging necessarily precedes
it; a failure there uses the normal startup error path. Close only after all producers,
including MCP background work, have stopped and joined.

Install a run-level `Log_Binding` in each owning execution scope, including the headless
path. `run_log_open` opens resources; an assignment to context inside it cannot configure
its caller. The caller assigns `context.logger` and keeps the binding alive through
teardown. Leave the binding scope before closing its sink, or explicitly restore the
previous logger first. Open/close and health queries remain explicit resource operations.

At `run_worker` entry, create a separate stack binding to the same process sink and assign
only `context.logger`. Keep `thread.init_context` unset so the thread library continues to
manage its default temporary allocator. Do not copy the main thread's entire context just
to propagate logging. The main thread and worker have separate bindings and scratch
lifetimes; only the sink is shared under its mutex.

Synchronous callbacks receive the calling scope's context, not a captured context from
where their procedure value was created. An asynchronous operation therefore cannot retain
a stack binding. A future worker must establish its own binding from explicitly owned
input and keep its sink alive until join. There is no implicit asynchronous propagation.

Structured serialization happens entirely under the writer mutex into writer-owned
scratch, then a write-all loop with EINTR and short-write handling. Ordinary `core:log`
messages have already been formatted by the standard library before the adapter is called;
the callback borrows that text only until it returns. There is no logging thread, no queue,
and no batch timer. This is what keeps a string allocated on `context.temp_allocator` or
owned by a provider callback from being retained past its lifetime.

I/O is synchronous and can stall on a broken filesystem. That is an accepted limit of the
first version, not a claim that logging cannot block. Recommended storage is local state.
A bounded writer queue is added only if measurement shows unacceptable stalls, and it would
need owned messages and an explicit drop policy.

No sink operation acquires a store lock, invokes application callbacks, or recursively
enters logging while holding the writer mutex. A private locked writer may encode internal
rollover records directly, not via `log_emit` or `core:log`. Call sites emit outside
`app.run.mu` and never from a signal handler. The sink uses its stored allocator for
resource changes; any allocator used there must not recursively log to the same sink.
Do not wrap that allocator with `log.Log_Allocator` pointed at this writer.

Startup order:

```text
resolve state directory and diagnostic options
  -> take the cleanup lock
  -> make the private run directory, take its lease, open the first segment
  -> remove closed runs until the retention bounds hold
  -> release the cleanup lock
  -> install the run-level context.logger binding
  -> run.started, then retention.finished if there were deletions, errors, or a scan limit
  -> load remaining configuration/catalog, open store and MCP clients
  -> start the worker, which installs its own logger binding
```

Return or retain the cleanup summary until root installs the logger. `run.started` is the
first record eligible for emission, followed by the cleanup summary. Both obey the chosen
threshold, so their absence at `warn` or `error` is not evidence of an unclean run.

Shutdown order:

```text
request stop -> worker observes cancellation -> durable work settles
  -> finish or abort operation captures -> stop and join producers
  -> destroy clients, release session and close store -> run.finished
  -> restore the prior logger / leave the binding scope
  -> close the segment and release the lease -> report any close failure without that sink
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

Directories are 0700 and files 0600. Descriptors are close-on-exec. Run, segment, and
artifact creation is exclusive; shared cleanup-lock creation is not. Symlinks are not
followed. Check existing shared directories and lock files too, rather than assuming
creation modes correct existing permissions. Use installed `core:os` support where it
satisfies this contract and narrowly scoped Linux APIs where it does not. A capture file's
prefix contains a writer-generated numeric artifact id and a fixed kind name; no model,
tool, URL, or session text appears in a path.

Default records omit prompts, instructions, tool arguments, file contents, command text,
tool output, environment values, raw exceptions, and configuration dumps. Endpoints are
recorded as provider id plus sanitized origin and path, never userinfo, query, fragment, or
credentials. Response headers are not recorded wholesale; a status, a declared length, and
a provider request id when it is specifically needed are allowlisted and capped. The
`authorization` header and other authentication fields are never intentionally passed to
a record or capture. This is a producer rule, not a guarantee that peer text or user
content contains no secrets.

Provider error text is recorded. A refused request is diagnosed by the peer's own message,
and the transport already bounds what it reads (`HTTP_MAX_ERROR_BYTES`, and
`HTTP_MAX_ERROR_EXCERPT` for the text it keeps), so a record carries bounded text rather
than a body. That text can echo part of the request, so a record is not safe to publish
unreviewed: the file is owner-only, but a peer can echo credentials or other sensitive
content in a response body. The capture policy below still governs the full bytes.
Ordinary `core:log` messages follow the same privacy policy. No wholesale HTTP targets,
headers, environment values, or remote payloads belong in them.

Capture policy, first version, read only by root:

- `NABLA_LOG_LEVEL=off|error|warn|info|debug`, default `info`.
  `off` sets `enabled=false`; other values select a standard threshold. The existing
  `trace` option is removed, with the same warning and default as any unsupported value.
- `NABLA_LOG_CAPTURE=off|payloads`, default `off`.

An invalid value warns once and falls back to the safe default; it never enables capture.
Root sets `enabled=true, lowest=.Info` for its normal default. An empty options value
remains disabled. Fatal is supported as a record level, not a separate CLI mode.
Capture does not override `off` logging. There is no provider-specific setting, and a later
Lua setting reuses the same `Log_Options` rather than adding a second parser.

`payloads` is explicit consent to sensitive local content. Producers are the provider
request body, the de-framed successful provider response stream, and complete MCP outgoing
and incoming JSON-RPC lines. It does not capture HTTP headers, authentication fields,
non-2xx response bodies beyond the bounded logged detail, MCP stderr, or the process
environment. Captured bodies can themselves contain secrets. Raw bytes and guaranteed
redaction are incompatible, so the mode is not described as safe, and enabling it prints
one local warning through the normal notice path.

Each capture owns its fd and two incremental SHA-256 contexts, one for observed bytes and
one for stored bytes. At begin it resolves the active Nabla binding once, borrows that
sink, and copies correlation with the sink's allocator. Capture finish/abort uses these
saved values directly, not whatever context is current later. This retained resource
relationship is distinct from passing a logger through session or tool execution state.
The sink outlives every capture, and each chunk is consumed synchronously. After the
storage allowance is exhausted, it keeps counting and hashing observed bytes without
storing them. A digest therefore describes what was
observed, never bytes that were never delivered to the hook.

`log_capture_finish` closes the payload, then writes a bounded metadata sidecar through a
temporary file and a rename. The sidecar, capped at `LOG_CAPTURE_SIDECAR_BYTES`, carries
the format version, full correlation, kind, observed and stored counts, observed and stored
digests, the completeness, truncation, and error facts, and the optional bounded capture
descriptor. Provider kinds keep their existing wire names. MCP uses `mcp-outgoing` and
`mcp-incoming`; remove the unused `mcp-stderr` kind. A
stored artifact can be a complete observation and a truncated copy at the same time; the
two flags are separate.

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
| `MAX_FIELD_STRING_BYTES` | 4 KiB | text/identifier/key cap before escaping |
| `MAX_RECORD_FIELDS` | 64 | caller fields, bounding validation work before encoding |
| `SEGMENT_BYTES` | 8 MiB | rotate before a record would cross the boundary |
| `SEGMENTS_PER_RUN` | 4 | current segment plus three preceding |
| `CAPTURE_BYTES` | 8 MiB | stored bytes per artifact |
| `CAPTURE_BYTES_PER_RUN` | 64 MiB | stored payload per run, sidecar metadata excluded |
| `CAPTURES_PER_RUN` | 128 | artifact slots per run, incomplete files included |
| `CLOSED_RUN_BYTES` | 256 MiB | cleanup target across inactive runs |
| `CLOSED_RUN_COUNT` | 128 | binds small-run directory proliferation |
| `RETENTION_AGE` | 14 days | closed runs expire at cleanup |

Enforce the scalar cap before scanning/escaping. Reject oversized keys, event names, and
correlation identifiers rather than truncating identities. For oversized field values or
records, write the bounded omission event and increment health; never silently truncate
an exact field. A compact omission record must still fit if the rejected event name or
correlation was itself oversized. Stop encoding as soon as scratch fills. Field validation
uses `MAX_RECORD_FIELDS` to bound duplicate-key checks. Ordinary oversized messages follow
the same omission policy as field values; do not silently turn a prefix into the full
message. A fallback omission record may omit invalid correlation but retains valid run
identity and its sequence.

Rotation closes the current segment and opens the next increasing number. A numbered
segment is never renamed onto another. The oldest segment is deleted only after the new one
is open, and the removed sequence range is recorded in the new segment so a reader can
report a gap. Keep first/last sequence ranges in a fixed ring for retained segments, not
an unbounded index. Reserve room for the rollover metadata before admitting the triggering
record, assign sequences in physical write order, and do not recursively rotate while
writing the metadata. Record successful deletion, not merely an intention to delete.
Close, allocation, and deletion failures are reflected in health.

With successful deletion, one run holds at most about 32 MiB of records plus bounded
captures. Failed deletions can exceed that target and are reported, not claimed away.
Every record fits inside one segment. Filenames may grow beyond six digits; readers parse
and sort the numeric suffix rather than assume lexical order or exactly six digits.

Capture admission reserves per-run bytes and one artifact slot under the writer mutex. Once
the quota is exhausted, later captures are declined and one warning plus counters are
emitted; a live capture is never evicted and nothing grows without bound. Metadata summaries
remain available after payload admission is exhausted.

Cleanup runs once per launch, while the run directory is being created and the cleanup
lock is held. There is no background thread and no periodic pass: a run bounds its own
segments as it writes them, and what other launches left behind is collected by the next
launch. Run-local rollover holds its targets during long turns when deletion succeeds;
global retention is eventual and skips live runs, so total usage can exceed
`CLOSED_RUN_BYTES` while many processes are active.

Liveness is an exclusive lock, not a timestamp and not a process id:

1. A run holds an exclusive lock on its own `lease` for its whole life. The kernel releases
   it when the process dies, so a crashed run is collectable without any cleanup step.
2. A cleanup pass holds the exclusive `cleanup.lock` for the whole pass. Creating a run
   takes the same lock, blocking, so a cleaner can never meet a run directory that has no
   lease yet. The lock file is never unlinked: replacing a locked inode would let two
   processes hold what each believes is the same lock.
3. Under that lock, probe each candidate's lease with a non-blocking lock. Lock contention
   means active. A missing lease or a successfully locked lease establishes collectability.
   Allocation, permission, open, or other lock errors mean unknown: keep the run and count
   the failure. Retry EINTR where appropriate. Keep the successful probe lock through
   inspection/deletion, so a reader can use the same lease to pin a closed run. Symlinks
   and names that are not run ids are left alone.
4. Expired runs are removed first, then the oldest until the count and byte targets hold. A
   future timestamp does not block size-based eviction, because the count and byte bounds
   are evaluated independently of age.
5. Decrease remaining count and bytes only after successful deletion. Count and report
   failed deletions, unreadable sizes, and incomplete scans. Include nested capture payloads
   and sidecars in byte accounting. Bound directory entries and traversal depth as well as
   the 4096-run scan; a run limit alone does not bound per-run work. A scan limit marks the
   cleanup incomplete and does not claim the global targets hold. Filesystem I/O itself
   can still block.

An existing run directory is never adopted by a new writer, and PID existence is never used
as proof that a run is alive.

## 12. Failure and durability contracts

- A record is written immediately to the operating system, without a userspace delay. It is
  not fsynced per line. A process crash normally preserves completed writes; machine or
  power failure can lose them. Neither JSONL nor captures are a write-ahead log.
- `log_close` returns a concrete close error. There is no userspace flush or implicit
  fsync. Root must check it and report it outside the closed sink. Check segment close
  errors during rotation too. An explicit export may fsync its own finished files and
  directory when asked; it cannot make old records durable retroactively.
- EINTR retries and short writes advance by the actual count. An unrecoverable error
  disables the event sink and latches the failure, and no further record is appended after a
  broken line.
- There is no automatic reopen loop on disk-full or permission failure. Root shows one
  warning and status reports diagnostics unavailable; a later process may try again.
- A capture failure disables that capture only. A retention failure does not stop writing
  while space remains.
- Structured emission uses fixed scratch and checks limits before allocation. Open,
  rollover, cleanup, capture, and reader allocations check optional allocator errors and
  unwind acquired resources. A failed append must not leak its newly allocated path.
  Allocating public procedures take `allocator := context.allocator`; retained owners
  store it and release through that allocator. Do not use temporary memory for sink state.
- Ordinary `core:log` formatting uses `context.temp_allocator` before the adapter runs.
  The adapter bounds stored text, not the upstream formatting allocation. Do not promise
  allocation-free or recoverable-OOM behavior for arbitrary `log.infof` calls. Call sites
  bound inputs before formatting; critical structured evidence uses `log_emit` instead.
- Error-returning diagnostics APIs preserve typed OS/allocator failure information where
  recovery or health needs it. Errors are trailing values, nil or `.None` means success,
  and borrowed details state their lifetime. Do not collapse lease probe errors into a
  boolean or convert platform errors to strings before the owner can classify them.
- No records are written from a fatal signal handler. SIGKILL may leave no final record.
  A missing `run.finished` may also reflect filtering, rollover, or sink failure; it does
  not by itself prove an unclean shutdown, much less diagnose its cause.
- A malformed final line is ignored with a truncation warning. A malformed interior line is
  reported with segment and offset and skipped, never executed.
- Cancellation is recorded as requested and observed when both are known. Terminal
  classification follows the existing rules, including deadline and cancel precedence.
- A partial record followed by an unrecoverable error leaves the sink disabled rather than
  emitting a second half-line.

## 13. Reading a session

One command reads the logs, parsed beside the existing `chat_cli_options`:

```text
nabla diagnostics <session-id> [--request N] [--level NAME] [--export DIR [--include-payloads]]
```

`agent/log_read.odin` holds the reader: it groups runs by directory modification time,
reads each segment whole, parses each line to select a session, and calls a visitor with
the record as written. This is approximate run ordering, not a global timeline: rotation
also updates directory modification time. It parses the line rather than searching it,
because a record may carry text a peer sent and that text must not be able to name another
session. Records are selected by the session field rather than by a file name, so a session
that spans runs is read across all of them, and a run that holds several sessions
contributes only the records that belong to the one asked for.

The reader checks a record's envelope before it believes anything inside it. A line that is
not a record, a record whose format version this build does not implement, and a record
whose run id disagrees with the directory it was found in are each counted with their own
reason, so unreadable evidence is never passed off as an empty result. Segment order comes
from the number in the file name, a segment is read through `lstat` and never through a
symlink, and a segment is read only up to the size it had when the read began, so an active
writer's new tail is ignored rather than reported as malformed. A final line without its
newline is counted as incomplete, and a segment the writer removed is counted as retention
rather than loss.

The command lives in root, which already resolves the logs directory and imports the
reader. Records go to stdout exactly as written, so a caller can pipe them into `jq`, and
the count of what was read goes to stderr together with everything the reader could not
read: an unlistable run directory, an unreadable segment, or a line that does not parse.
A missing or unlistable logs directory is reported as unreadable, not as an empty result.
The command exits 1 for no matching records, unreadable evidence, malformed lines, a run
scan limit, or failed output. Bad arguments exit 2. The visitor stops scanning on a failed
write, including a short write or a failure to write the record's newline.

A `--request` selection answers with two halves, and the exit code answers whether the
whole answer was found: the durable row must be read and the record stream must hold
something. So a session whose rows exist but whose run never logged exits 1 with the row on
stderr and an empty stdout, which is the honest report rather than a claim of success. The
export answers a different question, because its bundle states its own omissions: it exits 0
whenever a complete manifest was written and 1 when the join it was asked for could not be
made.

Run framing (`run.started`, `retention.finished`, `run.finished`) carries no session and is
not part of a session's stream; the run a record came from is a field of the record, and
its own directory holds the framing. The export copies each contributing run's stream whole,
which is where that framing is read.

Before extending selection or export further, note what the reader already holds: segment
reads and line parsing are bounded by the writer's limits, each segment is read to the size
it had at the start, and the version, run id, and sequence are validated. Directory and
allocation failures stay visible in the summary.

The remaining reader work is the request join in section 7.1. It runs only for
`--request`, reports the durable row to stderr, and keeps stdout as original JSONL.

The reader stays batch-only. Follow mode is not deferred logging work; it is a separate
feature if a user later needs to watch a live run. Nothing in the format prevents such a
command from using `(run_id, seq)`, but the logging completion gate does not include one.

The export bundle is laid out as:

```text
manifest.json
session.jsonl
request.json                         # only with --request
runs/<run-id>/events.jsonl
runs/<run-id>/captures/<artifacts, only with explicit inclusion>
```

The manifest records the format version, the selection, the snapshot time, per-file length
and digest, the request join when selected, and every missing, truncated, or disabled
piece of evidence. Destination creation is exclusive with 0700 and 0600 permissions, and
every file in the bundle is new, so an export never mixes with what a previous one left
behind. The default export contains correlated metadata only. `request.json` contains
durable outcome and usage metadata, never the request's stored semantic input, response,
error, or
configuration JSON. `--include-payloads` adds diagnostic provider and MCP wire artifacts;
it does not turn the export into a conversation dump. An omitted artifact is recorded as
an omission rather than passed over.

The default total export cap is 32 MiB across every file. `request.json` is written first
when selected, then the session stream, each contributing run's own stream, and opted-in
artifacts within the remaining budget. Every omission is recorded with its reason, and unrelated recent requests
are never added to fill a quota. A segment is read only up to the size it had when the read
began, so an active writer's incomplete tail is ignored rather than copied half-written.
A rotation race produces an explicit missing-file notice.

## 14. Walkthroughs

**A remote error about an unknown or blank model.** Run diagnostics with `--request` so the
durable outcome and usage appear first, then inspect `provider.encoded`: api, model, tool
count, body length, and digest. `attempt.finished` says whether the HTTP layer accepted the
whole request body, whether a response head arrived, its status and declared length, and
the observed streaming response bytes. `ai` rejects a
missing or empty model before encoding, so a record cannot show an empty model unless the
harness itself is broken, and the digest makes the encoded bytes checkable rather than
inferred. Zero observed streaming-body bytes does not prove that no response arrived:
headers or a bounded non-2xx body can arrive through a different path. Interpret the count
with its coverage, status, and failure kind. The bounded excerpt already reaches the
caller through `Failure.detail`. What the log cannot establish is how a gateway routed a
model it received; it records which model it sent and when.

**A rejected tool name.** Compare the name in `tool.call_received` with the wire and
canonical names in `tool.name_resolved` and the candidate `tool.binding` inventory.
`provider.encoded` supplies a tool count and body digest, not the full encoded inventory.
Exact wire definitions require an opted-in capture. Inspect native Responses replay
separately from projected historical calls. Do not claim a count alone proves which tool
names were sent.

**An MCP server reporting an unknown tool.** Follow `call_seq` to the server id and instance,
then compare the discovery remote name, the binding name, and the name sent in `tools/call`.
With payload capture on, the outgoing artifact contains the exact framed JSON-RPC request
and the incoming artifact contains the peer's exact line; their sidecars name the server,
operation, request id, and call correlation. Delivery state still comes from
`mcp.Error.delivery`, and a missing result is reported as unknown rather than as failure.

**A crash during a tool.** A committed dispatch with no committed result stays unknown even
if the log holds an observed result. The report shows both the observed diagnostic outcome
and the durable recovered outcome, and the tool is never retried on the strength of missing
records.

## 15. Implementation sequence

Every phase below is implemented, and the close-out order at the end of this section is the
record of how the last four changes were split. The phase numbers locate the work; they are
not a completion certificate, and the acceptance tests each phase names are the ones the
shipped code holds.

### Phase 0: migrate to Odin's logger and context

Done: `agent/log_bridge.odin` holds `log_logger`, the checked `log_emit`, `log_rebind`,
`log_active_sink`, and `log_enabled`. Severity is `core:log.Level` with enablement as a
separate fact, `Log_Emit_Result` is gone, and the reader, request, retry, compaction, tool,
MCP-refresh, and worker scopes all install their own binding. Nothing routes a writer
through session or tool state.

Acceptance tests:

- A normal `core:log` call reaches the same JSONL sink, threshold, sequence, and health
  as a structured record. Caller location survives; JSON-looking text remains text.
- Nil, zero, foreign, and multi-loggers are safe; structured emission never casts their
  data or changes their logger. Ordinary foreign logger behavior remains intact.
- Nested scopes restore correlation after return, cancellation, and early errors.
  Session switches, compaction, and later tools cannot inherit stale identifiers.
- Main and worker records share the sink safely, but not stack bindings or temporary
  allocator state. No producer uses the sink after close; ordinary logging never corrupts
  stdout or the terminal UI.
- A retry that observes bytes followed by an attempt with no chunk callback reports a
  fresh zero count with explicit coverage. Every `provider.encoded` has its own attempt.
- Disabled or filtered metadata avoids hashing and leaves execution, durable entries,
  retries, and tool invocation counts unchanged.

Run `mise run check`, `mise run test agent`, `mise run test ai`, and `mise run test .`.
Run affected lifetime suites with `--debug-only --sanitize address` as well. The
acceptance tests below are the ones the shipped code holds.

### Phase 1: finish the existing writer in `agent`

Keep `Log`, `Log_Options`, `Log_Category`, `Log_Value`, `Log_Field`, `Log_Record`,
`Log_Health`, `Log_Error`, zero-safe open/close, run identity, synchronous JSONL, sequence,
health, and rollover. Use the standard logger types and bindings from phase 0.

Keep the bounded flat encoder unless standard serialization makes it simpler with the
same measured allocation and failure behavior. `json.marshal_to_writer` does not require
an object tree; the old rationale was incorrect. Dynamic top-level fields and invalid-byte
replacement still need deliberate handling. Replace home-grown UTF-8 validation with
`utf8.decode_rune_in_string`, preserving U+FFFD on invalid bytes. Do not directly reuse
`io.write_quoted_string` on unvalidated bytes: the checked version can produce non-JSON
`\xNN` escapes. A small JSON escaper over standard decoding is justified here.

Remove unused `start_time_ns`; keep monotonic start tick and sample wall time per record.
Complete field bounds, nil-value rejection, rollover sequence-range evidence, close-error
handling, and non-recursive failure reporting. Use standard hex/number helpers when they
meet the fixed-buffer contract; do not create general-purpose utility abstractions.

Tests: quote, backslash, control byte, and invalid UTF-8 escaping; a record that repeats a
key, shadows an envelope key, or contains an unset value is rejected; a nil logger emits
nothing while zero correlation under an enabled logger writes a run-level record; the
sequence increases with every record; an injected write failure disables the sink exactly
once; an oversized record becomes the omission record; rollover keeps the configured
window and records removed sequence ranges in physical sequence order; the run directory
and its segments are owner-only. Cover overlong UTF-8, surrogate encodings, values above
U+10FFFF, truncation, valid U+FFFD, field caps, and oversized correlation. Verify ordinary
message bounds separately from structured allocation-free encoding. Run
`mise run test agent` and `mise run check`.

### Phase 2: run lifecycle and retention

The lease and cleanup implementation exists. Keep policy in `agent/log_retention.odin`
and the small Linux lock operation in `agent/log_lock_linux.odin`; use installed core
facilities where available. There is no Darwin sibling to plan for. Fix deletion counts,
unknown lease state, bounded nested byte accounting, and error summaries. Check allocation
results and release failed append inputs. Enforce safe path handling for shared locks,
existing directories, and readers, not only exclusive segment creation.

`app_log.odin` parses policy, opens/closes the writer, and records run framing inside the
root binding scope. Bring startup/teardown ordering into agreement with section 9.
Present latched failure once at a work boundary outside application locks, and report close
failure on stderr after terminal teardown. Logging failure must not fail the launch.

Tests: a leased run is kept even when it is past every bound; an expired closed run is
removed; an unleased orphan is removed; the count and byte bounds keep the newest runs; the
level names round trip. Add failure cases for deletion, unreadable leases, symlinks, scan
limits, capture-subdirectory accounting, and close-error reporting. Inject allocator
failure to verify no leaked paths or deleted live runs. Run `mise run test agent` and
`mise run test .`.

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

After phase 0, the writer travels through `context.logger`; session state contains no
logger. No new identity is introduced: `chat.turn_no`, `chat.active_request`, the active
retry counter, and `chat.active_operation_id` supply correlation under section 5.5.
Preparation has no operation ID until the state machine starts one. The schema stays at
version 4. Ensure failed final requests use Error while cancellation remains Info; avoid
a duplicate `request.commit_failed` record for the same `storage.failed` fact.

Tests: a cancelled turn records its own start and end with the session and durable turn; an
event from a superseded turn is recorded with the reason it was refused; a tool call is
recorded from the proposal through the dispatch and execution to the committed result, in
that order and under its own call id; and a turn driven with a writer records the same
durable entries and call count as the same turn driven without one, which is the property
that logging observes a turn rather than taking part in it. Root records
`session.claimed` and `session.recovered` where it claims the session and settles what an
earlier run left. Run `mise run test agent`, `mise run test .`, and `mise run check`.

This phase is complete. Admission, compaction, claim, release, and recovery are all
recorded at the boundaries that own them.

### Phase 4: provider observation, transport accounting, and capture

The provider observation is implemented: `Provider_Operation_Observer` in
`ai/request.odin`, reported at encode time and from the response chunk callback, and the
bridge in `agent/log_provider.odin` that turns it into `provider.encoded` and an observed
streaming-body byte count on the attempt that ends. Section 8.5 states the deliberate
non-2xx coverage limit. The report borrows bytes for the call only, so the bridge hashes
the body and records values rather than keeping a pointer. Lifetime tests must consume or
own their bytes before callback return.

Tests: the transport fixture reports what one operation encoded and received, and the bridge
records the digest of those exact bytes, checked against a digest computed outside the code
under test. Run `mise run test ai`, `mise run test agent`, and `mise run test .`.

Done: the one-shot transfer summary in section 8.1, mapped through `ai` and carried on
`attempt.finished`. Without it a connect failure, a partial write, and a failure after a
response head collapse to the same high-level transport error. The report uses
accepted-byte language and never claims transmission or receipt.

Done: `agent/log_capture.odin` with its per-artifact and per-run quotas, sidecar metadata,
digests, and the `NABLA_LOG_CAPTURE` switch, driven from the provider observation. A
capture stores the same borrowed body the bridge hashes, and the request artifact is
opened and finished within the encode report because the whole body arrives at once.
Test no-body/non-2xx paths, truncation versus incomplete observation, observed/stored digest
differences, quota exhaustion, abort, orphan sidecars, and sink lifetime. Adding an observer
must not read extra network data, alter retry policy, or change tool delivery semantics.

### Phase 5: MCP and tool evidence

Done: the executor records `mcp.exchange_started`, `mcp.exchange_finished`, and stderr
metadata without copying payloads into records; local refusals report `not_delivered` and
protocol failures preserve `mcp.Error.delivery`; refresh attempts record generation,
discovery and admission counts, unavailable servers, installation status, and duration;
debug `tool.binding` records map remote names to canonical names for a candidate
generation; and `app_mcp.odin` records `mcp.started`, `mcp.negotiated`, and `mcp.stopped`
with a run-local launch counter, so a restart is distinguishable from a first launch. The
MCP clients are released at teardown, which they previously were not.

Done: the operation-scoped MCP wire observer from section 8.3, bridged to `MCP_Outgoing`
and `MCP_Incoming` captures. Delivery still comes from `mcp.Error.delivery`, the remote name
remains the one `agent` chose, and `tools/call` is never automatically retried. Raw stderr
capture is rejected and its unused capture kind is removed.

Tests: a remote name containing underscores and dots; a renamed local alias; a disabled
discovery entry; a server restart; a malformed reply; a timeout after send; stderr
containing a newline and a secret; an unavailable tool. Assert that the encoded remote name,
the wire name, and the canonical name appear only in the fields that mean them. Run
`mise run test mcp`, `mise run test agent`, and `mise run test .`.

### Phase 6: reading and export

Done: `agent/log_read.odin` walks the runs oldest first and visits the records of one
session, bounded and validated as section 13 describes; `app_diagnostics.odin` prints them
as they were written while reporting what could not be read, and takes `--request`,
`--level`, `--export`, and `--include-payloads`; and `app_diagnostics_export.odin` writes
the bundle section 13 lays out, with its manifest and its omissions. Tests hold the reader
to records the writer produced, and the export to a bundle read back off disk.

Done: the read-only database join in section 7.1. Follow mode is not part of this phase or
of the logging system.

Run `mise run test agent`, `mise run test .`, and `mise run check`.

### Close-out order

The work was held to four reviewable changes, one per package boundary, in this order:

1. **Read-only store and request join.** `sqlite.Open_Mode`, `session.store_open_read_only`,
   the stderr summary, `request.json`, and the export tests. A test reads a row a live
   writer committed after the reader opened, which is what proves the path is a reader
   rather than a second writer.
2. **HTTP transfer summary.** Accepted-byte accounting in the connection, one completion
   callback, the exhaustive `ai` mapping, and the attempt fields. The `ai` transport
   fixture proves the three cases that matter: a completed request, a request that stopped
   inside the response body, and one that never left.
3. **MCP wire capture.** `mcp.Operation_Options`, every client message path, the capture
   bridge in `agent` and root, and the renamed capture kinds. The stdio harness proves the
   observed lines are whole JSON-RPC messages and that observing changes no outcome.
4. **Persistent-log privacy audit.** The `http` producers carry structural facts, and
   `storage.failed` carries a length rather than a message. What remains interpolates only
   error enums, socket numbers, byte counts, and the request method; that list is in the
   change that made it.

The logging system was complete when all four were merged and these statements held:

- a failed provider attempt names the last HTTP phase and accepted request bytes without
  claiming peer receipt;
- payload capture includes provider bodies and exact MCP JSON-RPC lines, but not headers,
  credentials, process environment, non-2xx bodies beyond bounded detail, or MCP stderr;
- `diagnostics --request` reports the durable outcome and usage without changing stdout,
  and export includes a hashed `request.json`;
- no known ordinary `core:log` producer persists a raw HTTP request target,
  request/header line, credential, environment value, peer payload, or local file path;
  the structured provider error field remains the documented bounded exception;
- logging and observers remain optional and do not change retries, delivery state, durable
  rows, tool execution count, or process exit status;
- the architecture document has no pending logging item. Follow mode remains an explicit
  non-goal, not unfinished work.

All of them hold: `mise run check`, the full `mise run test` gate including the external
harnesses, and the address sanitizer run over the changed ownership and lifetime paths are
green.

`mise run check` accompanies code changes, and `mise run fmt` formats Odin. Run affected
package tests in release and debug during each change. Compiler checks do not establish
borrowed lifetime, privacy, or diagnostic completeness; the boundary tests above do.

## 16. Deliberate limits

A failed request can be reconstructed from its attempts, correlation, encoded body
evidence, HTTP stop phase, tool resolution, MCP wire evidence, and observed versus durable
outcomes, and the command line reads and exports it. The system still cannot prove that an
HTTP peer received or acted on accepted bytes, and it never claims that it can. A record is
evidence, never authority: the session database answers what was decided, and the log
answers what one process observed.

Not included: OTLP, remote upload, metrics backends, follow mode, a live event bus, a
trace-tree UI, per-token Info records, raw MCP stderr capture, non-2xx body capture beyond
the bounded error detail, a package-global logger, a logging thread, a second SQLite event
store, and a diagnostics package. Not promised: power-loss durability, a hard quota across
unlimited concurrent processes, and safety to publish metadata or captures without review.

Further work needs a new debugging requirement rather than a tidy-up. The architecture
follows one request from preparation through transport, tool execution, and committed
recovery state without making diagnostics a second execution system.
