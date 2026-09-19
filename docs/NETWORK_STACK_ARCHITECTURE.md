# Network stack architecture and remaining work

Status: reviewed implementation and continuation plan, revision 5 (2026-09-19).
Section 9 specifies provider WebSocket integration; it is approved design, not implemented
behavior. Sections 4 and 6 distinguish review findings from completed corrections.
This replaces the pre-implementation proposal and its subsequently appended completion
notes. The stack is implemented, but passing interoperability tests is not evidence of
complete protocol compliance. The corrections below remain implementation work.

## 1. Scope and evidence

The harness uses outbound HTTP/1.1 and SSE for model APIs and metadata discovery.
`http/client` now uses the repository's TLS 1.3 client rather than OpenSSL bindings.
`websocket` implements client framing and opens ws/wss connections through `http/client`.
The native protocol implementation is Odin; this does not mean the executable has no
foreign dependencies. OpenSSL and Python remain independent test peers, not production
TLS dependencies.

This review inspected the HTTP request/response path, resolver and cancellation adapters,
TLS codecs, authentication, record protection and connection driver, WebSocket framing
and connection handling, callers, and existing tests. Findings below distinguish source
observations from behavior covered by tests. No new reproduction tests or production
fixes were added as part of this documentation revision.

Verification during information gathering:

- Repository check passed.
- Full release and debug test suites passed, including the HTTPS, TLS/OpenSSL and ws/wss
  executable harnesses. TLS currently has 11 unit tests and WebSocket has six.
- Earlier implementation verification found no libssl/libcrypto linkage. That linkage
  check was not repeated during this review.
- Earlier live checks reached OpenAI, Anthropic and OpenRouter over TLS 1.3. These are
  historical observations, not guarantees about every configured endpoint or future chain.

Use Fish and Mise for subsequent commands, for example `mise run check` and
`mise run test agent`. Consult the task script for supported package selection.

## 2. Architecture decisions

### Keep the existing package boundaries

- `http` owns HTTP syntax and semantics, including shared field parsing. It must not
  acquire provider policy. Its existing server implementation remains in place; lack of
  a harness caller is not grounds to delete a standalone library's server API.
- `http/client` owns DNS/TCP transport, the HTTP exchange, interruption and trust-store
  loading. `tls` receives anchors rather than choosing filesystem paths.
- `tls` owns TLS framing, negotiation, authentication and traffic keys. It takes a byte
  transport, not a socket. It currently imports `core:net` for address parsing and uses
  `time.now()` for verification; the old claim that it has no clock or net import was false.
- `websocket` owns its Upgrade validation and WebSocket protocol. `http/client` owns the
  connection handoff, including bytes buffered beyond the HTTP response head.
- `sse` owns the event-stream format. `ai` owns provider response interpretation.
  `agent` owns retries, budgets, configuration and recording policy.

Retain the blocking transport callbacks and single I/O owner. Do not add a generic network
package, TLS backend interface, connection pool, or sans-I/O state-machine rewrite to fix
local bugs. Continue using `core:net`, `core:nbio`, and `core:os`, not platform syscalls.
The repository targets Linux; platform trust-store paths are data, not a reason for new
OS-specific code branches.

### Separate HTTP outcomes from application acceptance

Change the client contract in a coordinated implementation change: a valid HTTP status
is response data, not an exchange failure. Report status and fields independently from
transport/framing completion. Move the 2xx and expected-media-type acceptance decisions
into `ai` and metadata callers. Keep upgrade refusal as a distinct outcome of an operation
whose contract requires a protocol switch.

Migrate `Response_Head.usable`, `Request.expected_content_type`, `Failure.HTTP_Status`
and their callers together. Preserve error-body delivery, retry classification, cancellation
and transfer observations. Do not replace the present API with a generic policy framework.

### Keep TLS 1.3 as the current scope

Finish the implemented version before adding another. TLS 1.2 is deferred until a required
provider, configured proxy, or supported deployment actually needs it. A public echo
service requiring TLS 1.2 demonstrates a compatibility gap, not a harness requirement.
No legacy TLS, PSK, resumption, 0-RTT, client credential provisioning, OCSP/CRL retrieval,
HTTP/2, HTTP/3, redirects or cookie jar is scheduled now. Mandatory handling of legal
messages within TLS 1.3 is not an optional feature: an empty response to a handshake
CertificateRequest and requested KeyUpdate handling belong in the correction work.

### Preserve fail-closed authentication

Keep verification always enabled. An explicitly configured CA bundle replaces the default;
an absent option searches the existing Linux bundle paths. Do not add insecure verification
or fallback to plaintext. Preserve certificate-path errors sufficiently to diagnose failures
and choose alerts. Revocation checking is absent, not a implemented "soft-fail" mechanism.
Do not describe parsing a partially usable CA bundle as loading every certificate.

## 3. Protocol sources

Use normative text, including current updates, rather than comments or successful provider
connections as the conformance baseline.

- [RFC 9846](https://www.rfc-editor.org/rfc/rfc9846.html): current TLS 1.3 specification,
  obsoleting RFC 8446. Section 1.2 identifies changes, including mandatory key-usage
  updates, an epoch bound, ticket handling and alert clarifications. Existing RFC 8446
  citations remain useful for the original implementation, but section numbers must be
  checked rather than mechanically replaced.
- [RFC 8448](https://www.rfc-editor.org/rfc/rfc8448): independent TLS 1.3 traces used by
  current known-answer tests. RFC 8446 Appendix B defines structures, not test vectors.
- [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110),
  [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112): HTTP semantics and HTTP/1.1 framing.
  RFC 9111 matters if caching is introduced; no cache implementation is claimed here.
- [RFC 6455](https://www.rfc-editor.org/rfc/rfc6455): WebSocket, particularly sections
  4.1, 5.2, 5.4, 5.5, 7 and 8; consult the IANA close-code registry as well.
- [RFC 1035](https://www.rfc-editor.org/rfc/rfc1035),
  [RFC 7766](https://www.rfc-editor.org/rfc/rfc7766), and
  [RFC 5452](https://www.rfc-editor.org/rfc/rfc5452): DNS transport and response matching.
- [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280),
  [RFC 9525](https://www.rfc-editor.org/rfc/rfc9525),
  [RFC 6066](https://www.rfc-editor.org/rfc/rfc6066), and
  [RFC 7301](https://www.rfc-editor.org/rfc/rfc7301): certificate paths, service identity,
  SNI and ALPN. Core verification is a dependency to inspect, not a proof of compliance.
- [WHATWG server-sent events](https://html.spec.whatwg.org/multipage/server-sent-events.html):
  SSE is not defined by an RFC.

The previous plan overstated what RFCs imply about limits. HTTP permits implementation
resource limits and caller timeouts; it does not require waiting for a 408 or 504.
Our stricter rule is a project policy: no hidden request lifetime or arbitrary message cap
in the reusable client. Protocol limits and caller-selected limits remain valid.

## 4. Confirmed source findings

These are open corrections, not claims that every case has a failing reproduction yet.

### 4.1 TLS authentication and ownership

1. `tls/conn.odin:chain_verify` discards the successful slice returned by
   `x509.verify_chain`. The installed core explicitly returns an allocated, caller-owned
   path. Release that slice without destroying the certificates it points to.
2. `http/client/client.odin:request_send` obtains an allocated handshake failure detail,
   then passes it to `failure_from_error`, which clones it. Release the original or
   transfer ownership explicitly. Cover a failing handshake under a tracking allocator.
3. `identity_verify` checks address literals against IP SANs, but `chain_verify` then
   passes the same literal as `dns_name` to core's DNS hostname check. Separate reference
   identity validation from path validation so a valid IP SAN is not rejected by a second,
   inappropriate DNS check.
4. `certificate_chain_decode` can break on a DER parse failure after consuming the last
   entry and still report success if earlier certificates exist. Track parse failure
   explicitly and require complete outer and nested consumption. Inspect cleanup when a
   certificate parses but its entry extensions are malformed.
5. Core verification has its own path-depth and signature-search budgets. Therefore the
   previous assertion of unlimited chain verification was inaccurate. Record these as
   dependency constraints; do not remove security checks or fork X.509 casually to hide
   them. Audit critical extensions, identity, EKU, signature algorithms and ownership
   against the exact installed core before claiming broad certificate compatibility.

### 4.2 TLS key transitions and records

1. `key_schedule_update` passes Hash(empty) as HKDF label context. The traffic-update
   equation uses the empty byte string. This prevents interoperability after an update.
2. `post_handshake_handle` rejects `update_requested = 1` with the mistaken explanation
   that only this client may initiate updates. Either peer can request an update. Update
   the receive secret and answer under the old send key before the next application record;
   then change the send secret. Validate the request byte and message length.
3. Sending has no key-usage or sequence-exhaustion guard. Implement suite-appropriate
   usage accounting and automatic updates before protocol security bounds, including the
   current specification's sending epoch bound. Long-lived wss connections already exist;
   this is not made irrelevant by one HTTP request per connection.
4. `read_record` drops every outer ChangeCipherSpec regardless of payload or phase, and
   also accepts an encrypted inner ChangeCipherSpec. Validate the compatibility record's
   single `0x01` byte and permitted handshake window; reject protected CCS.
5. `record_decode_inner` does not enforce the decrypted content limit or valid content
   type. `read_record` silently skips unknown types. Separate authentication failure,
   invalid inner plaintext and record overflow so the peer receives the appropriate alert.
6. The handshake stream permits bytes to remain across key transitions without checking
   required record alignment. Verify ServerHello, Finished and KeyUpdate boundaries,
   incomplete handshake/application-data interleaving and unexpected queued messages.
7. `fail` sends an alert but leaves the connection reusable. `write` does not check the
   closed state. Model terminal failure and separate read/write closure as needed by the
   protocol; never resume after a fatal error or partially written encrypted record.
8. `tls_error` maps a bare TCP close during TLS to `.Closed`. `stream_until_closed` treats
   that as successful completion. Preserve the distinction between authenticated
   close_notify and truncated TLS, while allowing HTTP framing to establish completion
   when an exact or chunked body has already ended.

### 4.3 TLS negotiation and message validation

1. ServerHello parsing ignores legacy version and compression values, does not reject
   duplicate extensions, ignores unsolicited extensions, and does not require complete
   consumption of recognized extension bodies or the whole message. Validate structure,
   placement and offer/response correspondence. Unknown response extensions are not the
   same as unknown ClientHello offers.
2. EncryptedExtensions uses `extension_find`, conflating malformed and missing fields.
   Its ALPN path accepts the first entry without requiring a single offered, nonempty
   protocol. Neither the TLS driver nor HTTP adapter checks the negotiated result.
3. A legal handshake CertificateRequest fails because Certificate is expected immediately.
   Parse the request, incorporate it into the transcript and send an empty Certificate
   before Finished when no credentials are configured. Do not implement credential
   provisioning or advertise post-handshake authentication merely to support this case.
4. HelloRetryRequest handling requires a different group and cannot answer a cookie-only
   retry. Preserve the existing share when no new share is requested. Validate an actual
   requested change, allowed extensions, session ID and suite consistency across the retry.
5. `MAX_SENT_MESSAGE = 2048` is an invented outbound handshake cap. Legal cookies and ALPN
   lists can exceed it. Size or grow the message buffer using checked protocol lengths,
   fragment outbound handshake messages across records, and validate nested vector lengths
   before encoding. `write_section_end` currently narrows lengths without a range check.
6. Many handshake failures still return without alerts: malformed messages, invalid
   selections, rejected chains, invalid CertificateVerify and Finished. Use typed failures
   and correct alerts, distinguish local failures from peer violations, and implement
   current `user_canceled`/close_notify handling. Do not label all errors Unsupported.

### 4.4 HTTP and client

1. `stream_request` skips body consumption entirely when callback is nil, despite its
   documented discard behavior, and reports completion without validating the body.
   Consume and validate through the same framing path with a nil sink.
2. An HTTP-status or media-type refusal hides later framing, cancellation and body-read
   errors. Preserve both the response status and incomplete-exchange fact. This is part of
   the coordinated response-result change, not an error-precedence patch in `ai` alone.
3. Request formatting trusts arbitrary field names and values, caller Content-Length and
   Transfer-Encoding while always writing a raw body. Validate before sending: prevent
   CR/LF injection, conflicting framing, duplicate singleton fields and length mismatch.
   Either encode a supported transfer coding or report unsupported request framing.
4. Shared `http.header_parse` checks only part of field-name syntax and accepts prohibited
   control characters in values. Tests currently endorse vertical tab and bare CR values.
   Apply token and field-value rules consistently to requests, responses and trailers;
   distinguish permitted normalization from silently accepting invalid syntax.
5. The header map comma-combines every duplicate field, including non-list fields such as
   Set-Cookie. Separate syntax parsing from field-specific combination rules and preserve
   repeated values where combination changes meaning. Keep the change scoped to existing
   consumers rather than creating a generalized header framework.
6. Duplicate Content-Length handling compares raw strings before framing, rejecting some
   numerically equivalent lists. Audit this with bodyless-response precedence and
   Transfer-Encoding precedence. Do not accept conflicting lengths or obscure framing
   ambiguity in pursuit of permissiveness.
7. Chunk sizes use a general signed integer parser and trailers are discarded without
   syntax validation. Validate the actual chunk grammar, checked arithmetic, transfer-coding
   order and trailer syntax. Framing a transfer-coded response is not decoding its codings;
   make the delivered-body contract explicit rather than silently presenting encoded bytes
   as decoded content.
8. URL parsing has no fragment handling, treats schemes case-sensitively in callers and
   cannot preserve an explicitly empty query. Audit authority/userinfo, percent encoding and
   invalid request-target bytes. CONNECT is exposed as a method but receives origin-form
   formatting and ordinary response-body framing instead of tunnel semantics. Do not claim
   CONNECT support; implement or explicitly reject it until a required proxy use exists.

### 4.5 DNS and cancellation

1. Truncated UDP DNS answers are not retried over TCP. Add length-prefixed TCP exchange
   using the same caller probe and core transports; validate replies before accepting them.
2. `query_nameservers` skips records on transaction-ID mismatch without releasing them.
   Release every rejected parsed response and inspect core parse failure ownership.
3. Source address and transaction ID checks are not the complete DNS response-validation
   contract. Audit question, QR/opcode, class, type, response code and CNAME processing
   against core's actual parser. Ignore unrelated datagrams within the current attempt
   rather than letting the first unrelated packet consume the only attempt.
4. Resolution returns one IPv4-preferred address and connection failure does not try another.
   Preserve candidate addresses and try alternatives before reporting failure. Parallel
   Happy Eyeballs is a possible later optimization, not a prerequisite for basic fallback.
5. DNS attempt timeouts are appropriate retransmission policy, but the comment claiming
   they never end a lookup is false: exhausting servers ends it. Check bounded retry paths,
   including the send-side Would_Block loop. A retry interval is not a whole-request deadline.
6. Cancellation drains every operation on the thread's event loop, not just the operation
   being cancelled. Audit shared-loop ownership, dial-completion races and returned-socket
   cleanup. Keep callback storage alive until its own operation is reaped, without waiting
   indefinitely for an unrelated upgraded connection's work.

### 4.6 WebSocket

1. Zero-length data frames never reach the completion path, leaving message state open.
   Cover both empty messages and empty final continuations.
2. UTF-8 validation rejects a valid encoded U+FFFD because it treats RUNE_ERROR alone as
   invalid. Use the decoder's consumed width to distinguish a replacement character from
   malformed encoding, including split code points.
3. Close payloads of length one, invalid status codes and invalid UTF-8 reasons are not
   validated. Local `close` slices its 125-byte buffer before checking reason length and
   can panic. Validate local input and received control payloads before slicing or echoing.
4. A bare transport EOF is classified as an orderly WebSocket close. Preserve abnormal
   closure separately from a completed closing handshake. Prevent data writes after sending
   Close, and document that peer waits remain under caller cancellation.
5. Extended frame lengths are accepted even when non-minimal. RFC 6455 requires minimal
   length encoding. Retain streaming payload reads and avoid a message-size cap.
6. Dial appends mandatory headers even when the caller supplied the same fields; its
   comment claiming replacement is false. Protect protocol-owned singleton fields and
   permit ordinary authentication headers without duplicate handshake fields.
7. Upgrade validation does not check unsolicited extensions or subprotocol selections.
   Reject extensions the codec cannot process and selections that were not offered.
   Do not add extension implementations unless the harness needs them.

## 5. Limits and deferred work

Keep allocation starting sizes, transport chunk sizes, control-frame bounds and TLS wire
bounds distinct from refusal caps. Growing HTTP fields and streaming WebSocket payloads
are useful existing properties and must survive the fixes. Physical allocation failure
and representability limits still require explicit error handling.

The harness's metadata fetch budgets, shell timeout, MCP server/entry caps and MCP call
maximums are application policy, not HTTP/TLS conformance. Audit them separately. Remove
hidden clamps on explicit user choices; expose meaningful caller policy without adding
configuration for every internal buffer. Verify the actual configuration path first:
`MCP_DEFAULT_MAXIMUM_CALL_TIMEOUT` is a default assigned to a field, not by itself proof
of an unchangeable clamp. This work must not be bundled with the TLS correction commits.

Keep the HTTP server, but do not claim this review establishes server conformance. Shared
parser changes must test server callers; a server-specific audit is separate. Retain the
50 ms readiness slices for now. Delete stale OpenSSL explanations when touching that code,
but do not undertake an asynchronous rewrite without a measured need.

No connection pooling, trust-store caching or ALPN expansion is required for the correction
plan. Provider WebSocket integration is now designed in section 9. It adds a session-owned
connection, not a general-purpose pool, and depends on the transport corrections named there.

## 6. Implementation progress

Completed after this review:

- Balanced verified-chain and handshake-detail ownership, separated IP SAN checking from
  DNS-name verification, and made certificate-list parsing fail atomically.
- Corrected traffic-update derivation, answered requested KeyUpdate messages, made fatal
  TLS failures terminal, and treated a bare TLS transport close as truncation.
- Strictly validated ServerHello and EncryptedExtensions, including ALPN selection, and
  answered a main-handshake CertificateRequest with an empty Certificate. The OpenSSL
  harness now covers optional client authentication.
- Rejected malformed ChangeCipherSpec records and protected inner CCS messages.
- Validated discarded HTTP response bodies and released parsed DNS answers rejected for
  transaction mismatch or emptiness.
- Corrected empty WebSocket messages, valid U+FFFD text, close payload validation, writes
  after Close, and minimal frame-length encoding.
- Made the WebSocket handshake own its Upgrade, Connection, key and version fields,
  refused extensions and unoffered subprotocols, and reported an abnormal stream close
  distinctly from a close frame.
- Added a nonblocking abort path through WebSocket, upgraded HTTP and TLS, so teardown
  during cancellation does not wait on the peer.
- Routed provider transport by API capability rather than by provider or model identity,
  selected it from a configured `transport` field, and recorded delivery state so an
  ambiguous model send is not replayed.

Provider Responses over WebSocket is implemented for full-context requests: one
session-owned connection, reused across foreground requests, with sticky HTTP fallback
under `auto` and no fallback where the transport is required. Incremental continuation is
deliberately not implemented; section 9.5 states why.

The remaining bullets in section 4 still apply except where this list explicitly records a
completed correction. In particular, TLS key-usage thresholds, dynamic outbound handshake
messages, alert coverage, HTTP syntax and outcome redesign, and DNS TCP retry/address
fallback remain open.

## 7. Ordered implementation plan

Each item is a coherent change or short series, independently buildable and tested. Do not
mark a phase complete from one successful live request.

1. **Ownership and authentication:** release verified paths and error details; correct IP
   identity/path separation; make certificate parsing fail atomically. Gate: tracked
   success/failure paths and certificates with DNS/IP identities and invalid chains.
2. **TLS key lifecycle:** correct update derivation, requested updates, key-usage bounds,
   terminal state and record/key-transition validation. Gate: independent update vectors
   and an OpenSSL peer that initiates updates with both request values, followed by data
   in both directions. Exercise thresholds by setting fixture counters, not millions of records.
3. **TLS negotiation:** strict nested parsing and alerts, offered ALPN, legal cookie-only
   retries, dynamically sized/fragmented ClientHello and empty client Certificate response.
   Gate: malformed-message tables plus local optional-client-auth and retry exchanges.
4. **HTTP outcome and syntax:** migrate status/media-type policy and callers together;
   preserve truncated error responses and nil-sink validation; correct shared field,
   request-target and framing behavior. Gate: wire fixtures and AI/metadata regressions,
   including cancellation during an error response.
5. **Resolver and interruption:** reply ownership/validation, TC-to-TCP retry, sequential
   address fallback and operation-specific cancellation. Gate: local DNS/TCP peers and
   controlled cancellation races, not public resolver availability.
6. **WebSocket correction:** empty messages, Unicode, close validation/state, handshake
   fields, extension selection and minimal frame lengths. Gate: byte fixtures and ws/wss
   exchange with an independent peer. Done, including handshake-field ownership and
   abnormal-close reporting.
7. **Acceptance and documentation cleanup:** run `mise run check`, appropriate package
   tests and the full `mise run test` gate. Verify formatter stability and no production
   libssl/libcrypto linkage. Optional live provider checks use no embedded credentials.
   Update this document from actual results; retain unresolved dependency limitations.

Security or memory defects discovered while implementing a phase take priority over the
ordering, but belong in their own scoped changes. Do not combine all corrections into one
commit or use this list as a reason to add speculative abstraction.

## 8. Test policy and acceptance

Keep useful existing RFC 8448 vectors and independent local peers. Add tests only for
observable protocol behavior, memory ownership or regressions. Prefer small tables of
malformed and legal boundary cases over one test per helper. A test that merely asserts
an internal constant does not demonstrate correctness.

Coverage missing from the current passing suite includes key-update interoperability,
optional client authentication, cookie-only retry, strict extension validation, TLS
truncation through HTTP, nil-sink incomplete bodies, DNS TCP fallback, empty WebSocket
messages and valid replacement characters. Split/coalesced records must be tested at
key changes, not only at arbitrary transport read boundaries.

Use tracking allocators for success and rejection paths; temp allocation can conceal
ownership mistakes. Keep process-spawning peers in executable harnesses, and report skips
explicitly. Do not claim X.509 corpus coverage or fuzzing unless those suites were actually
run. Live endpoints complement deterministic tests; they do not replace them.

Completion means the listed defects have verified fixes, legal supported exchanges work,
malformed exchanges fail with useful errors, caller cancellation remains effective, and
ownership is balanced. It does not mean support for every TLS version, every HTTP feature,
or a completed independent cryptographic security audit.

## 9. Provider WebSocket integration

Status: implemented for full-context Responses requests over a reused connection. This
section is the authoritative WebSocket plan. It belongs here because connection ownership,
transport selection, interruption and recovery cross the same boundaries as HTTP/SSE. The
harness and retry architecture documents link here rather than duplicating connection
policy. No separate WebSocket document or new package is needed.

### 9.1 Scope and defaults

Implement Responses-over-WebSocket for text/tool workflows, using the existing native
`websocket` client. This is not OpenAI Realtime or Live voice. HTTP/SSE remains the default
and stays supported for every current API. Chat Completions and Anthropic Messages retain
HTTP/SSE; sharing a provider name with a Responses endpoint does not give them WS support.

The required result is a persistent connection reused across foreground requests, full
request replay whenever needed, safe recovery, and optional incremental continuation on a
verified baseline. Connection reuse and delta input are separate capabilities: correctness
must not depend on retaining server-side history.

Do not implement multiplexing, prewarming (`generate:false`), provider-side mid-turn
steering, compression, OAuth/subscription authentication, or a socket pool in this work.
They are not needed by the current harness. Absence of multiplexing is a client scheduling
choice, not a claim that the provider protocol prohibits concurrency.

### 9.2 Configuration and routing

Add an optional provider `transport` field with values `http`, `websocket`, and `auto` to
Lua configuration and the resolved provider catalog. Absent means `http`. Preserve the
existing presence-based merge: a configured value is authoritative, and neither Models.dev
nor `/models` supplies a transport value unless its published schema actually defines one.
There is no model-name heuristic and no hardcoded list of WebSocket-capable models.

| Policy | Behavior |
|---|---|
| `http` or absent | Existing HTTP/SSE operation; no WS probe or connection |
| `websocket` | Require WS for a supported API; return a useful failure rather than silently switching |
| `auto` | Prefer WS for a supported API; permit safe HTTP fallback under section 9.6 |

A provider-level choice applies after per-model API routing. In `auto`, a selected API
without an implemented WS protocol uses HTTP directly. In required `websocket` mode it
fails local validation before any connection. This supports mixed-API providers without
pretending that every route can use WS. Do not add a model-level transport override until
an actual deployment needs it.

Setting `websocket` or `auto` is the operator's assertion that the configured Responses
endpoint may support the protocol. Successful Upgrade and a valid exchange establish what
that connection supports; the string `openai_responses` alone does not. An arbitrary
compatible gateway may still reject an Upgrade or implement different behavior.

For Responses, resolve the resource path once, preserving authority, path and query, then
map `https` to `wss` and `http` to `ws`. Never send credentials to a different authority,
follow an Upgrade redirect automatically, or downgrade a secure URL on failure. Continue
to support explicit local `http`/`ws` deployments; verification remains mandatory for TLS.
Reuse the API family's authentication headers and the caller's identity headers. Do not
copy Codex subscription URLs, beta headers, affinity tokens or Azure query rewrites into
the generic Responses adapter. Such differences need a documented endpoint requirement
and a targeted adapter, not inference from a model ID.

### 9.3 Ownership and Odin shape

Use structs for state and ordinary procedures for operations. Extend `ai` with a concrete
provider-session value containing a lazily dialed WS connection. Keep `Provider_Connection`
as borrowed endpoint/API/credential data; it must not ambiguously become both configuration
and an owned socket.

`agent.Chat_Session` owns the foreground provider-session value. `ai` owns its connection,
JSON encoding/decoding and continuation mechanics. `agent` decides selection, fallback,
retry and when a prepared result becomes authoritative. The root worker drives the session;
neither the presentation stack nor durable `agent/session` imports `websocket`.

The existing one-shot provider operation remains available for metadata-independent and
background callers. A session-aware operation borrows the concrete state explicitly.
Use direct branching for HTTP versus Responses WS, not a provider transport vtable,
executor registry or another service package. The existing byte-transport callback boundary
below `websocket` already serves its actual substitution purpose.

Ownership requirements:

- Exactly one foreground request is active per connection. The driving thread performs
  all reads, writes, reconnects and destruction. No read pump or mutex is necessary for
  this sequential flow. A concurrent use attempt is an API misuse, not silently queued.
- The socket remains on its creating thread because `Upgraded` owns an acquisition of
  that thread's event loop. Close it on that thread before worker exit, session replacement,
  or transferring the session to a different driver.
- Background compaction keeps an independent one-shot HTTP operation initially. It neither
  borrows nor evicts the foreground socket or continuation cache. This preserves current
  concurrency without multiplexing or a second persistent session manager.
- Connection probe storage is owned by the provider session and remains valid as long as
  the socket. It must not retain a pointer to an operation's stack-local `HTTP_Control`,
  response observer, encoded request or callback after that operation returns.
- Active interruption and observer bindings are installed for an operation and cleared on
  retirement. A cancelled token is never reused implicitly by the next request.
- Whatever a session retains for later requests uses the session allocator; event and
  operation buffers use their documented allocators. Neither borrows the worker's temp
  allocator across requests. Destruction releases all retained state once.

Compare connection affinity directly: resolved URL, API, model, authentication/header
values and trust configuration. A changed credential, provider selection, model or trust
configuration closes the old connection and clears continuation and fallback state.
Do not retain a secret hash in logs as an affinity identifier. No global session map or
cross-account cache is introduced.

### 9.4 Request and event path

Keep one Responses request encoder and one Responses event decoder. Separate the common
JSON request from its transport envelope at preparation time:

- HTTP adds `stream:true` and uses the existing SSE framing.
- WS sends a text message with top-level `type:"response.create"`, the same request fields,
  and no `stream` or `background`. `previous_response_id` is added only for an admitted
  incremental continuation. Omit `stream_id` for the single default lane.
- Assemble received fragments until `websocket.read` reports a complete text message,
  then pass the JSON payload to the shared Responses decoder. Do not synthesize SSE lines
  or maintain a second decoder. Expose a transport-neutral payload-consumption name;
  leave `[DONE]` handling in the SSE-specific path.
- Maintain separate request boundaries on a connection. Provider JSON messages are not
  synonymous with transport chunks or frames. Buffers grow with checked allocation;
  there is no copied 16 MiB cap or 128-event queue from a reference harness.
- Unexpected binary messages, malformed JSON and unexpected request-scoped events produce
  protocol failures and discard the connection. Unknown extensible event types remain
  subject to the shared decoder's documented rules.

Retain the provider's own in-band error status and code as evidence, distinct from the HTTP
Upgrade status. A `101` does not mean a model request succeeded or even began, and the
transport never turns a provider failure into a completion.

A WS request completes at its valid provider terminal message, not at socket EOF. Keep
normal tool validation and the one-terminal-callback guarantee, but do not wait for a
persistent connection to close before releasing a completed response. `response.failed`,
`response.incomplete`, and `error` retain their provider semantics and cannot become success
merely because the socket is healthy. The established decoder decides which incomplete
outputs are usable; transport integration must not change that policy incidentally.

Cancellation is checked before sending, while receiving, before delivering a terminal
result and before accepting continuation state. A response completed and accepted before
a later idle socket failure stays completed. A failure before a valid terminal result
cannot expose executable tool calls. An unexpected old response on the next request is
not attributed to the new request.

### 9.5 Continuation without losing durable history

The committed local conversation remains the source of truth, and every logical request is
still built as a full provider projection: replay sanitization, tool-result repairs, spill
handles, steering, current instructions and installed checkpoints. Full-context requests
over a reused connection are what the transport ships with. Connection-local continuation
(`previous_response_id` with an input suffix) is not implemented, and the reason is the
comparison it requires rather than the field itself.

A baseline is only valid if the input the provider now represents is exactly the prefix of
the next projection. That representation includes the response's own output items, while a
later request replays those items through the encoder's input normalization, which drops
output-only fields such as `status`. A comparison therefore has to be stated in the same
normalized vocabulary as the replay encoder and verified item by item. Getting this subtly
wrong would tell the provider that it already holds input it does not, and the divergence
would surface as a wrong answer rather than as an error. Until a measured need justifies
that work, the transport sends the full projection, which is always correct.

Should it return, these constraints are already fixed:

- Retain the connection identity, the previous response ID, the exact normalized input
  sequence the response represented, and the non-input settings that established it.
- Use a suffix only when the new input has that sequence as an exact prefix and the settings
  match; compare normalized serialization, not hashes or byte offsets in a map.
- Stage the state on a valid terminal message and promote it only after the harness accepts
  and durably records the response. Cancellation, parser failure, storage failure and a
  rejected completion establish nothing.
- Keep `store:false`, discard connection-local identity on reconnect or process restart, and
  send full context. A `previous_response_not_found` rejection would invalidate the baseline
  and permit one full-context retry within the existing attempt budget.

Today a reconnect discards the state, which is the correct outcome for every one of those
cases by a shorter route.

### 9.6 Failures, retries and fallback

`ai` performs one model send per operation and returns facts. Only `agent` authorizes another
send or changes transport. Do not hide an HTTP retry inside `websocket.dial` or the provider
adapter. Extend provider-neutral attempt evidence to distinguish:

- no model-message bytes accepted;
- some/all model-message bytes accepted locally, with provider acceptance unknown;
- provider response creation observed;
- provider terminal outcome observed.

A partial write is ambiguous even if the lower API returns zero completed plaintext bytes
for its last record. Extend write accounting or conservatively report ambiguity once a send
starts. Neither absence of text nor absence of `response.created` proves non-delivery.
An Upgrade request does not itself create a model response, so failed setup can be safely
retried without replaying a model operation.

| Observation | Harness action |
|---|---|
| Unsupported API under `auto` | HTTP directly; no WS attempt |
| Unsupported API under required WS | Local failure |
| Upgrade rejected as unsupported (for example 405, 426 or 501) under `auto` | Sticky HTTP fallback for this session affinity; no model replay ambiguity |
| Transient connect/setup failure under `auto` | Allow HTTP fallback through the existing recovery budget; record the reason |
| Authentication, authorization, TLS trust, invalid URL or local protocol-configuration failure | Stop; no fallback that hides configuration or weakens security |
| Rate limit or provider availability response | Apply existing provider classification and Retry-After policy; do not treat it as proof that WS is unsupported |
| Send failure known to precede all model bytes | Retry/fallback under the existing budget; discard the socket |
| Ambiguous send or disconnect before terminal outcome | Report the unknown outcome and stop automatic replay; discard socket and continuation |
| Explicit `previous_response_not_found` rejection before output | Invalidate continuation and allow one full-context retry within the same attempt budget |
| Explicit connection-lifetime rejection before a new request starts | Reconnect, clear continuation and send full context within the existing budget |
| Failure after visible output | Stop and preserve partial output; never silently switch transport |
| Valid completed response followed by idle disconnect | Keep the accepted result; reconnect for the next request |

The ambiguous-delivery rule is deliberately stricter than the current generic retry rule
based only on exposed output. Add the delivery fact to `Chat_Attempt_Facts` and apply it
when the WS adapter provides it. Do not pretend existing HTTP accounting already proves
non-delivery. Reconsider HTTP replay separately when its outcome contract is revised.

Fallback is sticky only for the affected live provider session and affinity, not persisted
in the model catalog or across process restarts. Required `websocket` mode never falls back
to HTTP. Even in `auto`, `previous_response_not_found` is a continuation failure, not a
reason to disable WS. Unknown provider errors are not generic retry instructions.

Each model send has its own durable request row, including a retry without a continuation
ID. Setup attempts and fallback decisions are recorded as transport facts even when no
model message was sent; bound setup retries through existing recovery policy rather than
introducing an unbounded pre-send loop. Preserve the frozen full projection across a
transport change while recording the actual envelope sent for each attempt.

### 9.7 Connection lifetime and interruption

Connect lazily on the first WS request; retain the socket across tool runs and user turns.
No hardcoded connect deadline, idle read deadline or total request lifetime is added.
Existing caller-supplied cancellation and deadlines continue to work. Provider-imposed
connection limits are not generic WebSocket protocol limits.

For the documented OpenAI Responses endpoint, a 60-minute connection lifetime is a provider
fact. When known, retire an aged connection between requests before starting the next one;
never abort an active model response at a local 55-minute timer copied from another harness.
For configured endpoints without a known age limit, react to their close/error evidence.
No universal provider age is inferred from the API-family enum.

Without an idle read pump, pings are processed when the driver resumes reading and an idle
connection can be closed by its peer. That is acceptable: probe or reconnect at the next
request boundary, but a successful liveness probe cannot guarantee the following write
will arrive. A stale connection whose send has become ambiguous follows section 9.6.
Do not promise transparent recovery from every idle disconnect.

On cancellation, protocol failure or ambiguous delivery, abort and destroy the connection
on its owning thread. Do not wait indefinitely for a WS close handshake in a destructor,
and do not leave unread output for the next request. Normal close is an explicit operation
under caller control; resource destruction must also provide an abort path that does not
perform a blocking TLS close write. Clear the active probe bindings.

### 9.8 Observations, persistence and tests

Extend `Provider_Operation_Report` and transfer facts only with observable distinctions:
selected transport, setup outcome, model send progress, terminal result and fallback reason.
Delta input, connection generation and response identity would be added with continuation,
which section 9.5 defers. Request byte counts must distinguish the HTTP Upgrade from model
JSON. Do not fabricate a new HTTP response head for each message on an existing connection.

Log exact sent envelopes through the existing opt-in payload capture path and retain the
full logical projection in request preparation/persistence as already required for replay.
Keep secrets and handshake authorization fields out of ordinary logs. Response captures
must preserve JSON message boundaries rather than concatenating documents into ambiguous
bytes. Retry policy must not depend on whether diagnostic capture is enabled. No new
presentation callbacks are needed merely to report the selected transport.

Implementation gates, each a scoped change:

1. **Transport prerequisites:** done for handshake-field ownership, unsolicited
   extension/subprotocol checks, abnormal close reporting and nonblocking abort teardown.
   Partial-write evidence remains open, and so do the TLS key-usage and key-transition
   safeguards that long-lived `wss` depends on. Those belong to the TLS plan above.
2. **Shared Responses codec:** done. The request envelope is separated from common encoding
   and the payload decoder serves SSE and WS. Response identity was not retained: nothing
   consumes it while continuation is deferred.
3. **Full-context WS operations:** done. Configuration, session ownership, one in-flight
   operation, reuse across foreground requests, independent compaction, capability-driven
   selection, `auto` fallback and required-transport refusal are implemented.
4. **Recovery and evidence:** done for unsupported-Upgrade fallback, refusal under a
   required transport, delivery states and the stop on ambiguous delivery. Remaining:
   partial-write evidence, auth/TLS failures specific to a WS session, and sticky-fallback
   reset on affinity change beyond session replacement.
5. **Incremental continuation:** deferred, with the conditions recorded in section 9.5.
6. **Acceptance:** run Fish/Mise check and release/debug tests plus local harnesses. Optional
   credentialed provider tests must show two dependent requests on one connection. Do not
   claim provider compatibility from a WS echo alone.

Two seams cannot be reached by an in-package test: the wire form of a request and the
reuse of one connection across turns. The connection seam is covered by
`websocket/test/echo`, whose peer frames RFC 6455 in Odin rather than borrowing the
client's encoder, so no foreign language enters this repository. The provider seam was
verified during development with a throwaway scripted peer outside the repository, which
asserted the handshake, the `response.create` envelope, the absence of the HTTP-only
fields, one connection carrying two model requests, and the fallback decision. A test earns
its place by catching a real fault, so nothing was committed for it.

### 9.9 Reference evidence and deliberate differences

The supplied `websocket-sse-study.md` is a research snapshot, not a protocol contract.
OpenCode's endpoint/call split, Codex's session lifecycle, and Pi's prefix validation and
account separation inform this design. Their queues, timers, rollover intervals, retry
counts and subscription-specific headers are not copied into Nabla.

The current [OpenAI WebSocket guide](https://developers.openai.com/api/docs/guides/websocket-mode)
and [event reference](https://developers.openai.com/api/reference/resources/responses/websocket-events)
document `response.create`, transport-field exclusions, shared server-event payloads,
`store:false` continuation, connection limits and named-lane multiplexing. Named lanes are
optional; Nabla uses the default lane initially. The earlier reference study's sequential
connection model must not be stated as a universal OpenAI protocol restriction.

Azure documentation gathered in the study describes a sequential Responses connection.
Do not assume OpenAI's newer lane support applies to Azure, xAI or a compatible gateway.
No direct credentialed provider WS exchange has yet been performed in Nabla. Subscription
Codex endpoints and voice APIs remain separate protocols until explicitly implemented.
