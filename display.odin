package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import "nabla:agent"
import "nabla:agent/session"

// Display owns the text sanitizer every transcript renderer needs. Model
// output, tool output, user text, and diagnostics may carry cursor movement,
// erase commands, or OSC sequences, and only the renderer may emit controls,
// so untrusted text is cleaned before it is drawn. Stored conversation
// content is never altered for display.

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

// retry_display_text says what a scheduled retry is, in words a person reads. The agent
// reports the failure class and the attempt numbers; turning them into a sentence for a
// user is the front-end's job, and this is the one place either front-end asks for it.
retry_display_text :: proc(event: agent.Chat_Retry_Event) -> string {
	reason := "the attempt did not complete"
	switch event.failure_class {
	case .Rate_Limited:
		reason = "the provider is rate limiting this session"
	case .Provider_Unavailable:
		reason = "the provider is unavailable"
	case .Incomplete_Stream:
		reason = "the response ended before it was complete"
	case .None, .Unknown, .Authentication, .Quota, .Context_Overflow, .Payload_Too_Large, .Invalid_Request, .Content_Policy, .Invalid_Output:
	}
	return fmt.tprintf("%s; retrying in %s (attempt %d of %d)", reason, display_duration(event.delay), event.next_attempt, event.max_attempts)
}

// display_duration renders a wait the way a reader measures one: tenths of a second while
// it is short, whole seconds once it is not.
display_duration :: proc(delay: time.Duration) -> string {
	seconds := time.duration_seconds(delay)
	if seconds < 10 { return fmt.tprintf("%.1fs", seconds) }
	return fmt.tprintf("%.0fs", seconds)
}

// tool_display_preview extracts the tool's useful payload from the model-facing
// result envelope. JSON string escapes are decoded by the parser, so newlines
// become display lines instead of literal backslash-n text.
tool_display_preview :: proc(result: ^agent.Tool_Result) -> string {
	if result == nil || result.content == "" { return "" }
	value, parse_err := json.parse_string(result.content, .JSON, true, context.temp_allocator)
	if parse_err != nil { return "" }
	defer json.destroy_value(value, context.temp_allocator)
	envelope, envelope_ok := value.(json.Object)
	if !envelope_ok { return "" }
	data, data_ok := envelope["data"].(json.Object)
	if data_ok {
		stdout := ""
		stderr := ""
		if value, ok := data["stdout"].(json.String); ok { stdout = string(value) }
		if value, ok := data["stderr"].(json.String); ok { stderr = string(value) }
		if stdout != "" && stderr != "" {
			return fmt.tprintf("%s\n%s", stdout, stderr)
		}
		if stdout != "" { return strings.clone(stdout, context.temp_allocator) }
		if stderr != "" { return strings.clone(stderr, context.temp_allocator) }
		if content, ok := data["content"].(json.String); ok {
			return strings.clone(string(content), context.temp_allocator)
		}
		if blocks, ok := data["content"].(json.Array); ok {
			for block in blocks {
				if object, object_ok := block.(json.Object); object_ok {
					if text, text_ok := object["text"].(json.String); text_ok {
						return strings.clone(string(text), context.temp_allocator)
					}
				}
			}
		}
	}
	if message, ok := envelope["message"].(json.String); ok {
		return strings.clone(string(message), context.temp_allocator)
	}
	return ""
}

// tool_display_summary renders one result line for the transcript. The full
// JSON envelope goes to the model; a human gets the tool's own short line and
// the outcome name when it has none.
tool_display_summary :: proc(result: ^agent.Tool_Result) -> string {
	if result.reason != "" { return result.reason }
	return session.tool_outcome_name(result.outcome)
}
