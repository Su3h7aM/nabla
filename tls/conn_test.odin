#+test
package tls

import "core:bytes"
import "core:testing"

// Fixture answers the first record this connection writes and nothing after it, which is
// what a peer that refuses the handshake does.
Fixture :: struct {
	incoming:         []u8,
	at:               int,
	outgoing:         [dynamic]u8,
	read_fail_after:  int,
	write_fail_after: int,
}

fixture_read :: proc(user_data: rawptr, buffer: []u8) -> (count: int, ok: bool) {
	fixture := cast(^Fixture)user_data
	available := len(fixture.incoming) - fixture.at
	if available <= 0 { return 0, false }
	if fixture.read_fail_after > 0 {
		remaining := fixture.read_fail_after - fixture.at
		if remaining <= 0 { return 0, false }
		available = min(available, remaining)
	}
	count = min(available, len(buffer))
	copy(buffer, fixture.incoming[fixture.at:fixture.at + count])
	fixture.at += count
	return count, true
}

fixture_write :: proc(user_data: rawptr, buffer: []u8) -> (count: int, ok: bool) {
	fixture := cast(^Fixture)user_data
	count = len(buffer)
	if fixture.write_fail_after > 0 {
		remaining := fixture.write_fail_after - len(fixture.outgoing)
		if remaining <= 0 { return 0, false }
		count = min(count, remaining)
	}
	append(&fixture.outgoing, ..buffer[:count])
	return count, true
}

@(test)
test_an_empty_server_name_is_rejected_before_the_client_hello :: proc(t: ^testing.T) {
	fixture: Fixture
	defer delete(fixture.outgoing)
	connection, init_err := init({read = fixture_read, write = fixture_write, user_data = &fixture}, {allocator = context.allocator})
	if !testing.expect(t, init_err == .None, "a connection could not be prepared") { return }
	defer destroy(connection)

	testing.expect_value(t, handshake(connection, "", nil), Error.Invalid_Identity)
	testing.expect_value(t, len(fixture.outgoing), 0)
	testing.expect_value(t, fixture.at, 0)
}

// A peer that answers with an alert ends the handshake, and the client reports the alert
// rather than reading what is left as if it were a handshake message. A fatal alert is
// RFC 8446 section 6.2 and a close_notify in the middle of a handshake is section 6.1.
@(test)
test_a_peer_that_refuses_the_handshake_is_reported :: proc(t: ^testing.T) {
	// The two records a refusing peer sends, each a complete alert of its own: a fatal
	// handshake_failure, and a close_notify with no reason in it.
	REFUSALS := [2][]u8{{21, 3, 3, 0, 2, 2, 40}, {21, 3, 3, 0, 2, 1, 0}}
	for refusal in REFUSALS {
		fixture := Fixture {
			incoming = refusal,
		}
		defer delete(fixture.outgoing)
		connection, init_err := init({read = fixture_read, write = fixture_write, user_data = &fixture}, {allocator = context.allocator})
		if !testing.expect(t, init_err == .None, "a connection could not be prepared") { return }
		defer destroy(connection)

		testing.expect_value(t, handshake(connection, "example.com", nil), Error.Alert)
		testing.expect_value(t, connection.peer_alert, refusal[len(refusal) - 1])
		testing.expect(t, len(fixture.outgoing) > 0, "the client sent no ClientHello")
	}
}

// A record the protocol does not allow is answered with the alert that names it, so the
// peer learns which rule it broke rather than seeing a bare close (RFC 8446 section 5.2).
@(test)
test_a_record_over_the_protocol_limit_is_refused_with_an_alert :: proc(t: ^testing.T) {
	// The record header alone: an application data record claiming more than a record may
	// hold.
	overflow := []u8{23, 3, 3, 0x41, 0x01}
	fixture := Fixture {
		incoming = overflow,
	}
	defer delete(fixture.outgoing)

	connection, init_err := init({read = fixture_read, write = fixture_write, user_data = &fixture}, {allocator = context.allocator})
	if !testing.expect(t, init_err == .None, "a connection could not be prepared") { return }
	defer destroy(connection)

	testing.expect_value(t, handshake(connection, "example.com", nil), Error.Record)

	// Whatever was written ends with the fatal record_overflow alert, which is 22.
	written := fixture.outgoing[:]
	tail := written[len(written) - 7:]
	expect_bytes(t, "the alert that ends the connection", tail, []u8{21, 3, 3, 0, 2, u8(Alert_Level.Fatal), u8(Alert_Description.Record_Overflow)})
}

@(test)
test_a_malformed_change_cipher_spec_is_refused :: proc(t: ^testing.T) {
	fixture := Fixture {
		incoming = []u8{u8(Record_Type.Change_Cipher_Spec), 3, 3, 0, 1, 2},
	}
	defer delete(fixture.outgoing)
	connection, init_err := init({read = fixture_read, write = fixture_write, user_data = &fixture}, {allocator = context.allocator})
	if !testing.expect(t, init_err == .None, "a connection could not be prepared") { return }
	defer destroy(connection)

	testing.expect_value(t, handshake(connection, "example.com", nil), Error.Record)
	written := fixture.outgoing[:]
	tail := written[len(written) - 7:]
	expect_bytes(t, "unexpected message alert", tail, []u8{21, 3, 3, 0, 2, u8(Alert_Level.Fatal), u8(Alert_Description.Unexpected_Message)})
}

@(test)
test_a_change_cipher_spec_after_the_server_finished_is_refused :: proc(t: ^testing.T) {
	fixture := Fixture {
		incoming = []u8{u8(Record_Type.Change_Cipher_Spec), 3, 3, 0, 1, CHANGE_CIPHER_SPEC},
	}
	defer delete(fixture.outgoing)
	connection, init_err := init({read = fixture_read, write = fixture_write, user_data = &fixture}, {allocator = context.allocator})
	if !testing.expect(t, init_err == .None, "a connection could not be prepared") { return }
	defer destroy(connection)
	connection.client_hello_sent = true
	connection.server_finished_received = true

	_, _, read_err := read_record(connection)
	testing.expect_value(t, read_err, Error.Record)
	written := fixture.outgoing[:]
	tail := written[len(written) - 7:]
	expect_bytes(t, "unexpected message alert", tail, []u8{21, 3, 3, 0, 2, u8(Alert_Level.Fatal), u8(Alert_Description.Unexpected_Message)})
}

@(test)
test_a_change_cipher_spec_is_accepted_after_the_client_hello_before_server_finished :: proc(t: ^testing.T) {
	fixture := Fixture {
		incoming = []u8 {
			u8(Record_Type.Change_Cipher_Spec),
			3,
			3,
			0,
			1,
			CHANGE_CIPHER_SPEC,
			u8(Record_Type.Handshake),
			3,
			3,
			0,
			4,
			u8(Handshake_Type.Finished),
			0,
			0,
			0,
		},
	}
	defer delete(fixture.outgoing)
	connection, init_err := init({read = fixture_read, write = fixture_write, user_data = &fixture}, {allocator = context.allocator})
	if !testing.expect(t, init_err == .None, "a connection could not be prepared") { return }
	defer destroy(connection)
	connection.client_hello_sent = true

	_, record_type, read_err := read_record(connection)
	testing.expect_value(t, read_err, Error.None)
	testing.expect_value(t, record_type, Record_Type.Handshake)
	testing.expect(t, !connection.server_finished_received, "the fixture marked the server Finished as received")
}

@(test)
test_transport_failure_mid_record_latches_the_connection :: proc(t: ^testing.T) {
	fixture := Fixture {
		incoming        = []u8{u8(Record_Type.Application_Data), 3, 3, 0, 1, 'x'},
		read_fail_after = RECORD_HEADER_SIZE,
	}
	defer delete(fixture.outgoing)
	connection, init_err := init({read = fixture_read, write = fixture_write, user_data = &fixture}, {allocator = context.allocator})
	if !testing.expect(t, init_err == .None, "a connection could not be prepared") { return }
	defer destroy(connection)

	_, _, read_err := read_record(connection)
	testing.expect_value(t, read_err, Error.Transport)
	testing.expect(t, connection.transport_failed, "the interrupted record did not fail the connection")

	fixture.read_fail_after = 0
	buffer: [1]u8
	count, repeated_err := read(connection, buffer[:])
	testing.expect_value(t, count, 0)
	testing.expect_value(t, repeated_err, Error.Transport)
	testing.expect_value(t, fixture.at, RECORD_HEADER_SIZE)
}

@(test)
test_transport_failure_mid_write_latches_the_connection :: proc(t: ^testing.T) {
	fixture := Fixture {
		write_fail_after = 3,
	}
	defer delete(fixture.outgoing)
	connection, init_err := init({read = fixture_read, write = fixture_write, user_data = &fixture}, {allocator = context.allocator})
	if !testing.expect(t, init_err == .None, "a connection could not be prepared") { return }
	defer destroy(connection)

	count, write_err := write(connection, []u8{'x'})
	testing.expect_value(t, count, 0)
	testing.expect_value(t, write_err, Error.Transport)
	testing.expect(t, connection.transport_failed, "the incomplete record did not fail the connection")
	written := len(fixture.outgoing)

	fixture.write_fail_after = 0
	repeated_count, repeated_err := write(connection, []u8{'x'})
	testing.expect_value(t, repeated_count, 0)
	testing.expect_value(t, repeated_err, Error.Transport)
	testing.expect_value(t, len(fixture.outgoing), written)
}

@(test)
test_a_main_handshake_certificate_request_can_be_answered_empty :: proc(t: ^testing.T) {
	request := []u8{u8(Handshake_Type.Certificate_Request), 0, 0, 11, 0, 0, 8, 0, 13, 0, 4, 0, 2, 4, 3}
	testing.expect(t, certificate_request_read(request), "a legal CertificateRequest was refused")

	without_signature_algorithms := []u8{u8(Handshake_Type.Certificate_Request), 0, 0, 3, 0, 0, 0}
	testing.expect(t, !certificate_request_read(without_signature_algorithms), "a CertificateRequest without signature algorithms was accepted")
}

@(test)
test_encrypted_extensions_select_one_offered_protocol :: proc(t: ^testing.T) {
	message := []u8{u8(Handshake_Type.Encrypted_Extensions), 0, 0, 11, 0, 9, 0, 16, 0, 5, 0, 3, 2, 'h', '2'}
	selected, ok := encrypted_extensions_read(message, false, []string{"h2"})
	testing.expect(t, ok, "an offered ALPN selection was refused")
	testing.expect_value(t, selected, "h2")

	_, unsolicited := encrypted_extensions_read(message, false, []string{"http/1.1"})
	testing.expect(t, !unsolicited, "an ALPN protocol the client did not offer was accepted")

	server_name_ack := []u8{u8(Handshake_Type.Encrypted_Extensions), 0, 0, 6, 0, 4, 0, 0, 0, 0}
	_, unsolicited_server_name := encrypted_extensions_read(server_name_ack, false, nil)
	testing.expect(t, !unsolicited_server_name, "a server acknowledged SNI the client did not send")
}

@(test)
test_peer_close_notify_closes_only_the_read_side :: proc(t: ^testing.T) {
	fixture: Fixture
	defer delete(fixture.outgoing)
	connection, init_err := init({read = fixture_read, write = fixture_write, user_data = &fixture}, {allocator = context.allocator})
	if !testing.expect(t, init_err == .None, "a connection could not be prepared") { return }
	defer destroy(connection)

	connection.suite = .AES_128_GCM_SHA256
	connection.encrypted = true
	for &octet, index in connection.read_secret { octet = u8(index) }
	for &octet, index in connection.write_secret { octet = u8(index + 32) }
	if !testing.expect(t, traffic_key_derive(connection.suite, connection.read_secret[:32], &connection.read_key)) { return }
	if !testing.expect(t, traffic_key_derive(connection.suite, connection.write_secret[:32], &connection.write_key)) { return }

	peer_key := connection.read_key
	peer_record: [RECORD_HEADER_SIZE + MAX_CIPHERTEXT_RECORD]u8
	peer_alert := []u8{u8(Alert_Level.Warning), u8(Alert_Description.Close_Notify)}
	peer_record_length, protected := record_protect(connection.suite, &peer_key, .Alert, peer_alert, peer_record[:])
	if !testing.expect(t, protected) { return }
	fixture.incoming = peer_record[:peer_record_length]

	buffer: [16]u8
	initial_read_count, read_err := read(connection, buffer[:])
	testing.expect_value(t, initial_read_count, 0)
	testing.expect_value(t, read_err, Error.None)
	testing.expect(t, connection.read_closed, "the peer close_notify did not close the read side")
	testing.expect(t, !connection.write_closed, "the peer close_notify closed the write side")
	repeated_read_count, repeated_read_err := read(connection, buffer[:])
	testing.expect_value(t, repeated_read_count, 0)
	testing.expect_value(t, repeated_read_err, Error.None)

	client_key := connection.write_key
	write_count, write_err := write(connection, []u8{'x'})
	testing.expect_value(t, write_count, 1)
	testing.expect_value(t, write_err, Error.None)
	testing.expect_value(t, close(connection), Error.None)
	written := len(fixture.outgoing)
	testing.expect_value(t, close(connection), Error.None)
	testing.expect_value(t, len(fixture.outgoing), written)

	_, first_length, first_decoded := record_decode_header(fixture.outgoing[:RECORD_HEADER_SIZE])
	if !testing.expect(t, first_decoded, "the application record was not encoded") { return }
	first_record_length := RECORD_HEADER_SIZE + first_length
	content, content_type, opened := record_unprotect(connection.suite, &client_key, fixture.outgoing[:first_record_length])
	if !testing.expect(t, opened, "the application record could not be opened") { return }
	testing.expect_value(t, content_type, Record_Type.Application_Data)
	expect_bytes(t, "application data after peer close_notify", content, []u8{'x'})

	_, close_length, close_decoded := record_decode_header(fixture.outgoing[first_record_length:])
	if !testing.expect(t, close_decoded, "the local close_notify was not encoded") { return }
	close_record := fixture.outgoing[first_record_length:first_record_length + RECORD_HEADER_SIZE + close_length]
	content, content_type, opened = record_unprotect(connection.suite, &client_key, close_record)
	if !testing.expect(t, opened, "the local close_notify could not be opened") { return }
	testing.expect_value(t, content_type, Record_Type.Alert)
	expect_bytes(t, "local close_notify", content, []u8{u8(Alert_Level.Warning), u8(Alert_Description.Close_Notify)})
}

@(test)
test_a_requested_key_update_is_answered_before_the_write_key_changes :: proc(t: ^testing.T) {
	fixture: Fixture
	defer delete(fixture.outgoing)
	connection, init_err := init({read = fixture_read, write = fixture_write, user_data = &fixture}, {allocator = context.allocator})
	if !testing.expect(t, init_err == .None, "a connection could not be prepared") { return }
	defer destroy(connection)

	connection.suite = .AES_128_GCM_SHA256
	connection.encrypted = true
	for index in 0 ..< 32 {
		connection.read_secret[index] = u8(index)
		connection.write_secret[index] = u8(index + 32)
	}
	if !testing.expect(t, traffic_key_derive(connection.suite, connection.read_secret[:32], &connection.read_key)) { return }
	if !testing.expect(t, traffic_key_derive(connection.suite, connection.write_secret[:32], &connection.write_key)) { return }
	old_write_key := connection.write_key
	old_write_secret := connection.write_secret

	request: [HANDSHAKE_HEADER_SIZE + 1]u8
	handshake_encode_header(.Key_Update, 1, request[:])
	request[HANDSHAKE_HEADER_SIZE] = 1
	append(&connection.stream, ..request[:])

	if !testing.expect_value(t, post_handshake_handle(connection), Error.None) { return }
	response_key := old_write_key
	response, response_type, opened := record_unprotect(connection.suite, &response_key, fixture.outgoing[:])
	if !testing.expect(t, opened, "the key update response was not protected with the old write key") { return }
	testing.expect_value(t, response_type, Record_Type.Handshake)
	expect_bytes(t, "key update response", response, []u8{u8(Handshake_Type.Key_Update), 0, 0, 1, 0})
	testing.expect(t, !bytes.equal(connection.write_secret[:32], old_write_secret[:32]), "the write secret did not advance")
	testing.expect_value(t, connection.write_key.sequence, u64(0))
}
