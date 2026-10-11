package search

import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"

// GENERATION_FIRST is the generation a fresh index carries. Cursors name the
// generation they were issued at, so an updated index refuses them as stale.
GENERATION_FIRST :: 1

// DENY_DIRS names directories a scan never descends into.
DENY_DIRS := [?]string{"node_modules", "target", "__pycache__"}

// SNIFF_LEN is how many leading bytes of a file are sniffed once for NUL
// before any match work. A NUL past this block keeps the text behavior.
SNIFF_LEN :: 4 * 1024

// CHUNK_LEN is the fixed read size a grep worker streams a file with, so a
// worker holds chunk buffers instead of the whole file.
CHUNK_LEN :: 64 * 1024

// APPROX_CAP bounds only the typo-tolerant fallback rows shown when exact
// search finds nothing: both fallbacks retain through a streaming top-K of
// this size, so the recovery never exceeds one page. The same bound covers
// the grep fallback. Exact results are never capped.
APPROX_CAP :: 50

// Skip_Breakdown counts what one scan or query did not search, by cause.
// binary, oversize, and unreadable count files; denylist counts the
// directories the denylist pruned at scan time, never files, so it is
// reported beside the file total rather than inside it. The zero value
// searched everything.
Skip_Breakdown :: struct {
	binary:     int, // files skipped holding a NUL byte in the sniff window
	oversize:   int, // files skipped past GREP_MAX_FILE_SIZE
	unreadable: int, // files that could not be opened or read
	denylist:   int, // directories pruned by DENY_DIRS
}

// skip_files_total counts the files a breakdown skipped. Pruned directories
// are reported beside the total, never inside it.
@(require_results)
skip_files_total :: proc(skipped: Skip_Breakdown) -> int {
	return skipped.binary + skipped.oversize + skipped.unreadable
}

// Error_Code names the failures a core:os error cannot already say: a path
// that is not a directory, a glob no matcher can read, and a cursor that is
// malformed, from another root, or older than the index.
Error_Code :: enum {
	Not_Directory,
	Invalid_Glob,
	Invalid_Cursor,
	Stale_Cursor,
}

// Error is every failure a search call returns. The os.Error member carries
// what the filesystem reported; Error_Code carries the shapes only this
// package can name. An allocation failure arrives as the allocator error.
Error :: union #shared_nil {
	Error_Code,
	mem.Allocator_Error,
	os.Error,
}

// error_message describes err in one static line. It allocates nothing and
// the text is valid for the life of the process.
error_message :: proc(err: Error) -> string {
	switch value in err {
	case Error_Code:
		switch value {
		case .Not_Directory:
			return "the search root is not a directory"
		case .Invalid_Glob:
			return "the glob is not a valid shell pattern"
		case .Invalid_Cursor:
			return "the cursor is malformed or from another root"
		case .Stale_Cursor:
			return "the cursor is older than the index; query again without it"
		}
	case mem.Allocator_Error:
		return "out of memory"
	case os.Error:
		return "a filesystem call failed"
	}
	return "unknown error"
}

@(private)
Parallel_For :: struct {
	next:      int, // the next index to claim, advanced atomically
	count:     int,
	data:      rawptr,
	procedure: proc(data: rawptr, index: int),
}

// parallel_for calls procedure(data, index) once for every index in
// [0, count), spread over at most thread_count threads, and returns when all
// calls have returned and every worker thread has exited. The calling thread
// is one of the workers, so the work completes even when no thread can be
// started, and a thread_count at or below one runs everything on the caller.
// Workers claim indexes one at a time, so uneven calls balance themselves.
// Calls run concurrently: procedure must only touch data that is read-only or
// owned by its own index. A call allocates only with an allocator it names,
// never context.temp_allocator, which would build a temp arena on every
// worker thread. The thread records are allocated and freed here, on the
// calling thread, with its allocator.
@(private)
parallel_for :: proc(count, thread_count: int, data: rawptr, procedure: proc(data: rawptr, index: int)) {
	state := Parallel_For {
		count     = count,
		data      = data,
		procedure = procedure,
	}
	workers := max(min(thread_count, count) - 1, 0)
	threads, make_error := make([dynamic]^thread.Thread, 0, workers)
	if make_error != nil {
		workers = 0
	}
	defer delete(threads)
	for _ in 0 ..< workers {
		worker := thread.create_and_start_with_data(&state, parallel_for_thread)
		if worker == nil {
			break
		}
		append(&threads, worker)
	}
	parallel_for_run(&state)
	thread.join_multiple(..threads[:])
	for worker in threads {
		thread.destroy(worker)
	}
}

@(private)
parallel_for_thread :: proc(data: rawptr) {
	parallel_for_run(cast(^Parallel_For)data)
}

@(private)
parallel_for_run :: proc(state: ^Parallel_For) {
	for {
		index := sync.atomic_add(&state.next, 1)
		if index >= state.count {
			return
		}
		state.procedure(state.data, index)
	}
}
