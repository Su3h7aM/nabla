package agent

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"


// --- read --------------------------------------------------------------------

TOOL_READ_NAME :: "builtin_read"

TOOL_READ_DESCRIPTION :: "Read a text file. Relative paths start at the session workspace, and absolute paths are used as given. Returns the requested lines together with the line range they came from and the file's total line count, so a long file can be read in parts."

TOOL_READ_SCHEMA :: `{"type":"object","properties":{"path":{"type":"string","description":"File path. Relative paths start at the session workspace; absolute paths are used as given."},"offset":{"type":["integer","null"],"description":"First line to read, counting from 1. Leave out to start at the beginning."},"limit":{"type":["integer","null"],"description":"Maximum number of lines to read. Leave out for the harness default."}},"required":["path"],"additionalProperties":false}`

TOOL_READ_FIELDS :: []string{"path", "offset", "limit"}

TOOL_READ_DEFAULT_LINES :: 2000

TOOL_READ_DEFINITION :: Tool_Definition {
	name = TOOL_READ_NAME,
	description = TOOL_READ_DESCRIPTION,
	input_schema = TOOL_READ_SCHEMA,
	hints = {read_only = .Yes, destructive = .No, idempotent = .Yes, open_world = .No},
	kind = .Read,
	execute = tool_read_execute,
}

// tool_read_args reads the read tool's arguments.
tool_read_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Read_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_READ_FIELDS, allocator = ctx.allocator) or_return
	args.path = tool_field_string(arguments, "path", allocator = ctx.allocator) or_return
	args.offset = tool_field_optional_int(arguments, "offset", 1, 1, max(int) / 2, &ctx.repairs, allocator = ctx.allocator) or_return
	args.limit = tool_field_optional_int(arguments, "limit", TOOL_READ_DEFAULT_LINES, 1, max(int) / 2, &ctx.repairs, allocator = ctx.allocator) or_return
	return
}

tool_read_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(Read_Args)

	path, resolve_error := tool_resolve_path(ctx.workspace, args.path, allocator = ctx.allocator)
	if resolve_error != nil { return tool_result_refused(ctx, &resolve_error) }
	defer delete(path, ctx.allocator)

	info, info_error := os.stat(path, ctx.allocator)
	defer os.file_info_delete(info, ctx.allocator)
	if info_error != nil || info.type != .Regular {
		return tool_result_failure(ctx, .Tool_Failed, fmt.tprintf("there is no readable file at %s", args.path), "not a file")
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
	// Only text is handed to the model: a provider request carries UTF-8, and a reader
	// that silently received a prefix would not know it had. A NUL marks a binary file.
	if strings.index_byte(text, 0) >= 0 || !utf8.valid_string(text) {
		return tool_result_failure(ctx, .Tool_Failed, fmt.tprintf("%s is not a text file", args.path), "binary")
	}

	total_lines := tool_line_count(text)
	start := tool_line_start(text, args.offset)
	end, lines := tool_line_span(text, start, args.limit)
	content := text[start:end]

	result := Read_Output {
		path        = args.path,
		content     = content,
		first_line  = args.offset,
		line_count  = lines,
		total_lines = total_lines,
		truncated   = end < len(text),
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

// tool_line_span returns the end offset and line count of up to limit lines starting at start.
@(private)
tool_line_span :: proc(text: string, start, limit: int) -> (end: int, lines: int) {
	end = start
	for lines < limit && end < len(text) {
		newline := strings.index_byte(text[end:], '\n')
		next := len(text)
		if newline >= 0 { next = end + newline + 1 }
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

TOOL_WRITE_DEFINITION :: Tool_Definition {
	name = TOOL_WRITE_NAME,
	description = TOOL_WRITE_DESCRIPTION,
	input_schema = TOOL_WRITE_SCHEMA,
	// Rewriting identical content reaches the same file, so a repeated call
	// with identical arguments is idempotent.
	hints = {read_only = .No, destructive = .Yes, idempotent = .Yes, open_world = .No},
	kind = .Write,
	execute = tool_write_execute,
}

tool_write_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Write_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_WRITE_FIELDS, allocator = ctx.allocator) or_return
	args.path = tool_field_string(arguments, "path", allocator = ctx.allocator) or_return
	args.content = tool_field_string(arguments, "content", allocator = ctx.allocator) or_return
	return
}

tool_write_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(Write_Args)

	path, resolve_error := tool_resolve_path(ctx.workspace, args.path, allocator = ctx.allocator)
	if resolve_error != nil { return tool_result_refused(ctx, &resolve_error) }
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
	return tool_result_success(ctx, Write_Output{path = args.path, bytes = len(args.content)}, fmt.tprintf("wrote %d bytes", len(args.content)))
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
