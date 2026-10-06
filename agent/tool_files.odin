package agent

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:unicode/utf8"


// --- read --------------------------------------------------------------------

TOOL_READ_NAME :: "builtin_read"

TOOL_READ_DESCRIPTION :: `Read a text file and return a window of its lines. Use it to see a file before editing it and to continue a result that was cut off; to find text across many files, run a search command with builtin_shell instead of reading them all. Relative paths start at the session workspace, and absolute paths are used as given. Directories, binary files, and files that are not valid UTF-8 fail.

offset is the first line, counting from 1 (default 1), and limit is the number of lines (default 2000). The result starts with path, first_line, line_count (lines returned), total_lines, and truncated, which is true when lines remain after the window; the text of the lines follows after a blank line. At most 32 KiB of one result is shown to you. When the window is longer, the text is cut at a line break and a notice gives the number of complete lines shown and the offset to continue from; call builtin_read again with that offset and a smaller limit. The notice also names a file that holds the whole result.`

TOOL_READ_SCHEMA :: `{"type":"object","properties":{"path":{"type":"string","description":"File path. Relative paths start at the session workspace; absolute paths are used as given."},"offset":{"type":["integer","null"],"description":"First line to read, counting from 1. Default: 1."},"limit":{"type":["integer","null"],"description":"Maximum number of lines to read. Default: 2000."}},"required":["path"],"additionalProperties":false}`

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

@(require_results)
tool_read_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Read_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_READ_FIELDS, allocator = ctx.allocator) or_return
	args.path = tool_field_string(arguments, "path", allocator = ctx.allocator) or_return
	args.offset = tool_field_optional_int(arguments, "offset", 1, 1, max(int) / 2, &ctx.repairs, allocator = ctx.allocator) or_return
	args.limit = tool_field_optional_int(arguments, "limit", TOOL_READ_DEFAULT_LINES, 1, max(int) / 2, &ctx.repairs, allocator = ctx.allocator) or_return
	return
}

@(require_results)
tool_read_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(Read_Args)

	path, resolve_error := tool_resolve_path(ctx.workspace, args.path, allocator = ctx.allocator)
	if resolve_error != nil { return tool_result_refused(ctx, &resolve_error) }
	defer delete(path, ctx.allocator)

	file, open_error := os.open(path, {.Read, .Non_Blocking})
	if open_error != nil {
		return tool_result_failure(ctx, .Tool_Failed, fmt.tprintf("could not read %s: %s", args.path, os.error_string(open_error)), "unreadable")
	}
	defer os.close(file)
	info, info_error := os.fstat(file, ctx.allocator)
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
	data, read_error := os.read_entire_file(file, ctx.allocator)
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

TOOL_WRITE_DESCRIPTION :: `Write a whole text file, creating it or replacing what it held. Use it for a new file or a complete rewrite, including a script you would otherwise create with a shell heredoc; to change part of an existing file use builtin_patch, which sends only the changed lines. Relative paths start at the session workspace, and absolute paths are used as given. The parent directory must already exist; builtin_patch with Add File creates directories. The write is atomic: a reader sees the old file or the whole new one, and a replaced file keeps its permissions. A symbolic link or a path that is not a regular file is refused. The result gives path and the number of bytes written.`

TOOL_WRITE_SCHEMA :: `{"type":"object","properties":{"path":{"type":"string","description":"File path. Relative paths start at the session workspace; absolute paths are used as given."},"content":{"type":"string","description":"The complete new contents of the file; whatever the file held is replaced."}},"required":["path","content"],"additionalProperties":false}`

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

@(require_results)
tool_write_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Write_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_WRITE_FIELDS, allocator = ctx.allocator) or_return
	args.path = tool_field_string(arguments, "path", allocator = ctx.allocator) or_return
	args.content = tool_field_string(arguments, "content", allocator = ctx.allocator) or_return
	return
}

@(require_results)
tool_write_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(Write_Args)

	path, resolve_error := tool_resolve_path(ctx.workspace, args.path, allocator = ctx.allocator)
	if resolve_error != nil { return tool_result_refused(ctx, &resolve_error) }
	defer delete(path, ctx.allocator)

	mode, mode_error := tool_write_mode(path)
	if mode_error != .None && mode_error != .Missing {
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
// touching it. Missing is not a refusal for a tool that creates files.
Tool_Path_Problem :: enum {
	None,
	Missing,
	Unreadable,
	Not_Regular,
	Symlink,
}

// tool_write_mode returns the mode a replacement file should carry: the mode the
// existing file has, or a zero mode with .Missing when nothing exists at path, so
// the file gets the creation default. A path that exists as anything but a regular
// file, or that is a symbolic link, is refused rather than replaced: renaming over
// a link would silently turn it into a regular file. A path that cannot be
// inspected is .Unreadable.
@(require_results)
tool_write_mode :: proc(path: string) -> (os.Permissions, Tool_Path_Problem) {
	// The mode is the answer; the info the lstat filled in is scratch.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	info, info_error := os.lstat(path, context.temp_allocator)
	if info_error != nil {
		if info_error == os.General_Error.Not_Exist { return {}, .Missing }
		return {}, .Unreadable
	}
	defer os.file_info_delete(info, context.temp_allocator)
	if info.type == .Symlink { return {}, .Symlink }
	if info.type != .Regular { return {}, .Not_Regular }
	return info.mode, .None
}

@(require_results)
tool_write_mode_text :: proc(path: string, problem: Tool_Path_Problem) -> string {
	switch problem {
	case .Symlink:
		return fmt.tprintf("%s is a symbolic link, so writing it would replace the link", path)
	case .Not_Regular:
		return fmt.tprintf("%s is not a regular file", path)
	case .Unreadable:
		return fmt.tprintf("%s could not be inspected", path)
	case .Missing, .None:
		return fmt.tprintf("%s cannot be written", path)
	}
	return ""
}

// tool_write_atomic writes content to a temporary file beside path and renames it
// into place, so a reader never sees a half-written file and a failed write
// leaves the original untouched. Cancellation is cooperative: it is checked
// before the temporary write begins, while the temporary file grows, and
// before the rename commits. A cancellation before the rename deletes the
// temporary file and reports cancelled; once the rename succeeds the observed
// result stands, because the effect already committed.
// A zero mode keeps the creation default, which the process umask narrows; any
// other mode is applied exactly, so a replaced file keeps its permissions.
@(require_results)
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
	dir, base := os.split_path(path)
	pattern := fmt.aprintf("%s.nabla-*", base, allocator = allocator)
	defer delete(pattern, allocator)
	file, open_error := os.create_temp_file(dir, pattern)
	if open_error != nil { return open_error, false }
	// The name belongs to the file and dies with close, while removal runs after it.
	temp_path, clone_error := strings.clone(os.name(file), allocator)
	if clone_error != nil {
		_ = os.close(file)
		return clone_error, false
	}
	defer delete(temp_path, allocator)
	defer _ = os.remove(temp_path)
	if mode != {} {
		if mode_error := os.fchmod(file, mode); mode_error != nil {
			_ = os.close(file)
			return mode_error, false
		}
	}

	cancelled_write := false
	written := 0
	for written < len(content) {
		if tool_control_cancelled(control) {
			cancelled_write = true
			break
		}
		count, chunk_error := os.write(file, content[written:])
		if chunk_error != nil {
			// The write already failed, so the cleanup that follows reports nothing more.
			_ = os.close(file)
			return chunk_error, false
		}
		if count <= 0 {
			_ = os.close(file)
			return os.General_Error.Invalid_File, false
		}
		written += count
	}
	if !cancelled_write {
		if sync_error := os.sync(file); sync_error != nil {
			_ = os.close(file)
			return sync_error, false
		}
	}
	if close_error := os.close(file); close_error != nil {
		if cancelled_write { return nil, true }
		return close_error, false
	}
	if cancelled_write || tool_control_cancelled(control) {
		return nil, true
	}
	if rename_error := os.rename(temp_path, path); rename_error != nil {
		return rename_error, false
	}
	return nil, false
}
