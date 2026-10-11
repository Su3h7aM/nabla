package search

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:simd"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:text/regex"
import "core:unicode/utf8"

import "nabla:fuzzy"

// Grep_Mode selects how a pattern is searched. Plain, the zero value, is a
// literal search that, only when it finds zero hits, runs a labeled recovery:
// a multi-word pattern retries without its leading word, then a
// typo-tolerant pass ranks the closest lines. Regex matches a regular
// expression; an invalid one falls back to a literal search, says so in the
// notice, and never runs the typo recovery.
Grep_Mode :: enum {
	Plain,
	Regex,
}

// Grep_Case selects how a pattern folds case. Smart means case-sensitive
// only when the pattern holds an uppercase letter, otherwise Unicode
// case-insensitive. The zero value is smart case.
Grep_Case :: enum {
	Smart,
	Sensitive,
	Insensitive,
}

// Grep_Output_Mode selects per-line content rows or one row per file with at
// least one hit. The zero value is content rows.
Grep_Output_Mode :: enum {
	Content,
	Files_With_Matches,
}

// Grep_Query is one grep call. pattern is searched as its mode says; an empty
// pattern matches every line. glob keeps only paths it matches, tried against
// the path then the base name; exclude drops paths it matches the same way.
// context_lines names lines of context around each hit in Content mode and
// is ignored for Files_With_Matches. cursor resumes a previous result's
// next_cursor, or "" for the first page. limit bounds the page, where zero or
// below means every row. A non-nil frecency orders the searched files by
// access score plus modification score at now, in unix seconds, highest
// first, then by path; otherwise files go in path order. Rows inside a file
// always follow line order. All strings and the frecency borrow the caller.
Grep_Query :: struct {
	pattern:       string,
	mode:          Grep_Mode,
	sensitivity:   Grep_Case,
	glob:          string,
	exclude:       string,
	context_lines: int,
	output:        Grep_Output_Mode,
	cursor:        string,
	limit:         int,
	frecency:      ^Frecency,
	now:           i64,
}

// Grep_Match is one content row. col is the 1-based byte column, 0 for
// context lines. path and text are owned by the query's allocator.
Grep_Match :: struct {
	path:       string,
	line:       int,
	col:        int,
	text:       string,
	is_context: bool,
}

// Grep_Result is one grep result. In Content mode matches holds the page
// rows and files is empty; in Files_With_Matches mode files holds one path
// per file with a hit and matches is empty. total counts every match or
// file, not just the page. next_cursor resumes after the page, or "" when
// no rows remain. notice labels the recovery the rows are, or "" for exact
// matches. Everything is owned by the query's allocator.
Grep_Result :: struct {
	matches:     []Grep_Match,
	files:       []string,
	total:       int,
	skipped:     Skip_Breakdown,
	next_cursor: string,
	notice:      string,
}

// GREP_MAX_FILE_SIZE bounds the files one grep opens: a larger file is
// skipped as oversize and counted, never searched, never failed. The bound
// applies the model's own context window, which no single match line may
// fill: the file stays readable through read in pages, and the skip is
// reported beside the total, so no match is silently missed. The value
// follows fff's max_file_size. Find still lists oversized files by path.
GREP_MAX_FILE_SIZE :: 10 * 1024 * 1024

// APPROX_LINE_BITS splits a fuzzy hit's index into the candidate position
// above and the 1-based line number below, so a worker's top-K names a line
// without retaining its text.
@(private)
APPROX_LINE_BITS :: 32

// grep_result_destroy releases a grep result allocated with allocator.
grep_result_destroy :: proc(result: ^Grep_Result, allocator: mem.Allocator) {
	if result == nil {
		return
	}
	matches_destroy(result.matches, allocator)
	for path in result.files {
		delete(path, allocator)
	}
	delete(result.files, allocator)
	delete(result.next_cursor, allocator)
	delete(result.notice, allocator)
	result^ = Grep_Result{}
}

// matches_destroy releases the rows and the slice that holds them.
@(private)
matches_destroy :: proc(matches: []Grep_Match, allocator: mem.Allocator) {
	for match in matches {
		delete(match.path, allocator)
		delete(match.text, allocator)
	}
	delete(matches, allocator)
}

// match_clone builds one row with owned copies of path and text.
@(private, require_results)
match_clone :: proc(path, text: string, line, col: int, is_context: bool, allocator: mem.Allocator) -> (match: Grep_Match, err: mem.Allocator_Error) {
	path_copy := strings.clone(path, allocator) or_return
	text_copy, text_error := strings.clone(text, allocator)
	if text_error != nil {
		delete(path_copy, allocator)
		return {}, text_error
	}
	return Grep_Match{path = path_copy, line = line, col = col, text = text_copy, is_context = is_context}, nil
}

// Line_Reader streams a file as lines in fixed-size chunk reads. Each
// returned line excludes its newline and a carriage return before it, and is
// valid only until the next call: lines fully inside one chunk are views into
// the read buffer, while a line split across chunks, or longer than one, is
// assembled in line_buf. A trailing fragment without a newline is a line; an
// empty file yields no lines. A worker makes one reader and opens it for
// every file it searches, so the buffers are allocated once. The zero reader
// is inert.
@(private)
Line_Reader :: struct {
	file:     ^os.File,
	chunk:    []byte, // owned read buffer of CHUNK_LEN bytes
	rest:     []byte, // unread tail of chunk
	line_buf: [dynamic]byte, // owned; holds a line the chunk boundary split
	joined:   bool, // line_buf holds the line last returned
	binary:   bool, // NUL seen below SNIFF_LEN; no lines are yielded
	done:     bool, // EOF consumed
	heap:     mem.Allocator,
}

// line_reader_make allocates a reader's buffers with heap; the caller
// releases them with line_reader_destroy.
@(private, require_results)
line_reader_make :: proc(heap: mem.Allocator) -> (reader: Line_Reader, err: mem.Allocator_Error) {
	reader.heap = heap
	reader.chunk = make([]byte, CHUNK_LEN, heap) or_return
	reader.line_buf = make([dynamic]byte, heap)
	return reader, nil
}

// line_reader_destroy closes any open file and frees the buffers.
@(private)
line_reader_destroy :: proc(reader: ^Line_Reader) {
	line_reader_close(reader)
	delete(reader.chunk, reader.heap)
	delete(reader.line_buf)
	reader^ = {}
}

// line_reader_open opens full and reads its first chunk, so the NUL sniff
// over the first SNIFF_LEN bytes settles reader.binary before any line is
// returned. size is the byte length the index recorded: the first read asks
// for no more than that, and a file that grew since is still read to its end.
// A failure closes the file and returns it; the caller closes a successful
// open with line_reader_close.
@(private)
line_reader_open :: proc(reader: ^Line_Reader, full: string, size: i64) -> (err: os.Error) {
	file := os.open(full) or_return
	reader.file = file
	reader.rest = nil
	reader.joined, reader.binary, reader.done = false, false, false
	clear(&reader.line_buf)
	want := CHUNK_LEN
	if size > 0 {
		want = int(min(i64(CHUNK_LEN), size))
	}
	filled := 0
	for filled < want {
		count, read_error := os.read(file, reader.chunk[filled:want])
		filled += count
		if read_error == .EOF {
			reader.done = true
			break
		}
		if read_error != nil {
			line_reader_close(reader)
			return read_error
		}
	}
	if strings.index_byte(string(reader.chunk[:min(filled, SNIFF_LEN)]), 0) >= 0 {
		reader.binary = true
		reader.done = true
		return nil
	}
	reader.rest = reader.chunk[:filled]
	return nil
}

// line_reader_close closes the open file, if any.
@(private)
line_reader_close :: proc(reader: ^Line_Reader) {
	if reader.file != nil {
		os.close(reader.file)
		reader.file = nil
	}
}

// line_reader_next returns the next line, or ok=false at end of input. A read
// failure returns its error; the caller counts the skip.
@(private)
line_reader_next :: proc(reader: ^Line_Reader) -> (line: string, ok: bool, err: os.Error) {
	if reader.joined {
		clear(&reader.line_buf)
		reader.joined = false
	}
	for {
		if len(reader.rest) == 0 {
			if reader.done {
				break
			}
			count, read_error := os.read(reader.file, reader.chunk)
			reader.rest = reader.chunk[:count]
			if read_error == .EOF {
				reader.done = true
			} else if read_error != nil {
				return "", false, read_error
			}
			continue
		}
		at := strings.index_byte(string(reader.rest), '\n')
		if at < 0 {
			append(&reader.line_buf, ..reader.rest)
			reader.rest = nil
			continue
		}
		if len(reader.line_buf) == 0 {
			line = string(reader.rest[:at])
		} else {
			append(&reader.line_buf, ..reader.rest[:at])
			line = string(reader.line_buf[:])
			reader.joined = true
		}
		reader.rest = reader.rest[at + 1:]
		return strings.trim_suffix(line, "\r"), true, nil
	}
	if len(reader.line_buf) > 0 {
		reader.joined = true
		return strings.trim_suffix(string(reader.line_buf[:]), "\r"), true, nil
	}
	return "", false, nil
}

// Candidate is one file a grep call searches. rank orders files when the
// query carries a frecency.
@(private)
Candidate :: struct {
	file: ^File, // borrowed from the index
	rank: f64,
}

// candidate_before orders candidates by rank, highest first, then by path.
@(private, require_results)
candidate_before :: proc(first, second: Candidate) -> bool {
	if first.rank != second.rank {
		return first.rank > second.rank
	}
	return first.file.rel < second.file.rel
}

// Search_Kind is how a pass matches a line: the literal gate, the compiled
// regular expression behind its literal prefilter, or the typo-tolerant
// fuzzy pattern.
@(private)
Search_Kind :: enum {
	Literal,
	Regex,
	Fuzzy,
}

// Page_Slot is one file the page window touches: its candidate position, the
// window of its own rows, and the rows read back.
@(private)
Page_Slot :: struct {
	position: int,
	start:    int, // first row of the file in the page, counted from the file's first row
	end:      int, // one past the last
	rows:     [dynamic]Grep_Match,
	err:      mem.Allocator_Error,
}

// Worker is one thread's reusable state: its line reader, regex scratch,
// context ring, and fuzzy pattern with its top-K. Workers never share a
// field, so a pass needs no lock. The zero Worker is inert.
@(private)
Worker :: struct {
	reader:    Line_Reader,
	skips:     Skip_Breakdown, // files this worker did not search in the current pass
	ring:      [dynamic][dynamic]byte, // the last context_lines lines while rows are read back
	arena:     mem.Dynamic_Arena, // virtual-machine temporaries, reset after every line
	row_arena: mem.Dynamic_Arena, // path and text of the page rows this worker read back, reset by page_rows once copied
	capture:   regex.Capture,
	has_regex: bool,
	pattern:   fuzzy.Pattern,
	top:       fuzzy.Top_K,
	has_fuzzy: bool,
	heap:      mem.Allocator,
}

// worker_make allocates a worker's buffers with the heap allocator. A worker
// grows and frees them on its own thread, so they never use the caller's
// allocator, which only the calling thread may touch.
@(private, require_results)
worker_make :: proc(worker: ^Worker) -> (err: mem.Allocator_Error) {
	worker.heap = runtime.heap_allocator()
	mem.dynamic_arena_init(&worker.row_arena, worker.heap, worker.heap)
	worker.reader = line_reader_make(worker.heap) or_return
	worker.ring = make([dynamic][dynamic]byte, worker.heap)
	return nil
}

// worker_regex_init sets up the virtual-machine scratch a regex pass needs.
@(private)
worker_regex_init :: proc(worker: ^Worker) {
	mem.dynamic_arena_init(&worker.arena, worker.heap, worker.heap)
	worker.capture = regex.preallocate_capture(worker.heap)
	worker.has_regex = true
}

// worker_fuzzy_init compiles the worker's own fuzzy pattern, because a
// pattern's scoring rows are call state, and makes its top-K.
@(private, require_results)
worker_fuzzy_init :: proc(worker: ^Worker, query: string) -> (err: mem.Allocator_Error) {
	worker.pattern = fuzzy.pattern_compile(query, allocator = worker.heap) or_return
	worker.has_fuzzy = true
	worker.top = fuzzy.top_k_make(APPROX_CAP, worker.heap) or_return
	return nil
}

// worker_destroy releases everything worker_make and the init procedures
// allocated.
@(private)
worker_destroy :: proc(worker: ^Worker) {
	line_reader_destroy(&worker.reader)
	mem.dynamic_arena_destroy(&worker.row_arena)
	for &line in worker.ring {
		delete(line)
	}
	delete(worker.ring)
	if worker.has_regex {
		regex.destroy_capture(worker.capture, worker.heap)
		mem.dynamic_arena_destroy(&worker.arena)
	}
	if worker.has_fuzzy {
		fuzzy.pattern_destroy(&worker.pattern, worker.heap)
		fuzzy.top_k_destroy(&worker.top, worker.heap)
	}
	worker^ = {}
}

// Search is one pass over the candidate files. Workers claim candidates with
// an atomic counter and write only their own counts entry, so the pass needs
// no lock. A Content pass records how many rows each file holds; a
// Files_With_Matches pass records 1 for a file with a hit. A fuzzy Content
// pass records nothing here: each worker's top-K keeps the best lines.
@(private)
Search :: struct {
	candidates: []Candidate,
	workers:    []Worker,
	counts:     []int, // by candidate position
	slots:      []Page_Slot, // the files the page window touches, in order
	next:       int, // the next candidate or slot to claim, advanced atomically
	kind:       Search_Kind,
	gate:       Gate, // the literal, or the literal every regex match holds
	compiled:   regex.Regular_Expression, // valid only when kind is Regex
	span:       int, // context lines on each side of a hit
	files_only: bool,
}

// search_run runs one pass over every candidate, with the skips of the pass
// left in each worker.
@(private)
search_run :: proc(search: ^Search) {
	for &worker in search.workers {
		worker.skips = {}
	}
	slice.zero(search.counts)
	search.next = 0
	if len(search.candidates) > 0 {
		parallel_for(len(search.workers), len(search.workers), search, search_worker)
	}
}

@(private)
search_worker :: proc(data: rawptr, index: int) {
	search := cast(^Search)data
	worker := &search.workers[index]
	for {
		position := sync.atomic_add(&search.next, 1)
		if position >= len(search.candidates) {
			return
		}
		search_file(search, worker, position)
	}
}

// search_file searches one candidate. An unreadable or binary file is
// counted in the worker's skips and holds no rows, however far the read got.
@(private)
search_file :: proc(search: ^Search, worker: ^Worker, position: int) {
	file := search.candidates[position].file
	if open_error := line_reader_open(&worker.reader, file.full, file.size); open_error != nil {
		worker.skips.unreadable += 1
		return
	}
	defer line_reader_close(&worker.reader)
	if worker.reader.binary {
		worker.skips.binary += 1
		return
	}
	read_error: os.Error
	switch {
	case search.files_only:
		search.counts[position], read_error = scan_first(search, worker)
	case search.kind == .Fuzzy:
		read_error = scan_approx(worker, position)
	case:
		sink: Row_Sink
		read_error = scan_rows(search, worker, &sink)
		search.counts[position] = sink.seen
	}
	if read_error != nil {
		worker.skips.unreadable += 1
		search.counts[position] = 0
	}
}

// search_column returns the 1-based byte column of the pattern in line, or 0
// for no hit. The gate rejects lines that cannot match before the virtual
// machine runs; it is conservative, so the machine decides the column.
@(private, require_results)
search_column :: proc(search: ^Search, worker: ^Worker, line: string) -> int {
	switch search.kind {
	case .Literal:
		return gate_index(search.gate, line) + 1 // -1 becomes 0
	case .Regex:
		if gate_index(search.gate, line) < 0 {
			return 0
		}
		scratch := mem.dynamic_arena_allocator(&worker.arena)
		_, matched := regex.match_with_preallocated_capture(search.compiled, line, &worker.capture, scratch)
		column := 0
		if matched && len(worker.capture.pos) > 0 {
			column = worker.capture.pos[0][0] + 1
		}
		free_all(scratch)
		return column
	case .Fuzzy:
		return 0
	}
	return 0
}

// scan_first returns 1 when the open file holds a hit, stopping at the first.
@(private)
scan_first :: proc(search: ^Search, worker: ^Worker) -> (count: int, err: os.Error) {
	for {
		line, ok := line_reader_next(&worker.reader) or_return
		if !ok {
			return 0, nil
		}
		if search.kind == .Fuzzy {
			if fuzzy.match_kept(fuzzy.pattern_match(&worker.pattern, line)) {
				return 1, nil
			}
		} else if search_column(search, worker, line) != 0 {
			return 1, nil
		}
	}
}

// approx_index names a line for a fuzzy top-K: the candidate position above
// and the 1-based line number below, so ties break toward earlier files.
@(private, require_results)
approx_index :: proc(position, line: int) -> int {
	return position << APPROX_LINE_BITS | line
}

// scan_approx offers every line of the open file to the worker's top-K.
@(private)
scan_approx :: proc(worker: ^Worker, position: int) -> (err: os.Error) {
	line_number := 0
	for {
		line, ok := line_reader_next(&worker.reader) or_return
		if !ok {
			return nil
		}
		line_number += 1
		fuzzy.top_k_offer(&worker.top, &worker.pattern, approx_index(position, line_number), line)
	}
}

// Row_Sink numbers the rows of one file in line order. While counting, store
// is false and only seen advances. While reading a page back, rows numbered
// in [start, end) are cloned into rows with allocator, the worker's row
// arena, and a clone failure lands in err and stops the scan.
@(private)
Row_Sink :: struct {
	path:      string,
	rows:      ^[dynamic]Grep_Match,
	start:     int,
	end:       int,
	seen:      int, // rows numbered so far
	err:       mem.Allocator_Error,
	allocator: mem.Allocator,
	store:     bool,
}

@(private)
row_sink_push :: proc(sink: ^Row_Sink, line, col: int, text: string, is_context: bool) {
	index := sink.seen
	sink.seen += 1
	if !sink.store || sink.err != nil || index < sink.start || index >= sink.end {
		return
	}
	match, clone_error := match_clone(sink.path, text, line, col, is_context, sink.allocator)
	if clone_error != nil {
		sink.err = clone_error
		return
	}
	if _, append_error := append(sink.rows, match); append_error != nil {
		sink.err = append_error
	}
}

// ring_store keeps line as the newest of the last span lines.
@(private)
ring_store :: proc(worker: ^Worker, sink: ^Row_Sink, span, line_number: int, line: string) {
	slot := (line_number - 1) % span
	if slot == len(worker.ring) {
		if _, append_error := append(&worker.ring, make([dynamic]byte, worker.heap)); append_error != nil {
			sink.err = append_error
			return
		}
	}
	clear(&worker.ring[slot])
	if _, append_error := append(&worker.ring[slot], ..transmute([]byte)line); append_error != nil {
		sink.err = append_error
	}
}

// scan_rows streams the open file once and numbers its rows: each hit, the
// span lines before it, and the span lines after it, with overlapping
// context counted once. pending counts the lines since the last row, capped
// at span, which are exactly the leading context a hit claims; trailing
// counts the context lines still owed after the last hit. The count pass and
// the page read-back share this procedure, so their row numbers agree.
@(private)
scan_rows :: proc(search: ^Search, worker: ^Worker, sink: ^Row_Sink) -> (err: os.Error) {
	span := search.span
	pending, trailing, line_number := 0, 0, 0
	for sink.err == nil {
		line, ok := line_reader_next(&worker.reader) or_return
		if !ok {
			break
		}
		line_number += 1
		if column := search_column(search, worker, line); column != 0 {
			for number in line_number - pending ..< line_number {
				text := ""
				if sink.store {
					text = string(worker.ring[(number - 1) % span][:])
				}
				row_sink_push(sink, number, 0, text, true)
			}
			row_sink_push(sink, line_number, column, line, false)
			pending, trailing = 0, span
		} else if trailing > 0 {
			row_sink_push(sink, line_number, 0, line, true)
			trailing -= 1
		} else {
			pending = min(pending + 1, span)
		}
		if sink.store {
			if span > 0 {
				ring_store(worker, sink, span, line_number, line)
			}
			if sink.seen >= sink.end {
				break
			}
		}
	}
	return nil
}

@(private)
page_worker :: proc(data: rawptr, index: int) {
	search := cast(^Search)data
	worker := &search.workers[index]
	for {
		slot_index := sync.atomic_add(&search.next, 1)
		if slot_index >= len(search.slots) {
			return
		}
		slot := &search.slots[slot_index]
		file := search.candidates[slot.position].file
		if open_error := line_reader_open(&worker.reader, file.full, file.size); open_error != nil {
			continue
		}
		sink := Row_Sink {
			path      = file.rel,
			rows      = &slot.rows,
			start     = slot.start,
			end       = slot.end,
			allocator = mem.dynamic_arena_allocator(&worker.row_arena),
			store     = true,
		}
		if !worker.reader.binary {
			// A file that changed since the count pass keeps the rows read
			// before the failure; the page is a snapshot of what was found.
			_ = scan_rows(search, worker, &sink)
		}
		line_reader_close(&worker.reader)
		slot.err = sink.err
	}
}

// page_rows materializes rows [start, end) of the pass in global order. It
// re-reads only the files that hold those rows, so memory follows the page,
// never the total. Workers clone each file's rows into their own row arenas;
// after they are joined the calling thread copies the rows into allocator and
// resets the arenas. The caller owns the rows and releases them with
// matches_destroy.
@(private, require_results)
page_rows :: proc(search: ^Search, start, end: int, allocator: mem.Allocator) -> (rows: []Grep_Match, err: mem.Allocator_Error) {
	heap := runtime.heap_allocator()
	slots := make([dynamic]Page_Slot, allocator)
	defer {
		for &worker in search.workers {
			free_all(mem.dynamic_arena_allocator(&worker.row_arena))
		}
		for slot in slots {
			delete(slot.rows)
		}
		delete(slots)
	}
	first := 0
	for count, position in search.counts {
		if count == 0 {
			continue
		}
		last := first + count
		defer first = last
		if last <= start {
			continue
		}
		if first >= end {
			break
		}
		slot := Page_Slot {
			position = position,
			start    = max(start - first, 0),
			end      = min(end, last) - first,
		}
		slot.rows = make([dynamic]Grep_Match, 0, slot.end - slot.start, heap)
		if _, append_error := append(&slots, slot); append_error != nil {
			delete(slot.rows)
			return nil, append_error
		}
	}
	if len(slots) > 0 {
		search.slots = slots[:]
		search.next = 0
		workers := min(len(search.workers), len(slots))
		parallel_for(workers, workers, search, page_worker)
	}
	total := 0
	for slot in slots {
		if slot.err != nil {
			return nil, slot.err
		}
		total += len(slot.rows)
	}
	rows = make([]Grep_Match, total, allocator) or_return
	cloned := 0
	defer if err != nil {
		for match in rows[:cloned] {
			delete(match.path, allocator)
			delete(match.text, allocator)
		}
		delete(rows, allocator)
		rows = nil
	}
	for slot in slots {
		for match in slot.rows {
			rows[cloned] = match_clone(match.path, match.text, match.line, match.col, match.is_context, allocator) or_return
			cloned += 1
		}
	}
	return rows, nil
}

// approx_before orders fuzzy hits best first, the order the fuzzy package's
// top-K keeps: higher score, then shorter line, then earlier index.
@(private, require_results)
approx_before :: proc(first, second: fuzzy.Match_Hit) -> bool {
	if first.score != second.score {
		return first.score > second.score
	}
	if first.length != second.length {
		return first.length < second.length
	}
	return first.index < second.index
}

// approx_winners merges the workers' top-Ks into the best APPROX_CAP hits,
// best first. Every hit of the global top-K is in its own worker's top-K, so
// the merge loses nothing. The caller owns the result.
@(private, require_results)
approx_winners :: proc(workers: []Worker, allocator: mem.Allocator) -> (winners: [dynamic]fuzzy.Match_Hit, err: mem.Allocator_Error) {
	winners = make([dynamic]fuzzy.Match_Hit, allocator)
	defer if err != nil {
		delete(winners)
	}
	for &worker in workers {
		append(&winners, ..worker.top.entries[:worker.top.count]) or_return
	}
	slice.sort_by(winners[:], approx_before)
	resize(&winners, min(len(winners), APPROX_CAP))
	return winners, nil
}

// approx_rows reads the lines the winners name back from their files, one
// open per file, and returns the rows in winner order. A line that vanished
// since the pass is left out. The caller owns the rows and releases them with
// matches_destroy.
@(private, require_results)
approx_rows :: proc(search: ^Search, winners: []fuzzy.Match_Hit, allocator: mem.Allocator) -> (rows: []Grep_Match, err: mem.Allocator_Error) {
	Located :: struct {
		index: int,
		rank:  int,
	}
	located := make([]Located, len(winners), allocator) or_return
	defer delete(located, allocator)
	for winner, rank in winners {
		located[rank] = Located {
			index = winner.index,
			rank  = rank,
		}
	}
	slice.sort_by(located, proc(first, second: Located) -> bool { return first.index < second.index })
	found := make([]Grep_Match, len(winners), allocator) or_return
	defer matches_destroy(found, allocator)
	worker := &search.workers[0]
	line_mask := 1 << APPROX_LINE_BITS - 1
	group := 0
	for group < len(located) {
		position := located[group].index >> APPROX_LINE_BITS
		group_end := group
		for group_end < len(located) && located[group_end].index >> APPROX_LINE_BITS == position {
			group_end += 1
		}
		file := search.candidates[position].file
		if open_error := line_reader_open(&worker.reader, file.full, file.size); open_error == nil {
			line_number, next := 0, group
			for !worker.reader.binary && next < group_end {
				line, ok, read_error := line_reader_next(&worker.reader)
				if read_error != nil || !ok {
					break
				}
				line_number += 1
				if line_number == located[next].index & line_mask {
					found[located[next].rank] = match_clone(file.rel, line, line_number, 1, false, allocator) or_return
					next += 1
				}
			}
			line_reader_close(&worker.reader)
		}
		group = group_end
	}
	kept := 0
	for match in found {
		if match.line != 0 {
			kept += 1
		}
	}
	rows = make([]Grep_Match, kept, allocator) or_return
	at := 0
	for match in found {
		if match.line != 0 {
			rows[at] = match
			at += 1
		}
	}
	// The rows moved into the result; the scratch slice releases only itself.
	delete(found, allocator)
	found = nil
	return rows, nil
}

// approx_files ranks the files a fuzzy Files_With_Matches pass kept by how
// close their paths are to the query and returns the best APPROX_CAP
// candidate positions, best first. The caller owns the result.
@(private, require_results)
approx_files :: proc(search: ^Search, query: string, allocator: mem.Allocator) -> (positions: [dynamic]int, err: mem.Allocator_Error) {
	pattern := fuzzy.pattern_compile(query, allocator = allocator) or_return
	defer fuzzy.pattern_destroy(&pattern, allocator)
	top := fuzzy.top_k_make(APPROX_CAP, allocator) or_return
	defer fuzzy.top_k_destroy(&top, allocator)
	for count, position in search.counts {
		if count != 0 {
			fuzzy.top_k_offer(&top, &pattern, position, search.candidates[position].file.rel)
		}
	}
	positions = make([dynamic]int, allocator)
	defer if err != nil {
		delete(positions)
	}
	for hit in fuzzy.top_k_sorted(&top) {
		append(&positions, hit.index) or_return
	}
	return positions, nil
}

// compile_pattern compiles pattern once per query with smart-case flags,
// then releases all working memory before returning: the caller owns only
// the compiled program. An invalid pattern returns its error with nothing
// allocated behind it.
@(private, require_results)
compile_pattern :: proc(pattern: string, case_sensitive: bool, heap: mem.Allocator) -> (compiled: regex.Regular_Expression, err: regex.Error) {
	flags := regex.Flags{.Unicode}
	if !case_sensitive {
		flags += {.Case_Insensitive}
	}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, heap, heap)
	defer mem.dynamic_arena_destroy(&arena)
	return regex.create(pattern, flags, heap, mem.dynamic_arena_allocator(&arena))
}

// Gate is one query's prefilter: the literal a line must hold to match, which
// is the whole pattern for a literal search and the longest required literal
// for a regex. An empty pattern gates nothing. It borrows the pattern.
@(private)
Gate :: struct {
	pattern:        string,
	case_sensitive: bool,
	ascii:          bool, // the pattern holds no byte at or above 0x80
}

@(private)
gate_make :: proc(pattern: string, case_sensitive: bool) -> Gate {
	ascii := true
	for value in transmute([]byte)pattern {
		ascii &&= value < utf8.RUNE_SELF
	}
	return Gate{pattern, case_sensitive, ascii}
}

// gate_index returns the byte offset of the gate's pattern in line, or -1.
// An empty pattern is at offset 0. A case-insensitive match folds runes
// against the original bytes, so length-changing folds keep the true offset.
// Unicode folds cross the ASCII boundary (the Kelvin sign matches k), so a
// byte comparison is exact only on pure-ASCII text: the case-insensitive
// prefilter runs only for an ASCII pattern, and passes any line with a
// non-ASCII byte to fold_index.
@(private, require_results)
gate_index :: proc(gate: Gate, line: string) -> int {
	if gate.pattern == "" {
		return 0
	}
	if gate.case_sensitive {
		return literal_index(line, gate.pattern)
	}
	if gate.ascii && !fold_may_match(line, gate.pattern) {
		return -1
	}
	return fold_index(line, gate.pattern)
}

// literal_index returns the byte offset of pattern in line, or -1. It scans
// for the pattern's last byte with the vectorized index_byte, which is rarer
// at line ends than a first byte is at line starts, and compares the whole
// pattern only at each hit. pattern must not be empty.
@(private, require_results)
literal_index :: proc(line, pattern: string) -> int {
	last := len(pattern) - 1
	for offset := 0; offset + len(pattern) <= len(line); offset += 1 {
		at := strings.index_byte(line[offset + last:], pattern[last])
		if at < 0 {
			return -1
		}
		offset += at
		if strings.has_prefix(line[offset:], pattern) {
			return offset
		}
	}
	return -1
}

// fold_verify reports whether pattern may start at pos of bytes under
// ASCII folding. A non-ASCII byte in the window passes, for fold_index to
// decide. The window must lie inside bytes.
@(private, require_results)
fold_verify :: proc(bytes: []byte, pattern: string, pos: int) -> bool {
	for j := 0; j < len(pattern); j += 1 {
		if bytes[pos + j] >= utf8.RUNE_SELF {
			return true
		}
		if ascii_fold(bytes[pos + j]) != ascii_fold(pattern[j]) {
			return false
		}
	}
	return true
}

// fold_may_match reports whether line may hold pattern under fold_index,
// without rejecting a line that matches. It is exact over pure-ASCII text
// and passes a line with any non-ASCII byte. It finds the pattern's first
// byte sixteen bytes per step, ORing 0x20 so both cases of a letter map to
// its lowercase and no other byte does, and verifies each hit. pattern must
// be non-empty ASCII.
@(private, require_results)
fold_may_match :: proc(line, pattern: string) -> bool {
	first := ascii_fold(pattern[0])
	fold_bit: byte = 0x20 if first >= 'a' && first <= 'z' else 0
	bytes := transmute([]byte)line
	i := 0
	when simd.HAS_HARDWARE_SIMD {
		for ; i + 16 <= len(bytes); i += 16 {
			chunk := intrinsics.unaligned_load((^simd.u8x16)(raw_data(bytes[i:])))
			if simd.reduce_or(chunk) >= utf8.RUNE_SELF {
				return true
			}
			hits := transmute(u16)simd.extract_msbs(simd.lanes_eq(chunk | simd.u8x16(fold_bit), simd.u8x16(first)))
			for ; hits != 0; hits &= hits - 1 {
				pos := i + int(intrinsics.count_trailing_zeros(hits))
				if pos + len(pattern) <= len(bytes) && fold_verify(bytes, pattern, pos) {
					return true
				}
			}
		}
	}
	for ; i < len(bytes); i += 1 {
		if bytes[i] >= utf8.RUNE_SELF || (bytes[i] | fold_bit == first && i + len(pattern) <= len(bytes) && fold_verify(bytes, pattern, i)) {
			return true
		}
	}
	return false
}

// Literal_Runs collects the literal byte runs of a regex pattern in an
// append-only buffer: each run is a slice of it, so the best run is a view.
@(private)
Literal_Runs :: struct {
	buffer: []byte,
	used:   int,
	start:  int, // where the open run begins
	best:   string,
}

@(private)
literal_runs_close :: proc(runs: ^Literal_Runs) {
	if run := runs.buffer[runs.start:runs.used]; len(run) > len(runs.best) {
		runs.best = string(run)
	}
	runs.start = runs.used
}

// literal_runs_pop drops the last rune of the open run, the one a quantifier
// makes optional.
@(private)
literal_runs_pop :: proc(runs: ^Literal_Runs) {
	for runs.used > runs.start && runs.buffer[runs.used - 1] & 0xC0 == 0x80 {
		runs.used -= 1
	}
	if runs.used > runs.start {
		runs.used -= 1
	}
}

// regex_literal returns the longest byte string every match of pattern
// holds, or "" when it finds none. Only call it with a pattern that
// compiled. It collects literals outside any group and breaks a run at every
// token that is not one plain rune: a class, a wildcard, an anchor, a group,
// a shorthand escape, a '+' (its operand repeats, so the run ends with it)
// and a quantifier that makes its operand optional (which drops the operand
// from the run). A top-level '|' leaves no required literal, and a '#' starts
// a comment, so the scan stops there. Doubt only shortens a run, which keeps
// the result sound. buffer must hold len(pattern) bytes, because a literal
// takes at least as many bytes in the pattern as in a run; the result is a
// view into it.
@(private, require_results)
regex_literal :: proc(pattern: string, buffer: []byte) -> string {
	runs := Literal_Runs {
		buffer = buffer,
	}
	depth := 0
	scan: for i := 0; i < len(pattern); i += 1 {
		switch pattern[i] {
		case '\\':
			i += 1
			if i == len(pattern) {
				break scan
			}
			// A letter, digit, or underscore after a backslash names a
			// class or an assertion; any other byte is itself.
			escaped := pattern[i]
			letter := escaped | 0x20
			shorthand := (letter >= 'a' && letter <= 'z') || (escaped >= '0' && escaped <= '9') || escaped == '_'
			if depth == 0 && !shorthand {
				runs.buffer[runs.used] = escaped
				runs.used += 1
			} else {
				literal_runs_close(&runs)
			}
		case '[':
			literal_runs_close(&runs)
			for i += 1; i < len(pattern) && pattern[i] != ']'; i += 1 {
				if pattern[i] == '\\' {
					i += 1
				}
			}
		case '(':
			literal_runs_close(&runs)
			depth += 1
		case ')':
			literal_runs_close(&runs)
			depth -= 1
		case '|':
			if depth == 0 {
				return ""
			}
		case '*', '?':
			literal_runs_pop(&runs)
			literal_runs_close(&runs)
		case '{':
			literal_runs_pop(&runs)
			literal_runs_close(&runs)
			for i += 1; i < len(pattern) && pattern[i] != '}'; i += 1 {  }
		case '#':
			if depth == 0 {
				break scan
			}
		case '+', '.', '^', '$':
			literal_runs_close(&runs)
		case:
			if depth == 0 {
				runs.buffer[runs.used] = pattern[i]
				runs.used += 1
			}
		}
	}
	literal_runs_close(&runs)
	return runs.best
}

// grep_notice formats one recovery label with allocator.
@(private, require_results)
grep_notice :: proc(allocator: mem.Allocator, format: string, args: ..any) -> (notice: string, err: mem.Allocator_Error) {
	notice = fmt.aprintf(format, ..args, allocator = allocator)
	if notice == "" {
		return "", .Out_Of_Memory
	}
	return notice, nil
}

// grep_candidates lists the files a query searches, in the order it searches
// them: path order, or frecency order when the query carries a frecency. A
// file the glob rejects is not a candidate and is never counted as skipped;
// the index's binary and oversize files that pass the glob are counted in
// skips. The caller owns the list.
@(private, require_results)
grep_candidates :: proc(
	index: ^Index,
	query: Grep_Query,
	allocator: mem.Allocator,
) -> (
	candidates: [dynamic]Candidate,
	skips: Skip_Breakdown,
	err: mem.Allocator_Error,
) {
	skips = index.skipped
	candidates = make([dynamic]Candidate, allocator)
	defer if err != nil {
		delete(candidates)
	}
	for &file in index.files {
		if !glob_keep(query.glob, file.rel) || (query.exclude != "" && glob_keep(query.exclude, file.rel)) {
			continue
		}
		if file.is_binary {
			skips.binary += 1
			continue
		}
		if file.size > GREP_MAX_FILE_SIZE {
			skips.oversize += 1
			continue
		}
		rank := 0.0
		if query.frecency != nil {
			rank = frecency_access_score(query.frecency, file.full, query.now) + modification_score(file.mtime, query.now)
		}
		append(&candidates, Candidate{file = &file, rank = rank}) or_return
	}
	if query.frecency != nil {
		slice.sort_by(candidates[:], candidate_before)
	}
	return candidates, skips, nil
}

// grep runs one grep call over the index, over the files the glob keeps.
// Files the index flags binary are counted as skipped without being opened.
// Workers record per-file row counts only; the page window is computed in
// global file order and only the files it touches are read again for their
// rows, so memory follows the page and never the total. A Plain-mode query
// with zero exact hits runs one labeled recovery (see Grep_Mode). The index
// is borrowed and never walked; the caller owns the result, allocated with
// allocator, and releases it with grep_result_destroy. Only the calling
// thread uses allocator; workers allocate with the heap allocator. A
// malformed glob is Invalid_Glob, a malformed or foreign cursor
// Invalid_Cursor, and a cursor from before the latest update Stale_Cursor.
// The cursor offset counts rows, or files in Files_With_Matches mode, in
// result order.
@(require_results)
grep :: proc(index: ^Index, query: Grep_Query, allocator := context.allocator) -> (result: Grep_Result, err: Error) {
	if !glob_valid(query.glob) || !glob_valid(query.exclude) {
		return {}, Error(Error_Code.Invalid_Glob)
	}
	offset := cursor_parse(query.cursor, index.root, index.generation, allocator) or_return
	case_sensitive := true
	switch query.sensitivity {
	case .Smart:
		case_sensitive = has_upper(query.pattern)
	case .Sensitive:
		case_sensitive = true
	case .Insensitive:
		case_sensitive = false
	}
	candidates, skips := grep_candidates(index, query, allocator) or_return
	defer delete(candidates)
	files_only := query.output == .Files_With_Matches
	search := Search {
		candidates = candidates[:],
		span       = 0 if files_only else max(query.context_lines, 0),
		files_only = files_only,
	}
	search.counts = make([]int, len(candidates), allocator) or_return
	defer delete(search.counts, allocator)
	cores := max(os.get_processor_core_count(), 1)
	search.workers = make([]Worker, max(min(cores, len(candidates)), 1), allocator) or_return
	defer {
		for &worker in search.workers {
			worker_destroy(&worker)
		}
		delete(search.workers, allocator)
	}
	for &worker in search.workers {
		worker_make(&worker) or_return
	}

	// The gate borrows the pattern text while workers run, and they read the
	// compiled program; both outlive every pass.
	pattern_text := query.pattern
	literal_buffer: []byte
	defer delete(literal_buffer, allocator)
	defer if search.kind == .Regex {
		regex.destroy_regex(search.compiled, allocator)
	}
	repaired := false
	if query.mode == .Regex {
		compiled, compile_error := compile_pattern(query.pattern, case_sensitive, allocator)
		if compile_error != nil {
			repaired = true
		} else {
			search.kind = .Regex
			search.compiled = compiled
			literal_buffer = make([]byte, len(query.pattern), allocator) or_return
			pattern_text = regex_literal(query.pattern, literal_buffer)
			for &worker in search.workers {
				worker_regex_init(&worker)
			}
		}
	}
	search.gate = gate_make(pattern_text, case_sensitive)
	search_run(&search)
	total := counts_total(search.counts)

	notice := ""
	defer if err != nil {
		delete(notice, allocator)
	}
	if repaired {
		notice = grep_notice(allocator, "pattern %q is not a valid regular expression; showing literal matches", query.pattern) or_return
	}
	approximate := false
	winners: [dynamic]fuzzy.Match_Hit
	defer delete(winners)
	positions: [dynamic]int
	defer delete(positions)
	if total == 0 && query.mode == .Plain && query.pattern != "" {
		if shorter, ok := broaden_query(query.pattern); ok {
			search.gate = gate_make(shorter, case_sensitive)
			search_run(&search)
			total = counts_total(search.counts)
			if total > 0 {
				notice = grep_notice(allocator, "0 exact matches for %q; showing %d matches for broadened query %q", query.pattern, total, shorter) or_return
			}
		}
		if total == 0 {
			search.kind = .Fuzzy
			for &worker in search.workers {
				worker_fuzzy_init(&worker, query.pattern) or_return
			}
			search_run(&search)
			if files_only {
				positions = approx_files(&search, query.pattern, allocator) or_return
				total = len(positions)
			} else {
				winners = approx_winners(search.workers, allocator) or_return
				total = len(winners)
			}
			if total > 0 {
				approximate = true
				kind := "matches" if !files_only else "file matches"
				notice = grep_notice(
					allocator,
					"0 exact matches for %q; showing %d approximate %s, typo-tolerant, best first",
					query.pattern,
					total,
					kind,
				) or_return
			}
		}
	}
	for worker in search.workers {
		skips.binary += worker.skips.binary
		skips.oversize += worker.skips.oversize
		skips.unreadable += worker.skips.unreadable
	}

	rows: []Grep_Match
	names: []string
	defer if err != nil {
		matches_destroy(rows, allocator)
		for name in names {
			delete(name, allocator)
		}
		delete(names, allocator)
	}
	start, end, has_more := 0, 0, false
	switch {
	case files_only:
		if !approximate {
			for count, position in search.counts {
				if count != 0 {
					append(&positions, position) or_return
				}
			}
		}
		start, end, has_more = page_split(len(positions), offset, query.limit)
		total = len(positions)
		names = make([]string, end - start, allocator) or_return
		for position, i in positions[start:end] {
			names[i] = strings.clone(candidates[position].file.rel, allocator) or_return
		}
	case approximate:
		start, end, has_more = page_split(len(winners), offset, query.limit)
		rows = approx_rows(&search, winners[start:end], allocator) or_return
	case:
		start, end, has_more = page_split(total, offset, query.limit)
		rows = page_rows(&search, start, end, allocator) or_return
	}
	next_cursor := ""
	if has_more {
		next_cursor = cursor_make(end, index.generation, index.root, allocator) or_return
	}
	return Grep_Result{matches = rows, files = names, total = total, skipped = skips, next_cursor = next_cursor, notice = notice}, nil
}

// counts_total sums a pass's per-file counts.
@(private, require_results)
counts_total :: proc(counts: []int) -> (total: int) {
	for count in counts {
		total += count
	}
	return total
}
