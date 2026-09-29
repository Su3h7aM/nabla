package agent

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"

// Patch_Change is one file section checked against the filesystem and ready to write.
// target is where the content goes: the Move to path when there is one, otherwise source.
@(private)
Patch_Change :: struct {
	operation:   Patch_Operation,
	source:      string,
	target:      string,
	mode:        os.Permissions,
	content:     []u8,
	summary_end: int,
}

// Patch_Match_Level is how loosely a hunk's lines are compared with the file's, from strictest
// to loosest. A looser level is tried only when a stricter one finds no match.
@(private)
Patch_Match_Level :: enum u8 {
	Exact,
	Trailing_Space,
	Surrounding_Space,
}

// Patch_Placement is where one hunk applies. start and removed are file line indexes. reindent
// is set when the hunk matched only without its indentation.
@(private)
Patch_Placement :: struct {
	hunk:     int,
	start:    int,
	removed:  int,
	reindent: bool,
}

// patch_prepare checks every file section against the filesystem and computes each new file.
// Everything it returns is owned by allocator. summary holds one line per change, and each
// change records where its line ends.
@(private, require_results)
patch_prepare :: proc(
	workspace: string,
	args: Patch_Args,
	allocator: mem.Allocator,
) -> (
	changes: []Patch_Change,
	summary: string,
	repaired_hunks: int,
	err: Patch_Error,
) {
	changes = make([]Patch_Change, len(args.files), allocator) or_return
	summary_buffer := make([dynamic]u8, allocator) or_return
	for file, index in args.files {
		change := &changes[index]
		change.operation = file.operation
		change.source = patch_resolve(workspace, file.path, allocator) or_return
		change.target = change.source
		if file.move_to != "" { change.target = patch_resolve(workspace, file.move_to, allocator) or_return }
		for earlier in changes[:index] {
			if change.source == earlier.source || change.source == earlier.target || change.target == earlier.source || change.target == earlier.target {
				return nil, "", 0, patch_failure(.Repeated_Path, allocator, "%s is named by more than one section of the patch", file.path)
			}
		}
		hunks := args.hunks[file.first_hunk:][:file.hunk_count]

		switch file.operation {
		case .Add:
			exists, exists_error := patch_path_exists(change.target, file.path, allocator)
			if exists_error != nil { return nil, "", 0, exists_error }
			if exists {
				return nil, "", 0, patch_failure(.File_Exists, allocator, "%s already exists; use %s to change it", file.path, PATCH_HEADERS[.Update])
			}
			change.mode = os.Permissions_Default_File
			hunks_repaired: int
			change.content, hunks_repaired = patch_update(file.path, "", args.lines, hunks, allocator) or_return
			repaired_hunks += hunks_repaired
			patch_append(&summary_buffer, "added ", file.path, "\n") or_return
		case .Delete:
			change.mode = patch_existing_mode(change.source, file.path, allocator) or_return
			patch_append(&summary_buffer, "deleted ", file.path, "\n") or_return
		case .Update:
			original := ""
			source_exists, source_exists_error := patch_path_exists(change.source, file.path, allocator)
			if source_exists_error != nil { return nil, "", 0, source_exists_error }
			if !source_exists && patch_only_adds(args.lines, hunks) && file.move_to == "" {
				change.mode = os.Permissions_Default_File
				patch_append(&summary_buffer, "added ", file.path, "\n") or_return
			} else {
				change.mode = patch_existing_mode(change.source, file.path, allocator) or_return
				if change.target != change.source {
					target_exists, target_exists_error := patch_path_exists(change.target, file.move_to, allocator)
					if target_exists_error != nil { return nil, "", 0, target_exists_error }
					if target_exists { return nil, "", 0, patch_failure(.File_Exists, allocator, "%s already exists", file.move_to) }
				}
				data, read_error := os.read_entire_file(change.source, allocator)
				if read_error !=
				   nil { return nil, "", 0, patch_failure(.Unreadable, allocator, "could not read %s: %s", file.path, os.error_string(read_error)) }
				original = string(data)
				if file.move_to == "" {
					patch_append(&summary_buffer, "updated ", file.path, "\n") or_return
				} else {
					patch_append(&summary_buffer, "moved ", file.path, " to ", file.move_to, "\n") or_return
				}
			}
			hunks_repaired: int
			change.content, hunks_repaired = patch_update(file.path, original, args.lines, hunks, allocator) or_return
			repaired_hunks += hunks_repaired
		}
		change.summary_end = len(summary_buffer)
	}
	return changes, string(summary_buffer[:]), repaired_hunks, nil
}

@(private = "file", require_results)
patch_path_exists :: proc(path, path_argument: string, allocator: mem.Allocator) -> (exists: bool, err: Patch_Error) {
	info, info_error := os.lstat(path, allocator)
	if info_error == os.General_Error.Not_Exist { return false, nil }
	if info_error != nil {
		return false, patch_failure(.Unreadable, allocator, "could not inspect %s: %s", path_argument, os.error_string(info_error))
	}
	os.file_info_delete(info, allocator)
	return true, nil
}

@(private = "file", require_results)
patch_failure :: proc(kind: Patch_Failure_Kind, allocator: mem.Allocator, format: string, arguments: ..any) -> Patch_Failure {
	return {kind, fmt.aprintf(format, ..arguments, allocator = allocator)}
}

@(private = "file", require_results)
patch_resolve :: proc(workspace, path: string, allocator: mem.Allocator) -> (string, Patch_Error) {
	resolved, resolve_error := tool_resolve_path(workspace, path, allocator = allocator)
	if resolve_error != nil { return "", patch_failure(.Invalid_Path, allocator, "%s is not a valid path", path) }
	return resolved, nil
}

@(private = "file", require_results)
patch_existing_mode :: proc(path, path_argument: string, allocator: mem.Allocator) -> (os.Permissions, Patch_Error) {
	mode, problem := tool_write_mode(path)
	if problem == .Missing { return {}, patch_failure(.File_Missing, allocator, "%s does not exist; use %s to create it", path_argument, PATCH_HEADERS[.Add]) }
	if problem != .None { return {}, Patch_Failure{.Not_Writable, tool_write_mode_text(path_argument, problem)} }
	return mode, nil
}

@(private = "file", require_results)
patch_append :: proc(buffer: ^[dynamic]u8, parts: ..string) -> mem.Allocator_Error {
	for part in parts { append(buffer, part) or_return }
	return nil
}

@(private = "file")
patch_hunk_lines :: proc(lines: []Patch_Line, hunk: Patch_Hunk) -> []Patch_Line {
	return lines[hunk.first_line:][:hunk.line_count]
}

@(private = "file", require_results)
patch_only_adds :: proc(lines: []Patch_Line, hunks: []Patch_Hunk) -> bool {
	for hunk in hunks {
		for line in patch_hunk_lines(lines, hunk) {
			if line.kind != .Added { return false }
		}
	}
	return true
}

// patch_update applies hunks to a file's text. Each hunk is placed on its own, then the
// placements are applied in file order, so hunks may arrive in any order but may not overlap.
// Unchanged lines keep the file's own bytes, and added lines take the file's line ending.
@(private = "file", require_results)
patch_update :: proc(
	path_argument, original: string,
	lines: []Patch_Line,
	hunks: []Patch_Hunk,
	allocator: mem.Allocator,
) -> (
	updated: []u8,
	repaired_hunks: int,
	err: Patch_Error,
) {
	file_lines := patch_split_lines(original, allocator) or_return
	placements := make([]Patch_Placement, len(hunks), allocator) or_return
	cursor := 0
	for hunk, index in hunks {
		repaired: bool
		placements[index], repaired = patch_place(path_argument, index, file_lines, patch_hunk_lines(lines, hunk), hunk, cursor, allocator) or_return
		if repaired { repaired_hunks += 1 }
		cursor = placements[index].start + placements[index].removed
	}
	slice.stable_sort_by(placements, proc(left, right: Patch_Placement) -> bool { return left.start < right.start })
	for index in 1 ..< len(placements) {
		previous, current := placements[index - 1], placements[index]
		if current.start < previous.start + previous.removed {
			return nil, 0, patch_failure(
				.Overlap,
				allocator,
				"hunks %d and %d of %s change the same lines",
				previous.hunk + 1,
				current.hunk + 1,
				path_argument,
			)
		}
	}

	line_ending := "\r\n" if len(file_lines) > 0 && strings.has_suffix(file_lines[0], "\r") else "\n"
	buffer := make([dynamic]u8, 0, len(original) + len(lines), allocator) or_return
	copied := 0
	for placement in placements {
		for line in file_lines[copied:placement.start] { patch_append(&buffer, line, "\n") or_return }
		hunk_lines := patch_hunk_lines(lines, hunks[placement.hunk])
		reference_file, reference_patch := patch_first_reference(file_lines[placement.start:], hunk_lines)
		matched := placement.start
		for line in hunk_lines {
			if line.kind != .Added && strings.trim_space(line.text) != "" { reference_file, reference_patch = file_lines[matched], line.text }
			switch line.kind {
			case .Context:
				patch_append(&buffer, file_lines[matched], "\n") or_return
				matched += 1
			case .Removed:
				matched += 1
			case .Added:
				indent, text := "", line.text
				if placement.reindent { indent, text = patch_reindent(line.text, reference_file, reference_patch) }
				patch_append(&buffer, indent, text, line_ending) or_return
			}
		}
		copied = matched
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
@(private = "file", require_results)
patch_split_lines :: proc(text: string, allocator: mem.Allocator) -> (lines: []string, err: mem.Allocator_Error) {
	if text == "" { return nil, nil }
	lines = strings.split(strings.trim_suffix(text, "\n"), "\n", allocator) or_return
	return
}

// patch_place finds where one hunk applies. At each match level, from strictest to loosest, the
// file lines matching the hunk's old lines are candidates, and each hint narrows them when it
// leaves at least one: the previous hunk's end, the anchor, End of File, and a unified diff's line
// number. The hunk applies only where exactly one candidate remains. A hunk with only added lines
// goes after its anchor, at its line number, or at the end of the file.
@(private = "file", require_results)
patch_place :: proc(
	path_argument: string,
	hunk_index: int,
	file_lines: []string,
	hunk_lines: []Patch_Line,
	hunk: Patch_Hunk,
	cursor: int,
	allocator: mem.Allocator,
) -> (
	placement: Patch_Placement,
	repaired: bool,
	err: Patch_Error,
) {
	placement.hunk = hunk_index
	expected := patch_side(hunk_lines, .Added, allocator) or_return
	anchor, anchor_found := patch_find_anchor(file_lines, hunk.anchor, cursor)
	if len(expected) == 0 {
		switch {
		case anchor_found:
			placement.start = anchor + 1
		case hunk.anchor != "":
			return {}, false, patch_failure(.Not_Found, allocator, "hunk %d of %s adds lines after %q, which is not in the file", hunk_index + 1, path_argument, hunk.anchor)
		case hunk.line_hint > 0:
			placement.start = min(hunk.line_hint, len(file_lines))
		case:
			placement.start = len(file_lines)
		}
		return
	}

	last_start := len(file_lines) - len(expected)
	for level in Patch_Match_Level {
		candidates := patch_matches(file_lines, expected, level, allocator) or_return
		if len(candidates) == 0 { continue }
		candidates = patch_narrow(candidates, cursor, last_start)
		if anchor_found { candidates = patch_narrow(candidates, anchor + 1, last_start) }
		if hunk.at_end { candidates = patch_narrow(candidates, last_start, last_start) }
		if hunk.line_hint > 0 { candidates = patch_narrow(candidates, hunk.line_hint - 1, hunk.line_hint - 1) }
		if len(candidates) > 1 {
			for &start in candidates { start += 1 }
			return {}, false, patch_failure(.Ambiguous, allocator, "hunk %d of %s matches %d places, at lines %v; add unchanged lines around the change so it matches one place", hunk_index + 1, path_argument, len(candidates), candidates)
		}
		placement.start = candidates[0]
		placement.removed = len(expected)
		placement.reindent = level == .Surrounding_Space
		return placement, level != .Exact, nil
	}
	return {}, false, patch_not_found(path_argument, hunk_index, file_lines, hunk_lines, expected, allocator)
}

// patch_side is the text of a hunk's lines that are not of the excluded kind: excluding Added
// gives the lines the file holds now, and excluding Removed the lines it will hold.
@(private = "file", require_results)
patch_side :: proc(hunk_lines: []Patch_Line, excluded: Patch_Line_Kind, allocator: mem.Allocator) -> (side: []string, err: mem.Allocator_Error) {
	buffer := make([dynamic]string, 0, len(hunk_lines), allocator) or_return
	for line in hunk_lines {
		if line.kind != excluded { append(&buffer, line.text) or_return }
	}
	return buffer[:], nil
}

@(private = "file", require_results)
patch_matches :: proc(file_lines, expected: []string, level: Patch_Match_Level, allocator: mem.Allocator) -> (starts: []int, err: mem.Allocator_Error) {
	buffer := make([dynamic]int, allocator) or_return
	for start in 0 ..= len(file_lines) - len(expected) {
		if patch_lines_match(file_lines[start:], expected, level) { append(&buffer, start) or_return }
	}
	return buffer[:], nil
}

@(private = "file", require_results)
patch_lines_match :: proc(file_lines, expected: []string, level: Patch_Match_Level) -> bool {
	for text, index in expected {
		if !patch_line_matches(file_lines[index], text, level) { return false }
	}
	return true
}

@(private = "file", require_results)
patch_line_matches :: proc(file_line, text: string, level: Patch_Match_Level) -> bool {
	file_text := strings.trim_suffix(file_line, "\r")
	switch level {
	case .Exact:
		return file_text == text
	case .Trailing_Space:
		return strings.trim_right_space(file_text) == strings.trim_right_space(text)
	case .Surrounding_Space:
		return strings.trim_space(file_text) == strings.trim_space(text)
	}
	return false
}

// patch_narrow keeps the candidates between lowest and highest, unless that would keep none.
@(private = "file")
patch_narrow :: proc(candidates: []int, lowest, highest: int) -> []int {
	kept := 0
	for start in candidates {
		if start >= lowest && start <= highest { kept += 1 }
	}
	if kept == 0 { return candidates }
	kept = 0
	for start in candidates {
		if start < lowest || start > highest { continue }
		candidates[kept] = start
		kept += 1
	}
	return candidates[:kept]
}

// patch_find_anchor finds the line an @@ names: a whole line before a line that contains it, and
// from the cursor before the start of the file.
@(private = "file", require_results)
patch_find_anchor :: proc(file_lines: []string, anchor: string, cursor: int) -> (index: int, found: bool) {
	if anchor == "" { return }
	for whole_line in ([?]bool{true, false}) {
		for from in ([?]int{cursor, 0}) {
			for line, offset in file_lines[from:] {
				text := strings.trim_space(line)
				if text == anchor || !whole_line && strings.contains(text, anchor) { return from + offset, true }
			}
		}
	}
	return
}

// patch_first_reference is the first old line of a hunk that is not blank, as the file holds it
// and as the patch wrote it. Added lines above every other old line are reindented against it.
@(private = "file")
patch_first_reference :: proc(file_lines: []string, hunk_lines: []Patch_Line) -> (file_line, patch_text: string) {
	matched := 0
	for line in hunk_lines {
		if line.kind == .Added { continue }
		if strings.trim_space(line.text) != "" { return file_lines[matched], line.text }
		matched += 1
	}
	return
}

// patch_reindent moves an added line from the patch's indentation to the file's: the indentation
// the patch gave the reference line is replaced by the one the file gives it. A line indented
// differently from the reference is left as written.
@(private = "file")
patch_reindent :: proc(text, reference_file, reference_patch: string) -> (indent, rest: string) {
	patch_indent := patch_indentation(reference_patch)
	if !strings.has_prefix(text, patch_indent) { return "", text }
	return patch_indentation(strings.trim_suffix(reference_file, "\r")), text[len(patch_indent):]
}

@(private = "file")
patch_indentation :: proc(text: string) -> string {
	return text[:len(text) - len(strings.trim_left_space(text))]
}

// patch_not_found describes why a hunk matched nowhere: its new lines are already in the file,
// or where the longest run of its leading lines matches and the first line there that differs.
@(private = "file", require_results)
patch_not_found :: proc(
	path_argument: string,
	hunk_index: int,
	file_lines: []string,
	hunk_lines: []Patch_Line,
	expected: []string,
	allocator: mem.Allocator,
) -> Patch_Error {
	result := patch_side(hunk_lines, .Removed, allocator) or_return
	if len(result) > 0 {
		applied := patch_matches(file_lines, result, .Surrounding_Space, allocator) or_return
		if len(applied) > 0 {
			return patch_failure(
				.Not_Found,
				allocator,
				"hunk %d of %s does not match, but its new lines are already at line %d; the change may already be applied",
				hunk_index + 1,
				path_argument,
				applied[0] + 1,
			)
		}
	}

	best_start, best_count := 0, 0
	for start in 0 ..< len(file_lines) {
		count := 0
		for count < len(expected) &&
		    start + count < len(file_lines) &&
		    patch_line_matches(file_lines[start + count], expected[count], .Surrounding_Space) { count += 1 }
		if count > best_count { best_start, best_count = start, count }
	}
	differing := best_start + best_count
	switch {
	case best_count == 0:
		return patch_failure(
			.Not_Found,
			allocator,
			"hunk %d of %s: no line in the file reads %q, the hunk's first line",
			hunk_index + 1,
			path_argument,
			expected[0],
		)
	case differing == len(file_lines):
		return patch_failure(
			.Not_Found,
			allocator,
			"hunk %d of %s: the file ends where the hunk expects %q; the hunk's earlier lines match from line %d",
			hunk_index + 1,
			path_argument,
			expected[best_count],
			best_start + 1,
		)
	}
	return patch_failure(
		.Not_Found,
		allocator,
		"hunk %d of %s: line %d reads %q where the hunk expects %q; the hunk's earlier lines match from line %d",
		hunk_index + 1,
		path_argument,
		differing + 1,
		strings.trim_suffix(file_lines[differing], "\r"),
		expected[best_count],
		best_start + 1,
	)
}
