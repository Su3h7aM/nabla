#+private
package http

import "core:bufio"
import "core:mem/virtual"
import "core:nbio"
import "core:net"

Scan_Callback :: #type proc(user_data: rawptr, token: string, err: bufio.Scanner_Error)
Split_Proc :: #type proc(split_data: rawptr, data: []byte, at_eof: bool) -> (advance: int, token: []byte, err: bufio.Scanner_Error, final_token: bool)

// scan_lines splits on LF and drops a CR before it. RFC 9112 2.2 lets a
// recipient treat a bare LF as a line terminator.
scan_lines :: proc(split_data: rawptr, data: []byte, at_eof: bool) -> (advance: int, token: []byte, err: bufio.Scanner_Error, final_token: bool) {
	return bufio.scan_lines(data, at_eof)
}

// scan_num_bytes takes exactly the byte count carried in split_data.
scan_num_bytes :: proc(split_data: rawptr, data: []byte, at_eof: bool) -> (advance: int, token: []byte, err: bufio.Scanner_Error, final_token: bool) {
	n := int(uintptr(split_data))
	if len(data) < n { return }
	return n, data[:n], nil, false
}

// Scanner splits a connection's bytes into tokens as they arrive, reading
// through the connection's event loop.
Scanner :: struct {
	connection:     ^Connection,
	split:          Split_Proc,
	split_data:     rawptr,
	buf:            [dynamic]byte,
	// max_token_size is the caller's bound on one token; zero or less is no
	// bound. HTTP itself sets none (RFC 9110 5.4).
	max_token_size: int,
	start:          int,
	end:            int,
	_err:           bufio.Scanner_Error,
	done:           bool,
	user_data:      rawptr,
	callback:       Scan_Callback,
	// recv is the read in flight, which a closing connection removes.
	recv:           ^nbio.Operation,
}

INIT_BUF_SIZE :: 1024

scanner_init :: proc(s: ^Scanner, c: ^Connection, buf_allocator := context.allocator) {
	s.connection = c
	s.split = scan_lines
	s.buf.allocator = buf_allocator
}

scanner_destroy :: proc(s: ^Scanner) {
	delete(s.buf)
}

// scanner_reset prepares for the next message, keeping bytes already read
// past the last token: a pipelined request may have arrived with the last one.
scanner_reset :: proc(s: ^Scanner) {
	scanner_compact(s)
	s.split = scan_lines
	s.split_data = nil
	s.max_token_size = 0
	s._err = nil
	s.done = false
	s.user_data = nil
	s.callback = nil
}

// scanner_compact moves the unread bytes to the front of the buffer.
scanner_compact :: proc(s: ^Scanner) {
	if s.start == 0 { return }
	copy(s.buf[:], s.buf[s.start:s.end])
	s.end -= s.start
	s.start = 0
}

scanner_scan :: proc(s: ^Scanner, user_data: rawptr, callback: Scan_Callback) {
	fail :: proc(s: ^Scanner, err: bufio.Scanner_Error, user_data: rawptr, callback: Scan_Callback) {
		if s._err == nil || s._err == .EOF { s._err = err }
		callback(user_data, "", s._err)
	}

	if s.done {
		callback(user_data, "", .EOF)
		return
	}

	// A token may already be buffered, and a read error still lets the split
	// procedure take what is left.
	if s.start < s.end || s._err != nil {
		advance, token, err, final_token := s.split(s.split_data, s.buf[s.start:s.end], s._err != nil)
		if final_token {
			s.done = true
			callback(user_data, "", .EOF)
			return
		}
		if err != nil {
			fail(s, err, user_data, callback)
			return
		}
		if advance < 0 || advance > s.end - s.start {
			fail(s, .Advanced_Too_Far, user_data, callback)
			return
		}
		s.start += advance
		if token != nil {
			s.callback = nil
			s.user_data = nil
			// A token taken after a read error is the last one, and carries it.
			callback(user_data, string(token), s._err)
			return
		}
	}

	if s._err != nil {
		s.start = 0
		s.end = 0
		callback(user_data, "", s._err)
		return
	}

	if s.max_token_size > 0 && s.end - s.start >= s.max_token_size {
		fail(s, .Too_Long, user_data, callback)
		return
	}

	// Make room: reuse the consumed front of the buffer before growing it.
	if s.end == len(s.buf) {
		scanner_compact(s)
		if s.end == len(s.buf) {
			if resize(&s.buf, max(INIT_BUF_SIZE, 2 * len(s.buf))) != nil {
				fail(s, .Too_Long, user_data, callback)
				return
			}
		}
	}

	s.user_data = user_data
	s.callback = callback
	assert_has_td()
	s.recv = nbio.recv_poly(s.connection.socket, {s.buf[s.end:len(s.buf)]}, s, scanner_on_read)
}

scanner_on_read :: proc(op: ^nbio.Operation, s: ^Scanner) {
	s.recv = nil
	context.temp_allocator = virtual.arena_allocator(&s.connection.temp_allocator)
	defer scanner_scan(s, s.user_data, s.callback)

	if op.recv.err != nil {
		#partial switch op.recv.err.(net.TCP_Recv_Error) {
		case .Connection_Closed, .Invalid_Argument:
			// EBADF (bad file descriptor) happens when the OS closes the socket.
			s._err = .EOF
		case:
			s._err = .Unknown
		}
		return
	}
	// Zero bytes is the peer's orderly close.
	if op.recv.received == 0 {
		s._err = .EOF
		return
	}
	s.end += op.recv.received
}
