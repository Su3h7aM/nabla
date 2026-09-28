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
	transport:             Transport,
	config:                Config,
	suite:                 Cipher_Suite,
	schedule:              Key_Schedule,
	read_secret:           Secret,
	write_secret:          Secret,
	read_key:              Traffic_Key,
	write_key:             Traffic_Key,
	transcript:            hash.Context,
	digest:                [MAX_SECRET_SIZE]u8,
	send:                  []u8,
	message:               []u8,
	recv:                  []u8,
	recv_filled:           int,
	stream:                [dynamic]u8,
	stream_at:             int,
	payload:               []u8,
	encrypted:             bool,
	closed:                bool,
	certificate_requested: bool,
	alpn:                  string,
	peer_alert:            u8,
}

// init prepares a connection. The transport is the caller's and outlives the
// connection; a connection owns nothing of it but the bytes it moves.
init :: proc(transport: Transport, config: Config) -> (connection: ^Conn, err: Error) {
	if transport.read == nil || transport.write == nil { return nil, .Transport }

	allocator := config.allocator
	self, alloc_error := new(Conn, allocator)
	if alloc_error != nil { return nil, .No_Room }
	self.transport = transport
	self.config = config
	self.send, alloc_error = make([]u8, RECORD_HEADER_SIZE + MAX_CIPHERTEXT_RECORD, allocator)
	if alloc_error != nil {
		destroy(self)
		return nil, .No_Room
	}
	self.message, alloc_error = make([]u8, HANDSHAKE_HEADER_SIZE + MAX_SENT_MESSAGE, allocator)
	if alloc_error != nil {
		destroy(self)
		return nil, .No_Room
	}
	self.recv, alloc_error = make([]u8, RECORD_HEADER_SIZE + MAX_CIPHERTEXT_RECORD, allocator)
	if alloc_error != nil {
		destroy(self)
		return nil, .No_Room
	}
	self.stream, alloc_error = make([dynamic]u8, 0, MAX_CIPHERTEXT_RECORD, allocator)
	if alloc_error != nil {
		destroy(self)
		return nil, .No_Room
	}
	return self, .None
}

destroy :: proc(connection: ^Conn) {
	if connection == nil { return }
	allocator := connection.config.allocator
	delete(connection.alpn, allocator)
	delete(connection.send, allocator)
	delete(connection.message, allocator)
	delete(connection.recv, allocator)
	delete(connection.stream)
	free(connection, allocator)
}

// handshake takes the connection through a TLS 1.3 handshake, verifying the peer's
// chain against the configured roots and its identity against `server_name`.
//
// `alpn` is what the caller speaks over TLS. A server that chooses none leaves the
// connection's alpn empty, which the caller may treat as a mismatch.
handshake :: proc(connection: ^Conn, server_name: string, alpn: []string) -> Error {
	suite := OFFERED_SUITES[0]
	connection.suite = suite
	connection.schedule = key_schedule_init(suite)
	hash.init(&connection.transcript, CIPHER_SUITES[suite].hash)

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
	hello_sent, hello_built := client_hello_message(connection, fields)
	if !hello_built { return .No_Room }
	if hello_err := send_message(connection, hello_sent); hello_err != .None { return hello_err }

	hello_message, answer_err := handshake_next(connection)
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
		if hello.version != VERSION_1_3 || hello.pre_shared_key { return fail(connection, .Illegal_Parameter, .Unsupported) }
		if !suite_offered(hello.cipher_suite) { return fail(connection, .Illegal_Parameter, .Unsupported) }
		if !bytes.equal(hello.session_id, session_id[:]) { return fail(connection, .Illegal_Parameter, .Handshake) }
		// A retry that asks for the group this client already sent a share for would not
		// change the second ClientHello, and a retry has to (RFC 8446 section 4.1.4).
		if hello.group == exchange.group { return fail(connection, .Illegal_Parameter, .Unsupported) }
		if !key_exchange_generate(&exchange, hello.group) { return fail(connection, .Illegal_Parameter, .Unsupported) }

		// The retry names the suite the rest of the handshake uses, and the ServerHello
		// must name the same one (RFC 8446 section 4.1.4), so the schedule and the
		// transcript change to it before the first ClientHello is replaced by its hash.
		if hello.cipher_suite != suite {
			suite = hello.cipher_suite
			connection.suite = suite
			connection.schedule = key_schedule_init(suite)
		}

		fields.group = exchange.group
		fields.keyshare = exchange.share[:exchange.length]
		fields.cookie = hello.cookie
		if retry_err := client_hello_retry(connection, fields, hello_sent, hello_message); retry_err != .None { return retry_err }
		change_cipher_spec_sent = true
		retried = true

		hello_message, answer_err = handshake_next(connection)
		if answer_err != .None { return answer_err }
		hello, hello_ok = server_hello_read(hello_message)
		// A second retry leaves this client with nothing to answer.
		if !hello_ok || hello.retry { return fail(connection, .Unexpected_Message, .Handshake) }
	}

	if hello.version != VERSION_1_3 || hello.pre_shared_key { return .Unsupported }
	if !suite_offered(hello.cipher_suite) { return .Unsupported }
	if hello.group != exchange.group || len(hello.keyshare) == 0 { return fail(connection, .Illegal_Parameter, .Unsupported) }
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
		if retried { return fail(connection, .Illegal_Parameter, .Unsupported) }
		suite = hello.cipher_suite
		connection.suite = suite
		connection.schedule = key_schedule_init(suite)
		hash.init(&connection.transcript, CIPHER_SUITES[suite].hash)
		hash.update(&connection.transcript, hello_sent)
	}
	hash.update(&connection.transcript, hello_message)

	shared_secret: [SHARED_SECRET_MAX]u8
	if !key_exchange_shared(&exchange, hello.keyshare, shared_secret[:]) { return .Unsupported }
	// A shared secret of zeros is a small-order peer key, and the protocol refuses
	// the connection rather than derive keys from it (RFC 8446 section 7.4.2).
	if all_zero(shared_secret[:]) { return .Unsupported }

	if !key_schedule_advance(&connection.schedule, shared_secret[:]) { return .Unsupported }
	client_secret, server_secret: Secret
	if !key_schedule_traffic_secrets(&connection.schedule, transcript_hash(connection), &client_secret, &server_secret) {
		return .Unsupported
	}
	connection.read_secret = server_secret
	connection.write_secret = client_secret
	connection.encrypted = true
	if !traffic_key_derive(suite, connection.read_secret[:secret_size(suite)], &connection.read_key) { return .Unsupported }
	if !traffic_key_derive(suite, connection.write_secret[:secret_size(suite)], &connection.write_key) { return .Unsupported }

	if flight_err := handshake_server_flight(connection, server_name, alpn); flight_err != .None { return flight_err }

	// The client's Finished is the last thing the handshake keys protect, and it
	// covers the handshake through the server's Finished. The application secrets
	// cover exactly the same transcript, so it is kept before the client's Finished
	// joins it (RFC 8446 section 7.1).
	application_hash: [MAX_SECRET_SIZE]u8
	digest := transcript_hash(connection)
	copy(application_hash[:], digest)

	// The master secret is extracted from a zero input when no pre-shared key is in
	// play, and needs no transcript.
	zeroes: [MAX_SECRET_SIZE]u8
	if !key_schedule_advance(&connection.schedule, zeroes[:secret_size(suite)]) { return .Unsupported }

	if !change_cipher_spec_sent {
		if change_err := send_change_cipher_spec(connection); change_err != .None { return change_err }
	}
	if connection.certificate_requested {
		if certificate_err := empty_certificate_send(connection); certificate_err != .None { return certificate_err }
	}
	if finished_err := handshake_client_finished(connection); finished_err != .None { return finished_err }

	client_application, server_application: Secret
	if !key_schedule_traffic_secrets(&connection.schedule, application_hash[:len(digest)], &client_application, &server_application) {
		return .Unsupported
	}
	connection.read_secret = server_application
	connection.write_secret = client_application
	if !traffic_key_derive(suite, connection.read_secret[:secret_size(suite)], &connection.read_key) { return .Unsupported }
	if !traffic_key_derive(suite, connection.write_secret[:secret_size(suite)], &connection.write_key) { return .Unsupported }
	return .None
}

// handshake_server_flight reads what the server says once the handshake keys are
// live: its extensions, its chain, its proof of the chain's key, and its Finished,
// in the order the protocol fixes (RFC 8446 section 4.4).
handshake_server_flight :: proc(connection: ^Conn, server_name: string, alpn: []string) -> Error {
	extensions_message, err := handshake_next(connection)
	if err != .None { return err }
	negotiated, extensions_ok := encrypted_extensions_read(extensions_message, server_name != "", alpn)
	if !extensions_ok { return fail(connection, .Decode_Error, .Handshake) }
	if negotiated != "" { connection.alpn = strings.clone(negotiated, connection.config.allocator) }
	hash.update(&connection.transcript, extensions_message)

	certificate_message, certificate_err := handshake_next(connection)
	if certificate_err != .None { return certificate_err }
	certificate_type, _, certificate_decoded := handshake_decode_header(certificate_message)
	if certificate_decoded && certificate_type == .Certificate_Request {
		if !certificate_request_read(certificate_message) { return fail(connection, .Decode_Error, .Handshake) }
		hash.update(&connection.transcript, certificate_message)
		connection.certificate_requested = true
		certificate_message, certificate_err = handshake_next(connection)
		if certificate_err != .None { return certificate_err }
		certificate_type, _, certificate_decoded = handshake_decode_header(certificate_message)
	}
	if !certificate_decoded || certificate_type != .Certificate { return .Handshake }
	chain, chain_decoded := certificate_chain_decode(certificate_message[HANDSHAKE_HEADER_SIZE:], connection.config.allocator)
	defer certificate_chain_destroy(&chain)
	if !chain_decoded { return .Handshake }
	if !chain_verify(chain.certificates, server_name, connection.config) { return .Peer_Rejected }
	hash.update(&connection.transcript, certificate_message)

	verify_message, verify_err := handshake_next(connection)
	if verify_err != .None { return verify_err }
	verify_type, _, verify_decoded := handshake_decode_header(verify_message)
	if !verify_decoded || verify_type != .Certificate_Verify { return .Handshake }
	if !certificate_verify_verify(verify_message[HANDSHAKE_HEADER_SIZE:], &chain.certificates[0], transcript_hash(connection)) {
		return .Signature
	}
	hash.update(&connection.transcript, verify_message)

	finished_message, finished_err := handshake_next(connection)
	if finished_err != .None { return finished_err }
	finished_type, _, finished_decoded := handshake_decode_header(finished_message)
	if !finished_decoded || finished_type != .Finished { return .Handshake }
	size := secret_size(connection.suite)
	if !finished_verify(connection.suite, connection.read_secret[:size], transcript_hash(connection), finished_message[HANDSHAKE_HEADER_SIZE:]) {
		return .Finished
	}
	hash.update(&connection.transcript, finished_message)
	return .None
}

// certificate_request_read validates a main-handshake request. This client has no
// credential to select, but a legal request is answered with an empty Certificate.
certificate_request_read :: proc(message: []u8) -> bool {
	message_type, length, decoded := handshake_decode_header(message)
	if !decoded || message_type != .Certificate_Request || length != len(message) - HANDSHAKE_HEADER_SIZE {
		return false
	}

	body := Reader {
		data = message[HANDSHAKE_HEADER_SIZE:],
		ok   = true,
	}
	request_context := read_section_u8(&body)
	if !request_context.ok || len(request_context.data) != 0 { return false }
	extensions := read_section_u16(&body)
	has_signature_algorithms := false
	for extensions.ok && extensions.at < len(extensions.data) {
		start := extensions.at
		extension_type := Extension_Type(read_u16(&extensions))
		if extension_seen(extensions.data[:start], extension_type) { return false }
		extension := read_section_u16(&extensions)
		if extension_type == .Signature_Algorithms {
			schemes := read_section_u16(&extension)
			if !schemes.ok || len(schemes.data) == 0 || len(schemes.data) % 2 != 0 {
				return false
			}
			has_signature_algorithms = true
		} else {
			extension.at = len(extension.data)
		}
		if !extension.ok || extension.at != len(extension.data) { return false }
	}
	return has_signature_algorithms && body.ok && body.at == len(body.data) && extensions.ok && extensions.at == len(extensions.data)
}

empty_certificate_send :: proc(connection: ^Conn) -> Error {
	message := connection.message[:HANDSHAKE_HEADER_SIZE + 4]
	handshake_encode_header(.Certificate, 4, message)
	mem.zero_slice(message[HANDSHAKE_HEADER_SIZE:])
	return send_message(connection, message)
}

// handshake_client_finished proves the handshake to the server, over the transcript
// that now ends with the server's own Finished.
handshake_client_finished :: proc(connection: ^Conn) -> Error {
	size := secret_size(connection.suite)
	finished := connection.message[:HANDSHAKE_HEADER_SIZE + size]
	handshake_encode_header(.Finished, size, finished)
	finished_key: [MAX_SECRET_SIZE]u8
	if !hkdf_expand_label(connection.suite, connection.write_secret[:size], "finished", {}, finished_key[:size]) {
		return .Unsupported
	}
	hmac.sum(CIPHER_SUITES[connection.suite].hash, finished[HANDSHAKE_HEADER_SIZE:], transcript_hash(connection), finished_key[:size])
	return send_message(connection, finished)
}

// read returns the next bytes of application data, reading a record when it holds
// none. Zero bytes with .None is the end of the stream.
read :: proc(connection: ^Conn, buffer: []u8) -> (count: int, err: Error) {
	for len(connection.payload) == 0 {
		if connection.closed { return 0, .None }
		if post_err := post_handshake_handle(connection); post_err != .None { return 0, post_err }

		content, record_type, read_err := read_record(connection)
		if read_err != .None { return 0, read_err }
		switch record_type {
		case .Application_Data:
			connection.payload = content
		case .Alert:
			return 0, alert_report(connection, content)
		case .Handshake:
			// read_record keeps handshake bytes to itself.
			continue
		case .Change_Cipher_Spec:
			continue
		}
	}

	count = copy(buffer, connection.payload)
	connection.payload = connection.payload[count:]
	return count, .None
}

// write hands the whole buffer to the peer as application data. It counts bytes the
// record layer accepted, which is not evidence that the peer has them.
write :: proc(connection: ^Conn, buffer: []u8) -> (count: int, err: Error) {
	if connection.closed { return 0, .Alert }
	for count < len(buffer) {
		chunk := buffer[count:]
		if len(chunk) > MAX_PLAINTEXT_RECORD { chunk = chunk[:MAX_PLAINTEXT_RECORD] }
		if send_err := send_record(connection, .Application_Data, chunk); send_err != .None { return count, send_err }
		count += len(chunk)
	}
	return count, .None
}

// close sends the close_notify that tells the peer no more records follow. The
// transport is the caller's to close, and closing twice sends nothing.
close :: proc(connection: ^Conn) -> Error {
	if connection.closed { return .None }
	connection.closed = true
	if !connection.encrypted { return .None }

	alert := connection.message[:2]
	alert[0] = u8(Alert_Level.Warning)
	alert[1] = u8(Alert_Description.Close_Notify)
	return send_record(connection, .Alert, alert)
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
client_hello_message :: proc(connection: ^Conn, fields: Client_Hello_Fields) -> (message: []u8, ok: bool) {
	body := connection.message[HANDSHAKE_HEADER_SIZE:]
	body_length, encoded := client_hello_encode(body, fields)
	if !encoded { return nil, false }
	message = connection.message[:HANDSHAKE_HEADER_SIZE + body_length]
	handshake_encode_header(.Client_Hello, body_length, message)
	return message, true
}

// client_hello_retry answers a HelloRetryRequest: the one change cipher spec, then the
// second ClientHello with the key share and the cookie the server asked for, and the
// transcript replaced by the message_hash of the first ClientHello, the retry, and the
// second one (RFC 8446 sections 4.1.4 and 4.4.1). The first ClientHello is hashed
// again here because the retry names the suite, so the transcript's own hash is not it.
client_hello_retry :: proc(connection: ^Conn, fields: Client_Hello_Fields, first: []u8, retry_message: []u8) -> Error {
	suite_hash := CIPHER_SUITES[connection.suite].hash
	hash.init(&connection.transcript, suite_hash)
	hash.update(&connection.transcript, first)
	digest := transcript_hash(connection)

	hash.init(&connection.transcript, suite_hash)
	header: [HANDSHAKE_HEADER_SIZE]u8
	handshake_encode_header(.Message_Hash, len(digest), header[:])
	hash.update(&connection.transcript, header[:])
	hash.update(&connection.transcript, digest)
	hash.update(&connection.transcript, retry_message)

	if change_err := send_change_cipher_spec(connection); change_err != .None { return change_err }
	message, built := client_hello_message(connection, fields)
	if !built { return .No_Room }
	return send_message(connection, message)
}

// CHANGE_CIPHER_SPEC is the body a change cipher spec record carries, which is all
// compatibility mode needs of it (RFC 8446 section D.4).
CHANGE_CIPHER_SPEC :: 1

// send_change_cipher_spec writes the unencrypted change cipher spec record that
// compatibility mode places before this client's second flight. It goes out unencrypted
// even when the handshake keys are live, because a peer that is not reading the handshake
// yet is exactly what it is for.
send_change_cipher_spec :: proc(connection: ^Conn) -> Error {
	body: [1]u8 = {CHANGE_CIPHER_SPEC}
	count, encoded := record_encode(.Change_Cipher_Spec, body[:], connection.send)
	if !encoded { return .No_Room }
	return transport_write(connection, connection.send[:count])
}

// --- records ---

// read_record reads one record and returns what it carried that is not handshake
// bytes. Handshake bytes belong to the handshake stream, and a record that carries
// only a change cipher spec is dropped, which is what a compatibility-mode peer
// sends and what a receiver does without further processing (RFC 8446 section 5).
read_record :: proc(connection: ^Conn) -> (content: []u8, record_type: Record_Type, err: Error) {
	for {
		connection.recv_filled = 0
		if fill_err := recv_fill(connection, RECORD_HEADER_SIZE); fill_err != .None { return nil, {}, fill_err }
		outer_type, length, decoded := record_decode_header(connection.recv[:RECORD_HEADER_SIZE])
		if !decoded { return nil, {}, fail(connection, .Decode_Error, .Record) }
		// A record longer than the protocol allows ends the connection, and the size
		// is what the peer is told (RFC 8446 section 5.2).
		if length > MAX_CIPHERTEXT_RECORD { return nil, {}, fail(connection, .Record_Overflow, .Record) }
		if fill_err := recv_fill(connection, RECORD_HEADER_SIZE + length); fill_err != .None { return nil, {}, fill_err }

		record := connection.recv[:RECORD_HEADER_SIZE + length]
		// Compatibility mode permits only the one-byte change_cipher_spec
		// message. Any other record with that type is malformed.
		if outer_type == .Change_Cipher_Spec {
			if length != 1 || record[RECORD_HEADER_SIZE] != CHANGE_CIPHER_SPEC {
				return nil, {}, fail(connection, .Unexpected_Message, .Record)
			}
			continue
		}

		payload: []u8
		content_type: Record_Type
		if connection.encrypted {
			// Once the handshake keys are live, everything but a change cipher
			// spec is protected, and an unprotected record would be a message
			// anyone could have written.
			if outer_type != .Application_Data { return nil, {}, fail(connection, .Unexpected_Message, .Record) }
			inner, inner_type, opened := record_unprotect(connection.suite, &connection.read_key, record)
			// A record that does not authenticate ends the connection too (RFC 8446
			// section 5.2).
			if !opened { return nil, {}, fail(connection, .Bad_Record_Mac, .Record) }
			payload, content_type = inner, inner_type
		} else {
			decoded_payload, plain_type, plain_decoded := record_decode(record)
			if !plain_decoded { return nil, {}, .Record }
			payload, content_type = decoded_payload, plain_type
		}

		switch content_type {
		case .Handshake:
			// Handshake bytes belong to the handshake stream, and the caller has
			// them to parse now rather than after the next record.
			append(&connection.stream, ..payload)
			return nil, .Handshake, .None
		case .Alert, .Application_Data:
			return payload, content_type, .None
		case .Change_Cipher_Spec:
			return nil, {}, fail(connection, .Unexpected_Message, .Record)
		case:
			return nil, {}, fail(connection, .Unexpected_Message, .Record)
		}
	}
}

// recv_fill reads exactly `count` bytes of the record being read.
recv_fill :: proc(connection: ^Conn, count: int) -> Error {
	for connection.recv_filled < count {
		read, ok := connection.transport.read(connection.transport.user_data, connection.recv[connection.recv_filled:count])
		if !ok || read <= 0 { return .Transport }
		connection.recv_filled += read
	}
	return .None
}

// send_record writes one record, protected once the handshake keys are live, and
// returns what ended the write.
send_record :: proc(connection: ^Conn, record_type: Record_Type, payload: []u8) -> Error {
	count: int
	written: bool
	if connection.encrypted {
		count, written = record_protect(connection.suite, &connection.write_key, record_type, payload, connection.send)
	} else {
		count, written = record_encode(record_type, payload, connection.send)
	}
	if !written { return .No_Room }
	return transport_write(connection, connection.send[:count])
}

transport_write :: proc(connection: ^Conn, data: []u8) -> Error {
	pending := data
	for len(pending) > 0 {
		written, ok := connection.transport.write(connection.transport.user_data, pending)
		if !ok || written <= 0 { return .Transport }
		pending = pending[written:]
	}
	return .None
}

// send_message sends a handshake message that is already built, header included, and
// adds it to the transcript.
send_message :: proc(connection: ^Conn, message: []u8) -> Error {
	hash.update(&connection.transcript, message)
	return send_record(connection, .Handshake, message)
}

// --- the handshake stream ---

// handshake_next returns the next handshake message, reading records until the
// stream holds all of it. A handshake message is not aligned to records, so one
// message can span records and one record can carry several. The message is the
// whole of it, header included, and it stays valid until the next call.
handshake_next :: proc(connection: ^Conn) -> (message: []u8, err: Error) {
	for {
		if available := handshake_available(connection); available != nil { return available, .None }

		content, record_type, read_err := read_record(connection)
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
			// Recording it changes nothing here, since the handshake ends either way.
			_ = alert_report(connection, content)
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
handshake_available :: proc(connection: ^Conn) -> []u8 {
	buffered := connection.stream[connection.stream_at:]
	if len(buffered) >= HANDSHAKE_HEADER_SIZE {
		_, length, decoded := handshake_decode_header(buffered)
		if !decoded { return nil }
		if len(buffered) >= HANDSHAKE_HEADER_SIZE + length {
			message := buffered[:HANDSHAKE_HEADER_SIZE + length]
			connection.stream_at += HANDSHAKE_HEADER_SIZE + length
			if connection.stream_at == len(connection.stream) {
				clear(&connection.stream)
				connection.stream_at = 0
			}
			return message
		}
	}
	return nil
}

// --- answers to what the peer said ---

// fail tells the peer which rule it broke and reports the failure, which is what the
// protocol asks of the side that finds a violation (RFC 8446 section 6.2).
fail :: proc(connection: ^Conn, description: Alert_Description, err: Error) -> Error {
	if connection.closed { return err }
	alert: [2]u8 = {u8(Alert_Level.Fatal), u8(description)}
	// The alert is best effort: the violation is reported whether or not the peer hears it.
	_ = send_record(connection, .Alert, alert[:])
	connection.closed = true
	return err
}

// alert_report records the peer's alert and reports how the connection ended. A
// close_notify is the end of the stream, and anything else is the peer refusing.
alert_report :: proc(connection: ^Conn, content: []u8) -> Error {
	if len(content) < 2 { return .Record }
	connection.peer_alert = content[1]
	connection.closed = true
	if Alert_Description(content[1]) == .Close_Notify {
		return .None
	}
	return .Alert
}

// post_handshake_handle consumes the handshake messages a peer may send after the
// handshake. A new session ticket is not this client's business, since it keeps no
// tickets, and a key update changes the read key (RFC 8446 section 4.6).
post_handshake_handle :: proc(connection: ^Conn) -> Error {
	for {
		message := handshake_available(connection)
		if message == nil { return .None }

		message_type, _, decoded := handshake_decode_header(message)
		if !decoded { return .Handshake }
		#partial switch message_type {
		case .New_Session_Ticket:
		case .Key_Update:
			if len(message) != HANDSHAKE_HEADER_SIZE + 1 {
				return fail(connection, .Decode_Error, .Handshake)
			}
			request := message[HANDSHAKE_HEADER_SIZE]
			if request > 1 { return fail(connection, .Illegal_Parameter, .Handshake) }

			size := secret_size(connection.suite)
			updated: Secret
			if !key_schedule_update(connection.suite, connection.read_secret[:size], updated[:size]) { return .Unsupported }
			connection.read_secret = updated
			if !traffic_key_derive(connection.suite, connection.read_secret[:size], &connection.read_key) { return .Unsupported }

			if request == 1 {
				if update_err := key_update_send(connection); update_err != .None { return update_err }
			}
		case:
			return .Handshake
		}
	}
}

// key_update_send answers a peer's request under the current write key, then advances
// that key before any later application data (RFC 9846 section 4.7.3).
key_update_send :: proc(connection: ^Conn) -> Error {
	message: [HANDSHAKE_HEADER_SIZE + 1]u8
	handshake_encode_header(.Key_Update, 1, message[:])
	message[HANDSHAKE_HEADER_SIZE] = 0
	if send_err := send_record(connection, .Handshake, message[:]); send_err != .None { return send_err }

	size := secret_size(connection.suite)
	updated: Secret
	if !key_schedule_update(connection.suite, connection.write_secret[:size], updated[:size]) { return .Unsupported }
	connection.write_secret = updated
	if !traffic_key_derive(connection.suite, connection.write_secret[:size], &connection.write_key) { return .Unsupported }
	return .None
}

// --- what a connection can say about itself ---

// transcript_hash is the hash of the handshake so far. The running hash stays
// usable, since every message after it extends it. The result is valid until the
// next call.
transcript_hash :: proc(connection: ^Conn) -> []u8 {
	size := hash.digest_size(&connection.transcript)
	hash.final(&connection.transcript, connection.digest[:size], true)
	return connection.digest[:size]
}

// encrypted_extensions_read validates the server's extension responses and returns
// the one application protocol it selected, when it selected one.
encrypted_extensions_read :: proc(message: []u8, server_name_offered: bool, alpn_offered: []string) -> (negotiated: string, ok: bool) {
	message_type, length, decoded := handshake_decode_header(message)
	if !decoded || message_type != .Encrypted_Extensions || length != len(message) - HANDSHAKE_HEADER_SIZE {
		return "", false
	}

	body := Reader {
		data = message[HANDSHAKE_HEADER_SIZE:],
		ok   = true,
	}
	extensions := read_section_u16(&body)
	for extensions.ok && extensions.at < len(extensions.data) {
		start := extensions.at
		extension_type := Extension_Type(read_u16(&extensions))
		if extension_seen(extensions.data[:start], extension_type) { return "", false }
		extension := read_section_u16(&extensions)
		#partial switch extension_type {
		case .Server_Name:
			if !server_name_offered || len(extension.data) != 0 { return "", false }
		case .Supported_Groups:
			groups := read_section_u16(&extension)
			if !groups.ok || len(groups.data) == 0 || len(groups.data) % 2 != 0 { return "", false }
			groups.at = len(groups.data)
		case .Application_Layer_Protocol_Negotiation:
			protocols := read_section_u16(&extension)
			selected := read_bytes(&protocols, int(read_u8(&protocols)))
			if !protocols.ok || len(selected) == 0 || protocols.at != len(protocols.data) {
				return "", false
			}
			negotiated = string(selected)
			matched := false
			for offered in alpn_offered {
				if offered == negotiated {
					matched = true
					break
				}
			}
			if !matched { return "", false }
		case:
			return "", false
		}
		if !extension.ok || extension.at != len(extension.data) { return "", false }
	}
	return negotiated, body.ok && body.at == len(body.data) && extensions.ok && extensions.at == len(extensions.data)
}

// chain_verify checks the peer's chain against the configured anchors, within their
// validity windows, against the identity the connection was reached by, and for the
// purpose a TLS server certificate is used for.
chain_verify :: proc(certificates: []x509.Certificate, server_name: string, config: Config) -> bool {
	if len(certificates) == 0 || len(config.roots) == 0 { return false }

	dns_name := server_name
	if net.parse_address(server_name) != nil {
		if !identity_verify(&certificates[0], server_name) { return false }
		dns_name = ""
	}

	intermediates := certificate_pointers(certificates[1:], config.allocator)
	defer delete(intermediates, config.allocator)
	verified, chain_err := x509.verify_chain(
		&certificates[0],
		{roots = config.roots, intermediates = intermediates, current_time = time.now(), dns_name = dns_name, required_eku = x509.EKU_Bit.Server_Auth},
		config.allocator,
	)
	defer delete(verified, config.allocator)
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
