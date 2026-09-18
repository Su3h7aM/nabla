#+test
package tls

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
	REFUSALS := [2][]u8 {
		{21, 3, 3, 0, 2, 2, 40},
		{21, 3, 3, 0, 2, 1, 0},
	}
	for refusal in REFUSALS {
		fixture := Fixture{incoming = refusal}
		defer delete(fixture.outgoing)
		conn, init_err := init(
			{read = fixture_read, write = fixture_write, user_data = &fixture},
			{allocator = context.allocator},
		)
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
	fixture := Fixture{incoming = overflow}
	defer delete(fixture.outgoing)

	conn, init_err := init(
		{read = fixture_read, write = fixture_write, user_data = &fixture},
		{allocator = context.allocator},
	)
	if !testing.expect(t, init_err == .None, "a connection could not be prepared") { return }
	defer destroy(conn)

	testing.expect_value(t, handshake(conn, "example.com", nil), Error.Record)

	// Whatever was written ends with the fatal record_overflow alert, which is 22.
	written := fixture.outgoing[:]
	tail := written[len(written) - 7:]
	expect_bytes(t, "the alert that ends the connection", tail, []u8{21, 3, 3, 0, 2, u8(Alert_Level.Fatal), u8(Alert_Description.Record_Overflow)})
}
