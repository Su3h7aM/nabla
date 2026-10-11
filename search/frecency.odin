package search

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

// FRECENCY_HALF_LIFE is the default half-life of one access, in seconds: three
// days, the agent-mode value of fff.
FRECENCY_HALF_LIFE :: 3 * 24 * 60 * 60

// FRECENCY_WINDOW is the default age in seconds past which an entry scores 0
// and is dropped when a log is opened: seven days, the agent-mode value of fff.
FRECENCY_WINDOW :: 7 * 24 * 60 * 60

// ACCESS_SCORE_KNEE is the decayed sum above which access scores grow with the
// square root of the excess instead of linearly.
ACCESS_SCORE_KNEE :: 10

// Access is the whole history of one path: the decayed number of accesses as
// of time, in unix seconds. Recording at t sets weight to
// weight * decay(t - time) + 1, so memory stays O(1) per path.
Access :: struct {
	weight: f64,
	time:   i64,
}

// Frecency ranks absolute paths by how often and how recently they were
// accessed, and optionally persists the accesses in an append-only log.
//
// Each access counts exp(-ln(2) * age / half_life), so the score is a sum
// that halves every half_life seconds. An entry whose last access is older
// than window scores 0. The access score maps the sum S to S up to
// ACCESS_SCORE_KNEE and to ACCESS_SCORE_KNEE + sqrt(S - ACCESS_SCORE_KNEE)
// above it, so heavy use has diminishing returns.
//
// The log holds one line per access, "<unix seconds> <weight> <path>\n", and
// appends write weight 1. Replaying a line adds weight, decayed to the later
// of the line time and the entry time, so replay is order independent. Opening
// a log rewrites it with one line per surviving path whose weight is the
// decayed sum, which replays to the same score. A path containing a newline
// cannot be recorded and is skipped silently. Malformed lines are ignored.
//
// The zero value is inert: it scores every path 0, and destroying it is a
// no-op. frecency_open initializes it, and a zero half_life or window set
// before it selects the default. After frecency_open, record and score may be
// called from any thread. frecency_destroy may not run concurrently with any
// other call. The map, its keys, and the allocator state belong to the
// Frecency until frecency_destroy.
Frecency :: struct {
	half_life: i64, // seconds, set before frecency_open or left zero for FRECENCY_HALF_LIFE
	window:    i64, // seconds, set before frecency_open or left zero for FRECENCY_WINDOW
	allocator: runtime.Allocator,
	accesses:  map[string]Access, // keyed by cloned absolute path
	log:       ^os.File, // nil for a memory-only Frecency
	mutex:     sync.Mutex, // guards accesses; never held across I/O
}

// frecency_open initializes frecency and, when log_path is not empty, replays
// that log and rewrites it compacted at now. A missing log is not an error,
// and a corrupt one never fails: bad lines are ignored. The compacted copy is
// written to log_path with ".tmp" appended and renamed over the log, so a
// crash never loses the log. The directory of log_path must exist. An empty
// log_path makes a memory-only Frecency. On error frecency is destroyed.
// Errors are the allocator's and the filesystem's.
@(require_results)
frecency_open :: proc(frecency: ^Frecency, log_path: string, now: i64, allocator := context.allocator) -> (err: Error) {
	frecency^ = {
		half_life = frecency.half_life if frecency.half_life > 0 else FRECENCY_HALF_LIFE,
		window    = frecency.window if frecency.window > 0 else FRECENCY_WINDOW,
		allocator = allocator,
		accesses  = make(map[string]Access, allocator),
	}
	defer if err != nil {
		frecency_destroy(frecency)
	}
	if log_path == "" {
		return nil
	}

	data, read_error := os.read_entire_file(log_path, allocator)
	if read_error != nil && read_error != .Not_Exist {
		return read_error
	}
	defer delete(data, allocator)
	remaining := string(data)
	for line in strings.split_iterator(&remaining, "\n") {
		seconds, weight, path := frecency_parse_line(line) or_continue
		frecency_add(frecency, path, seconds, weight) or_return
	}

	frecency_compact(frecency, log_path, now) or_return
	frecency.log = os.open(log_path, {.Write, .Append, .Create}, os.Permissions_Default_File) or_return
	return nil
}

// frecency_destroy closes the log and frees the map and its keys. The zero
// Frecency is left as it is.
frecency_destroy :: proc(frecency: ^Frecency) {
	if frecency.log != nil {
		_ = os.close(frecency.log)
	}
	for path in frecency.accesses {
		delete(path, frecency.allocator)
	}
	delete(frecency.accesses)
	frecency^ = {}
}

// frecency_record counts one access to path at now and appends it to the log
// with a single write. The map is updated even when the write fails, and the
// write error is returned. A path that is empty or contains a newline is not
// recordable: nothing happens and no error is returned.
@(require_results)
frecency_record :: proc(frecency: ^Frecency, path: string, now: i64) -> Error {
	if !frecency_recordable(path) {
		return nil
	}
	frecency_add(frecency, path, now, 1) or_return
	if frecency.log == nil {
		return nil
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	_ = os.write_string(frecency.log, fmt.tprintf("%d 1 %s\n", now, path)) or_return
	return nil
}

// frecency_access_score returns the access score of path at now: 0 when the
// path is unknown or its last access is older than the window, otherwise the
// decayed sum with diminishing returns above ACCESS_SCORE_KNEE.
@(require_results)
frecency_access_score :: proc(frecency: ^Frecency, path: string, now: i64) -> f64 {
	sync.guard(&frecency.mutex)
	access, found := frecency.accesses[path]
	if !found || now - access.time > frecency.window {
		return 0
	}
	sum := access.weight * frecency_decay(frecency.half_life, max(now - access.time, 0))
	if sum <= ACCESS_SCORE_KNEE {
		return sum
	}
	return ACCESS_SCORE_KNEE + math.sqrt(sum - ACCESS_SCORE_KNEE)
}

// Modification_Breakpoint is one point of the modification score curve: files
// modified within age seconds score at least score.
Modification_Breakpoint :: struct {
	age:   i64,
	score: f64,
}

// MODIFICATION_BREAKPOINTS is the agent-mode curve of fff. The score is flat
// before the first breakpoint, linear between breakpoints, and 0 past the last.
MODIFICATION_BREAKPOINTS :: [?]Modification_Breakpoint {
	{age = 30, score = 16},
	{age = 5 * 60, score = 8},
	{age = 15 * 60, score = 4},
	{age = 60 * 60, score = 2},
	{age = 4 * 60 * 60, score = 1},
}

// modification_score returns the score of a file last modified at mtime, seen
// at now in unix seconds: 16 for a file modified within 30 seconds, falling
// linearly through the MODIFICATION_BREAKPOINTS to 1 at four hours, and 0
// after. A modification time in the future scores like one at now.
@(require_results)
modification_score :: proc "contextless" (mtime: time.Time, now: i64) -> f64 {
	age := now - time.to_unix_seconds(mtime)
	breakpoints := MODIFICATION_BREAKPOINTS
	if age <= breakpoints[0].age {
		return breakpoints[0].score
	}
	for i in 1 ..< len(breakpoints) {
		from, to := breakpoints[i - 1], breakpoints[i]
		if age <= to.age {
			fraction := f64(age - from.age) / f64(to.age - from.age)
			return from.score + (to.score - from.score) * fraction
		}
	}
	return 0
}

@(private = "file")
frecency_recordable :: proc(path: string) -> bool {
	return path != "" && strings.index_byte(path, '\n') < 0
}

// frecency_decay is the fraction of an access that remains after age seconds.
@(private = "file")
frecency_decay :: proc(half_life, age: i64) -> f64 {
	return math.exp(-math.LN2 * f64(age) / f64(half_life))
}

// frecency_add adds weight at seconds to path, decaying both the stored sum
// and the new weight to the later of the two times. path is cloned when new.
@(private = "file")
frecency_add :: proc(frecency: ^Frecency, path: string, seconds: i64, weight: f64) -> Error {
	sync.guard(&frecency.mutex)
	key, access, just_inserted := runtime.map_entry(&frecency.accesses, path) or_return
	if just_inserted {
		cloned, clone_error := strings.clone(path, frecency.allocator)
		if clone_error != nil {
			delete_key(&frecency.accesses, path)
			return clone_error
		}
		// The clone hashes the same as path, so the map stays valid.
		key^ = cloned
		access^ = {
			weight = weight,
			time   = seconds,
		}
		return nil
	}
	latest := max(access.time, seconds)
	access.weight = access.weight * frecency_decay(frecency.half_life, latest - access.time) + weight * frecency_decay(frecency.half_life, latest - seconds)
	access.time = latest
	return nil
}

// frecency_parse_line splits "<unix seconds> <weight> <path>". The path is a
// view into line.
@(private = "file")
frecency_parse_line :: proc(line: string) -> (seconds: i64, weight: f64, path: string, ok: bool) {
	seconds_text, _, rest := strings.partition(line, " ")
	weight_text, _, path_text := strings.partition(rest, " ")
	seconds = strconv.parse_i64_of_base(seconds_text, 10) or_return
	weight = strconv.parse_f64(weight_text) or_return
	if seconds < 0 || !(weight > 0) || math.is_inf(weight) || !frecency_recordable(path_text) {
		return 0, 0, "", false
	}
	return seconds, weight, path_text, true
}

// frecency_compact drops the entries older than the window and replaces the
// log with one line per remaining entry.
@(private = "file")
frecency_compact :: proc(frecency: ^Frecency, log_path: string, now: i64) -> Error {
	stale := make([dynamic]string, frecency.allocator)
	defer delete(stale)
	for path, access in frecency.accesses {
		if now - access.time > frecency.window {
			append(&stale, path) or_return
		}
	}
	for path in stale {
		owned, _ := delete_key(&frecency.accesses, path)
		delete(owned, frecency.allocator)
	}

	compacted: strings.Builder
	strings.builder_init(&compacted, frecency.allocator) or_return
	defer strings.builder_destroy(&compacted)
	for path, access in frecency.accesses {
		weight_buffer: [32]byte
		weight_text := strconv.write_float(weight_buffer[:], access.weight, 'g', -1, 64)
		fmt.sbprintf(&compacted, "%d %s %s\n", access.time, strings.trim_prefix(weight_text, "+"), path)
	}

	temporary_path := strings.concatenate({log_path, ".tmp"}, frecency.allocator) or_return
	defer delete(temporary_path, frecency.allocator)
	write_error := os.write_entire_file(temporary_path, strings.to_string(compacted))
	if write_error == nil {
		write_error = os.rename(temporary_path, log_path)
	}
	if write_error != nil {
		_ = os.remove(temporary_path)
	}
	return write_error
}
