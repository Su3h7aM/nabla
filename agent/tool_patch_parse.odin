package agent

import "core:fmt"
import "core:mem"
import "core:strings"

PATCH_BEGIN :: "*** Begin Patch"
PATCH_END :: "*** End Patch"
PATCH_MOVE :: "*** Move to:"
PATCH_END_OF_FILE :: "*** End of File"
PATCH_HUNK :: "@@"

@(rodata, private)
PATCH_HEADERS := [Patch_Operation]string {
	.Add    = "*** Add File:",
	.Delete = "*** Delete File:",
	.Update = "*** Update File:",
}

Patch_Operation :: enum u8 {
	Add,
	Delete,
	Update,
}

Patch_Line_Kind :: enum u8 {
	Context,
	Removed,
	Added,
}

Patch_Line :: struct {
	kind: Patch_Line_Kind,
	text: string,
}

// Patch_Hunk is one block of changes: lines[first_line:][:line_count] of its patch. anchor and
// line_hint come from its @@ line and only narrow where the hunk may apply.
Patch_Hunk :: struct {
	anchor:     string,
	line_hint:  int,
	at_end:     bool,
	first_line: int,
	line_count: int,
}

// Patch_File is one file section: hunks[first_hunk:][:hunk_count] of its patch. An added file
// has one hunk of added lines, and a deleted file has none.
Patch_File :: struct {
	operation:  Patch_Operation,
	path:       string,
	move_to:    string,
	first_hunk: int,
	hunk_count: int,
}

@(private)
Patch_Parser :: struct {
	files:     [dynamic]Patch_File,
	hunks:     [dynamic]Patch_Hunk,
	lines:     [dynamic]Patch_Line,
	section:   bool,
	hunk_open: bool,
}

patch_args_destroy :: proc(args: ^Patch_Args, allocator: mem.Allocator) {
	delete(args.files, allocator)
	delete(args.hunks, allocator)
	delete(args.lines, allocator)
	args^ = {}
}

// patch_parse reads a patch in the Begin Patch format or as a unified diff. It accepts every
// form that has one reading: missing envelope lines, text around the patch, context lines
// without their leading space, and added files without `+` prefixes. Strings borrow patch, and
// the arrays are owned by allocator. problem names what has no single reading, is "" for a
// patch that parsed, and is allocated in the temp allocator.
patch_parse :: proc(patch: string, allocator: mem.Allocator) -> (args: Patch_Args, problem: string, err: mem.Allocator_Error) {
	parser: Patch_Parser
	defer if problem != "" || err != nil {
		delete(parser.files)
		delete(parser.hunks)
		delete(parser.lines)
		args = {}
	}
	parser.files = make([dynamic]Patch_File, allocator) or_return
	parser.hunks = make([dynamic]Patch_Hunk, allocator) or_return
	parser.lines = make([dynamic]Patch_Line, allocator) or_return

	raw_lines := strings.split_lines(patch, allocator) or_return
	defer delete(raw_lines, allocator)
	for index := 0; index < len(raw_lines); index += 1 {
		line := strings.trim_suffix(raw_lines[index], "\r")
		marker := strings.trim_right_space(line)
		if strings.equal_fold(marker, PATCH_END) || patch_is_wrapper_end(raw_lines[index:]) { break }
		if strings.equal_fold(marker, PATCH_BEGIN) { continue }
		if operation, path, is_header := patch_header(line); is_header {
			if problem = patch_open_section(&parser, operation, path, "", index + 1) or_return; problem != "" { break }
			continue
		}
		if operation, path, move_to, is_header := patch_unified_header(raw_lines[index:], parser.section); is_header {
			if problem = patch_open_section(&parser, operation, path, move_to, index + 1) or_return; problem != "" { break }
			index += 1
			continue
		}
		if !parser.section { continue }
		if strings.has_prefix(line, "diff --git ") {
			if problem = patch_close_section(&parser); problem != "" { break }
			continue
		}
		if problem = patch_section_line(&parser, line, index + 1) or_return; problem != "" { break }
	}
	if problem == "" { problem = patch_close_section(&parser) }
	if problem == "" && len(parser.files) == 0 { problem = "a patch with at least one *** Add File:, *** Delete File:, or *** Update File: header" }
	args = {parser.files[:], parser.hunks[:], parser.lines[:]}
	return
}

// patch_is_wrapper_end reports whether lines start with a closing code fence or heredoc
// terminator followed only by blank lines, which ends a patch that lacks *** End Patch.
@(private = "file")
patch_is_wrapper_end :: proc(lines: []string) -> bool {
	first := strings.trim_space(lines[0])
	if !strings.has_prefix(first, "```") && first != "EOF" { return false }
	for line in lines[1:] {
		if strings.trim_space(line) != "" { return false }
	}
	return true
}

@(private = "file")
patch_header :: proc(line: string) -> (operation: Patch_Operation, path: string, is_header: bool) {
	for marker, candidate in PATCH_HEADERS {
		if rest, found := patch_marker(line, marker); found { return candidate, patch_clean_path(rest), true }
	}
	return
}

// patch_marker matches a marker at the start of a line in any letter case.
@(private = "file")
patch_marker :: proc(line, marker: string) -> (rest: string, found: bool) {
	if len(line) < len(marker) || !strings.equal_fold(line[:len(marker)], marker) { return }
	return line[len(marker):], true
}

@(private = "file")
patch_clean_path :: proc(text: string) -> string {
	path := strings.trim_space(text)
	for quote in ([?]string{"\"", "'", "`"}) {
		if len(path) >= 2 && strings.has_prefix(path, quote) && strings.has_suffix(path, quote) { return path[1:len(path) - 1] }
	}
	return path
}

// patch_unified_header reads a `--- old` and `+++ new` pair. Inside a section the pair must be
// followed by an @@ line, because there it could also be a removed and an added line.
@(private = "file")
patch_unified_header :: proc(lines: []string, in_section: bool) -> (operation: Patch_Operation, path, move_to: string, is_header: bool) {
	if len(lines) < 2 { return }
	old_line := strings.trim_suffix(lines[0], "\r")
	new_line := strings.trim_suffix(lines[1], "\r")
	if !strings.has_prefix(old_line, "--- ") || !strings.has_prefix(new_line, "+++ ") { return }
	if in_section && (len(lines) < 3 || !strings.has_prefix(lines[2], PATCH_HUNK)) { return }

	old_path := patch_unified_path(old_line[len("--- "):])
	new_path := patch_unified_path(new_line[len("+++ "):])
	if (strings.has_prefix(old_path, "a/") || old_path == "/dev/null") && (strings.has_prefix(new_path, "b/") || new_path == "/dev/null") {
		old_path = strings.trim_prefix(old_path, "a/")
		new_path = strings.trim_prefix(new_path, "b/")
	}
	switch {
	case old_path == "/dev/null":
		return .Add, new_path, "", true
	case new_path == "/dev/null":
		return .Delete, old_path, "", true
	case new_path != old_path:
		return .Update, old_path, new_path, true
	}
	return .Update, old_path, "", true
}

// patch_unified_path drops the timestamp a diff tool may write after a tab.
@(private = "file")
patch_unified_path :: proc(text: string) -> string {
	path := text
	if tab := strings.index_byte(path, '\t'); tab >= 0 { path = path[:tab] }
	return patch_clean_path(path)
}

@(private = "file")
patch_open_section :: proc(
	parser: ^Patch_Parser,
	operation: Patch_Operation,
	path, move_to: string,
	line_number: int,
) -> (
	problem: string,
	err: mem.Allocator_Error,
) {
	if problem = patch_close_section(parser); problem != "" { return }
	if path == "" { return fmt.tprintf("a patch whose line %d names a file", line_number), nil }
	append(&parser.files, Patch_File{operation = operation, path = path, move_to = move_to, first_hunk = len(parser.hunks)}) or_return
	parser.section = true
	parser.hunk_open = false
	return
}

@(private = "file")
patch_open_hunk :: proc(parser: ^Patch_Parser, anchor: string, line_hint: int) -> mem.Allocator_Error {
	append(&parser.hunks, Patch_Hunk{anchor = anchor, line_hint = line_hint, first_line = len(parser.lines)}) or_return
	parser.hunk_open = true
	return nil
}

@(private = "file")
patch_add_line :: proc(parser: ^Patch_Parser, line: Patch_Line) -> mem.Allocator_Error {
	if !parser.hunk_open { patch_open_hunk(parser, "", 0) or_return }
	append(&parser.lines, line) or_return
	parser.hunks[len(parser.hunks) - 1].line_count += 1
	return nil
}

@(private = "file")
patch_section_line :: proc(parser: ^Patch_Parser, line: string, line_number: int) -> (problem: string, err: mem.Allocator_Error) {
	file := &parser.files[len(parser.files) - 1]
	if rest, is_move := patch_marker(line, PATCH_MOVE); is_move {
		if file.operation != .Update || len(parser.hunks) > file.first_hunk {
			return fmt.tprintf("a patch whose line %d, %s, comes right after %s", line_number, PATCH_MOVE, PATCH_HEADERS[.Update]), nil
		}
		file.move_to = patch_clean_path(rest)
		return
	}
	if strings.has_prefix(line, "\\") { return }

	switch file.operation {
	case .Delete:
		if strings.trim_space(line) == "" || strings.has_prefix(line, "-") || strings.has_prefix(line, PATCH_HUNK) { return }
		return fmt.tprintf("a patch with nothing after %s%s, but line %d follows it", PATCH_HEADERS[.Delete], file.path, line_number), nil
	case .Add:
		if strings.has_prefix(line, PATCH_HUNK) { return }
		patch_add_line(parser, {.Added, line}) or_return
	case .Update:
		if strings.equal_fold(strings.trim_right_space(line), PATCH_END_OF_FILE) {
			if parser.hunk_open { parser.hunks[len(parser.hunks) - 1].at_end = true }
			parser.hunk_open = false
			return
		}
		if strings.has_prefix(line, PATCH_HUNK) {
			anchor, line_hint := patch_hunk_header(line)
			patch_open_hunk(parser, anchor, line_hint) or_return
			return
		}
		patch_add_line(parser, patch_classify(line)) or_return
	}
	return
}

// patch_hunk_header reads an @@ line: `@@ <anchor>` or a unified `@@ -12,7 +12,8 @@ <anchor>`.
@(private = "file")
patch_hunk_header :: proc(line: string) -> (anchor: string, line_hint: int) {
	rest := strings.trim_space(line[len(PATCH_HUNK):])
	if strings.has_prefix(rest, "-") {
		digits := 1
		for digits < len(rest) && rest[digits] >= '0' && rest[digits] <= '9' {
			line_hint = line_hint * 10 + int(rest[digits] - '0')
			digits += 1
		}
		if digits > 1 {
			close := strings.index(rest, PATCH_HUNK)
			rest = rest[close + len(PATCH_HUNK):] if close >= 0 else ""
		}
	}
	return strings.trim_space(strings.trim_suffix(strings.trim_space(rest), PATCH_HUNK)), line_hint
}

// patch_classify reads one hunk line. A line without a marker is an unchanged line whose
// leading space was dropped.
@(private = "file")
patch_classify :: proc(line: string) -> Patch_Line {
	if line == "" { return {.Context, ""} }
	switch line[0] {
	case '+':
		return {.Added, line[1:]}
	case '-':
		return {.Removed, line[1:]}
	case ' ':
		return {.Context, line[1:]}
	}
	return {.Context, line}
}

// patch_close_section finishes the last section. An added file drops its `+` prefixes when
// every line has one, and blank lines that trail it. An updated file drops unchanged empty lines
// that trail a hunk and hunks that change nothing, since neither can change the result.
@(private = "file")
patch_close_section :: proc(parser: ^Patch_Parser) -> (problem: string) {
	if !parser.section { return }
	parser.section = false
	parser.hunk_open = false
	file := &parser.files[len(parser.files) - 1]
	hunks := parser.hunks[file.first_hunk:]

	switch file.operation {
	case .Delete:
	case .Add:
		for &hunk in hunks {
			lines := parser.lines[hunk.first_line:][:hunk.line_count]
			prefixed := true
			for line in lines {
				if line.text != "" && !strings.has_prefix(line.text, "+") { prefixed = false }
			}
			for &line in lines {
				if prefixed { line.text = strings.trim_prefix(line.text, "+") }
			}
			for hunk.line_count > 0 && strings.trim_space(lines[hunk.line_count - 1].text) == "" { hunk.line_count -= 1 }
		}
	case .Update:
		kept := 0
		for hunk in hunks {
			trimmed := hunk
			lines := parser.lines[hunk.first_line:][:hunk.line_count]
			for trimmed.line_count > 0 {
				last := lines[trimmed.line_count - 1]
				if last.kind != .Context || last.text != "" { break }
				trimmed.line_count -= 1
			}
			if !patch_hunk_changes(parser.lines[trimmed.first_line:][:trimmed.line_count]) { continue }
			hunks[kept] = trimmed
			kept += 1
		}
		// Dropping trailing hunks never grows the array, and shrinking cannot fail.
		_ = resize(&parser.hunks, file.first_hunk + kept)
		if kept == 0 && file.move_to == "" {
			return fmt.tprintf("a patch whose %s %s section adds or removes at least one line", PATCH_HEADERS[.Update], file.path)
		}
	}
	file.hunk_count = len(parser.hunks) - file.first_hunk
	return
}

@(private = "file")
patch_hunk_changes :: proc(lines: []Patch_Line) -> bool {
	for line in lines {
		if line.kind != .Context { return true }
	}
	return false
}
