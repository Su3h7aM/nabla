package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import "core:unicode"
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
// borrowed from the caller and the prompt and the Code Mode program are decoded into
// the temporary allocator, so a caller that keeps the call past its own temporary
// scope must clone them into memory that lives as long as the call does.
Tool_Display_Call :: struct {
	name:   string,
	prompt: Maybe(string),
	code:   Maybe(string),
}

// tool_display_call borrows name and decodes a start prompt, or a Code Mode program,
// into the temporary allocator. A start without a prompt text has none to show, so its
// box falls back to the result, and a codemode call without a program text does the same.
tool_display_call :: proc(name, arguments: string) -> Tool_Display_Call {
	call := Tool_Display_Call {
		name = name,
	}
	if name == agent.TOOL_AGENT_NAME {
		args: struct {
			action: string,
			prompt: Maybe(string),
		}
		if json.unmarshal_string(arguments, &args, allocator = context.temp_allocator) != nil { return call }
		if prompt, present := args.prompt.?; present && args.action == "start" && strings.trim_space(prompt) != "" { call.prompt = prompt }
		return call
	}
	if name == agent.TOOL_CODEMODE_NAME {
		args: struct {
			code: Maybe(string),
		}
		if json.unmarshal_string(arguments, &args, allocator = context.temp_allocator) != nil { return call }
		if code, present := args.code.?; present && strings.trim_space(code) != "" { call.code = code }
		return call
	}
	return call
}

// tool_entry_text renders a start call's prompt, or the result preview of another call.
// A failed start shows the prompt and then the same preview a non-start box would show,
// so the failure reason is not lost behind the prompt.
tool_entry_text :: proc(call: Tool_Display_Call, content, fallback: string, outcome: journal.Tool_Outcome) -> string {
	return tool_entry_text_titled(call, call.name, content, fallback, outcome)
}

// tool_entry_text_titled renders the same box under another title. A Code Mode inner
// call keeps its own result preview, so its box reads like a normal tool box that is
// titled for the script that ran it.
tool_entry_text_titled :: proc(call: Tool_Display_Call, title, content, fallback: string, outcome: journal.Tool_Outcome) -> string {
	preview := tool_display_preview(content)
	if preview == "" { preview = fallback }
	if prompt, present := call.prompt.?; present {
		if outcome == .Success { return fmt.tprintf("%s\n%s", title, prompt) }
		return fmt.tprintf("%s\n%s\n%s", title, prompt, preview)
	}
	return fmt.tprintf("%s\n%s", title, preview)
}

// Codemode_Inner is one call a Code Mode script made, as the script's box lists it:
// the call's journal id, the tool, the arguments it ran with, and how it ended. While
// running is set the call has no outcome yet. The strings are borrowed.
Codemode_Inner :: struct {
	call:      journal.Call_Id,
	name:      string,
	arguments: string,
	outcome:   journal.Tool_Outcome,
	running:   bool,
}

// codemode_inner_title is the title of one inner call's box: the script and the tool
// it ran. Live and replay share it so the two boxes read the same.
codemode_inner_title :: proc(name: string) -> string {
	return fmt.tprintf("codemode · %s", name)
}

// CODEMODE_ARGUMENT_PREVIEW_BYTES is how much of an inner call's arguments its
// script's box lists: the collapsed text, cut at a UTF-8 boundary.
CODEMODE_ARGUMENT_PREVIEW_BYTES :: 80

// codemode_arguments_preview collapses an inner call's arguments to one line: newlines
// and runs of whitespace become single spaces, and text past the preview budget is cut
// with an ellipsis. The result is temporary, like every other display helper.
codemode_arguments_preview :: proc(arguments: string) -> string {
	builder, builder_error := strings.builder_make(0, CODEMODE_ARGUMENT_PREVIEW_BYTES + len("…"), context.temp_allocator)
	if builder_error != nil { return "" }
	pending_space := false
	remaining := arguments
	for len(remaining) > 0 && len(builder.buf) < CODEMODE_ARGUMENT_PREVIEW_BYTES {
		character, width := utf8.decode_rune_in_string(remaining)
		if unicode.is_space(character) {
			pending_space = len(builder.buf) > 0
			remaining = remaining[width:]
			continue
		}
		// Decoding an invalid byte returns RUNE_ERROR with width one; encoding it
		// writes a valid replacement rune instead of passing invalid UTF-8 through.
		encoded, encoded_width := utf8.encode_rune(character)
		space_bytes := 1 if pending_space else 0
		if len(builder.buf) + space_bytes + encoded_width > CODEMODE_ARGUMENT_PREVIEW_BYTES { break }
		if pending_space {
			if strings.write_byte(&builder, ' ') != 1 { return "" }
			pending_space = false
		}
		if strings.write_string(&builder, string(encoded[:encoded_width])) != encoded_width { return "" }
		remaining = remaining[width:]
	}
	if len(remaining) > 0 {
		if strings.write_string(&builder, "…") != len("…") { return "" }
	}
	return strings.to_string(builder)
}

// codemode_entry_text renders a Code Mode call's box: the title, the program, one
// line per inner call in admission order, and the result preview. A running inner
// call reads `… <tool> <arguments>`. A script with no inner calls omits the call
// lines and their blank line, and a call without a program text falls back to the
// preview-only box other calls show. Live, follower, and replay share it so the boxes
// read the same.
codemode_entry_text :: proc(call: Tool_Display_Call, content, fallback: string, outcome: journal.Tool_Outcome, inner: []Codemode_Inner) -> string {
	preview := tool_display_preview(content)
	if preview == "" { preview = fallback }
	code, present := call.code.?
	if !present { return tool_entry_text(call, content, fallback, outcome) }
	builder, builder_error := strings.builder_make(context.temp_allocator)
	if builder_error != nil { return tool_entry_text(call, content, fallback, outcome) }
	strings.write_string(&builder, call.name)
	strings.write_byte(&builder, '\n')
	strings.write_string(&builder, code)
	strings.write_byte(&builder, '\n')
	if len(inner) > 0 {
		strings.write_byte(&builder, '\n')
		for entry in inner {
			glyph := "✗"
			if entry.running {
				glyph = "…"
			} else {
				switch entry.outcome {
				case .Success:
					glyph = "✓"
				case .Cancelled:
					glyph = "⊘"
				case .Tool_Failed, .Invalid_Arguments, .Denied, .Unavailable, .Not_Executed, .Transport_Failed, .Timed_Out, .Unknown:
				}
			}
			strings.write_string(&builder, glyph)
			strings.write_byte(&builder, ' ')
			strings.write_string(&builder, entry.name)
			strings.write_byte(&builder, ' ')
			strings.write_string(&builder, codemode_arguments_preview(entry.arguments))
			strings.write_byte(&builder, '\n')
		}
	}
	strings.write_byte(&builder, '\n')
	strings.write_string(&builder, preview)
	return strings.to_string(builder)
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
