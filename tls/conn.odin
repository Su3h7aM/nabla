package tls

import "core:bytes"
import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:crypto/x509"
import "core:mem"
import "core:net"
import "core:strings"
import "core:time"

// Transport is how a connection reaches its peer. Both calls block until they moved
// bytes or the caller ended the wait, and report false when they moved none.
// Cancellation, deadlines, and their reporting stay with the caller, which is the
// only side that knows why a wait ended.
Transport :: struct {
	read:      proc(user_data: rawptr, buffer: []u8) -> (count: int, ok: bool),
	write:     proc(user_data: rawptr, buffer: []u8) -> (count: int, ok: bool),
	user_data: rawptr,
}

// Config is what a connection needs from its caller: the certificates a chain may
// end at, and where its own allocations live.
Config :: struct {
	// roots are the trust anchors. A chain that ends anywhere else is refused, so
	// no roots refuse every chain.
	roots:     []^x509.Certificate,
	allocator: mem.Allocator,
}

// Error is why a connection failed. Transport is the caller's own failure handed
// back, and the rest name what about the peer's answer was not acceptable.
Error :: enum {
	None,
	Transport,
	Record,
	Handshake,
	Unsupported,
	Peer_Rejected,
	Signature,
	Finished,
	Alert,
	No_Room,
}

// MAX_SENT_MESSAGE is the room a handshake message this client sends has. What it
// sends is a ClientHello, a Finished, and alerts, all of them far smaller; the room
// exists so that a caller's oversized ALPN list is refused rather than truncated.
MAX_SENT_MESSAGE :: 2048

// Conn is one TLS connection: the handshake stream it is assembling, the keys it has
// reached, and the record it is reading.
//
// Every buffer is allocated once and reused, so a connection moves no memory while
// it is in use.
Conn :: struct {
	transport:    Transport,
	config:       Config,
	suite:        Cipher_Suite,
	schedule:     Key_Schedule,
	read_secret:  Secret,
	write_secret: Secret,
	read_key:     Traffic_Key,
	write_key:    Traffic_Key,
	transcript:   hash.Context,
	digest:       [MAX_SECRET_SIZE]u8,

	send:        []u8,
	message:     []u8,
	recv:        []u8,
	recv_filled: int,
	stream:      [dynamic]u8,
	stream_at:   int,

	payload:   []u8,
	encrypted: bool,
	closed:    bool,
	alpn:      string,
	peer_alert: u8,
}

// init prepares a connection. The transport is the caller's and outlives the
// connection; a connection owns nothing of it but the bytes it moves.
init :: proc(transport: Transport, config: Config) -> (conn: ^Conn, err: Error) {
	if transport.read == nil || transport.write == nil { return nil, .Transport }

	allocator := config.allocator
	self := new(Conn, allocator)
	self.transport = transport
	self.config = config
	self.send = make([]u8, RECORD_HEADER_SIZE + MAX_CIPHERTEXT_RECORD, allocator)
	self.message = make([]u8, HANDSHAKE_HEADER_SIZE + MAX_SENT_MESSAGE, allocator)
	self.recv = make([]u8, RECORD_HEADER_SIZE + MAX_CIPHERTEXT_RECORD, allocator)
	self.stream = make([dynamic]u8, 0, MAX_CIPHERTEXT_RECORD, allocator)
	return self, .None
}

destroy :: proc(conn: ^Conn) {
	if conn == nil { return }
	allocator := conn.config.allocator
	delete(conn.alpn, allocator)
	delete(conn.send, allocator)
	delete(conn.message, allocator)
	delete(conn.recv, allocator)
	delete(conn.stream)
	free(conn, allocator)
}

// handshake takes the connection through a TLS 1.3 handshake, verifying the peer's
// chain against the configured roots and its identity against `server_name`.
//
// `alpn` is what the caller speaks over TLS. A server that chooses none leaves the
// connection's alpn empty, which the caller may treat as a mismatch.
handshake :: proc(conn: ^Conn, server_name: string, alpn: []string) -> Error {
	suite := OFFERED_SUITES[0]
	conn.suite = suite
	conn.schedule = key_schedule_init(suite)
	hash.init(&conn.transcript, CIPHER_SUITES[suite].hash)

	random: [32]u8
	session_id: [32]u8
	crypto.rand_bytes(random[:])
	crypto.rand_bytes(session_id[:])

	// An address literal is not a name, and SNI carries no address literals
	// (RFC 6066 section 3), so it is verified without being sent.
	sni := server_name
	if _, is_ip4 := net.parse_ip4_address(sni); is_ip4 { sni = "" }
	if _, is_ip6 := net.parse_ip6_address(sni); is_ip6 { sni = "" }

	// What a second ClientHello repeats unchanged: a retry differs from the first only
	// in the key share it was asked for and the cookie it was given (RFC 8446 section
	// 4.1.2).
	fields := Client_Hello_Fields {
		random      = random,
		session_id  = session_id[:],
		server_name = sni,
		alpn        = alpn,
	}

	exchange: Key_Exchange
	if !key_exchange_generate(&exchange, OFFERED_GROUPS[0]) { return .Unsupported }
	fields.group = exchange.group
	fields.keyshare = exchange.share[:exchange.length]

	// The first ClientHello is kept: a server whose own suite is not the one offered
	// first makes the transcript be taken again, and this is the message it is taken
	// with (RFC 8446 section 4.1.3).
	hello_sent, hello_built := client_hello_message(conn, fields)
	if !hello_built { return .No_Room }
	if hello_err := send_message(conn, hello_sent); hello_err != .None { return hello_err }

	hello_message, answer_err := handshake_next(conn)
	if answer_err != .None { return answer_err }
	hello, hello_ok := server_hello_read(hello_message)
	if !hello_ok { return .Handshake }

	// Compatibility mode sends one change cipher spec, immediately before the client's
	// second flight (RFC 8446 section D.4). Which flight that is depends on what the
	// server answered, so it goes out where that is known.
	change_cipher_spec_sent := false
	retried := false
	if hello.retry {
		// The server asked for a key exchange in another group. The client names a
		// session id in its first ClientHello and the server echoes it, so this is
		// where a middlebox-aware handshake happens (RFC 8446 section D.4).
		if hello.version != VERSION_1_3 || hello.pre_shared_key { return fail(conn, .Illegal_Parameter, .Unsupported) }
		if !suite_offered(hello.cipher_suite) { return fail(conn, .Illegal_Parameter, .Unsupported) }
		if !bytes.equal(hello.session_id, session_id[:]) { return fail(conn, .Illegal_Parameter, .Handshake) }
		if !key_exchange_generate(&exchange, hello.group) { return fail(conn, .Illegal_Parameter, .Unsupported) }

		// The retry names the suite the rest of the handshake uses, and the ServerHello
		// must name the same one (RFC 8446 section 4.1.4), so the schedule and the
		// transcript change to it before the first ClientHello is replaced by its hash.
		if hello.cipher_suite != suite {
			suite = hello.cipher_suite
			conn.suite = suite
			conn.schedule = key_schedule_init(suite)
		}

		fields.group = exchange.group
		fields.keyshare = exchange.share[:exchange.length]
		fields.cookie = hello.cookie
		if retry_err := client_hello_retry(conn, fields, hello_sent, hello_message); retry_err != .None { return retry_err }
		change_cipher_spec_sent = true
		retried = true

		hello_message, answer_err = handshake_next(conn)
		if answer_err != .None { return answer_err }
		hello, hello_ok = server_hello_read(hello_message)
		// A second retry leaves this client with nothing to answer.
		if !hello_ok || hello.retry { return fail(conn, .Unexpected_Message, .Handshake) }
	}

	if hello.version != VERSION_1_3 || hello.pre_shared_key { return .Unsupported }
	if !suite_offered(hello.cipher_suite) { return .Unsupported }
	if hello.group != exchange.group || len(hello.keyshare) == 0 { return fail(conn, .Illegal_Parameter, .Unsupported) }
	// A server echoes the session id it was sent, which is what carries a
	// compatibility-mode handshake through a middlebox (RFC 8446 section 4.1.3).
	if !bytes.equal(hello.session_id, session_id[:]) { return .Handshake }

	// The server's own choice is the one that protects the connection, and its hash is
	// the hash of the transcript, so both are taken again for it (RFC 8446 section
	// 4.1.3). The first ClientHello is hashed from the buffer it was built in, which
	// still holds it: what has been read since went into another.
	if hello.cipher_suite != suite {
		// A retry already named the suite, and the ServerHello has to name the same one
		// (RFC 8446 section 4.1.4).
		if retried { return fail(conn, .Illegal_Parameter, .Unsupported) }
		suite = hello.cipher_suite
		conn.suite = suite
		conn.schedule = key_schedule_init(suite)
		hash.init(&conn.transcript, CIPHER_SUITES[suite].hash)
		hash.update(&conn.transcript, hello_sent)
	}
	hash.update(&conn.transcript, hello_message)

	shared_secret: [SHARED_SECRET_MAX]u8
	if !key_exchange_shared(&exchange, hello.keyshare, shared_secret[:]) { return .Unsupported }
	// A shared secret of zeros is a small-order peer key, and the protocol refuses
	// the connection rather than derive keys from it (RFC 8446 section 7.4.2).
	if all_zero(shared_secret[:]) { return .Unsupported }

	if !key_schedule_advance(&conn.schedule, shared_secret[:]) { return .Unsupported }
	client_secret, server_secret: Secret
	if !key_schedule_traffic_secrets(&conn.schedule, transcript_hash(conn), &client_secret, &server_secret) {
		return .Unsupported
	}
	conn.read_secret = server_secret
	conn.write_secret = client_secret
	conn.encrypted = true
	if !traffic_key_derive(suite, conn.read_secret[:secret_size(suite)], &conn.read_key) { return .Unsupported }
	if !traffic_key_derive(suite, conn.write_secret[:secret_size(suite)], &conn.write_key) { return .Unsupported }

	if flight_err := handshake_server_flight(conn, server_name); flight_err != .None { return flight_err }

	// The client's Finished is the last thing the handshake keys protect, and it
	// covers the handshake through the server's Finished. The application secrets
	// cover exactly the same transcript, so it is kept before the client's Finished
	// joins it (RFC 8446 section 7.1).
	application_hash: [MAX_SECRET_SIZE]u8
	digest := transcript_hash(conn)
	copy(application_hash[:], digest)

	// The master secret is extracted from a zero input when no pre-shared key is in
	// play, and needs no transcript.
	zeroes: [MAX_SECRET_SIZE]u8
	if !key_schedule_advance(&conn.schedule, zeroes[:secret_size(suite)]) { return .Unsupported }

	if !change_cipher_spec_sent {
		if change_err := send_change_cipher_spec(conn); change_err != .None { return change_err }
	}
	if finished_err := handshake_client_finished(conn); finished_err != .None { return finished_err }

	client_application, server_application: Secret
	if !key_schedule_traffic_secrets(&conn.schedule, application_hash[:len(digest)], &client_application, &server_application) {
		return .Unsupported
	}
	conn.read_secret = server_application
	conn.write_secret = client_application
	if !traffic_key_derive(suite, conn.read_secret[:secret_size(suite)], &conn.read_key) { return .Unsupported }
	if !traffic_key_derive(suite, conn.write_secret[:secret_size(suite)], &conn.write_key) { return .Unsupported }
	return .None
}

// handshake_server_flight reads what the server says once the handshake keys are
// live: its extensions, its chain, its proof of the chain's key, and its Finished,
// in the order the protocol fixes (RFC 8446 section 4.4).
handshake_server_flight :: proc(conn: ^Conn, server_name: string) -> Error {
	extensions_message, err := handshake_next(conn)
	if err != .None { return err }
	extensions_type, _, decoded := handshake_decode_header(extensions_message)
	if !decoded || extensions_type != .Encrypted_Extensions { return .Handshake }
	if negotiated := extension_find(extensions_message[HANDSHAKE_HEADER_SIZE:], .Application_Layer_Protocol_Negotiation); negotiated != nil {
		protocols := Reader{data = negotiated, ok = true}
		names := read_section_u16(&protocols)
		first := read_bytes(&names, int(read_u8(&names)))
		if !names.ok { return .Handshake }
		conn.alpn = strings.clone(string(first), conn.config.allocator)
	}
	hash.update(&conn.transcript, extensions_message)

	certificate_message, certificate_err := handshake_next(conn)
	if certificate_err != .None { return certificate_err }
	certificate_type, _, certificate_decoded := handshake_decode_header(certificate_message)
	if !certificate_decoded || certificate_type != .Certificate { return .Handshake }
	chain, chain_decoded := certificate_chain_decode(certificate_message[HANDSHAKE_HEADER_SIZE:], conn.config.allocator)
	defer certificate_chain_destroy(&chain)
	if !chain_decoded { return .Handshake }
	if !chain_verify(chain.certificates, server_name, conn.config) { return .Peer_Rejected }
	hash.update(&conn.transcript, certificate_message)

	verify_message, verify_err := handshake_next(conn)
	if verify_err != .None { return verify_err }
	verify_type, _, verify_decoded := handshake_decode_header(verify_message)
	if !verify_decoded || verify_type != .Certificate_Verify { return .Handshake }
	if !certificate_verify_verify(verify_message[HANDSHAKE_HEADER_SIZE:], &chain.certificates[0], transcript_hash(conn)) {
		return .Signature
	}
	hash.update(&conn.transcript, verify_message)

	finished_message, finished_err := handshake_next(conn)
	if finished_err != .None { return finished_err }
	finished_type, _, finished_decoded := handshake_decode_header(finished_message)
	if !finished_decoded || finished_type != .Finished { return .Handshake }
	size := secret_size(conn.suite)
	if !finished_verify(conn.suite, conn.read_secret[:size], transcript_hash(conn), finished_message[HANDSHAKE_HEADER_SIZE:]) {
		return .Finished
	}
	hash.update(&conn.transcript, finished_message)
	return .None
}

// handshake_client_finished proves the handshake to the server, over the transcript
// that now ends with the server's own Finished.
handshake_client_finished :: proc(conn: ^Conn) -> Error {
	size := secret_size(conn.suite)
	finished := conn.message[:HANDSHAKE_HEADER_SIZE + size]
	handshake_encode_header(.Finished, size, finished)
	finished_key: [MAX_SECRET_SIZE]u8
	if !hkdf_expand_label(conn.suite, conn.write_secret[:size], "finished", {}, finished_key[:size]) {
		return .Unsupported
	}
	hmac.sum(CIPHER_SUITES[conn.suite].hash, finished[HANDSHAKE_HEADER_SIZE:], transcript_hash(conn), finished_key[:size])
	return send_message(conn, finished)
}

// read returns the next bytes of application data, reading a record when it holds
// none. Zero bytes with .None is the end of the stream.
read :: proc(conn: ^Conn, buffer: []u8) -> (count: int, err: Error) {
	for len(conn.payload) == 0 {
		if conn.closed { return 0, .None }
		if post_err := post_handshake_handle(conn); post_err != .None { return 0, post_err }

		content, record_type, read_err := read_record(conn)
		if read_err != .None { return 0, read_err }
		switch record_type {
		case .Application_Data:
			conn.payload = content
		case .Alert:
			return 0, alert_report(conn, content)
		case .Handshake:
			// read_record keeps handshake bytes to itself.
			continue
		case .Change_Cipher_Spec:
			continue
		}
	}

	count = copy(buffer, conn.payload)
	conn.payload = conn.payload[count:]
	return count, .None
}

// write hands the whole buffer to the peer as application data. It counts bytes the
// record layer accepted, which is not evidence that the peer has them.
write :: proc(conn: ^Conn, buffer: []u8) -> (count: int, err: Error) {
	for count < len(buffer) {
		chunk := buffer[count:]
		if len(chunk) > MAX_PLAINTEXT_RECORD { chunk = chunk[:MAX_PLAINTEXT_RECORD] }
		if send_err := send_record(conn, .Application_Data, chunk); send_err != .None { return count, send_err }
		count += len(chunk)
	}
	return count, .None
}

// close sends the close_notify that tells the peer no more records follow. The
// transport is the caller's to close, and closing twice sends nothing.
close :: proc(conn: ^Conn) -> Error {
	if conn.closed { return .None }
	conn.closed = true
	if !conn.encrypted { return .None }

	alert := conn.message[:2]
	alert[0] = u8(Alert_Level.Warning)
	alert[1] = u8(Alert_Description.Close_Notify)
	return send_record(conn, .Alert, alert)
}

// --- what this client sends first ---

// server_hello_read decodes the answer to a ClientHello, reporting false for a message
// that is not one.
server_hello_read :: proc(message: []u8) -> (hello: Server_Hello, ok: bool) {
	hello_type, _, decoded := handshake_decode_header(message)
	if !decoded || hello_type != .Server_Hello { return {}, false }
	return server_hello_decode(message[HANDSHAKE_HEADER_SIZE:])
}

// client_hello_message builds a ClientHello in the connection's message buffer and
// returns it, ready to send. The slice stays valid until the next ClientHello is built.
client_hello_message :: proc(conn: ^Conn, fields: Client_Hello_Fields) -> (message: []u8, ok: bool) {
	body := conn.message[HANDSHAKE_HEADER_SIZE:]
	body_length, encoded := client_hello_encode(body, fields)
	if !encoded { return nil, false }
	message = conn.message[:HANDSHAKE_HEADER_SIZE + body_length]
	handshake_encode_header(.Client_Hello, body_length, message)
	return message, true
}

// client_hello_retry answers a HelloRetryRequest. The second ClientHello repeats the
// first with the key share and the cookie the server asked for, and it is preceded by
// the one change cipher spec this client sends, which compatibility mode places before
// its second flight (RFC 8446 sections 4.1.4 and D.4).
//
// The transcript becomes the hash of the first ClientHello in a message_hash message,
// the retry, and the second ClientHello, which is the digest the retry replaces. That
// hash is the hash of the suite the retry named, which is why the first ClientHello is
// hashed again here rather than read out of the running transcript (RFC 8446 section
// 4.4.1).
client_hello_retry :: proc(conn: ^Conn, fields: Client_Hello_Fields, first: []u8, retry_message: []u8) -> Error {
	suite_hash := CIPHER_SUITES[conn.suite].hash
	hash.init(&conn.transcript, suite_hash)
	hash.update(&conn.transcript, first)
	digest := transcript_hash(conn)

	hash.init(&conn.transcript, suite_hash)
	header: [HANDSHAKE_HEADER_SIZE]u8
	handshake_encode_header(.Message_Hash, len(digest), header[:])
	hash.update(&conn.transcript, header[:])
	hash.update(&conn.transcript, digest)
	hash.update(&conn.transcript, retry_message)

	if change_err := send_change_cipher_spec(conn); change_err != .None { return change_err }
	message, built := client_hello_message(conn, fields)
	if !built { return .No_Room }
	return send_message(conn, message)
}

// CHANGE_CIPHER_SPEC is the body a change cipher spec record carries, which is all
// compatibility mode needs of it (RFC 8446 section D.4).
CHANGE_CIPHER_SPEC :: 1

// send_change_cipher_spec writes the unencrypted change cipher spec record that
// compatibility mode places before this client's second flight. It goes out unencrypted
// even when the handshake keys are live, because a peer that is not reading the handshake
// yet is exactly what it is for.
send_change_cipher_spec :: proc(conn: ^Conn) -> Error {
	body: [1]u8 = {CHANGE_CIPHER_SPEC}
	count, encoded := record_encode(.Change_Cipher_Spec, body[:], conn.send)
	if !encoded { return .No_Room }
	return transport_write(conn, conn.send[:count])
}

// --- records ---

// read_record reads one record and returns what it carried that is not handshake
// bytes. Handshake bytes belong to the handshake stream, and a record that carries
// only a change cipher spec is dropped, which is what a compatibility-mode peer
// sends and what a receiver does without further processing (RFC 8446 section 5).
read_record :: proc(conn: ^Conn) -> (content: []u8, record_type: Record_Type, err: Error) {
	for {
		conn.recv_filled = 0
		if fill_err := recv_fill(conn, RECORD_HEADER_SIZE); fill_err != .None { return nil, {}, fill_err }
		outer_type, length, decoded := record_decode_header(conn.recv[:RECORD_HEADER_SIZE])
		if !decoded { return nil, {}, fail(conn, .Decode_Error, .Record) }
		// A record longer than the protocol allows ends the connection, and the size
		// is what the peer is told (RFC 8446 section 5.2).
		if length > MAX_CIPHERTEXT_RECORD { return nil, {}, fail(conn, .Record_Overflow, .Record) }
		if fill_err := recv_fill(conn, RECORD_HEADER_SIZE + length); fill_err != .None { return nil, {}, fill_err }

		record := conn.recv[:RECORD_HEADER_SIZE + length]
		// A compatibility-mode peer sends one, and a receiver drops it without
		// further processing (RFC 8446 section 5).
		if outer_type == .Change_Cipher_Spec { continue }

		payload: []u8
		content_type: Record_Type
		if conn.encrypted {
			// Once the handshake keys are live, everything but a change cipher
			// spec is protected, and an unprotected record would be a message
			// anyone could have written.
			if outer_type != .Application_Data { return nil, {}, fail(conn, .Unexpected_Message, .Record) }
			inner, inner_type, opened := record_unprotect(conn.suite, &conn.read_key, record)
			// A record that does not authenticate ends the connection too (RFC 8446
			// section 5.2).
			if !opened { return nil, {}, fail(conn, .Bad_Record_Mac, .Record) }
			payload, content_type = inner, inner_type
		} else {
			decoded_payload, plain_type, plain_decoded := record_decode(record)
			if !plain_decoded { return nil, {}, .Record }
			payload, content_type = decoded_payload, plain_type
		}

		#partial switch content_type {
		case .Change_Cipher_Spec:
			continue
		case .Handshake:
			// Handshake bytes belong to the handshake stream, and the caller has
			// them to parse now rather than after the next record.
			append(&conn.stream, ..payload)
			return nil, .Handshake, .None
		case .Alert, .Application_Data:
			return payload, content_type, .None
		}
	}
}

// recv_fill reads exactly `count` bytes of the record being read.
recv_fill :: proc(conn: ^Conn, count: int) -> Error {
	for conn.recv_filled < count {
		read, ok := conn.transport.read(conn.transport.user_data, conn.recv[conn.recv_filled:count])
		if !ok || read <= 0 { return .Transport }
		conn.recv_filled += read
	}
	return .None
}

// send_record writes one record, protected once the handshake keys are live, and
// returns what ended the write.
send_record :: proc(conn: ^Conn, record_type: Record_Type, payload: []u8) -> Error {
	count: int
	written: bool
	if conn.encrypted {
		count, written = record_protect(conn.suite, &conn.write_key, record_type, payload, conn.send)
	} else {
		count, written = record_encode(record_type, payload, conn.send)
	}
	if !written { return .No_Room }
	return transport_write(conn, conn.send[:count])
}

transport_write :: proc(conn: ^Conn, data: []u8) -> Error {
	pending := data
	for len(pending) > 0 {
		written, ok := conn.transport.write(conn.transport.user_data, pending)
		if !ok || written <= 0 { return .Transport }
		pending = pending[written:]
	}
	return .None
}

// send_message sends a handshake message that is already built, header included, and
// adds it to the transcript.
send_message :: proc(conn: ^Conn, message: []u8) -> Error {
	hash.update(&conn.transcript, message)
	return send_record(conn, .Handshake, message)
}

// --- the handshake stream ---

// handshake_next returns the next handshake message, reading records until the
// stream holds all of it. A handshake message is not aligned to records, so one
// message can span records and one record can carry several. The message is the
// whole of it, header included, and it stays valid until the next call.
handshake_next :: proc(conn: ^Conn) -> (message: []u8, err: Error) {
	for {
		if available := handshake_available(conn); available != nil { return available, .None }

		content, record_type, read_err := read_record(conn)
		if read_err != .None { return nil, read_err }
		#partial switch record_type {
		case .Handshake:
			// read_record keeps handshake bytes in the stream, and there are now
			// some to parse.
			continue
		case .Alert:
			// An alert ends the handshake whatever it describes: a close_notify
			// here is a peer that gave up rather than one that finished, and it is
			// not a handshake message to parse (RFC 8446 section 6.1).
			_ = alert_report(conn, content)
			return nil, .Alert
		case:
			// Application data has no place in a handshake.
			return nil, .Handshake
		}
	}
}

// handshake_available returns the next handshake message when the stream already
// holds all of it, and nil when it does not. Consumed bytes are dropped, so the
// stream keeps only what a message still needs.
handshake_available :: proc(conn: ^Conn) -> []u8 {
	buffered := conn.stream[conn.stream_at:]
	if len(buffered) >= HANDSHAKE_HEADER_SIZE {
		_, length, decoded := handshake_decode_header(buffered)
		if !decoded { return nil }
		if len(buffered) >= HANDSHAKE_HEADER_SIZE + length {
			message := buffered[:HANDSHAKE_HEADER_SIZE + length]
			conn.stream_at += HANDSHAKE_HEADER_SIZE + length
			if conn.stream_at == len(conn.stream) {
				clear(&conn.stream)
				conn.stream_at = 0
			}
			return message
		}
	}
	return nil
}

// --- answers to what the peer said ---

// fail tells the peer which rule it broke and reports the failure, which is what the
// protocol asks of the side that finds a violation (RFC 8446 section 6.2).
fail :: proc(conn: ^Conn, description: Alert_Description, err: Error) -> Error {
	alert: [2]u8 = {u8(Alert_Level.Fatal), u8(description)}
	_ = send_record(conn, .Alert, alert[:])
	return err
}

// alert_report records the peer's alert and reports how the connection ended. A
// close_notify is the end of the stream, and anything else is the peer refusing.
alert_report :: proc(conn: ^Conn, content: []u8) -> Error {
	if len(content) < 2 { return .Record }
	conn.peer_alert = content[1]
	if Alert_Description(content[1]) == .Close_Notify {
		conn.closed = true
		return .None
	}
	return .Alert
}

// post_handshake_handle consumes the handshake messages a peer may send after the
// handshake. A new session ticket is not this client's business, since it keeps no
// tickets, and a key update changes the read key (RFC 8446 section 4.6).
post_handshake_handle :: proc(conn: ^Conn) -> Error {
	for {
		message := handshake_available(conn)
		if message == nil { return .None }

		message_type, _, decoded := handshake_decode_header(message)
		if !decoded { return .Handshake }
		#partial switch message_type {
		case .New_Session_Ticket:
		case .Key_Update:
			if len(message) != HANDSHAKE_HEADER_SIZE + 1 || message[HANDSHAKE_HEADER_SIZE] != 0 {
				// This client never asks for an update, so a peer that asks for one
				// is answering a request that was never made.
				return .Handshake
			}
			size := secret_size(conn.suite)
			updated: Secret
			if !key_schedule_update(conn.suite, conn.read_secret[:size], updated[:size]) { return .Unsupported }
			conn.read_secret = updated
			if !traffic_key_derive(conn.suite, conn.read_secret[:size], &conn.read_key) { return .Unsupported }
		case:
			return .Handshake
		}
	}
}

// --- what a connection can say about itself ---

// transcript_hash is the hash of the handshake so far. The running hash stays
// usable, since every message after it extends it. The result is valid until the
// next call.
transcript_hash :: proc(conn: ^Conn) -> []u8 {
	size := hash.digest_size(&conn.transcript)
	hash.final(&conn.transcript, conn.digest[:size], true)
	return conn.digest[:size]
}

// extension_find returns the body of one extension of a message whose whole body is
// an extension list, and nil when the peer did not send it.
extension_find :: proc(body: []u8, wanted: Extension_Type) -> []u8 {
	r := Reader{data = body, ok = true}
	extensions := read_section_u16(&r)
	for extensions.ok && extensions.at < len(extensions.data) {
		extension_type := Extension_Type(read_u16(&extensions))
		extension := read_section_u16(&extensions)
		if extension_type == wanted && extension.ok { return extension.data }
	}
	return nil
}

// chain_verify checks the peer's chain against the configured anchors, within their
// validity windows, against the identity the connection was reached by, and for the
// purpose a TLS server certificate is used for.
chain_verify :: proc(certificates: []x509.Certificate, server_name: string, config: Config) -> bool {
	if len(certificates) == 0 || len(config.roots) == 0 { return false }
	if !identity_verify(&certificates[0], server_name) { return false }

	intermediates := certificate_pointers(certificates[1:], config.allocator)
	defer delete(intermediates, config.allocator)
	_, chain_err := x509.verify_chain(
		&certificates[0],
		{
			roots         = config.roots,
			intermediates = intermediates,
			current_time  = time.now(),
			dns_name      = server_name,
			required_eku  = x509.EKU_Bit.Server_Auth,
		},
		config.allocator,
	)
	return chain_err == .None
}

suite_offered :: proc(suite: Cipher_Suite) -> bool {
	for offered in OFFERED_SUITES {
		if offered == suite { return true }
	}
	return false
}

all_zero :: proc(data: []u8) -> bool {
	for byte in data {
		if byte != 0 { return false }
	}
	return true
}
