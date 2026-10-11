package acp

import "core:bufio"
import "core:bytes"
import "core:io"
import "core:mem"
import "core:unicode/utf8"

Frame_Error :: enum {
	None,
	Invalid_UTF8,
	Empty_Frame,
	Allocation,
}

// frame_split is a bufio.Split_Proc that returns each newline-terminated frame of the stream,
// without the newline and an optional preceding carriage return, and returns an empty line
// as an empty frame. It is bufio.scan_lines except that bytes the stream ends with, after its
// last newline, return no frame: a message is newline-terminated, so an unterminated tail is
// a message its peer never finished.
frame_split :: proc(data: []byte, at_eof: bool) -> (advance: int, token: []byte, err: bufio.Scanner_Error, final_token: bool) {
	newline := bytes.index_byte(data, '\n')
	if newline < 0 {
		if at_eof {
			advance = len(data)
		}
		return
	}
	token = data[:newline]
	if len(token) > 0 && token[len(token) - 1] == '\r' {
		token = token[:len(token) - 1]
	}
	return newline + 1, token, nil, false
}

// frame_scanner_init prepares scanner to read newline-delimited frames from stream with
// bufio.scan, split by frame_split. ACP imposes no frame size, so the scanner's buffer grows
// to hold whatever the peer sends. The buffer belongs to allocator until the caller's
// bufio.scanner_destroy, and every token borrows from it until the next scan.
frame_scanner_init :: proc(scanner: ^bufio.Scanner, stream: io.Reader, allocator: mem.Allocator) {
	bufio.scanner_init(scanner, stream, allocator)
	scanner.split = frame_split
	scanner.max_token_size = max(int)
}

// frame_check returns why frame, a token from a frame scanner, is refused: .Empty_Frame for a
// line with nothing on it and .Invalid_UTF8 for bytes that are not text. A refused frame is
// dropped whole, and the scanner goes on to the frames behind it.
frame_check :: proc(frame: string) -> Frame_Error {
	if len(frame) == 0 {
		return .Empty_Frame
	}
	if !utf8.valid_string(frame) {
		return .Invalid_UTF8
	}
	return .None
}

// frame_error_text returns the sentence a client reads for err, naming what was
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

// frame_strings_destroy frees every frame in frames with allocator, which must be the one
// that allocated them, and frees the list itself.
frame_strings_destroy :: proc(frames: ^[dynamic]string, allocator := context.allocator) {
	for frame in frames^ {
		delete(frame, allocator)
	}
	delete(frames^)
}
