package text

import "base:runtime"
import "core:unicode/utf8"

Sanitizer_State :: enum u8 {
	Text,
	Escape,
	Control_Sequence,
	String,
}

// Sanitizer carries state between chunks. The zero value is ready to use.
Sanitizer :: struct {
	state:    Sanitizer_State,
	hold:     [utf8.UTF_MAX - 1]u8,
	hold_len: u8,
	after_cr: bool,
}

@(private = "file")
INVALID_RUNE :: rune(-1)

// sanitizer_write appends the safe text of chunk to buffer. Chunks may split anywhere.
//
//   - Escape sequences are removed whole: ESC-introduced, CSI (ESC [ or U+009B), and
//     strings (ESC ], P, X, ^, _ or U+009D) ended by BEL, ESC \ or U+009C.
//   - CRLF and lone CR become LF.
//   - Other C0 controls, DEL and C1 controls are removed; TAB and LF are kept.
//   - Each byte core:unicode/utf8 rejects becomes U+FFFD, so the result does not depend
//     on where chunks split.
//
// The only error is an allocation failure of buffer.
sanitizer_write :: proc(sanitizer: ^Sanitizer, buffer: ^[dynamic]u8, chunk: string) -> runtime.Allocator_Error {
	rest := chunk
	if sanitizer.hold_len > 0 {
		held := int(sanitizer.hold_len)
		head: [utf8.UTF_MAX]u8
		copy(head[:], sanitizer.hold[:held])
		length := held + copy(head[held:], rest)
		if !utf8.full_rune(head[:length]) {
			copy(sanitizer.hold[:], head[:length])
			sanitizer.hold_len = u8(length)
			return nil
		}
		sanitizer.hold_len = 0
		r, size := utf8.decode_rune(head[:length])
		if r == utf8.RUNE_ERROR && size == 1 {
			// Held bytes are a lead and continuations, each rejected alone; chunk bytes are re-read.
			for _ in 0 ..< held {
				sanitizer_step(sanitizer, buffer, INVALID_RUNE) or_return
			}
		} else {
			sanitizer_step(sanitizer, buffer, r) or_return
			rest = rest[size - held:]
		}
	}
	for len(rest) > 0 {
		r, size := utf8.decode_rune(rest)
		if r == utf8.RUNE_ERROR && size == 1 {
			if !utf8.full_rune(rest) {
				copy(sanitizer.hold[:], rest)
				sanitizer.hold_len = u8(len(rest))
				return nil
			}
			sanitizer_step(sanitizer, buffer, INVALID_RUNE) or_return
		} else {
			sanitizer_step(sanitizer, buffer, r) or_return
		}
		rest = rest[size:]
	}
	return nil
}

// sanitizer_flush ends the stream and resets sanitizer. A cut-off rune becomes one
// U+FFFD per byte and an unterminated escape sequence is dropped. The only error is an
// allocation failure of buffer.
sanitizer_flush :: proc(sanitizer: ^Sanitizer, buffer: ^[dynamic]u8) -> runtime.Allocator_Error {
	if sanitizer.state == .Text {
		for _ in 0 ..< sanitizer.hold_len {
			append_rune(buffer, utf8.RUNE_ERROR) or_return
		}
	}
	sanitizer^ = {}
	return nil
}

// sanitize_text returns value sanitized as one whole stream, owned by allocator.
@(require_results)
sanitize_text :: proc(value: string, allocator := context.allocator) -> (result: string, err: runtime.Allocator_Error) {
	buffer := make([dynamic]u8, 0, len(value), allocator) or_return
	sanitizer: Sanitizer
	if err = sanitizer_write(&sanitizer, &buffer, value); err == nil {
		err = sanitizer_flush(&sanitizer, &buffer)
	}
	if err != nil {
		delete(buffer)
		return "", err
	}
	return string(buffer[:]), nil
}

@(private = "file")
append_rune :: proc(buffer: ^[dynamic]u8, r: rune) -> runtime.Allocator_Error {
	encoded, width := utf8.encode_rune(r)
	_, err := append(buffer, ..encoded[:width])
	return err
}

@(private = "file")
sanitizer_step :: proc(sanitizer: ^Sanitizer, buffer: ^[dynamic]u8, r: rune) -> runtime.Allocator_Error {
	for {
		switch sanitizer.state {
		case .Text:
			after_cr := sanitizer.after_cr
			sanitizer.after_cr = false
			switch r {
			case 0x1B:
				sanitizer.state = .Escape
			case 0x9B:
				sanitizer.state = .Control_Sequence
			case 0x9D:
				sanitizer.state = .String
			case '\r':
				sanitizer.after_cr = true
				append_rune(buffer, '\n') or_return
			case '\n':
				if !after_cr { append_rune(buffer, '\n') or_return }
			case '\t':
				append_rune(buffer, '\t') or_return
			case INVALID_RUNE:
				append_rune(buffer, utf8.RUNE_ERROR) or_return
			case 0 ..< 0x20, 0x7F ..= 0x9F:
			case:
				append_rune(buffer, r) or_return
			}
			return nil
		case .Escape:
			switch {
			case r == 0x1B, 0x20 <= r && r <= 0x2F:
			case r == '[':
				sanitizer.state = .Control_Sequence
			case r == ']', r == 'P', r == 'X', r == '^', r == '_':
				sanitizer.state = .String
			case 0x30 <= r && r <= 0x7E:
				sanitizer.state = .Text
			case:
				sanitizer.state = .Text
				continue
			}
			return nil
		case .Control_Sequence:
			switch {
			case r == 0x1B:
				sanitizer.state = .Escape
			case 0x20 <= r && r <= 0x3F:
			case 0x40 <= r && r <= 0x7E:
				sanitizer.state = .Text
			case:
				sanitizer.state = .Text
				continue
			}
			return nil
		case .String:
			switch r {
			case 0x07, 0x9C:
				sanitizer.state = .Text
			case 0x1B:
				sanitizer.state = .Escape
			}
			return nil
		}
	}
}
