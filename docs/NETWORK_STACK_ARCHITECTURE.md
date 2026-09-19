# Network stack architecture and remaining work

Status: reviewed implementation and continuation plan, revision 4 (2026-09-19).
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

No connection pooling, trust-store caching, ALPN expansion or new provider transport is
required to complete the current correction plan.

## 6. Ordered implementation plan

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
   exchange with an independent peer.
7. **Acceptance and documentation cleanup:** run `mise run check`, appropriate package
   tests and the full `mise run test` gate. Verify formatter stability and no production
   libssl/libcrypto linkage. Optional live provider checks use no embedded credentials.
   Update this document from actual results; retain unresolved dependency limitations.

Security or memory defects discovered while implementing a phase take priority over the
ordering, but belong in their own scoped changes. Do not combine all corrections into one
commit or use this list as a reason to add speculative abstraction.

## 7. Test policy and acceptance

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
