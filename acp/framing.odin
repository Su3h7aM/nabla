package acp

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// MAX_FRAME_BYTES matches Buzz's ACP line budget. ACP itself does not impose a
// frame limit; this is Nabla's allocation and denial-of-service boundary.
MAX_FRAME_BYTES :: 10_000_000
Frame_Decoder :: struct {
	buffer:                [dynamic]u8,
	max_frame_bytes:       int,
	allocator:             mem.Allocator,
	discard_until_newline: bool,
}
Frame_Error :: enum {
	None,
	Frame_Too_Large,
	Invalid_UTF8,
	Empty_Frame,
	Allocation,
}
frame_decoder_init :: proc(max_frame_bytes := MAX_FRAME_BYTES, allocator := context.allocator) -> (Frame_Decoder, mem.Allocator_Error) {
	initial_capacity := min(max_frame_bytes + 1, 64 * 1024)
	buffer, buffer_error := make([dynamic]u8, 0, initial_capacity, allocator)
	if buffer_error != nil {
		return Frame_Decoder{max_frame_bytes = max_frame_bytes, allocator = allocator}, buffer_error
	}
	return Frame_Decoder{buffer = buffer, max_frame_bytes = max_frame_bytes, allocator = allocator}, nil
}
// frame_error_text says what a decoder refused, in the words the client reads.
frame_error_text :: proc(err: Frame_Error) -> string {
	switch err {
	case .None:
		return ""
	case .Frame_Too_Large:
		return "the message exceeds the maximum frame size"
	case .Invalid_UTF8:
		return "the message is not valid UTF-8"
	case .Empty_Frame:
		return "the message is empty"
	case .Allocation:
		return "the message could not be stored"
	}
	return "the message could not be read"
}

frame_decoder_destroy :: proc(decoder: ^Frame_Decoder) { delete(decoder.buffer); decoder^ = {} }
frame_strings_destroy :: proc(frames: ^[dynamic]string, allocator := context.allocator) { for frame in frames^ { delete(frame, allocator) }; delete(frames^) }
frame_decoder_feed :: proc(decoder: ^Frame_Decoder, chunk: []byte, frames: ^[dynamic]string) -> Frame_Error {
	first_error := Frame_Error.None
	for byte in chunk {
		if decoder.discard_until_newline {
			if byte == '\n' { decoder.discard_until_newline = false }
			continue
		}
		if byte == '\n' {
			frame_len := len(decoder.buffer)
			if frame_len > 0 && decoder.buffer[frame_len - 1] == '\r' { frame_len -= 1 }
			if frame_len == 0 { clear(&decoder.buffer); if first_error == .None { first_error = .Empty_Frame }; continue }
			line := decoder.buffer[:frame_len]
			if !utf8.valid_string(string(line)) { if first_error == .None { first_error = .Invalid_UTF8 }; clear(&decoder.buffer); continue }
			frame, clone_error := strings.clone(string(line), decoder.allocator)
			if clone_error != nil { clear(&decoder.buffer); if first_error == .None { first_error = .Allocation }; continue }
			if append(frames, frame) != 1 {
				delete(frame, decoder.allocator)
				clear(&decoder.buffer)
				if first_error == .None { first_error = .Allocation }
				continue
			}
			clear(&decoder.buffer)
			continue
		}
		if append(&decoder.buffer, byte) != 1 {
			clear(&decoder.buffer)
			decoder.discard_until_newline = true
			if first_error == .None { first_error = .Allocation }
			continue
		}
		if len(decoder.buffer) > decoder.max_frame_bytes {
			clear(&decoder.buffer)
			decoder.discard_until_newline = true
			if first_error == .None { first_error = .Frame_Too_Large }
		}
	}
	return first_error
}
