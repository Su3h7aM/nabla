package acp

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// Frame_Decoder turns a byte stream into newline-delimited frames. ACP imposes no frame
// size, so a frame is as large as the peer sends and the buffer grows to hold it.
Frame_Decoder :: struct {
	buffer:                [dynamic]u8,
	allocator:             mem.Allocator,
	discard_until_newline: bool,
}
Frame_Error :: enum {
	None,
	Invalid_UTF8,
	Empty_Frame,
	Allocation,
}
// frame_decoder_init returns a decoder that clones every frame it yields with allocator,
// which owns those frames until frame_strings_destroy frees them. It returns the error
// from creating the frame buffer.
frame_decoder_init :: proc(allocator := context.allocator) -> (Frame_Decoder, mem.Allocator_Error) {
	buffer, buffer_error := make([dynamic]u8, allocator)
	if buffer_error != nil {
		return Frame_Decoder{allocator = allocator}, buffer_error
	}
	return Frame_Decoder{buffer = buffer, allocator = allocator}, nil
}
// frame_error_text says what a decoder refused, in the words the client reads.
frame_error_text :: proc(err: Frame_Error) -> string {
	switch err {
	case .None:
		return ""
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
		}
	}
	return first_error
}
