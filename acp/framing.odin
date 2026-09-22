package acp

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

MAX_FRAME_BYTES :: 1024 * 1024
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
}
frame_decoder_init :: proc(max_frame_bytes := MAX_FRAME_BYTES, allocator := context.allocator) -> Frame_Decoder {
	return Frame_Decoder{buffer = make([dynamic]u8, 0, max_frame_bytes + 1, allocator), max_frame_bytes = max_frame_bytes, allocator = allocator}
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
			append(frames, strings.clone(string(line), decoder.allocator)); clear(&decoder.buffer); continue
		}
		append(&decoder.buffer, byte)
		if len(decoder.buffer) >
		   decoder.max_frame_bytes { clear(&decoder.buffer); decoder.discard_until_newline = true; if first_error == .None { first_error = .Frame_Too_Large } }
	}
	return first_error
}
