package websocket

import "core:crypto"
import "core:mem"
import "core:unicode/utf8"

// Transport is how a connection reaches its peer. Both calls block until they moved
// bytes, or the caller ended the wait: a read that moved none reports why, so a
// cancellation or a deadline is never mistaken for the peer closing. `err` is one of
// .None, .Closed for the peer's orderly end of the stream, .Idle_Timeout for a peer
// that sent nothing for as long as the transport allows, or .Transport for the
// caller's own reason for stopping.
//
// release, when set, is called once by destroy, so a transport that owns what it
// reads from closes it there. A transport that borrows the stream leaves it nil.
Transport :: struct {
	read:      proc(user_data: rawptr, buffer: []u8) -> (count: int, err: Error),
	write:     proc(user_data: rawptr, buffer: []u8) -> (count: int, err: Error),
	// release performs the transport's ordinary teardown. abort, when set, performs
	// teardown without a protocol-level close that could wait on the peer.
	release:   proc(user_data: rawptr),
	abort:     proc(user_data: rawptr),
	user_data: rawptr,
}

// Close_Code is why an endpoint closed (RFC 6455 section 7.4.1).
Close_Code :: enum u16 {
	Normal              = 1000,
	Going_Away          = 1001,
	Protocol_Error      = 1002,
	Unsupported_Data    = 1003,
	Invalid_Payload     = 1007,
	Policy_Violation    = 1008,
	Message_Too_Big     = 1009,
	Mandatory_Extension = 1010,
	Internal_Error      = 1011,
}

Error :: enum {
	None,
	// Transport is the caller's own failure handed back.
	Transport,
	// Protocol is a frame, or an order of frames, the protocol does not allow. The
	// connection is closed with the code the protocol names for it.
	Protocol,
	// Closed is a valid close frame received from the peer.
	Closed,
	// Abnormal_Closure is the underlying stream ending without a close frame.
	Abnormal_Closure,
	// Idle_Timeout is a peer that sent no byte for as long as the transport allows a
	// read to wait.
	Idle_Timeout,
	No_Room,
}

// SEND_CHUNK is how much of a message one frame carries. A message of any size is
// sent as a sequence of frames, which is what fragmentation is for (RFC 6455
// section 5.4), so no message is refused for being large.
SEND_CHUNK :: 16 * 1024

// Conn is one WebSocket connection. It is a client: it masks what it sends, and it
// refuses what a server may not send.
//
// Every buffer is allocated once, and a payload is unmasked in the caller's own
// buffer, so a connection moves no memory while it is in use.
Conn :: struct {
	transport:       Transport,
	allocator:       mem.Allocator,
	send:            []u8,
	header:          [HEADER_MAX_SIZE]u8,

	// The frame being read: how much of its payload is left, and where the masking
	// key has reached. A payload larger than a chunk is read in pieces, so the key
	// does not restart at a piece boundary.
	header_filled:   int,
	frame_final:     bool,
	frame_remaining: int,
	mask:            [MASK_KEY_SIZE]u8,
	mask_at:         int,
	message_opcode:  Opcode,
	in_message:      bool,

	// A rune split by a read boundary, and a control frame's payload, which is small
	// enough to hold because a control frame may not exceed it.
	carry:           [utf8.UTF_MAX]u8,
	carry_length:    int,
	control:         [MAX_CONTROL_PAYLOAD]u8,
	closed:          bool,
	close_sent:      bool,
	close_code:      Close_Code,
}

@(require_results)
init :: proc(transport: Transport, allocator: mem.Allocator) -> (connection: ^Conn, err: Error) {
	if transport.read == nil || transport.write == nil { return nil, .Transport }
	self, alloc_error := new(Conn, allocator)
	if alloc_error != nil { return nil, .No_Room }
	self.transport = transport
	self.allocator = allocator
	self.send, alloc_error = make([]u8, HEADER_MAX_SIZE + SEND_CHUNK, allocator)
	if alloc_error != nil {
		destroy(self)
		return nil, .No_Room
	}
	return self, .None
}

destroy :: proc(connection: ^Conn) {
	connection_release(connection, false)
}

// abort releases a connection without attempting another protocol close. It is for
// cancellation and teardown paths where waiting on the peer is not allowed.
abort :: proc(connection: ^Conn) {
	connection_release(connection, true)
}

connection_release :: proc(connection: ^Conn, aborted: bool) {
	if connection == nil { return }
	delete(connection.send, connection.allocator)
	if aborted && connection.transport.abort != nil {
		connection.transport.abort(connection.transport.user_data)
	} else if connection.transport.release != nil {
		connection.transport.release(connection.transport.user_data)
	}
	free(connection, connection.allocator)
}

// write sends one whole message. A message larger than a frame is fragmented, and
// every frame is masked under a key of its own, which is what a client must do
// (RFC 6455 section 5.3).
@(require_results)
write :: proc(connection: ^Conn, opcode: Opcode, message: []u8) -> Error {
	if connection == nil { return .Protocol }
	if opcode != .Text && opcode != .Binary { return .Protocol }
	// RFC 6455 5.6: a text message is valid UTF-8. The whole message is
	// checked before its first frame, so a refusal sends nothing.
	if opcode == .Text && !utf8.valid_string(string(message)) { return .Protocol }
	if connection.closed || connection.close_sent { return .Closed }

	pending := message
	first := true
	wrote_frame := false
	for {
		chunk := pending
		if len(chunk) > SEND_CHUNK { chunk = chunk[:SEND_CHUNK] }
		pending = pending[len(chunk):]

		mask: [MASK_KEY_SIZE]u8
		crypto.rand_bytes(mask[:])
		frame_opcode := opcode
		if !first { frame_opcode = .Continuation }
		count, encoded := frame_encode(frame_opcode, len(pending) == 0, mask, chunk, connection.send)
		if !encoded { return .No_Room }
		if err := transport_write(connection, connection.send[:count]); err != .None {
			if wrote_frame { connection.closed = true }
			return err
		}

		wrote_frame = true
		first = false
		if len(pending) == 0 { return .None }
	}
}

// ping asks the peer whether it is there, with whatever body the caller wants echoed
// (RFC 6455 section 5.5.2).
@(require_results)
ping :: proc(connection: ^Conn, body: []u8) -> Error {
	if len(body) > MAX_CONTROL_PAYLOAD { return .Protocol }
	return control_send(connection, .Ping, body)
}

// close sends the close frame and waits for the peer's, so that both ends agree the
// connection is over (RFC 6455 section 5.5.1). The transport is the caller's to close.
@(require_results)
close :: proc(connection: ^Conn, code: Close_Code, reason: string, buffer: []u8) -> Error {
	if !close_code_valid(code) || len(reason) > MAX_CONTROL_PAYLOAD - 2 || !utf8.valid_string(reason) {
		return .Protocol
	}
	if connection.closed {
		if connection.close_sent { return .None }
		return .Closed
	}
	if !connection.close_sent {
		payload := connection.control[:2 + len(reason)]
		payload[0] = u8(u16(code) >> 8)
		payload[1] = u8(u16(code) & 0xff)
		copy(payload[2:], reason)
		if err := control_send(connection, .Close, payload); err != .None { return err }
		connection.close_sent = true
	}
	if connection.closed { return .None }

	// Read what the peer says, which is a close frame or nothing at all.
	for {
		_, _, _, err := read(connection, buffer)
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
@(require_results)
read :: proc(connection: ^Conn, buffer: []u8) -> (count: int, opcode: Opcode, complete: bool, err: Error) {
	// A connection that ended, whether by the peer's close or by this side failing
	// it, delivers nothing more.
	if connection.closed { return 0, connection.message_opcode, false, .Closed }
	for {
		if connection.frame_remaining > 0 {
			count, err = frame_payload_read(connection, buffer)
			if err != .None { return 0, connection.message_opcode, false, err }
			if connection.message_opcode == .Text && !text_validate(connection, buffer[:count]) {
				return 0, connection.message_opcode, false, fail(connection, .Invalid_Payload, .Protocol)
			}
			if connection.frame_remaining == 0 && connection.frame_final {
				if connection.message_opcode == .Text && connection.carry_length != 0 {
					return 0, connection.message_opcode, false, fail(connection, .Invalid_Payload, .Protocol)
				}
				connection.in_message = false
				complete = true
			}
			return count, connection.message_opcode, complete, .None
		}

		header, header_err := frame_header_read(connection)
		if header_err != .None { return 0, connection.message_opcode, false, header_err }

		// A server must not mask, and a client must close a connection if it sees
		// one that did (RFC 6455 section 5.3).
		if header.masked { return 0, connection.message_opcode, false, fail(connection, .Protocol_Error, .Protocol) }
		// A control frame must fit in one frame, which is what keeps it actionable
		// in the middle of a message (RFC 6455 section 5.5).
		if header.opcode >= .Close && (header.length > MAX_CONTROL_PAYLOAD || !header.final) {
			return 0, connection.message_opcode, false, fail(connection, .Protocol_Error, .Protocol)
		}

		switch header.opcode {
		case .Ping:
			payload, read_err := control_read(connection, header.length)
			if read_err != .None { return 0, connection.message_opcode, false, read_err }
			if pong_err := control_send(connection, .Pong, payload); pong_err != .None {
				return 0, connection.message_opcode, false, pong_err
			}
			// A control frame is not part of the message in progress, so the frame
			// that follows it is the one to read next.
			continue
		case .Pong:
			if _, read_err := control_read(connection, header.length); read_err != .None {
				return 0, connection.message_opcode, false, read_err
			}
			continue
		case .Close:
			payload, read_err := control_read(connection, header.length)
			if read_err != .None { return 0, connection.message_opcode, false, read_err }
			if len(payload) == 1 { return 0, connection.message_opcode, false, fail(connection, .Protocol_Error, .Protocol) }
			if len(payload) >= 2 {
				code := Close_Code(u16(payload[0]) << 8 | u16(payload[1]))
				if !close_code_valid(code) || code == .Mandatory_Extension {
					return 0, connection.message_opcode, false, fail(connection, .Protocol_Error, .Protocol)
				}
				if !utf8.valid_string(string(payload[2:])) {
					return 0, connection.message_opcode, false, fail(connection, .Invalid_Payload, .Protocol)
				}
				connection.close_code = code
			}
			if !connection.close_sent {
				// The peer's close is answered best effort: the stream ends either way.
				_ = control_send(connection, .Close, payload)
				connection.close_sent = true
			}
			connection.closed = true
			return 0, connection.message_opcode, false, .Closed
		case .Continuation:
			if !connection.in_message { return 0, connection.message_opcode, false, fail(connection, .Protocol_Error, .Protocol) }
		case .Text, .Binary:
			if connection.in_message {
				// A message in progress may only be continued.
				return 0, connection.message_opcode, false, fail(connection, .Protocol_Error, .Protocol)
			}
			connection.message_opcode = header.opcode
			connection.in_message = true
			connection.carry_length = 0
		case:
			// The opcodes between these are reserved for extensions this client has
			// negotiated none of (RFC 6455 section 5.8).
			return 0, connection.message_opcode, false, fail(connection, .Protocol_Error, .Protocol)
		}

		connection.frame_final = header.final
		connection.frame_remaining = header.length
		connection.mask = header.mask
		connection.mask_at = 0
		if connection.frame_remaining == 0 {
			if !connection.frame_final { continue }
			if connection.message_opcode == .Text && connection.carry_length != 0 {
				return 0, connection.message_opcode, false, fail(connection, .Invalid_Payload, .Protocol)
			}
			connection.in_message = false
			return 0, connection.message_opcode, true, .None
		}
	}
}

// fail tells the peer why the connection is ending and reports the failure, which is
// what the protocol asks of the side that finds it (RFC 6455 section 7.1.7).
@(require_results)
fail :: proc(connection: ^Conn, code: Close_Code, err: Error) -> Error {
	if !connection.close_sent {
		payload := connection.control[:2]
		payload[0] = u8(u16(code) >> 8)
		payload[1] = u8(u16(code) & 0xff)
		// The close is best effort: the violation is reported whether or not the peer hears it.
		_ = control_send(connection, .Close, payload)
		connection.close_sent = true
	}
	connection.closed = true
	return err
}

@(require_results)
control_send :: proc(connection: ^Conn, opcode: Opcode, payload: []u8) -> Error {
	if connection.closed { return .Closed }
	mask: [MASK_KEY_SIZE]u8
	crypto.rand_bytes(mask[:])
	count, encoded := frame_encode(opcode, true, mask, payload, connection.send)
	if !encoded { return .No_Room }
	return transport_write(connection, connection.send[:count])
}

// control_read reads a control frame's payload, which is small enough to hold.
@(require_results)
control_read :: proc(connection: ^Conn, length: int) -> (payload: []u8, err: Error) {
	if length > MAX_CONTROL_PAYLOAD { return nil, .Protocol }
	connection.frame_remaining = length
	connection.mask = {}
	connection.mask_at = 0
	payload = connection.control[:length]
	if length == 0 { return payload, .None }
	if read_err := transport_read(connection, payload); read_err != .None {
		// The frame header has already been consumed, and read does not retain the
		// control opcode needed to resume this payload.
		connection.closed = true
		return nil, read_err
	}
	connection.frame_remaining = 0
	return payload, .None
}

// frame_header_read reads one frame header, which is as long as its length field says
// it is.
@(require_results)
frame_header_read :: proc(connection: ^Conn) -> (header: Header, err: Error) {
	if fill_err := recv_fill(connection, 2); fill_err != .None { return {}, fill_err }
	count := 2
	switch connection.header[1] & 0x7f {
	case 126:
		count = 4
	case 127:
		count = 10
	}
	if connection.header[1] & 0x80 != 0 { count += MASK_KEY_SIZE }
	if fill_err := recv_fill(connection, count); fill_err != .None { return {}, fill_err }

	decoded_header, decoded := frame_header_decode(connection.header[:count])
	if !decoded { return {}, fail(connection, .Protocol_Error, .Protocol) }
	connection.header_filled = 0
	return decoded_header, .None
}

// frame_payload_read hands over at most one piece of the frame in progress, unmasking
// it in place.
@(require_results)
frame_payload_read :: proc(connection: ^Conn, buffer: []u8) -> (count: int, err: Error) {
	if len(buffer) == 0 || connection.frame_remaining == 0 { return 0, .None }
	count = min(len(buffer), connection.frame_remaining)
	if read_err := transport_read(connection, buffer[:count]); read_err != .None { return 0, read_err }
	for octet, at in buffer[:count] {
		buffer[at] = octet ~ connection.mask[(connection.mask_at + at) % MASK_KEY_SIZE]
	}
	connection.mask_at = (connection.mask_at + count) % MASK_KEY_SIZE
	connection.frame_remaining -= count
	return count, .None
}

// text_validate checks what has arrived of a text message, carrying the octets of a
// rune that a read boundary split. A stream that is not UTF-8 ends the connection
// (RFC 6455 section 8.1).
@(require_results)
text_validate :: proc(connection: ^Conn, chunk: []u8) -> bool {
	at := 0
	for connection.carry_length > 0 && at < len(chunk) {
		connection.carry[connection.carry_length] = chunk[at]
		connection.carry_length += 1
		at += 1

		window := connection.carry[:connection.carry_length]
		if !utf8.full_rune_in_bytes(window) {
			// Four octets that are still not a rune cannot become one.
			if connection.carry_length == utf8.UTF_MAX { return false }
			continue
		}
		decoded, size := utf8.decode_rune_in_bytes(window)
		if decoded == utf8.RUNE_ERROR && size == 1 { return false }
		connection.carry_length = 0
	}

	remaining := chunk[at:]
	for len(remaining) > 0 {
		if !utf8.full_rune_in_bytes(remaining) {
			copy(connection.carry[:], remaining)
			connection.carry_length = len(remaining)
			return true
		}
		decoded, size := utf8.decode_rune_in_bytes(remaining)
		if decoded == utf8.RUNE_ERROR && size == 1 { return false }
		remaining = remaining[size:]
	}
	return true
}

@(require_results)
close_code_valid :: proc(code: Close_Code) -> bool {
	value := u16(code)
	if value >= 3000 && value <= 4999 { return true }
	switch value {
	case 1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014:
		return true
	}
	return false
}

// transport_read reads exactly the bytes it is given, from wherever the connection has
// read up to.
@(require_results)
transport_read :: proc(connection: ^Conn, dst: []u8) -> Error {
	filled := 0
	for filled < len(dst) {
		count, err := connection.transport.read(connection.transport.user_data, dst[filled:])
		if err != .None {
			if filled > 0 || count > 0 { connection.closed = true }
			if err == .Closed { return .Abnormal_Closure }
			return err
		}
		if count <= 0 {
			if filled > 0 { connection.closed = true }
			return .Transport
		}
		filled += count
	}
	return .None
}

// recv_fill reads the next bytes of a frame header into the connection's header
// buffer.
@(require_results)
recv_fill :: proc(connection: ^Conn, count: int) -> Error {
	if err := transport_read(connection, connection.header[connection.header_filled:count]); err != .None { return err }
	connection.header_filled = count
	return .None
}

@(require_results)
transport_write :: proc(connection: ^Conn, data: []u8) -> Error {
	if connection.closed { return .Closed }
	pending := data
	wrote := false
	for len(pending) > 0 {
		written, err := connection.transport.write(connection.transport.user_data, pending)
		if err != .None {
			if wrote || written > 0 { connection.closed = true }
			return err
		}
		if written <= 0 {
			if wrote { connection.closed = true }
			return .Transport
		}
		wrote = true
		pending = pending[written:]
	}
	return .None
}
