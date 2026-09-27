package agent

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"

TOOL_PATCH_NAME :: "builtin_patch"

TOOL_PATCH_DESCRIPTION :: `Apply a patch that adds, deletes, moves, or changes text files. Relative paths start at the session workspace, and absolute paths are used as given. The whole patch is checked before any file is written, so a patch that does not apply changes nothing.

*** Begin Patch
*** Add File: <path>
+<every line of the new file>
*** Delete File: <path>
*** Update File: <path>
*** Move to: <new path, optional>
@@ <optional: a line above the change, such as a function signature>
 <unchanged line>
-<removed line>
+<added line>
*** End of File <optional: the hunk ends at the end of the file>
*** End Patch

Each @@ starts a hunk. A hunk's unchanged and removed lines must appear exactly once in the file after the previous hunk, so include about three unchanged lines around each change. A hunk with only added lines goes after its @@ line, or at the end of the file.`

TOOL_PATCH_SCHEMA :: `{"type":"object","properties":{"patch":{"type":"string","description":"The whole patch, from *** Begin Patch to *** End Patch."}},"required":["patch"],"additionalProperties":false}`

TOOL_PATCH_FIELDS :: []string{"patch"}

TOOL_PATCH_DEFINITION :: Tool_Definition {
	name = TOOL_PATCH_NAME,
	description = TOOL_PATCH_DESCRIPTION,
	input_schema = TOOL_PATCH_SCHEMA,
	hints = {read_only = .No, destructive = .Yes, idempotent = .No, open_world = .No},
	kind = .Patch,
	execute = tool_patch_execute,
}

PATCH_BEGIN :: "*** Begin Patch"
PATCH_END :: "*** End Patch"
PATCH_ADD :: "*** Add File: "
PATCH_DELETE :: "*** Delete File: "
PATCH_UPDATE :: "*** Update File: "
PATCH_MOVE :: "*** Move to: "
PATCH_END_OF_FILE :: "*** End of File"
PATCH_HUNK :: "@@"

Patch_Operation :: enum u8 {
	Add,
	Delete,
	Update,
}

// Patch_File is one file section of a patch. Its strings borrow the patch text. body holds the
// lines after the section's headers: the new file's `+` lines for Add, the hunks for Update.
Patch_File :: struct {
	operation: Patch_Operation,
	path:      string,
	move_to:   string,
	body:      string,
}

Patch_Failure_Kind :: enum u8 {
	Invalid_Path,
	Repeated_Path,
	File_Missing,
	File_Exists,
	Not_Writable,
	Unreadable,
	Not_Found,
	Ambiguous,
}

@(rodata, private = "file")
PATCH_FAILURE_NAMES := [Patch_Failure_Kind]string {
	.Invalid_Path  = "invalid_path",
	.Repeated_Path = "repeated_path",
	.File_Missing  = "file_missing",
	.File_Exists   = "file_exists",
	.Not_Writable  = "not_writable",
	.Unreadable    = "unreadable",
	.Not_Found     = "not_found",
	.Ambiguous     = "ambiguous",
}

// Patch_Failure is why a patch does not apply. message names the file and, for a hunk, its
// number and the nearest lines, so the model can correct the patch without rereading the file.
Patch_Failure :: struct {
	kind:    Patch_Failure_Kind,
	message: string,
}

Patch_Error :: union {
	Patch_Failure,
	mem.Allocator_Error,
}

// Patch_Change is one file section checked against the filesystem and ready to write.
// target is where the content goes: the Move to path when there is one, otherwise source.
@(private = "file")
Patch_Change :: struct {
	operation:   Patch_Operation,
	source:      string,
	target:      string,
	mode:        os.Permissions,
	content:     []u8,
	summary_end: int,
}

@(private = "file")
Patch_Hunk :: struct {
	anchor: string,
	lines:  string,
	at_end: bool,
}

tool_patch_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (Patch_Args, Tool_Argument_Error) {
	if fields_error := tool_fields_known(arguments, TOOL_PATCH_FIELDS, allocator = ctx.allocator); fields_error.kind != .None { return {}, fields_error }
	patch, patch_error := tool_field_string(arguments, "patch", allocator = ctx.allocator)
	if patch_error.kind != .None { return {}, patch_error }
	files, problem, allocation_error := patch_parse(patch, ctx.allocator)
	if allocation_error != nil { return {}, tool_argument_error(.Too_Large, "patch", "a patch that fits in memory", ctx.allocator) }
	if problem != "" { return {}, tool_argument_error(.Invalid_Value, "patch", problem, ctx.allocator) }
	return Patch_Args{files = files}, {}
}

tool_patch_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(Patch_Args)
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { return patch_failure_result(ctx, arena_error) }
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)

	changes, summary, repaired_hunks, prepare_error := patch_prepare(ctx.workspace, args.files, scratch)
	if prepare_error != nil { return patch_failure_result(ctx, prepare_error) }

	for change, index in changes {
		write_error, cancelled := patch_write(change, ctx.control, scratch)
		if !cancelled && write_error == nil { continue }
		applied := Patch_Output {
			files   = index,
			summary = summary[:changes[index - 1].summary_end] if index > 0 else "",
		}
		applied_note := "; the files listed were already changed" if index > 0 else ""
		if cancelled { return tool_result_of(ctx, .Cancelled, fmt.tprintf("the patch was cancelled%s", applied_note), applied, "cancelled") }
		message := fmt.tprintf("could not write %s: %s%s", args.files[index].path, os.error_string(write_error), applied_note)
		return tool_result_of(ctx, .Tool_Failed, message, applied, "write failed")
	}
	output := Patch_Output {
		files                     = len(changes),
		whitespace_repaired_hunks = repaired_hunks,
		summary                   = summary,
	}
	return tool_result_success(ctx, output, fmt.tprintf("%d files", len(changes)))
}

@(private = "file")
patch_failure_result :: proc(ctx: ^Tool_Context, err: Patch_Error) -> Tool_Result {
	switch failure in err {
	case Patch_Failure:
		return tool_result_failure(ctx, .Tool_Failed, failure.message, PATCH_FAILURE_NAMES[failure.kind])
	case mem.Allocator_Error:
	}
	return tool_result_failure(ctx, .Tool_Failed, "there was not enough memory to prepare the patch", "out of memory")
}

// --- parsing -----------------------------------------------------------------

// patch_parse splits a patch into file sections that borrow patch; files is owned by allocator.
// problem names the first line that breaks the format, is "" for a well-formed patch, and is
// allocated in the temp allocator.
patch_parse :: proc(patch: string, allocator: mem.Allocator) -> (files: []Patch_File, problem: string, err: mem.Allocator_Error) {
	position := 0
	if strings.trim_space(patch_take_line(patch, &position)) != PATCH_BEGIN { return nil, "a patch whose first line is " + PATCH_BEGIN, nil }

	section_count := 0
	for scan := position; scan < len(patch); {
		if _, _, is_header := patch_section_header(patch_take_line(patch, &scan)); is_header { section_count += 1 }
	}
	if section_count == 0 { return nil, "a patch that names at least one file", nil }
	files = make([]Patch_File, section_count, allocator) or_return
	defer if problem != "" {
		delete(files, allocator)
		files = nil
	}

	section := -1
	body_start := position
	line_number := 1
	ended := false
	for position < len(patch) {
		line_start := position
		line := patch_take_line(patch, &position)
		line_number += 1
		if ended {
			if strings.trim_space(line) != "" {
				problem = fmt.tprintf("a patch with nothing after %s, but line %d follows it", PATCH_END, line_number)
				return
			}
			continue
		}
		operation, path, is_header := patch_section_header(line)
		if is_header || strings.trim_space(line) == PATCH_END {
			if section >= 0 {
				files[section].body = patch[body_start:line_start]
				if problem = patch_section_problem(files[section]); problem != "" { return }
			}
			if !is_header {
				ended = true
				continue
			}
			if path == "" {
				problem = fmt.tprintf("a patch whose line %d names a file", line_number)
				return
			}
			section += 1
			files[section] = {
				operation = operation,
				path      = path,
			}
			body_start = position
			continue
		}
		if section < 0 {
			problem = fmt.tprintf("a patch whose line %d is a file header such as %s<path>", line_number, PATCH_UPDATE)
			return
		}
		file := &files[section]
		if strings.has_prefix(line, PATCH_MOVE) {
			if file.operation != .Update || file.move_to != "" || line_start != body_start {
				problem = fmt.tprintf("a patch whose line %d, %s, directly follows %s<path>", line_number, PATCH_MOVE, PATCH_UPDATE)
				return
			}
			file.move_to = strings.trim_space(line[len(PATCH_MOVE):])
			if file.move_to == "" {
				problem = fmt.tprintf("a patch whose line %d names the file to move to", line_number)
				return
			}
			body_start = position
			continue
		}
		if !patch_body_line_valid(file.operation, line) {
			switch file.operation {
			case .Add:
				problem = fmt.tprintf("a patch whose line %d starts with +, as every line of an added file does", line_number)
			case .Delete:
				problem = fmt.tprintf("a patch with no lines after %s%s, but line %d follows it", PATCH_DELETE, file.path, line_number)
			case .Update:
				problem = fmt.tprintf("a patch whose line %d starts with a space, -, +, or %s", line_number, PATCH_HUNK)
			}
			return
		}
	}
	if !ended { problem = "a patch whose last line is " + PATCH_END }
	return
}

@(private = "file")
patch_section_header :: proc(line: string) -> (operation: Patch_Operation, path: string, is_header: bool) {
	switch {
	case strings.has_prefix(line, PATCH_ADD):
		return .Add, strings.trim_space(line[len(PATCH_ADD):]), true
	case strings.has_prefix(line, PATCH_DELETE):
		return .Delete, strings.trim_space(line[len(PATCH_DELETE):]), true
	case strings.has_prefix(line, PATCH_UPDATE):
		return .Update, strings.trim_space(line[len(PATCH_UPDATE):]), true
	}
	return
}

@(private = "file")
patch_body_line_valid :: proc(operation: Patch_Operation, line: string) -> bool {
	switch operation {
	case .Add:
		return strings.has_prefix(line, "+")
	case .Delete:
		return strings.trim_space(line) == ""
	case .Update:
		if line == "" || line == PATCH_END_OF_FILE || strings.has_prefix(line, PATCH_HUNK) { return true }
		return line[0] == ' ' || line[0] == '-' || line[0] == '+'
	}
	return false
}

@(private = "file")
patch_section_problem :: proc(file: Patch_File) -> string {
	if file.operation != .Update { return "" }
	if file.body == "" && file.move_to == "" { return fmt.tprintf("a patch whose %s%s section has a hunk or a %s line", PATCH_UPDATE, file.path, PATCH_MOVE) }
	hunks := file.body
	hunk_number := 0
	for hunk in patch_next_hunk(&hunks) {
		hunk_number += 1
		if !patch_hunk_changes(hunk.lines) { return fmt.tprintf("a patch whose hunk %d of %s adds or removes a line", hunk_number, file.path) }
	}
	return ""
}

// patch_take_line returns the line that starts at position, without its line ending, and moves
// position to the start of the next line.
@(private = "file")
patch_take_line :: proc(text: string, position: ^int) -> string {
	rest := text[position^:]
	length := strings.index_byte(rest, '\n')
	if length < 0 {
		position^ = len(text)
		return strings.trim_suffix(rest, "\r")
	}
	position^ += length + 1
	return strings.trim_suffix(rest[:length], "\r")
}

// patch_next_hunk takes the next hunk from the front of an Update section's body.
@(private = "file")
patch_next_hunk :: proc(body: ^string) -> (hunk: Patch_Hunk, more: bool) {
	text := body^
	if text == "" { return }
	position := 0
	if strings.has_prefix(text, PATCH_HUNK) { hunk.anchor = strings.trim_space(patch_take_line(text, &position)[len(PATCH_HUNK):]) }
	lines_start := position
	for position < len(text) {
		line_start := position
		line := patch_take_line(text, &position)
		if strings.has_prefix(line, PATCH_HUNK) {
			position = line_start
			break
		}
		if line == PATCH_END_OF_FILE {
			hunk.lines = text[lines_start:line_start]
			hunk.at_end = true
			body^ = text[position:]
			return hunk, true
		}
	}
	hunk.lines = text[lines_start:position]
	body^ = text[position:]
	return hunk, true
}

// patch_hunk_line splits a hunk line into its marker and text. A bare empty line is an
// unchanged empty line whose leading space was dropped.
@(private = "file")
patch_hunk_line :: proc(line: string) -> (marker: u8, text: string) {
	if line == "" { return ' ', "" }
	return line[0], line[1:]
}

@(private = "file")
patch_hunk_changes :: proc(lines: string) -> bool {
	position := 0
	for position < len(lines) {
		marker, _ := patch_hunk_line(patch_take_line(lines, &position))
		if marker == '+' || marker == '-' { return true }
	}
	return false
}

// --- preparing ---------------------------------------------------------------

// patch_prepare checks every file section against the filesystem and computes each new file.
// Everything it returns is owned by allocator. summary holds one line per change, and each
// change records where its line ends.
@(private = "file")
patch_prepare :: proc(
	workspace: string,
	files: []Patch_File,
	allocator: mem.Allocator,
) -> (
	changes: []Patch_Change,
	summary: string,
	repaired_hunks: int,
	err: Patch_Error,
) {
	changes = make([]Patch_Change, len(files), allocator) or_return
	summary_buffer := make([dynamic]u8, allocator) or_return
	for file, index in files {
		change := &changes[index]
		change.operation = file.operation
		change.source = patch_resolve(workspace, file.path, allocator) or_return
		change.target = change.source
		if file.move_to != "" { change.target = patch_resolve(workspace, file.move_to, allocator) or_return }
		for earlier in changes[:index] {
			if change.source == earlier.source || change.source == earlier.target || change.target == earlier.source || change.target == earlier.target {
				return nil, "", 0, Patch_Failure {
					.Repeated_Path,
					fmt.aprintf("%s is named by more than one section of the patch", file.path, allocator = allocator),
				}
			}
		}

		switch file.operation {
		case .Add:
			if os.exists(change.target) { return nil, "", 0, Patch_Failure{.File_Exists, fmt.aprintf("%s already exists", file.path, allocator = allocator)} }
			change.mode = os.Permissions_Default_File
			change.content = patch_added_content(file.body, allocator) or_return
			patch_append(&summary_buffer, "added ", file.path, "\n") or_return
		case .Delete:
			change.mode = patch_existing_mode(change.source, file.path, allocator) or_return
			patch_append(&summary_buffer, "deleted ", file.path, "\n") or_return
		case .Update:
			change.mode = patch_existing_mode(change.source, file.path, allocator) or_return
			if change.target != change.source && os.exists(change.target) {
				return nil, "", 0, Patch_Failure{.File_Exists, fmt.aprintf("%s already exists", file.move_to, allocator = allocator)}
			}
			original, read_error := os.read_entire_file(change.source, allocator)
			if read_error != nil {
				message := fmt.aprintf("could not read %s: %s", file.path, os.error_string(read_error), allocator = allocator)
				return nil, "", 0, Patch_Failure{.Unreadable, message}
			}
			hunks_repaired: int
			change.content, hunks_repaired = patch_update(file.path, string(original), file.body, allocator) or_return
			repaired_hunks += hunks_repaired
			if file.move_to == "" {
				patch_append(&summary_buffer, "updated ", file.path, "\n") or_return
			} else {
				patch_append(&summary_buffer, "moved ", file.path, " to ", file.move_to, "\n") or_return
			}
		}
		change.summary_end = len(summary_buffer)
	}
	return changes, string(summary_buffer[:]), repaired_hunks, nil
}

@(private = "file")
patch_resolve :: proc(workspace, path: string, allocator: mem.Allocator) -> (string, Patch_Error) {
	resolved, resolve_error := tool_resolve_path(workspace, path, allocator = allocator)
	if resolve_error.kind != .None { return "", Patch_Failure{.Invalid_Path, fmt.aprintf("%s is not a valid path", path, allocator = allocator)} }
	return resolved, nil
}

@(private = "file")
patch_existing_mode :: proc(path, path_argument: string, allocator: mem.Allocator) -> (os.Permissions, Patch_Error) {
	if !os.exists(path) { return {}, Patch_Failure{.File_Missing, fmt.aprintf("%s does not exist", path_argument, allocator = allocator)} }
	mode, problem := tool_write_mode(path)
	if problem != .None { return {}, Patch_Failure{.Not_Writable, tool_write_mode_text(path_argument, problem)} }
	return mode, nil
}

@(private = "file")
patch_append :: proc(buffer: ^[dynamic]u8, parts: ..string) -> mem.Allocator_Error {
	for part in parts { append(buffer, part) or_return }
	return nil
}

@(private = "file")
patch_added_content :: proc(body: string, allocator: mem.Allocator) -> (content: []u8, err: mem.Allocator_Error) {
	buffer := make([dynamic]u8, 0, len(body), allocator) or_return
	position := 0
	for position < len(body) {
		line := patch_take_line(body, &position)
		patch_append(&buffer, line[1:], "\n") or_return
	}
	return buffer[:], nil
}

// patch_update applies an Update section's hunks to a file's text. Unchanged lines keep the
// file's own bytes, and added lines take the file's line ending.
@(private = "file")
patch_update :: proc(path_argument, original, body: string, allocator: mem.Allocator) -> (updated: []u8, repaired_hunks: int, err: Patch_Error) {
	file_lines := patch_split_lines(original, allocator) or_return
	line_ending := "\r\n" if len(file_lines) > 0 && strings.has_suffix(file_lines[0], "\r") else "\n"
	buffer := make([dynamic]u8, 0, len(original) + len(body), allocator) or_return

	copied, cursor, hunk_number := 0, 0, 0
	hunks := body
	for hunk in patch_next_hunk(&hunks) {
		hunk_number += 1
		if hunk.anchor != "" {
			anchor_index, found := patch_find_anchor(file_lines, hunk.anchor, cursor)
			if !found {
				message := fmt.aprintf(
					"hunk %d of %s: its %s line %q does not appear from line %d on",
					hunk_number,
					path_argument,
					PATCH_HUNK,
					hunk.anchor,
					cursor + 1,
					allocator = allocator,
				)
				return nil, 0, Patch_Failure{.Not_Found, message}
			}
			cursor = anchor_index + 1
		}
		expected := patch_expected_lines(hunk.lines, allocator) or_return
		start := cursor if hunk.anchor != "" else len(file_lines)
		if len(expected) > 0 {
			loose: bool
			start, loose = patch_locate(path_argument, hunk_number, file_lines, expected, cursor, hunk.at_end, allocator) or_return
			if loose { repaired_hunks += 1 }
		}

		for line in file_lines[copied:start] { patch_append(&buffer, line, "\n") or_return }
		matched := start
		position := 0
		for position < len(hunk.lines) {
			marker, text := patch_hunk_line(patch_take_line(hunk.lines, &position))
			switch marker {
			case ' ':
				patch_append(&buffer, file_lines[matched], "\n") or_return
				matched += 1
			case '-':
				matched += 1
			case '+':
				patch_append(&buffer, text, line_ending) or_return
			}
		}
		copied = matched
		cursor = matched
	}
	for line in file_lines[copied:] { patch_append(&buffer, line, "\n") or_return }

	text := string(buffer[:])
	if original != "" && !strings.has_suffix(original, "\n") {
		text = strings.trim_suffix(text, "\n")
		if line_ending == "\r\n" { text = strings.trim_suffix(text, "\r") }
	}
	return transmute([]u8)text, repaired_hunks, nil
}

// patch_split_lines views text as lines without their newline. A trailing newline ends the last
// line rather than starting an empty one.
@(private = "file")
patch_split_lines :: proc(text: string, allocator: mem.Allocator) -> (lines: []string, err: mem.Allocator_Error) {
	if text == "" { return nil, nil }
	body := strings.trim_suffix(text, "\n")
	lines = make([]string, strings.count(body, "\n") + 1, allocator) or_return
	position := 0
	for &line in lines {
		rest := body[position:]
		length := strings.index_byte(rest, '\n')
		if length < 0 { length = len(rest) }
		line = rest[:length]
		position += length + 1
	}
	return lines, nil
}

@(private = "file")
patch_expected_lines :: proc(lines: string, allocator: mem.Allocator) -> (expected: []string, err: mem.Allocator_Error) {
	buffer := make([dynamic]string, allocator) or_return
	position := 0
	for position < len(lines) {
		marker, text := patch_hunk_line(patch_take_line(lines, &position))
		if marker != '+' { append(&buffer, text) or_return }
	}
	return buffer[:], nil
}

@(private = "file")
patch_find_anchor :: proc(file_lines: []string, anchor: string, from: int) -> (int, bool) {
	for index in from ..< len(file_lines) {
		if strings.trim_space(file_lines[index]) == anchor { return index, true }
	}
	return 0, false
}

// patch_locate finds the one place at or after from where a hunk's expected lines appear. An
// exact match wins; only when there is none are trailing spaces ignored, and loose reports that.
@(private = "file")
patch_locate :: proc(
	path_argument: string,
	hunk_number: int,
	file_lines, expected: []string,
	from: int,
	at_end: bool,
	allocator: mem.Allocator,
) -> (
	start: int,
	loose: bool,
	err: Patch_Error,
) {
	starts := patch_matches(file_lines, expected, from, at_end, false, allocator) or_return
	if len(starts) == 0 {
		starts = patch_matches(file_lines, expected, from, at_end, true, allocator) or_return
		loose = true
	}
	switch len(starts) {
	case 1:
		return starts[0], loose, nil
	case 0:
		return 0, false, Patch_Failure{.Not_Found, patch_not_found_message(path_argument, hunk_number, file_lines, expected, from, allocator)}
	}
	for &line in starts { line += 1 }
	message := fmt.aprintf(
		"hunk %d of %s matches %d places, at lines %v; add unchanged lines around the change so it matches one place",
		hunk_number,
		path_argument,
		len(starts),
		starts,
		allocator = allocator,
	)
	return 0, false, Patch_Failure{.Ambiguous, message}
}

@(private = "file")
patch_matches :: proc(file_lines, expected: []string, from: int, at_end, loose: bool, allocator: mem.Allocator) -> (starts: []int, err: mem.Allocator_Error) {
	buffer := make([dynamic]int, allocator) or_return
	last := len(file_lines) - len(expected)
	first := max(last, from) if at_end else from
	for start in first ..= last {
		if patch_lines_match(file_lines[start:], expected, loose) { append(&buffer, start) or_return }
	}
	return buffer[:], nil
}

@(private = "file")
patch_lines_match :: proc(file_lines, expected: []string, loose: bool) -> bool {
	for text, index in expected {
		if !patch_line_matches(file_lines[index], text, loose) { return false }
	}
	return true
}

@(private = "file")
patch_line_matches :: proc(file_line, patch_line: string, loose: bool) -> bool {
	file_text := strings.trim_suffix(file_line, "\r")
	if loose { return strings.trim_right_space(file_text) == strings.trim_right_space(patch_line) }
	return file_text == patch_line
}

// patch_not_found_message describes where the longest run of a hunk's leading lines matches, and
// the first line there that differs.
@(private = "file")
patch_not_found_message :: proc(path_argument: string, hunk_number: int, file_lines, expected: []string, from: int, allocator: mem.Allocator) -> string {
	best_start, best_count := from, 0
	for start in from ..< len(file_lines) {
		count := 0
		for count < len(expected) && start + count < len(file_lines) && patch_line_matches(file_lines[start + count], expected[count], true) { count += 1 }
		if count > best_count { best_start, best_count = start, count }
	}
	differing := best_start + best_count
	switch {
	case best_count == 0:
		return fmt.aprintf(
			"hunk %d of %s: no line from line %d on reads %q, the hunk's first line",
			hunk_number,
			path_argument,
			from + 1,
			expected[0],
			allocator = allocator,
		)
	case best_count == len(expected):
		return fmt.aprintf(
			"hunk %d of %s matches at line %d, but %s requires it to end the file",
			hunk_number,
			path_argument,
			best_start + 1,
			PATCH_END_OF_FILE,
			allocator = allocator,
		)
	case differing == len(file_lines):
		return fmt.aprintf(
			"hunk %d of %s: the file ends where the hunk expects %q; the hunk's earlier lines match from line %d",
			hunk_number,
			path_argument,
			expected[best_count],
			best_start + 1,
			allocator = allocator,
		)
	}
	return fmt.aprintf(
		"hunk %d of %s: line %d reads %q where the hunk expects %q; the hunk's earlier lines match from line %d",
		hunk_number,
		path_argument,
		differing + 1,
		strings.trim_suffix(file_lines[differing], "\r"),
		expected[best_count],
		best_start + 1,
		allocator = allocator,
	)
}

// --- writing -----------------------------------------------------------------

// patch_write applies one prepared change. A moved file is written at its new path before the
// old one is removed, so a failure between the two leaves both rather than neither.
@(private = "file")
patch_write :: proc(change: Patch_Change, control: Tool_Control, allocator: mem.Allocator) -> (write_error: os.Error, cancelled: bool) {
	if tool_control_cancelled(control) { return nil, true }
	if change.operation == .Delete { return os.remove(change.source), false }

	directory, _ := os.split_path(change.target)
	if directory != "" {
		if directory_error := os.make_directory_all(directory);
		   directory_error != nil && directory_error != os.General_Error.Exist { return directory_error, false }
	}
	write_error, cancelled = tool_write_atomic(change.target, change.content, change.mode, allocator, control)
	if write_error != nil || cancelled || change.target == change.source { return }
	return os.remove(change.source), false
}
