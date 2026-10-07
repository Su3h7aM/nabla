#+private
package http

import "core:bufio"
import "core:mem/virtual"
import "core:nbio"
import "core:net"

Scan_Callback :: #type proc(user_data: rawptr, token: string, err: bufio.Scanner_Error)
// Split_Bytes makes a token of exactly that many bytes.
Split_Bytes :: distinct int

// Split is how the scanner cuts a token: nil splits on LF and drops a CR before
// it, which RFC 9112 2.2 lets a recipient do for a bare LF.
Split :: union {
	Split_Bytes,
}

@(require_results)
split_token :: proc(split: Split, data: []byte, at_eof: bool) -> (advance: int, token: []byte, err: bufio.Scanner_Error, final_token: bool) {
	if count, ok := split.(Split_Bytes); ok {
		if len(data) < int(count) { return }
		return int(count), data[:count], nil, false
	}
	return bufio.scan_lines(data, at_eof)
}

// Scanner splits a connection's bytes into tokens as they arrive, reading
// through the connection's event loop.
Scanner :: struct {
	connection:     ^Connection,
	split:          Split,
	buffer:         [dynamic]byte,
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

scanner_init :: proc(scanner: ^Scanner, connection: ^Connection, buffer_allocator := context.allocator) {
	scanner.connection = connection
	scanner.buffer.allocator = buffer_allocator
}

scanner_destroy :: proc(scanner: ^Scanner) {
	delete(scanner.buffer)
}

// scanner_reset prepares for the next message, keeping bytes already read
// past the last token: a pipelined request may have arrived with the last one.
scanner_reset :: proc(scanner: ^Scanner) {
	scanner_compact(scanner)
	scanner.split = nil
	scanner.max_token_size = 0
	scanner._err = nil
	scanner.done = false
	scanner.user_data = nil
	scanner.callback = nil
}

// scanner_compact moves the unread bytes to the front of the buffer.
scanner_compact :: proc(scanner: ^Scanner) {
	if scanner.start == 0 { return }
	copy(scanner.buffer[:], scanner.buffer[scanner.start:scanner.end])
	scanner.end -= scanner.start
	scanner.start = 0
}

scanner_scan :: proc(scanner: ^Scanner, user_data: rawptr, callback: Scan_Callback) {
	fail :: proc(scanner: ^Scanner, err: bufio.Scanner_Error, user_data: rawptr, callback: Scan_Callback) {
		if scanner._err == nil || scanner._err == .EOF { scanner._err = err }
		callback(user_data, "", scanner._err)
	}

	if scanner.done {
		callback(user_data, "", .EOF)
		return
	}

	// A token may already be buffered, and a read error still lets the split
	// procedure take what is left.
	if scanner.start < scanner.end || scanner._err != nil {
		advance, token, err, final_token := split_token(scanner.split, scanner.buffer[scanner.start:scanner.end], scanner._err != nil)
		if final_token {
			scanner.done = true
			callback(user_data, "", .EOF)
			return
		}
		if err != nil {
			fail(scanner, err, user_data, callback)
			return
		}
		if advance < 0 || advance > scanner.end - scanner.start {
			fail(scanner, .Advanced_Too_Far, user_data, callback)
			return
		}
		scanner.start += advance
		if token != nil {
			scanner.callback = nil
			scanner.user_data = nil
			// A token taken after a read error is the last one, and carries it.
			callback(user_data, string(token), scanner._err)
			return
		}
	}

	if scanner._err != nil {
		scanner.start = 0
		scanner.end = 0
		callback(user_data, "", scanner._err)
		return
	}

	if scanner.max_token_size > 0 && scanner.end - scanner.start >= scanner.max_token_size {
		fail(scanner, .Too_Long, user_data, callback)
		return
	}

	// Make room: reuse the consumed front of the buffer before growing it.
	if scanner.end == len(scanner.buffer) {
		scanner_compact(scanner)
		if scanner.end == len(scanner.buffer) {
			if resize(&scanner.buffer, max(INIT_BUF_SIZE, 2 * len(scanner.buffer))) != nil {
				fail(scanner, .Too_Long, user_data, callback)
				return
			}
		}
	}

	scanner.user_data = user_data
	scanner.callback = callback
	assert_on_server_thread()
	scanner.recv = nbio.recv_poly(scanner.connection.socket, {scanner.buffer[scanner.end:len(scanner.buffer)]}, scanner, scanner_on_read)
}

scanner_on_read :: proc(op: ^nbio.Operation, scanner: ^Scanner) {
	scanner.recv = nil
	context.temp_allocator = virtual.arena_allocator(&scanner.connection.temp_allocator)
	defer scanner_scan(scanner, scanner.user_data, scanner.callback)

	if op.recv.err != nil {
		#partial switch op.recv.err.(net.TCP_Recv_Error) {
		case .Connection_Closed, .Invalid_Argument:
			// EBADF (bad file descriptor) happens when the OS closes the socket.
			scanner._err = .EOF
		case:
			scanner._err = .Unknown
		}
		return
	}
	// Zero bytes is the peer's orderly close.
	if op.recv.received == 0 {
		scanner._err = .EOF
		return
	}
	scanner.end += op.recv.received
}
