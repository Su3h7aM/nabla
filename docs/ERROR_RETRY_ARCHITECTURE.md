# Provider failures, retries, and context recovery

Status: implementation specification, not implemented. Inspected against Nabla change
`knoqvwwr`, with Odin `dev-2026-09-nightly:a2fb372`. This document is authoritative for the
work below, with one superseded direction: the deadline-based recovery policy it proposes
(attempt timeout, recovery budget, retained turn deadline) was rejected. Model requests carry
no harness time bound; only the provider bounds deliberation. A future implementation must not
reintroduce harness deadlines. The existing compaction lifecycle remains implemented as described in
[Context management and non-blocking compaction](CONTEXT_COMPACTION_ARCHITECTURE.md).
Where this document changes that policy, the change is explicitly identified.

## 1. Scope and decisions

Keep a turn running when another provider attempt can reasonably succeed. Do not turn
configuration mistakes into retry loops, tool failures into duplicate effects, or context
exhaustion into a wait for summarization.

There are three possible decisions after a failed provider attempt:

- Stop this turn. The session remains available for another prompt.
- Retry the same frozen request after a bounded, cancellable delay.
- Install an already-ready checkpoint, rebuild the request, and try the changed context once.

These are an enum and a few procedures in `agent`, not a plugin protocol or a retry service.
`ai` classifies provider facts. `http/client` reports HTTP and transport facts. Only `agent`
decides whether to send again. No automatic model fallback, credential refresh, arbitrary
history deletion, thinking-block stripping, or retry-everything mode.

The two open compaction items are resolved here:

1. Provider-confirmed context overflow gets one repair using a checkpoint already ready at
   the failed request boundary. An unfinished compaction never makes the foreground wait. Not yet
   implemented; it needs the provider classification in §3.
2. Aggregate tool-result admission gets a per-response budget and durable result storage. Large
   results become small handles before entering history. Implemented, and described in §8.

Cache breakpoints, prefix prewarming, and measured growth rates remain optional tuning work.
They are not prerequisites for correct failure recovery. A finite context and an unavailable
summarizer still cannot guarantee indefinite execution.

### Invariants

1. One provider operation performs one send. There is no retry loop in `ai`, `sse`, or HTTP.
2. A transient retry uses the same endpoint, credentials, model, instructions, tools, effort,
   cache key, and encoded body. A repair is a different request, not a hidden mutation.
3. No retry after user-visible text or an accepted completion. No tool from an unsuccessful
   attempt executes. Bytes accepted by a socket do not prove provider execution did not occur.
4. Cancellation and storage failure defeat every recovery decision, including one already
   scheduled. Time spent waiting counts against the recovery deadline.
5. Each actual send has its own durable request row, recorded before sending. Failed attempts
   and diagnostic messages do not become ordinary model-visible conversation entries.
6. A retry does not reset the turn deadline, add another user prompt, refresh skills, or drain
   steering into the frozen request. Steering is applied at the next ordinary boundary.
7. Previously committed tool calls are never replayed to recover a provider failure.
8. Compaction remains independent of the foreground turn. No foreground path joins a running
   summary worker, including recovery from a provider rejection.

## 2. What exists and what needs changing

The supplied study's Nabla section describes an older revision. The current code has background
compaction and `context.compact`, but provider failures still take the older retry path.

| Current code | Relevant behavior | Required change |
|---|---|---|
| `agent/chat.odin:chat_perform_request` | Three attempts on one operation and one request row | Separate attempt recording, retry policy, and context repair |
| `chat_request_retryable` | Transport/stream and HTTP 408/409/429/5xx retry; timeout and TLS never retry | Use normalized facts; distinguish attempt timeout from exhausted recovery budget |
| `chat_provider_event` | Error callback immediately fails the session operation | Keep attempt error provisional until the caller decides recovery |
| `ai/request.odin` | Returns kind/status/detail; loses `Provider_Code` on stream errors | Preserve structured failure evidence in returned error |
| `http/client/client.odin` | Discards headers; formats a bounded error-body excerpt | Expose bounded, decoded response evidence before formatting |
| `ai/http.odin` | Transfer observation attached only when diagnostics need it | Make decision facts available independently of logging |
| `agent/compact.odin` | One send; failure cooldown is 5 seconds; explicit trigger bypasses it | Bounded retry chain and class-sensitive suppression |
| `agent/tool.odin:tool_result_finalize` | Oversized result replaced irretrievably; 64 KiB per result | Done: the batch budget and the handle decision moved to `tool_result_read.odin`; the per-result cap remains |
| `agent/chat_tools.odin` | Results recorded sequentially without a batch budget | Done: the batch budget is opened before the first result is recorded |
| `agent/chat_command.odin` | Failed steering may display an unrelated `last_error` | Return a typed steering outcome and display only its own failure |

Current partial assistant entries are excluded by `chat_build_request_into`. Retain that
contract. The study's statement that nothing is excluded from projection is not accurate for
partial answers. A bad request can still repeat because its input remains invalid, not because
all diagnostic errors are being replayed to the model.

The retry loop currently re-encodes `prep.request` on every attempt. Freeze actual encoded bytes
once using the existing `Provider_Encoded_Request` path rather than relying on the comment
that calls them the same bytes.

## 3. Error facts and package boundaries

### 3.1 HTTP evidence

Extend `client.Options` with an optional response-head callback, separate from the diagnostic
observer. It receives final status and borrowed `http.Headers` after the final response head
has been read, before the body. No provider field names belong in this callback's implementation.
Headers live only for the call. `sse.post` forwards this option without interpreting it.

Extend `client.Failure` with bounded error-body bytes and a truncation flag. Read non-2xx bodies
through the existing framing rules, including chunk decoding and content-length, under the same
probe and deadline as successful bodies. Stop at `HTTP_MAX_ERROR_BYTES`, currently 4096.
A truncated or malformed body is evidence, not a valid JSON document. Preserve the status even
when reading its error body fails. Do not parse the existing `"HTTP 400: ..."` display string.

Use an explicit `client.failure_destroy` contract to release owned body/detail data on all paths,
including content-type rejection. Current ownership differs by error kind; adding more owned
fields without one destructor is error-prone. `ai` copies what it needs before destruction.
Do not retain all headers or raw error bodies in the harness's durable failure record.

Retain the underlying `client.Error` cause in the failure, and collect `Transfer_Summary` even
with diagnostics disabled. `ai` maps it into provider vocabulary. This permits a TLS trust or
hostname failure to remain terminal while a TLS read/write disconnect can retry. Unknown TLS
failure stays terminal. Never weaken certificate verification to recover.

### 3.2 Provider evidence

Keep `Provider_Operation_Error_Kind` for the local operation outcome. Add a separate
`Provider_Failure_Class` enum for the provider's rejection or unusable output:

```text
None, Unknown, Authentication, Quota, Rate_Limited, Context_Overflow,
Payload_Too_Large, Invalid_Request, Content_Policy, Provider_Unavailable,
Incomplete_Stream, Invalid_Output
```

Extend `Provider_Operation_Error` with these fields:

| Field | Contract |
|---|---|
| `failure_class` | Normalized provider meaning; `None` when no provider classification applies |
| `provider_code` | Owned bounded code/type string, empty if absent |
| `provider_request_id` | Owned bounded identifier from a documented response header, empty if absent |
| `retry_after` | `Maybe(time.Duration)`; nil differs from zero |
| `retry_directive` | Enum `Unspecified`, `Forbid`, `Allow`; recognized provider header only |
| `transfer` and `transfer_present` | Mapped transfer facts, independent of diagnostics |
| `transport_cause` | Provider-neutral cause distinguishing trust, configuration, connection, and I/O failures |

Keep the existing owned `detail` and numeric `status`. Add
`Provider_Operation_Error_Destroy` and use it for both foreground and compaction results.
Zero initialization means no operation error, no directive, and no borrowed resources.
A nonzero operation error with no positive classification must not look like success.

Implement `provider_classify_failure` in `ai`, with API-specific extraction alongside the
existing OpenAI and Anthropic adapters. The same classifier handles HTTP error documents and
in-stream `Provider_Error_Event`. Preserve `Provider_Code` through `provider_accept_event` and
`provider_terminal_error`; an HTTP 200 error event needs no invented non-200 status.
Parser failures preserve their own kind rather than being relabeled as provider rejection.

Classification precedence:

1. Local cancellation, local deadline expiry, and local request validation retain their own
   operation kind. Provider text cannot override them.
2. Authentication and quota evidence take precedence over generic retry hints. HTTP 401/403
   classifies authentication/permission failure, and 402 classifies quota/payment failure.
   In particular, a quota code inside a 429 is not throttling.
3. Recognized context-limit codes or API-specific context-limit messages classify overflow.
   An ordinary 413 is `Payload_Too_Large`, not proof of context exhaustion. A generic 400 is
   `Invalid_Request`, never automatically repaired.
4. Recognized policy refusals are terminal. Output length exhaustion is not input overflow.
5. 429 means rate limiting absent stronger evidence. 408/409 and 500..599 mean transient
   provider unavailability, except recognized permanent failures. Statuses outside the valid
   HTTP range do not become retryable merely because they are numerically large.
6. Other 4xx are invalid requests; unrecognized redirects are terminal. A stream missing its
   required terminal marker is `Incomplete_Stream`. Invalid JSON or inconsistent tool output
   is `Invalid_Output`, not a network disconnect.
7. Anything not identified stays `Unknown`. It is not retried by guessing from display prose.

Seed the adapter tables with OpenAI `context_length_exceeded`, `insufficient_quota`, and
Anthropic `rate_limit_error`, `overloaded_error`, `authentication_error`, `permission_error`.
Anthropic `invalid_request_error` needs a narrow message check for `prompt is too long` to
identify overflow. Codes describe the configured API family, not a guessed service hostname.
Compatible endpoints may omit them; HTTP status remains the fallback.

Use a small table of exact codes and narrow message predicates, not a configurable regex
engine. Capture unknown shapes in redacted diagnostics before adding a classifier rule.
A generic mention of tokens, length, or limits is insufficient evidence for repair.

### 3.3 Retry-After

Interpret `Retry-After` in `ai` from the borrowed response headers. Accept nonnegative decimal
seconds and HTTP-date. Reuse an HTTP-date parser if one is available when implementing;
current `core:time` supplies ISO 8601 and RFC 3339 parsers, not an HTTP-date parser. Add the
HTTP-date grammar to `http`, where it belongs, using `core:time/datetime` for calendar
validation/conversion. HTTP dates require IMF-fixdate and the two obsolete recipient formats;
do not feed them to the RFC 3339 parser.

Convert an absolute date to a nonnegative delay using wall time once at header receipt, then
wait against a monotonic deadline. Reject invalid, conflicting duplicate, negative, and
unrepresentable values. Saturate valid but enormous delays to a named out-of-policy sentinel
rather than overflow or treat them as absent. Limit inspected header values to 256 bytes.
A delay that exceeds policy is a reason to stop, not permission to retry earlier.

Use the header first. Provider-specific body delays can be added only for documented fields;
do not search arbitrary JSON for something resembling a delay. Respect `x-should-retry: false`
where the adapter recognizes it. `true` cannot override cancellation, trust failure, auth,
quota, invalid input, output exposure, or the attempt/deadline budgets. `Allow` confirms
eligibility only within the transient classes below; it does not make an unknown failure retryable.

## 4. Foreground policy

Put the pure decision and delay procedures in `agent/retry.odin`. Keep request execution in
`chat.odin`; do not add another package. Proposed declarations are data, not interfaces:

- `Request_Recovery_Action`: `Stop`, `Retry`, `Repair_Context`.
- `Request_Recovery_Reason`: named reasons for transient failure, terminal classification,
  output exposure, cancellation, deadline, attempt limit, excessive provider delay, and
  context exhaustion. Never a boolean with an unexplained false result.
- `Request_Recovery_Decision`: action, reason, and `time.Duration` delay.
- `Request_Recovery`: attempts sent, transient retries used, overflow repair used, monotonic
  deadline, and previous `Maybe(session.Request_No)`.

Policy defaults:

| Constant | Value |
|---|---:|
| `CHAT_REQUEST_MAX_ATTEMPTS` | 3 total sends, including a repaired request |
| `CHAT_REQUEST_RECOVERY_BUDGET` | 120 seconds, retaining the existing total operation bound |
| `CHAT_REQUEST_ATTEMPT_TIMEOUT` | 45 seconds, clamped to the recovery and turn deadlines |
| `CHAT_RETRY_BASE_DELAY` | 500 milliseconds |
| `CHAT_RETRY_MAX_DELAY` | 8 seconds for computed backoff |
| `CHAT_RETRY_MAX_PROVIDER_DELAY` | 30 seconds |
| `CHAT_RETRY_SLICE` | 50 milliseconds |

Retain `CHAT_TURN_DEADLINE = 300 seconds`. One response/recovery chain gets 120 seconds in total,
not 120 seconds per send. An attempt timeout can retry while that total remains; exhaustion of
the total or turn deadline cannot. A slow but valid provider may require tuning the 45-second
attempt default. Make the limits one policy struct passed to the runner, with these production
defaults; tests can use short deadlines without environment-variable bypasses.

### Decision order

After the synchronous send returns and provisional output is settled:

1. Storage failure, cancellation, or expired total deadline: stop.
2. Successful complete operation and accepted completion: commit normally.
3. Published text or accepted completion: stop on failure. Preserve text as partial.
4. Confirmed input overflow: use §7, never ordinary backoff.
5. Terminal class or `Forbid`: stop.
6. Retry transient connection/I/O failure, attempt timeout, incomplete stream, rate limiting,
   or provider unavailability if another attempt and time remain.
7. Otherwise stop. Unknown provider failure and malformed output are terminal initially.

Do not make delivered body bytes the exposure test. A usage update, keepalive, or ignored
reasoning event is not visible output. Track `text_exposed` and `completion_accepted` explicitly
in per-attempt runtime state. If reasoning becomes visible later, it must set exposure too.
`Provider_Completed_Event` remains withheld until clean transport completion, as it is today.
A successful HTTP exchange with an unusable completion is not retried by the transport policy.

The policy deliberately does not copy opencode's synthetic continuation prompt. Nabla excludes
partial answers from model context; inserting a continuation would require a different history
contract and might repeat prose or proposed actions. Stop transparently after exposed output.

### Delay and cancellation

For transient retry number `n`, starting at 1:

```text
ceiling = min(8 seconds, 500 milliseconds * 2^(n - 1))
backoff = uniform(ceiling / 2, ceiling)
delay   = max(backoff, retry_after if present)
```

Compute in checked/saturating integer durations. Use `core:math/rand.float64_range` for jitter,
with the thread's generator. Pass a sampled fraction to the pure delay procedure in tests.
No custom random generator or scheduler framework.

If the provider asks for more than 30 seconds, or the delay reaches the remaining total budget,
stop with a typed reason and show the delay the provider requested. Do not cap a 10-minute
instruction to 30 seconds and send early. Check cancellation before scheduling, during each
50 ms wait slice, and immediately before sending again. Extend `chat_retry_wait`, which already
sleeps in `CHAT_RETRY_SLICE` slices against a monotonic deadline, to take the recovery deadline
as an argument and to distinguish cancellation from expiry in its result. Do not switch it to
wall-clock arithmetic: a delay derived from an `Retry-After` date is converted to a duration
once, at header receipt, and then waited on monotonically.

While waiting, the driver may poll/adopt completed compaction work, but cannot install it into
the frozen request or start unrelated inference. A ready summary waits for the next boundary.
Queued ordinary steering stays queued. Stop/cancel remains out-of-band and interrupts the wait.

## 5. Attempt identity, persistence, and accounting

Reuse the existing request table instead of adding an attempt table. Change its operational
meaning to one actual provider send. `Request_No` identifies that send; retry chains are linked
by small versioned harness JSON fields. `agent/session` stores them without interpreting policy.
Existing databases need no request-table migration.

Extend the request input record to version 2 with `previous_request_no`, `recovery_kind`
(`initial`, `transient_retry`, or `checkpoint_repair`), and `attempt_number`. Preserve the existing
instruction snapshot, `summary_seq`, `covered_seq`, and `context_through` fields. Include a digest
of the encoded body using the existing logging digest facility, not another hash implementation.
The first request has no predecessor. Changed context always names the new checkpoint.

Each send has this lifecycle:

1. Build/admit/encode once at the ordinary boundary, then retain the preparation and bytes.
2. Record `request_begin`; assign a fresh operation/event-source identity for this attempt.
3. Perform one `Provider_Request_Operation_Encoded` call with the attempt deadline.
4. Finish its row with success/failure/cancellation, normalized error, and attempt-local usage.
5. Decide recovery. Persist the decision with the failed request's finish record before waiting.
6. If retrying, wait, clear all attempt state, record the next row, then send identical bytes.
   For repair, use §7 and record the rebuilt input as the next row.

No database transaction spans a network call or a wait. Computing a recovery decision before
`request_finish` is allowed; acting on it before the write succeeds is not. A finish record may
say that repair was eligible, but it cannot claim installation happened before the checkpoint
transaction committed. The next row and checkpoint entry prove the actual action.

Version 2 error JSON contains operation kind, failure class, status, provider code/request id,
retry delay if present, exposure flags, stop/recovery reason, scheduled delay, and bounded detail.
Cap durable detail at 2048 UTF-8 bytes and provider code/request id at 256 bytes each. Truncation
must remain distinguishable from absence. These limits also apply to HTTP 200 error events.
Store enum names, not ordinals. Unknown future names decode as unknown. Historical v1 request
rows remain valid aggregates; never manufacture missing historical attempts.

Reset `Chat_Runtime_Context`, staged output, finish reason, error ownership, and usage for every
send. Do not use `chat_session_clear_attempt` to undo an already-finalized turn. Error callbacks
capture attempt-local facts; only terminal recovery decisions call `chat_session_feed_error`.
The returned `Provider_Operation_Error` is authoritative for operation failures. Callback-level
completion validation failures are a separate explicit terminal result, even if the operation
returned `.None`. Retire each operation only after its call returns.

Usage events can be repeated or cumulative within a send. Keep the latest reported value for
each bucket, never sum snapshots. Sum sends when reporting turn/session cost, including failed
sends and compaction. Missing stays nil. Keep a separate count of sends without reported usage
so a total does not claim to include unreported cost. `last_input_measured` is the latest request's
input estimate anchor, not the sum across retries. Update `chat_request_usage`, root usage
consumers, and cache-total readers accordingly.

Crash recovery still closes running rows as interrupted and never automatically replays them.
A retry scheduled before a crash is an audit fact, not a durable alarm. A new prompt starts a
new recovery budget. No stale error or global provider blacklist prevents that prompt.

A row begun before a crash may never have reached the network. Report it as interrupted with
unknown delivery, not a proven send or billable attempt. `attempt_number` counts attempted sends
in the chain; confirmed transport facts and reported usage remain separate evidence.

## 6. Tools are not provider retries

A completed provider response commits its calls before dispatch. Keep that boundary. A transport
failure may have consumed provider tokens, even if no text was published, but cannot have run a
Nabla tool because dispatch requires a committed successful response.

Do not wrap `chat_run_tools` or MCP execution in this retry loop. An uncertain shell/MCP outcome
stays `Unknown`; an unavailable tool stays unavailable. Tool behavior hints are not sufficient
proof that repeating an arbitrary invocation is safe. The model may choose a subsequent call
from the recorded outcome. Process recovery never runs a previously dispatched tool again.

The provider APIs used here generate text and client-side calls. If provider-executed tools or
remote side effects are added, automatic ambiguous-delivery retries require a separate provider
contract or idempotency mechanism. Do not generalize the current policy to such operations.

## 7. Resolve provider-confirmed context overflow

Local admission and provider overflow use the same repair opportunity, but they are different
facts. Local admission is an estimate; a provider can reject a request that passed it.

On confirmed overflow with no exposed output:

1. Finish the failed attempt row. Check storage/cancellation/deadline first.
2. Refuse if the chain already repaired once or has sent three attempts.
3. Poll the compaction worker once. It may have completed while the rejected request was sent.
4. If there is a ready, valid candidate, call the existing conditional checkpoint installation.
   Check base/coverage/origin exactly as normal. A stale candidate is not progress.
5. Rebuild the preparation against the installed checkpoint. Require a different checkpoint,
   an estimated reduction of at least `CHAT_COMPACT_MIN_REDUCTION_TOKENS`, and local admission.
6. Mark the repair used and send immediately as the next attempt with the remaining budget.
   No transient backoff is required for a rejected payload whose context actually changed.

The old request's error is immutable. The new request points to it through `previous_request_no`.
No recursive call to `chat_perform_request`: the bounded outer recovery loop owns both payloads.
A second overflow is terminal even if another candidate appears. The unchanged request is never
resent for overflow, and the counter does not reset when the payload changes.

If no candidate is ready, end the turn with `Context_Exhausted`, carrying a reason such as
`Summary_Running`, `No_Candidate`, `No_Reduction`, or `Repair_Rejected`. Do not sleep until one
appears, even as a special case of retry. Record session-level capacity pressure so idle servicing
can start a background summary from an admissible prefix if none exists. Never submit the
rejected full foreground payload as the summary request. Use the existing seam and independently
check the summary's admission; if no such prefix fits, report that constraint.

Add a `Provider_Overflow` compaction trigger. It installs at the first safe boundary, like an
explicit trigger, and does not bypass retry cooldown. A summary already running is promoted to
that trigger. If it later finishes after the turn failed, idle servicing may install it and report
that the same session has capacity again. It must not resume the failed turn or rerun its tools.
The user can submit another prompt without starting a new session.

Do not overwrite `context_window` with a guessed lower limit based on arbitrary error text.
Store the provider rejection and estimate for tuning. If instructions, tool schemas, a single
user entry, or the retained call/result run itself exceeds the available context, this plan does
not silently discard it. Report which part local accounting identifies as too large.

## 8. Aggregate tool-result admission and spill

Status: implemented. `agent/tool_result_read.odin` owns the batch budget, the handle, and the read
tool; `agent/chat_tools.odin` charges each result against that budget; `agent/session` stores the
result and reads it back.

A turn's results are bounded as a batch rather than one at a time. One large result must not crowd
out the rest, and the sum is what makes the next request unsendable.

### 8.1 The batch budget

When a response has committed its calls, `chat_tool_budget_open` opens the batch's budget: what the
model's context holds once that response is committed, subtracted from what the window admits.

```text
remaining = chat_capacity_input_ceiling(capacity) - (last_estimate + response_cost)
```

`response_cost` is what the committed response added: its text, the calls it proposed, the
harness's notice, and the verbatim output when the API produced one. It is estimated the way the
projection is, so the batch is charged for what the next request will carry. The wall is the
window's input ceiling rather than the compaction trigger, because the trigger exists to start
background work and not to stop the agent from using the window it has.

Each result is offered what is left after a handle is set aside for every result still to come. A
result that fits keeps its content; one that does not is spilled. The decision is made once, as the
result arrives, and stored, so a request built from these entries sends the same bytes however much
the context grows afterwards. That stability is the point: rewriting an earlier result's
representation would invalidate the cache from that point forward.

`TOOL_RESULT_HANDLE_TOKENS` is the reserved constant. A handle is a fixed envelope carrying a
sequence number and a byte count, so every handle costs nearly the same, and a test holds the real
handle to that bound so the constant cannot drift away from the text it stands for. Reserving a
constant is also what lets the budget be closed before any result is recorded.

The budget can go negative when even handles do not fit. The next request then fails admission,
which is the honest report that the context is full. Nothing waits and nothing is dropped.

### 8.2 The record keeps the result; the model gets a handle

There is no second store. `Tool_Result_Entry` already holds the observed result for every call, so
a spilled result stays exactly where it was written; only `spilled: true` is added. The handle is
derived from that entry by the projection and never stored beside it, so the record and the
projection cannot disagree about what the model was told.

The handle is an ordinary result envelope naming the call:

```json
{"status":"success","message":"the observed output did not fit this context and was kept in the
session; read it with context.read_result","data":{"call_seq":42,"bytes":48123}}
```

`call_seq` is the call the result answers, which is the key `context.read_result` takes.

Reads go through `session.tool_result_read`, which selects one result entry by its call and returns
it; the tool slices a page out of it. The window is a byte range rather than a line range, because a
stored result is not a file and the model is given its size, so an offset is the one thing both
sides can agree on. The page ends on a character boundary, because half a character is not a string
the encoder can send. A read never spills into another handle and never mutates the record; a page
that does not fit the tool's own bound is shortened, and `next_offset` and `eof` say where to
continue.

`Result_Reader` carries the store and the session and nothing else, and reaches a tool through
`Tool_Context.results`. It is borrowed by the whole batch, so a call can read back what an earlier
call in the same turn kept.

### 8.3 What remains

- **Retention beyond the per-result cap.** `TOOL_MAX_RESULT_BYTES` (64 KiB) still bounds one stored
  result, and a larger one is replaced by an honest message rather than a prefix. Keeping a
  UTF-8-safe prefix and marking it incomplete would make the largest results retrievable too. Every
  producer already bounds its own output well below the cap, so the gap is a large MCP result.
- **A session-wide retention cap.** Nothing bounds what one session keeps across turns. The bound
  is per result until a session total exists.
- **`Context_Exhausted` as a typed reason.** A batch that cannot fit at all currently ends as a
  failed admission, which is the right outcome but not yet a reason the front-end can name. §7
  defines it.

Malformed envelopes remain a tool-contract failure with the observed outcome preserved. They are
not provider failures and do not enter this retry policy.

## 9. Background compaction retries

Use the same pure classifier and delay computation, but a smaller chain: at most two sends and
120 seconds total, with a 45-second per-attempt timeout. No hidden retry loop inside the worker.
An unsuccessful partial summary may be discarded and retried because it was never published or
installed. A summary with tool calls, length exhaustion, malformed output, or insufficient
reduction is not repaired by blindly regenerating it.

Add `Backoff` to `Compact_State`. The owner polls a completed worker, joins only after it is done,
finishes that attempt's `.Compaction` request row, and records the retry decision. In `Backoff`,
the frozen snapshot and monotonic retry time remain owned by the job, but no worker runs. At the
due time, the owner clears output/error/usage, begins a new request row, and starts a new one-send
worker on the same bytes. The successful attempt's request number is the checkpoint origin.
No new checkpoint table or auxiliary session is needed.

`app_compaction_pending` must include `Backoff`; idle ticks and foreground boundaries service it.
They never sleep for it. Headless execution services only ordinary boundaries and cancels remaining
work at teardown. Cancellation of a foreground turn does not cancel this session-level job.
Session/model changes and teardown cancel both running and scheduled work.

After chain exhaustion, pressure may start a fresh snapshot only after a 30-second cooldown and
new foreground context progress. Track the last attempted context-through sequence and resolved
configuration identity. Repeated explicit triggers coalesce and do not bypass cooldown or
provider-requested delays. Terminal auth/quota/invalid-request failures suppress automatic starts
for that configuration; explicit retry after configuration/credential correction may clear that
suppression, but never a pending Retry-After time. Use an owner-side configuration generation,
incremented when resolved model, endpoint, credentials, or request options change. Do not log
credentials or use their plaintext as a suppression key. Overflow or a too-large summary requires a
changed admissible prefix. This replaces the existing unconditional 5-second retry policy.

Keep database and policy work on the owner thread. Worker output is read only after join. For
allocator safety, do not assume that wrapping only worker allocations in `mem.mutex_allocator`
serializes an unwrapped foreground allocator. Allocate worker-owned snapshot/output/error storage
from a thread-safe heap independent of the caller's allocator, using `core:os.heap_allocator`.
Keep owner control objects on the session allocator. Copy across that ownership boundary before
thread start and destroy with the matching allocator after join. Alternatively, serialization
would require every caller of the backing allocator to use the same lock; do not introduce that
larger change here. The signal-mask inheritance rule remains unchanged.

## 10. User-visible behavior and recovery reporting

Expose a typed retry callback/event through `Chat_Observer`: request number, next attempt, maximum
attempts, failure class, and due time/delay. Root owns wording and the status snapshot. Headless
mode prints one notice per scheduled retry; TUI shows the next attempt and clears it on send,
success, cancellation, or terminal failure. No renderer reaches into `Compact_Control` or policy.

Use structured events `request.retry_scheduled`, `request.retry_started`,
`request.recovery_stopped`, and `request.context_repaired`. Correlate every one with the actual
request/attempt, and include the changed checkpoint for repair. Keep existing transfer diagnostics,
but do not make policy depend on them being enabled. Redact credentials and sensitive response
text; identifiers and bounded error text remain subject to the existing logging policy.

Persist typed terminal failure data on the turn as well as the last failed request. It includes
`Context_Exhausted` and its cause, not just a display string. Local admission can fail before a
request row exists; do not invent a sent request for that case. The frontend should distinguish:

- temporary provider failure exhausted its retry budget;
- credentials/quota/configuration require a change;
- partial output prevented safe automatic retry;
- context is full while a summary is running, or no admissible summary exists.

Fix steering's stale-error path with a small result enum such as `Accepted`, `Outside_Boundary`,
`Storage_Failed`. Only the last uses a new storage error. Do not display a previous provider error
because a later message arrived at the wrong boundary. Audit the queue drain after turn failure:
accepted pending prompts must either start a fresh turn or remain visibly queued, never be lost
under the old failure. Cancellation/quit retains the existing explicit discard semantics.

Do not impose a cross-turn identical-payload circuit breaker. A user may have repaired credentials
without changing history, and an endpoint may recover. The bounds apply to automatic recovery
inside a turn and background compaction chains; a new explicit prompt always gets a fresh decision.

## 11. Odin implementation rules

Use explicit enums, structs, exhaustive switches, and procedures. Fallible storage procedures
return the value followed by `session.Error`, as existing session code does. Policy returns a
plain decision, not an exception or a callback chain. Optional data uses `Maybe`; no negative
millisecond sentinel escapes the parsing boundary.

`time.Duration` is the internal delay type, `time.Tick` the wait/deadline type. Wall milliseconds
are serialization facts only. Reuse `ai.deadline_in`, `deadline_remaining`, and the existing probe
for transport cancellation. `core:strconv` handles decimal parsing; `core:encoding/json` handles
provider documents and persisted records; `core:unicode/utf8` handles result boundaries. Do not
write a second event loop or replace existing `core:nbio` transport waits.

Every owned result has one destructor. Borrow headers/events for callbacks only; clone bounded
fields that survive them. Retain encoded bytes through the entire foreground chain. Destroy old
preparation and bytes only after the prior operation returns, then rebuild for repair. Keep the
job's frozen snapshot across background retries and release it only after its last worker stops.
No job data or retained failure detail comes from `context.temp_allocator`.

Comments should document these ownership/boundary contracts, not narrate loops. Put classification
rationale and retry defaults here; tests assert observable recovery behavior, not enum layouts or
status-message wording.

## 12. Implementation sequence and gates

Each step is an independently reviewable change. Keep old behavior until the relevant replacement
is usable, rather than enabling a retry path that has not acquired durable recording or ownership.

1. **Preserve failure evidence.** Extend HTTP response metadata and framed error-body handling;
   add destructors, provider normalization, Retry-After, and diagnostic-independent transfer facts.
   Touch `http/client`, `sse`, `ai/http.odin`, `ai/request.odin`, and provider adapters. No harness
   retry policy changes yet.
2. **Separate attempts from turn failure.** Freeze foreground bytes, make runtime/error/usage
   attempt-local, give each send a request row and operation identity, add versioned records.
   Update `chat_record.odin`, `chat_session.odin`, `chat.odin`, usage consumers, and recovery tests.
3. **Install the bounded retry policy.** Add `agent/retry.odin`, attempt deadlines, cancellable
   backoff, typed observer reporting, and the steering fix. Reuse the existing HTTP test fixture.
4. **Recover confirmed overflow.** Add the one-repair branch, typed context exhaustion, pressure
   promotion and idle recovery. Preserve existing conditional checkpoint persistence.
5. ~~**Retain and admit tool results.**~~ Done: the batch budget, the stored result, the derived
   handle, and `context.read_result`. See §8, including what it leaves open.
6. **Apply retry policy to compaction.** Add owner-driven backoff, one-send request records,
   suppression/cooldown, allocator isolation, and root idle servicing. No foreground wait added.
7. **Validate and update status.** Mark implemented sections only after their gates pass. Run a
   small live failure exercise to tune latency defaults separately from deterministic tests.

Minimum useful test groups:

- Table-driven classifier/delay tests: quota 429 versus rate limit, context 400 versus generic
  400/413, HTTP 200 error event, permanent TLS versus I/O disconnect, malformed/duplicate/huge
  Retry-After and HTTP-date. Assert parsed facts and chosen actions, not messages.
- One scripted provider sequence: 429 then truncated pre-output stream then success. Assert
  identical encoded bytes, three finished request rows, retry links, attempt-local usage, and
  one successful conversation append. Run with diagnostics disabled too.
- Extend that fixture for cancellation during delay, total deadline exhaustion, and text followed
  by disconnect. Assert bounded sends, no automatic continuation, no executed partial tool call,
  and a fresh prompt can succeed. No wall-clock tests that sleep for production backoff periods.
- Extend the existing compaction lifecycle test for provider overflow: a ready summary repairs
  once and preserves the post-fork tail; a stalled summary causes immediate context exhaustion;
  second overflow stops. Assert no checkpoint for a failed/stale candidate and no unchanged resend.
- Artifact/batch integration: many large results stay within the allocated model-visible budget;
  exact retained bytes can be read after reopen; references and results commit atomically; reading
  does not recursively spill; capacity failure does not cause a repeated tool execution.
- Extend worker lifecycle coverage for background backoff, cancellation while scheduled, exhausted
  retries, and shutdown. Run allocator tracking plus address/thread sanitizers for this work.

Use colocated tests and the existing in-package HTTP fixtures rather than a mock-provider framework.
`mise run check` and `mise run test` are the final gate, including release/debug and external
harnesses. Focused package tests are sufficient while developing a step. Live cache economics,
provider latency, and summary quality need measurements; passing a fixture cannot establish them.

## 13. Reference evidence and choices

The supplied study is `~/.opencode/plan/nabla-error-retry-reference-study.md`, read in full for this
design. It traces goose, opencode v2, and Chipset source, with concrete paths and revision notes.
Those external checkouts were not independently re-audited here. The useful evidence is summarized
below so this plan does not require their local paths to exist on another machine.

- Goose `retry.rs` distinguishes transient retries from permanent failures and uses jitter.
  Nabla keeps that distinction but rejects goose's default retry of generic request failures.
  Multiple retry layers can multiply sends, so Nabla keeps one policy owner.
- Opencode `runner/retry.ts` and `runner/step.ts` separate retry, continuation, and context repair,
  and expose scheduled retry state. Nabla adopts explicit decisions and reporting, but not the
  synthetic continuation path or default retry of unknown failures.
- Chipset `llm-retry` records a decision before waiting and delegates terminal failures back to the
  loop. Nabla uses the same durability ordering without the plugin waterfall. It also adopts the
  refusal to shorten an excessive provider delay into an early send.
- All three distinguish overflow repair from identical-payload retry. Their compaction waits are
  not transferable to Nabla's non-blocking contract. Only an already-ready candidate can repair
  this foreground request; a late summary benefits a later turn.
- Their error records demonstrate that audit history and model-visible history need not be the
  same projection. Nabla already has request outcomes and partial-entry exclusion. Keep those
  boundaries rather than introducing assistant error messages.

Local evidence inspected: `agent/chat.odin`, `chat_request.odin`, `chat_session.odin`,
`chat_command.odin`, `operation.odin`, `compact.odin`, `chat_tools.odin`, `tool.odin`,
`agent/session/context.odin`, `history.odin`, `ai/request.odin`, `http.odin`, `interrupt.odin`,
`contract.odin`, `http/client/client.odin`, and the current compaction architecture.
Odin facilities checked in the installed root: `core/math/rand/rand.odin`, `core/time`,
`core/time/datetime`, and `core/os/heap.odin`. Implementation must verify any new procedure
signature against the compiler version in use, rather than assume another language's API.
