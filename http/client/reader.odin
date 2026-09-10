package client

import "core:mem"

// Reader buffers a connection so response lines and bodies can be scanned without
// a syscall per byte. reader_line returns a view that stays valid until the next
// fill, which is enough because header parsing copies what it keeps.
Reader :: struct {
	connection: ^Connection,
	allocator:  mem.Allocator,
	buffer:     []u8,
	head:       int,
	tail:       int,
}

reader_init :: proc(reader: ^Reader, connection: ^Connection, allocator: mem.Allocator) {
	reader.connection = connection
	reader.allocator = allocator
	reader.buffer = make([]u8, 8192, allocator)
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
		if len(reader.buffer) >= HTTP_MAX_LINE_BYTES { return .Bad_Response }
		grown_len := min(len(reader.buffer) * 2, HTTP_MAX_LINE_BYTES)
		if grown_len <= len(reader.buffer) { return .Bad_Response }
		grown := make([]u8, grown_len, reader.allocator)
		copy(grown, reader.buffer[:reader.tail])
		delete(reader.buffer, reader.allocator)
		reader.buffer = grown
	}
	count, err := connection_read(reader.connection, reader.buffer[reader.tail:])
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
