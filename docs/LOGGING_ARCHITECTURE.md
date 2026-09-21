# Diagnostics and logging

Status: required target. The writer, correlation, capture, retention and reader exist;
treat them as the baseline, not as a reason to keep duplicate machinery. Diagnostics
observe execution and never change admission, retry, tool or persistence policy.

## Ownership and dispatch

Start from Odin's facilities. `context.logger` is the scoped logger parameter, and
`core:log` is the ordinary text path. Keep a custom `log.Logger` callback backed by
one process `Log` sink because the standard sinks do not provide typed correlation,
bounded JSONL, sink health, rotation/retention or private capture. Do not add a
subscriber registry, logging thread, global logger, `context.user_ptr` smuggling or
second event bus.

`agent` owns the record model, correlation, capture policy, rotation, retention and
reader, because those concepts name sessions, turns, requests and tools. Root owns
process lifetime, environment policy, the logger binding, health presentation and the
`diagnostics` command. Lower libraries report their own protocol facts in their own
vocabulary; they do not import harness policy or write files. A library may call
`core:log` for ordinary diagnostics and may expose an optional typed observer for
facts that text cannot carry.

No new package: this code cannot be described without Nabla concepts, so it lives in
`agent` beside the state machine that produces the facts.

## What must be answerable

Given a session and a failed request, reconstruct:

- process/run, turn, logical request, attempt and operation identity;
- prepared inventory, encoded body length/digest, and accepted plaintext request bytes;
- failure boundary: preparation, DNS, connect, TLS, request write, response head,
  framing, SSE/WS decode, provider classification, dispatch, execution or persistence;
- tool identity: proposed name, selected canonical name, remote MCP name, delivery
  state, whether execution started, whether a result was observed, whether it committed;
- usage and cache coverage with missing/paired facts kept separate;
- what evidence is absent because capture was off, bounded, truncated or failed.

A record states what one process observed at a named boundary. It is never authority
over the session database. Missing completion is not proof of failure; an accepted
local write is not proof of remote receipt.

## Records and correlation

One valid UTF-8 JSON object per line. The envelope is fixed and reserved: version,
run id, sequence, wall time, monotonic elapsed, thread id, level, category, event.
Correlation fields are added when they exist: session, turn, request, attempt,
operation, call, entry sequences, server instance, artifact id.

```odin
Log_Category :: enum {
	Runtime, Session, Agent, Provider, Transport, Tool, MCP, Storage, Diagnostics,
}

Log_Value :: union { bool, i64, u64, string }

Log_Field :: struct { key: string, value: Log_Value }
Log_Record :: struct { level: log.Level, category: Log_Category, event: string, fields: []Log_Field }

Log_Correlation :: struct {
	session_id: session.Session_Id, turn_no: session.Turn_No, request_no: session.Request_No,
	attempt: int, operation_id: u64, call_id: string,
}

Log_Binding :: struct { sink: ^Log, correlation: Log_Correlation }
```

Severity is `core:log.Level`; enablement is separate so a zero options value is off.
Enum names are serialized by explicit stable spelling, never by ordinal. A reader
retains unknown fields/events; an unsupported major version is reported, not guessed.
An event name or field meaning is never changed in place.

`log_emit` consumes borrowed fields synchronously and returns no result. Diagnostics
never decide whether work continues. Reject unset values, duplicate keys and reserved
envelope keys; grow the scalar union when a producer needs a new type. Domain types
stay typed until serialization. Never use remote content as a format string.

Bind correlation in the scope that owns the identity. Rebind after each identity
becomes durable; do not invent a request or operation number before it exists, and
clear obsolete fields when leaving a boundary. A retry keeps request/operation
identity and increments attempt. Do not mutate an ancestor binding through a pointer
or return a logger pointing at a helper's local. A foreign or disabled logger is
valid for ordinary calls; structured emission with one is a no-op, not a cast.

Operation identity starts when the state machine starts the operation. Preparation
and a failed insert carry session/turn only. A new session never inherits old
identifiers. Correlation travels through the scoped logger, not through session or
tool state.

## Events

Emit at the boundary that owns the fact, once. `Error` means the emitting operation
failed; a retryable or malformed-remote event is `Warning`; cancellation is normally
`Info`; a final failed request is `Error`. Lower layers name the stage; the owner
records the terminal outcome. One failure is not a final error at every layer.

Minimum contracts, with fields beyond correlation:

| Event | Level | Facts |
| --- | --- | --- |
| `run.started`, `run.finished` | Info | build id, pid, schema version, effective policy; health at close |
| `runtime.message` | caller | bounded text plus caller file/line/procedure |
| `session.claimed`, `session.released`, `session.recovered` | Info | resume vs fresh; settled interrupted work |
| `storage.failed` | Error | local operation, store error kind, detail length |
| `turn.started`, `turn.finished` | Info | prompt size; outcome, whether it landed, request/call counts |
| `agent.event_ignored` | Debug | supplied vs current turn/operation |
| `request.prepared`, `request.recorded` | Info | purpose, model, provider, api, estimate, window, counts |
| `request.admission`, `compaction.started/finished` | Info | estimate, budget, decision, covered seq, commit result |
| `attempt.started`, `attempt.finished` | Info | error kind/class, finish reason, status, transfer phase, accepted bytes, completeness, declared/observed response bytes, duration |
| `request.retry_scheduled/started`, `request.recovery_stopped`, `request.context_repaired` | Info/Warn | next attempt, failure class, delay, covered checkpoint |
| `provider.encoded` | Info | body length and digest, api, model, tool count |
| `tool.call_received` … `tool.result_committed` | Info/Debug | canonical name, argument status/repair, entry sequences, outcome |
| `tool.stop_requested`, `tool.job_stuck` | Warn/Error | tool, patience, waited time |
| `mcp.started/negotiated/stopped`, `mcp.exchange_started/finished`, `mcp.stderr` | Info/Warn | server instance, revision, method, delivery state, bounded stderr size |
| `capture.finished/failed`, `retention.finished`, `log.segment_removed` | Info/Warn | artifact id, counts, completeness, freed bytes, removed sequence range |

Required fields are documented beside the emitting procedure and tested at the real
boundary. There is no union enumerating every application event; the scalar union
bounds serialization types, and producer helpers plus tests enforce each contract.

## Sequence, rotation and durability

`seq` is a `u64` assigned under the writer mutex in physical write order, spanning
rotation, with filtered records consuming none. `run_id` is 128 random bits generated
once, with exclusive directory creation and collision retry; if randomness fails,
disable diagnostics with a warning rather than using a pid-only identity.

Serialization happens under the writer mutex into writer-owned scratch, then a
write-all loop handling EINTR and short writes. No logging thread, queue or batch
timer. I/O is synchronous and may stall; that is an accepted limit until measurement
shows a bounded queue is needed, which would require owned messages and a drop policy.

A record is written immediately to the OS without per-line fsync. Crash normally
preserves completed writes; power loss may not. JSONL and captures are not a
write-ahead log. `log_close` returns a real error that root reports outside the
closed sink. An unrecoverable write error disables the sink and latches health; never
append after a broken line. Do not write from a fatal signal handler.

Rotation closes the current segment and opens the next increasing number, never
renaming one segment onto another. Delete the oldest only after the new one is open,
and record the removed sequence range. Keep first/last sequence ranges in a fixed
ring, not an unbounded index.

| Limit | Value |
| --- | ---: |
| `MAX_RECORD_BYTES` | 64 KiB |
| `MAX_FIELD_STRING_BYTES` | 4 KiB |
| `MAX_RECORD_FIELDS` | 64 |
| `SEGMENT_BYTES` / `SEGMENTS_PER_RUN` | 8 MiB / 4 |
| `CAPTURE_BYTES` / `CAPTURE_BYTES_PER_RUN` / `CAPTURES_PER_RUN` | 8 MiB / 64 MiB / 128 |
| `CLOSED_RUN_BYTES` / `CLOSED_RUN_COUNT` / `RETENTION_AGE` | 256 MiB / 128 / 14 days |

Enforce scalar caps before scanning/escaping; reject oversized keys and identities
rather than truncating them. An oversized value or record becomes a bounded omission
record plus health, never a silent prefix. A compact omission record must still fit
when the rejected event or correlation was itself oversized.

## Observation APIs

Libraries expose their own facts, not harness types:

- `http/client`: one final `Transfer_Summary` per request: stopping phase, accepted
  plaintext request/body bytes, request completeness, response-head presence, status,
  declared body length and presence. A zero observer changes nothing. Accepted bytes
  do not prove peer receipt.
- `ai`: one `Provider_Operation_Report` per operation at `Encoded`, `Response_Body`
  and `Transfer`, using `ai` vocabulary. `ai` owns the exhaustive mapping from the
  transport phase, so a new phase fails to compile until it is interpreted.
- `mcp`: an operation-scoped `Wire_Observer` borrowing complete JSON-RPC lines before
  write and before decode. `mcp.Error.delivery` remains authoritative for delivery.

Observers are borrowed for one synchronous operation and never retained. A bridge
hashes/copies what it needs and points into nothing the operation frees. Only attach
an observer when metadata or capture needs it, and do not hash a disabled event.

Byte accounting distinguishes, and never presents one as another: encoded request
body bytes; plaintext accepted by the socket/TLS layer; observed streaming response
bytes; declared response bytes; stored capture bytes. A capture may be a truncated
prefix and says so.

## Capture and privacy

Capture is explicit consent, separate from verbosity:

```text
NABLA_LOG_LEVEL   = off | error | warn | info | debug   (default info)
NABLA_LOG_CAPTURE = off | payloads                      (default off)
```

An invalid value warns once and falls back to the safe default; it never enables
capture. Capture does not override `off`. Producers are the provider request body,
the de-framed successful response stream, and complete MCP outgoing/incoming lines.
Not captured: HTTP headers, credentials, process environment, non-2xx bodies beyond
the bounded error detail, MCP stderr. Captured bodies can contain secrets; the mode
is not described as safe and prints one local warning.

Default records omit prompts, instructions, arguments, file contents, command text,
tool output, environment values and configuration dumps. Endpoints appear as provider
id plus sanitized origin/path, never userinfo, query, fragment or credentials. Peer
error text is bounded and may echo request content, so a record is not safe to publish
unreviewed. Producers enforce this; it is not a guarantee about peer content.

Each capture owns its fd and two incremental SHA-256 contexts (observed and stored),
borrows the active sink at begin, and copies correlation with the sink allocator. After
the allowance it keeps counting/hashing observed bytes without storing them. Finish
writes a bounded sidecar via temporary file and rename. A crash between payload and
sidecar leaves an orphan; a reader never infers completion from a filename and never
promotes an orphan. A capture failure disables that capture only and cannot fail the
model request or stop stream consumption. Never splice a head and tail into a claimed
exact body.

Layout under the resolved state directory:

```text
logs/cleanup.lock
logs/runs/<run-id>/{lease, events-NNNNNN.jsonl, captures/…}
```

Directories 0700, files 0600, close-on-exec, exclusive creation for runs/segments/
artifacts, no symlink following, and no model/tool/URL/session text in a path.

## Retention

Liveness is an exclusive lock on the run's `lease`, not a timestamp or pid. Cleanup
runs once per launch under the exclusive `cleanup.lock`, which run creation also takes
so a cleaner never meets a run with no lease yet. The lock file is never unlinked.
Probe each candidate lease non-blockingly: contention means active; a missing or
successfully locked lease means collectable; any other error means unknown, so keep
the run and count the failure. Remove expired runs first, then the oldest until count
and byte targets hold. Decrement remaining counts/bytes only after successful deletion.
Include nested captures in byte accounting and bound entries/depth as well as run
count. A scan limit marks cleanup incomplete; it does not claim the targets hold.

## Reading and export

```text
nabla diagnostics <session-id> [--request N] [--level NAME] [--export DIR [--include-payloads]]
```

The reader selects records by their parsed session field, not by filename, so a
session spanning runs is read across them. It validates envelope version, run id and
sequence before believing contents; segment order comes from the parsed number; a
segment is read through `lstat`, never a symlink, and only up to its size at read
start. A malformed interior line is reported with location and skipped; a malformed
final line is a truncation warning. Records go to stdout exactly as written; the
summary and unreadable evidence go to stderr. Exit 1 for no matches, unreadable
evidence, malformed lines, scan limits or output failure; exit 2 for bad arguments.

`--request` additionally opens the session database read-only (no claim, creation or
migration) and reports the durable request row. Read-only WAL access is used; do not
use `immutable=1` while a writer may hold the WAL. Export writes a manifest plus
`session.jsonl`, `runs/<run-id>/events.jsonl`, optional `request.json` and opted-in
captures, all newly created with owner-only permissions, each file hashed, omissions
recorded, default total cap 32 MiB. Payload inclusion is diagnostic wire artifacts,
not a conversation dump. Follow mode is an explicit non-goal.

## Acceptance

Prove the sink never changes a turn: the same durable entries and call counts with and
without a writer. Cover foreign/nil loggers, nested rebinding, stale correlation after
session switch, injected write failure disabling the sink once, rotation windows,
retention with a live lease and an orphan, capture truncation vs incomplete observation,
orphan sidecars, read-only join beside a live writer, and that no ordinary `core:log`
producer persists raw targets, headers, credentials, environment or file paths.
Diagnostics and observers remain optional and never alter retries, delivery state,
durable rows, execution counts or exit status.
