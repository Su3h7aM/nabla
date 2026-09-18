# Network stack architecture

Status: architecture and implementation plan, revision 3. Nothing in this document has
been built. Revision 1 claimed no reference project contains a TLS implementation; revision
2 re-tested that claim exhaustively across every branch and every commit of every reference
tree and added the two rules the work is held to (section 1), the limits audit (section 2),
the operating-system abstraction position (section 3), and the specification basis for each
protocol (section 8). This revision settles the TLS version question (section 8.2) with the
provider endpoints measured directly rather than assumed, and narrows stage 1 to the
minimum that works today.

The plan is based on a direct study of the reference trees in
`/home/su3h7am/Projects/refs/odin-net-stack`, of our own `http` package, and of RFC 8446,
RFC 9110, RFC 9111, RFC 9112, and RFC 6455. Every claim about `core:` is verified against
the installed toolchain; every claim about a protocol quotes or cites the normative text.

## 0. Ownership in one paragraph

The TLS protocol is separable and reusable on its own terms, so it belongs in a new
library-layer package, `tls`, beside `http` and `sse`. It knows nothing about HTTP,
sessions, models, or the harness. `http/client` keeps ownership of transport policy:
which trust roots, which minimum version, whether to verify, how to interrupt, and whether
to impose any bound at all. The harness gains no new concept and its call sites do not
change, because the byte source `http/client` already parses through is a procedure
pointer that a TLS connection satisfies exactly as a socket does. WebSocket framing is a
protocol of its own and belongs in a `websocket` package beside `sse`, the other line
protocol the harness speaks. None of these packages imports `core:sys/*`, and none
carries a constant that the protocol does not have.

## 1. Two rules

### 1.1 Never impose a limit the protocol does not have

This is the rule the previous plan failed to state, and it is the one most likely to be
violated by accident, because a limit always looks like defensive engineering at the
moment it is written.

The protocol text is explicit that a client-side connection timeout is not required.
RFC 9112 section 9.5, verbatim:

> Servers will usually have some timeout value beyond which they will no longer maintain
> an inactive connection. Proxy servers might make this a higher value since it is likely
> that the client will be making more connections through the same proxy server. The use
> of persistent connections places no requirements on the length (or existence) of this
> timeout for either the client or the server.
>
> A client or server that wishes to time out SHOULD issue a graceful close on the
> connection.

So the specification does not merely fail to mandate a request duration; it declines to
require one "for either the client or the server", and leaves the decision to the
implementation. A fixed request lifetime compiled into the client is therefore our
invention, and it is invisible to a user until it truncates a long generation.

The same reading applies to sizes. RFC 9112 section 3 sets no maximum on a request line and
recommends a capability floor rather than a ceiling:

> Various ad hoc limitations on request-line length are found in practice. It is
> RECOMMENDED that all HTTP senders and recipients support, at a minimum, request-line
> lengths of 8000 octets.

And RFC 9110 section 15.2 requires a client to tolerate an unbounded run of interim
responses, which our `reader_test.odin` already asserts with 64 of them. That test is the
model for this rule: state the floor the spec states, and refuse to invent a ceiling.

The rule, stated positively: **a package may bound something only when the protocol
bounds it, or when the caller chose the bound.** Everywhere else the zero value means
"no bound", and the caller decides. Where a bound exists purely for liveness, it belongs
in the caller's options with a zero value meaning unbounded, never in a package constant.

### 1.2 Prefer the abstraction Odin already provides

`core:os/doc.odin` states the contract:

> A cross-platform API for things like `I/O`, intended to be uniform across all operating
> systems. Features not generally available appear in the system-specific packages under
> `core:sys`.

So the rule is to reach for `core:os`, `core:net`, and `core:nbio` first, and to write
`core:sys/*` code only when no agnostic interface exists. Verified in the installed
toolchain, `core:os` already provides `make_directory` (`core/os/path.odin:77`), `open`,
`create`, `remove`, `rename`, `read_entire_file_from_path`,
`write_entire_file_from_bytes` (`core/os/file_util.odin`), `Read_Directory_Iterator`
(`core/os/dir.odin`), and `Walker` (`core/os/dir_walker.odin`). None of that is ours to
write, and a hand-rolled `mkdir` per platform would be a defect, not thoroughness.

`core:nbio` is the same story for I/O multiplexing: `dial`, `send`, `recv`, `poll`,
`accept`, `close`, and `timeout` are implemented per platform inside core, with `impl_linux.odin`,
`impl_posix.odin`, and `impl_windows.odin` behind one API. Our package calls the API and
never the platform.

## 2. Limits audit

Every bound currently present in `http/`, `sse/`, `ai/`, and `agent/`, with the protocol's
position and a verdict. This is the concrete form of rule 1.1.

| Location | Bound | Protocol position | Verdict |
|---|---|---|---|
| `http/client/reader.odin` `READER_INITIAL_BYTES` | 8192, a starting size that doubles | RFC 9112 section 3 sets no maximum and recommends a floor of 8000 | Keep. It is not a cap; the comment already says so |
| `http/client/wait.odin` `WAIT_SLICE` | 50 ms per event-loop tick | Nothing states or forbids | Keep, but document that it bounds cancellation latency only and never the request |
| `http/client/resolve.odin` `DNS_TIMEOUT` | 5 s per nameserver attempt | RFC 1035 sets no such requirement | **Keep**, which phase 1 settled after this plan first said change: withdrawing an attempt at a timeout is the retransmission step DNS's own algorithm prescribes (section 7.1), and an exhausted attempt moves to the next nameserver rather than ending the lookup |
| `http/client/resolve.odin` `DNS_MAX_RESPONSE` | 4096-byte datagram buffer | RFC 1035 section 4.2.1: 512 octets without EDNS; more requires the TC bit and TCP retry | Keep the buffer. The real gap is that TC is not handled, so a large answer set fails instead of retrying over TCP || `http/scanner.odin` | `INIT_BUF_SIZE` 1024, `DEFAULT_MAX_CONSECUTIVE_EMPTY_READS` 128 | RFC 9112 section 7.1.1 explicitly permits a server to apply length limits and timeouts | Keep. Server-side, and the server half has no caller |
| `http/date.odin` | `HTTP_DATE_CENTURY_WINDOW` 50 | RFC 9110 section 5.6.7: a recipient of an rfc850-date two-digit year "MUST interpret a timestamp that appears to be more than 50 years in the future as representing the most recent year in the past that had the same last two digits" | Keep. Spec-mandated, and it applies to the rfc850 form only |
| `http/client/client.odin` | non-2xx is classified as a `Failure` | RFC 9110 defines 1xx, 3xx, and 4xx as responses, not transport errors | **Review.** The body is still delivered and the status is reported, so the caller can act; but calling a valid status a failure is the client deciding policy. Recorded in section 12 |
| `ai/interrupt.odin` `Deadline` | zero value means no deadline | Caller policy | Correct by construction. Preserve this in `tls` |
| `agent/discovery.odin` `PROVIDER_MODELS_TIMEOUT` | 10 s per fetch | RFC 9112 section 9.5 declines to require any | **Review.** A fixed lifetime on one HTTP request |
| `agent/models_dev.odin` `MODELS_DEV_TIMEOUT` | 60 s per fetch | Same | **Review.** Same pattern |
| `agent/config_mcp.odin` `MCP_DEFAULT_MAXIMUM_CALL_TIMEOUT` | 120 s, a hard maximum that clamps a requested value | MCP defines no maximum | **Review.** A hard maximum is the pattern rule 1.1 forbids |
| `agent/config_mcp.odin` `MCP_MAX_SERVERS`, `MCP_MAX_ENTRIES` | 32 and 256 | MCP defines no maximum | **Review.** Same |
| `agent/tool_shell.odin` `TOOL_SHELL_MAX_TIMEOUT` | 120 s, a hard maximum | Ours | **Review.** Same |

Two notes on what this audit does not find, because the omission is the point. The client
does not cap header count, header size, body size, or the number of interim responses, and
`agent/tool.odin:506` records that the turn sets no deadline of its own: "The deadline
comes only from tool bounds; the turn itself sets none." Those are the places a limit would
have been easiest to add and the outcome was right.

For the new code, the rule applies forward, and the resulting prohibitions are specific:

- `tls` has **no** handshake timeout, idle timeout, connection lifetime, maximum chain
  length, maximum certificate count, maximum extension count, or maximum handshake message
  size. A caller-supplied `Deadline` reaches it through the transport's cancellation, and
  the zero value means the handshake may take as long as it takes.
- `websocket` has **no** maximum message or frame size. RFC 6455 sets none. The one bound
  it does have is the protocol's: control frames "MUST have a payload length of 125 bytes
  or less and MUST NOT be fragmented" (section 5.5).
- The only bounds in `tls` are the ones RFC 8446 states, listed in section 8.1, and each
  one is a termination condition with a named alert, not a silent truncation.

## 3. Operating system abstraction

The network stack should contain no platform-specific code. The current state is one
violation, and it is small.

`http/client/connection.odin` imports `core:sys/linux` and uses `linux.connect` and
`linux.getsockopt_base` directly. The comment explains why: "Connect is the reason this
file still needs raw syscalls: core:net has no nonblocking connect, and interruptibility
depends on one." That is no longer true. `core:nbio` provides `dial(endpoint, cb, timeout, l)`
with `dial_poly` for typed user data, implemented per platform inside core.

`http/client/connection.odin` is the only file in the network stack that names a platform:

```
http/client/client.odin     core:bytes core:fmt core:mem core:nbio core:net core:strconv core:strings
http/client/connection.odin core:c core:mem core:net core:sys/linux     <-- the only one
http/client/control.odin    core:net
http/client/reader.odin     base:intrinsics core:mem
http/client/resolve.odin    base:runtime core:mem core:net core:os core:strings core:time
http/client/wait.odin       core:nbio core:net core:time
```

So the action is exact: replace the hand-rolled non-blocking connect and the `SO_ERROR`
read with `nbio.dial`, and delete `core:c` and `core:sys/linux` from the file. That also
deletes the pointer-size padding workaround written for `odin-lang/Odin#7534`, which is
itself a symptom of doing by hand what core should do. `resolve.odin` is already clean and
is the model: `core:net` and `core:os`, no platform names.

The new packages hold to this by construction. `tls` takes procedures, not a socket, so it
never imports `core:net` or `core:nbio` at all. `websocket` takes a byte transport. Neither
needs a build-file split, and neither may add one.

Consequently: no `#+build linux`, no platform-named files, and no per-platform branch in
any package this plan creates.

## 4. What we have today

### 4.1 Layout and size

`http` and `http/client` total 6545 lines across 32 files:

```
http/server.odin 649   http/response.odin 424   http/cookie.odin 427
http/http.odin 338     http/body.odin 328       http/allocator.odin 267
http/routing.odin 262  http/scanner.odin 238    http/date.odin 190
http/responses.odin 191 http/headers.odin 153   http/status.odin 154
http/handlers.odin 121  http/mimes.odin 65      http/request.odin 65

http/client/client.odin 603       http/client/reader.odin 103
http/client/reader_test.odin 332  http/client/connection.odin 320
http/client/resolve.odin 256      http/client/control.odin 180
http/client/wait.odin 123         http/client/openssl.odin 73
http/client/tls.odin 69
```

The server half (`server.odin`, `routing.odin`, `handlers.odin`, `responses.odin`,
`mimes.odin`) has no caller outside `http/`: no other package calls `server_init`,
`router_init`, or a handler helper. Section 11 records it as a separate decision.

### 4.2 The seam that already exists

`http/client/reader.odin` defines the byte source as a procedure pointer:

```odin
Read_Proc :: #type proc(user_data: rawptr, buffer: []u8) -> (count: int, err: Error)
```

`Reader` holds one and `connection_read_source` adapts `connection_read` to it, so the
entire response path, framing, and `stream_body`, reads through that pointer and never
names a socket. This is why the TLS work is small: the HTTP layer does not change.

### 4.3 Where OpenSSL is welded in

Not in the binding, which is 73 lines, but in four call sites that branch on
`connection.ssl != nil` and each map `SSL_get_error` separately: `connection_handshake`,
`connection_write_all`, `connection_read`, and `connection_destroy`. Roughly 120 of
`connection.odin`'s 320 lines are these branches. The error mapping is careful
(`.Closed` for an orderly close, `.Truncated` for a cutoff, cancellation ahead of
readiness) and that care must survive the replacement.

`http/client/openssl.odin` also carries `TLS_server_method`, `SSL_accept`, and the
certificate-loading calls, because `ai/transport_test.odin` starts an in-process TLS server
to test HTTPS against a local peer. Section 9 addresses what replaces it.

### 4.4 The precedent we already follow

`resolve.odin` implements only the I/O core lacks, an interruptible UDP exchange, and
reuses core for everything else: `net.make_dns_packet`, `net.parse_response`,
`net.destroy_dns_records`, `net.validate_hostname`, `net.parse_hosts`,
`net.parse_resolv_conf`, and `net.dns_configuration`. The TLS package should have exactly
this shape.

## 5. What the reference projects are worth

### 5.1 The re-test

Revision 1's claim was re-tested exhaustively, not by sampling the working tree:

- Every file of every type in all seven trees was enumerated (263 files) and swept,
  case-insensitively, for `clienthello`, `serverhello`, `key_share`, `keyshare`, `hkdf`,
  `transcript`, `verify_data`, `finished_key`, `handshake_secret`, `master_secret`,
  `premaster`, `cipher_suite`, `tls_record`, `secp256`, `x25519`, `chacha20poly1305`,
  `aes_gcm`, `supported_versions`, `encryptedextensions`, `certificateverify`, and the TLS
  1.3 key-schedule label prefix `tls13 `.
- `git log --all` was run in every tree, and every path containing `tls`, `ssl`, or
  `crypt` in any commit of any branch was listed.
- `git rev-list --all` was walked and `git grep` run for the label prefix `tls13 ` across
  all reachable commits.

Result: **no reference project contains a TLS implementation, on any branch, in any
commit.** The only matches are inside vendored compiled OpenSSL static libraries, in
`laytan-odin-http/openssl/includes/windows/libssl_static.lib` and
`odin-http-ws/openssl/includes/windows/libssl_static.lib`, plus one `valkyrie-httpd/README.md`.

The specific false leads, since they are what a reader would otherwise chase:

- **`HyperSock/hypersock_http/tls.odin`**, 611 lines, contains `master_secret: [48]byte`,
  `cipher_suite: []string`, and a `verify_hostname` that looks like a real check. It is a
  facade: `tls_handshake` calls `openssl_client_context_new` and `SSL_connect`, and
  `tls.cipher_suite = openssl_get_cipher(tls.openssl_sock)`. Its own header says so:
  "Odin's core library does not include TLS/SSL support. This module provides a framework
  and interfaces for TLS operations. Actual TLS implementation requires either: 1. External
  bindings to OpenSSL/BoringSSL". Development stopped the day it was uploaded: created
  2026-02-23T07:19, last push 07:40, 21 minutes later.
- **`laytan-odin-http/client/ssl.odin`**, which exists only in history (added in
  `05b4e96`, deleted in `62f9880`), is the most promising-sounding candidate and is not an
  implementation. It is 30 lines of a plug-in interface: a `SSL` struct of procedures
  (`client_create`, `connection_create`, `connect`, `send`, `recv`) behind
  `set_ssl_implementation`. It is a good design idea and it is the same idea as section 6.1.
- **`valkyrie-httpd`** has the only substantial pure-Odin protocol body in the set, and it
  is HTTP/2 and HPACK. Its `tls.odin` wraps wolfSSL and its `s2n.odin` is a stub.

The conclusion is unchanged and now evidenced: the TLS work is greenfield, and the
references supply design ideas, not code.

### 5.2 Each project, its contribution, and its verdict

| Project | What it is | Worth taking | Verdict |
|---|---|---|---|
| `arcbjorn-odin-http` | HTTP/1.1 + HTTP/2, Sans-IO, 385 tests | `http/transport.odin`'s backend swap, and the split-point test discipline. Its README states the core team's framing: "TLS is a `Transport` backend, not a fork of the request path" | Adopt the discipline. Reject HTTP/2 and HPACK |
| `laytan-odin-http` | The 445-star community HTTP/1.1 | Its historical `client/ssl.odin` plug-in interface confirms the seam. `client/communication.odin` `parse_response` is a readable reference. Mainline files already import `core:nbio` | Reject `old_nbio/`: superseded by `core:nbio` |
| `mocompute-odin-http` | Minimal HTTP/1.1 server + WebSocket | `src/http/websocket.odin`: compact frame reader and writer, length ladder, MSB check, masking, and the accept-key computation over `core:crypto/legacy/sha1` and `core:encoding/base64` | Adopt as the WebSocket reference |
| `odin-websocket` | Client + server, active, MIT | `types.odin`: `Frame_Byte_0` and `Frame_Byte_1` as `bit_field u8`, an `Opcode` enum covering reserved values, `Data_Opcodes` and `Control_Opcodes` as `bit_set`, and a `Malformed_Header_Error` enum citing the RFC clause per variant. `parse_header` returns `(header, consumed, needs_more, error)` | Adopt the types and the partial-parse contract |
| `odin-http-ws` | Personal HTTP/1.1 + WS | Nothing | **No license.** Nothing may be copied |
| `HyperSock` | HTTP + WS, single-upload dump | Nothing technically | Read as a negative example |
| `valkyrie-httpd` | HTTP/2 + wolfSSL | Nothing for us | **No license**, out of scope |

### 5.3 Ideas to adopt

1. **The protocol logic never touches a socket** (`arcbjorn`, and `valkyrie`'s parser).
2. **Feed every message at every split point** (`arcbjorn`): replay a corpus at every
   offset and compare against the whole-message result.
3. **`bit_field` and `bit_set` for wire formats**, with a partial-parse contract
   (`odin-websocket`).
4. **A pluggable backend behind one interface**, which `laytan`'s deleted `client/ssl.odin`
   and `arcbjorn`'s `Transport` independently arrive at.

### 5.4 Ideas to reject

Vendored `nbio` copies (`laytan-odin-http/old_nbio/`, 12 files that `core:nbio`
supersedes); HTTP/2 and HPACK; foreign TLS bindings of any kind; hand-rolled hostname
verification; and facade packages that name an algorithm they do not implement.

## 6. Target architecture

### 6.1 Layers and dependency direction

```
root nabla      process wiring
agent           harness policy
ai  sse  mcp    provider and protocol clients
http            HTTP vocabulary
http/client     HTTP/1.1 client, transport policy      websocket   RFC 6455
tls             TLS 1.3 client (new)                   |
core:net  core:nbio  core:crypto  core:encoding  core:os
```

`tls` depends only on `core:crypto`, `core:encoding`, and `core:time`. It does not import
`core:net`, `core:nbio`, `core:sys/*`, `http`, or anything of ours, because its input is a
pair of procedures rather than a socket. `http/client` depends on `tls`. `websocket`
depends on `http/client`. No arrow points toward the harness.

### 6.2 Why `tls` is a package

It is separable, reusable on its own, and describable in its own vocabulary ("tls is the
TLS protocol"), which is the test in `AGENTS.md`. Folding it into `http/client` would bury
a security-critical protocol where no other program can reach it.

### 6.3 The transport contract

TLS takes ciphertext in and out through a procedure pair, exactly as `Reader` takes
plaintext:

```odin
// Transport is the ciphertext byte stream a TLS connection rides on. Both calls
// block until they have moved bytes or failed, and they report the same
// classification the plaintext path uses, so the caller's cancellation, deadline,
// and absence-of-deadline all reach the record layer unchanged.
Transport :: struct {
	read:      proc(user_data: rawptr, buffer: []u8) -> (count: int, err: Error),
	write:     proc(user_data: rawptr, buffer: []u8) -> (count: int, err: Error),
	user_data: rawptr,
}
```

This is the entire coupling between `tls` and I/O. It lets the handshake be driven from a
byte slice in tests with no socket and no event loop; it keeps waiting, cancellation, and
deadlines in `http/client` where the caller's policy already lives; and it means the
package cannot impose a timeout even accidentally, because it has no clock and no socket.

`Connection` then holds `tls: ^tls.Conn` in place of `ssl` and `ctx`, and its four OpenSSL
branches become four one-call branches. The `Error` enum in `control.odin` is unchanged;
`tls.Error` maps once, in `connection.odin`, onto the existing `.TLS_*` members.

### 6.4 Sans-IO internals, blocking exterior

The protocol is implemented as a pure state machine over bytes:

```odin
// handshake_step consumes whatever has arrived and reports the next state.
handshake_step :: proc(conn: ^Conn, input: []u8) -> (consumed: int, state: Handshake_State, err: Error)
```

and the public surface is blocking, with cancellation delegated to the transport:

```odin
handshake :: proc(conn: ^Conn, host: string, transport: Transport) -> Error
read      :: proc(conn: ^Conn, buffer: []u8) -> (count: int, err: Error)
write     :: proc(conn: ^Conn, buffer: []u8) -> (count: int, err: Error)
close     :: proc(conn: ^Conn)
```

Sans-IO inside because that is the only way to test a handshake at every split point.
Blocking outside because that is what `connection.odin` already is, and because rewriting
the client into an async machine is a change nothing in section 7 requires.

### 6.5 Why not a full transport vtable

Introducing `Transport` with `set_timeout` and `has_pending` and `using base` into
`http/client`, with plain and TLS variants, would remove the last two branches from
`connection.odin`. It would also add two procedure tables and a second home for the error
mapping, to save two `if` statements. The branches were never the problem; the duplicated
error mapping was, and moving TLS behind a package removes that duplication because
`tls.read` returns one classification rather than four OpenSSL cases. The vtable stays
available if a second TLS consumer appears, which section 12 asks about.

### 6.6 Trust roots: fact versus policy

`tls` owns the fact that a chain must terminate at a trust anchor, and offers the two
mechanical steps:

```odin
roots_load_file   :: proc(path: string, allocator := context.allocator) -> (roots: []^x509.Certificate, err: Error)
roots_load_system :: proc(allocator := context.allocator) -> (roots: []^x509.Certificate, err: Error)
```

`roots_load_file` loops `pem.decode` and `x509.parse`, both from core.
`roots_load_system` tries the Linux bundle locations in order and fails if none resolves,
never silently returning an empty store. Policy stays in `http/client`: whether
`options.ca_file` replaces or supplements, and that verification is always on. This is the
same split `resolve.odin` observes, where core parses and the caller chooses the servers.

### 6.7 WebSocket placement

The Upgrade handshake is HTTP/1.1 and belongs in `http/client`: a request form that sends
`Upgrade: websocket` and `Connection: Upgrade` with a generated `Sec-WebSocket-Key`,
acceptance of a `101` as a final response, and the ability to hand the connection back
instead of closing it. Those three additions are what RFC 9110 section 7.8 and RFC 6455
section 4.1 require of a client. The frame codec is RFC 6455 and belongs in `websocket`.
`wss` is the same codec over a non-nil `connection.tls`, which is why it follows section 7.

## 7. The packages

### 7.1 `tls` public API

Deliberately small. Note the absence of any duration: the only way to bound a handshake is
the caller's own probe or deadline, and an empty one bounds nothing.

```odin
package tls

// Stage 1 speaks TLS 1.3 only. TLS 1.2 is stage 2 and lands behind the three seams
// named in section 8.2: the version dispatch here, key_schedule.odin, and
// protect.odin. TLS 1.0 and 1.1 are never offered; RFC 8996 forbids negotiating
// them, so there is no flag for them.
TLS_1_3 :: 0x0304

Error :: enum {
	None,
	Protocol,     // a peer violation, or a refused parameter
	Unsupported,  // a suite, group, or signature the peer required
	Decode,       // a malformed record or handshake message
	Verify,       // chain, hostname, or validity
	Alert,        // a peer alert; the description is in the connection
	Closed,
	Truncated,
}

Conn :: struct { ... }

Config :: struct {
	roots:     []^x509.Certificate,
	allocator: mem.Allocator,
}

Transport :: struct { read, write: ..., user_data: rawptr }

init      :: proc(conn: ^Conn, config: Config) -> Error
handshake :: proc(conn: ^Conn, host: string, transport: Transport) -> Error
read      :: proc(conn: ^Conn, buffer: []u8) -> (count: int, err: Error)
write     :: proc(conn: ^Conn, buffer: []u8) -> (count: int, err: Error)
close     :: proc(conn: ^Conn)
destroy   :: proc(conn: ^Conn)

roots_load_file   :: proc(path: string, allocator := context.allocator) -> (roots: []^x509.Certificate, err: Error)
roots_load_system :: proc(allocator := context.allocator) -> (roots: []^x509.Certificate, err: Error)
```

Not in the API, on purpose: a cipher-suite list, a version range, a verification toggle,
an SNI override, a session cache, an ALPN list, a duration, and anything taking a
`net.TCP_Socket`, an `nbio.Event_Loop`, or a platform name.

### 7.2 `tls` module layout

```
tls/tls.odin           package doc, Conn, Config, Transport, the state machine driver
tls/record.odin        RFC 8446 5: header, fragmenting, reassembly, inner/outer type
tls/handshake.odin     RFC 8446 4: four-byte header, message reassembly, transcript hash
tls/client_hello.odin  RFC 8446 4.1.2, 4.2: the seven mandatory extensions
tls/server_hello.odin  RFC 8446 4.1.3, 4.1.4, 4.2.2: negotiation, HRR, cookie echo
tls/key_schedule.odin  RFC 8446 7.1, 7.3, 7.4, 7.5: HKDF-Expand-Label, Derive-Secret
tls/auth.odin          RFC 8446 4.3, 4.4: EncryptedExtensions, Certificate,
                       CertificateVerify, Finished, and the x509 wiring
tls/protect.odin       RFC 8446 5.2, 5.3: per-record keys, nonce, sequence numbers
tls/alert.odin         RFC 8446 6: the alert enum and its wire form
tls/roots.odin         PEM bundle loading over core:encoding/pem
```

Nine files, four small, all well under the 2000-line guideline.

### 7.3 What we reuse from core

Nothing in this table is implemented by us.

| TLS 1.3 needs | Source |
|---|---|
| AES-128/256-GCM, ChaCha20-Poly1305 record protection | `core:crypto/aead` `seal_oneshot` / `open_oneshot` |
| SHA-256, SHA-384 transcripts and HKDF | `core:crypto/sha2`, `core:crypto/hash` |
| HMAC for Finished and HKDF-Extract | `core:crypto/hmac` |
| HKDF-Extract, HKDF-Expand | `core:crypto/hkdf` |
| X25519 and P-256 key exchange | `core:crypto/ecdh` |
| ECDSA P-256, RSA PKCS#1 v1.5, RSA-PSS verification | `core:crypto/x509` `verify_signature` |
| Chain building, path length, name chaining, EKU nesting | `core:crypto/x509` `verify_chain` |
| Hostname and SAN matching per RFC 6125 | `core:crypto/x509` `verify_hostname` |
| Validity windows | `core:crypto/x509` `valid_at` |
| DER parsing | `core:crypto/x509` `parse` |
| PEM bundle decoding | `core:encoding/pem` |
| Entropy | `core:crypto.rand_bytes` |
| Constant-time comparison | `core:crypto.compare_constant_time` |
| Socket I/O and multiplexing | `core:net`, `core:nbio` |

### 7.4 What we implement

The TLS 1.3 client protocol, and nothing else:

1. **Record layer.** Five-byte header; `legacy_record_version` always 0x0303 and ignored on
   read; the outer `application_data` with the real type inside; decryption then a
   backwards scan for the inner type that must not run past the start of the cleartext; and
   reassembly across arbitrary reads.
2. **Handshake framing.** Four-byte header, reassembly of messages spanning records,
   fragmenting of outgoing messages that exceed the record limit, and the transcript hash
   over `ClientHello, [HelloRetryRequest, ClientHello], ServerHello, EncryptedExtensions,
   [CertificateRequest], Certificate, CertificateVerify, Finished`.
3. **ClientHello**, with the seven extensions RFC 8446 section 9.2 makes mandatory
   (`supported_versions`, `cookie`, `signature_algorithms`, `signature_algorithms_cert`,
   `supported_groups`, `key_share`, `server_name`), SNI for the DNS name, and ALPN
   `http/1.1`. Offered suites are `TLS_AES_128_GCM_SHA256` plus the two SHOULD suites;
   offered groups are X25519 and `secp256r1`. Section 8.2 records that the mandatory suite
   and X25519 alone are sufficient for every provider the harness uses.
4. **Middlebox compatibility mode** (Appendix D.4), because it is what the RFC recommends
   for connecting at all: a non-empty 32-byte `legacy_session_id`, and one dummy
   `change_cipher_spec` record sent immediately before the second flight. Section 4.1.2
   makes the non-empty session ID a MUST in this mode, and requires a zero-length value
   otherwise.
5. **Key schedule.** `HKDF-Expand-Label` over `hkdf.expand` with the `HkdfLabel` encoding,
   `Derive-Secret` over the transcript hash, then early, handshake, and master secrets and
   the four traffic secrets.
6. **ServerHello and HelloRetryRequest.** Detect HRR by its `Random` equalling
   `SHA-256("HelloRetryRequest")`, resend with the requested group, and copy the `cookie`
   extension verbatim. Rare in the wild, and the case that costs a connection when missed.
7. **Authentication.** `CertificateVerify` over 64 bytes of `0x20`, the context string
   `"TLS 1.3, server CertificateVerify"`, a `0x00`, and the transcript hash; the chain and
   hostname through `x509.verify_chain` with `required_eku = .Server_Auth` and
   `dns_name = host`; `Finished` through `finished_key` and a constant-time compare.
8. **Record protection.** `nonce = (64-bit big-endian sequence number, zero-padded to
   iv_length) XOR static_iv`, per direction, reset on key change; the five-byte header as AAD.
9. **Alerts and closure.** The alert enum, `close_notify` sent and required, and the
   orderly-close versus truncation distinction preserved.

## 8. Specification basis

Each protocol names the document that governs it, because "compliant" is meaningless
without it.

### 8.1 TLS 1.3: RFC 8446

The mandatory set for a client, and the resulting bounds. Every bound here is a
termination condition the RFC names, not a policy of ours.

- **Section 9.1.** `TLS_AES_128_GCM_SHA256` MUST be implemented;
  `TLS_AES_256_GCM_SHA384` and `TLS_CHACHA20_POLY1305_SHA256` SHOULD be. Signatures
  `rsa_pkcs1_sha256` (certificates), `rsa_pss_rsae_sha256` (CertificateVerify and
  certificates), and `ecdsa_secp256r1_sha256` MUST be supported. Key exchange with
  `secp256r1` MUST be supported and `X25519` SHOULD be.
- **Section 9.2.** The seven extensions above; `cookie` is the client's obligation to echo.
- **Section 5.1.** `TLSPlaintext.length` "MUST NOT exceed 2^14 bytes. An endpoint that
  receives a record that exceeds this length MUST terminate the connection with a
  `record_overflow` alert."
- **Section 5.2.** `TLSCiphertext.length` "MUST NOT exceed 2^14 + 256 bytes", with the same
  alert. Section 5.4: the full `TLSInnerPlaintext` "MUST NOT exceed 2^14 + 1 octets".
- **Section 5.3.** Sequence numbers are 64-bit and per direction, start at zero, and reset
  on key change; on wrap an implementation "MUST either rekey or terminate the connection".
- **Section 5.5.** Key-usage limits: for AES-GCM, on the order of 2^24.5 full-size records
  may be encrypted under one set of keys, and implementations "SHOULD do a key update".
  Irrelevant at our request volumes, but it is the only place the RFC sanctions a bound on
  how much may be sent.
- **Appendix C.3**, the client-relevant items: fragmented handshake messages including a
  fragmented `Certificate`; ignoring the record-layer version on unencrypted records; no
  SSL, RC4, EXPORT, or MD5 in any configuration that supports TLS 1.3; correct handling of
  unknown extensions; not scanning past the start of the cleartext; handling a
  HelloRetryRequest; preserving leading zero bytes in the shared secret and zero-padding
  public values to group size; validating the peer's ECDHE point; and a properly seeded
  random number generator.
- **Appendix D.1.** A client offering only TLS 1.3 is conformant, and "If the version
  chosen by the server is not supported by the client (or is not acceptable), the client
  MUST abort the handshake with a `protocol_version` alert."

Absent from RFC 8446 entirely: any handshake timeout, any idle timeout, any connection
lifetime, any maximum chain length. Those are ours to decline.

### 8.2 TLS version strategy and the provider evidence

The question "implement 1.1, 1.2, and 1.3" has a different answer for each, and the
difference is not effort but permission.

**1.0 and 1.1 are forbidden, not skipped.** RFC 8996 is BCP 195 and it is unambiguous.
Section 4: "TLS 1.0 MUST NOT be used. Negotiation of TLS 1.0 from any version of TLS MUST
NOT be permitted." Section 5: "TLS 1.1 MUST NOT be used. Negotiation of TLS 1.1 from any
version of TLS MUST NOT be permitted." Both add the client obligation in the same terms:
"clients MUST NOT send a ClientHello with ClientHello.client_version set to {03,02}", and
a party receiving such a Hello "MUST respond with a 'protocol_version' alert message and
close the connection." Implementing TLS 1.1 would therefore make us non-compliant with a
current Best Current Practice. This is not a scoping judgement.

**1.2 and 1.3 are the complete set, and RFC 9325 says so.** Also BCP 195, section 3.1:
"Implementations MUST support TLS 1.2 [RFC5246]" and "Implementations SHOULD support TLS
1.3 [RFC8446] and, if implemented, MUST prefer to negotiate TLS 1.3 over earlier versions
of TLS." So the full, conformant target is exactly TLS 1.2 and TLS 1.3, and nothing else.

**The two are not trivial relative to each other.** They share the record framing, the
AEAD primitives, ECDHE, the whole X.509 path, and the extension codec. Everything else is
a second implementation:

| Aspect | TLS 1.3 | TLS 1.2 |
|---|---|---|
| Key derivation | HKDF-Expand-Label over traffic secrets | `PRF` = `P_hash` over HMAC-SHA256; master secret and key block |
| Handshake confidentiality | everything after ServerHello is encrypted | only Finished is encrypted; ServerKeyExchange, Certificate, and CertificateVerify travel in the clear |
| Server key signature | CertificateVerify over the transcript with a context string | ServerKeyExchange signature over client_random + server_random + ServerECDHParams |
| Finished | HMAC over the transcript hash with `finished_key` | `PRF(master_secret, "... finished", Hash(handshake_messages))`, 12 bytes |
| Record protection | AEAD only; nonce is `iv XOR sequence` | AEAD with an explicit nonce (RFC 5288), or MAC-then-encrypt for CBC |
| ChangeCipherSpec | a dummy, sent for middlebox compatibility | a real state transition |
| Extensions | seven mandatory, plus keyshare and HRR | `ec_point_formats`, `renegotiation_info`, `session_ticket`; `signature_algorithms` was optional and defaulted to SHA-1 when absent |
| Renegotiation | removed | exists, and a client must at least not break on a request |
| Resumption | PSK tickets | session-id cache and tickets |

Call it roughly 40 percent shared and 60 percent new work: a second handshake, not a
variant of the first.

**What we actually need today.** Measured directly against the endpoints the harness uses,
not read from documentation: `api.openai.com`, `api.anthropic.com`, `openrouter.ai`,
`opencode.ai` (the Zen and Go gateway).

| Host | TLS 1.3 | TLS 1.2 | TLS 1.1 / 1.0 | ALPN result | HTTP/1.1 request |
|---|---|---|---|---|---|
| api.openai.com | yes | yes | refused | `http/1.1` | 421, verified |
| api.anthropic.com | yes | yes | refused | `http/1.1` | 404, verified |
| openrouter.ai | yes | yes | refused | `http/1.1` | 200, verified |
| opencode.ai | yes | yes | refused | `http/1.1` | 200, verified |

The 1.1 and 1.0 columns are the client refusing to offer them, since OpenSSL 3.6 is built
without them; that is the same position RFC 8996 requires, so no server behaviour needs
testing there. TLS 1.2 succeeded only when forced with `--tls-max 1.2`, and every host
preferred 1.3 when both were offered.

Four further facts, each of which shrinks stage 1:

- **The RFC's single mandatory suite is enough.** TLS 1.3 with only
  `TLS_AES_128_GCM_SHA256` offered completes against `api.openai.com` and
  `api.anthropic.com`. AES-256-GCM and ChaCha20-Poly1305 are a SHOULD, and they cost us
  nothing because `core:crypto/aead` already has both.
- **X25519 alone works, and P-256 alone works.** Both completed without the peer needing a
  group we did not offer. HelloRetryRequest handling was left out at first for that reason
  and is answered now, along with the secp256r1 exchange section 8.1 makes mandatory: a
  server restricted to P-256 answers the share this client sends with a retry, and
  `tls/test/openssl_handshake` runs that handshake for each suite.
- **TLS 1.2 needs one suite for these providers**: `ECDHE-ECDSA-AES128-GCM-SHA256` alone
  completed against both test hosts. CBC suites are not needed for them, which removes the
  padding-oracle surface from stage 2 entirely.
- **Certificates are all ECDSA P-256.** Every host presents an ECDSA P-256 leaf, an ECDSA
  P-256 intermediate signed `ecdsa-with-SHA384`, and a Google Trust Services root whose own
  signature is an RSA cross-sign from GlobalSign. Certificate verification therefore needs
  ECDSA P-256 and SHA-256/SHA-384, all in `core:crypto/x509`; the root is a trust anchor, so
  its cross-signature is not checked.
- **ALPN is not required.** All four complete a handshake with no ALPN extension sent, and
  all four answer HTTP/1.1. Advertising `http/1.1` remains the safer choice, and HTTP/2 is
  unnecessary.

**The decision.**

- **Stage 1, now: TLS 1.3 only.** Offer the RFC 8446 section 9.1 mandatory suite plus the
  two SHOULD suites, X25519 and P-256, SNI, and ALPN `http/1.1`. Verify certificates through
  `core:crypto/x509`. This is the minimum that works against every endpoint the harness
  uses, proven end to end by HTTP/1.1 requests over a forced TLS 1.3 connection.
- **Stage 2, deferred: TLS 1.2, AEAD suites only.** RFC 9325's MUST is why it is on the
  roadmap at all; no current endpoint requires it. Restrict it to
  `ECDHE-ECDSA-AES128-GCM-SHA256` and its RSA counterpart per RFC 5288, and skip CBC, which
  for our providers costs nothing and avoids MAC-then-encrypt entirely.
- **Never: TLS 1.0, TLS 1.1, SSLv3, or DTLS.** RFC 8996 forbids the first two and nothing
  in section 10.1 uses the others.

**Three seams so that stage 2 is an addition, not a rewrite.** Documented now, not built
now, because building them before there is a second version is exactly the speculative
abstraction to avoid: version dispatch in the handshake driver, key derivation behind one
internal procedure set, and record protection behind one internal interface. TLS 1.2 differs
from 1.3 at precisely those three points, so keeping them as separate files
(`key_schedule.odin`, `protect.odin`, and the driver in `tls.odin`) is the whole
preparation.

### 8.3 HTTP: RFC 9110, RFC 9111, RFC 9112

- **No duration.** RFC 9112 section 9.5, quoted in full in section 1.1: persistent
  connections place no requirement on the length or existence of a timeout for client or
  server. What a client must handle instead is an incomplete message, which RFC 9112
  section 8 governs: a client that receives an incomplete response "MUST record the message
  as incomplete".
- **No size maximum.** RFC 9112 section 3 recommends supporting at least 8000 octets for a
  request line and sets no ceiling. Section 7.1.1 permits a *server* to limit chunk
  extension length, and says so in the same breath as other message limits and timeouts,
  which is the mirror image of the client rule.
- **Interim responses.** RFC 9110 section 15.2: a client must be able to parse one or more
  1xx before the final response, with no count given.
- **Timeouts exist as protocol signals, not as client deadlines.** `408 Request Timeout`
  (RFC 9110 section 15.5.9) is a server's statement, and the RFC says a client with an
  outstanding request "MAY repeat that request". `504 Gateway Timeout` likewise. A client
  that wants a bound should therefore expect the server to say so, not invent one.
- **Upgrade.** RFC 9110 section 7.8: "A client MAY send a list of protocol names in the
  Upgrade header field ... Upgrade cannot be used to insist on a protocol change." That is
  the hook RFC 6455 uses.
- **Deliberately not adopted:** redirect following, a cookie jar, and pipelining. RFC 9110
  section 15.4 makes automatic redirection optional for a user agent, and our client
  already declines it.

### 8.4 WebSocket: RFC 6455

- **Client masking is mandatory.** Section 5.3: "a client MUST mask all frames that it
  sends to the server ... (Note that masking is done whether or not the WebSocket Protocol
  is running over TLS.)" The converse is also a MUST: "A server MUST NOT mask any frames
  that it sends to the client. A client MUST close a connection if it detects a masked
  frame." So a masked frame from a server fails the connection, with 1002 (protocol error)
  permitted as the status code.
- **Opening handshake**, section 4.2.1: a GET, `Host`, `Upgrade: websocket`, `Connection`
  including `Upgrade`, `Sec-WebSocket-Key` decoding to 16 bytes, `Sec-WebSocket-Version: 13`.
- **Secure connections**, section 4.1 item 5: "If /secure/ is true, the client MUST perform
  a TLS handshake over the connection after opening the connection and before sending the
  handshake data", and "Clients MUST use the Server Name Indication extension in the TLS
  handshake." That is the one place `wss` imposes a requirement on `tls`, and our `tls`
  sends SNI for every DNS-name host already.
- **Control frames**, section 5.5: "All control frames MUST have a payload length of 125
  bytes or less and MUST NOT be fragmented." Section 5.5.1: a Close body, when present,
  begins with a 2-byte status code.
- **No message size limit.** RFC 6455 sets none, so a limit would be ours. A caller that
  wants one applies it to the reassembled message it receives.

### 8.5 Server-Sent Events

Not an RFC. The event-stream format is defined by the WHATWG HTML Standard, section
"Server-sent events", and is delivered as `text/event-stream`. `sse/sse.odin` and
`sse/write.odin` therefore implement a WHATWG specification, and the plan names it as such
rather than claiming RFC compliance. Nothing in this work changes `sse`; it rides
`http/client` and needs only HTTPS beneath it.

## 9. Test strategy

### 9.1 The current HTTPS test cannot survive

`ai/transport_test.odin` builds an in-process TLS server with
`SSL_CTX_new(TLS_server_method())`, `SSL_CTX_use_certificate_file`,
`SSL_CTX_use_PrivateKey_file`, and `SSL_accept`. Removing the binding removes that server,
and writing a TLS server to keep a test would violate the scope in section 10 for the sake
of test scaffolding. The replacement has three parts, the first two mandatory.

1. **Recorded transcripts as fixtures.** A capture of a real handshake as bytes, replayed
   through the Sans-IO interior. Deterministic, no network, no external process, usable
   under `odin test`. This is where the per-byte and per-split-point assertions live, and
   it is the only layer that can assert exact `ClientHello` bytes, because the fixtures fix
   the peer randomness.
2. **An external server at integration time.** `openssl s_server` as a child process from a
   `test/` harness rather than from `odin test`, since it forks. This depends on the
   `openssl` *tool* at test time, which is a different thing from linking libssl, and the
   harness reports a skip when the tool is absent. Any real HTTP/1.1 server over TLS is an
   equivalent and exercises more.
3. **Optional live endpoints**, behind an environment variable, never in the default gate.

### 9.2 Cases that must exist

A `Certificate` large enough to be fragmented across records; a hello split into several
small records; several records in one TCP segment; a HelloRetryRequest followed by a cookie
echo; an orderly `close_notify` versus a bare TCP close; a chain that fails `verify_chain`,
so the failure is known to propagate rather than be swallowed; and a record exceeding
`2^14 + 256`, so `record_overflow` is known to be produced.

Certificate verification reuses `tests/core/crypto/x509/testdata` and the `x509_limbo`
harness, so a mismatch between our usage and core's expectations is caught.

Because rule 1.1 governs the new code too, one test asserts the negative: a handshake
against a peer that stalls mid-flight must still be in progress after a duration longer
than any constant in the package, because the package has none.

## 10. Scope

### 10.1 In scope

Every capability the harness needs is a client over one TCP connection: HTTP (present),
HTTPS (the work), SSE over both (present, needs HTTPS), and WebSocket over both (new).

### 10.2 Non-goals, each with its reason

- **The server role.** No caller serves TLS. The two ends of an HTTP connection here are
  both outbound clients.
- **TLS 1.0 and TLS 1.1 are never implemented.** RFC 8996 (BCP 195) says a client "MUST NOT
  send a ClientHello with ClientHello.client_version set to {03,02}" and that negotiation
  of either version "MUST NOT be permitted". Implementing them would be a compliance
  defect, not a scope reduction. Section 8.2.
- **TLS 1.2 is stage 2, not stage 1.** RFC 9325 makes it a MUST for a conformant
  implementation, and no endpoint the harness uses requires it: all four measured hosts
  prefer 1.3 and answer only when forced down. Stage 1 ships 1.3; stage 2 adds 1.2 in AEAD
  form behind the seams section 8.2 names.
- **PSK, resumption, session tickets, 0-RTT.** `NewSessionTicket` is parsed and ignored. A
  full handshake per connection is the current behaviour anyway.
- **Client certificates, CertificateRequest.** No caller presents one.
- **OCSP and CRL revocation.** Soft-fail, as most clients do, and out of band if ever wanted.
- **Renegotiation and compression.** Removed from TLS 1.3.
- **ALPN beyond `http/1.1`.** The client is HTTP/1.1.
- **HTTP/2, HTTP/3, HPACK, QUIC.** No capability needs them.
- **Redirects, a cookie jar, pipelining, automatic retries.** Caller policy, and none is
  required by section 10.1.
- **Windows and macOS build splits.** The project targets Linux. Core abstractions are used
  so that no split is needed, which is section 3; adding a platform branch is not.
- **The `http` server half.** Section 11.

## 11. Independent opportunities, not to be bundled

Each is its own change. Bundling any of them would make the TLS diff unreadable and the
TLS commit unrevertable.

1. **Remove platform code from `http/client`.** Done in phase 1: `nbio.dial` replaced
   `linux.connect`, and `core:c` and `core:sys/linux` left the package. It was first
   because it makes everything after it OS-agnostic by construction.
2. **Handle DNS truncation.** A response with the TC bit set should retry over TCP rather
   than fail, per RFC 1035 section 4.2.1. This is the one gap section 2 records in the
   resolver.
3. **Review the harness's hard maximums** listed in section 2: the MCP call maximum, the
   server and entry counts, and the shell timeout maximum. These are policy, they are
   visible to users, and each one currently overrides a request the user or a provider made.
4. **Decide the fate of the `http` server half.** About 1450 lines with no caller outside
   `http/`. An HTTP package may reasonably ship a server, and an official one probably
   should, so this is a decision about what the package is for rather than a cleanup.
5. **Consider a fully asynchronous client.** `nbio.send` with `all`, `nbio.recv`, and
   operation-level timeouts would replace `wait.odin`'s 50 ms slices. It is a rewrite of
   three files and nothing needs it.

## 12. Risks and open decisions

### 12.1 Risks

- **Interoperability is the long tail.** The primitives are core's and already exercised.
  The failures are a record split at an uncovered offset, a server sending an extension we
  reject instead of ignore, and a chain shape the corpora lack.
- **Certificate verification is where the security lives.** A record-layer bug corrupts; a
  verification bug leaks silently and permanently. The wiring of `verify_chain`,
  `verify_hostname`, and `required_eku = .Server_Auth` is the part to review hardest, and
  the double-check idiom arcbjorn uses, where verification is enforced in two places so
  that removing one changes nothing observable, is worth copying in spirit.
- **We become the only thing between the harness and the network.** Today a 142-line
  binding stands on OpenSSL's decade of adversarial review. The core maintainer's own
  argument applies: "Getting the code audited for correctness would cost an utterly
  mind-blowing amount of money." The mitigation that exists is section 9's vectors and
  split-point tests before any code touches a socket.
- **TLS 1.3 only in stage 1.** A server that requires 1.2 and offers no suite below it fails
  against stage 1 with a clean `protocol_version` alert. Measured cost for our endpoints:
  zero. For an arbitrary third-party URL, unknown, and that is the trigger in section 12.2.
- **Scope creep via the references.** HTTP/2 and HPACK sit in the same directory and are
  not needed.

### 12.2 Open decisions for the owner

1. **When to start stage 2 (TLS 1.2).** Section 8.2 settles what and how: stage 1 is TLS
   1.3, stage 2 is TLS 1.2 in AEAD form, and 1.0/1.1 are never done. The only open item is
   the trigger, and no current endpoint provides one. RFC 9325's MUST is why it belongs on
   the roadmap rather than in a backlog.
2. **Is `tls` reached through `http/client` only?** Yes: the WebSocket client of phase 6
   opens its connection through `http/client` too, so `http/client` is still the only
   consumer. `tls` stays written to stand alone, and the vtable of section 6.5 stays
   unnecessary until a second consumer appears.
3. **Should the client stop classifying a valid status as a failure?** Section 2 records
   that `stream_request` treats a non-2xx as a `Failure`. The body is still delivered, so
   no caller is blocked, but it is the client making a policy call.
4. **The harness's hard maximums**, per section 11 item 3, and the `http` server half, per
   item 4.

## 13. Implementation plan

Each phase is a commit, and `mise run check` must be green at every boundary. No phase
leaves the tree unbuildable.

**Phase 0: contract and verification.** Confirm every core API in sections 3 and 7.3 by
compiling a throwaway program that calls each one. No production code. Gate: it builds and
runs.

**Phase 1: make the client OS-agnostic.** Done: `core:nbio`'s dial replaces the raw
connect, `core:c` and `core:sys/linux` have left `connection.odin`, and `grep -r 'core:sys'
http/` is empty. `DNS_TIMEOUT` stayed, and section 2 records why: withdrawing an attempt at
a timeout is DNS's own retransmission step rather than a limit this client invented.

**Phase 2: record layer and key schedule, offline.** Done: `tls/record.odin`,
`tls/handshake.odin`, `tls/key_schedule.odin`, `tls/protect.odin`, with the RFC 8448
section 3 known-answer vectors as the gate: the derived secrets, the traffic key, a
protected record reproduced byte for byte, and the flight recovered by unprotecting it.
The constants the record layer and the handshake encode come from RFC 8446 Appendix B.1
and B.3.

**Phase 3: handshake, offline and local.** Done: `tls/client_hello.odin`,
`tls/server_hello.odin`, `tls/auth.odin`, `tls/alert.odin`, `tls/roots.odin`, and the
`Conn` driver with `Transport`. The trace's own CertificateVerify and Finished verify,
which is what pins the signature input and the transcript each of them covers.
Compatibility mode is complete: a session id is named, the one change cipher spec record
the appendix places before this client's second flight is sent, and an alert the peer ends
the handshake with is reported with the description it carried. Gate:
`tls/test/openssl_handshake` completes a real handshake against `openssl s_server` over a
socket and asks it for a page.

Two things phase 3 left were finished after it, each for a reason the RFC states rather than
one a provider forced: a HelloRetryRequest is answered, and the mandatory secp256r1 key
exchange is offered, so a peer that accepts only the mandatory group is reachable.
`tls/test/openssl_handshake` now runs each suite against a server restricted to each group,
which is where both retries are exercised against an independent implementation.

**Phase 4: record protection and public read/write, local.** Done: `Conn.read` and
`Conn.write` carry application data, a key update from the peer is followed, and a
close_notify is sent and understood. Gate: the same harness writes an HTTP request and
reads the response over the protected connection.

**Phase 5: integration, and OpenSSL leaves the client.** Done: `http/client` builds a
`tls.Transport` from the socket movers it already had, loads the caller's trust store with
`tls.roots_parse`, and maps what the TLS layer said onto its own errors;
`http/client/openssl.odin` and the OpenSSL half of `http/client/tls.odin` are deleted;
the in-process TLS server fixture is replaced per section 9.1. Gate: `mise run check`,
`mise run test`, `http/test/https_request` completing a real HTTPS request through
`stream_request`, a live `GET` to `api.openai.com`, `api.anthropic.com`, and
`openrouter.ai` whose chains are ECDSA, the same three refused when the trust store does
not contain their anchors, and `ldd` on the built binary showing neither libssl nor
libcrypto.

**Phase 6: WebSocket.** Done: `http/client/upgrade.odin` performs a request the peer may
take the connection over and hands it back when a 101 answers it, keeping the octets read
past the response head for the upgraded protocol and requiring a 101 rather than a failure
with a status; a caller's own fields also replace the ones the request builder would
supply, which is how the upgrade states its connection. `websocket/frame.odin` holds the
framing rules, `websocket/handshake.odin` the key and the answer to it, `websocket/conn.odin`
the protocol rules, and `websocket/client.odin` dials ws and wss by stating the WebSocket
URL as the HTTP URL it is, then keeps the calling thread's event loop for as long as the
connection lives, so a caller's cancellation and deadlines reach a WebSocket unchanged.
Gate: `websocket` holds the codec to the RFC 6455 section 5.7 octets and a connection to a
byte-for-byte transport fixture, and `websocket/test/echo` runs ws and wss against a
scripted Python peer that speaks RFC 6455 itself: a message in each direction, a fragmented
message reassembled, a ping each way, an orderly close, a masked frame from the server and a
control frame over 125 octets each failing the connection with 1002, and a response that
does not accept the key refused. That peer found two defects, both fixed in their own
commit: the connection was protected with the client's own first suite rather than the
server's choice, and a `defer` inside a block released the trust store path before the dial
read it.

**Phase 7: cleanup.** Done with phase 5: no `system:ssl` or `system:crypto` reference
remains, and the fixtures an OpenSSL server needed are gone.

**Stage 2, deferred: TLS 1.2.** RFC 5288 AEAD suites only, no CBC, and no renegotiation
handling beyond not breaking. Gated on an endpoint that requires it. Section 8.2 lists the
three seams that keep it an addition rather than a rewrite.
