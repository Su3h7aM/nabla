package agent

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

import "nabla:agent/journal"
import "nabla:search"
import "nabla:web"

// Tool_Output is what one call produced, typed by the tool that produced it. A result
// with nothing of its own to report, such as a refusal or a timeout, carries nil.
//
// The field names are the contract a script reads: a Lua parent receives each output
// as a table keyed by these names, and the model reads them as `key: value` lines.
Tool_Output :: union {
	Background_Output,
	Read_Output,
	Read_Media_Output,
	Write_Output,
	Edit_Output,
	Shell_Output,
	Skills_Output,
	Skill_Output,
	Find_Output,
	Grep_Output,
	Compact_Output,
	Codemode_Output,
	MCP_Output,
	Agent_Output,
	Agents_Output,
	Jobs_Output,
	Web_Search_Output,
	Web_Fetch_Output,
	Argument_Failure,
}

Background_Output :: struct {
	job:         string,
	status:      string,
	stdout_file: string,
	stderr_file: string,
}

Read_Output :: struct {
	path:        string,
	first_line:  int,
	line_count:  int,
	total_lines: int,
	truncated:   bool,
	content:     string,
}


// Read_Media_Output is a read of an image or PDF file; the file travels as the result's attachment, so the output only describes it.
Read_Media_Output :: struct {
	path:       string,
	media_type: string,
	bytes:      int,
}

Write_Output :: struct {
	path:  string,
	bytes: int,
}

// Edit_Output is what a patch changed. summary has one line per file, in patch order, such as
// `updated <path>` or `moved <path> to <path>`.
Edit_Output :: struct {
	files:                     int,
	whitespace_repaired_hunks: int,
	summary:                   string,
}

// Shell_Output is what a command produced. exit_code is present only when the command
// exited rather than being ended by a signal. A stream too large to hold in memory is
// kept whole in its file, and stdout or stderr then holds only its beginning.
Shell_Output :: struct {
	exit_code:    Maybe(int),
	stdout:       string,
	stderr:       string,
	stdout_bytes: int,
	stderr_bytes: int,
	stdout_file:  string,
	stderr_file:  string,
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

Compact_Output :: struct {
	state: string,
}

Agents_Output :: struct {
	content: string,
}

// Jobs_Output is the list of background jobs: count, and their rendered entries or a note that there are none.
Jobs_Output :: struct {
	count:   int,
	content: string,
}

// Agent_Output is what an agent tool did to one subagent. answer is the subagent's final
// answer once it finished, or the last text it wrote when it failed or was stopped.
// session is the child's Nabla session; acp_session is an ACP agent's own session id.
Agent_Output :: struct {
	agent:       string,
	status:      string,
	model:       string,
	effort:      string,
	session:     string,
	acp_session: string,
	notice:      string, // a repair of the call, such as an effort the model does not state
	answer:      string,
}

// Web_Search_Output is the search's results and an optional synthesized answer. notice
// reports a repair of the request, such as a count lowered to the service's maximum.
Web_Search_Output :: struct {
	notice:  string,
	answer:  string,
	results: []web.Result,
}

Web_Fetch_Output :: struct {
	url:          string,
	redirected:   bool,
	title:        string,
	description:  string,
	content_type: string,
	content:      string,
}

// Codemode_Call is one tool call a script made, as its parent reports it. It is a summary,
// never the child's output: the script returns whatever of that output the model needs.
Codemode_Call :: struct {
	call:    journal.Call_Id,
	name:    string,
	outcome: string,
}

// Codemode_Output is what a Code Mode execution did. failure is empty when the chunk
// returned, and otherwise names why it did not. value is the returned value written as
// a Lua literal, traceback the frames a runtime error unwound, logs what print produced,
// and calls the script's tool calls.
Codemode_Output :: struct {
	failure:     string,
	value:       string,
	calls_total: int,
	calls:       []Codemode_Call,
	traceback:   string,
	logs:        string,
}

// MCP_Output is what an MCP server returned. Text blocks carry their text; every other
// block carries a line saying what was returned and why it is not shown.
// structured_content is the JSON the server sent, exactly as sent.
MCP_Output :: struct {
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
@(require_results)
tool_result_render :: proc(
	outcome: journal.Tool_Outcome,
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
	if outcome != .Success { render_text(&head, journal.TOOL_OUTCOME_NAMES[outcome]) or_return }
	if message != "" {
		render_text(&head, ": ") or_return
		render_value(&head, message) or_return
	}
	render_byte(&head, '\n') or_return

	switch value in output {
	case Background_Output:
		render_field(&head, "job", value.job) or_return
		render_field(&head, "status", value.status) or_return
		if value.stdout_file != "" { render_field(&head, "stdout_file", value.stdout_file) or_return }
		if value.stderr_file != "" { render_field(&head, "stderr_file", value.stderr_file) or_return }
		render_text(
			&body,
			"The result arrives as a message when the job ends. Keep working on what does not depend on it; if nothing is left, end your response and you will be resumed. Do not poll.",
		) or_return
	case Read_Output:
		render_field(&head, "path", value.path) or_return
		render_field(&head, "first_line", value.first_line) or_return
		render_field(&head, "line_count", value.line_count) or_return
		render_field(&head, "total_lines", value.total_lines) or_return
		render_field(&head, "truncated", value.truncated) or_return
		render_text(&body, value.content) or_return
	case Read_Media_Output:
		render_field(&head, "path", value.path) or_return
		render_field(&head, "media_type", value.media_type) or_return
		render_field(&head, "bytes", value.bytes) or_return
	case Write_Output:
		render_field(&head, "path", value.path) or_return
		render_field(&head, "bytes", value.bytes) or_return
	case Edit_Output:
		render_field(&head, "files", value.files) or_return
		if value.whitespace_repaired_hunks > 0 { render_field(&head, "whitespace_repaired_hunks", value.whitespace_repaired_hunks) or_return }
		render_text(&body, value.summary) or_return
	case Shell_Output:
		if code, exited := value.exit_code.?; exited { render_field(&head, "exit_code", code) or_return }
		if value.stdout_file != "" {
			render_field(&head, "stdout_bytes", value.stdout_bytes) or_return
			render_field(&head, "stdout_complete_in", value.stdout_file) or_return
		}
		if value.stderr_file != "" {
			render_field(&head, "stderr_bytes", value.stderr_bytes) or_return
			render_field(&head, "stderr_complete_in", value.stderr_file) or_return
		}
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
	case Find_Output:
		render_field(&head, "total_matches", value.total_matches) or_return
		if value.next_cursor != "" { render_field(&head, "next_cursor", value.next_cursor) or_return }
		if value.notice != "" { render_field(&head, "notice", value.notice) or_return }
		render_skipped(&head, value.skipped) or_return
		// The body is what the front-end previews, so it carries the same
		// facts the head counts: the labeled recovery first, an empty result
		// as its indexed count, and a page under its best-match header with
		// its counts and its cursor trailer. A body is never empty, so no
		// find preview falls back to a bare status word.
		if value.notice != "" {
			render_text(&body, value.notice) or_return
			render_byte(&body, '\n') or_return
		}
		if len(value.files) == 0 {
			// A fallback always carries rows, so an empty page here is a true
			// non-match restated with its indexed count.
			if value.notice == "" {
				render_text(&body, "0 results (") or_return
				render_integer(&body, i64(value.indexed)) or_return
				render_text(&body, " indexed)\n") or_return
			}
		} else {
			render_text(&body, "→ Read ") or_return
			render_text(&body, value.files[0]) or_return
			if value.exact_match {
				render_text(&body, " (exact match!)\n") or_return
			} else {
				render_text(&body, " (best match)\n") or_return
			}
			render_integer(&body, i64(len(value.files))) or_return
			render_text(&body, " of ") or_return
			render_integer(&body, i64(value.total_matches)) or_return
			render_text(&body, " paths\n") or_return
			for file in value.files {
				render_text(&body, file) or_return
				render_byte(&body, '\n') or_return
			}
			if value.next_cursor != "" {
				render_text(&body, "cursor: ") or_return
				render_text(&body, value.next_cursor) or_return
				render_byte(&body, '\n') or_return
			}
		}
	case Grep_Output:
		render_field(&head, "total_matches", value.total_matches) or_return
		if value.next_cursor != "" { render_field(&head, "next_cursor", value.next_cursor) or_return }
		if value.notice != "" { render_field(&head, "notice", value.notice) or_return }
		render_skipped(&head, value.skipped) or_return
		if value.full_lines_file != "" { render_field(&head, "full_lines_in", value.full_lines_file) or_return }
		// The body is what the front-end previews: an empty result reads as
		// its zero count, and a labeled recovery stays up front so the rows
		// that follow are read as what the notice says they are.
		if len(value.matches) == 0 && len(value.files) == 0 {
			if value.notice != "" {
				render_text(&body, value.notice) or_return
				render_byte(&body, '\n') or_return
			} else {
				render_text(&body, "0 matches\n") or_return
			}
		} else {
			if value.notice != "" {
				render_text(&body, value.notice) or_return
				render_byte(&body, '\n') or_return
			}
			if len(value.matches) > 0 {
				render_text(&body, "→ Read ") or_return
				render_text(&body, value.matches[0].path) or_return
				render_text(&body, " (best match)\n") or_return
				current := ""
				for match, index in value.matches {
					if match.path != current {
						if index > 0 { render_text(&body, "--\n") or_return }
						render_text(&body, match.path) or_return
						render_byte(&body, '\n') or_return
						current = match.path
					}
					if match.is_context {
						render_byte(&body, ' ') or_return
						render_integer(&body, i64(match.line)) or_return
						render_byte(&body, '-') or_return
					} else {
						render_integer(&body, i64(match.line)) or_return
						render_text(&body, ": ") or_return
					}
					render_text(&body, match.text) or_return
					render_byte(&body, '\n') or_return
				}
			}
			for path in value.files {
				render_text(&body, path) or_return
				render_byte(&body, '\n') or_return
			}
			if value.next_cursor != "" {
				render_text(&body, "cursor: ") or_return
				render_text(&body, value.next_cursor) or_return
				render_byte(&body, '\n') or_return
			}
		}
	case Compact_Output:
		render_field(&head, "state", value.state) or_return
	case Agents_Output:
		render_text(&body, value.content) or_return
	case Jobs_Output:
		render_field(&head, "jobs", value.count) or_return
		render_text(&body, value.content) or_return
	case Agent_Output:
		render_field(&head, "agent", value.agent) or_return
		render_field(&head, "status", value.status) or_return
		if value.model != "" { render_field(&head, "model", value.model) or_return }
		if value.effort != "" { render_field(&head, "effort", value.effort) or_return }
		if value.session != "" { render_field(&head, "session", value.session) or_return }
		if value.acp_session != "" { render_field(&head, "acp_session", value.acp_session) or_return }
		if value.notice != "" { render_field(&head, "notice", value.notice) or_return }
		render_text(&body, value.answer) or_return
	case Web_Fetch_Output:
		if value.redirected { render_field(&head, "url", value.url) or_return }
		if value.title != "" { render_field(&head, "title", value.title) or_return }
		if value.description != "" { render_field(&head, "description", value.description) or_return }
		if value.content_type != "" { render_field(&head, "content_type", value.content_type) or_return }
		render_text(&body, value.content) or_return
	case Web_Search_Output:
		render_field(&head, "results", len(value.results)) or_return
		if value.notice != "" { render_field(&head, "notice", value.notice) or_return }
		render_section(&body, "answer", value.answer) or_return
		if len(value.results) == 0 {
			render_text(&body, "No results. Try a broader query, fewer domain filters, or different words.") or_return
		}
		for result, index in value.results {
			if index > 0 || value.answer != "" { render_byte(&body, '\n') or_return }
			render_integer(&body, i64(index + 1)) or_return
			render_text(&body, ". ") or_return
			render_value(&body, result.title) or_return
			render_byte(&body, '\n') or_return
			render_value(&body, result.url) or_return
			render_byte(&body, '\n') or_return
			if result.published != "" { render_field(&body, "published", result.published) or_return }
			if result.snippet != "" {
				render_text(&body, result.snippet) or_return
				if !strings.has_suffix(result.snippet, "\n") { render_byte(&body, '\n') or_return }
			}
		}
	case Codemode_Output:
		if value.failure != "" {
			render_field(&head, "failure", value.failure) or_return
		} else {
			render_field(&head, "value", value.value) or_return
		}
		render_field(&head, "calls_total", value.calls_total) or_return
		for call in value.calls {
			render_text(&head, "call: ") or_return
			render_integer(&head, i64(call.call)) or_return
			render_byte(&head, ' ') or_return
			render_value(&head, call.name) or_return
			render_byte(&head, ' ') or_return
			render_value(&head, call.outcome) or_return
			render_byte(&head, '\n') or_return
		}
		render_section(&body, "traceback", value.traceback) or_return
		render_section(&body, "logs", value.logs) or_return
	case MCP_Output:
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
	if _, is_fetch := output.(Web_Fetch_Output); len(body.buf) > 0 || is_fetch {
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

render_text :: proc(builder: ^strings.Builder, value: string) -> (written: int, err: mem.Allocator_Error) #optional_allocator_error {
	written = strings.write_string(builder, value)
	if written != len(value) { err = .Out_Of_Memory }
	return
}

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
@(require_results)
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

// render_skipped writes the `skipped:` line breaking the file count into its
// named reasons, and the `denylist:` line for pruned directories. A line is
// written only when it counts something, so a clean search shows neither.
render_skipped :: proc(builder: ^strings.Builder, skipped: search.Skip_Breakdown) -> (written: int, err: mem.Allocator_Error) #optional_allocator_error {
	start := len(builder.buf)
	if total := search.skip_files_total(skipped); total > 0 {
		render_text(builder, "skipped: ") or_return
		render_integer(builder, i64(total)) or_return
		render_text(builder, " (") or_return
		shown := false
		if skipped.binary > 0 {
			render_text(builder, "binary: ") or_return
			render_integer(builder, i64(skipped.binary)) or_return
			shown = true
		}
		if skipped.oversize > 0 {
			if shown { render_text(builder, ", ") or_return }
			render_text(builder, "oversize: ") or_return
			render_integer(builder, i64(skipped.oversize)) or_return
			shown = true
		}
		if skipped.unreadable > 0 {
			if shown { render_text(builder, ", ") or_return }
			render_text(builder, "unreadable: ") or_return
			render_integer(builder, i64(skipped.unreadable)) or_return
			shown = true
		}
		render_text(builder, ")\n") or_return
	}
	if skipped.denylist > 0 {
		render_text(builder, "denylist: ") or_return
		render_integer(builder, i64(skipped.denylist)) or_return
		if skipped.denylist == 1 {
			render_text(builder, " directory\n") or_return
		} else {
			render_text(builder, " directories\n") or_return
		}
	}
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

// tool_output_clone copies every borrowed string and slice with allocator. The caller
// owns the result and releases it with tool_output_destroy using the same allocator.
// On allocation failure, it releases partial copies and returns nil with the error.
@(require_results)
tool_output_clone :: proc(output: Tool_Output, allocator: mem.Allocator) -> (owned: Tool_Output, allocation_error: mem.Allocator_Error) {
	switch borrowed in output {
	case Background_Output:
		value: Background_Output
		defer if allocation_error != nil {
			partial: Tool_Output = value
			tool_output_destroy(&partial, allocator)
		}
		value.job = strings.clone(borrowed.job, allocator) or_return
		value.status = strings.clone(borrowed.status, allocator) or_return
		value.stdout_file = strings.clone(borrowed.stdout_file, allocator) or_return
		value.stderr_file = strings.clone(borrowed.stderr_file, allocator) or_return
		owned = value
	case Read_Output:
		value := Read_Output {
			first_line  = borrowed.first_line,
			line_count  = borrowed.line_count,
			total_lines = borrowed.total_lines,
			truncated   = borrowed.truncated,
		}
		defer if allocation_error != nil {
			partial: Tool_Output = value
			tool_output_destroy(&partial, allocator)
		}
		value.path = strings.clone(borrowed.path, allocator) or_return
		value.content = strings.clone(borrowed.content, allocator) or_return
		owned = value
	case Read_Media_Output:
		value := Read_Media_Output {
			bytes = borrowed.bytes,
		}
		defer if allocation_error != nil {
			partial: Tool_Output = value
			tool_output_destroy(&partial, allocator)
		}
		value.path = strings.clone(borrowed.path, allocator) or_return
		value.media_type = strings.clone(borrowed.media_type, allocator) or_return
		owned = value
	case Write_Output:
		value := Write_Output {
			bytes = borrowed.bytes,
		}
		defer if allocation_error != nil {
			partial: Tool_Output = value
			tool_output_destroy(&partial, allocator)
		}
		value.path = strings.clone(borrowed.path, allocator) or_return
		owned = value
	case Edit_Output:
		value := Edit_Output {
			files                     = borrowed.files,
			whitespace_repaired_hunks = borrowed.whitespace_repaired_hunks,
		}
		defer if allocation_error != nil {
			partial: Tool_Output = value
			tool_output_destroy(&partial, allocator)
		}
		value.summary = strings.clone(borrowed.summary, allocator) or_return
		owned = value
	case Shell_Output:
		value := Shell_Output {
			exit_code    = borrowed.exit_code,
			stdout_bytes = borrowed.stdout_bytes,
			stderr_bytes = borrowed.stderr_bytes,
		}
		defer if allocation_error != nil {
			partial: Tool_Output = value
			tool_output_destroy(&partial, allocator)
		}
		value.stdout = strings.clone(borrowed.stdout, allocator) or_return
		value.stderr = strings.clone(borrowed.stderr, allocator) or_return
		value.stdout_file = strings.clone(borrowed.stdout_file, allocator) or_return
		value.stderr_file = strings.clone(borrowed.stderr_file, allocator) or_return
		owned = value
	case Skills_Output:
		value := Skills_Output {
			total_matches = borrowed.total_matches,
			next_offset   = borrowed.next_offset,
		}
		defer if allocation_error != nil {
			partial: Tool_Output = value
			tool_output_destroy(&partial, allocator)
		}
		value.skills = make([]Skill_Record, len(borrowed.skills), allocator) or_return
		for item, index in borrowed.skills {
			value.skills[index].name = strings.clone(item.name, allocator) or_return
			value.skills[index].source = strings.clone(item.source, allocator) or_return
			value.skills[index].description = strings.clone(item.description, allocator) or_return
		}
		owned = value
	case Skill_Output:
		value: Skill_Output
		defer if allocation_error != nil {
			partial: Tool_Output = value
			tool_output_destroy(&partial, allocator)
		}
		value.name = strings.clone(borrowed.name, allocator) or_return
		value.path = strings.clone(borrowed.path, allocator) or_return
		value.directory = strings.clone(borrowed.directory, allocator) or_return
		value.content_digest = strings.clone(borrowed.content_digest, allocator) or_return
		value.instructions = strings.clone(borrowed.instructions, allocator) or_return
		owned = value
	case Find_Output:
		value := Find_Output {
			total_matches = borrowed.total_matches,
			skipped       = borrowed.skipped,
			indexed       = borrowed.indexed,
			exact_match   = borrowed.exact_match,
		}
		defer if allocation_error != nil {
			partial: Tool_Output = value
			tool_output_destroy(&partial, allocator)
		}
		value.next_cursor = strings.clone(borrowed.next_cursor, allocator) or_return
		value.notice = strings.clone(borrowed.notice, allocator) or_return
		value.files = make([]string, len(borrowed.files), allocator) or_return
		for file, index in borrowed.files {
			value.files[index] = strings.clone(file, allocator) or_return
		}
		owned = value
	case Grep_Output:
		value := Grep_Output {
			total_matches = borrowed.total_matches,
			skipped       = borrowed.skipped,
		}
		defer if allocation_error != nil {
			partial: Tool_Output = value
			tool_output_destroy(&partial, allocator)
		}
		value.next_cursor = strings.clone(borrowed.next_cursor, allocator) or_return
		value.notice = strings.clone(borrowed.notice, allocator) or_return
		value.matches = make([]search.Grep_Match, len(borrowed.matches), allocator) or_return
		for match, index in borrowed.matches {
			value.matches[index].line = match.line
			value.matches[index].col = match.col
			value.matches[index].is_context = match.is_context
			value.matches[index].path = strings.clone(match.path, allocator) or_return
			value.matches[index].text = strings.clone(match.text, allocator) or_return
		}
		value.full_lines_file = strings.clone(borrowed.full_lines_file, allocator) or_return
		value.files = make([]string, len(borrowed.files), allocator) or_return
		for path, index in borrowed.files {
			value.files[index] = strings.clone(path, allocator) or_return
		}
		owned = value
	case Compact_Output:
		value: Compact_Output
		defer if allocation_error != nil {
			partial: Tool_Output = value
			tool_output_destroy(&partial, allocator)
		}
		value.state = strings.clone(borrowed.state, allocator) or_return
		owned = value
	case Agents_Output:
		value: Agents_Output
		defer if allocation_error != nil {
			partial: Tool_Output = value
			tool_output_destroy(&partial, allocator)
		}
		value.content = strings.clone(borrowed.content, allocator) or_return
		owned = value
	case Jobs_Output:
		value := Jobs_Output {
			count = borrowed.count,
		}
		value.content = strings.clone(borrowed.content, allocator) or_return
		owned = value
	case Agent_Output:
		value: Agent_Output
		defer if allocation_error != nil {
			partial: Tool_Output = value
			tool_output_destroy(&partial, allocator)
		}
		value.agent = strings.clone(borrowed.agent, allocator) or_return
		value.status = strings.clone(borrowed.status, allocator) or_return
		value.model = strings.clone(borrowed.model, allocator) or_return
		value.effort = strings.clone(borrowed.effort, allocator) or_return
		value.session = strings.clone(borrowed.session, allocator) or_return
		value.acp_session = strings.clone(borrowed.acp_session, allocator) or_return
		value.notice = strings.clone(borrowed.notice, allocator) or_return
		value.answer = strings.clone(borrowed.answer, allocator) or_return
		owned = value
	case Web_Fetch_Output:
		value := Web_Fetch_Output {
			redirected = borrowed.redirected,
		}
		defer if allocation_error != nil {
			partial: Tool_Output = value
			tool_output_destroy(&partial, allocator)
		}
		value.url = strings.clone(borrowed.url, allocator) or_return
		value.title = strings.clone(borrowed.title, allocator) or_return
		value.description = strings.clone(borrowed.description, allocator) or_return
		value.content_type = strings.clone(borrowed.content_type, allocator) or_return
		value.content = strings.clone(borrowed.content, allocator) or_return
		owned = value
	case Web_Search_Output:
		value: Web_Search_Output
		defer if allocation_error != nil {
			partial: Tool_Output = value
			tool_output_destroy(&partial, allocator)
		}
		value.notice = strings.clone(borrowed.notice, allocator) or_return
		value.answer = strings.clone(borrowed.answer, allocator) or_return
		value.results = make([]web.Result, len(borrowed.results), allocator) or_return
		for item, index in borrowed.results {
			value.results[index].title = strings.clone(item.title, allocator) or_return
			value.results[index].url = strings.clone(item.url, allocator) or_return
			value.results[index].snippet = strings.clone(item.snippet, allocator) or_return
			value.results[index].published = strings.clone(item.published, allocator) or_return
		}
		owned = value
	case Codemode_Output:
		value := Codemode_Output {
			calls_total = borrowed.calls_total,
		}
		defer if allocation_error != nil {
			partial: Tool_Output = value
			tool_output_destroy(&partial, allocator)
		}
		value.failure = strings.clone(borrowed.failure, allocator) or_return
		value.value = strings.clone(borrowed.value, allocator) or_return
		value.traceback = strings.clone(borrowed.traceback, allocator) or_return
		value.logs = strings.clone(borrowed.logs, allocator) or_return
		value.calls = make([]Codemode_Call, len(borrowed.calls), allocator) or_return
		for item, index in borrowed.calls {
			value.calls[index].call = item.call
			value.calls[index].name = strings.clone(item.name, allocator) or_return
			value.calls[index].outcome = strings.clone(item.outcome, allocator) or_return
		}
		owned = value
	case MCP_Output:
		value: MCP_Output
		defer if allocation_error != nil {
			partial: Tool_Output = value
			tool_output_destroy(&partial, allocator)
		}
		value.structured_content = strings.clone(borrowed.structured_content, allocator) or_return
		value.content = make([]MCP_Block, len(borrowed.content), allocator) or_return
		for item, index in borrowed.content {
			value.content[index].type = strings.clone(item.type, allocator) or_return
			value.content[index].text = strings.clone(item.text, allocator) or_return
			value.content[index].detail = strings.clone(item.detail, allocator) or_return
		}
		owned = value
	case Argument_Failure:
		value: Argument_Failure
		defer if allocation_error != nil {
			partial: Tool_Output = value
			tool_output_destroy(&partial, allocator)
		}
		value.kind = strings.clone(borrowed.kind, allocator) or_return
		value.field = strings.clone(borrowed.field, allocator) or_return
		value.expected = strings.clone(borrowed.expected, allocator) or_return
		owned = value
	case nil:
	}
	return
}

tool_output_destroy :: proc(output: ^Tool_Output, allocator: mem.Allocator) {
	switch value in output^ {
	case Background_Output:
		delete(value.job, allocator)
		delete(value.status, allocator)
		delete(value.stdout_file, allocator)
		delete(value.stderr_file, allocator)
	case Read_Output:
		delete(value.path, allocator)
		delete(value.content, allocator)
	case Read_Media_Output:
		delete(value.path, allocator)
		delete(value.media_type, allocator)
	case Write_Output:
		delete(value.path, allocator)
	case Edit_Output:
		delete(value.summary, allocator)
	case Shell_Output:
		delete(value.stdout, allocator)
		delete(value.stderr, allocator)
		delete(value.stdout_file, allocator)
		delete(value.stderr_file, allocator)
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
	case Find_Output:
		delete(value.next_cursor, allocator)
		delete(value.notice, allocator)
		for file in value.files {
			delete(file, allocator)
		}
		delete(value.files, allocator)
	case Grep_Output:
		delete(value.next_cursor, allocator)
		delete(value.notice, allocator)
		for match in value.matches {
			delete(match.path, allocator)
			delete(match.text, allocator)
		}
		delete(value.matches, allocator)
		delete(value.full_lines_file, allocator)
		for path in value.files {
			delete(path, allocator)
		}
		delete(value.files, allocator)
	case Compact_Output:
		delete(value.state, allocator)
	case Agents_Output:
		delete(value.content, allocator)
	case Jobs_Output:
		delete(value.content, allocator)
	case Agent_Output:
		delete(value.agent, allocator)
		delete(value.status, allocator)
		delete(value.model, allocator)
		delete(value.effort, allocator)
		delete(value.session, allocator)
		delete(value.acp_session, allocator)
		delete(value.notice, allocator)
		delete(value.answer, allocator)
	case Web_Fetch_Output:
		delete(value.url, allocator)
		delete(value.title, allocator)
		delete(value.description, allocator)
		delete(value.content_type, allocator)
		delete(value.content, allocator)
	case Web_Search_Output:
		delete(value.notice, allocator)
		delete(value.answer, allocator)
		for item in value.results {
			delete(item.title, allocator)
			delete(item.url, allocator)
			delete(item.snippet, allocator)
			delete(item.published, allocator)
		}
		delete(value.results, allocator)
	case Codemode_Output:
		delete(value.failure, allocator)
		delete(value.value, allocator)
		delete(value.traceback, allocator)
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
