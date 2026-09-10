package main

import "core:fmt"
import "core:io"
import "core:strings"
import "core:unicode/utf8"

import "nabla:agent"
import "nabla:ai"

// Display owns transcript rendering on the interactive path: role labels and
// diagnostic lines go through here, so a later terminal owner takes over one
// funnel instead of many print sites. Plain text only: no color, no cursor
// movement. The labels carry the meaning with NO_COLOR set.
//
// Streams stay split: transcript and notices on stdout, warnings and errors
// on stderr. Stored conversation content is never altered for display.
//
// Every text argument is sanitized before display: model output, tool
// output, user text, and diagnostics may carry cursor movement, erase
// commands, or OSC sequences, and only the renderer may emit controls.

display_interactive: bool // set once from terminal detection; layout reads it later,

display_set_interactive :: proc(interactive: bool) {
	display_interactive = interactive
}

display_user :: proc(text: string) {
	cleaned := display_clean(text)
	defer delete(cleaned)
	fmt.println("You")
	fmt.println(cleaned)
	fmt.println()
}

display_assistant_begin :: proc() {
	fmt.println("Assistant")
}

display_assistant_end :: proc(output: io.Writer) {
	io.write_string(output, "\n")
}

display_tool :: proc(name, detail: string) {
	cleaned := display_clean(detail)
	defer delete(cleaned)
	fmt.println("Tool ·", name)
	fmt.println(cleaned)
	fmt.println()
}

display_notice :: proc(message: string) {
	cleaned := display_clean(message)
	defer delete(cleaned)
	fmt.println(cleaned)
}

display_warning :: proc(message: string) {
	cleaned := display_clean(message)
	defer delete(cleaned)
	fmt.eprintln("warning:", cleaned)
}

display_error :: proc(message: string) {
	cleaned := display_clean(message)
	defer delete(cleaned)
	fmt.eprintln("error:", cleaned)
}

display_queue_ack :: proc(depth: int) {
	fmt.eprintf("[queued %d]\n", depth)
}

display_queue_full :: proc() {
	fmt.eprint("[steering queue full, input dropped]\n")
}

display_usage :: proc(operation: u64, usage: ai.Provider_Usage_Event) {
	fmt.eprintf("tokens [request %d]:", operation)
	if usage.Input_Tokens_Present { fmt.eprintf(" input %d", usage.Input_Tokens) } else { fmt.eprint(" input unknown") }
	if usage.Cached_Input_Tokens_Present {
		fmt.eprintf(", cached %d", usage.Cached_Input_Tokens)
	} else {
		fmt.eprint(", cached unknown")
	}
	if usage.Cache_Write_Tokens_Present { fmt.eprintf(", write %d", usage.Cache_Write_Tokens) }
	if usage.Output_Tokens_Present { fmt.eprintf(", output %d", usage.Output_Tokens) } else { fmt.eprint(", output unknown") }
	fmt.eprintln()
}

// tool_display_summary renders one result line for the transcript. The full
// JSON goes to the model; a human gets the outcome.
tool_display_summary :: proc(result: ^agent.Tool_Result) -> string {
	#partial switch result.status {
	case .Exited:
		if result.stdout_trunc || result.stderr_trunc || result.output_trunc {
			return fmt.tprintf("exited %d (output truncated)", result.exit_code)
		}
		return fmt.tprintf("exited %d", result.exit_code)
	case .Timed_Out:
		return "timed out"
	case .Cancelled:
		return "cancelled"
	case:
		if result.error_text != "" { return result.error_text }
		return "not executed"
	}
}

Display_San_State :: enum {
	Text,
	Esc,
	Csi,
	Osc,
	Osc_Esc,
}

// Display_Sanitizer drops terminal control sequences from untrusted text
// while passing ordinary text and newlines through. State persists across
// chunks, so a sequence split over two stream fragments is still dropped and
// a UTF-8 rune split the same way is still completed. The zero value is
// ready: plain text with no pending state.
Display_Sanitizer :: struct {
	state:    Display_San_State,
	hold:     [4]u8, // incomplete UTF-8 tail carried into the next chunk,
	hold_len: int,
	after_cr: bool, // swallow one \n after a \r-mapped newline,
	skip_one: bool, // drop one byte: a charset-designation final,
}

display_utf8_len :: proc(lead: u8) -> int {
	switch {
	case lead < 0x80:
		return 1
	case lead >> 5 == 0b110:
		return 2
	case lead >> 4 == 0b1110:
		return 3
	case lead >> 3 == 0b11110:
		return 4
	}
	return 0
}

// display_sanitize_chunk renders one fragment and returns owned text.
// display_sanitize_flush closes the stream: a dangling escape is dropped and
// a dangling rune fragment becomes U+FFFD.
display_sanitize_chunk :: proc(san: ^Display_Sanitizer, chunk: string, allocator := context.allocator) -> string {
	combined := make([dynamic]u8, 0, san.hold_len + len(chunk), context.temp_allocator)
	defer delete(combined)
	append(&combined, ..san.hold[:san.hold_len])
	append(&combined, chunk)
	san.hold_len = 0
	builder := strings.builder_make(allocator)
	i := 0
	for i < len(combined) {
		if san.skip_one {
			san.skip_one = false
			i += 1
			continue
		}
		c := combined[i]
		switch san.state {
		case .Text:
			switch {
			case c == 0x1B:
				san.state = .Esc
				i += 1
			case c == '\r':
				strings.write_byte(&builder, '\n')
				san.after_cr = true
				i += 1
			case c == '\n':
				if !san.after_cr { strings.write_byte(&builder, '\n') }
				san.after_cr = false
				i += 1
			case c == '\t':
				strings.write_byte(&builder, '\t')
				san.after_cr = false
				i += 1
			case c < 0x20 || c == 0x7F:
				san.after_cr = false
				i += 1
			case c < 0x80:
				strings.write_byte(&builder, c)
				san.after_cr = false
				i += 1
			case:
				need := display_utf8_len(c)
				if need == 0 {
					strings.write_rune(&builder, utf8.RUNE_ERROR)
					san.after_cr = false
					i += 1
				} else if i + need > len(combined) {
					copy(san.hold[:], combined[i:])
					san.hold_len = len(combined) - i
					i = len(combined)
				} else {
					valid := true
					for k in 1 ..< need {
						if combined[i + k] < 0x80 || combined[i + k] > 0xBF { valid = false }
					}
					if valid {
						for k in 0 ..< need { strings.write_byte(&builder, combined[i + k]) }
						i += need
					} else {
						strings.write_rune(&builder, utf8.RUNE_ERROR)
						i += 1
					}
					san.after_cr = false
				}
			}
		case .Esc:
			san.after_cr = false
			switch c {
			case '[', 0x9B:
				san.state = .Csi
			case ']', 0x9D, 0x9E, 0x9F, 0x90, 'P', 'X', '^', '_':
				san.state = .Osc
			case 0x9C:
				san.state = .Text
			case '(', ')', '#':
				san.state = .Text
				san.skip_one = true
			case 0x20 ..= 0x2F:
			// Intermediate byte: consume and stay for the final.
			case:
				san.state = .Text
			}
			i += 1
		case .Csi:
			if c == 0x1B {
				san.state = .Esc
			} else if c >= 0x40 && c <= 0x7E {
				san.state = .Text
			}
			i += 1
		case .Osc:
			if c == 0x07 {
				san.state = .Text
			} else if c == 0x1B {
				san.state = .Osc_Esc
			}
			i += 1
		case .Osc_Esc:
			if c == '\\' {
				san.state = .Text
			} else if c != 0x1B {
				san.state = .Osc
			}
			i += 1
		}
	}
	return strings.to_string(builder)
}

display_sanitize_flush :: proc(san: ^Display_Sanitizer, allocator := context.allocator) -> string {
	san.state = .Text
	san.after_cr = false
	san.skip_one = false
	if san.hold_len == 0 { return "" }
	san.hold_len = 0
	return strings.clone("�", allocator)
}

display_clean :: proc(text: string, allocator := context.allocator) -> string {
	san := Display_Sanitizer{}
	cleaned := display_sanitize_chunk(&san, text, allocator)
	tail := display_sanitize_flush(&san, allocator)
	defer delete(tail, allocator)
	if tail == "" { return cleaned }
	joined := strings.concatenate([]string{cleaned, tail}, allocator = allocator)
	delete(cleaned, allocator)
	return joined
}

// display_stream_text sanitizes one streamed fragment and writes it. The
// sanitizer outlives the call so sequences split across fragments stay
// dropped; flush it when the request ends.
display_stream_text :: proc(output: io.Writer, san: ^Display_Sanitizer, chunk: string) {
	cleaned := display_sanitize_chunk(san, chunk)
	defer delete(cleaned)
	io.write_string(output, cleaned)
}

display_stream_flush :: proc(output: io.Writer, san: ^Display_Sanitizer) {
	tail := display_sanitize_flush(san)
	defer delete(tail)
	if tail != "" { io.write_string(output, tail) }
}
