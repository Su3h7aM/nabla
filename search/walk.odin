package search

import "base:runtime"

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// glob_valid reports whether glob is a shell pattern the matcher can read. An
// empty glob is valid and means no filter. The whole pattern is checked, not
// only the part a given name reaches: a character class must be closed, hold
// at least one member, and have well-formed ranges; a backslash escape must be
// followed by a character. The grammar is the one filepath.match reads.
@(require_results)
glob_valid :: proc(glob: string) -> bool {
	rest := glob
	for len(rest) > 0 {
		switch rest[0] {
		case '[':
			rest = glob_class_rest(rest[1:]) or_return
		case '\\':
			when ODIN_OS != .Windows {
				if len(rest) == 1 {
					return false
				}
				rest = rest[1:]
			}
			rest = rest[1:]
		case:
			rest = rest[1:]
		}
	}
	return true
}

// glob_class_rest returns what follows the character class that starts at
// chunk, the text after its opening bracket, and whether the class is well
// formed.
@(private, require_results)
glob_class_rest :: proc(chunk: string) -> (rest: string, ok: bool) {
	rest = chunk
	if len(rest) > 0 && rest[0] == '^' {
		rest = rest[1:]
	}
	for member := 0;; member += 1 {
		if member > 0 && len(rest) > 0 && rest[0] == ']' {
			return rest[1:], true
		}
		rest = glob_class_member(rest) or_return
		if rest[0] == '-' {
			rest = glob_class_member(rest[1:]) or_return
		}
	}
}

// glob_class_member returns what follows the one possibly escaped character
// at the start of chunk. A member cannot be empty, a dash, or a closing
// bracket, and the class cannot end with it.
@(private, require_results)
glob_class_member :: proc(chunk: string) -> (rest: string, ok: bool) {
	if len(chunk) == 0 || chunk[0] == '-' || chunk[0] == ']' {
		return "", false
	}
	rest = chunk
	when ODIN_OS != .Windows {
		if rest[0] == '\\' {
			rest = rest[1:]
			if len(rest) == 0 {
				return "", false
			}
		}
	}
	member, width := utf8.decode_rune_in_string(rest)
	if member == utf8.RUNE_ERROR && width == 1 {
		return "", false
	}
	rest = rest[width:]
	return rest, len(rest) > 0
}

// glob_keep reports whether rel passes the glob filter, tried against the
// path first and then the base name.
@(private, require_results)
glob_keep :: proc(pattern, rel: string) -> bool {
	if len(pattern) == 0 {
		return true
	}
	hit, match_error := filepath.match(pattern, rel)
	if match_error == nil && hit {
		return true
	}
	base := rel
	if pos := strings.last_index(rel, "/"); pos >= 0 {
		base = rel[pos + 1:]
	}
	hit, match_error = filepath.match(pattern, base)
	return match_error == nil && hit
}

// Walk_Entry is one file a batch found: the lengths of its path inside the
// batch's paths, which hold the entries' full paths back to back in entry
// order.
@(private)
Walk_Entry :: struct {
	full_len:  int,
	rel_len:   int, // the trailing bytes of the full path below the root
	size:      i64,
	mtime:     time.Time,
	is_binary: bool,
}

// Walk_Batch is the storage one walking thread fills: its entries, their
// paths, and its skips. Both arrays use the heap allocator, never the
// caller's, so a batch is safe to fill on any thread. The thread that fills a
// batch initializes it, and walk_collect frees it after the walk threads are
// done. A batch is not usable after an error.
@(private)
Walk_Batch :: struct {
	dir:     string, // borrowed subdirectory a job walks; empty for the root's own entries
	paths:   [dynamic]u8,
	entries: [dynamic]Walk_Entry,
	skipped: Skip_Breakdown,
	err:     mem.Allocator_Error,
}

@(private)
walk_batch_init :: proc(batch: ^Walk_Batch) -> mem.Allocator_Error {
	heap := runtime.heap_allocator()
	batch.paths = make([dynamic]u8, heap) or_return
	batch.entries = make([dynamic]Walk_Entry, heap) or_return
	return nil
}

@(private)
walk_batch_destroy :: proc(batch: ^Walk_Batch) {
	delete(batch.paths)
	delete(batch.entries)
	batch^ = {}
}

// collect_entry classifies one directory entry found under root. A regular
// file is appended to batch with its size, mtime, and binary flag; the
// returned descend reports whether a directory is worth walking. Denylisted
// directories are counted in the batch's skips and pruned; hidden
// directories, .git, symlinks, other non-regular entries, and anything the
// ignore sets ignore are dropped without a count. info and ignore are
// borrowed. On an allocation failure err is set.
@(private)
collect_entry :: proc(batch: ^Walk_Batch, info: os.File_Info, root: string, ignore: []Ignore_Set) -> (descend: bool, err: mem.Allocator_Error) {
	#partial switch info.type {
	case .Directory:
		if slice.contains(DENY_DIRS[:], info.name) {
			batch.skipped.denylist += 1
			return false, nil
		}
		return !strings.has_prefix(info.name, ".") && !ignore_matches(ignore, info.fullpath, true), nil
	case .Regular:
		if !strings.has_prefix(info.fullpath, root) {
			batch.skipped.unreadable += 1
			return false, nil
		}
		rel := strings.trim_prefix(strings.trim_prefix(info.fullpath, root), "/")
		if rel == ".git" || strings.has_prefix(rel, ".git/") {
			return false, nil
		}
		if ignore_matches(ignore, info.fullpath, false) {
			return false, nil
		}
		append(&batch.paths, info.fullpath) or_return
		entry := Walk_Entry {
			full_len  = len(info.fullpath),
			rel_len   = len(rel),
			size      = info.size,
			mtime     = info.modification_time,
			is_binary = sniff_binary(info.fullpath),
		}
		append(&batch.entries, entry) or_return
	}
	return false, nil
}

@(private)
Walk_State :: struct {
	batches:  []Walk_Batch, // the first is the root's own; each later one is a subdirectory job
	root:     string,
	ignore:   []Ignore_Set, // the sets in force at the root, outermost first; read-only while jobs run
	ignoring: bool, // whether the root is inside a repository, so deeper ignore files apply
}

@(private)
walk_job_run :: proc(data: rawptr, index: int) {
	state := cast(^Walk_State)data
	batch := &state.batches[index + 1]
	batch.err = walk_single(batch, state.root, state.ignore, state.ignoring)
}

// walk_read returns the entries of directory, allocated with allocator. A
// directory that cannot be opened or read yields no entries and readable
// false; only an allocation failure is an error.
@(private)
walk_read :: proc(directory: string, allocator: mem.Allocator) -> (entries: []os.File_Info, readable: bool, err: mem.Allocator_Error) {
	handle, open_error := os.open(directory)
	if open_error != nil {
		return nil, false, nil
	}
	defer os.close(handle)
	read_error: os.Error
	entries, read_error = os.read_directory(handle, -1, allocator)
	if alloc_error, is_alloc := read_error.(mem.Allocator_Error); is_alloc {
		return nil, false, alloc_error
	}
	return entries, read_error == nil, nil
}

// walk_collect walks root and returns every regular file sorted by rel, with
// size, mtime, and the binary flag read at scan time. Unreadable paths are
// skipped, never fatal, and counted by cause in the breakdown; pruned
// denylist directories are counted there too (see collect_entry for what
// stays silent). Files matched by .gitignore rules are left out; see
// ignore_ancestors and walk_directory for which rules apply. The root's
// subdirectories are walked in parallel, one walk_single each, into storage
// each walking thread owns; only the calling thread uses allocator, and it
// reads the ignore files at and above the root before the walk starts. paths
// holds the root followed by every full path, and each File's full and rel
// are views into it. root must be absolute and is borrowed. An allocation
// failure returns it and no files. The caller owns paths and files and frees
// both with allocator.
@(private)
walk_collect :: proc(root: string, allocator: mem.Allocator) -> (paths: []u8, files: []File, skipped: Skip_Breakdown, err: Error) {
	entries, readable := walk_read(root, allocator) or_return
	if !readable {
		skipped.unreadable += 1
	}
	defer os.file_info_slice_delete(entries, allocator)
	ignore := make([dynamic]Ignore_Set, allocator) or_return
	defer {
		ignore_pop(&ignore, len(ignore))
		delete(ignore)
	}
	root_files := ignore_scan(entries)
	ignoring := root_files.repository
	if !ignoring && root != "/" {
		ignoring = ignore_ancestors(&ignore, parent_directory(root), allocator) or_return
	}
	if ignoring {
		_ = ignore_push(&ignore, root, root_files, allocator) or_return
	}
	batches := make([dynamic]Walk_Batch, 1, allocator) or_return
	defer {
		for &batch in batches {
			walk_batch_destroy(&batch)
		}
		delete(batches)
	}
	walk_batch_init(&batches[0]) or_return
	for info in entries {
		if collect_entry(&batches[0], info, root, ignore[:]) or_return {
			append(&batches, Walk_Batch{dir = info.fullpath}) or_return
		}
	}
	state := Walk_State {
		batches  = batches[:],
		root     = root,
		ignore   = ignore[:],
		ignoring = ignoring,
	}
	parallel_for(len(batches) - 1, os.get_processor_core_count(), &state, walk_job_run)

	path_bytes := len(root)
	file_count := 0
	for batch in batches {
		if batch.err != nil {
			return nil, nil, {}, batch.err
		}
		path_bytes += len(batch.paths)
		file_count += len(batch.entries)
		skipped.binary += batch.skipped.binary
		skipped.oversize += batch.skipped.oversize
		skipped.unreadable += batch.skipped.unreadable
		skipped.denylist += batch.skipped.denylist
	}
	paths = make([]u8, path_bytes, allocator) or_return
	defer if err != nil {
		delete(paths, allocator)
		paths = nil
	}
	files = make([]File, file_count, allocator) or_return
	copy(paths, root)
	path_at := len(root)
	file_at := 0
	for batch in batches {
		batch_at := 0
		for entry in batch.entries {
			full := paths[path_at:][:entry.full_len]
			copy(full, batch.paths[batch_at:][:entry.full_len])
			files[file_at] = File {
				rel       = string(full[entry.full_len - entry.rel_len:]),
				full      = string(full),
				size      = entry.size,
				mtime     = entry.mtime,
				is_binary = entry.is_binary,
			}
			batch_at += entry.full_len
			path_at += entry.full_len
			file_at += 1
		}
	}
	sort_files(files)
	return paths, files, skipped, nil
}

// walk_single walks batch.dir single-threaded, adding every regular file
// below it to batch as classified by collect_entry against root. ignore and
// ignoring describe the root as in Walk_State; the walk keeps its own copy of
// the stack, so sets it pushes never reach another thread. A directory that
// cannot be opened is counted unreadable and the walk goes on. All paths are
// borrowed. It initializes the batch, so the batch must be fresh.
@(private)
walk_single :: proc(batch: ^Walk_Batch, root: string, ignore: []Ignore_Set, ignoring: bool) -> mem.Allocator_Error {
	walk_batch_init(batch) or_return
	stack := make([dynamic]Ignore_Set, 0, len(ignore), runtime.heap_allocator()) or_return
	defer delete(stack)
	append(&stack, ..ignore) or_return
	return walk_directory(batch, &stack, root, batch.dir, ignoring)
}

// walk_directory adds the regular files below directory to batch and
// recurses into each directory collect_entry lets through. Inside a
// repository it first pushes directory's own ignore sets onto stack and pops
// them on return, so the stack always holds the sets of the directories
// above the one being read. A repository marker in directory starts the
// rules there when the root was outside one. Allocation uses the heap
// allocator.
@(private)
walk_directory :: proc(batch: ^Walk_Batch, stack: ^[dynamic]Ignore_Set, root, directory: string, in_repository: bool) -> mem.Allocator_Error {
	heap := runtime.heap_allocator()
	entries, readable := walk_read(directory, heap) or_return
	if !readable {
		batch.skipped.unreadable += 1
	}
	defer os.file_info_slice_delete(entries, heap)
	files := ignore_scan(entries)
	ignoring := in_repository || files.repository
	pushed: int
	push_error: mem.Allocator_Error
	if ignoring {
		pushed, push_error = ignore_push(stack, directory, files, heap)
	}
	defer ignore_pop(stack, pushed)
	if push_error != nil {
		return push_error
	}
	for info in entries {
		if collect_entry(batch, info, root, stack[:]) or_return {
			walk_directory(batch, stack, root, info.fullpath, ignoring) or_return
		}
	}
	return nil
}
