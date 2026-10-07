package acp

import "core:bytes"
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
@(require_results)
frame_decoder_init :: proc(allocator := context.allocator) -> (Frame_Decoder, mem.Allocator_Error) {
	buffer, buffer_error := make([dynamic]u8, allocator)
	if buffer_error != nil {
		return Frame_Decoder{allocator = allocator}, buffer_error
	}
	return Frame_Decoder{buffer = buffer, allocator = allocator}, nil
}

// frame_error_text returns the sentence a client reads for err, naming what the decoder
// refused. The result is a constant string the caller never frees.
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

// frame_decoder_destroy frees the decoder's frame buffer with the allocator that made it
// and leaves decoder inert. The frames already yielded belong to the caller, who frees
// them with frame_strings_destroy.
frame_decoder_destroy :: proc(decoder: ^Frame_Decoder) {
	delete(decoder.buffer)
	decoder^ = {}
}

// frame_strings_destroy frees every frame in frames with allocator, which must be the one
// frame_decoder_feed cloned them with, and frees the list itself.
frame_strings_destroy :: proc(frames: ^[dynamic]string, allocator := context.allocator) {
	for frame in frames^ {
		delete(frame, allocator)
	}
	delete(frames^)
}

// frame_decoder_feed consumes the next chunk of the stream and appends every frame it
// completes to frames, cloning each with the decoder's allocator so that frames owns them.
// It returns the first frame the chunk was refused for, or .None when it yielded them all,
// and it keeps reading the chunk after a refusal so that one bad frame does not hide the
// frames behind it. A frame is dropped whole: its bytes are never yielded in part.
@(require_results)
frame_decoder_feed :: proc(decoder: ^Frame_Decoder, chunk: []byte, frames: ^[dynamic]string) -> Frame_Error {
	first_error := Frame_Error.None
	rest := chunk
	for len(rest) > 0 {
		newline := bytes.index_byte(rest, '\n')
		piece := rest if newline < 0 else rest[:newline]
		rest = nil if newline < 0 else rest[newline + 1:]
		if !decoder.discard_until_newline {
			if _, append_error := append(&decoder.buffer, ..piece); append_error != nil {
				// The bytes of the frame under assembly went with the failed append, so the
				// rest of that frame is discarded rather than yielded shortened.
				clear(&decoder.buffer)
				decoder.discard_until_newline = true
				if first_error == .None {
					first_error = .Allocation
				}
			}
		}
		if newline < 0 { break }
		if decoder.discard_until_newline {
			decoder.discard_until_newline = false
			continue
		}
		frame_error := frame_end(decoder, frames)
		if frame_error != .None && first_error == .None {
			first_error = frame_error
		}
	}
	return first_error
}

// frame_end ends the frame the decoder has accumulated at its newline: the line terminator
// is stripped, an empty or non-UTF-8 frame is refused, and a frame the decoder can store is
// cloned with the decoder's allocator and appended to frames, which then owns it. The
// buffer is empty when it returns, whatever the outcome. It returns the reason the frame
// was refused, or .None when frames received it.
@(private, require_results)
frame_end :: proc(decoder: ^Frame_Decoder, frames: ^[dynamic]string) -> Frame_Error {
	defer clear(&decoder.buffer)
	length := len(decoder.buffer)
	if length > 0 && decoder.buffer[length - 1] == '\r' {
		length -= 1
	}
	if length == 0 {
		return .Empty_Frame
	}
	line := string(decoder.buffer[:length])
	if !utf8.valid_string(line) {
		return .Invalid_UTF8
	}
	frame, clone_error := strings.clone(line, decoder.allocator)
	if clone_error != nil {
		return .Allocation
	}
	if _, append_error := append(frames, frame); append_error != nil {
		delete(frame, decoder.allocator)
		return .Allocation
	}
	return .None
}
