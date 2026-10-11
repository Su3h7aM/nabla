package search

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

// File is one indexed file. rel is the root-relative path, full the cached
// absolute path, size the byte length, mtime the last modification, and
// is_binary whether a NUL byte was sniffed in its leading bytes. full and rel
// are views into the index's paths buffer, and rel is the tail of full.
File :: struct {
	rel:       string,
	full:      string,
	size:      i64,
	mtime:     time.Time,
	is_binary: bool,
}

// Index is one root's file-discovery index: the absolute root key, the
// generation cursors must name, the file list sorted by rel, and the
// walk-level skips counted by cause at scan time. It owns two allocations of
// allocator: paths, which holds the root key followed by every full path, and
// files, whose strings are views into paths. A scan uses allocator only on the
// calling thread. Only a serialized caller mutates the index, with
// index_update or index_refresh_if_stale; queries borrow it and may run on any
// thread, but never concurrently with an update, so no lock is needed. The
// zero Index is inert and destroying it is a no-op.
Index :: struct {
	root:       string, // a view of the start of paths
	generation: int,
	files:      []File,
	skipped:    Skip_Breakdown,
	root_mtime: time.Time, // the root directory's mtime at the last scan
	paths:      []u8,
	allocator:  mem.Allocator,
}

// index_make scans root once and returns its index. root may be absolute or
// relative to the working directory; the index keys the absolute form. A
// root that is not an existing directory fails, as does an allocation. The
// caller owns the index and destroys it with index_destroy.
@(require_results)
index_make :: proc(root: string, allocator := context.allocator) -> (index: Index, err: Error) {
	absolute, abs_error := filepath.abs(root, allocator)
	if abs_error != nil {
		return {}, abs_error
	}
	defer delete(absolute, allocator)
	info, stat_error := os.stat(absolute, allocator)
	if stat_error != nil {
		return {}, stat_error
	}
	defer os.file_info_delete(info, allocator)
	if info.type != .Directory {
		return {}, Error(Error_Code.Not_Directory)
	}
	paths, files, skipped := walk_collect(absolute, allocator) or_return
	return Index {
			root = string(paths[:len(absolute)]),
			generation = GENERATION_FIRST,
			files = files,
			skipped = skipped,
			root_mtime = info.modification_time,
			paths = paths,
			allocator = allocator,
		},
		nil
}

// index_destroy releases the index and everything it holds. Only the owner
// calls it, once no query can still reach the index. Destroying a zero Index
// is a no-op.
index_destroy :: proc(index: ^Index) {
	if index == nil {
		return
	}
	delete(index.files, index.allocator)
	delete(index.paths, index.allocator)
	index^ = {}
}

// index_update rescans the index's root and bumps its generation, so cursors
// issued before it read as stale. A root that is no longer an existing
// directory, or a scan that cannot allocate, fails and keeps the old list and
// generation. Only the owner calls it, never concurrently with a query.
@(require_results)
index_update :: proc(index: ^Index) -> (generation: int, err: Error) {
	heap := index.allocator
	info, stat_error := os.stat(index.root, heap)
	if stat_error != nil {
		return index.generation, stat_error
	}
	defer os.file_info_delete(info, heap)
	if info.type != .Directory {
		return index.generation, Error(Error_Code.Not_Directory)
	}
	paths, files, skipped := walk_collect(index.root, heap) or_return
	root_len := len(index.root)
	delete(index.files, heap)
	delete(index.paths, heap)
	index.paths = paths
	index.root = string(paths[:root_len])
	index.files = files
	index.skipped = skipped
	index.root_mtime = info.modification_time
	index.generation += 1
	return index.generation, nil
}

// index_refresh_if_stale rescans the index when the root directory's mtime
// moved past the last scan, and returns whether a scan ran. A root that
// cannot be statted reads as fresh. The mtime only moves when a direct child
// is created, removed, or renamed, so an edit to an existing file or a change
// below the top level needs index_update. Like index_update, it must not run
// concurrently with a query.
@(require_results)
index_refresh_if_stale :: proc(index: ^Index) -> (refreshed: bool, err: Error) {
	heap := index.allocator
	info, stat_error := os.stat(index.root, heap)
	if stat_error != nil {
		return false, nil
	}
	defer os.file_info_delete(info, heap)
	if info.type != .Directory {
		return false, Error(Error_Code.Not_Directory)
	}
	if info.modification_time == index.root_mtime {
		return false, nil
	}
	_, update_error := index_update(index)
	if update_error != nil {
		return false, update_error
	}
	return true, nil
}

// sort_files orders files by rel, the page order every query shows.
@(private)
sort_files :: proc(files: []File) {
	slice.sort_by(files, proc(first, second: File) -> bool { return first.rel < second.rel })
}

// sniff_binary reports whether full holds a NUL byte in its first SNIFF_LEN
// bytes. An unreadable file reads as text here; the grep pass counts it as
// skipped when it cannot be read.
@(private)
sniff_binary :: proc(full: string) -> bool {
	file, open_error := os.open(full)
	if open_error != nil {
		return false
	}
	defer os.close(file)
	buffer: [SNIFF_LEN]byte
	count, read_error := os.read(file, buffer[:])
	if read_error != nil && read_error != .EOF {
		return false
	}
	return strings.index_byte(string(buffer[:max(count, 0)]), 0) >= 0
}
