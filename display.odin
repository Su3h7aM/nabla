package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import "nabla:agent"
import "nabla:agent/journal"

// Display owns the text sanitizer every transcript renderer needs: model output, tool
// output, user text, and diagnostics may carry cursor movement, erase commands, or OSC
// sequences, and only the renderer may emit controls. Stored content is never altered.

Display_San_State :: enum {
	Text,
	Esc,
	Csi,
	Osc,
	Osc_Esc,
}

// Display_Sanitizer drops terminal control sequences from untrusted text and passes
// ordinary text and newlines through. The state persists across chunks, so a sequence or a
// UTF-8 rune split over two fragments is still handled. The zero value is ready.
Display_Sanitizer :: struct {
	state:    Display_San_State,
	hold:     [4]u8, // incomplete UTF-8 tail carried into the next chunk,
	hold_len: int,
	after_cr: bool, // swallow one \n after a \r-mapped newline,
	skip_one: bool, // drop one byte: a charset-designation final,
}

// display_sanitize_chunk renders one fragment and returns text owned by allocator.
// A successful result transfers the builder's backing allocation to the caller.
// An allocation failure returns an empty string and releases the partial builder.
@(require_results)
display_sanitize_chunk :: proc(sanitizer: ^Display_Sanitizer, chunk: string, allocator := context.allocator) -> string {
	combined, combined_error := make([dynamic]u8, 0, sanitizer.hold_len + len(chunk), context.temp_allocator)
	if combined_error != nil { return "" }
	defer delete(combined)
	if append(&combined, ..sanitizer.hold[:sanitizer.hold_len]) != sanitizer.hold_len { return "" }
	if append(&combined, chunk) != len(chunk) { return "" }
	sanitizer.hold_len = 0
	builder, builder_error := strings.builder_make(allocator)
	if builder_error != nil { return "" }
	failed := false
	defer if failed { strings.builder_destroy(&builder) }
	i := 0
	for i < len(combined) && !failed {
		if sanitizer.skip_one {
			sanitizer.skip_one = false
			i += 1
			continue
		}
		c := combined[i]
		switch sanitizer.state {
		case .Text:
			switch {
			case c == 0x1B:
				sanitizer.state = .Esc
				i += 1
			case c == '\r':
				strings.write_byte(&builder, '\n')
				sanitizer.after_cr = true
				i += 1
			case c == '\n':
				if !sanitizer.after_cr { strings.write_byte(&builder, '\n') }
				sanitizer.after_cr = false
				i += 1
			case c == '\t':
				strings.write_byte(&builder, '\t')
				sanitizer.after_cr = false
				i += 1
			case c < 0x20 || c == 0x7F:
				sanitizer.after_cr = false
				i += 1
			case c < 0x80:
				strings.write_byte(&builder, c)
				sanitizer.after_cr = false
				i += 1
			case:
				remaining := combined[i:]
				if !utf8.full_rune_in_bytes(remaining) {
					copy(sanitizer.hold[:], remaining)
					sanitizer.hold_len = len(remaining)
					i = len(combined)
				} else {
					r, size := utf8.decode_rune_in_bytes(remaining)
					if r == utf8.RUNE_ERROR && size == 1 {
						if _, write_error := strings.write_rune(&builder, utf8.RUNE_ERROR); write_error != nil { failed = true }
						i += 1
					} else {
						if _, write_error := strings.write_rune(&builder, r); write_error != nil { failed = true }
						i += size
					}
					sanitizer.after_cr = false
				}
			}
		case .Esc:
			sanitizer.after_cr = false
			switch c {
			case '[', 0x9B:
				sanitizer.state = .Csi
			case ']', 0x9D, 0x9E, 0x9F, 0x90, 'P', 'X', '^', '_':
				sanitizer.state = .Osc
			case 0x9C:
				sanitizer.state = .Text
			case '(', ')', '#':
				sanitizer.state = .Text
				sanitizer.skip_one = true
			case 0x20 ..= 0x2F:
			// Intermediate byte: consume and stay for the final.
			case:
				sanitizer.state = .Text
			}
			i += 1
		case .Csi:
			if c == 0x1B {
				sanitizer.state = .Esc
			} else if c >= 0x40 && c <= 0x7E {
				sanitizer.state = .Text
			}
			i += 1
		case .Osc:
			if c == 0x07 {
				sanitizer.state = .Text
			} else if c == 0x1B {
				sanitizer.state = .Osc_Esc
			}
			i += 1
		case .Osc_Esc:
			if c == '\\' {
				sanitizer.state = .Text
			} else if c != 0x1B {
				sanitizer.state = .Osc
			}
			i += 1
		}
	}
	if failed { return "" }
	return strings.to_string(builder)
}

// display_sanitize_flush closes the stream: a dangling escape is dropped and
// a dangling rune fragment becomes U+FFFD. The returned replacement is owned by
// allocator.
@(require_results)
display_sanitize_flush :: proc(sanitizer: ^Display_Sanitizer, allocator := context.allocator) -> string {
	sanitizer.state = .Text
	sanitizer.after_cr = false
	sanitizer.skip_one = false
	if sanitizer.hold_len == 0 { return "" }
	sanitizer.hold_len = 0
	replacement, replacement_error := strings.clone("�", allocator)
	if replacement_error != nil { return "" }
	return replacement
}

@(require_results)
display_clean :: proc(text: string, allocator := context.allocator) -> string {
	sanitizer := Display_Sanitizer{}
	cleaned := display_sanitize_chunk(&sanitizer, text, allocator)
	tail := display_sanitize_flush(&sanitizer, allocator)
	defer delete(tail, allocator)
	if tail == "" { return cleaned }
	joined, join_error := strings.concatenate([]string{cleaned, tail}, allocator = allocator)
	if join_error != nil {
		delete(cleaned, allocator)
		return ""
	}
	delete(cleaned, allocator)
	return joined
}

// The display helpers below return text from the default temporary arena. Their callers
// consume it synchronously while building or flushing a frame, then the arena is reset;
// they do not transfer ownership to a later turn or session.

// retry_display_text says what a scheduled retry is, in words a person reads. The agent
// reports the failure class and the attempt numbers; turning them into a sentence for a
// user is the front-end's job, and this is the one place either front-end asks for it.
retry_display_text :: proc(event: agent.Chat_Retry_Event) -> string {
	reason := "the request failed"
	switch event.failure_class {
	case .Rate_Limited:
		reason = "the provider is rate limiting this session"
	case .Provider_Unavailable:
		reason = "the provider or the connection is unavailable"
	case .Incomplete_Stream:
		reason = "the response was cut off before it was complete"
	case .Invalid_Output:
		reason = "the response could not be read"
	case .Invalid_Request:
		#partial switch event.reason {
		case .Adaptive_Thinking_Refused:
			reason = "the endpoint refused the request; sending it again without adaptive thinking in case that caused it"
		case .Cache_Hints_Refused:
			reason = "the endpoint refused the request; sending it again without its cache hints in case they caused it"
		case:
			reason = "the endpoint refused the request"
		}
	case .None, .Unknown, .Authentication, .Quota, .Not_Found, .Context_Overflow, .Payload_Too_Large, .Content_Policy, .Untrusted_Connection:
	}
	return fmt.tprintf("%s; retrying in %s (attempt %d)", reason, display_duration(event.delay), event.next_attempt)
}

// display_duration renders a wait the way a reader measures one: tenths of a second while
// it is short, whole seconds once it is not.
display_duration :: proc(delay: time.Duration) -> string {
	seconds := time.duration_seconds(delay)
	if seconds < 10 { return fmt.tprintf("%.1fs", seconds) }
	return fmt.tprintf("%.0fs", seconds)
}

// Tool_Display_Call is the part of a tool call the transcript box shows. The name is
// borrowed from the caller and the prompt is decoded into the temporary allocator, so a
// caller that keeps the call past its own temporary scope must clone the prompt into
// memory that lives as long as the call does.
Tool_Display_Call :: struct {
	name:   string,
	prompt: Maybe(string),
}

// tool_display_call borrows name and decodes a start prompt into the temporary allocator. A
// start without a prompt text has none to show, so its box falls back to the result.
tool_display_call :: proc(name, arguments: string) -> Tool_Display_Call {
	call := Tool_Display_Call {
		name = name,
	}
	if name != agent.TOOL_AGENT_NAME { return call }
	args: struct {
		action: string,
		prompt: Maybe(string),
	}
	if json.unmarshal_string(arguments, &args, allocator = context.temp_allocator) != nil { return call }
	if prompt, present := args.prompt.?; present && args.action == "start" && strings.trim_space(prompt) != "" { call.prompt = prompt }
	return call
}

// tool_entry_text renders a start call's prompt, or the result preview of another call.
// A failed start shows the prompt and then the same preview a non-start box would show,
// so the failure reason is not lost behind the prompt.
tool_entry_text :: proc(call: Tool_Display_Call, content, fallback: string, outcome: journal.Tool_Outcome) -> string {
	preview := tool_display_preview(content)
	if preview == "" { preview = fallback }
	if prompt, present := call.prompt.?; present {
		if outcome == .Success { return fmt.tprintf("%s\n%s", call.name, prompt) }
		return fmt.tprintf("%s\n%s\n%s", call.name, prompt, preview)
	}
	return fmt.tprintf("%s\n%s", call.name, preview)
}

tool_display_preview :: proc(content: string) -> string {
	return agent.tool_result_body(content)
}

// tool_display_summary renders one result line for the transcript. The full rendering goes to
// the model; a human gets the tool's own short line and the outcome name when it has none.
tool_display_summary :: proc(result: ^agent.Tool_Result) -> string {
	if result.reason != "" { return result.reason }
	return journal.TOOL_OUTCOME_NAMES[result.outcome]
}
