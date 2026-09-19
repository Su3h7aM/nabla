# Network stack architecture and implementation plan

Status: architectural decisions accepted, revision 7. Reviewed against source at
`876bc824`, the complete WebSocket transport report, and the transport reference study.
Revision 7 chooses automatic WS-first selection with safe HTTP fallback, extends delivery
safety to HTTP, and specifies provider/model switches across transports. The shipped default
is still HTTP until the rollout gates in section 9.10 pass. This revision changes documentation,
not implementation. Sections 4 and 6 describe the implementation; sections 7, 9 and 10 specify
work still required. A passing test suite is not a claim of complete protocol compliance.

## 1. Scope and decisions

Nabla needs outbound HTTP/1.1, TLS 1.3, SSE, and Responses-over-WebSocket for AI APIs.
Keep the native Odin stack and correct the features we use. Do not replace it with a new
transport framework or implement unrelated protocol features.

The decisions are:

- Make `auto` the target default: prefer WS for an API with an implemented WS adapter,
  otherwise use HTTP/SSE. Explicit `http` and required `websocket` remain overrides.
  Change the shipped default only after section 9.10's correctness and cache-cost gates.
  Selection uses API capability and observed outcomes, never a provider/model-name list.
- Keep one foreground Responses connection per live chat session, one request at a time,
  driven on its creating thread. Reuse it for full-context requests. Local committed history
  remains authoritative. Switching provider or model uses the new selection's transport, and
  the switch is invisible to the conversation, the user and the model.
- Do not implement incremental continuation, named lanes, connection-age timers, prewarming,
  a socket pool, compression, or background compaction over WebSocket in this phase.
- Fix request retirement, event identity, setup evidence, and cancellation before extending
  reuse. Apply conservative delivery accounting to both WS and HTTP. A transport switch is
  another model send, not recovery of the old stream. Do not implement byte-accurate WebSocket
  write progress merely to recover a few more failed sends.
- Remove arbitrary parsing and message-size refusal caps from the supported client paths.
  Keep actual wire bounds, cryptographic bounds, and checked machine representability.
  Application retention and retry policy must not change protocol parsing.
- Complete TLS key/record safeguards, legal handshake fragmentation, HTTP syntax/outcome
  corrections, SSE decoding, and DNS fallback. These are correctness work for the existing
  feature set, not optional additions for protocol completeness.
- Preserve provider prompt-cache reuse as a cost requirement, not optional tuning. Fix the
  incomplete-usage hit-rate calculation and require transport parity and measured cache
  acceptance under section 10 before expanding WebSocket rollout.
- Commit deterministic provider and `wss` integration coverage. A discarded development
  script is not a regression gate.

This design uses Odin's explicit state, ownership, and error values.

## 2. Package responsibilities

| Package | Owns | Must not own |
|---|---|---|
| `http` | HTTP syntax, fields, URL/request-target handling, framing rules, HTTP dates | Provider acceptance, retries, logging policy |
| `http/client` | DNS, TCP, trust-store loading, HTTP exchange, cancellation, Upgrade handoff | API status/media-type decisions or fallback to another provider transport |
| `tls` | TLS messages, authentication, records, alerts, keys; a supplied byte transport and trust anchors | Filesystem trust policy, providers, request lifetimes |
| `websocket` | RFC 6455 handshake, framing, text validation, control frames and closure | JSON, model requests, reconnect/replay policy |
| `sse` | Event-stream parsing/writing and the existing HTTP POST convenience operation | Provider events, automatic replay, browser EventSource lifecycle |
| `ai` | API request/event codecs, provider failure classification, one-send operations, concrete Responses connection state | Retry authorization, durable conversation, presentation |
| `agent` | Session lifetime, selection, fallback, attempts, committed history, retention policy | Protocol syntax or provider-name guesses in transports |
| Root | Driving thread and process lifetime | A second transport policy implementation |

Keep the HTTP server as a standalone library consumer. Shared parser changes must migrate
and test its callers, but this review is not a server conformance audit. Foundation packages
remain independent of these libraries and the harness.

Keep the blocking byte-transport callbacks and existing `core:net` / `core:nbio` integration.
Do not add a generic network package, backend registry, transport vtable above `ai`, or a
sans-I/O rewrite. A concrete session struct and ordinary procedures are sufficient.

## 3. Protocol baseline and limit policy

Protocol sources for this design:

- [RFC 9846](https://www.rfc-editor.org/rfc/rfc9846.html), the current TLS 1.3 specification,
  supersedes RFC 8446. Use sections 4.1.2 and 4.1.4 for ClientHello/retry, 4.7.3 for KeyUpdate,
  5.1 through 5.5 for records and key usage, and 6 for alerts. Do not mechanically replace
  old RFC 8446 section numbers. Keep [RFC 8448](https://www.rfc-editor.org/rfc/rfc8448.html)
  as independent known-answer traces.
- [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html), especially 5, 7.8, 8.6, 9.2.2, 10.2.3,
  and 15.2.2; [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html), especially 2 through 7.
  [RFC 3986](https://www.rfc-editor.org/rfc/rfc3986.html) defines URI components.
- [RFC 6455](https://www.rfc-editor.org/rfc/rfc6455.html), especially 3, 4.1, 4.3, 5,
  7, 8, and 10.4, plus the
  [IANA WebSocket registries](https://www.iana.org/assignments/websocket/websocket.xhtml).
- [WHATWG SSE](https://html.spec.whatwg.org/multipage/server-sent-events.html#parsing-an-event-stream)
  and the [Encoding Standard's UTF-8 decoder](https://encoding.spec.whatwg.org/#utf-8-decoder).
  SSE is not an RFC. The framing algorithm does not require implementing browser EventSource.
- [RFC 1035](https://www.rfc-editor.org/rfc/rfc1035.html),
  [RFC 7766](https://www.rfc-editor.org/rfc/rfc7766.html), and
  [RFC 5452](https://www.rfc-editor.org/rfc/rfc5452.html) for DNS transport and matching.
- [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280.html),
  [RFC 9525](https://www.rfc-editor.org/rfc/rfc9525.html),
  [RFC 6066](https://www.rfc-editor.org/rfc/rfc6066.html), and
  [RFC 7301](https://www.rfc-editor.org/rfc/rfc7301.html) for certificate paths, service
  identity, SNI, and ALPN. Dependency behavior must be verified too.

HTTP does not prescribe universal field/body caps. RFC 6455 section 10.4 explicitly permits
implementation limits and recommends protection against memory exhaustion. Therefore an
implementation cap is not automatically an RFC violation. Nabla chooses the stricter project
rule requested here: no arbitrary protocol refusal cap. This is a project decision, not a
claim that the RFC forbids limits. Streaming reduces memory use but does not make finite
memory unlimited. Whole provider JSON events still require memory proportional to their size.

Distinguish four things in code and documentation:

1. Wire/security bounds are mandatory. Examples are WebSocket control payloads of at most
   125 bytes, its 63-bit frame length, TLS record/vector widths, and TLS key-usage bounds.
2. Buffer/chunk sizes are implementation choices, not maximum accepted input. HTTP fields
   and SSE lines grow; WebSocket payloads and HTTP bodies stream in chunks.
3. Allocation failure and unrepresentable values are local resource failures, not malformed
   peer input. Check growth, conversions, and allocator results. Never truncate and continue.
4. Retained log excerpts, tool-result admission, retry counts, and retry waits are harness
   policy. They may bound retention or decline another operation, not change a parsed fact
   or label a legal protocol message invalid. No harness deadline bounds model deliberation.

There is no implicit connect, idle, or whole-request timer. Reusable transport callers may
supply cancellation/deadlines; Nabla model operations supply cancellation without a time bound.
DNS retransmission intervals and test-process timeouts are not model-request deadlines.

## 4. Source audit and required corrections

The following are source observations, not newly reproduced failures. Completed earlier
corrections are in section 6. This table also records limits that are not protocol requirements.

| Source and current behavior | Specification or boundary | Decision |
|---|---|---|
| `tls/conn.odin`: `MAX_SENT_MESSAGE = 2048`, `send_message` emits one record | TLS permits larger ClientHello messages and handshake fragmentation | Remove the cap; checked dynamic encoding and record fragmentation, section 7.2 |
| `tls/conn.odin`: no outbound key-usage/epoch guard; incomplete transition validation | RFC 9846 4.7.3, 5.1, 5.5 | Implement before calling long-lived `wss` hardened |
| `tls/record.odin`: inner decoding strips padding without validating the content bound/type | RFC 9846 5.2, 5.4 | Validate content and full inner length separately from authentication |
| `tls/conn.odin`: cookie-only retry is rejected, CCS is not restricted to its legal window, alert parsing accepts extra bytes | RFC 9846 4.1.4, 5, 6 | Accept legal retry; reject invalid phases and alert lengths with the appropriate alert |
| Installed core X.509 verifier has `_MAX_CHAIN_DEPTH` and `_MAX_SIG_CHECKS` | These are dependency search budgets, not TLS certificate-list limits | Track as an unresolved dependency restriction; section 7.2 defines the required dependency change |
| `http/client/reader.odin`: growing response lines; no body cap in client streaming | HTTP has no universal line/body bound | Preserve growth and streaming; distinguish allocation/representation failures from syntax failures |
| `http/client/client.odin`: status/media-type rejection can hide a later framing failure | HTTP outcome is distinct from application acceptance | Migrate the result and all callers together, section 7.3 |
| Shared HTTP fields comma-combine every duplicate; request formatting trusts fields and framing | RFC 9110 5; RFC 9112 6 | Preserve repeated fields, validate field-specific framing and request syntax |
| HTTP chunk parsing uses signed parsing; trailers lack full validation | RFC 9112 7.1 | Parse hexadecimal grammar and trailers; do not accept sign prefixes or silently discard invalid trailers |
| `http/routing.odin` loses empty-query presence and has no fragment component; client schemes are case-sensitive | RFC 3986; RFC 9112 request-target rules | Parse components once, validate for the calling protocol, preserve raw query and percent encoding |
| `ai/responses_websocket.odin:provider_websocket_endpoint` appends to the whole URL | `/responses` is a path, not part of a query | Share component-based Responses resource resolution across HTTP and WS |
| `ai/classify.odin`: ignores Retry-After over 256 bytes | RFC 9110 10.2.3 has no such bound; many leading zeros can still mean a short delay | Remove the cap, validate all digits, preserve overflow as present rather than absent |
| `ai/request.odin`: retains only 8192 error-body bytes before JSON classification; code/message caps affect extraction | A large valid error document can carry relevant rejection evidence after that prefix | Parse full error JSON with checked growth before classification; bound only diagnostic copies in `agent` |
| `sse/sse.odin`: no line/event cap, but UTF-8 replacement is per byte | WHATWG requires the Encoding Standard decoder, which consumes malformed prefixes differently | Preserve uncapped framing, correct malformed UTF-8 replacement |
| `sse/sse.odin:parse_retry` returns on overflow before checking the remaining characters | Only an all-ASCII-digit value updates retry state | Scan the complete field even after overflow; do not accept a digit prefix followed by garbage |
| `websocket/conn.odin`: 16 KiB send/read chunks | RFC 6455 permits fragmentation; these are not message caps | Keep chunking and streaming, with no total message/fragment-count cap |
| `websocket/client.odin:protocol_offered` uses case-insensitive token matching and does not validate offer uniqueness/grammar | Subprotocol identity is exact; HTTP field names being case-insensitive does not make every value so | Validate nonempty unique offered tokens and an exact selected token; retain case-folding only where specified |
| WebSocket refuses extension offers | No extension codec is implemented | Keep refusal as a local unsupported-feature error; never negotiate unimplemented extensions |
| `http/client/resolve.odin`: 4096-byte receive buffer, no TC-to-TCP retry, only first address returned | DNS supports truncated UDP answers and TCP length-prefixed messages | Do not make the scratch size an answer cap; implement TCP retry and sequential address fallback |
| `ai/responses_websocket.odin`: any decoder failure becomes `Terminal_Observed`; some failures retain the socket | Malformed JSON is not a provider terminal, and unread messages can contaminate the next request | Separate terminal evidence from local parser failure; abort every unsuccessful operation |
| Provider control retains the prior operation's interruption pointer; affinity is reset mainly on selection replacement | A session outlives operation storage and option values can change | Clear bindings on every return; check effective affinity before every use |
| Upgrade failure loses refusal body, retry headers, and some configuration/cancellation causes | A failed Upgrade is still an HTTP response or a typed local failure | Preserve both response and exchange evidence; cancellation must never trigger fallback |
| `agent/retry.odin` treats every nonzero WS delivery state as ambiguous | A recognized explicit rejection is different from unknown execution | Preserve the stop on uncertain sends; authorize only the narrow proven-rejection cases in 9.6 |

No server-wide, certificate-corpus, or cryptographic implementation audit is claimed. Shared
server scanner/body limits are explicit server resource policy, outside the outbound provider
path; do not describe them as HTTP limits or silently copy them into the client.

## 5. Feature scope

Implement client HTTP/1.1, TLS 1.3 with currently supported authenticated suites, SSE framing,
and RFC 6455 version 13 without extensions. Offer only HTTP/1.1 ALPN for this client and
validate the selected value. Absence of ALPN remains compatible with HTTP/1.1.

Do not add TLS 1.2, PSK/resumption, 0-RTT, client-credential provisioning, post-handshake
client authentication, HTTP/2, HTTP/3, redirects, cookies, proxy CONNECT, or compression in
this phase. Reject unsupported outgoing CONNECT explicitly rather than sending an invalid
origin-form tunnel request. These are feature choices, not invented limits on features we
claim to support. Mandatory legal messages in the selected protocol remain mandatory.

Do not advertise transfer/content codings the client cannot decode. Chunked framing is
required; unsupported additional codings must remain an explicit unsupported result, not
bytes mislabeled as decoded provider JSON. Do not add a coding framework for hypothetical use.

Trust verification is always enabled. An explicit CA bundle replaces the defaults. No
plaintext fallback from TLS, insecure verification switch, or automatic redirect of credentials.
Revocation retrieval is absent; do not describe it as implemented soft-fail checking.

## 6. Implementation baseline

Already present and retained:

- Native TLS authentication with repaired verified-path/detail ownership, IP SAN validation,
  atomic certificate-list parsing, strict ServerHello/EncryptedExtensions checks, and empty
  client Certificate response to a main-handshake CertificateRequest.
- Correct traffic-update derivation and requested KeyUpdate response, terminal fatal TLS
  errors, TLS truncation distinguished from authenticated closure, and protected CCS rejection.
- HTTP nil-sink body validation and cleanup of rejected parsed DNS answers.
- WebSocket empty messages/final continuations, valid U+FFFD text, close-payload validation,
  writes-after-Close rejection, minimal frame-length encoding, handshake-field ownership,
  abnormal closure, and an abort path without close writes.
- Shared Responses request encoding and event decoding, API-driven transport capability,
  provider transport configuration, lazy session socket reuse with full context, and delivery
  evidence that prevents uncertain WS sends from being replayed.

The report records a passing check and full release/debug test run at the baseline. The
committed echo harness covers `ws`, not `wss`. TLS/OpenSSL and HTTPS harnesses cover adjacent
layers separately. No credentialed provider WebSocket exchange has been established. The
old document's claims of a `wss` echo gate and no remaining optional-client-auth coverage
were stale. Test counts are not an architectural contract.

## 7. Implementation sequence and contracts

Each item is a scoped commit or short series with colocated unit tests and package-owned
integration tests. Keep packages buildable throughout. Security and lifetime fixes take
priority; do not wait for unrelated feature work.

### 7.1 Provider operation safety

Implement section 9's retirement, affinity, cancellation, identity, and terminal-evidence
rules first, alongside section 10's cache accounting and request-parity gates. Fix URL
resolution as one shared HTTP/WS adapter change, including shared HTTP URL callers. Keep conservative send evidence; remove unreachable continuation recovery
branches from the plan rather than implementing an unused cache.

Gate: two dependent full-context operations on one connection, cancellation on every return
path, malformed event followed by a new request, mismatched response identity, option/credential
replacement, no replay after an uncertain send, and no tool execution from failed output.

### 7.2 TLS correctness for persistent connections

Extend existing key/connection structs, not a key-lifecycle service:

- Count protected records under each send key. For AES-GCM, use the integer floor of the
  RFC 9846 section 5.5 bound of `2^24.5` full-size records as a conservative accounting unit
  even for shorter records. Reserve room for KeyUpdate under the old key. For ChaCha20,
  reserve room before the sequence number would wrap. Never encrypt twice with a nonce.
- Automatically update the send key before exhausting its budget. Send KeyUpdate under the
  old key, then install the new secret/key and reset its sequence/usage counters. A partial
  encrypted write is terminal; no retransmission under either epoch.
- Track sending epoch in `u64`; never advance beyond `2^48 - 1`. Do not enforce that bound
  on received epochs. At the final sending epoch, ignore a request to advance as permitted
  by 4.7.3 and close when further sending would exceed key usage. A valid peer update still
  changes the receive key. No age timer substitutes for cryptographic accounting.
- Account for all protected record types, including automatic Pong/Close traffic through TLS.
  Centralize the guard in the record send path; make KeyUpdate emission nonrecursive.
- Check record alignment at key changes and reject handshake/other-content interleaving
  forbidden by 5.1. Validate the CCS phase window, complete inner plaintext length, content
  length/type, and exactly one two-byte alert per alert record. Keep empty application-data
  records legal; do not invent a count cap on them or session tickets.
- Allocate the ClientHello buffer from one checked encoded-length calculation.
  Remove `MAX_SENT_MESSAGE`. Range-check nested 8-, 16-, and 24-bit wire lengths before narrowing.
  Hash each complete handshake message once, then fragment its bytes into legal records.
  Key-changing handshake messages end at a record boundary.
- For cookie-only HelloRetryRequest retain the original key share; generate another only
  when a legal different group was requested. Preserve original ClientHello bytes until
  transcript replacement completes. A slice into a growing/reused message buffer is not
  an owned transcript snapshot. Enforce retry count, offered suite/group and extension rules.
- Use typed TLS failures and RFC alerts. Preserve peer-alert detail; distinguish local
  allocation/cancellation failure, malformed input, authentication failure, record overflow,
  and truncated transport. Separate receive close_notify from send closure; a fatal failure
  makes both directions unusable. Continue reading after `user_canceled` for its required
  close_notify under caller cancellation, as section 6.1 specifies. Ignore NewSessionTicket
  without retaining tickets when resumption is unsupported, as section 4.7.1 requires.
  Teardown itself must not block trying to report an alert.

Continue using core crypto/X.509 facilities. The installed verifier's fixed chain-depth and
signature-search budgets are not accepted as protocol limits in the intended architecture.
Do not remove them blindly or write a second verifier. Make an upstream core change, then
update the pinned toolchain, to expose search-resource exhaustion distinctly and allow the
caller to use no arbitrary search budget while retaining pathLenConstraint, cycle detection,
critical-extension checks, identity, EKU and signature validation. Until that dependency is
available, keep verification fail-closed and record this as an unresolved compatibility
restriction. Do not claim the no-arbitrary-limits objective complete while it remains.

Gate: RFC 8448/independent update vectors, fixture counters immediately around usage and
epoch boundaries, large and fragmented ClientHello, cookie-only retry, CCS outside its window,
misaligned KeyUpdate/Finished, malformed and legal alert/inner records, and OpenSSL-initiated
updates with data afterward in both directions. Test success/failure ownership with a tracking
allocator. No production-length sleeps or millions of records are needed.

### 7.3 HTTP outcomes, syntax, and refusal evidence

Replace `Response_Head.usable`, `Request.expected_content_type`, and status-as-failure in one
caller migration. A concrete exchange result holds head presence/status, framing completion,
and a typed local/transport error with owned detail. The response callback borrows fields;
the chunk callback receives body bytes regardless of status. A nil sink still validates the
body. A status such as 429 survives a truncated body or cancellation; those facts do not
compete for one error slot.

`ai` decides which status/media type its API accepts and chooses event versus error parsing
at the head callback. Metadata callers make their own decision. `sse.post` retains its
convenience framing/Accept behavior but does not turn a legal HTTP response into a transport
failure. Keep unsupported Upgrade as the result of an operation specifically requiring 101.
For a non-101 response, read its ordinarily framed body through the same callbacks before
closing; for 101, do not read a body or consume upgraded bytes. Transfer buffered suffix bytes
and connection ownership exactly once only after protocol validation succeeds.

Use ordered field entries preserving duplicates, with small field-specific accessors. Do not
comma-combine non-list fields. Validate field-name tokens, field-value controls, request-target
bytes, Host ownership, Content-Length and Transfer-Encoding before sending. Reject CR/LF
injection, conflicting lengths, unsupported outgoing transfer coding, and ambiguous framing.
Apply response body-length precedence before parsing fields irrelevant to a bodyless response.
Accept permitted identical decimal Content-Length values by numeric meaning, including leading
zeros; handle oversized significant values as representation failures rather than wraparound.
Parse chunk sizes as `1*HEXDIG` with checked arithmetic, validate extensions/trailers, and
never reuse a connection after incomplete or ambiguous framing.

URI parsing records scheme, authority, path, query presence, and fragment presence. Scheme
comparison is case-insensitive; path and query bytes are not normalized or decoded/re-encoded.
HTTP fragments are excluded from the request target; a WebSocket URI with a fragment is
invalid under RFC 6455 section 3. Reject userinfo for these authenticated client endpoints
as an explicit unsupported credential form. Preserve bracketed IPv6 and explicit ports.
For WS resource naming follow RFC 6455 section 3's nonempty-query rule; for HTTP origin-form
preserve an explicitly empty query. Adding `/responses` changes only the path component.

Parse complete provider error documents before classification. Growing raw JSON is sufficient
for this use case; no streaming JSON framework is required. A local resource failure must
retain the HTTP status and report incomplete evidence, never parse a truncated prefix as a
complete error. `agent` alone truncates copies for durable detail and diagnostics after the
full code/message has been classified. A full provider payload capture remains opt-in.

Remove the 256-byte Retry-After inspection cap. Scan all digits, including after numeric
overflow, without allocating a big integer. Preserve valid-but-unrepresentable delay as a
typed overflow/presence fact, and retain normal HTTP-date support. Leading zeros do not cause
overflow. `agent` may stop rather than wait beyond its retry policy, but must not retry early
because a large valid field was treated as absent. Do not impose a one-year parser ceiling.

Gate: shared HTTP/server fixtures, bodyless responses, equivalent/conflicting lengths,
transfer-coding precedence, valid/invalid chunks and trailers, huge legal fields, long leading-zero
Retry-After, large error JSON with its code beyond byte 8192, truncated 429, cancellation during
refusal-body reads, and Upgrade plus first frame in one read.

### 7.4 SSE and WebSocket framing

Keep SSE line/event accumulation with no cap. Change parser feed/finish to return a typed
resource error when growth fails and migrate `ai`/other callers with it. Use core UTF-8 decoding
for well-formed input and encoding U+FFFD. Add only the small malformed-prefix consumption
logic required to match the WHATWG decoder; core's width-one error result alone is not that
algorithm. Preserve split BOM, CR/LF/CRLF, comments, exact field names, persistent IDs, ignored
NUL IDs, and blank-line-only dispatch. EOF does not synthesize an event.

Retry fields must validate the whole value. Represent overflow separately from a usable delay;
retain the last valid value when a field is malformed. SSE retry metadata does not authorize
reposting an AI request. Reconnection remains the caller's responsibility.

Finish WebSocket offer token validation and exact selection matching. Keep mandatory header
ownership; validate outgoing text UTF-8 before starting its first frame. Peer protocol violations
and partial reads/writes poison the connection; no subsequent call resumes from an unknown frame
boundary. Reject reserved bits/opcodes without negotiated extensions. Preserve partial UTF-8
state across continuations and control frames, and preserve distinct Close, abnormal EOF,
local cancellation, and protocol failure. Check caller arguments before slicing buffers.

Gate: case-different and duplicate subprotocols, forbidden handshake fields/extensions, invalid
outgoing text with no data sent, partial frame failure followed by attempted reuse, split malformed
SSE UTF-8 prefixes, valid U+FFFD, overflow digits followed by a nondigit, empty/final continuation,
interleaved control frames, and legal payloads larger than transport scratch buffers.

### 7.5 DNS and interruption

Keep core transports and parsing where they provide the necessary facts. Validate source,
transaction ID, QR/opcode, question name/type/class, response code and answer/CNAME relation
before accepting a reply. Release rejected parse results. Ignore unrelated packets within the
same attempt, using one monotonic attempt interval, not a fresh interval per datagram.

On a matching UDP response with TC set, retry that query using DNS-over-TCP with a two-byte
length prefix, allocate by that wire length, and read the complete response. Do not require
EDNS to implement this fallback. Size UDP storage for the supported DNS transport rather than
silently accepting a truncated scratch buffer. Retain all usable A/AAAA candidates and try them
sequentially on connection failure. Stop immediately for caller cancellation or trust failure;
address fallback must not become a way to ignore failed authentication. No parallel Happy Eyeballs
or resolver cache is required now.

Fix the send-side Would_Block timeout loop and operation cancellation. Reap only the cancelled
operation; do not drain unrelated work on the thread's event loop. Keep callback storage alive
until its operation is reaped, including a dial that completes concurrently with cancellation.

Gate: local UDP/TCP peers, mismatched replies before the right reply, TC fallback, TCP split
length prefixes, several addresses with the first unreachable, and concurrent upgraded/HTTP
operation cancellation without leaked sockets or cross-operation waits.

## 8. Acceptance and Odin implementation rules

Use structs, explicit enums, exhaustive switches, and trailing error results. Zero-initialized
state is unopened/inactive with no owned resources, not a falsely successful live connection.
Use existing public `Provider_*` spellings at that boundary; use `snake_case` for new internal
procedures/fields, `Ada_Case` types, and named protocol constants with source citations.

Session state uses its explicit allocator; operation/event state has operation lifetime.
Callback slices are borrowed only until return. Clone only data that must survive, and give
every owned result one destroy procedure. Check fallible `new`, `make`, `append`, and size
arithmetic. Do not retain temp-allocator buffers across requests. Defer cleanup in the scope
that owns the data, not in an inner block that releases it before use. Do not copy a dynamic
array header and treat it as a separate owner, or retain element pointers across growth.

Use `core:encoding/json`, `core:unicode/utf8`, `core:crypto`, `core:time`, `core:net`, `core:nbio`,
and `core:os`. The inspected compiler is `dev-2026-09-nightly:a2fb372`. Verify new signatures
against the installed compiler/core; this design intentionally does not invent APIs for them.
The core UTF-8 decoder and X.509 search budgets were inspected, not assumed compliant.

Run `mise run check`, focused package tests for each step, then the full `mise run test` gate
before accepting implementation. The scripts run release/debug suites and executable harnesses.
Use `mise run test <package>` and `mise run test <harness>` during development. Run tracking
allocators and supported address/thread sanitizers on affected ownership/concurrency paths.
Test observable protocol behavior, not internal constants or struct layouts.

All new test logic is Odin. Use the installed OpenSSL command as an independent TLS peer,
not a production dependency. Extend the echo executable with an OpenSSL `s_server` child using
a local test CA/certificate; drive its application-data stdin/stdout from the Odin handshake/frame
peer. This covers TLS, HTTP Upgrade, buffered first-frame handoff, messages and closure on the
same `wss` connection without implementing a TLS server. Include hostname/CA rejection and
cancellation. Report missing peer executables as explicit skips; CI acceptance requires the
harness to run, not skip. Never introduce Python or credential-dependent mandatory tests.

Add a package-owned Responses peer test that uses public operation/session calls and records
actual wire messages. Cover two dependent requests, fallback/refusal, provider error shapes,
identity, large events, cancellation and ambiguous delivery. Reuse the existing small Odin
peer mechanics where practical; do not create a mock-provider framework. An echo alone proves
neither provider envelopes nor request isolation. Live provider tests are optional, operator-run,
and credential-redacted. Record provider/endpoint/API evidence without claiming that all compatible
gateways behave the same.

## 9. Provider WebSocket integration

This is the authoritative target design. Full-context session reuse exists; the corrections
below are required before declaring the integration complete. The harness and retry documents
link here so connection/recovery policy has one home.

### 9.1 Routing and wire request

Keep `transport = "http" | "websocket" | "auto"` in provider configuration, presence-merged
into the catalog. The accepted target is absent means `auto`; the current code still defaults
to `http`. Do not change that default until section 9.10's gates pass. Explicit `http` always
uses HTTP/SSE without an Upgrade probe; explicit `websocket` requires WS and never falls back.
`auto` tries WS first when the selected API implements it and this affinity has not fallen back.
An API without a WS adapter uses HTTP directly in `auto` and fails local validation in required
`websocket`. A Responses-compatible API name states which adapter to try, not proof that a
particular endpoint accepts Upgrade. Successful Upgrade establishes protocol availability,
not live cache neutrality.

Transport mode belongs to a provider and is read again after every selection change. Switching
to another provider uses that provider's configured mode; it never carries the previous
provider's mode, fallback state or socket. Switching mid-session in either direction is a
supported operation, specified in section 9.11.

When implementing the default, resolve an absent setting to `.Auto` explicitly after source
merging. Preserve `transport_present` and explicit `.HTTP`; do not reorder enum values to make
zero initialization silently change existing callers. Update catalog/configuration tests and
root selection together. Models.dev supplies no transport capability in the inspected study.
Do not add a discovery request, provider-name allowlist or runtime cache benchmark.

The preference is asymmetric. WS is the reusable fast path; HTTP is the compatibility path.
Once a qualifying WS transport failure selects HTTP, keep HTTP for that live affinity. There
is no periodic reprobe and no automatic HTTP-to-WS switch when an HTTP request fails. A new
session or explicit configuration reset clears the preference; merely starting another turn
or reconnecting does not. Background compaction stays HTTP regardless of this foreground policy.

Resolve the Responses path once as section 7.3 specifies, map `https` to `wss` and `http` to
`ws`, and preserve authority and query. Reuse API authentication and identity headers. No
subscription URLs, beta headers, Azure rewrites, or model-name capability guesses. Explicit
local insecure endpoints are allowed; failed TLS never downgrades to plaintext.

The common Responses encoder generates the full logical request. HTTP adds `stream:true`;
WS adds `type:"response.create"` and omits `stream`, `background`, `stream_id`, and
`previous_response_id`. Keep `store:false`. Re-encode only the envelope on an authorized
transport change; do not rebuild history, drain steering, or adopt a new checkpoint mid-retry.
Anthropic Messages and Chat Completions remain HTTP/SSE. This applies equally to OpenAI,
Anthropic, OpenCode Go, OpenRouter, or another configured gateway according to API capability.

### 9.2 Ownership and affinity

`agent.Chat_Session` owns a stable allocated `ai.Provider_WebSocket_Session` containing the
borrowed `Provider_Connection`, owned socket, stable probe storage, allocator and active-state
flag. Do not introduce a session registry or move this state into durable `agent/session`.
Open, use, abort and destroy on the thread that acquired the `nbio` loop. Reject concurrent
use explicitly; no silent queue and no mutex on the connection.

Before every connect/use compare the effective values with the session's affinity. Two groups
matter, and conflating them either reconnects needlessly or reuses a socket that no longer
belongs to the selection:

- Socket and replay affinity: endpoint, API family, credential, identity/handshake headers,
trust configuration and configured transport mode. A change to any of these destroys the
socket, clears sticky fallback and clears the retained last-response identity.
- Request identity: model, effort, instruction snapshot, tool inventory, checkpoint and
capacity. These shape the request and the conversation's cache identity, so a change may
cancel compaction and rebuild the projection, but it does not by itself require a new socket.
The model travels in each request, not in the connection handshake.

Compare actual values, not a secret digest written to logs. Retain an owned configuration
snapshot where borrowed catalog storage cannot guarantee immutability/lifetime. A socket borrows
its endpoint and credential strings from the runtime connection, so destroy the socket before
releasing or replacing those strings. A change clears sticky fallback too. Trust-file replacement
requires an explicit configuration reload/reset; do not add background filesystem watching.

Bind the active interruption/deadline only for the operation. Clear it on every exit, including
connect-only preflight success/failure, before the caller can destroy operation storage. Socket
probe storage stays allocated while the socket lives but never points at a retired operation.
No observer, callback, or encoded-body pointer survives its operation. Session destruction is
idempotent for a nil handle and aborts without protocol writes or waiting on the peer.

Background compaction permanently stays a separate one-shot HTTP operation for this phase.
It neither borrows nor evicts the foreground socket. No second persistent connection manager.

### 9.3 Request lifecycle and event identity

One operation performs at most one model send:

1. Validate and freeze the selected envelope from the retained projection. Check cancellation
   and effective affinity before using the session; local encoding failures send nothing.
2. Record the attempt and bind its control before network work, including Upgrade. Open and
   validate Upgrade if needed. A setup failure finishes this row with no model delivery.
3. Check cancellation again, mark send evidence, then send one text message.
4. Read complete WebSocket text messages. Accumulate with checked growth; fragments/chunks
   are not events. Pass each complete JSON object to the shared Responses decoder.
5. Validate request identity and terminal semantics before staging completion. Check
   cancellation before publishing completion. Return after the provider terminal, not EOF.
6. On successful accepted completion clear all operation bindings and retain only the idle
   connection, affinity and last completed response identity. On every unsuccessful operation
   abort the socket before returning.
   Storage or harness completion rejection also invalidates the socket at the owner boundary.

Retain response identity for the active operation to correlate events, not for continuation.
The shared Responses decoder must recognize creation/terminal identities and check documented
response IDs on subsequent events when present. A different ID or an unexpected named lane is
an invalid stream. Remember the last completed response ID on the live connection only to reject
an old response being replayed as the next request. Clear it on connection destruction; do not
persist it or create a generation counter. This is a real consumer of identity that the earlier
implementation did not have. Do not require a response ID on event types whose schema omits it.

Unknown extensible event types may be ignored under the shared decoder contract after checking
available routing identity. Known malformed, contradictory, binary, or wrong-request events fail
the operation. A transport chunk is never evidence of response creation or a provider terminal.
Parser failure keeps the last delivery observation; it must not manufacture `Terminal_Observed`.

Decode the documented WS `error` envelope's nested `error.code`, `error.type`, `error.message`,
and top-level status, as well as the existing SSE event shape. The current shared
`openai_parse_api_error` already extracts nested code/message, but does not retain top-level
WS status or error type as distinct evidence; extend it rather than add a second parser.
Preserve provider failure facts without synthesizing another HTTP head. `response.failed`,
`response.incomplete`, and `error`
keep their shared API meanings. Transport choice must not redefine which incomplete output the
harness can accept. Only a valid, accepted completion can release executable tool calls.

### 9.4 Full context, not incremental continuation

Do not implement `previous_response_id` in this phase. There is no pending design choice for
implementation to resolve. Full projection on every request is the selected architecture.
It already includes replay normalization, tool-result repair, spill handles, steering and the
installed checkpoint, and survives reconnection/restart without trusting remote history.

Continuation would require a measured benefit and a separate approved change. Its minimum
proof would be exact normalized item-prefix equality including replayed response output,
matching non-input settings, connection affinity, and promotion only after durable acceptance.
Raw output JSON, a hash alone, or matching item counts is insufficient. Do not build the cache,
unused response-ID persistence, or `previous_response_not_found` retry handling now.

Keep one default lane. Named-lane multiplexing exists in the documented OpenAI protocol but
Nabla has no concurrent foreground consumer. This scheduling decision is not a protocol limit.
No prewarming, provider-side mid-turn steering, or speculative future lane abstraction.

### 9.5 Delivery evidence for both transports

Use the same non-replay rule for WS and HTTP/SSE. Add explicit delivery-evidence presence to
`Provider_Operation_Error` and attempt facts. Zero/unset evidence means unknown, not not-sent.
This matters because the current HTTP adapter leaves `delivery` at `.None`; that default is not
proof that a POST never reached the provider. Successful operations still complete normally;
evidence presence controls recovery after failure.

Keep conservative accounting instead of extending TLS/WS APIs for precise accepted-byte counts:

- Present `None` means the model-send path was not entered. An HTTP Upgrade alone does not
  send model input. For HTTP POST, validation/DNS/connect/TLS failures before the request
  writer is entered can establish this fact, as can an invalid input or cancellation checked
  before write, though neither of those authorizes a retry.
- `Model_Send_Started` means delivery is possible and nothing came back. Entering the WS frame
  writer, or the HTTP model-request writer without a final response head, is enough. The HTTP
  writer currently writes headers and body in one buffer; be conservative even if it may have
  failed in the headers. Zero completed TLS plaintext bytes does not prove zero ciphertext
  reached the socket.
- `Response_Observed` means a valid request-associated provider event was decoded.
- `Terminal_Observed` means a valid associated provider terminal was decoded, not merely an
  error returned by our parser. It does not by itself mean retry is safe.

Add a separate zero-safe evidence enum for explicit pre-execution rejection, set only by a
recognized API rejection contract. Keep unknown as zero. Do not overload delivery stages with
retry permission, or infer permission from absence of output. Plain byte counts cannot prove
that a provider did not execute a request.

If accurate write accounting is later needed for diagnostics, implement it through TCP, TLS
record writes, upgraded HTTP and frame writes together. A frame-only counter cannot establish
non-delivery over TLS. This work is explicitly deferred, not a prerequisite for safe reuse.

### 9.6 Retry, setup, and fallback

Only `agent` authorizes a further send. Cancellation, storage failure, trust/configuration
failure, and visible output stop recovery. For both transports, an uncertain model send stops
with `Ambiguous_Delivery`, discards the connection, and cannot be retried by switching protocols.
A fresh independently admitted request can use another transport. It is not automatic replay
of the failed attempt. A WS transport failure can select HTTP for those future requests without
authorizing a resend of the uncertain request.

Neither SSE framing nor WebSocket defines resume for these model POST/create operations.
Do not send Last-Event-ID, synthesize continuation prompts, or reuse response IDs as idempotency
keys. RFC 9110 section 9.2.2 does not make a failed POST automatically safe to repeat. A future
provider-documented resume/idempotency contract would be a separate adapter feature.

| Evidence | Required action |
|---|---|
| Unsupported API in `auto` | HTTP directly |
| Unsupported API in required WS | Local failure before network I/O |
| Valid Upgrade refusal 404, 405, 426 or 501 in `auto`, without stronger auth/quota evidence | Permit HTTP fallback for this affinity; these statuses are an interoperability policy, not proof of a universal WS capability |
| Transient DNS/connect/setup I/O failure before a WS model send in `auto` | Select sticky HTTP; permit the next attempt only through ordinary eligibility, backoff and remaining attempt accounting. Switching does not repair a shared network outage |
| Required WS setup failure | Never fall back; apply ordinary eligible setup retry policy |
| 401/403, trust error, malformed/invalid local URL/header, invalid 101 handshake | Stop; fallback must not hide these failures |
| Upgrade 429/availability response | Preserve status, body classification and Retry-After; apply ordinary retry policy, not sticky unsupported-transport fallback |
| WS transport failure after send entry, without a valid explicit rejection | Stop this chain with unknown outcome; mark HTTP for future independently admitted requests in `auto`. Do not send the failed request again |
| HTTP request failure after the writer was entered and no final response head arrived, without a valid explicit rejection | Stop this chain with unknown outcome; do not try WS or another HTTP POST. The request may have run and nothing says it did not |
| HTTP failure after a final response head, such as a truncated or unfinished stream | Ordinary classification: a transient class retries within the bound. The provider answered, the prefix is cached, and a stream that never reached its terminal cannot release a tool call |
| HTTP failure known before writer entry | Retry HTTP with ordinary backoff when eligible; do not switch to WS |
| Absent delivery evidence | Classification decides, except that no failure may be retried once output was exposed |
| Recognized pre-execution rate-limit/unavailable rejection | Ordinary bounded retry if eligible and no output; a new WS connection, not transport fallback |
| Recognized input-overflow rejection | Existing one-checkpoint repair within the same attempt bound |
| Exact documented `websocket_connection_limit_reached` rejection for the sole pending request, before any response/output | Allow one reconnect/full-context resend within the same bound; abort old socket |
| Unknown error, malformed error, response failure without non-execution evidence | Stop; neither status 5xx nor `Terminal_Observed` proves safe replay |
| Successful completion followed by an observed clean idle Close | Keep committed result; open WS for the next request unless the affinity already uses HTTP |
| Successful completion followed by an observed abnormal idle transport failure in `auto` | Keep committed result and select HTTP for subsequent requests; no replay is needed |

The explicit-rejection exception is narrow. The adapter records evidence; the harness applies
classification and policy. A 400 mentioning age in prose, EOF, Close code, or a late event from
an older response is not the documented lifetime rejection. Do not add provider hostname checks.
`previous_response_not_found` is not a recovery case because we do not send continuation IDs.

Move `auto` preflight into the same bounded attempt execution instead of leaving it outside
recovery. Each transport attempt, including failed setup, consumes one attempt slot; each actual
model send has its own request row begun before sending. A setup-only row records no model send,
not a fabricated response or billable operation. A fallback attempt over the other transport is
authorized only when evidence says that no model message was sent for the failed attempt. It
reuses the same frozen projection with the other envelope. Completed setup, an ambiguous send,
or any model-send evidence authorizes no second attempt of that request; transport selection
still changes for future independently admitted requests. Keep the existing maximum-attempt
policy and no additional hidden loop. A failed setup cannot multiply model sends or bypass
Retry-After.

Sticky HTTP selection is a transport decision, separate from permission to replay. Set it on
an eligible unsupported-Upgrade/setup transport failure or an abnormal WS transport break, even
when delivery ambiguity prevents recovery of that particular request. Do not set it for user
cancellation, local/storage failure, malformed provider output, authentication, rate limiting,
quota, ordinary provider rejection, or the documented connection-lifetime rejection. Those
are not evidence that HTTP will work better. A clean close observed between requests requires
only a new connection. With lazy reads, a queued idle Close may be discovered after a new send;
in that case delivery remains ambiguous and the failed chain stops.

Keep this as the existing per-affinity fallback state plus a typed reason, not transport health
scores, a circuit-breaker service, failure-count thresholds or wall-clock expiry. It lasts only
for the live affinity, resets on explicit session/configuration replacement, and is not persisted
as a provider blacklist. If HTTP also fails, follow its eligible same-transport retry policy;
never bounce back to WS in this affinity. Required modes never switch in either direction.
Record setup outcome, selection changes and fallback reason without credentials. Selection,
delivery, rejection evidence and retry decisions must be available with diagnostics disabled.

### 9.7 Lifetime, control frames, and teardown

Do not add a connection-age setting or a 55/60-minute timer now. The official OpenAI endpoint
currently documents 60 minutes, but RFC 6455 does not. Generic gateways need not share it.
Handle explicit rejection as above, and otherwise handle close/error evidence. Never abort an
active response merely because a local connection-age estimate crossed a provider's number.

Retain lazy, single-owner reads without an idle read thread or heartbeat timer. RFC 6455
requires Pong on received Ping and recommends doing so as soon as practical; answer immediately
when the owner reads one, including between fragments. This design does not promise prompt
idle servicing while the owner is running tools or waiting for a user. A peer may close an idle
connection. That is a deliberate tradeoff against a second I/O scheduler, not a protocol timeout
or a claim that idle liveness is guaranteed. Do not describe it as an idle-Ping compliance test.
If prompt idle servicing becomes a demonstrated endpoint requirement, revisit scheduling as a
separate change rather than quietly adding a concurrent reader to this connection.

Do not add a liveness probe to justify retries. Even a successful Pong cannot prove the next
send will arrive. A stale socket discovered only after write entry remains ambiguous. This is
less transparent than replaying automatically, but does not risk duplicate provider execution.

Abort on cancellation, partial transport failure, parser failure, rejected completion, or
ambiguous delivery. `abort` performs no WS/TLS close write and waits on no peer. Graceful Close
is a separate caller-controlled operation with interruption; acknowledge valid peer Close while
actively reading. Protocol-error notification is best effort under the active cancellation
probe, never a blocking destructor requirement. No unread failed response survives into reuse.

### 9.8 Observations and regression gates

Keep full logical request preparation separate from actual encoded envelope capture. Record
selected transport, setup-only versus model-send attempt, delivery, explicit rejection evidence,
terminal result and fallback reason through existing observation/persistence paths. Do not
invent a fresh HTTP response head for each request on an established socket.

Add a message-complete fact to WS response-body observations, including an empty final chunk.
Record cumulative message-end byte offsets in the existing capture metadata alongside raw bytes.
A bounded capture must mark a missing/truncated boundary index as incomplete; that bound never
limits protocol parsing. Concatenated JSON without boundaries is not an exact event capture.
Ordinary logs exclude credentials, authorization headers, and response content.

The committed provider peer must demonstrate reuse and isolation across two dependent requests;
proper nested errors; sticky fallback/reset and required refusal; cancellation during dial/send/read
and at terminal delivery; no replay after partial write/EOF; failure invalidation; a valid explicit
rejection retry; and request rows/observations with diagnostics disabled. Pair this with the `wss`
seam in section 8. Tests need not assert every enum/table entry to establish those behaviors.

### 9.9 Reference harnesses and the transport preference

Source snapshot from the local `websocket-sse-study.md`, sections 2 through 6. It records
implementation choices, not latency, cache or packet-loss measurements.

| Harness | Text-inference selection | Recovery |
|---|---|---|
| Goose | HTTP/SSE; WS only for Live voice | Not evidence for inference fallback |
| MiniMax-Code | HTTP/SSE for inference; WS for channels/browser control | Channel reconnection is not model replay |
| OpenCode | Omitted setting is HTTP; Responses WS needs endpoint support plus a per-session executor | Setup or proven not-sent selects sticky HTTP; ambiguous delivery is an error |
| Codex | WS when the provider enables it and session fallback has not disabled it | 426-to-HTTP and post-retry fallback, both session-sticky |
| Pi | `openai-codex-responses` defaults to `auto` and tries WS first, with cached continuation | Pre-start failures select sticky SSE; post-start failures throw |

The study's section 8 summaries ("SSE everywhere", "post-start failures are errors") contradict
its own Pi and Codex sections. Use the per-harness observations above, not those sentences.

Decision: in `auto`, try WS first for an API with an adapter, reuse it while it works, and keep
HTTP for that affinity after a qualifying transport failure (section 9.6). Do not probe again
per turn. Required modes never switch.

Why this order:

- Reuse removes repeated TCP/TLS setup, HTTP heads and Upgrade per model request. Our HTTP client
  sends `Connection: close` and does a fresh exchange per operation, so the benefit is real here.
  It is not inherent to SSE: HTTP/1.1 keep-alive or HTTP/2 would change the comparison, and neither
  transport makes inference itself faster. Our full-context mode does not get Pi/Codex-style
  continuation savings; never quote their numbers.
- Both transports are reliable ordered streams over the same TCP/TLS path, and neither resumes an
  interrupted model operation. Packet loss and latency behave the same. SSE is the broader
  compatibility path, not a more robust protocol for recovery.
- A reused socket can go stale across long idle or tool gaps, since this design has no idle read
  pump. That is the cost of reuse and the reason a qualifying failure falls back to HTTP.
- Never switch transport as a recovery attempt. Same path, and after a POST is entered it can
  duplicate paid inference. A future concrete HTTP-only intermediary fault is a new decision.

Source anchors: OpenCode `packages/core/src/session/model-transport.ts` and `model-request.ts`,
Codex `codex-rs/core/src/client.rs` and `core/tests/suite/websocket_fallback.rs`, Pi
`packages/ai/src/api/openai-codex-responses.ts`. Their thresholds, headers and retry counts are
not Nabla contracts. Do not adopt a retry rule keyed only on whether streaming visibly started:
delivery can be ambiguous before the first event.

#### Provider contract evidence

The [OpenAI WebSocket guide](https://developers.openai.com/api/docs/guides/websocket-mode)
and [WebSocket event reference](https://developers.openai.com/api/reference/resources/responses/websocket-events)
confirm `response.create`, the omitted HTTP-only fields, default/named lanes, full-context restart
without `previous_response_id`, nested error envelopes and a provider-specific connection lifetime.
They establish nothing for OpenRouter, OpenCode Go, Azure, Anthropic or an arbitrary gateway.
Optional live acceptance identifies the configured API/endpoint and shows two dependent requests
on one connection; it never replaces local tests.

### 9.10 Rollout and recovery acceptance

The target default is decided: `auto`, WS-first for supported APIs. Do not flip the current
omitted-setting behavior as an isolated config patch. Land these prerequisites first:

1. Finish section 7's protocol/lifetime corrections and committed `wss`/provider operation
   gates. In particular, validate failed-socket retirement and control-pointer lifetime.
2. Extend HTTP delivery evidence and conservative recovery with WS in one migration. Add a
   monotonic `request_write_started` fact to HTTP transfer reporting, set immediately before
   invoking the request writer. Map it into `ai` model-delivery evidence for inference POSTs,
   not Upgrade GETs. Collect it even without logging. Missing evidence remains unknown;
   plaintext accepted-byte counts alone cannot establish non-delivery through TLS.
3. Put setup and fallback under one bounded attempt runner. Unsupported Upgrade may select
   HTTP immediately within the remaining attempt count; a transient network failure observes
   ordinary backoff. Auth/quota/trust/cancellation never authorize alternate-transport sends.
4. Run fault-injection cases for both transports: before writer entry, partial write including
   TLS partial-record failure, after send before first event, after visible output, and after
   a valid terminal. Assert actual peer-received model-send counts and durable attempt rows,
   not just the chosen enum. A disconnected post-send operation must not create a second
   request on the other transport. Use local peers, not flaky public networks.
5. Cover `auto` WS success/reuse, unsupported Upgrade then HTTP, WS ambiguous failure then
   HTTP only on a new independent request, HTTP failure with no WS bounce, explicit required
   modes, affinity reset and APIs without WS. Test long tool/idle boundaries so stale-socket
   limitations remain visible. Never add a production deadline merely to make tests finish.
6. Pass section 10's accounting/parity and operator-run matched cache/cost comparison for the
   deployments on which the default change is accepted. Also measure time to first event,
   total equivalent-workload time, connection count and completion rate under controlled
   disconnects. No rollout accepts a sustained unexplained cache/cost regression in return
   for a latency improvement. Keep `transport = "http"` for affected endpoints; do not encode
   a provider-name exception table or diagnose cache quality through paid runtime probes.
7. Change omitted configuration to `auto`, with explicit overrides preserved, and publish
   the default change and unknown-delivery behavior. This documentation revision does not
   claim that migration, live cache acceptance or unstable-network testing has happened.

### 9.11 Provider and model switches across transports

Selection changes happen inside one conversation (quota, outage, user choice). Both directions
between WS-capable and HTTP-only providers must work, and the switch must be invisible outside
diagnostics.

#### Transparency contract

- Transport is not session identity. A switch never starts a new session, rewrites durable
  history, changes the transcript or rotates the session/cache identity.
- No transport detail reaches the model or the user. Nothing is appended to the conversation
  about how a request travels, and no rendering, retry wording or completion semantics depend on
  it. Observable turn behavior is identical: same streamed events, tool handling, cancellation
  and terminal results.
- The front-end shows the selected provider and model because the user chose them. Diagnostics
  and `/status` may record the selected transport and any fallback for operators. Nothing else
  discloses it.

| From | To | Required behavior |
|---|---|---|
| WS-capable provider | Provider or API without a WS adapter | Destroy the socket, then use HTTP/SSE; no WS probe, no failure, no notice |
| WS-capable provider | Required-WS provider | Destroy the socket, then require WS; refuse the selection if the new API has no adapter |
| Provider without a WS adapter | WS-capable provider in `auto` | Attempt WS at the first request of the new affinity |
| WS-capable provider | Another WS-capable provider | Destroy the socket and open the new endpoint's own connection |
| Same provider, different model | Same API and endpoint | Keep the socket; the model is a request field, not socket affinity |

#### The upgrade decision

A switch to a WS-capable provider or API attempts WS again, even if the previous provider had
selected HTTP. Sticky HTTP records one observed relationship between one endpoint, credential and
transport mode; it is not a property of a provider name, API family, model or network. A new
affinity has no such evidence, so the default preference applies. Switching back to a provider
that previously fell back does the same: one failed Upgrade is the whole cost, which is the
deliberate consequence of keeping no persisted provider blacklist.

A switch never authorizes a second send. An ambiguous model send in the previous affinity stays
stopped under section 9.6; it is not replayed against the new provider.

#### Where the switch happens

The boundary is any request boundary, including one inside a running turn: a tool-loop
iteration, a steer drain, or the gap between turns. A change made while a response streams or
while tools run installs before the next request of that same turn. The owning worker is the
only writer, so the install is serialized by construction. The pending-intent mechanism and the
boundary hook are specified in the harness document, section 9.1.

Never mutate an in-flight request, its frozen bytes, its control binding, its projection or an
attempt chain. A pending change ends the current request chain at its next decision point
(retry document, section 4) and is applied before the following request is built.

The switch performs, in this order:

1. Resolve the new provider, model, credential and transport mode, and validate them. A required
   transport the new API cannot carry, or an unusable provider, is refused at the boundary with
   a turn-visible reason; the previous configuration stays in effect.
2. Cancel and retire the compaction chain, which belongs to the previous configuration.
3. Abort and destroy the previous socket when socket affinity changed, before the credential or
   connection value it borrows is replaced. Clear fallback state, the retained last-response
   identity and active probe bindings.
4. Publish the new connection and model identity. The next request opens or reuses a socket for
   the new affinity.

Background compaction stays an independent HTTP operation across the switch; it is cancelled
because its summary belongs to the previous model's configuration, not because a transport
changed.

#### Request identity across a switch

Build every request from the same committed projection with the same instruction snapshot, tool
inventory, session id and cache key. A switch changes only what genuinely differs for the new
model or API: per-model capacity, tools when the new model disables them, and provider-specific
replay items under the existing cross-provider rule. Never reload instructions, rotate the cache
key or start a new conversation to mark it. Cache consequences, including the expected cold
cache for a new provider, are in section 10.6.

#### Diagnostics and acceptance

Record a selection or transport-change event carrying the old and new mode, the changed affinity
facts, the reason (user selection, quota, availability), and whether the socket was reused,
recreated, or abandoned. Keep credentials and prompt content out of it. The event must be
available with payload capture disabled.

Test the round trip as a first-class scenario, using local peers or scripted provider responses:
WS provider to non-WS provider and back, with a quota or availability failure as the trigger; a
model switch within one provider that keeps the socket; a change applied mid-turn between two
requests of the same tool loop; and a switch while a compaction chain is running. Assert that the
conversation id, durable history, transcript and cache key are unchanged, that no transport detail
appears in the conversation or rendered output, that no request is replayed after an ambiguous
send, that fallback state does not leak across affinities, and that no socket is leaked,
double-aborted or destroyed after the strings it borrows.

## 10. Prompt-cache preservation and the reported regression

Prompt-cache reuse is a cost requirement for every transport. Do not trade it for lower
connection latency without explicit measured justification. HTTP remains the shipped default
until the `auto` rollout gates pass, and remains the explicit override for an endpoint with a
cache/cost regression. The reported drop from roughly 98% or 99% to 80% is unresolved. The target is no avoidable
loss of reusable prefix or cached-input savings for the same workload, not a guaranteed
percentage that the provider and workload cannot promise.

### 10.1 What the investigation establishes

The source comparison from pre-integration `4bedb7ed` to `876bc824` establishes:

- Both Responses encoders call `openai_responses_request_object` and the same sorted-key
  serializer. The WS addition changes `stream:true` to `type:"response.create"`; it does not
  remove instructions, tools, input items, `store:false`, or `prompt_cache_key`.
- `agent/chat_request.odin` still derives `Prompt_Cache_Key` and `Session_Id` from the durable
  chat ID. Neither changes with request number, socket recreation, transport fallback or
  compaction. Both transport freezes preserve identity-header fields and dial uses the shared
  `provider_encoded_headers`. The session header is a gateway hint, not an RFC cache feature.
- Request projection, verbatim replay normalization and usage parsing did not change in that
  integration diff. HTTP/SSE and WS both reach `openai_responses_parse_usage` on the terminal
  event; request recording keeps the latest reported value per bucket, not the sum of snapshots.
- A local Odin probe through the public freeze operations, using instructions, a tool schema,
  native function-call replay, a tool result, effort and stable cache/session identity, produced
  identical normalized request JSON after removing only `stream` and the WS envelope `type`.
  This checks that fixture, not all possible requests or a provider's internal rendering.
- `agent/session/history.odin:cache_hit_rate` divides independently accumulated cache-read
  tokens by all reported input tokens. It can label an incomplete sample as measured. The
  root status display and `/status` both use it. A local probe reproduced 80% from a row with
  10,000 input and 9,800 cached tokens plus a row with 2,250 input and absent cache usage.
  The one fully measured row still had 98% cache reuse. The test in `history_test.odin` currently
  endorses this mixed-denominator behavior. This is a confirmed accounting defect, present
  before WebSocket, not proof that the user's provider cache actually stayed at 98%.

No matched HTTP/WS traces from the reported sessions or credentialed live measurements were
available for this review. The actual cause remains unproven. Do not claim the above example
reproduces the user's workload, and do not claim framing changes inherently lower prompt caching.

There are also real prefix/routing risks to measure:

- `app_mcp.odin:app_tools_refresh` sorts tools but refreshes definitions between turns and
  removes unavailable servers. Changed schemas, descriptions, or membership can invalidate
  the prefix even with the same names. This predates WS. Keep safety-driven refresh; do not
  advertise stale/unusable tools merely to inflate cache hits. Record actual inventory changes.
- Installed compaction replaces a prefix. Cache reuse after that replacement must be measured
  separately. Background compaction's HTTP requests and failures currently contribute to the
  same displayed session totals as foreground WS requests.
- A long-lived WS may route differently from one-shot HTTP at the provider/gateway. Reconnects,
  cache eviction/TTL, resolved model, account/region and request cadence also matter. A stable
  cache key helps where supported but neither a key nor a TCP connection guarantees placement.
- An endpoint may report different or missing usage fields on WS. Terminal-message completion
  is correct for the documented Responses API; an adapter for a gateway that reports usage
  elsewhere needs that gateway's documented contract, not an arbitrary post-terminal drain.
- Full replay preserves the local request prefix but may differ from the provider's internally
  represented generated output. Continuation and prompt caching are separate mechanisms.
  Absence of `previous_response_id` is not evidence that prompt caching is disabled.

### 10.2 Request construction contract

Keep one common request builder. Transport selection must not change cache-relevant settings,
instruction bytes, ordered tools/schemas, ordered input, replay IDs/encrypted reasoning, or
cache controls. Sorted JSON map keys make encoding deterministic; they do not prove equality
of the provider's rendered/tokenized prefix. Array order, text whitespace, roles and item
boundaries remain significant. Never sort conversation arrays or normalize tool-argument
strings just to make an equality check pass.

Within unchanged model/tool/instruction configuration and checkpoint, append new conversation
items without rewriting the earlier normalized input. Preserve the existing durable instruction
snapshot, stable spill handles and faithful native output replay. Tool repair, explicit
instruction/tool/model/effort changes and checkpoint installation are legitimate prefix changes;
record their reason rather than hiding them. Do not add per-request timestamps, connection IDs,
mutable skill lists or retry annotations to the prompt prefix. Reconnect/transport change is
not a reason to reload instructions, rewrite history, rotate the cache key or create a new chat.

Keep the durable session cache key for foreground and compaction. Do not broaden it across
accounts or unrelated sessions to chase a ratio. Keep `store:false`; prompt-cache retention
and server-side response storage are different controls. Keep provider-default implicit caching
for Responses unless the caller deliberately supplies a documented supported cache option.
Preserve any explicit options identically across HTTP/WS. Do not force explicit-only caching
with a static instruction breakpoint, which could leave the growing conversation uncached.
Do not force `24h`, add model-name heuristics, or change privacy/retention policy to improve a
benchmark. Anthropic's existing automatic `cache_control` remains in its API adapter, not HTTP.

Do not implement speculative prewarm requests or continuation as a blind fix for the reported
regression. First establish the actual sent prefix and measured cache loss. If a controlled
comparison later establishes that an endpoint needs continuation to meet cost requirements,
keep HTTP recommended there until a separately reviewed continuation implementation satisfies
section 9.4. Do not ship a knowingly costlier default on a promise to fix the cache later.

### 10.3 Correct usage and cost accounting

Preserve raw reported usage and presence per request. For OpenAI Responses, `input_tokens`
already includes cache reads and writes. For Anthropic, total input is uncached input plus
cache-read plus cache-creation input. Cache writes are not hits. Validate nonnegative values
and impossible overlapping totals according to the API; report inconsistent usage, never clamp
a bad value to 100%. Missing cache usage is unknown, not zero. Latest cumulative values win
within an operation; only separate attempts are summed.

Extend the existing session aggregate with paired sums, without inventing historical usage:

```text
paired_input = sum(input for rows with both input and cache_read present and valid)
paired_read  = sum(cache_read for those same rows)
hit_rate     = paired_read / paired_input, when paired_input > 0
coverage     = paired_input / all_valid_reported_input, when that denominator > 0
```

Keep raw per-row evidence; exclude invalid negative counts from computed token totals.
Keep the existing independent valid-bucket totals for accounting. Add total, paired, missing
and invalid row counts,
including rows that reported no tokens. Surface measurement coverage alongside the hit rate;
a paired rate with missing rows is a measured-subset rate, not the whole session's rate. Do not
silently change an 80% label to 98% while hiding the unmeasured requests. Historical rows remain
nullable and can be reaggregated; no backfill assumes that missing means a cache miss.

Provide separate views for foreground, compaction and retries/failures, with an all-work total
that includes their cost. For transport comparisons filter by recorded transport, endpoint/API,
resolved model/configuration and checkpoint period; old rows with no transport evidence stay
unknown. The root display uses these facts from `agent/session`, not its own formula. A new
WebSocket diagnostic must not erase compaction cost or reset the session-wide totals on reconnect.

Evaluate uncached, cache-read, cache-write and output costs with the applicable recorded pricing
when known. Keep price/usage gaps explicit. Do not equate a higher cache percentage with lower
cost: new useful input lowers the ratio, and charged cache writes or extra prewarm calls can
increase cost. Acceptance compares cost per equivalent completed workload as well as hit rate.

### 10.4 Evidence without another cache subsystem

Extend existing request preparation/finish metadata and the diagnostics export. Record transport,
connection reused/reopened and reason, request purpose, instruction snapshot/checkpoint identity,
cache-control presence/value, and normalized usage/presence. Keep correlation with the durable
request row. No transport-specific event store or live metrics service is needed.

For an explicit cache investigation, compare canonical common request fields and ordered input
items, not the whole wire-body digest, which differs by transport envelope. Report the first
changed section/item and the unchanged item/byte-prefix length relative to the prior logical
request. Call that a local prefix comparison, not the provider's cacheable-token count. Compare
full values in local tests; diagnostic digests are only evidence, not permission for continuation.

Reuse existing digest/capture/export facilities and privacy controls. Do not record credentials,
a credential hash, raw authorization fields, or prompt contents in ordinary logs. Detailed prefix
comparison works on opted-in captures or reconstructed durable requests with complete inputs;
mark it unavailable if evidence is missing/truncated. Retain no second full prompt solely for
telemetry. Usage collection and all recovery decisions work with capture disabled.

### 10.5 Implementation and acceptance gates

Implement the accounting correction and deterministic parity fixtures with the provider-safety
work in section 7.1. This is required work, not a future optimization:

1. In `agent/session/history.odin`, aggregate paired usage and coverage. Migrate `/status`, root
   status and exports together. Replace the test that treats absent cache usage as a miss.
   Cover partial coverage, explicit zero, missing-all, invalid per-row counts, unequal request
   sizes and repeated usage snapshots. Preserve all-work totals and reported costs.
2. In `ai` tests, freeze the same realistic request for HTTP and WS, remove only the documented
   envelope fields, and compare all remaining JSON. Cover tool schemas, cache controls,
   native response replay, encrypted reasoning, repaired calls and Unicode. Feed identical
   terminal payloads via SSE and WS JSON and assert equal usage, replay output and completion.
3. In `agent` tests, run an append-only tool chain, reconnect, fallback and session resume.
   Compare instruction/tool/settings equality and the earlier normalized input prefix at each
   boundary. Add separate expected-change cases for checkpoint installation and tool refresh.
   A deliberate context repair cannot be asserted to preserve a prefix it actually replaces.
4. Commit an opt-in Odin provider comparison harness with explicit endpoint/API/model input
   and credentials supplied by the operator, never fixtures. Run matched HTTP and WS arms
   against the same account/region/model/settings with identical fixed prompt/tool histories
   and append-only suffixes. Freeze replay inputs rather than comparing two freely diverging
   generated conversations. No real tool side effects are necessary.
5. Warm each arm with its own stable cache key; alternate arm order and repeat with fresh
   paired keys. Keys do not universally isolate physical caches, so record the endpoint's key
   semantics and treat cross-warming as a possible confounder. Report cold requests separately
   from warm steady-state requests, while retaining all costs. Match cadence and idle gaps. Compare HTTP,
   reused WS and forced WS reconnects. Test compaction as a separate workload, not a confounder
   in the primary comparison. Record actual sent fields, provider IDs and usage coverage.
6. Require deterministic parity to pass and no reproducible unexplained cache/cost loss on a
   matched provider workload before recommending `auto`/WS for that endpoint. A sustained
   drop from roughly 98% or 99% to 80% on matched warm inputs fails this gate. Do not invent a
   universal 99% floor or claim parity from one successful request. If WS remains worse with identical
   inputs, keep HTTP selected and use provider request IDs to investigate routing/rendering.

Live measurements cost money and are operator-authorized acceptance, not a mandatory CI job.
The current local test suite does not establish live cache neutrality. Required `websocket`
remains explicit and never silently downgrades; a low hit-rate sample is not a runtime retry or
fallback signal. Do not send duplicate paid requests or flap transports to optimize a dashboard.

Add to gate 3 the dynamic cases: a model change, an effort change and a transport change each
applied mid-turn between two requests of one tool loop must append only the documented items,
leave the earlier normalized prefix byte-identical, and keep the session cache key unchanged.

### 10.6 Model and effort changes

A model, provider or effort change must not rewrite the cached prefix. Keep the same session id
and `prompt_cache_key`, instruction snapshot and committed history bytes. Drop provider-specific
replay items only under the existing cross-provider rule, and omit tools only when the new model
disables them. Never insert a marker, note or status message into the conversation to record the
change; that is model-visible content the provider cannot cache with the prefix.

Effort is the case where the prefix can be preserved. OpenAI documents changing reasoning effort
mid-conversation by appending a `configuration_update` input item and leaving top-level
`reasoning.effort` at the value that established the prefix, because changing that field can
rewrite hidden system instructions. Implement that where the API adapter and configuration
establish the capability, never by model-name check:

- Set top-level `reasoning.effort` from the effort in force when the conversation's prefix is
  first established, and keep it there for that conversation.
- Each distinct effort change appends one `configuration_update` item at the boundary where it
  happened, once, never once per request.
- The item is durable append-only state, projected at its position like a dispatch or checkpoint
  entry, so every later request reproduces the same prefix.
- Where the capability is not established, change the top-level field and record an intentional
  prefix change. Do not claim preservation that did not happen.

Cross-model cache sharing is not documented for any provider consulted here, and weights differ
between models. Do not invent a mechanism, assume a shared entry, or rotate identity to imitate
one. Send the same prefix under the same key and measure. A cold cache after a model change is
expected provider behavior, not a transport or harness defect, and must not be reported as one.
Keep model and effort breakdowns visible in the section 10.3 accounting so a real regression
stays visible behind the expected cold start.

Provider references: [OpenAI prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching)
describes exact rendered-prefix matching, routing/retention, usage and model-dependent cache
controls. Do not transplant OpenAI cache parameters, thresholds, or pricing into another API's
adapter.

