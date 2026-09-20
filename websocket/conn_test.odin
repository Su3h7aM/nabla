#+test
package websocket

import "core:mem"
import "core:testing"

// A connection is driven byte for byte: what a server would send is a buffer, and what
// the connection sends back is kept, so a test states the frames rather than a socket
// fixture.
Fixture :: struct {
	incoming: []u8,
	at:       int,
	outgoing: [dynamic]u8,
	released: int,
	aborted:  int,
}

fixture_read :: proc(user_data: rawptr, buffer: []u8) -> (count: int, err: Error) {
	fixture := cast(^Fixture)user_data
	available := len(fixture.incoming) - fixture.at
	if available <= 0 { return 0, .Closed }
	count = min(available, len(buffer))
	copy(buffer, fixture.incoming[fixture.at:fixture.at + count])
	fixture.at += count
	return count, .None
}

fixture_write :: proc(user_data: rawptr, buffer: []u8) -> (count: int, err: Error) {
	fixture := cast(^Fixture)user_data
	append(&fixture.outgoing, ..buffer)
	return len(buffer), .None
}

fixture_release :: proc(user_data: rawptr) {
	fixture := cast(^Fixture)user_data
	fixture.released += 1
}

fixture_abort :: proc(user_data: rawptr) {
	fixture := cast(^Fixture)user_data
	fixture.aborted += 1
}

fixture_conn :: proc(t: ^testing.T, fixture: ^Fixture, incoming: []u8) -> ^Conn {
	fixture.incoming = incoming
	conn, err := init(
		{read = fixture_read, write = fixture_write, release = fixture_release, abort = fixture_abort, user_data = fixture},
		context.temp_allocator,
	)
	if !testing.expect(t, err == .None, "a connection could not be prepared") { return nil }
	return conn
}

@(test)
test_stream_end_without_a_close_frame_is_abnormal :: proc(t: ^testing.T) {
	fixture: Fixture
	conn := fixture_conn(t, &fixture, nil)
	if conn == nil { return }
	buffer: [8]u8
	_, _, _, err := read(conn, buffer[:])
	testing.expect_value(t, err, Error.Abnormal_Closure)
	destroy(conn)
	testing.expect_value(t, fixture.released, 1)
	testing.expect_value(t, fixture.aborted, 0)
}

@(test)
test_abort_uses_nonblocking_transport_teardown :: proc(t: ^testing.T) {
	fixture: Fixture
	conn := fixture_conn(t, &fixture, nil)
	if conn == nil { return }
	abort(conn)
	testing.expect_value(t, fixture.released, 0)
	testing.expect_value(t, fixture.aborted, 1)
}

// A server's frames carry no mask, so what it sends is what the protocol says it may
// send.
@(test)
test_fragmented_message_with_a_ping_between_the_fragments :: proc(t: ^testing.T) {
	fixture: Fixture
	defer delete(fixture.outgoing)
	incoming := []u8 {
		// A text message that does not end yet: 0x01 0x03 "Hel".
		0x01,
		0x03,
		0x48,
		0x65,
		0x6c,
		// A ping between the fragments, whose body the client echoes.
		0x89,
		0x05,
		0x48,
		0x65,
		0x6c,
		0x6c,
		0x6f,
		// The rest of the message: 0x80 0x02 "lo".
		0x80,
		0x02,
		0x6c,
		0x6f,
		// An orderly close, with code 1000.
		0x88,
		0x02,
		0x03,
		0xe8,
	}
	conn := fixture_conn(t, &fixture, incoming)
	if conn == nil { return }
	defer destroy(conn)

	buffer: [64]u8
	count, opcode, complete, err := read(conn, buffer[:])
	if !testing.expect(t, err == .None, "the first fragment could not be read") { return }
	testing.expect_value(t, string(buffer[:count]), "Hel")
	testing.expect_value(t, opcode, Opcode.Text)
	testing.expect(t, !complete, "the message ended at its first fragment")

	count, opcode, complete, err = read(conn, buffer[:])
	if !testing.expect(t, err == .None, "the last fragment could not be read") { return }
	testing.expect_value(t, string(buffer[:count]), "lo")
	testing.expect_value(t, opcode, Opcode.Text)
	testing.expect(t, complete, "the message did not end at its last fragment")

	// The ping was answered before the rest of the message was handed over, so the
	// reply is the first thing on the wire.
	pong, pong_header, pong_read := outgoing_frame(fixture.outgoing[:])
	if !testing.expect(t, pong_read, "the client did not answer the ping") { return }
	testing.expect_value(t, pong_header.opcode, Opcode.Pong)
	testing.expect(t, pong_header.masked, "a client frame is masked")
	testing.expect_value(t, string(pong), "Hello")

	count, _, _, err = read(conn, buffer[:])
	testing.expect(t, err == .Closed, "the close frame did not end the stream")
	testing.expect_value(t, count, 0)
	testing.expect_value(t, conn.close_code, Close_Code.Normal)

	// The close was echoed, which is what both ends agreeing the connection is over
	// means (RFC 6455 section 5.5.1).
	_, close_header, close_read := outgoing_frame(fixture.outgoing[pong_header.header_length + len(pong):])
	testing.expect(t, close_read, "the client did not answer the close")
	testing.expect_value(t, close_header.opcode, Opcode.Close)
}

@(test)
test_frames_a_server_may_not_send :: proc(t: ^testing.T) {
	// A masked frame: a client must close the connection when it sees one (RFC 6455
	// section 5.3).
	fixture: Fixture
	defer delete(fixture.outgoing)
	conn := fixture_conn(t, &fixture, []u8{0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58})
	if conn == nil { return }
	buffer: [64]u8
	_, _, _, masked_err := read(conn, buffer[:])
	testing.expect_value(t, masked_err, Error.Protocol)
	testing.expect(t, close_code_sent(fixture.outgoing[:]) == Close_Code.Protocol_Error, "the close did not name the protocol error")
	destroy(conn)

	// A control frame whose payload does not fit in one frame: 0x89 0x7e 0x0100
	// followed by the octets it claims (RFC 6455 section 5.5).
	clear(&fixture.outgoing)
	fixture.at = 0
	conn = fixture_conn(t, &fixture, []u8{0x89, 0x7e, 0x01, 0x00})
	if conn == nil { return }
	_, _, _, large_err := read(conn, buffer[:])
	testing.expect_value(t, large_err, Error.Protocol)
	testing.expect(t, close_code_sent(fixture.outgoing[:]) == Close_Code.Protocol_Error, "the close did not name the protocol error")
	destroy(conn)

	// A text message that is not UTF-8: 0x81 0x01 0xff.
	clear(&fixture.outgoing)
	fixture.at = 0
	conn = fixture_conn(t, &fixture, []u8{0x81, 0x01, 0xff})
	if conn == nil { return }
	_, _, _, text_err := read(conn, buffer[:])
	testing.expect_value(t, text_err, Error.Protocol)
	testing.expect(t, close_code_sent(fixture.outgoing[:]) == Close_Code.Invalid_Payload, "the close did not name the invalid payload")
	destroy(conn)
}

@(test)
test_empty_text_and_replacement_character_messages :: proc(t: ^testing.T) {
	fixture: Fixture
	defer delete(fixture.outgoing)
	conn := fixture_conn(t, &fixture, []u8{0x81, 0x00, 0x81, 0x03, 0xef, 0xbf, 0xbd})
	if conn == nil { return }
	defer destroy(conn)

	buffer: [8]u8
	count, opcode, complete, err := read(conn, buffer[:])
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, count, 0)
	testing.expect_value(t, opcode, Opcode.Text)
	testing.expect(t, complete, "the empty message did not complete")

	count, opcode, complete, err = read(conn, buffer[:])
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, opcode, Opcode.Text)
	testing.expect(t, complete, "the replacement-character message did not complete")
	testing.expect(t, mem.compare(buffer[:count], []u8{0xef, 0xbf, 0xbd}) == 0, "the replacement character changed")
}

@(test)
test_invalid_outgoing_text_is_never_sent :: proc(t: ^testing.T) {
	// RFC 6455 5.6: what this endpoint sends as text is valid UTF-8. The
	// whole message is checked before its first frame, so a refusal sends
	// nothing and the connection stays usable.
	fixture: Fixture
	defer delete(fixture.outgoing)
	conn := fixture_conn(t, &fixture, nil)
	if conn == nil { return }
	defer destroy(conn)

	testing.expect_value(t, write(conn, .Text, []u8{0xff}), Error.Protocol)
	testing.expect_value(t, len(fixture.outgoing), 0)
	testing.expect_value(t, write(conn, .Text, transmute([]u8)string("valid")), Error.None)
	testing.expect(t, len(fixture.outgoing) > 0, "valid text was not sent")
	clear(&fixture.outgoing)
	testing.expect_value(t, write(conn, .Binary, []u8{0xff}), Error.None)
	testing.expect(t, len(fixture.outgoing) > 0, "binary was refused for its bytes")
	testing.expect_value(t, write(conn, .Text, nil), Error.None)
	testing.expect_value(t, write(nil, .Text, transmute([]u8)string("hi")), Error.Protocol)
}

@(test)
test_invalid_close_payloads_are_not_echoed :: proc(t: ^testing.T) {
	Cases := []struct {
		frame: []u8,
		code:  Close_Code,
	}{{[]u8{0x88, 0x01, 0x00}, .Protocol_Error}, {[]u8{0x88, 0x02, 0x03, 0xed}, .Protocol_Error}, {[]u8{0x88, 0x03, 0x03, 0xe8, 0xff}, .Invalid_Payload}}
	for test_case in Cases {
		fixture: Fixture
		conn := fixture_conn(t, &fixture, test_case.frame)
		if conn == nil { continue }
		buffer: [8]u8
		_, _, _, err := read(conn, buffer[:])
		testing.expect_value(t, err, Error.Protocol)
		testing.expect_value(t, close_code_sent(fixture.outgoing[:]), test_case.code)
		destroy(conn)
		delete(fixture.outgoing)
	}
}

@(test)
test_local_close_input_is_checked_before_the_control_buffer_is_sliced :: proc(t: ^testing.T) {
	fixture: Fixture
	conn := fixture_conn(t, &fixture, nil)
	if conn == nil { return }
	defer destroy(conn)
	defer delete(fixture.outgoing)

	reason := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	testing.expect_value(t, len(reason), 124)
	testing.expect_value(t, close(conn, .Normal, reason, nil), Error.Protocol)
	testing.expect_value(t, len(fixture.outgoing), 0)
}

// A message larger than one frame is fragmented, and every frame carries a mask of
// its own, which is what a client must do (RFC 6455 section 5.3).
@(test)
test_a_large_message_is_fragmented_into_masked_frames :: proc(t: ^testing.T) {
	fixture: Fixture
	defer delete(fixture.outgoing)
	conn := fixture_conn(t, &fixture, nil)
	if conn == nil { return }
	defer destroy(conn)

	message := make([]u8, 2 * SEND_CHUNK + 100)
	defer delete(message)
	// Valid UTF-8: cycling letters, with one three-byte rune straddling the
	// first frame boundary, which whole-message validation accepts.
	for i in 0 ..< len(message) { message[i] = 'a' + u8(i % 26) }
	message[SEND_CHUNK - 1] = 0xe2
	message[SEND_CHUNK] = 0x82
	message[SEND_CHUNK + 1] = 0xac

	if !testing.expect(t, write(conn, .Text, message) == .None, "the message could not be written") { return }

	Expected :: struct {
		opcode: Opcode,
		length: int,
		final:  bool,
	}
	remaining := fixture.outgoing[:]
	at := 0
	for want in ([]Expected{{.Text, SEND_CHUNK, false}, {.Continuation, SEND_CHUNK, false}, {.Continuation, 100, true}}) {
		payload, header, ok := outgoing_frame(remaining)
		if !testing.expect(t, ok, "a frame was not encoded") { return }
		testing.expect_value(t, header.opcode, want.opcode)
		testing.expect_value(t, header.length, want.length)
		testing.expect_value(t, header.final, want.final)
		testing.expect(t, header.masked, "a client frame is masked")
		testing.expect(t, mem.compare(payload, message[at:at + want.length]) == 0, "the payload is not the message's octets")
		at += want.length
		remaining = remaining[header.header_length + header.length:]
	}
	testing.expect_value(t, len(remaining), 0)
}

// outgoing_frame decodes the frame at the front of what the connection wrote, so a test
// can assert on a reply without knowing the masking key it chose.
@(private)
outgoing_frame :: proc(data: []u8) -> (payload: []u8, header: Header, ok: bool) {
	decoded_header, decoded := frame_header_decode(data)
	if !decoded || len(data) < decoded_header.header_length + decoded_header.length { return nil, {}, false }
	payload = data[decoded_header.header_length:decoded_header.header_length + decoded_header.length]
	if decoded_header.masked { frame_mask(payload, decoded_header.mask) }
	return payload, decoded_header, true
}

// close_code_sent reads the code out of a close frame the connection wrote.
@(private)
close_code_sent :: proc(data: []u8) -> Close_Code {
	payload, header, ok := outgoing_frame(data)
	if !ok || header.opcode != .Close || len(payload) < 2 { return Close_Code(0) }
	return Close_Code(u16(payload[0]) << 8 | u16(payload[1]))
}
