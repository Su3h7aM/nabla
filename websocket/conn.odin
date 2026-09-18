package websocket

import "core:crypto"
import "core:mem"
import "core:unicode/utf8"

// Transport is how a connection reaches its peer. Both calls block until they moved
// bytes, or the caller ended the wait: a read that moved none reports why, so a
// cancellation or a deadline is never mistaken for the peer closing. `err` is one of
// .None, .Closed for the peer's orderly end of the stream, or .Transport for the
// caller's own reason for stopping.
//
// release, when set, is called once by destroy, so a transport that owns what it
// reads from closes it there. A transport that borrows the stream leaves it nil.
Transport :: struct {
	read:      proc(user_data: rawptr, buffer: []u8) -> (count: int, err: Error),
	write:     proc(user_data: rawptr, buffer: []u8) -> (count: int, err: Error),
	release:   proc(user_data: rawptr),
	user_data: rawptr,
}

// Close_Code is why an endpoint closed (RFC 6455 section 7.4.1).
Close_Code :: enum u16 {
	Normal           = 1000,
	Going_Away       = 1001,
	Protocol_Error   = 1002,
	Unsupported_Data = 1003,
	Invalid_Payload  = 1007,
	Policy_Violation = 1008,
	Message_Too_Big  = 1009,
	Internal_Error   = 1011,
}

Error :: enum {
	None,
	// Transport is the caller's own failure handed back.
	Transport,
	// Protocol is a frame, or an order of frames, the protocol does not allow. The
	// connection is closed with the code the protocol names for it.
	Protocol,
	// Closed is the peer's close, which is the orderly end of a connection.
	Closed,
	No_Room,
}

// SEND_CHUNK is how much of a message one frame carries. A message of any size is
// sent as a sequence of frames, which is what fragmentation is for (RFC 6455
// section 5.4), so no message is refused for being large.
SEND_CHUNK :: 16 * 1024

// RECV_CHUNK is how much of a frame's payload one read asks the transport for.
RECV_CHUNK :: 16 * 1024

// Conn is one WebSocket connection. It is a client: it masks what it sends, and it
// refuses what a server may not send.
//
// Every buffer is allocated once, and a payload is unmasked in the caller's own
// buffer, so a connection moves no memory while it is in use.
Conn :: struct {
	transport: Transport,
	allocator: mem.Allocator,

	send:   []u8,
	header: [HEADER_MAX_SIZE]u8,
	recv:   []u8,

	// The frame being read: how much of its payload is left, and where the masking
	// key has reached. A payload larger than a chunk is read in pieces, so the key
	// does not restart at a piece boundary.
	header_filled:   int,
	frame_final:     bool,
	frame_remaining: int,
	mask:            [MASK_KEY_SIZE]u8,
	mask_at:         int,

	message_opcode: Opcode,
	in_message:     bool,

	// A rune split by a read boundary, and a control frame's payload, which is small
	// enough to hold because a control frame may not exceed it.
	carry:        [utf8.UTF_MAX]u8,
	carry_length: int,
	control:      [MAX_CONTROL_PAYLOAD]u8,

	closed:     bool,
	close_sent: bool,
	close_code: Close_Code,
}

init :: proc(transport: Transport, allocator: mem.Allocator) -> (conn: ^Conn, err: Error) {
	if transport.read == nil || transport.write == nil { return nil, .Transport }
	self := new(Conn, allocator)
	self.transport = transport
	self.allocator = allocator
	self.send = make([]u8, HEADER_MAX_SIZE + SEND_CHUNK, allocator)
	self.recv = make([]u8, RECV_CHUNK, allocator)
	return self, .None
}

destroy :: proc(conn: ^Conn) {
	if conn == nil { return }
	delete(conn.send, conn.allocator)
	delete(conn.recv, conn.allocator)
	if conn.transport.release != nil { conn.transport.release(conn.transport.user_data) }
	free(conn, conn.allocator)
}

// write sends one whole message. A message larger than a frame is fragmented, and
// every frame is masked under a key of its own, which is what a client must do
// (RFC 6455 section 5.3).
write :: proc(conn: ^Conn, opcode: Opcode, message: []u8) -> Error {
	if opcode != .Text && opcode != .Binary { return .Protocol }
	if conn.closed { return .Closed }

	pending := message
	first := true
	for {
		chunk := pending
		if len(chunk) > SEND_CHUNK { chunk = chunk[:SEND_CHUNK] }
		pending = pending[len(chunk):]

		mask: [MASK_KEY_SIZE]u8
		crypto.rand_bytes(mask[:])
		frame_opcode := opcode
		if !first { frame_opcode = .Continuation }
		count, encoded := frame_encode(frame_opcode, len(pending) == 0, mask, chunk, conn.send)
		if !encoded { return .No_Room }
		if err := transport_write(conn, conn.send[:count]); err != .None { return err }

		first = false
		if len(pending) == 0 { return .None }
	}
}

// ping asks the peer whether it is there, with whatever body the caller wants echoed
// (RFC 6455 section 5.5.2).
ping :: proc(conn: ^Conn, body: []u8) -> Error {
	if len(body) > MAX_CONTROL_PAYLOAD { return .Protocol }
	return control_send(conn, .Ping, body)
}

// close sends the close frame and waits for the peer's, so that both ends agree the
// connection is over (RFC 6455 section 5.5.1). The transport is the caller's to close.
close :: proc(conn: ^Conn, code: Close_Code, reason: string, buffer: []u8) -> Error {
	if !conn.close_sent {
		payload := conn.control[:2 + len(reason)]
		payload[0] = u8(u16(code) >> 8)
		payload[1] = u8(u16(code) & 0xff)
		copy(payload[2:], reason)
		if err := control_send(conn, .Close, payload); err != .None { return err }
		conn.close_sent = true
	}
	if conn.closed { return .None }

	// Read what the peer says, which is a close frame or nothing at all.
	for {
		_, _, _, err := read(conn, buffer)
		if err == .Closed { return .None }
		if err != .None { return err }
	}
}

// read hands the caller the next bytes of the message being received and reports the
// message's type, which is the type of its first frame. `complete` says the message
// ended with these bytes.
//
// A control frame is answered here rather than handed out, so a ping that arrives
// between the fragments of a message does not disturb it. `buffer` is unmasked in
// place, so it holds the message's bytes on return.
read :: proc(conn: ^Conn, buffer: []u8) -> (count: int, opcode: Opcode, complete: bool, err: Error) {
	// A connection that ended, whether by the peer's close or by this side failing
	// it, delivers nothing more.
	if conn.closed { return 0, conn.message_opcode, false, .Closed }
	for {
		if conn.frame_remaining > 0 {
			count, err = frame_payload_read(conn, buffer)
			if err != .None { return 0, conn.message_opcode, false, err }
			if conn.message_opcode == .Text && !text_validate(conn, buffer[:count]) {
				return 0, conn.message_opcode, false, fail(conn, .Invalid_Payload, .Protocol)
			}
			if conn.frame_remaining == 0 && conn.frame_final {
				if conn.message_opcode == .Text && conn.carry_length != 0 {
					return 0, conn.message_opcode, false, fail(conn, .Invalid_Payload, .Protocol)
				}
				conn.in_message = false
				complete = true
			}
			return count, conn.message_opcode, complete, .None
		}

		header, header_err := frame_header_read(conn)
		if header_err != .None { return 0, conn.message_opcode, false, header_err }

		// A server must not mask, and a client must close a connection if it sees
		// one that did (RFC 6455 section 5.3).
		if header.masked { return 0, conn.message_opcode, false, fail(conn, .Protocol_Error, .Protocol) }
		// A control frame must fit in one frame, which is what keeps it actionable
		// in the middle of a message (RFC 6455 section 5.5).
		if header.opcode >= .Close && (header.length > MAX_CONTROL_PAYLOAD || !header.final) {
			return 0, conn.message_opcode, false, fail(conn, .Protocol_Error, .Protocol)
		}

		switch header.opcode {
		case .Ping:
			payload, read_err := control_read(conn, header.length)
			if read_err != .None { return 0, conn.message_opcode, false, read_err }
			if pong_err := control_send(conn, .Pong, payload); pong_err != .None {
				return 0, conn.message_opcode, false, pong_err
			}
			// A control frame is not part of the message in progress, so the frame
			// that follows it is the one to read next.
			continue
		case .Pong:
			if _, read_err := control_read(conn, header.length); read_err != .None {
				return 0, conn.message_opcode, false, read_err
			}
			continue
		case .Close:
			payload, read_err := control_read(conn, header.length)
			if read_err != .None { return 0, conn.message_opcode, false, read_err }
			if len(payload) >= 2 { conn.close_code = Close_Code(u16(payload[0]) << 8 | u16(payload[1])) }
			if !conn.close_sent {
				_ = control_send(conn, .Close, payload)
				conn.close_sent = true
			}
			conn.closed = true
			return 0, conn.message_opcode, false, .Closed
		case .Continuation:
			if !conn.in_message { return 0, conn.message_opcode, false, fail(conn, .Protocol_Error, .Protocol) }
		case .Text, .Binary:
			if conn.in_message {
				// A message in progress may only be continued.
				return 0, conn.message_opcode, false, fail(conn, .Protocol_Error, .Protocol)
			}
			conn.message_opcode = header.opcode
			conn.in_message = true
			conn.carry_length = 0
		case:
			// The opcodes between these are reserved for extensions this client has
			// negotiated none of (RFC 6455 section 5.8).
			return 0, conn.message_opcode, false, fail(conn, .Protocol_Error, .Protocol)
		}

		conn.frame_final = header.final
		conn.frame_remaining = header.length
		conn.mask = header.mask
		conn.mask_at = 0
	}
}

// fail tells the peer why the connection is ending and reports the failure, which is
// what the protocol asks of the side that finds it (RFC 6455 section 7.1.7).
fail :: proc(conn: ^Conn, code: Close_Code, err: Error) -> Error {
	if !conn.close_sent {
		payload := conn.control[:2]
		payload[0] = u8(u16(code) >> 8)
		payload[1] = u8(u16(code) & 0xff)
		_ = control_send(conn, .Close, payload)
		conn.close_sent = true
	}
	conn.closed = true
	return err
}

control_send :: proc(conn: ^Conn, opcode: Opcode, payload: []u8) -> Error {
	mask: [MASK_KEY_SIZE]u8
	crypto.rand_bytes(mask[:])
	count, encoded := frame_encode(opcode, true, mask, payload, conn.send)
	if !encoded { return .No_Room }
	return transport_write(conn, conn.send[:count])
}

// control_read reads a control frame's payload, which is small enough to hold.
control_read :: proc(conn: ^Conn, length: int) -> (payload: []u8, err: Error) {
	if length > MAX_CONTROL_PAYLOAD { return nil, .Protocol }
	conn.frame_remaining = length
	conn.mask = {}
	conn.mask_at = 0
	payload = conn.control[:length]
	if length == 0 { return payload, .None }
	if read_err := transport_read(conn, payload); read_err != .None { return nil, read_err }
	conn.frame_remaining = 0
	return payload, .None
}

// frame_header_read reads one frame header, which is as long as its length field says
// it is.
frame_header_read :: proc(conn: ^Conn) -> (header: Header, err: Error) {
	if fill_err := recv_fill(conn, 2); fill_err != .None {
		// A peer that closes between frames ends the stream, which is not a failure
		// of the protocol.
		if fill_err == .Closed && conn.header_filled == 0 { return {}, .Closed }
		return {}, fill_err
	}
	count := 2
	switch conn.header[1] & 0x7f {
	case 126: count = 4
	case 127: count = 10
	}
	if conn.header[1] & 0x80 != 0 { count += MASK_KEY_SIZE }
	if fill_err := recv_fill(conn, count); fill_err != .None { return {}, fill_err }

	decoded_header, decoded := frame_header_decode(conn.header[:count])
	if !decoded { return {}, fail(conn, .Protocol_Error, .Protocol) }
	conn.header_filled = 0
	return decoded_header, .None
}

// frame_payload_read hands over at most one piece of the frame in progress, unmasking
// it in place.
frame_payload_read :: proc(conn: ^Conn, buffer: []u8) -> (count: int, err: Error) {
	if len(buffer) == 0 || conn.frame_remaining == 0 { return 0, .None }
	count = min(len(buffer), conn.frame_remaining)
	if read_err := transport_read(conn, buffer[:count]); read_err != .None { return 0, read_err }
	for octet, at in buffer[:count] {
		buffer[at] = octet ~ conn.mask[(conn.mask_at + at) % MASK_KEY_SIZE]
	}
	conn.mask_at = (conn.mask_at + count) % MASK_KEY_SIZE
	conn.frame_remaining -= count
	return count, .None
}

// text_validate checks what has arrived of a text message, carrying the octets of a
// rune that a read boundary split. A stream that is not UTF-8 ends the connection
// (RFC 6455 section 8.1).
text_validate :: proc(conn: ^Conn, chunk: []u8) -> bool {
	at := 0
	for conn.carry_length > 0 && at < len(chunk) {
		conn.carry[conn.carry_length] = chunk[at]
		conn.carry_length += 1
		at += 1

		window := conn.carry[:conn.carry_length]
		if !utf8.full_rune_in_bytes(window) {
			// Four octets that are still not a rune cannot become one.
			if conn.carry_length == utf8.UTF_MAX { return false }
			continue
		}
		decoded, _ := utf8.decode_rune_in_bytes(window)
		if decoded == utf8.RUNE_ERROR { return false }
		conn.carry_length = 0
	}

	remaining := chunk[at:]
	for len(remaining) > 0 {
		if !utf8.full_rune_in_bytes(remaining) {
			copy(conn.carry[:], remaining)
			conn.carry_length = len(remaining)
			return true
		}
		decoded, size := utf8.decode_rune_in_bytes(remaining)
		if decoded == utf8.RUNE_ERROR { return false }
		remaining = remaining[size:]
	}
	return true
}

// transport_read reads exactly the bytes it is given, from wherever the connection has
// read up to.
transport_read :: proc(conn: ^Conn, dst: []u8) -> Error {
	filled := 0
	for filled < len(dst) {
		count, err := conn.transport.read(conn.transport.user_data, dst[filled:])
		if err != .None { return err }
		if count <= 0 { return .Transport }
		filled += count
	}
	return .None
}

// recv_fill reads the next bytes of a frame header into the connection's header
// buffer.
recv_fill :: proc(conn: ^Conn, count: int) -> Error {
	if err := transport_read(conn, conn.header[conn.header_filled:count]); err != .None { return err }
	conn.header_filled = count
	return .None
}

transport_write :: proc(conn: ^Conn, data: []u8) -> Error {
	pending := data
	for len(pending) > 0 {
		written, err := conn.transport.write(conn.transport.user_data, pending)
		if err != .None { return err }
		if written <= 0 { return .Transport }
		pending = pending[written:]
	}
	return .None
}
