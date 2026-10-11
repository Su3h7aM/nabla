package search

import "core:bytes"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Ignore_Rule is one parsed .gitignore line. pattern is '/'-separated, holds
// no empty segment, and has its leading '!', leading '/', and trailing '/'
// removed. A pattern with a slash anywhere else is anchored and matches the
// path below the set's directory; one without matches the final name at any
// depth.
@(private)
Ignore_Rule :: struct {
	pattern:        string, // borrowed from the set's text
	negated:        bool,
	directory_only: bool,
	anchored:       bool,
}

// Ignore_Set is the rules of one ignore file, whose patterns are relative to
// directory. text owns the bytes the rules' patterns view. The set owns text
// and rules, both allocated with rules.allocator. directory is borrowed and
// must outlive the set. The zero set matches nothing and destroying it is a
// no-op.
@(private)
Ignore_Set :: struct {
	directory: string, // absolute
	text:      []u8,
	rules:     [dynamic]Ignore_Rule,
}

// Ignore_Files names which of a directory's entries feed the ignore rules.
@(private)
Ignore_Files :: struct {
	repository:    bool, // .git or .jj exists, whatever its type
	git_directory: bool, // .git is a directory, so .git/info/exclude may exist
	gitignore:     bool, // .gitignore is a regular file
}

// ignore_scan reads which ignore-relevant entries entries holds.
@(private, require_results)
ignore_scan :: proc(entries: []os.File_Info) -> (files: Ignore_Files) {
	for info in entries {
		switch info.name {
		case ".git":
			files.repository = true
			files.git_directory = info.type == .Directory
		case ".jj":
			files.repository = true
		case ".gitignore":
			files.gitignore = info.type == .Regular
		}
	}
	return files
}

// ignore_set_make parses text, the bytes of an ignore file, into a set for
// directory. It takes ownership of text, also on failure, and rewrites it in
// place. Blank lines, comments, and malformed patterns yield no rule.
@(private, require_results)
ignore_set_make :: proc(directory: string, text: []u8, allocator: mem.Allocator) -> (set: Ignore_Set, err: mem.Allocator_Error) {
	rules, make_error := make([dynamic]Ignore_Rule, allocator)
	if make_error != nil {
		delete(text, allocator)
		return {}, make_error
	}
	set = Ignore_Set {
		directory = directory,
		text      = text,
		rules     = rules,
	}
	defer if err != nil {
		ignore_set_destroy(&set)
	}
	rest := text
	for len(rest) > 0 {
		line := rest
		if end := bytes.index_byte(rest, '\n'); end >= 0 {
			line, rest = rest[:end], rest[end + 1:]
		} else {
			rest = nil
		}
		if rule, ok := ignore_rule_parse(line); ok {
			append(&set.rules, rule) or_return
		}
	}
	return set, nil
}

@(private)
ignore_set_destroy :: proc(set: ^Ignore_Set) {
	delete(set.text, set.rules.allocator)
	delete(set.rules)
	set^ = {}
}

// ignore_rule_parse reads one line of an ignore file. ok is false for a blank
// line, a comment, and a pattern no matcher can read. It rewrites the classes
// of line in place and the rule's pattern views line.
@(private, require_results)
ignore_rule_parse :: proc(line: []u8) -> (rule: Ignore_Rule, ok: bool) {
	line := line
	if len(line) > 0 && line[len(line) - 1] == '\r' {
		line = line[:len(line) - 1]
	}
	// A space is part of the pattern only when a backslash escapes it.
	for len(line) > 0 && line[len(line) - 1] == ' ' && !(len(line) > 1 && line[len(line) - 2] == '\\') {
		line = line[:len(line) - 1]
	}
	if len(line) == 0 || line[0] == '#' {
		return {}, false
	}
	if line[0] == '!' {
		rule.negated = true
		line = line[1:]
	}
	if len(line) > 0 && line[len(line) - 1] == '/' {
		rule.directory_only = true
		line = line[:len(line) - 1]
	}
	rule.anchored = bytes.index_byte(line, '/') >= 0
	if len(line) > 0 && line[0] == '/' {
		line = line[1:]
	}
	if len(line) == 0 {
		return {}, false
	}
	ignore_classes_rewrite(line)
	rule.pattern = string(line)
	segments := rule.pattern
	for segment in strings.split_iterator(&segments, "/") {
		if segment == "" || !glob_valid(segment) {
			return {}, false
		}
	}
	return rule, true
}

// ignore_classes_rewrite changes each class that opens with "[!" in pattern to
// open with "[^", the negation filepath.match reads. Escaped brackets and the
// insides of classes are left alone. A malformed class ends the rewrite;
// glob_valid rejects the segment holding it.
@(private)
ignore_classes_rewrite :: proc(pattern: []u8) {
	at := 0
	for at < len(pattern) {
		switch pattern[at] {
		case '\\':
			at += 2
		case '[':
			if at + 1 < len(pattern) && pattern[at + 1] == '!' {
				pattern[at + 1] = '^'
			}
			rest, ok := glob_class_rest(string(pattern[at + 1:]))
			if !ok {
				return
			}
			at = len(pattern) - len(rest)
		case:
			at += 1
		}
	}
}

// ignore_matches reports whether path, an absolute path below every set's
// directory, is ignored. is_dir tells a directory from a file. The innermost
// set with a matching rule decides, and inside a set the last matching rule
// wins, so a negated rule re-includes.
@(private, require_results)
ignore_matches :: proc(sets: []Ignore_Set, path: string, is_dir: bool) -> bool {
	#reverse for set in sets {
		relative := strings.trim_prefix(strings.trim_prefix(path, set.directory), "/")
		name := relative[strings.last_index_byte(relative, '/') + 1:]
		#reverse for rule in set.rules {
			if ignore_rule_matches(rule, relative, name, is_dir) {
				return !rule.negated
			}
		}
	}
	return false
}

// ignore_rule_matches reports whether rule matches relative, a path below
// the rule's directory, whose final segment is name.
@(private, require_results)
ignore_rule_matches :: proc(rule: Ignore_Rule, relative, name: string, is_dir: bool) -> bool {
	if rule.directory_only && !is_dir {
		return false
	}
	if !rule.anchored {
		return ignore_glob_match(rule.pattern, name)
	}
	return ignore_segments_match(rule.pattern, relative)
}

// ignore_segments_match reports whether the '/'-separated path matches the
// '/'-separated pattern, segment by segment. A "**" segment matches zero or
// more segments, except a trailing one, which needs at least one. Every other
// segment is a filepath.match glob and never crosses a '/'.
@(private, require_results)
ignore_segments_match :: proc(pattern, path: string) -> bool {
	if pattern == "" {
		return path == ""
	}
	head, _, pattern_rest := strings.partition(pattern, "/")
	if head == "**" {
		if pattern_rest == "" {
			return path != ""
		}
		rest := path
		for {
			if ignore_segments_match(pattern_rest, rest) {
				return true
			}
			if rest == "" {
				return false
			}
			_, _, rest = strings.partition(rest, "/")
		}
	}
	if path == "" {
		return false
	}
	name, _, path_rest := strings.partition(path, "/")
	return ignore_glob_match(head, name) && ignore_segments_match(pattern_rest, path_rest)
}

// ignore_glob_match reports whether name, one path segment, matches the
// one-segment glob pattern. The two shapes that make up most ignore files, a
// plain name and a star followed by a plain suffix, skip filepath.match,
// which costs several times as much; both agree with it on a name without a
// '/'.
@(private, require_results)
ignore_glob_match :: proc(pattern, name: string) -> bool {
	if !glob_has_meta(pattern) {
		return pattern == name
	}
	if pattern[0] == '*' && !glob_has_meta(pattern[1:]) {
		return strings.has_suffix(name, pattern[1:])
	}
	hit, match_error := filepath.match(pattern, name)
	return match_error == nil && hit
}

@(private, require_results)
glob_has_meta :: proc(glob: string) -> bool {
	for char in transmute([]u8)glob {
		switch char {
		case '*', '?', '[', '\\':
			return true
		}
	}
	return false
}

// ignore_ancestors pushes onto stack the sets of the nearest directory at or
// above directory that holds a repository marker, and of every directory
// between it and directory, outermost first. found reports whether such a
// repository exists; if it does not, nothing is pushed. A directory is
// borrowed for the life of the sets.
@(private)
ignore_ancestors :: proc(stack: ^[dynamic]Ignore_Set, directory: string, allocator: mem.Allocator) -> (found: bool, err: mem.Allocator_Error) {
	for name in ([?]string{".git", ".jj"}) {
		path := strings.concatenate({directory, "/", name}, allocator) or_return
		defer delete(path, allocator)
		found ||= os.exists(path)
	}
	if !found && directory != "/" {
		found = ignore_ancestors(stack, parent_directory(directory), allocator) or_return
	}
	if found {
		_ = ignore_push(stack, directory, {git_directory = true, gitignore = true}, allocator) or_return
	}
	return found, nil
}

// parent_directory returns the absolute directory holding path, or "/" for a
// top-level path. path is borrowed and the result views it.
@(private, require_results)
parent_directory :: proc(path: string) -> string {
	last := strings.last_index_byte(path, '/')
	if last <= 0 {
		return "/"
	}
	return path[:last]
}

// ignore_push reads the ignore files files names in directory and pushes a
// set for each that holds a rule: .git/info/exclude first, so .gitignore sits
// above it and wins. A file that is missing or unreadable adds no set. pushed
// is how many sets were added, also when err is set; the caller pops them
// with ignore_pop. directory is borrowed for the life of the sets.
@(private)
ignore_push :: proc(stack: ^[dynamic]Ignore_Set, directory: string, files: Ignore_Files, allocator: mem.Allocator) -> (pushed: int, err: mem.Allocator_Error) {
	if files.git_directory {
		pushed += ignore_push_file(stack, directory, ".git/info/exclude", allocator) or_return
	}
	if files.gitignore {
		pushed += ignore_push_file(stack, directory, ".gitignore", allocator) or_return
	}
	return pushed, nil
}

@(private)
ignore_push_file :: proc(stack: ^[dynamic]Ignore_Set, directory, name: string, allocator: mem.Allocator) -> (pushed: int, err: mem.Allocator_Error) {
	path := strings.concatenate({directory, "/", name}, allocator) or_return
	defer delete(path, allocator)
	text, read_error := os.read_entire_file(path, allocator)
	if read_error != nil {
		delete(text, allocator)
		alloc_error, _ := read_error.(mem.Allocator_Error)
		return 0, alloc_error
	}
	set := ignore_set_make(directory, text, allocator) or_return
	if len(set.rules) == 0 {
		ignore_set_destroy(&set)
		return 0, nil
	}
	if _, append_error := append(stack, set); append_error != nil {
		ignore_set_destroy(&set)
		return 0, append_error
	}
	return 1, nil
}

// ignore_pop removes the last count sets from stack and destroys them.
@(private)
ignore_pop :: proc(stack: ^[dynamic]Ignore_Set, count: int) {
	for _ in 0 ..< count {
		set := pop(stack)
		ignore_set_destroy(&set)
	}
}
