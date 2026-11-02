package agent

import "base:runtime"
import "core:encoding/endian"
import "core:io"
import "core:mem"
import "core:os"
import "core:path/filepath"

import "nabla:agent/journal"

STREAM_DIRECTORY_NAME :: "streams"
STREAM_HEADER_SIZE :: 5

Stream_Kind :: enum u8 {
	Assistant_Begin,
	Assistant_Text,
	Assistant_Flush,
	Assistant_End,
	Tool_Output,
}

// stream_encode_assistant returns the caller-owned payload of an assistant frame: the turn, the ordinal, then text.
@(require_results)
stream_encode_assistant :: proc(turn: u64, ordinal: u32, text: []u8, allocator := context.allocator) -> ([]u8, mem.Allocator_Error) {
	head := size_of(u64) + size_of(u32)
	payload, allocation_error := make([]u8, head + len(text), allocator)
	if allocation_error != nil { return nil, allocation_error }
	endian.unchecked_put_u64le(payload, turn)
	endian.unchecked_put_u32le(payload[size_of(u64):], ordinal)
	copy(payload[head:], text)
	return payload, nil
}

// stream_decode_assistant splits an assistant payload; text borrows from payload and ok is false for a short payload.
@(require_results)
stream_decode_assistant :: proc(payload: []u8) -> (turn: u64, ordinal: u32, text: []u8, ok: bool) {
	head := size_of(u64) + size_of(u32)
	if len(payload) < head { return 0, 0, nil, false }
	turn = endian.unchecked_get_u64le(payload)
	ordinal = endian.unchecked_get_u32le(payload[size_of(u64):])
	return turn, ordinal, payload[head:], true
}

// stream_encode_tool_output returns the caller-owned payload of a tool output frame: the call, its parent call, then chunk.
@(require_results)
stream_encode_tool_output :: proc(call, parent_call: u64, chunk: []u8, allocator := context.allocator) -> ([]u8, mem.Allocator_Error) {
	head := 2 * size_of(u64)
	payload, allocation_error := make([]u8, head + len(chunk), allocator)
	if allocation_error != nil { return nil, allocation_error }
	endian.unchecked_put_u64le(payload, call)
	endian.unchecked_put_u64le(payload[size_of(u64):], parent_call)
	copy(payload[head:], chunk)
	return payload, nil
}

// stream_decode_tool_output splits a tool output payload; chunk borrows from payload and ok is false for a short payload.
@(require_results)
stream_decode_tool_output :: proc(payload: []u8) -> (call, parent_call: u64, chunk: []u8, ok: bool) {
	head := 2 * size_of(u64)
	if len(payload) < head { return 0, 0, nil, false }
	call = endian.unchecked_get_u64le(payload)
	parent_call = endian.unchecked_get_u64le(payload[size_of(u64):])
	return call, parent_call, payload[head:], true
}

// stream_directory returns the caller-owned directory path using the same runtime fallback as session locks.
@(require_results)
stream_directory :: proc(allocator := context.allocator) -> (string, XDG_Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	locks, _, lock_error := session_lock_directory(context.temp_allocator)
	if lock_error != .None { return "", lock_error }
	path, join_error := filepath.join({filepath.dir(locks), STREAM_DIRECTORY_NAME}, allocator)
	if join_error != nil { return "", .Unresolved }
	return path, .None
}

// stream_path returns the caller-owned path for session in directory.
@(require_results)
stream_path :: proc(directory: string, session: journal.Session_Id, allocator := context.allocator) -> (string, os.Error) {
	hex: [journal.SESSION_ID_HEX_LENGTH]u8
	return filepath.join({directory, journal.session_id_to_hex(session, hex[:])}, allocator)
}

// stream_open_writer creates or truncates path. The caller closes the returned file.
@(require_results)
stream_open_writer :: proc(path: string) -> (^os.File, os.Error) {
	return os.open(path, {.Write, .Create, .Trunc, .Append}, {.Read_User, .Write_User})
}

// stream_append writes one frame to file. Only its owner thread may write to file.
@(require_results)
stream_append :: proc(file: ^os.File, kind: Stream_Kind, payload: []u8) -> os.Error {
	if u64(len(payload)) > u64(max(u32)) { return .Invalid_Argument }
	length := u32(len(payload))
	header := [STREAM_HEADER_SIZE]u8{u8(kind), u8(length), u8(length >> 8), u8(length >> 16), u8(length >> 24)}
	if _, error := os.write(file, header[:]); error != nil { return error }
	if _, error := os.write(file, payload); error != nil { return error }
	return nil
}

// Stream_Reader reads successive frames from one open stream file. It owns its
// file until stream_reader_close, and only its owner thread may read from it.
// The zero value reads nothing.
Stream_Reader :: struct {
	file: ^os.File,
}

// stream_reader_open opens path to read frames from. A missing file is no
// stream: ok is false and err is nil. The caller closes an opened reader.
@(require_results)
stream_reader_open :: proc(path: string) -> (reader: Stream_Reader, ok: bool, err: os.Error) {
	file, open_error := os.open(path)
	if open_error == os.General_Error.Not_Exist { return {}, false, nil }
	if open_error != nil { return {}, false, open_error }
	return Stream_Reader{file = file}, true, nil
}

// stream_reader_close closes the reader's file.
stream_reader_close :: proc(reader: ^Stream_Reader) {
	if reader.file == nil { return }
	_ = os.close(reader.file)
	reader.file = nil
}

// stream_reader_length returns the current length of the reader's open file, so
// a caller whose offset is past it can start over at the beginning.
@(require_results)
stream_reader_length :: proc(reader: ^Stream_Reader) -> (i64, os.Error) {
	if reader.file == nil { return 0, .Invalid_File }
	return os.file_size(reader.file)
}

// stream_reader_read returns one complete frame at offset, or found false for a
// reader with no file or a partial frame. The caller deletes payload with allocator.
@(require_results)
stream_reader_read :: proc(reader: ^Stream_Reader, offset: i64, allocator := context.allocator) -> (Stream_Kind, []u8, i64, bool, os.Error) {
	file := reader.file
	if file == nil { return {}, nil, offset, false, nil }
	header: [STREAM_HEADER_SIZE]u8
	count, read_error := os.read_at(file, header[:], offset)
	if read_error != nil && read_error != io.Error.EOF { return {}, nil, offset, false, read_error }
	if count != len(header) { return {}, nil, offset, false, nil }
	length := u32(header[1]) | u32(header[2]) << 8 | u32(header[3]) << 16 | u32(header[4]) << 24
	payload, allocation_error := make([]u8, int(length), allocator)
	if allocation_error != nil { return {}, nil, offset, false, allocation_error }
	count, read_error = os.read_at(file, payload, offset + STREAM_HEADER_SIZE)
	if read_error != nil && read_error != io.Error.EOF { delete(payload, allocator); return {}, nil, offset, false, read_error }
	if count != len(payload) { delete(payload, allocator); return {}, nil, offset, false, nil }
	return Stream_Kind(header[0]), payload, offset + STREAM_HEADER_SIZE + i64(length), true, nil
}

// stream_read returns one complete frame at offset, or found false for a missing file or partial frame. The caller deletes payload with allocator.
@(require_results)
stream_read :: proc(path: string, offset: i64, allocator := context.allocator) -> (Stream_Kind, []u8, i64, bool, os.Error) {
	reader, ok, open_error := stream_reader_open(path)
	if !ok { return {}, nil, offset, false, open_error }
	defer stream_reader_close(&reader)
	return stream_reader_read(&reader, offset, allocator)
}

// stream_remove removes path; a missing file is already removed.
@(require_results)
stream_remove :: proc(path: string) -> os.Error {
	error := os.remove(path)
	if error == os.General_Error.Not_Exist { return nil }
	return error
}
