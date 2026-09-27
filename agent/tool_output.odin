package agent

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

import "nabla:agent/session"

// Tool_Output is what one call produced, typed by the tool that produced it. A result
// with nothing of its own to report, such as a refusal or a timeout, carries nil.
//
// The field names are the contract a script reads: a Lua parent receives each output
// as a table keyed by these names, and the model reads them as `key: value` lines.
Tool_Output :: union {
	Read_Output,
	Write_Output,
	Patch_Output,
	Shell_Output,
	Skills_Output,
	Skill_Output,
	Result_Read_Output,
	Compact_Output,
	Codemode_Output,
	MCP_Output,
	Argument_Failure,
}

Read_Output :: struct {
	path:        string,
	first_line:  int,
	line_count:  int,
	total_lines: int,
	truncated:   bool,
	content:     string,
}

Write_Output :: struct {
	path:  string,
	bytes: int,
}

// Patch_Output is what a patch changed. summary has one line per file, in patch order, such as
// `updated <path>` or `moved <path> to <path>`.
Patch_Output :: struct {
	files:                     int,
	whitespace_repaired_hunks: int,
	summary:                   string,
}

// Shell_Output is what a command produced. exit_code is present only when the command
// exited rather than being ended by a signal.
Shell_Output :: struct {
	exit_code:         Maybe(int),
	stdout_truncated:  bool,
	stderr_truncated:  bool,
	output_incomplete: bool,
	stdout:            string,
	stderr:            string,
}

Skill_Record :: struct {
	name:        string,
	source:      string,
	description: string,
}

Skills_Output :: struct {
	total_matches: int,
	next_offset:   Maybe(int),
	skills:        []Skill_Record,
}

Skill_Output :: struct {
	name:           string,
	path:           string,
	directory:      string,
	content_digest: string,
	instructions:   string,
}

// Result_Read_Output is one page of a kept result. bytes is the size of the whole
// result, and next_offset is where the following page starts.
Result_Read_Output :: struct {
	bytes:       int,
	next_offset: int,
	eof:         bool,
	text:        string,
}

Compact_Output :: struct {
	state: string,
}

// Codemode_Call is one tool call a script made, as its parent reports it. It is a summary,
// never the child's output: a model that wants the output reads it back from call_seq
// with context_read_result.
Codemode_Call :: struct {
	call_seq: i64,
	name:     string,
	outcome:  string,
}

// Codemode_Output is what a Code Mode execution did. failure is empty when the chunk
// returned, and otherwise names why it did not. value is the returned value written as
// a Lua literal, logs is what print produced, and calls are the script's tool calls.
Codemode_Output :: struct {
	failure:        string,
	value:          string,
	calls_total:    int,
	calls:          []Codemode_Call,
	logs_truncated: bool,
	logs:           string,
}

// MCP_Output is what an MCP server returned. Text blocks carry their text; every other
// block carries a line saying what was returned and why it is not shown.
// structured_content is the JSON the server sent, exactly as sent.
MCP_Output :: struct {
	truncated:          bool,
	content:            []MCP_Block,
	structured_content: string `lua:"json"`,
}

MCP_Block :: struct {
	type:   string,
	text:   string,
	detail: string,
}

// --- rendering -------------------------------------------------------------------

// tool_result_render writes the text the model reads for one result: an outcome line, the
// output's fields as `key: value` lines, and after a blank line the raw body. Raw text
// needs no escaping inside the provider's own encoding, which is why the body is not
// quoted. The text is owned by allocator.
tool_result_render :: proc(
	outcome: session.Tool_Outcome,
	message: string,
	output: Tool_Output,
	allocator: mem.Allocator,
) -> (
	text: string,
	err: mem.Allocator_Error,
) {
	// The head is handed to the caller as the builder wrote it; the body is a builder of
	// its own, because its parts are written in the order they are read.
	head, head_error := strings.builder_make(allocator)
	if head_error != nil { return "", head_error }
	failed := true
	defer if failed { strings.builder_destroy(&head) }
	body, body_error := strings.builder_make(allocator)
	if body_error != nil { return "", body_error }
	defer strings.builder_destroy(&body)

	render_text(&head, "ok" if outcome == .Success else "error ") or_return
	if outcome != .Success { render_text(&head, session.tool_outcome_name(outcome)) or_return }
	if message != "" {
		render_text(&head, ": ") or_return
		render_value(&head, message) or_return
	}
	render_byte(&head, '\n') or_return

	switch value in output {
	case Read_Output:
		render_field(&head, "path", value.path) or_return
		render_field(&head, "first_line", value.first_line) or_return
		render_field(&head, "line_count", value.line_count) or_return
		render_field(&head, "total_lines", value.total_lines) or_return
		render_field(&head, "truncated", value.truncated) or_return
		render_text(&body, value.content) or_return
	case Write_Output:
		render_field(&head, "path", value.path) or_return
		render_field(&head, "bytes", value.bytes) or_return
	case Patch_Output:
		render_field(&head, "files", value.files) or_return
		if value.whitespace_repaired_hunks > 0 { render_field(&head, "whitespace_repaired_hunks", value.whitespace_repaired_hunks) or_return }
		render_text(&body, value.summary) or_return
	case Shell_Output:
		if code, exited := value.exit_code.?; exited { render_field(&head, "exit_code", code) or_return }
		render_field(&head, "stdout_truncated", value.stdout_truncated) or_return
		render_field(&head, "stderr_truncated", value.stderr_truncated) or_return
		render_field(&head, "output_incomplete", value.output_incomplete) or_return
		render_section(&body, "stdout", value.stdout) or_return
		render_section(&body, "stderr", value.stderr) or_return
	case Skills_Output:
		render_field(&head, "total_matches", value.total_matches) or_return
		if next, more := value.next_offset.?; more { render_field(&head, "next_offset", next) or_return }
		for skill, index in value.skills {
			if index > 0 { render_byte(&body, '\n') or_return }
			render_field(&body, "name", skill.name) or_return
			render_field(&body, "source", skill.source) or_return
			render_field(&body, "description", skill.description) or_return
		}
	case Skill_Output:
		render_field(&head, "name", value.name) or_return
		render_field(&head, "path", value.path) or_return
		render_field(&head, "directory", value.directory) or_return
		render_field(&head, "content_digest", value.content_digest) or_return
		render_text(&body, value.instructions) or_return
	case Result_Read_Output:
		render_field(&head, "bytes", value.bytes) or_return
		render_field(&head, "next_offset", value.next_offset) or_return
		render_field(&head, "eof", value.eof) or_return
		render_text(&body, value.text) or_return
	case Compact_Output:
		render_field(&head, "state", value.state) or_return
	case Codemode_Output:
		if value.failure != "" {
			render_field(&head, "failure", value.failure) or_return
		} else {
			render_field(&head, "value", value.value) or_return
		}
		render_field(&head, "calls_total", value.calls_total) or_return
		for call in value.calls {
			render_text(&head, "call: ") or_return
			render_integer(&head, call.call_seq) or_return
			render_byte(&head, ' ') or_return
			render_value(&head, call.name) or_return
			render_byte(&head, ' ') or_return
			render_value(&head, call.outcome) or_return
			render_byte(&head, '\n') or_return
		}
		render_field(&head, "logs_truncated", value.logs_truncated) or_return
		render_text(&body, value.logs) or_return
	case MCP_Output:
		render_field(&head, "truncated", value.truncated) or_return
		for block in value.content {
			if block.text != "" {
				render_text(&body, block.text) or_return
				if !strings.has_suffix(block.text, "\n") { render_byte(&body, '\n') or_return }
			} else {
				render_text(&body, "[") or_return
				render_text(&body, block.detail) or_return
				render_text(&body, "]\n") or_return
			}
		}
		render_section(&body, "structured_content", value.structured_content) or_return
	case Argument_Failure:
		render_field(&head, "kind", value.kind) or_return
		if value.field != "" { render_field(&head, "field", value.field) or_return }
		if value.expected != "" { render_field(&head, "expected", value.expected) or_return }
	}
	if len(body.buf) > 0 {
		render_byte(&head, '\n') or_return
		render_text(&head, strings.to_string(body)) or_return
	}
	text = strings.to_string(head)
	failed = false
	return
}
// The render procedures below write the text a result is read as. Each one reports a
// missing allocation the way the standard library does, so a caller writes `or_return`
// and the whole rendering is answered once rather than at every line.

// render_text writes text as it is.
render_text :: proc(builder: ^strings.Builder, value: string) -> (written: int, err: mem.Allocator_Error) #optional_allocator_error {
	written = strings.write_string(builder, value)
	if written != len(value) { err = .Out_Of_Memory }
	return
}

// render_byte writes one byte.
render_byte :: proc(builder: ^strings.Builder, value: u8) -> (written: int, err: mem.Allocator_Error) #optional_allocator_error {
	written = strings.write_byte(builder, value)
	if written != 1 { err = .Out_Of_Memory }
	return
}

// render_integer writes a whole number out of a stack buffer, so a count costs no memory.
render_integer :: proc(builder: ^strings.Builder, value: i64) -> (written: int, err: mem.Allocator_Error) #optional_allocator_error {
	buffer: [32]u8
	written, err = render_text(builder, fmt.bprintf(buffer[:], "%d", value))
	return
}

// render_quoted writes text quoted and escaped, so it stays on the line it started on and
// its edges are visible. Valid UTF-8 keeps its bytes, and every other byte is written as
// `\xNN`: the text stays valid UTF-8 and reads back as the same bytes.
render_quoted :: proc(builder: ^strings.Builder, value: string) -> (written: int, err: mem.Allocator_Error) #optional_allocator_error {
	start := len(builder.buf)
	render_byte(builder, '"') or_return
	for index := 0; index < len(value); {
		c := value[index]
		switch c {
		case '"':
			render_text(builder, `\"`) or_return
		case '\\':
			render_text(builder, `\\`) or_return
		case '\n':
			render_text(builder, `\n`) or_return
		case '\r':
			render_text(builder, `\r`) or_return
		case '\t':
			render_text(builder, `\t`) or_return
		case:
			if c >= 0x20 && c != 0x7F {
				render_byte(builder, c) or_return
			} else if r, width := utf8.decode_rune_in_string(value[index:]); c >= 0x80 && r != utf8.RUNE_ERROR {
				render_text(builder, value[index:index + width]) or_return
				index += width
				continue
			} else {
				digits := "0123456789abcdef"
				render_text(builder, `\x`) or_return
				render_byte(builder, digits[int(c >> 4)]) or_return
				render_byte(builder, digits[int(c & 0x0F)]) or_return
			}
		}
		index += 1
	}
	render_byte(builder, '"') or_return
	written = len(builder.buf) - start
	return
}

// render_value writes one value that has to stay on the line it started on: plain text as
// it is, and anything else quoted.
render_value :: proc(builder: ^strings.Builder, value: string) -> (written: int, err: mem.Allocator_Error) #optional_allocator_error {
	if render_value_plain(value) {
		written, err = render_text(builder, value)
		return
	}
	written, err = render_quoted(builder, value)
	return
}

// render_value_plain reports whether a value reads as itself on one line: no control byte
// to break it and no edge a reader could not see.
render_value_plain :: proc(value: string) -> bool {
	if value != strings.trim_space(value) { return false }
	for c in transmute([]u8)value {
		if c < 0x20 || c == 0x7F { return false }
	}
	return true
}

// render_field writes one `key: value` line. A boolean is written only when it is true, so
// absence reads as false and the common case costs nothing.
render_field :: proc(builder: ^strings.Builder, key: string, value: $T) -> (written: int, err: mem.Allocator_Error) #optional_allocator_error {
	when T == bool {
		if !value { return }
	}
	start := len(builder.buf)
	render_text(builder, key) or_return
	render_text(builder, ": ") or_return
	when T == string {
		render_value(builder, value) or_return
	} else when T == bool {
		render_text(builder, "true") or_return
	} else {
		render_integer(builder, i64(value)) or_return
	}
	render_byte(builder, '\n') or_return
	written = len(builder.buf) - start
	return
}

// render_section writes one labelled part of a body, ending on a line break so the next
// label starts a line of its own. An empty part is left out.
render_section :: proc(builder: ^strings.Builder, label, body: string) -> (written: int, err: mem.Allocator_Error) #optional_allocator_error {
	if body == "" { return }
	start := len(builder.buf)
	render_text(builder, label) or_return
	render_text(builder, ":\n") or_return
	render_text(builder, body) or_return
	if !strings.has_suffix(body, "\n") { render_byte(builder, '\n') or_return }
	written = len(builder.buf) - start
	return
}
// tool_result_body is the raw body of rendered result text, or the outcome line's
// message when the result has no body. A front-end shows it instead of the whole text.
tool_result_body :: proc(text: string) -> string {
	if index := strings.index(text, "\n\n"); index >= 0 { return text[index + 2:] }
	line := text
	if newline := strings.index_byte(line, '\n'); newline >= 0 { line = line[:newline] }
	if colon := strings.index(line, ": "); colon >= 0 { return line[colon + 2:] }
	return ""
}

// --- ownership -------------------------------------------------------------------

// tool_output_clone copies every string and slice output borrows into its own memory, so a
// result outlives the buffers its executor used.
tool_output_clone :: proc(output: Tool_Output, allocator: mem.Allocator) -> (owned: Tool_Output, allocation_error: mem.Allocator_Error) {
	// Every owned field is emptied before its copy is made, so a clone that fails partway
	// frees only its own copies and never the memory the executor still owns.
	defer if allocation_error != nil { tool_output_destroy(&owned, allocator) }
	owned = output
	switch &value in owned {
	case Read_Output:
		borrowed := value
		value.path = ""
		value.content = ""
		value.path = strings.clone(borrowed.path, allocator) or_return
		value.content = strings.clone(borrowed.content, allocator) or_return
	case Write_Output:
		borrowed := value
		value.path = ""
		value.path = strings.clone(borrowed.path, allocator) or_return
	case Patch_Output:
		borrowed := value
		value.summary = ""
		value.summary = strings.clone(borrowed.summary, allocator) or_return
	case Shell_Output:
		borrowed := value
		value.stdout = ""
		value.stderr = ""
		value.stdout = strings.clone(borrowed.stdout, allocator) or_return
		value.stderr = strings.clone(borrowed.stderr, allocator) or_return
	case Skills_Output:
		borrowed := value
		value.skills = nil
		value.skills = make([]Skill_Record, len(borrowed.skills), allocator) or_return
		for item, index in borrowed.skills {
			value.skills[index].name = strings.clone(item.name, allocator) or_return
			value.skills[index].source = strings.clone(item.source, allocator) or_return
			value.skills[index].description = strings.clone(item.description, allocator) or_return
		}
	case Skill_Output:
		borrowed := value
		value.name = ""
		value.path = ""
		value.directory = ""
		value.content_digest = ""
		value.instructions = ""
		value.name = strings.clone(borrowed.name, allocator) or_return
		value.path = strings.clone(borrowed.path, allocator) or_return
		value.directory = strings.clone(borrowed.directory, allocator) or_return
		value.content_digest = strings.clone(borrowed.content_digest, allocator) or_return
		value.instructions = strings.clone(borrowed.instructions, allocator) or_return
	case Result_Read_Output:
		borrowed := value
		value.text = ""
		value.text = strings.clone(borrowed.text, allocator) or_return
	case Compact_Output:
		borrowed := value
		value.state = ""
		value.state = strings.clone(borrowed.state, allocator) or_return
	case Codemode_Output:
		borrowed := value
		value.failure = ""
		value.value = ""
		value.logs = ""
		value.calls = nil
		value.failure = strings.clone(borrowed.failure, allocator) or_return
		value.value = strings.clone(borrowed.value, allocator) or_return
		value.logs = strings.clone(borrowed.logs, allocator) or_return
		value.calls = make([]Codemode_Call, len(borrowed.calls), allocator) or_return
		for item, index in borrowed.calls {
			value.calls[index].call_seq = item.call_seq
			value.calls[index].name = strings.clone(item.name, allocator) or_return
			value.calls[index].outcome = strings.clone(item.outcome, allocator) or_return
		}
	case MCP_Output:
		borrowed := value
		value.structured_content = ""
		value.content = nil
		value.structured_content = strings.clone(borrowed.structured_content, allocator) or_return
		value.content = make([]MCP_Block, len(borrowed.content), allocator) or_return
		for item, index in borrowed.content {
			value.content[index].type = strings.clone(item.type, allocator) or_return
			value.content[index].text = strings.clone(item.text, allocator) or_return
			value.content[index].detail = strings.clone(item.detail, allocator) or_return
		}
	case Argument_Failure:
		borrowed := value
		value.kind = ""
		value.field = ""
		value.expected = ""
		value.kind = strings.clone(borrowed.kind, allocator) or_return
		value.field = strings.clone(borrowed.field, allocator) or_return
		value.expected = strings.clone(borrowed.expected, allocator) or_return
	case nil:
	}
	return
}

tool_output_destroy :: proc(output: ^Tool_Output, allocator: mem.Allocator) {
	switch value in output^ {
	case Read_Output:
		delete(value.path, allocator)
		delete(value.content, allocator)
	case Write_Output:
		delete(value.path, allocator)
	case Patch_Output:
		delete(value.summary, allocator)
	case Shell_Output:
		delete(value.stdout, allocator)
		delete(value.stderr, allocator)
	case Skills_Output:
		for item in value.skills {
			delete(item.name, allocator)
			delete(item.source, allocator)
			delete(item.description, allocator)
		}
		delete(value.skills, allocator)
	case Skill_Output:
		delete(value.name, allocator)
		delete(value.path, allocator)
		delete(value.directory, allocator)
		delete(value.content_digest, allocator)
		delete(value.instructions, allocator)
	case Result_Read_Output:
		delete(value.text, allocator)
	case Compact_Output:
		delete(value.state, allocator)
	case Codemode_Output:
		delete(value.failure, allocator)
		delete(value.value, allocator)
		delete(value.logs, allocator)
		for item in value.calls {
			delete(item.name, allocator)
			delete(item.outcome, allocator)
		}
		delete(value.calls, allocator)
	case MCP_Output:
		delete(value.structured_content, allocator)
		for item in value.content {
			delete(item.type, allocator)
			delete(item.text, allocator)
			delete(item.detail, allocator)
		}
		delete(value.content, allocator)
	case Argument_Failure:
		delete(value.kind, allocator)
		delete(value.field, allocator)
		delete(value.expected, allocator)
	case nil:
	}
	output^ = nil
}
