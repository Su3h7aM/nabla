package agent

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

import "nabla:search"

// Native find and grep tools: a thin adapter over the standalone search
// library. The adapter owns the harness concerns only: the tool definitions
// and their schemas, decoding, validating, and repairing arguments, the
// session's workspace index, and mapping library results into tool outputs.
// Matching, paging, and the typo-tolerant recovery live in search.
//
// Admission decodes arguments and resolves the root to an absolute path
// lexically. It touches no file, so the owner loop never waits on the
// filesystem; every check of the root and every scan runs on a worker thread.
// The session keeps one index, of the workspace, and
// a prewarm thread builds it at session start. Any other root is one-shot:
// the call builds an index, queries it, and destroys it before returning, so
// nothing is retained for it and its cursors never age.
//
// The workspace index is replaced only by a rescan at query time, when the
// root directory's mtime moved; the rescan bumps the generation, which is what
// makes earlier cursors stale. Scans hold no lock. Installing the first scan
// takes one short guard, and the first install wins, so a concurrent build
// never moves a generation under a live cursor.

// TOOL_SEARCH_DEFAULT_TIMEOUT applies when the model gives no timeout. There is no maximum.
TOOL_SEARCH_DEFAULT_TIMEOUT :: 60 * time.Second

// GREP_WINDOW_BYTES is how much of one overlong match line the result shows;
// a longer line is cut to a window around the hit, marked with … where bytes
// were cut. The bound keeps one match line inside the model's context window;
// the full lines are kept whole in the file full_lines_file names.
GREP_WINDOW_BYTES :: 180

// GREP_WINDOW_LEAD is how many bytes before the hit the window keeps, so the
// hit stays visible with its leading context; the rest of the window follows it.
GREP_WINDOW_LEAD :: 120

// GREP_LINES_SUFFIX follows the call's kept-output base in the name of the
// file holding a grep page's full match lines. It differs from the shell's
// kept-stream suffixes, which share the same base.
GREP_LINES_SUFFIX :: ".lines.txt"

// SEARCH_ROOT_EXPECTED is what the root field must hold.
SEARCH_ROOT_EXPECTED :: "an existing directory to search, as an absolute path or one relative to the workspace"

// SEARCH_GLOB_EXPECTED is what the glob field must hold.
SEARCH_GLOB_EXPECTED :: "a valid shell glob pattern"

// SEARCH_OUT_OF_MEMORY is the failure text of every search allocation failure.
SEARCH_OUT_OF_MEMORY :: "the search ran out of memory"

// --- workspace index ----------------------------------------------------------

// Search_Cache is the session's workspace index. root is the absolute
// workspace key and never changes, so it reads without the lock. home is nil
// until the first scan installs it and is read and written under the mutex.
// Only the query-time rescan mutates the installed index, on the native lane
// where native calls never run at once; queries borrow it. Everything is
// owned by allocator, the process heap, and released by search_cache_destroy
// at session close.
//
// frecency ranks the workspace's files by what the agent touched. It is
// memory-only until search_cache_frecency_open attaches a log, which happens
// once at session install before any worker runs. After that, workers record
// into it through its own mutex, and no cache lock is held across a record.
Search_Cache :: struct {
	mutex:     sync.Mutex,
	allocator: mem.Allocator,
	root:      string,
	home:      ^search.Index,
	prewarm:   ^thread.Thread, // nil until the session-start scan is launched
	frecency:  search.Frecency,
}

// search_cache_make returns the cache for the session whose workspace is
// workspace, with a memory-only frecency. The root key is the workspace
// cleaned lexically, the same form search_root_arg gives the workspace, so no
// file is touched. It performs no scan; the prewarm and the first query scan
// on worker threads. The caller owns the cache and destroys it with
// search_cache_destroy.
@(require_results)
search_cache_make :: proc(workspace: string, allocator: mem.Allocator) -> (cache: ^Search_Cache, err: mem.Allocator_Error) {
	made := new(Search_Cache, allocator) or_return
	made.allocator = allocator
	clean_error: mem.Allocator_Error
	made.root, clean_error = filepath.clean(workspace, allocator)
	if clean_error != nil {
		free(made, allocator)
		return nil, clean_error
	}
	// A memory-only open allocates a map header and does no I/O, so its only failure is the allocator's.
	if search.frecency_open(&made.frecency, "", 0, allocator) != nil {
		delete(made.root, allocator)
		free(made, allocator)
		return nil, .Out_Of_Memory
	}
	return made, nil
}

// SEARCH_FRECENCY_DIRECTORY_NAME is the directory, under the state directory,
// that holds one frecency log per workspace.
SEARCH_FRECENCY_DIRECTORY_NAME :: "frecency"

// search_frecency_directory resolves the directory that holds frecency logs:
// $XDG_STATE_HOME/nabla/frecency. It touches nothing on the filesystem and
// returns "" when no state directory resolves. The caller owns the result.
@(require_results)
search_frecency_directory :: proc(allocator := context.allocator) -> string {
	state, state_error := xdg_directory(.State, context.temp_allocator)
	if state_error != .None { return "" }
	directory, join_error := filepath.join({state, SEARCH_FRECENCY_DIRECTORY_NAME}, allocator)
	if join_error != nil { return "" }
	return directory
}

// search_cache_frecency_open replaces the cache's memory-only frecency with
// one backed by this workspace's log in directory, named by the fnv64a of the
// absolute workspace path so each workspace has its own. It creates directory
// and its parents, replays the log, and compacts it. On error the cache keeps
// its memory-only frecency. now is unix seconds. The owner calls it once, at
// session install, before any worker can reach the cache.
search_cache_frecency_open :: proc(cache: ^Search_Cache, directory: string, now: i64) -> search.Error {
	if make_error := os.make_directory_all(directory, XDG_APP_PERMISSIONS); make_error != nil && make_error != .Exist {
		return make_error
	}
	name := fmt.tprintf("%016x.log", hash.fnv64a(transmute([]byte)cache.root))
	log_path, join_error := filepath.join({directory, name}, context.temp_allocator)
	if join_error != nil {
		return join_error
	}
	opened: search.Frecency
	search.frecency_open(&opened, log_path, now, cache.allocator) or_return
	search.frecency_destroy(&cache.frecency)
	cache.frecency = opened
	return nil
}

// search_path_resolve returns path as a cleaned absolute path owned by
// allocator: path itself when absolute, otherwise path under workspace. It is
// purely lexical and does no I/O, so it is safe on the owner loop; symbolic
// links are not resolved and a missing path is not an error.
@(require_results)
search_path_resolve :: proc(workspace, path: string, allocator: mem.Allocator) -> (resolved: string, err: mem.Allocator_Error) {
	if filepath.is_abs(path) {
		return filepath.clean(path, allocator)
	}
	return filepath.join({workspace, path}, allocator)
}

// search_record_access counts the agent's touch of path (a read, edit, or
// write that succeeded) toward ranking, when path is inside the workspace
// root. The path is resolved lexically to an absolute one first, so it does no
// I/O. The ranking is not critical, so every failure is ignored. Safe from any
// thread and holds no lock of its own.
search_record_access :: proc(ctx: ^Tool_Context, path: string) {
	cache := ctx.search
	if cache == nil { return }
	absolute, abs_error := search_path_resolve(ctx.workspace, path, ctx.allocator)
	if abs_error != nil { return }
	defer delete(absolute, ctx.allocator)
	root := cache.root
	inside := strings.has_prefix(absolute, root) && len(absolute) > len(root) && (absolute[len(root)] == '/' || strings.has_suffix(root, "/"))
	if !inside { return }
	_ = search.frecency_record(&cache.frecency, absolute, time.to_unix_seconds(time.now()))
}

// search_cache_destroy releases the index and everything it holds. It joins
// the prewarm thread first, because that thread touches only this cache. Only
// the owner calls it, at session close once no worker can still reach the
// cache.
search_cache_destroy :: proc(cache: ^Search_Cache) {
	if cache == nil { return }
	allocator := cache.allocator
	if cache.prewarm != nil {
		thread.join(cache.prewarm)
		context.allocator = allocator
		thread.destroy(cache.prewarm)
	}
	if cache.home != nil {
		search.index_destroy(cache.home)
		free(cache.home, allocator)
	}
	search.frecency_destroy(&cache.frecency)
	delete(cache.root, allocator)
	free(cache, allocator)
}

// search_cache_ensure returns the workspace index, scanning the root when none
// is installed. The scan runs with no lock held; only the install takes the
// guard, and the first install wins, so concurrent callers race safely and a
// later call reuses the index without rescanning. A root that cannot be
// indexed fails with the library error and installs nothing. Safe from any
// thread, and in particular from query workers, where blocking I/O is allowed.
@(require_results)
search_cache_ensure :: proc(cache: ^Search_Cache) -> (home: ^search.Index, err: search.Error) {
	{
		sync.guard(&cache.mutex)
		if cache.home != nil {
			return cache.home, nil
		}
	}
	made := search.index_make(cache.root, cache.allocator) or_return
	slot, slot_error := new(search.Index, cache.allocator)
	if slot_error != nil {
		search.index_destroy(&made)
		return nil, slot_error
	}
	slot^ = made
	{
		sync.guard(&cache.mutex)
		if cache.home == nil {
			cache.home = slot
			return slot, nil
		}
		home = cache.home
	}
	// A concurrent caller installed first; its index stays, so no live cursor ages.
	search.index_destroy(slot)
	free(slot, cache.allocator)
	return home, nil
}

// search_cache_prewarm starts one background scan of the workspace and returns
// at once, so the owner waits on nothing. An installed index or a scan already
// launched means there is nothing to do. A launch that fails leaves nothing
// behind; the first query builds the index anyway. Only the owner calls it,
// once per session from the front-end's install path, never per query, and
// never from two threads at once. The thread is created and started with no
// lock held; the mutex covers only the check and the install of the handle.
search_cache_prewarm :: proc(cache: ^Search_Cache) {
	if cache == nil { return }
	{
		sync.guard(&cache.mutex)
		if cache.prewarm != nil || cache.home != nil { return }
	}
	previous := chat_signal_block_watched()
	worker: ^thread.Thread
	{
		context.allocator = os.heap_allocator()
		worker = thread.create(search_prewarm_thread, name = "nabla-search-prewarm")
	}
	chat_signal_restore(previous)
	if worker == nil { return }
	worker.data = cache
	thread.start(worker)
	sync.guard(&cache.mutex)
	cache.prewarm = worker
}

// search_prewarm_thread scans the workspace and installs it, then exits. It
// touches only the cache, which outlives it: session close joins it before
// destroying anything it could reach.
search_prewarm_thread :: proc(worker: ^thread.Thread) {
	cache := (^Search_Cache)(worker.data)
	context.allocator = cache.allocator
	_, _ = search_cache_ensure(cache)
}

// search_index_acquire returns the index one call searches. The workspace
// root borrows the session's index, rescanned first when the root directory's
// mtime moved. Any other root, and a nil cache, is scanned into scratch for
// this call alone; the caller destroys scratch with search.index_destroy
// whether or not it was used. A root that cannot be indexed fails with the
// library error and builds nothing. It runs on the worker thread, where
// blocking I/O is allowed, never on the owner loop.
@(require_results)
search_index_acquire :: proc(ctx: ^Tool_Context, root_key: string, scratch: ^search.Index) -> (index: ^search.Index, err: search.Error) {
	cache := ctx.search
	if cache == nil || root_key != cache.root {
		scratch^ = search.index_make(root_key, ctx.allocator) or_return
		return scratch, nil
	}
	index = search_cache_ensure(cache) or_return
	// A rescan that cannot run keeps the list; the query still runs.
	_, _ = search.index_refresh_if_stale(index)
	return index, nil
}

// search_frecency_of returns the frecency one call ranks with: the session's
// for the workspace root, nil for any other root and for a nil cache.
@(require_results)
search_frecency_of :: proc(ctx: ^Tool_Context, root_key: string) -> ^search.Frecency {
	cache := ctx.search
	if cache == nil || root_key != cache.root { return nil }
	return &cache.frecency
}

// --- find --------------------------------------------------------------------

TOOL_FIND_NAME :: "find"

TOOL_FIND_DESCRIPTION :: `Find files by path substring in the workspace or in any other directory (root). Use grep to search file contents and read to view a file. Several words must all occur in the path. Hidden directories and node_modules, target, and __pycache__ are not searched; hidden files are.

The result gives total_matches and, when rows remain, next_cursor (pass it as cursor for the next page). After a blank line come the paths, best first, under a "→ Read" header naming the top path, marked "(exact match!)" when it names the query exactly. skipped counts files that could not be read, and denylist counts the pruned directories. When no path contains the query, a typo-tolerant search runs and notice labels its rows as approximate; a query nothing resembles returns total_matches 0 with no notice.

The workspace file list is kept between calls and rescanned when the workspace directory's modification time moves, so a file created below its top level can be missing until then, and a cursor issued before a rescan is refused as stale; rerun without it. Any other root, including a subdirectory of the workspace, is scanned afresh on every call. The timeout defaults to 60 seconds and is checked when the search returns; a late result reports the timeout and still shows its rows.`

TOOL_FIND_SCHEMA ::
	`{"type":"object","properties":{` +
	`"query":{"type":"string","description":"Words to look for in paths relative to the searched directory. Every word must occur in the path; a word with an uppercase letter matches case-sensitively, any other word ignores case."},` +
	`"pattern":{"type":["string","null"],"description":"Alias of query; query wins when both are given. Leave out or pass null when query is given."},` +
	`"glob":{"type":["string","null"],"description":"Shell pattern a path must match, tried against the path then its base name. Leave out or pass null for no filter."},` +
	`"root":{"type":["string","null"],"description":"Directory to search, absolute or relative to the workspace. Leave out or pass null for the workspace itself."},` +
	`"cursor":{"type":["string","null"],"description":"Opaque cursor from a previous find or grep result's next_cursor. Leave out or pass null to start from the first match."},` +
	`"limit":{"type":["integer","null"],"description":"Maximum matches to return. Leave out, pass 0, or pass a negative number for every match."},` +
	`"timeout_ms":{"type":["integer","null"],"description":"Positive timeout in milliseconds, with no maximum. Leave out or pass null for the default the tool description states."}},"required":["query"],"additionalProperties":false}`

TOOL_FIND_FIELDS :: []string{"query", "pattern", "glob", "root", "cursor", "limit", "timeout_ms"}

TOOL_FIND_DEFINITION :: Tool_Definition {
	name = TOOL_FIND_NAME,
	description = TOOL_FIND_DESCRIPTION,
	input_schema = TOOL_FIND_SCHEMA,
	hints = {read_only = .Yes, destructive = .No, idempotent = .Yes, open_world = .No},
	placement = .Worker,
	timeout = TOOL_SEARCH_DEFAULT_TIMEOUT,
	kind = .Find,
	execute = tool_find_execute,
}

// --- grep --------------------------------------------------------------------

TOOL_GREP_NAME :: "grep"

TOOL_GREP_DESCRIPTION :: `Search file contents line by line in the workspace or in any other directory (root). Use find to locate a file by name and read to view a file. Hidden directories and node_modules, target, and __pycache__ are not searched; hidden files are.

The result gives total_matches and, when rows remain, next_cursor (pass it as cursor for the next page). After a blank line come the matches grouped by file under a "→ Read" header naming the best file: an "N: text" row per hit, an " N-text" row per context line, and "--" between files. output_mode "files_with_matches" lists one path per file instead. A line longer than 180 bytes is shown cut around the hit with … marking the cuts, and full_lines_in names the file holding the full lines. skipped counts binary, oversize, and unreadable files, and denylist counts the pruned directories. When no line matches exactly, a typo-tolerant search runs and notice labels its rows as approximate; a pattern nothing resembles returns total_matches 0 with no notice. An invalid regular expression is searched literally and notice says so.

The workspace file list is kept between calls and rescanned when the workspace directory's modification time moves, so a file created below its top level can be missing until then, and a cursor issued before a rescan is refused as stale; rerun without it. Any other root, including a subdirectory of the workspace, is scanned afresh on every call. The timeout defaults to 60 seconds and is checked when the search returns; a late result reports the timeout and still shows its rows.`

TOOL_GREP_SCHEMA ::
	`{"type":"object","properties":{` +
	`"pattern":{"type":"string","description":"Text to look for in each line: a literal substring in plain mode, a regular expression in regex mode."},` +
	`"mode":{"type":["string","null"],"description":"\"plain\" for a literal substring, \"regex\" for a regular expression. Leave out or pass null for \"plain\"."},` +
	`"case":{"type":["string","null"],"description":"\"smart\" folds case unless the pattern holds an uppercase letter, \"sensitive\" always matches case, \"insensitive\" always folds. Leave out or pass null for \"smart\"."},` +
	`"output_mode":{"type":["string","null"],"description":"\"content\" for one row per hit, \"files_with_matches\" for one path per file with a hit. Leave out or pass null for \"content\"."},` +
	`"glob":{"type":["string","null"],"description":"Shell pattern a path must match, tried against the path then its base name. Leave out or pass null for no filter."},` +
	`"root":{"type":["string","null"],"description":"Directory to search, absolute or relative to the workspace. Leave out or pass null for the workspace itself."},` +
	`"context":{"type":["integer","null"],"description":"Lines of context around each hit. Default: 0."},` +
	`"cursor":{"type":["string","null"],"description":"Opaque cursor from a previous find or grep result's next_cursor. Leave out or pass null to start from the first match."},` +
	`"limit":{"type":["integer","null"],"description":"Maximum matches to return. Leave out, pass 0, or pass a negative number for every match."},` +
	`"timeout_ms":{"type":["integer","null"],"description":"Positive timeout in milliseconds, with no maximum. Leave out or pass null for the default the tool description states."}},"required":["pattern"],"additionalProperties":false}`

TOOL_GREP_FIELDS :: []string{"pattern", "mode", "case", "output_mode", "glob", "root", "context", "cursor", "limit", "timeout_ms"}

TOOL_GREP_DEFINITION :: Tool_Definition {
	name = TOOL_GREP_NAME,
	description = TOOL_GREP_DESCRIPTION,
	input_schema = TOOL_GREP_SCHEMA,
	hints = {read_only = .Yes, destructive = .No, idempotent = .Yes, open_world = .No},
	placement = .Worker,
	timeout = TOOL_SEARCH_DEFAULT_TIMEOUT,
	kind = .Grep,
	execute = tool_grep_execute,
}

// Find_Args is one find call. query, glob, and cursor borrow the admitted
// document; root_key is the absolute search root owned by the caller's
// allocator. limit at or below zero means every match.
Find_Args :: struct {
	query:    string,
	glob:     string,
	root_key: string,
	cursor:   string,
	limit:    int,
	timeout:  time.Duration,
}

// Grep_Args is one grep call. pattern, glob, and cursor borrow the admitted
// document; root_key is the absolute search root owned by the caller's
// allocator. mode, sensitivity, and output select the library query shape;
// limit at or below zero means every match.
Grep_Args :: struct {
	pattern:       string,
	mode:          search.Grep_Mode,
	sensitivity:   search.Grep_Case,
	output:        search.Grep_Output_Mode,
	glob:          string,
	root_key:      string,
	cursor:        string,
	context_lines: int,
	limit:         int,
	timeout:       time.Duration,
}

// Find_Output is one find result. next_cursor is "" when no rows remain and
// notice carries the labeled recovery, if any. files holds one path relative
// to the searched root per row, in the page order the body shows. indexed is
// how many files the searched index holds.
Find_Output :: struct {
	total_matches: int,
	skipped:       search.Skip_Breakdown,
	next_cursor:   string,
	notice:        string,
	files:         []string,
	indexed:       int,
	exact_match:   bool,
}

// Grep_Output is one grep result. next_cursor is "" when no rows remain and
// notice carries the labeled recovery or regex repair, if any. matches holds
// the page's content rows with files empty, or files holds one path per file
// with a hit with matches empty, by output mode. full_lines_file names the
// kept file holding the page's full match lines when overlong lines were
// windowed for display, or "" when nothing was windowed.
Grep_Output :: struct {
	total_matches:   int,
	skipped:         search.Skip_Breakdown,
	next_cursor:     string,
	notice:          string,
	matches:         []search.Grep_Match,
	files:           []string,
	full_lines_file: string,
}

// tool_find_args reads a find call's arguments. pattern is an accepted alias
// of query: it stands in for a blank query, and is ignored beside a usable
// one, and either use is recorded as a repair so the result reports it.
// Admission resolves the root key and reads fields only: it performs no scan,
// so the owner loop never blocks on a filesystem walk. A timeout the model
// gives is honored as given; otherwise the definition's default applies.
@(require_results)
tool_find_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Find_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_FIND_FIELDS, allocator = ctx.allocator) or_return
	query := tool_field_optional_string(arguments, "query", allocator = ctx.allocator) or_return
	alias := tool_field_optional_string(arguments, "pattern", allocator = ctx.allocator) or_return
	if query == "" && alias == "" {
		return {}, tool_argument_error(.Missing_Field, "query", allocator = ctx.allocator)
	}
	args.query = query
	if strings.trim_space(query) == "" {
		args.query = alias
	}
	if strings.trim_space(args.query) == "" {
		return {}, tool_argument_error(.Invalid_Value, "query", "a non-empty substring to look for", ctx.allocator)
	}
	if alias != "" {
		ctx.repairs += {.Field_Alias}
	}
	args.glob = search_glob_arg(ctx, arguments) or_return
	args.root_key = search_root_arg(ctx, arguments) or_return
	args.cursor = tool_field_optional_string(arguments, "cursor", allocator = ctx.allocator) or_return
	args.limit = tool_field_optional_int(arguments, "limit", 0, min(int), max(int), &ctx.repairs, allocator = ctx.allocator) or_return
	args.timeout = tool_web_timeout(ctx, arguments) or_return
	return
}

// tool_grep_args reads a grep call's arguments. Only the empty pattern is
// refused; whitespace is text to look for. Admission resolves the root key and
// reads fields only: it performs no scan, so the owner loop never blocks on a
// filesystem walk. A timeout the model gives is honored as given; otherwise
// the definition's default applies.
@(require_results)
tool_grep_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Grep_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_GREP_FIELDS, allocator = ctx.allocator) or_return
	args.pattern = tool_field_string(arguments, "pattern", allocator = ctx.allocator) or_return
	if args.pattern == "" {
		return {}, tool_argument_error(.Invalid_Value, "pattern", "non-empty text to look for", ctx.allocator)
	}
	args.mode = search_mode_arg(arguments, ctx.allocator) or_return
	args.sensitivity = search_case_arg(arguments, ctx.allocator) or_return
	args.output = search_output_mode_arg(arguments, ctx.allocator) or_return
	args.glob = search_glob_arg(ctx, arguments) or_return
	args.root_key = search_root_arg(ctx, arguments) or_return
	args.context_lines = tool_field_optional_int(arguments, "context", 0, 0, max(int), &ctx.repairs, allocator = ctx.allocator) or_return
	args.cursor = tool_field_optional_string(arguments, "cursor", allocator = ctx.allocator) or_return
	args.limit = tool_field_optional_int(arguments, "limit", 0, min(int), max(int), &ctx.repairs, allocator = ctx.allocator) or_return
	args.timeout = tool_web_timeout(ctx, arguments) or_return
	return
}

// search_mode_arg reads the grep mode field: plain by default, regex on
// request. Matching is case-insensitive, so "Regex" reads as regex.
@(require_results)
search_mode_arg :: proc(arguments: json.Object, allocator: mem.Allocator) -> (mode: search.Grep_Mode, err: Tool_Argument_Error) {
	text := tool_field_optional_string(arguments, "mode", allocator = allocator) or_return
	if text == "" || strings.equal_fold(text, "plain") {
		return .Plain, nil
	}
	if strings.equal_fold(text, "regex") {
		return .Regex, nil
	}
	return .Plain, tool_argument_error(.Invalid_Value, "mode", `"plain" or "regex"`, allocator)
}

// search_case_arg reads the grep case field: smart by default. Matching is
// case-insensitive, so "Smart" reads as smart.
@(require_results)
search_case_arg :: proc(arguments: json.Object, allocator: mem.Allocator) -> (sensitivity: search.Grep_Case, err: Tool_Argument_Error) {
	text := tool_field_optional_string(arguments, "case", allocator = allocator) or_return
	if text == "" || strings.equal_fold(text, "smart") {
		return .Smart, nil
	}
	if strings.equal_fold(text, "sensitive") {
		return .Sensitive, nil
	}
	if strings.equal_fold(text, "insensitive") {
		return .Insensitive, nil
	}
	return .Smart, tool_argument_error(.Invalid_Value, "case", `"smart", "sensitive", or "insensitive"`, allocator)
}

// search_output_mode_arg reads the grep output_mode field: content rows by
// default, one path per file on request. Matching is case-insensitive.
@(require_results)
search_output_mode_arg :: proc(arguments: json.Object, allocator: mem.Allocator) -> (output: search.Grep_Output_Mode, err: Tool_Argument_Error) {
	text := tool_field_optional_string(arguments, "output_mode", allocator = allocator) or_return
	if text == "" || strings.equal_fold(text, "content") {
		return .Content, nil
	}
	if strings.equal_fold(text, "files_with_matches") {
		return .Files_With_Matches, nil
	}
	return .Content, tool_argument_error(.Invalid_Value, "output_mode", `"content" or "files_with_matches"`, allocator)
}


// search_glob_arg reads the glob field and refuses one the matcher cannot
// read, so a malformed pattern is feedback before the query rather than a
// silent empty result. The borrowed string lives as long as the document.
@(require_results)
search_glob_arg :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (glob: string, err: Tool_Argument_Error) {
	glob = tool_field_optional_string(arguments, "glob", allocator = ctx.allocator) or_return
	if !search.glob_valid(glob) {
		return "", tool_argument_error(.Invalid_Value, "glob", SEARCH_GLOB_EXPECTED, ctx.allocator)
	}
	return glob, nil
}

// search_root_arg reads the root field as a cleaned absolute key owned by the
// caller's allocator. An absent or null root is the workspace and a relative
// root starts at the workspace; an absolute root may name any directory. The
// key is lexical, so decoding does no I/O on the owner loop and checks
// nothing: the worker indexes the root at execute time, where a missing or
// non-directory root is refused as the root field.
@(require_results)
search_root_arg :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (key: string, err: Tool_Argument_Error) {
	root := tool_field_optional_string(arguments, "root", allocator = ctx.allocator) or_return
	resolved, resolve_error := search_path_resolve(ctx.workspace, root, ctx.allocator)
	if resolve_error != nil {
		return "", Tool_Argument_Defect{kind = .Out_Of_Memory}
	}
	return resolved, nil
}

// search_root_refused refuses a call whose root cannot be indexed, naming the
// field and what it must hold. Nothing ran.
@(require_results)
search_root_refused :: proc(ctx: ^Tool_Context) -> Tool_Result {
	err := tool_argument_error(.Invalid_Value, "root", SEARCH_ROOT_EXPECTED, ctx.allocator)
	return tool_result_refused(ctx, &err)
}

// search_out_of_memory answers a call that ran out of memory. Nothing was reported.
@(require_results)
search_out_of_memory :: proc(ctx: ^Tool_Context) -> Tool_Result {
	return tool_result_failure(ctx, .Tool_Failed, SEARCH_OUT_OF_MEMORY, "out of memory")
}

// search_index_refused maps an index failure to its answer: a root that is
// not an existing directory is refused as the root field, naming what was
// expected, and anything else fails the call. Nothing ran.
@(require_results)
search_index_refused :: proc(ctx: ^Tool_Context, err: search.Error) -> Tool_Result {
	switch value in err {
	case search.Error_Code:
		if value == .Not_Directory {
			return search_root_refused(ctx)
		}
		return tool_result_failure(ctx, .Tool_Failed, fmt.tprintf("the search index could not be built: %s", search.error_message(err)), "search failed")
	case mem.Allocator_Error:
		return search_out_of_memory(ctx)
	case os.Error:
		return search_root_refused(ctx)
	}
	return tool_result_failure(ctx, .Tool_Failed, "the search index could not be built", "search failed")
}

// search_query_refused maps a query failure to its answer: a malformed cursor
// and a cursor from another root are refused as the cursor field, naming what
// was expected and what arrived, and a cursor from before the latest rescan
// is refused as stale, naming the current generation. The library also
// refuses a malformed glob, which decode already refused. Nothing ran.
@(require_results)
search_query_refused :: proc(ctx: ^Tool_Context, err: search.Error, cursor: string, generation: int) -> Tool_Result {
	switch value in err {
	case search.Error_Code:
		switch value {
		case .Invalid_Cursor:
			defect := tool_argument_error(
				.Invalid_Value,
				"cursor",
				fmt.tprintf(`an opaque cursor exactly as a previous find or grep result returned it (received %q)`, cursor),
				ctx.allocator,
			)
			return tool_result_refused(ctx, &defect)
		case .Stale_Cursor:
			defect := tool_argument_error(
				.Invalid_Value,
				"cursor",
				fmt.tprintf(
					"a cursor from the current search generation %d for this root; the index was rebuilt, so rerun without cursor (received %q)",
					generation,
					cursor,
				),
				ctx.allocator,
			)
			return tool_result_refused(ctx, &defect)
		case .Invalid_Glob:
			defect := tool_argument_error(.Invalid_Value, "glob", SEARCH_GLOB_EXPECTED, ctx.allocator)
			return tool_result_refused(ctx, &defect)
		case .Not_Directory:
			return search_root_refused(ctx)
		}
	case mem.Allocator_Error:
		return search_out_of_memory(ctx)
	case os.Error:
		return tool_result_failure(ctx, .Tool_Failed, fmt.tprintf("the search could not run: %s", search.error_message(err)), "search failed")
	}
	return tool_result_failure(ctx, .Tool_Failed, "the search could not run", "search failed")
}

// search_result_finish answers a finished search with its rows. The search
// library has no interrupt, so cancellation and the timeout are observed only
// after it returns: a stopped call still reports the rows it found. tool names
// the call in the stop message, and output is borrowed.
@(require_results)
search_result_finish :: proc(ctx: ^Tool_Context, tool: string, start: time.Tick, timeout: time.Duration, output: Tool_Output, summary: string) -> Tool_Result {
	#partial switch tool_control_stop(ctx.control, start, timeout) {
	case .Cancelled:
		return tool_result_of(ctx, .Cancelled, fmt.tprintf("the %s was cancelled; showing %s", tool, summary), output, "stopped")
	case .Timed_Out:
		return tool_result_of(ctx, .Timed_Out, fmt.tprintf("the %s timed out; showing %s", tool, summary), output, "stopped")
	}
	return tool_result_success(ctx, output, summary)
}

// tool_find_execute runs one find call and answers with its rows. The
// workspace root searches the session's index; any other root is scanned for
// this call alone. Zero exact hits carries the library's labeled recovery in
// notice; anything the library reports is refused or failed with nothing run.
@(require_results)
tool_find_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(Find_Args)
	heap := ctx.allocator
	start := time.tick_now()

	scratch: search.Index
	defer search.index_destroy(&scratch)
	index, index_error := search_index_acquire(ctx, args.root_key, &scratch)
	if index_error != nil {
		return search_index_refused(ctx, index_error)
	}

	library, query_error := search.find(
		index,
		search.Find_Query {
			query = args.query,
			glob = args.glob,
			cursor = args.cursor,
			limit = args.limit,
			frecency = search_frecency_of(ctx, args.root_key),
			now = time.to_unix_seconds(time.now()),
		},
		heap,
	)
	if query_error != nil {
		return search_query_refused(ctx, query_error, args.cursor, index.generation)
	}
	output := Find_Output {
		total_matches = library.total,
		skipped       = library.skipped,
		next_cursor   = library.next_cursor,
		notice        = library.notice,
		files         = library.files,
		indexed       = len(index.files),
		exact_match   = find_exact_match(library.files, args.query),
	}
	defer {
		owned: Tool_Output = output
		tool_output_destroy(&owned, heap)
	}
	return search_result_finish(ctx, "find", start, args.timeout, output, find_summary(len(output.files), output.total_matches, output.indexed))
}

// find_summary is the short line a find result carries: an empty result names
// the indexed count so zero is a fact, and a page leads with its counts.
@(require_results)
find_summary :: proc(shown, total, indexed: int) -> string {
	if total == 0 {
		return fmt.tprintf("0 results (%d indexed)", indexed)
	}
	return fmt.tprintf("%d of %d paths", shown, total)
}

// find_exact_match reports whether the top find row names the query exactly:
// the whole root-relative path or its base name, case-insensitively. The
// header calls that row an exact match; any other top row is a best match.
@(require_results)
find_exact_match :: proc(files: []string, query: string) -> bool {
	if len(files) == 0 {
		return false
	}
	if strings.equal_fold(files[0], query) {
		return true
	}
	return strings.equal_fold(filepath.base(files[0]), query)
}

// tool_grep_execute runs one grep call and answers with its rows. The
// workspace root searches the session's index; any other root is scanned for
// this call alone. Zero exact hits carries the library's labeled recovery in
// notice, and an invalid regular expression carries its literal repair there
// instead; anything the library reports is refused or failed with nothing run.
//
// An overlong match line is windowed for display and its full line kept in a
// file the result names: see grep_window_long_lines.
@(require_results)
tool_grep_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(Grep_Args)
	heap := ctx.allocator
	start := time.tick_now()

	scratch: search.Index
	defer search.index_destroy(&scratch)
	index, index_error := search_index_acquire(ctx, args.root_key, &scratch)
	if index_error != nil {
		return search_index_refused(ctx, index_error)
	}

	library, query_error := search.grep(
		index,
		search.Grep_Query {
			pattern = args.pattern,
			mode = args.mode,
			sensitivity = args.sensitivity,
			glob = args.glob,
			context_lines = args.context_lines,
			output = args.output,
			cursor = args.cursor,
			limit = args.limit,
			frecency = search_frecency_of(ctx, args.root_key),
			now = time.to_unix_seconds(time.now()),
		},
		heap,
	)
	if query_error != nil {
		return search_query_refused(ctx, query_error, args.cursor, index.generation)
	}
	output := Grep_Output {
		total_matches = library.total,
		skipped       = library.skipped,
		next_cursor   = library.next_cursor,
		notice        = library.notice,
		matches       = library.matches,
		files         = library.files,
	}
	defer {
		owned: Tool_Output = output
		tool_output_destroy(&owned, heap)
	}

	grep_window_long_lines(ctx, &output)

	unit := "files" if args.output == .Files_With_Matches else "matches"
	shown := len(output.matches) + len(output.files)
	return search_result_finish(ctx, "grep", start, args.timeout, output, grep_summary(shown, output.total_matches, unit))
}

// grep_summary is the short line a grep result carries: an empty result reads
// as its zero count, and a page leads with its counts.
@(require_results)
grep_summary :: proc(shown, total: int, unit: string) -> string {
	if total == 0 {
		return "0 matches"
	}
	return fmt.tprintf("%d of %d %s", shown, total, unit)
}

// grep_needs_window reports whether any page row runs past the display
// window, which is when the page needs its full lines kept beside it.
@(private, require_results)
grep_needs_window :: proc(matches: []search.Grep_Match) -> bool {
	for match in matches {
		if len(match.text) > GREP_WINDOW_BYTES {
			return true
		}
	}
	return false
}

// grep_window_line cuts text to a window of GREP_WINDOW_BYTES around col,
// marked with … where bytes were cut. col is the 1-based byte column of the
// hit, 0 for a context line, which windows from the line start. Short lines
// come back whole. Cuts land on rune boundaries, so the window stays valid
// UTF-8. The caller owns the result with allocator.
@(private, require_results)
grep_window_line :: proc(text: string, col: int, allocator: mem.Allocator) -> (windowed: string, err: mem.Allocator_Error) {
	if len(text) <= GREP_WINDOW_BYTES {
		return strings.clone(text, allocator)
	}
	start := 0
	if col > 0 {
		// Up to GREP_WINDOW_LEAD bytes of leading context keep the hit in
		// view; the rest of the window follows it.
		start = clamp(col - 1 - GREP_WINDOW_LEAD, 0, len(text) - GREP_WINDOW_BYTES)
	}
	end := start + GREP_WINDOW_BYTES
	for start > 0 && !utf8.rune_start(text[start]) {
		start -= 1
	}
	for end < len(text) && !utf8.rune_start(text[end]) {
		end += 1
	}
	head := "…" if start > 0 else ""
	tail := "…" if end < len(text) else ""
	return strings.concatenate({head, text[start:end], tail}, allocator)
}

// grep_window_long_lines keeps the page's full match lines in the kept-output
// file and windows the overlong rows for display, naming the file in output.
// When no row is overlong, when no kept-output base exists, or when the keep
// fails, the rows stay whole and no file is named: a windowed row always has
// its full line behind full_lines_file. Only content rows carry text; files
// mode has none to window.
@(private)
grep_window_long_lines :: proc(ctx: ^Tool_Context, output: ^Grep_Output) {
	if len(output.matches) == 0 || !grep_needs_window(output.matches) {
		return
	}
	if ctx.output_base == "" {
		return
	}
	heap := ctx.allocator
	view: Tool_Output = output^
	full, full_error := tool_result_render(.Success, "", view, heap)
	if full_error != nil {
		return
	}
	defer delete(full, heap)
	path, path_error := strings.concatenate({ctx.output_base, GREP_LINES_SUFFIX}, heap)
	if path_error != nil {
		return
	}
	if tool_output_write(path, full) != nil {
		delete(path, heap)
		return
	}
	for &match in output.matches {
		if len(match.text) <= GREP_WINDOW_BYTES {
			continue
		}
		windowed, window_error := grep_window_line(match.text, match.col, heap)
		if window_error != nil {
			// The row stays whole; its full line is still in the file.
			continue
		}
		delete(match.text, heap)
		match.text = windowed
	}
	output.full_lines_file = path
}
