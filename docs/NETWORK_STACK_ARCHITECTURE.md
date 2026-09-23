# Network and provider transports

Status: accepted target, partially implemented. Owns outbound HTTP/1.1, TLS 1.3, SSE,
DNS and Responses-over-WebSocket, plus provider transport selection and delivery
evidence. [Errors](ERROR_RETRY_ARCHITECTURE.md) owns retry authorization and
[execution](EXECUTION_ARCHITECTURE.md) owns when a send happens. A passing test suite
is not a claim of protocol compliance.

## Scope and decisions

Keep the native Odin stack and correct the features actually used. Do not add a generic
network framework, transport vtable, sans-I/O rewrite or backend registry. Use explicit
structs, enums, exhaustive switches and trailing errors.

- Target default for provider transport is `auto`: prefer WebSocket for an API with an
  implemented adapter, otherwise HTTP/SSE. Explicit `http` and `websocket` remain
  overrides. Change the shipped default only after the correctness and cache/cost gates.
- Keep one foreground Responses connection per live session, one request at a time, on
  its creating thread, reused for full-context requests. Local committed history stays
  authoritative. A provider/model switch uses the new selection's transport and is
  invisible to the conversation.
- No incremental continuation, named lanes, connection-age timers, prewarming, socket
  pool, compression or background compaction over WebSocket in this phase.
- Fix request retirement, event identity, setup evidence and cancellation before
  extending reuse. Apply conservative delivery accounting to both WS and HTTP.
- Remove arbitrary parsing/message-size refusal caps from supported client paths; keep
  real wire, cryptographic and machine-representability bounds. Retention and retry
  policy never change a parsed protocol fact.
- Preserve provider prompt-cache reuse as a cost requirement. Fix the incomplete-usage
  hit-rate calculation and require measured parity before expanding rollout.

## Package responsibilities

| Package | Owns | Must not own |
| --- | --- | --- |
| `http` | HTTP syntax, fields, URL/request-target, framing, HTTP dates | Provider acceptance, retries, logging policy |
| `http/client` | DNS, TCP, trust loading, HTTP exchange, cancellation, Upgrade handoff | API status/media decisions, transport fallback |
| `tls` | TLS messages, authentication, records, alerts, keys | Filesystem trust policy, request lifetimes |
| `websocket` | RFC 6455 handshake, framing, text validation, control/closure | JSON, model requests, reconnect/replay |
| `sse` | Event-stream framing plus the HTTP POST convenience operation | Provider events, replay, browser lifecycle |
| `ai` | API codecs, provider failure classification, one-send operations, Responses connection state | Retry authorization, durable conversation, presentation |
| `agent` | Session lifetime, selection, fallback, attempts, committed history, retention policy | Protocol syntax or provider-name guesses |
| Root | Driving thread and process lifetime | A second transport policy implementation |

Keep the blocking byte-transport callbacks and `core:net`/`core:nbio` integration. Keep
the HTTP server a standalone consumer; shared parser changes migrate and test its callers.

## Bounds policy

Distinguish four things in code and documentation:

1. Wire/security bounds are mandatory: WebSocket control payloads ≤ 125 bytes, its
   63-bit frame length, TLS record/vector widths and key-usage bounds.
2. Buffer/chunk sizes are implementation choices, not maximum accepted input. HTTP
   fields and SSE lines grow; WebSocket payloads and HTTP bodies stream in chunks.
3. Allocation failure and unrepresentable values are local resource failures, not
   malformed peer input. Check growth, conversions and allocator results; never
   truncate and continue.
4. Retained log excerpts, tool-result admission, retry counts and waits are harness
   policy. They may bound retention or decline an operation; they never change a parsed
   fact or label a legal message invalid.

The HTTP client and SSE reader are used with configured provider endpoints, not as a
public server. Their response heads, lines, and events therefore grow until the provider
closes them, the caller cancels, or the process runs out of memory. This is an explicit
trust and resource policy, not a claim that a hostile peer is bounded by the HTTP or SSE
grammar. A deployment that exposes either parser to an untrusted peer must add a
per-request byte budget at that trust boundary before accepting the parser's result.

There is no implicit connect, idle or whole-request timer. Reusable transport callers
may supply cancellation/deadlines; model operations supply cancellation without a time
bound. DNS retransmission intervals and test timeouts are not model-request deadlines.

## Required corrections

Source observations to close before claiming the stack hardened. Each is a scoped
change with colocated tests.

| Area | Current behavior | Required |
| --- | --- | --- |
| TLS send cap | `MAX_SENT_MESSAGE = 2048`, one record per message | Remove the cap; checked dynamic encoding, legal handshake fragmentation |
| TLS key usage | No outbound epoch/usage guard; incomplete transition validation | Count protected records per send key; auto KeyUpdate before exhaustion; never reuse a nonce; reject forbidden interleaving |
| TLS records | Inner decode strips padding without validating content bound/type | Validate content and full inner length separately from authentication |
| TLS handshake | Cookie-only retry rejected; CCS unrestricted; alert parsing lax | Accept legal retry; reject invalid phases/lengths with the right alert |
| X.509 | Fixed chain-depth/signature-search budgets | Track as a dependency restriction; make an upstream change or keep verification fail-closed |
| HTTP client | Growing response lines, no body cap | Preserve growth/streaming; distinguish allocation from syntax failures |
| HTTP outcomes | Status/media-type rejection can hide framing failure | One exchange result with head presence/status, framing completion, typed error |
| HTTP fields | Duplicates comma-combined; request formatting trusts fields | Preserve duplicates; field-specific framing validation; reject CR/LF injection and conflicting lengths |
| HTTP chunks | Signed parsing; trailers under-validated | Parse `1*HEXDIG` with checked arithmetic; validate extensions/trailers; never reuse an ambiguous connection |
| URI | Empty-query presence lost; no fragment; case-sensitive schemes | Parse components once; scheme case-insensitive; preserve raw path/query; exclude fragments |
| Responses path | `/responses` appended to the whole URL | Shared component-based resource resolution for HTTP and WS |
| Retry-After | Ignored past 256 bytes | Scan all digits; preserve valid overflow as present; support HTTP-date |
| Provider errors | 8192-byte error-body prefix before classification | Parse complete error JSON with checked growth; bound only diagnostic copies in `agent` |
| SSE | Per-byte UTF-8 replacement; retry parse returns on overflow | WHATWG decoder behavior; validate the whole retry field; no line/event cap |
| WebSocket | 16 KiB chunks; lax subprotocol matching; extension offers refused | Keep chunking without total cap; exact unique offer/selection matching; refuse unimplemented extensions explicitly |
| DNS | 4096-byte buffer, no TC-to-TCP retry, first address only | Validate replies fully; TC fallback over TCP; sequential address fallback |
| WS provider | Any decoder failure becomes a terminal; socket may be retained | Separate terminal evidence from local parser failure; abort every unsuccessful operation |
| WS control | Prior operation's interrupt pointer retained | Bind control per operation; clear on every return; check affinity before use |
| Upgrade | Refusal body, retry headers, cancellation cause lost | Preserve response and exchange evidence; cancellation never triggers fallback |
| Retry policy | Every nonzero WS delivery state treated as ambiguous | Keep stop on uncertain sends; authorize only the narrow proven-rejection cases |

## Feature scope

Implement client HTTP/1.1, TLS 1.3 with supported authenticated suites, SSE framing and
RFC 6455 version 13 without extensions. Offer only HTTP/1.1 ALPN and validate the
selected value; absence of ALPN remains HTTP/1.1-compatible.

Do not add TLS 1.2, PSK/resumption, 0-RTT, client credential provisioning,
post-handshake client auth, HTTP/2, HTTP/3, redirects, cookies, proxy CONNECT or
compression in this phase. Reject unsupported outgoing CONNECT explicitly. Never
advertise a transfer coding the client cannot decode. Trust verification is always
enabled; an explicit CA bundle replaces defaults; no plaintext fallback and no insecure
verification switch. Revocation retrieval is absent and not described as implemented.

## Delivery evidence and fallback

Use one non-replay rule for WS and HTTP/SSE. Add explicit delivery-evidence presence
to `Provider_Operation_Error` and attempt facts. Zero/unset evidence means unknown, not
not-sent.

- `None`: the model-send path was not entered. An HTTP Upgrade alone does not send
  model input. Validation/DNS/connect/TLS failure before the request writer is entered
  can establish this, as can a pre-write cancellation, though neither authorizes a retry.
- `Model_Send_Started`: delivery is possible and nothing came back. Entering the WS
  frame writer, or the HTTP model-request writer without a final response head, suffices.
- `Response_Observed`: a valid request-associated provider event was decoded.
- `Terminal_Observed`: a valid associated provider terminal was decoded. It does not by
  itself make retry safe.

Keep a separate zero-safe evidence enum for explicit pre-execution rejection, set only
by a recognized API rejection contract. Do not overload delivery stages with retry
permission or infer permission from absence of output.

Only `agent` authorizes a further send. An uncertain model send stops with
`Ambiguous_Delivery`, discards the connection, and cannot be retried by switching
protocols. A fresh independently admitted request may use another transport. Neither
SSE nor WebSocket defines resume for these POST/create operations: do not send
Last-Event-ID, synthesize continuations, or reuse response IDs as idempotency keys.

| Evidence | Action |
| --- | --- |
| Unsupported API in `auto` | HTTP directly |
| Unsupported API in required WS | Local failure before network I/O |
| Valid Upgrade refusal 404/405/426/501 in `auto`, no stronger auth/quota evidence | Permit HTTP for this affinity |
| Transient DNS/connect/setup failure before a WS model send in `auto` | Sticky HTTP; next attempt only through ordinary eligibility |
| Required WS setup failure | Never fall back; ordinary eligible setup retry |
| 401/403, trust error, invalid local URL/header, invalid 101 | Stop; fallback must not hide these |
| Upgrade 429/availability response | Preserve status/body/Retry-After; ordinary retry, not sticky unsupported-transport |
| WS transport failure after send entry, no valid explicit rejection | Stop with unknown outcome; mark HTTP for future requests; do not resend |
| HTTP failure after writer entry and no final head | Stop with unknown outcome; do not try WS or another POST |
| HTTP failure after a final head (truncated/unfinished stream) | Ordinary classification; a transient class may retry within the bound |
| HTTP failure known before writer entry | Retry HTTP with ordinary backoff when eligible |
| Recognized pre-execution rate-limit/unavailable rejection | Ordinary bounded retry if eligible and no output |
| Recognized input overflow | Existing one-checkpoint repair within the attempt bound |
| Documented connection-limit rejection for the sole pending request, before any output | One reconnect/full-context resend within the bound; abort the old socket |
| Unknown error, malformed error, response failure without non-execution evidence | Stop |
| Successful completion then clean idle Close | Keep result; open WS for the next request unless the affinity uses HTTP |
| Successful completion then abnormal idle failure in `auto` | Keep result; select HTTP for subsequent requests |

Move `auto` preflight into the bounded attempt execution; each transport attempt,
including failed setup, consumes an attempt slot, and each actual model send has its own
request row begun before sending. A setup-only row records no model send. A fallback
attempt is authorized only when evidence says no model message was sent, and reuses the
same frozen projection with the other envelope. Keep the existing maximum-attempt policy
and no additional hidden loop.

Sticky HTTP is a transport decision separate from replay permission. Set it on an
eligible unsupported-Upgrade/setup failure or abnormal WS break, even when ambiguity
prevents recovering that request. Do not set it for cancellation, local/storage failure,
malformed provider output, auth, rate limiting, quota, ordinary rejection or the
documented connection-lifetime rejection. It lasts for the live affinity, resets on
explicit session/configuration replacement, and is not a persisted blacklist. Required
modes never switch. Record setup outcome, selection changes and fallback reason without
credentials, available with diagnostics disabled.

## Provider WebSocket integration

**Routing.** Keep `transport = "http" | "websocket" | "auto"` presence-merged into the
catalog; absent means `auto` once the rollout gates pass. Selection uses API capability
and observed outcomes, never a provider/model-name list. Explicit `http` never probes;
explicit `websocket` requires WS and never falls back. Resolve the Responses path once,
map `https`→`wss`/`http`→`ws`, preserve authority/query. No subscription URLs, beta
headers, Azure rewrites or capability guesses. Explicit local insecure endpoints are
allowed; failed TLS never downgrades.

The common Responses encoder generates the full logical request; HTTP adds `stream:true`,
WS adds `type:"response.create"` and omits `stream`, `background`, `stream_id`,
`previous_response_id`. Keep `store:false`. Re-encode only the envelope on an authorized
transport change; do not rebuild history, drain steering or adopt a checkpoint mid-retry.
Anthropic Messages and Chat Completions remain HTTP/SSE.

**Ownership and affinity.** `Chat_Session` owns one stable allocated WS session containing
the borrowed connection, owned socket, probe storage, allocator and active flag. Open,
use, abort and destroy on the thread that acquired the I/O loop; reject concurrent use
explicitly with no queue or mutex on the connection. Before every connect/use compare:

- Socket/replay affinity: endpoint, API family, credential, identity/handshake headers,
  trust configuration, configured transport mode. Any change destroys the socket, clears
  sticky fallback and clears the retained response identity.
- Request identity: model, effort, instruction snapshot, tool inventory, checkpoint,
  capacity. A change may rebuild the projection or cancel compaction but does not itself
  require a new socket; the model travels in each request.

Compare actual values, not a secret digest written to logs. Retain an owned configuration
snapshot where borrowed catalog storage cannot guarantee lifetime; destroy the socket
before releasing the strings it borrows. Trust-file replacement requires explicit reload.

**Request lifecycle.** One operation performs at most one model send: validate and freeze,
check cancellation/affinity, record the attempt and bind control before network work
(including Upgrade), check cancellation again, mark send evidence, send one text message,
read complete text messages (chunks are not events), decode via the shared Responses
decoder, validate identity and terminal semantics, check cancellation before publishing
completion, and return after the provider terminal rather than EOF. On success clear all
operation bindings and retain only the idle connection, affinity and last completed
response identity; on any unsuccessful operation abort the socket before returning.

Retain response identity for the active operation to correlate events, not for
continuation. Reject a different ID or unexpected lane as an invalid stream; remember the
last completed ID only to reject a replayed old response, and clear it on connection
destruction. Unknown extensible event types may be ignored after routing-identity checks;
known malformed, contradictory, binary or wrong-request events fail. A transport chunk is
never evidence of creation or terminal. Decode the WS `error` envelope's nested
code/type/message and top-level status as well as the SSE shape; extend the shared parser
rather than adding a second.

**Full context.** Do not implement `previous_response_id`. Full projection every request
is the selected architecture and already includes replay normalization, tool-result
repair, spill handles, steering and the installed checkpoint. Continuation would need
exact normalized item-prefix equality, matching settings, connection affinity and
post-acceptance promotion as a separate approved change. Keep one default lane; named
multiplexing has no concurrent foreground consumer.

**Lifetime.** No connection-age setting or provider-number timer. Retain lazy
single-owner reads without an idle read thread or heartbeat. Answer a received Ping
promptly when the owner reads it, including between fragments; do not promise idle
servicing while the owner runs tools. Abort on cancellation, partial transport failure,
parser failure, rejected completion or ambiguous delivery without a close write or peer
wait. Graceful Close is a separate caller-controlled operation.

## Provider and model switches

A switch happens at any request boundary, including a tool-loop iteration or steer drain
inside a running turn, and never mutates an in-flight request, frozen bytes, control
binding, projection or attempt chain. It performs, in order: resolve and validate the new
provider/model/credential/transport (refuse at the boundary, keeping the previous usable
selection); cancel/retire the previous configuration's compaction chain; abort and destroy
the previous socket when socket affinity changed, before the strings it borrows are
replaced, clearing fallback and retained identity; publish the new connection/model.

Transport is not session identity: the switch keeps the same session, durable history,
transcript and cache key, appends no conversation entry, and changes no rendering or
completion semantics. A switch to a WS-capable affinity attempts WS again even if the
previous affinity selected HTTP, because sticky HTTP belongs to one affinity, not a
provider name. A switch never authorizes a second send; an ambiguous send in the previous
affinity stays stopped. Rebuild every request from the same committed projection with the
same instructions, tools, session id and cache key, changing only what genuinely differs
(per-model capacity, tools when the new model disables them, provider-specific replay items).

Record a selection/transport-change event with old and new mode, changed affinity facts,
reason and whether the socket was reused/recreated/abandoned, without credentials or prompt
content, available with capture disabled.

## Prompt-cache preservation

Prompt-cache reuse is a cost requirement. Keep one common request builder; transport
selection must not change cache-relevant settings, instruction bytes, ordered tools/schemas,
ordered input, replay IDs/encrypted reasoning or cache controls. Sorted JSON map keys make
encoding deterministic; they do not prove equality of the provider's rendered prefix.
Array order, whitespace, roles and item boundaries remain significant. Never sort
conversation arrays or normalize tool-argument strings to pass an equality check.

Within unchanged configuration and checkpoint, append new items without rewriting earlier
normalized input. Keep the durable instruction snapshot, stable spill handles and faithful
native replay. Tool repair, instruction/tool/model/effort changes and checkpoint installation
are legitimate prefix changes; record their reason. Do not add per-request timestamps,
connection IDs, mutable skill lists or retry annotations to the prefix.

Correct usage accounting: preserve raw per-request usage and presence; latest cumulative
value wins within an operation; sum distinct attempts. Missing cache usage is unknown, not
zero. Report a paired hit rate plus coverage (see [context](CONTEXT_COMPACTION_ARCHITECTURE.md))
and keep foreground, compaction and retry/failure views with an all-work total. Do not
equate a higher percentage with lower cost; charged cache writes and failed inference count.

Evidence for a cache investigation compares canonical common fields and ordered input items,
not whole wire-body digests (which differ by envelope), reporting the first changed section
and the unchanged prefix length. Reuse existing digest/capture/export facilities and privacy
controls; do not retain a second full prompt for telemetry.

An effort change can preserve the prefix only where a verified adapter capability supports
appending a configuration update while keeping the top-level value that established the
prefix; otherwise change the field and record an intentional prefix change. Cross-model
cache sharing is not promised. A cold cache after a model/provider change is expected
provider behavior, not a transport or harness defect.

## Implementation and acceptance rules

Use structs, explicit enums, exhaustive switches and trailing errors. Zero-initialized
state is unopened/inactive with no owned resources. Session state uses its explicit
allocator; operation/event state has operation lifetime. Callback slices are borrowed only
until return; clone what must survive; give every owned result one destroy procedure. Check
fallible allocations and size arithmetic; never retain temp-allocator buffers across
requests; do not copy a dynamic-array header and treat it as a separate owner. Use
`core:encoding/json`, `core:unicode/utf8`, `core:crypto`, `core:time`, `core:net`,
`core:nbio` and `core:os`, verifying signatures against the installed compiler.

All new test logic is Odin. Use the installed OpenSSL command as an independent TLS peer
(never a production dependency) to drive a local `wss` seam, and a package-owned Responses
peer test through public operations that records actual wire messages. Report missing peer
executables as explicit skips; CI acceptance requires the harness to run. No Python or
credential-dependent mandatory tests; live provider tests are optional and credential-redacted.

Gates: two dependent full-context operations on one connection; cancellation on every
return path; malformed event then a new request; mismatched response identity;
option/credential replacement; no replay after an uncertain send; no tool execution from
failed output; fault injection before writer entry, partial write, after send, after visible
output and after terminal, asserting actual peer-received send counts; `auto` success/reuse,
unsupported Upgrade then HTTP, ambiguous failure then HTTP only on a new request, required
modes, affinity reset, and APIs without WS; deterministic HTTP/WS request parity; and an
operator-run matched cache/cost comparison before changing the default. Run `mise run check`
and the full `mise run test` gate, with sanitizers on affected ownership/concurrency paths.
