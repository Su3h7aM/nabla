#+test
package tls

import "core:testing"

// Fixture answers the first record this connection writes and nothing after it, which is
// what a peer that refuses the handshake does.
Fixture :: struct {
	incoming: []u8,
	at:       int,
	outgoing: int,
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
	fixture.outgoing += len(buffer)
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
		conn, init_err := init(
			{read = fixture_read, write = fixture_write, user_data = &fixture},
			{allocator = context.allocator},
		)
		if !testing.expect(t, init_err == .None, "a connection could not be prepared") { return }
		defer destroy(conn)

		testing.expect_value(t, handshake(conn, "example.com", nil), Error.Alert)
		testing.expect_value(t, conn.peer_alert, refusal[len(refusal) - 1])
		testing.expect(t, fixture.outgoing > 0, "the client sent no ClientHello")
	}
}
