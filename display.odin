package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import "core:unicode"
import "core:unicode/utf8"

import "nabla:agent"
import "nabla:agent/journal"

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
	preview := tool_preview(content, fallback)
	if prompt, present := call.prompt.?; present {
		if outcome == .Success { return fmt.tprintf("%s\n%s", title, prompt) }
		return fmt.tprintf("%s\n%s\n%s", title, prompt, preview)
	}
	return fmt.tprintf("%s\n%s", title, preview)
}

// text_last_lines returns a view of the last count lines of text, or all of it when it
// has fewer. A newline that ends the text ends its last line and does not start another.
text_last_lines :: proc(text: string, count: int) -> string {
	body := text
	if strings.has_suffix(body, "\n") { body = body[:len(body) - 1] }
	start := len(body)
	for _ in 0 ..< count {
		newline := strings.last_index_byte(body[:start], '\n')
		if newline < 0 { return text }
		start = newline
	}
	return text[start + 1:]
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
	preview := tool_preview(content, fallback)
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

// tool_preview is the result text a box ends with: the body of content, or fallback when it has none.
tool_preview :: proc(content, fallback: string) -> string {
	preview := tool_display_preview(content)
	if preview == "" { return fallback }
	return preview
}

// tool_text_collapse cuts the result preview that ends text to its first TOOL_WINDOW_ROWS lines.
// It returns the kept text, the offset where the preview starts, and the number of lines cut.
tool_text_collapse :: proc(text, preview: string) -> (kept: string, preview_at: int, hidden: int) {
	if !strings.has_suffix(text, preview) { return text, len(text), 0 }
	preview_at = len(text) - len(preview)
	counted := preview
	if strings.has_suffix(counted, "\n") { counted = counted[:len(counted) - 1] }
	cut := 0
	for _ in 0 ..< TOOL_WINDOW_ROWS {
		newline := strings.index_byte(counted[cut:], '\n')
		if newline < 0 { return text, preview_at, 0 }
		cut += newline + 1
	}
	remaining := counted[cut:]
	if remaining == "" { return text, preview_at, 0 }
	return text[:preview_at + cut - 1], preview_at, strings.count(remaining, "\n") + 1
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
