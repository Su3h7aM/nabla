package agent

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"


// --- read --------------------------------------------------------------------

TOOL_READ_NAME :: "builtin_read"

TOOL_READ_DESCRIPTION :: "Read a text file. Relative paths start at the session workspace, and absolute paths are used as given. Returns the requested lines together with the line range they came from and the file's total line count, so a long file can be read in parts."

TOOL_READ_SCHEMA :: `{"type":"object","properties":{"path":{"type":"string","description":"File path. Relative paths start at the session workspace; absolute paths are used as given."},"offset":{"type":["integer","null"],"description":"First line to read, counting from 1. Leave out to start at the beginning."},"limit":{"type":["integer","null"],"description":"Maximum number of lines to read. Leave out for the harness default."}},"required":["path"],"additionalProperties":false}`

TOOL_READ_FIELDS :: []string{"path", "offset", "limit"}

TOOL_READ_DEFAULT_LINES :: 2000
TOOL_READ_MAX_LINES :: 20000
TOOL_READ_MAX_BYTES :: 48 * 1024
TOOL_READ_MAX_FILE_BYTES :: 8 * 1024 * 1024

Read_Data :: struct {
	path:        string `json:"path"`,
	content:     string `json:"content"`,
	first_line:  int `json:"first_line"`,
	line_count:  int `json:"line_count"`,
	total_lines: int `json:"total_lines"`,
	truncated:   bool `json:"truncated"`,
}

TOOL_READ_DEFINITION :: Tool_Definition {
	name = TOOL_READ_NAME,
	description = TOOL_READ_DESCRIPTION,
	input_schema = TOOL_READ_SCHEMA,
	hints = {read_only = .Yes, destructive = .No, idempotent = .Yes, open_world = .No},
	execute = tool_read_execute,
}

// Tool_Read_Args is the read tool's own view of a call. path borrows the
// argument document.
Tool_Read_Args :: struct {
	path:   string,
	offset: int,
	limit:  int,
}

// tool_read_args reads the read tool's arguments.
tool_read_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (Tool_Read_Args, Tool_Argument_Error) {
	if known_error := tool_fields_known(arguments, TOOL_READ_FIELDS, allocator = ctx.allocator); known_error.kind != .None { return {}, known_error }
	path, path_error := tool_field_string(arguments, "path", allocator = ctx.allocator)
	if path_error.kind != .None { return {}, path_error }
	offset, offset_error := tool_field_optional_int(arguments, "offset", 1, 1, TOOL_READ_MAX_LINES, allocator = ctx.allocator)
	if offset_error.kind != .None { return {}, offset_error }
	limit, limit_error := tool_field_optional_int(arguments, "limit", TOOL_READ_DEFAULT_LINES, 1, TOOL_READ_MAX_LINES, allocator = ctx.allocator)
	if limit_error.kind != .None { return {}, limit_error }
	return Tool_Read_Args{path = path, offset = offset, limit = limit}, {}
}

tool_read_execute :: proc(ctx: ^Tool_Context, arguments: json.Object) -> Tool_Result {
	args, args_error := tool_read_args(ctx, arguments)
	defer if args_error.kind != .None { tool_argument_error_destroy(&args_error, ctx.allocator) }
	if args_error.kind != .None { return tool_result_refused(ctx, &args_error) }

	path, resolve_error := tool_resolve_path(ctx.workspace, args.path, allocator = ctx.allocator)
	if resolve_error.kind != .None { return tool_result_refused(ctx, &resolve_error) }
	defer delete(path, ctx.allocator)

	info, info_error := os.stat(path, ctx.allocator)
	defer os.file_info_delete(info, ctx.allocator)
	if info_error != nil || info.type != .Regular {
		return tool_result_failure(ctx, .Tool_Failed, fmt.tprintf("there is no readable file at %s", args.path), "not a file")
	}
	if info.size > TOOL_READ_MAX_FILE_BYTES {
		return tool_result_failure(
			ctx,
			.Tool_Failed,
			fmt.tprintf("%s is larger than the %d-byte read limit", args.path, TOOL_READ_MAX_FILE_BYTES),
			"too large",
		)
	}
	// The read below can block on the filesystem, so cancellation is checked
	// before the expensive call and again before the output is built. There is
	// no tool-specific timeout for reads: only the turn ending stops one.
	if tool_control_cancelled(ctx.control) {
		return tool_result_failure(ctx, .Cancelled, "the read was cancelled", "cancelled")
	}
	data, read_error := os.read_entire_file(path, ctx.allocator)
	if read_error != nil {
		return tool_result_failure(ctx, .Tool_Failed, fmt.tprintf("could not read %s: %s", args.path, os.error_string(read_error)), "unreadable")
	}
	defer delete(data, ctx.allocator)
	if tool_control_cancelled(ctx.control) {
		return tool_result_failure(ctx, .Cancelled, "the read was cancelled", "cancelled")
	}

	text := string(data)
	// A result is JSON, and JSON is UTF-8. A file whose bytes are not valid UTF-8 is not
	// text the model can be handed: the encoder escapes such a byte as JSON5, which is not
	// JSON, and a reader that silently received a prefix would not know it had. A NUL is
	// refused for the same reason, so the two checks sit together.
	if strings.index_byte(text, 0) >= 0 || !utf8.valid_string(text) {
		return tool_result_failure(ctx, .Tool_Failed, fmt.tprintf("%s is not a text file", args.path), "binary")
	}

	total_lines := tool_line_count(text)
	start := tool_line_start(text, args.offset)
	end, lines := tool_line_span(text, start, args.limit)
	content := text[start:end]
	// A single very long line is taken whole by the line span and truncated
	// here, which is a different fact from the line range ending early. Both
	// set truncated, so the model knows when it did not receive everything.
	byte_truncated := len(content) > TOOL_READ_MAX_BYTES
	if byte_truncated { content = tool_truncate_runes(content, TOOL_READ_MAX_BYTES) }

	result := Read_Data {
		path        = args.path,
		content     = content,
		first_line  = args.offset,
		line_count  = lines,
		total_lines = total_lines,
		truncated   = end < len(text) || byte_truncated,
	}
	reason := fmt.tprintf("lines %d-%d of %d", args.offset, args.offset + lines - 1, total_lines) if lines > 0 else "no lines"
	return tool_result_success(ctx, result, reason)
}

// tool_line_count is the number of newline-separated lines. A trailing newline
// ends the last line rather than starting an empty one, so a file of one line
// plus a newline is one line.
@(private)
tool_line_count :: proc(text: string) -> int {
	if text == "" { return 0 }
	count := 1
	for i in 0 ..< len(text) {
		if text[i] == '\n' { count += 1 }
	}
	if text[len(text) - 1] == '\n' { count -= 1 }
	return count
}

// tool_line_start is the byte offset where a one-based line begins. A line past
// the end of the file starts at the end.
@(private)
tool_line_start :: proc(text: string, line: int) -> int {
	offset := 0
	for _ in 1 ..< line {
		newline := strings.index_byte(text[offset:], '\n')
		if newline < 0 { return len(text) }
		offset += newline + 1
	}
	return offset
}

// tool_line_span returns the end offset and line count of up to limit lines
// starting at start, stopping early when the byte budget is reached. One line is
// always taken, so a single very long line is returned truncated rather than
// omitted.
@(private)
tool_line_span :: proc(text: string, start, limit: int) -> (end: int, lines: int) {
	end = start
	for lines < limit && end < len(text) {
		newline := strings.index_byte(text[end:], '\n')
		next := len(text)
		if newline >= 0 { next = end + newline + 1 }
		if lines > 0 && next - start > TOOL_READ_MAX_BYTES { break }
		end = next
		lines += 1
	}
	return
}

// --- write -------------------------------------------------------------------

TOOL_WRITE_NAME :: "builtin_write"

TOOL_WRITE_DESCRIPTION :: "Write a text file, replacing whatever it held. Relative paths start at the session workspace, and absolute paths are used as given. The write is atomic: a reader sees either the old file or the whole new one. The parent directory must already exist."

TOOL_WRITE_SCHEMA :: `{"type":"object","properties":{"path":{"type":"string","description":"File path. Relative paths start at the session workspace; absolute paths are used as given."},"content":{"type":"string","description":"The complete new contents of the file."}},"required":["path","content"],"additionalProperties":false}`

TOOL_WRITE_FIELDS :: []string{"path", "content"}

Write_Data :: struct {
	path:  string `json:"path"`,
	bytes: int `json:"bytes"`,
}

TOOL_WRITE_DEFINITION :: Tool_Definition {
	name = TOOL_WRITE_NAME,
	description = TOOL_WRITE_DESCRIPTION,
	input_schema = TOOL_WRITE_SCHEMA,
	// Rewriting identical content reaches the same file, so a repeated call
	// with identical arguments is idempotent.
	hints = {read_only = .No, destructive = .Yes, idempotent = .Yes, open_world = .No},
	execute = tool_write_execute,
}

Tool_Write_Args :: struct {
	path:    string,
	content: string,
}

tool_write_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (Tool_Write_Args, Tool_Argument_Error) {
	if known_error := tool_fields_known(arguments, TOOL_WRITE_FIELDS, allocator = ctx.allocator); known_error.kind != .None { return {}, known_error }
	path, path_error := tool_field_string(arguments, "path", allocator = ctx.allocator)
	if path_error.kind != .None { return {}, path_error }
	content, content_error := tool_field_string(arguments, "content", allocator = ctx.allocator)
	if content_error.kind != .None { return {}, content_error }
	return Tool_Write_Args{path = path, content = content}, {}
}

tool_write_execute :: proc(ctx: ^Tool_Context, arguments: json.Object) -> Tool_Result {
	args, args_error := tool_write_args(ctx, arguments)
	defer if args_error.kind != .None { tool_argument_error_destroy(&args_error, ctx.allocator) }
	if args_error.kind != .None { return tool_result_refused(ctx, &args_error) }

	path, resolve_error := tool_resolve_path(ctx.workspace, args.path, allocator = ctx.allocator)
	if resolve_error.kind != .None { return tool_result_refused(ctx, &resolve_error) }
	defer delete(path, ctx.allocator)

	mode, mode_error := tool_write_mode(path)
	if mode_error != .None {
		return tool_result_failure(ctx, .Tool_Failed, tool_write_mode_text(args.path, mode_error), "not writable")
	}
	if tool_control_cancelled(ctx.control) {
		return tool_result_failure(ctx, .Cancelled, "the write was cancelled before it began", "cancelled")
	}
	if write_error, write_cancelled := tool_write_atomic(path, transmute([]u8)args.content, mode, ctx.allocator, ctx.control); write_cancelled {
		return tool_result_failure(ctx, .Cancelled, "the write was cancelled", "cancelled")
	} else if write_error != nil {
		return tool_result_failure(ctx, .Tool_Failed, fmt.tprintf("could not write %s: %s", args.path, os.error_string(write_error)), "write failed")
	}
	return tool_result_success(ctx, Write_Data{path = args.path, bytes = len(args.content)}, fmt.tprintf("wrote %d bytes", len(args.content)))
}

// Tool_Path_Problem is the kind of reason a write tool refused a path before
// touching it.
Tool_Path_Problem :: enum {
	None,
	Missing,
	Not_Regular,
	Symlink,
}

// tool_write_mode returns the mode a replacement file should carry: the mode the
// existing file has, or the default for a new one. A path that exists as
// anything but a regular file, or that is a symbolic link, is refused rather than
// replaced: renaming over a link would silently turn it into a regular file.
tool_write_mode :: proc(path: string) -> (os.Permissions, Tool_Path_Problem) {
	// The mode is the answer; the info the lstat filled in is scratch.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	info, info_error := os.lstat(path, context.temp_allocator)
	if info_error != nil {
		if info_error == os.General_Error.Not_Exist { return os.Permissions_Default_File, .None }
		return {}, .Missing
	}
	defer os.file_info_delete(info, context.temp_allocator)
	if info.type == .Symlink { return {}, .Symlink }
	if info.type != .Regular { return {}, .Not_Regular }
	return info.mode, .None
}

tool_write_mode_text :: proc(path: string, problem: Tool_Path_Problem) -> string {
	switch problem {
	case .Symlink:
		return fmt.tprintf("%s is a symbolic link, so writing it would replace the link", path)
	case .Not_Regular:
		return fmt.tprintf("%s is not a regular file", path)
	case .Missing, .None:
		return fmt.tprintf("%s cannot be written", path)
	}
	return ""
}

// TOOL_WRITE_TEMP_ATTEMPTS bounds how many names an atomic write tries before
// giving up. A collision means the name is taken, which resolves on the next
// attempt.
TOOL_WRITE_TEMP_ATTEMPTS :: 64

// tool_write_atomic writes content to a temporary file beside path and renames it
// into place, so a reader never sees a half-written file and a failed write
// leaves the original untouched. Cancellation is cooperative: it is checked
// before the temporary write begins, while the temporary file grows, and
// before the rename commits. A cancellation before the rename deletes the
// temporary file and reports cancelled; once the rename succeeds the observed
// result stands, because the effect already committed.
tool_write_atomic :: proc(
	path: string,
	content: []u8,
	mode: os.Permissions,
	allocator: mem.Allocator,
	control: Tool_Control,
) -> (
	write_error: os.Error,
	cancelled: bool,
) {
	if tool_control_cancelled(control) { return nil, true }
	for attempt in 0 ..< TOOL_WRITE_TEMP_ATTEMPTS {
		if tool_control_cancelled(control) { return nil, true }
		temp_path := fmt.aprintf("%s.nabla-%d-%d", path, time.tick_now(), attempt, allocator = allocator)
		defer delete(temp_path, allocator)
		file, open_error := os.open(temp_path, {.Write, .Create, .Excl}, mode)
		if open_error == os.General_Error.Exist { continue }
		if open_error != nil { return open_error, false }

		cancelled_write := false
		written := 0
		for written < len(content) {
			if tool_control_cancelled(control) {
				cancelled_write = true
				break
			}
			count, chunk_error := os.write(file, content[written:])
			if chunk_error != nil {
				os.close(file)
				os.remove(temp_path)
				return chunk_error, false
			}
			if count <= 0 {
				os.close(file)
				os.remove(temp_path)
				return os.General_Error.Invalid_File, false
			}
			written += count
		}
		if close_error := os.close(file); close_error != nil {
			os.remove(temp_path)
			if cancelled_write { return nil, true }
			return close_error, false
		}
		if cancelled_write || tool_control_cancelled(control) {
			os.remove(temp_path)
			return nil, true
		}
		if rename_error := os.rename(temp_path, path); rename_error != nil {
			os.remove(temp_path)
			return rename_error, false
		}
		return nil, false
	}
	return os.General_Error.Exist, false
}

// --- edit --------------------------------------------------------------------

TOOL_EDIT_NAME :: "builtin_edit"

TOOL_EDIT_DESCRIPTION :: "Replace exact text in a file. Relative paths start at the session workspace, and absolute paths are used as given. Each replacement's old text must appear in the file exactly once, and no two replacements may overlap. All of them are applied in one write or none is."

TOOL_EDIT_SCHEMA :: `{"type":"object","properties":{"path":{"type":"string","description":"File path. Relative paths start at the session workspace; absolute paths are used as given."},"edits":{"type":"array","minItems":1,"description":"Replacements to apply, each matching exactly once.","items":{"type":"object","properties":{"old":{"type":"string","description":"Text to find, matched byte for byte."},"new":{"type":"string","description":"Text to put in its place."}},"required":["old","new"],"additionalProperties":false}}},"required":["path","edits"],"additionalProperties":false}`

TOOL_EDIT_FIELDS :: []string{"path", "edits"}
TOOL_EDIT_ITEM_FIELDS :: []string{"old", "new"}
TOOL_EDIT_MAX_REPLACEMENTS :: 64
TOOL_EDIT_MAX_FILE_BYTES :: 8 * 1024 * 1024

Edit_Data :: struct {
	path:         string `json:"path"`,
	replacements: int `json:"replacements"`,
}

Tool_Replacement :: struct {
	old: string,
	new: string,
}

@(private)
Tool_Match :: struct {
	start: int,
	end:   int,
	text:  string,
}

TOOL_EDIT_DEFINITION :: Tool_Definition {
	name = TOOL_EDIT_NAME,
	description = TOOL_EDIT_DESCRIPTION,
	input_schema = TOOL_EDIT_SCHEMA,
	// A repeated edit finds different text: the first call consumed the match
	// the second one looks for, so identical arguments do not repeat the effect.
	hints = {read_only = .No, destructive = .Yes, idempotent = .No, open_world = .No},
	execute = tool_edit_execute,
}

tool_edit_execute :: proc(ctx: ^Tool_Context, arguments: json.Object) -> Tool_Result {
	if fields_error := tool_fields_known(arguments, TOOL_EDIT_FIELDS, allocator = ctx.allocator); fields_error.kind != .None {
		return tool_result_refused(ctx, &fields_error)
	}
	path_argument, path_error := tool_field_string(arguments, "path", allocator = ctx.allocator)
	if path_error.kind != .None { return tool_result_refused(ctx, &path_error) }
	edits_value, edits_error := tool_field_array(arguments, "edits", 1, TOOL_EDIT_MAX_REPLACEMENTS, allocator = ctx.allocator)
	if edits_error.kind != .None { return tool_result_refused(ctx, &edits_error) }

	replacements := make([]Tool_Replacement, len(edits_value), ctx.allocator)
	defer delete(replacements, ctx.allocator)
	for value, index in edits_value {
		item_path := fmt.tprintf("edits/%d", index)
		item, item_error := tool_field_object(value, item_path, ctx.allocator)
		if item_error.kind != .None { return tool_result_refused(ctx, &item_error) }
		if fields_error := tool_fields_known(item, TOOL_EDIT_ITEM_FIELDS, item_path, ctx.allocator); fields_error.kind != .None {
			return tool_result_refused(ctx, &fields_error)
		}
		old, old_error := tool_field_string(item, "old", item_path, ctx.allocator)
		if old_error.kind != .None { return tool_result_refused(ctx, &old_error) }
		if old == "" {
			empty := tool_argument_error(.Invalid_Value, fmt.tprintf("%s/old", item_path), "text to find", ctx.allocator)
			return tool_result_refused(ctx, &empty)
		}
		fresh, fresh_error := tool_field_string(item, "new", item_path, ctx.allocator)
		if fresh_error.kind != .None { return tool_result_refused(ctx, &fresh_error) }
		replacements[index] = Tool_Replacement {
			old = old,
			new = fresh,
		}
	}

	path, resolve_error := tool_resolve_path(ctx.workspace, path_argument, allocator = ctx.allocator)
	if resolve_error.kind != .None { return tool_result_refused(ctx, &resolve_error) }
	defer delete(path, ctx.allocator)

	mode, mode_problem := tool_write_mode(path)
	if mode_problem != .None {
		return tool_result_failure(ctx, .Tool_Failed, tool_write_mode_text(path_argument, mode_problem), "not writable")
	}
	info, info_error := os.stat(path, ctx.allocator)
	defer os.file_info_delete(info, ctx.allocator)
	if info_error != nil {
		return tool_result_failure(ctx, .Tool_Failed, fmt.tprintf("there is no file at %s", path_argument), "not a file")
	}
	if info.size > TOOL_EDIT_MAX_FILE_BYTES {
		return tool_result_failure(
			ctx,
			.Tool_Failed,
			fmt.tprintf("%s is larger than the %d-byte edit limit", path_argument, TOOL_EDIT_MAX_FILE_BYTES),
			"too large",
		)
	}
	data, read_error := os.read_entire_file(path, ctx.allocator)
	if read_error != nil {
		return tool_result_failure(ctx, .Tool_Failed, fmt.tprintf("could not read %s: %s", path_argument, os.error_string(read_error)), "unreadable")
	}
	defer delete(data, ctx.allocator)
	text := string(data)

	matches := make([]Tool_Match, len(replacements), ctx.allocator)
	defer delete(matches, ctx.allocator)
	for replacement, index in replacements {
		edit_path := fmt.tprintf("edits/%d/old", index)
		occurrences := strings.count(text, replacement.old)
		if occurrences == 0 {
			missing := tool_argument_error(.Invalid_Value, edit_path, "text that appears in the file", ctx.allocator)
			return tool_result_refused(ctx, &missing)
		}
		if occurrences > 1 {
			ambiguous := tool_argument_error(
				.Invalid_Value,
				edit_path,
				fmt.tprintf("text that appears exactly once; this appears %d times", occurrences),
				ctx.allocator,
			)
			return tool_result_refused(ctx, &ambiguous)
		}
		start := strings.index(text, replacement.old)
		matches[index] = Tool_Match {
			start = start,
			end   = start + len(replacement.old),
			text  = replacement.new,
		}
	}
	slice.sort_by(matches[:], proc(a, b: Tool_Match) -> bool { return a.start < b.start })
	for index in 1 ..< len(matches) {
		if matches[index].start < matches[index - 1].end {
			overlap := tool_argument_error(.Invalid_Value, "edits", "replacements that do not overlap", ctx.allocator)
			return tool_result_refused(ctx, &overlap)
		}
	}

	// One allocation holds the rewritten file, so the buffer is owned outright and
	// a failed write leaves the original untouched.
	size := len(text)
	for match in matches { size += len(match.text) - (match.end - match.start) }
	updated := make([]u8, size, ctx.allocator)
	defer delete(updated, ctx.allocator)
	at, cursor := 0, 0
	for match in matches {
		copy(updated[at:], transmute([]u8)text[cursor:match.start])
		at += match.start - cursor
		copy(updated[at:], transmute([]u8)match.text)
		at += len(match.text)
		cursor = match.end
	}
	copy(updated[at:], transmute([]u8)text[cursor:])

	if write_error, write_cancelled := tool_write_atomic(path, updated, mode, ctx.allocator, ctx.control); write_cancelled {
		return tool_result_failure(ctx, .Cancelled, "the edit was cancelled", "cancelled")
	} else if write_error != nil {
		return tool_result_failure(ctx, .Tool_Failed, fmt.tprintf("could not write %s: %s", path_argument, os.error_string(write_error)), "write failed")
	}
	return tool_result_success(ctx, Edit_Data{path = path_argument, replacements = len(matches)}, fmt.tprintf("%d replacements", len(matches)))
}
