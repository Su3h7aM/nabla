package client

import "base:intrinsics"
import "core:mem"

// READER_INITIAL_BYTES is the buffer's starting size, not a bound: the buffer
// grows to hold whatever a peer sends, because HTTP sets no limit on the length of
// a line (RFC 9110 5.4).
READER_INITIAL_BYTES :: 8192

// Read_Proc fills buffer and reports .Closed once the stream has ended. It is the
// signature of connection_read.
Read_Proc :: #type proc(user_data: rawptr, buffer: []u8) -> (count: int, err: Error)

// Reader buffers bytes so response lines and bodies can be scanned without a
// syscall per byte. It reads through `read` rather than from a connection, so the
// parsing path can be driven from a byte slice in tests. reader_line returns a
// view that stays valid until the next fill, which is enough because header
// parsing copies what it keeps.
Reader :: struct {
	read:      Read_Proc,
	user_data: rawptr,
	allocator: mem.Allocator,
	buffer:    []u8,
	head:      int,
	tail:      int,
}

reader_init :: proc(reader: ^Reader, read: Read_Proc, user_data: rawptr, allocator: mem.Allocator) {
	reader.read = read
	reader.user_data = user_data
	reader.allocator = allocator
	reader.buffer = make([]u8, READER_INITIAL_BYTES, allocator)
}

reader_destroy :: proc(reader: ^Reader) {
	if reader.buffer != nil { delete(reader.buffer, reader.allocator) }
	reader^ = {}
}

reader_fill :: proc(reader: ^Reader) -> Error {
	if reader.head > 0 {
		copy(reader.buffer[:], reader.buffer[reader.head:reader.tail])
		reader.tail -= reader.head
		reader.head = 0
	}
	if reader.tail == len(reader.buffer) {
		// The buffer doubles until it holds the line being read. RFC 9112 2.2 requires
		// a recipient to handle a line of at least 8000 octets and sets no maximum, so
		// the only size this refuses is one the machine cannot represent.
		size := READER_INITIAL_BYTES
		if len(reader.buffer) > 0 {
			overflowed: bool
			size, overflowed = intrinsics.overflow_mul(len(reader.buffer), 2)
			if overflowed { return .Bad_Response }
		}
		grown := make([]u8, size, reader.allocator)
		copy(grown, reader.buffer[:reader.tail])
		delete(reader.buffer, reader.allocator)
		reader.buffer = grown
	}
	count, err := reader.read(reader.user_data, reader.buffer[reader.tail:])
	if err != .None { return err }
	reader.tail += count
	return .None
}

// reader_line returns one CRLF-terminated line without its terminator.
reader_line :: proc(reader: ^Reader) -> (line: string, err: Error) {
	for {
		for index in reader.head ..< reader.tail - 1 {
			if reader.buffer[index] == '\r' && reader.buffer[index + 1] == '\n' {
				line = string(reader.buffer[reader.head:index])
				reader.head = index + 2
				return line, .None
			}
		}
		if fill_err := reader_fill(reader); fill_err != .None { return "", fill_err }
	}
}

// reader_read returns buffered bytes, filling first when the buffer is empty.
reader_read :: proc(reader: ^Reader, out: []u8) -> (int, Error) {
	for {
		if reader.head < reader.tail {
			count := min(len(out), reader.tail - reader.head)
			copy(out[:count], reader.buffer[reader.head:reader.head + count])
			reader.head += count
			return count, .None
		}
		if err := reader_fill(reader); err != .None { return 0, err }
	}
}

reader_read_full :: proc(reader: ^Reader, out: []u8) -> Error {
	filled := 0
	for filled < len(out) {
		count, err := reader_read(reader, out[filled:])
		if err != .None { return err }
		filled += count
	}
	return .None
}
