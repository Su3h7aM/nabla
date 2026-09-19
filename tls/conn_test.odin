#+test
package tls

import "core:bytes"
import "core:testing"

// Fixture answers the first record this connection writes and nothing after it, which is
// what a peer that refuses the handshake does.
Fixture :: struct {
	incoming: []u8,
	at:       int,
	outgoing: [dynamic]u8,
}

fixture_read :: proc(user_data: rawptr, buffer: []u8) -> (count: int, ok: bool) {
	fixture := cast(^Fixture)user_data
	available := len(fixture.incoming) - fixture.at
	if available <= 0 { return 0, false }
	count = min(available, len(buffer))
	copy(buffer, fixture.incoming[fixture.at:fixture.at + count])
	fixture.at += count
	return count, true
}

fixture_write :: proc(user_data: rawptr, buffer: []u8) -> (count: int, ok: bool) {
	fixture := cast(^Fixture)user_data
	append(&fixture.outgoing, ..buffer)
	return len(buffer), true
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
		conn, init_err := init({read = fixture_read, write = fixture_write, user_data = &fixture}, {allocator = context.allocator})
		if !testing.expect(t, init_err == .None, "a connection could not be prepared") { return }
		defer destroy(conn)

		testing.expect_value(t, handshake(conn, "example.com", nil), Error.Alert)
		testing.expect_value(t, conn.peer_alert, refusal[len(refusal) - 1])
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

	conn, init_err := init({read = fixture_read, write = fixture_write, user_data = &fixture}, {allocator = context.allocator})
	if !testing.expect(t, init_err == .None, "a connection could not be prepared") { return }
	defer destroy(conn)

	testing.expect_value(t, handshake(conn, "example.com", nil), Error.Record)

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
	conn, init_err := init({read = fixture_read, write = fixture_write, user_data = &fixture}, {allocator = context.allocator})
	if !testing.expect(t, init_err == .None, "a connection could not be prepared") { return }
	defer destroy(conn)

	testing.expect_value(t, handshake(conn, "example.com", nil), Error.Record)
	written := fixture.outgoing[:]
	tail := written[len(written) - 7:]
	expect_bytes(t, "unexpected message alert", tail, []u8{21, 3, 3, 0, 2, u8(Alert_Level.Fatal), u8(Alert_Description.Unexpected_Message)})
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
}

@(test)
test_a_requested_key_update_is_answered_before_the_write_key_changes :: proc(t: ^testing.T) {
	fixture: Fixture
	defer delete(fixture.outgoing)
	conn, init_err := init({read = fixture_read, write = fixture_write, user_data = &fixture}, {allocator = context.allocator})
	if !testing.expect(t, init_err == .None, "a connection could not be prepared") { return }
	defer destroy(conn)

	conn.suite = .AES_128_GCM_SHA256
	conn.encrypted = true
	for index in 0 ..< 32 {
		conn.read_secret[index] = u8(index)
		conn.write_secret[index] = u8(index + 32)
	}
	if !testing.expect(t, traffic_key_derive(conn.suite, conn.read_secret[:32], &conn.read_key)) { return }
	if !testing.expect(t, traffic_key_derive(conn.suite, conn.write_secret[:32], &conn.write_key)) { return }
	old_write_key := conn.write_key
	old_write_secret := conn.write_secret

	request: [HANDSHAKE_HEADER_SIZE + 1]u8
	handshake_encode_header(.Key_Update, 1, request[:])
	request[HANDSHAKE_HEADER_SIZE] = 1
	append(&conn.stream, ..request[:])

	if !testing.expect_value(t, post_handshake_handle(conn), Error.None) { return }
	response_key := old_write_key
	response, response_type, opened := record_unprotect(conn.suite, &response_key, fixture.outgoing[:])
	if !testing.expect(t, opened, "the key update response was not protected with the old write key") { return }
	testing.expect_value(t, response_type, Record_Type.Handshake)
	expect_bytes(t, "key update response", response, []u8{u8(Handshake_Type.Key_Update), 0, 0, 1, 0})
	testing.expect(t, !bytes.equal(conn.write_secret[:32], old_write_secret[:32]), "the write secret did not advance")
	testing.expect_value(t, conn.write_key.sequence, u64(0))
}
