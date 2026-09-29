package agent

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:time"

import "nabla:ai"
import "nabla:http/client"

// The models.dev catalog is one enrichment source: it states providers and the
// models they serve. It is fetched once and cached, and it stays a source record
// -- resolving it into the runtime's catalog is a separate step that consumes it
// alongside user configuration and provider discovery. Nothing here interprets
// the body.

// MODELS_DEV_URL is the models.dev API representation: provider records with the models
// they serve, which is what this harness consumes. The catalog representation adds a
// model registry this harness never reads.
MODELS_DEV_URL :: "https://models.dev/api.json"
MODELS_DEV_CACHE_FILE :: "models-dev-api.json"

// A cached catalog is used for a day before it is refreshed. A stale copy is a
// normal input rather than an error, so a refresh that fails keeps serving it:
// the catalog changes when providers add or retire models, not between requests.
MODELS_DEV_FRESH :: 24 * time.Hour
MODELS_DEV_TIMEOUT :: 60 * time.Second

Models_Dev_Error :: enum {
	None,
	// The cache directory could not be resolved or created. Cache-only reads report
	// this; catalog acquisition still uses the network without reading or writing cache.
	Cache_Directory,
	// The document is neither cached nor reachable.
	Unavailable,
	// The document was acquired but is not a usable provider document, and no
	// cached copy could serve instead.
	Invalid_Data,
	// A provider source record could not be built because an allocation failed.
	Allocation,
	// A document was acquired but cannot become provider source records.
	Invalid_JSON,
	Invalid_Structure,
	Missing_Identity,
}

// Models_Dev_Fetch delivers a catalog body owned by the caller. Production uses
// models_dev_fetch; a test supplies its own, which is how the cache policy is
// exercised without the network.
Models_Dev_Fetch :: #type proc(user_data: rawptr, allocator: mem.Allocator) -> ([]u8, bool)

// models_dev_catalog returns the catalog, preferring a fresh cache that can answer a
// request for `providers` and refreshing it otherwise. A refresh that fails leaves the
// cached copy in place, so a network problem degrades to stale metadata, never to none.
// The returned body is owned by the caller.
@(require_results)
models_dev_catalog :: proc(
	fetch: Models_Dev_Fetch = models_dev_fetch,
	user_data: rawptr = nil,
	providers: []string = {},
	allocator := context.allocator,
) -> (
	[]u8,
	Models_Dev_Error,
) {
	return models_dev_catalog_at(time.now(), fetch, user_data, providers, allocator)
}

// models_dev_catalog_at is the same policy against an explicit clock, so the
// freshness window is testable without waiting for it or forging file times.
@(require_results)
models_dev_catalog_at :: proc(
	now: time.Time,
	fetch: Models_Dev_Fetch,
	user_data: rawptr,
	providers: []string,
	allocator: mem.Allocator,
) -> (
	[]u8,
	Models_Dev_Error,
) {
	path, path_err := models_dev_cache_path(allocator)
	path_ok := path_err == .None
	defer if path_ok { delete(path, allocator) }
	unusable := false
	if path_ok && models_dev_cache_fresh(path, now) {
		if cached, cached_ok := models_dev_cache_read(path, allocator); cached_ok {
			if models_dev_cache_answers(cached, providers) { return cached, .None }
			delete(cached, allocator)
		}
		// An unreadable cache counts as absent, and so does one that answers nothing
		// for these providers: the refresh below replaces either.
	}
	if body, fetched := fetch(user_data, allocator); fetched {
		if models_dev_validate(body) {
			// Caching is best effort. A document already in hand is a usable source,
			// so a write that fails is not a failed acquisition.
			if path_ok { _ = models_dev_cache_write(path, body) }
			return body, .None
		}
		// An acquired but unusable document never becomes the cache: replacing a
		// usable one with it would deny enrichment for a whole refresh window. It is
		// remembered only as the reason to report if the cache cannot serve either.
		delete(body, allocator)
		unusable = true
	}
	// The refresh failed or was unusable, so the cached copy -- stale or not -- is
	// the best source available, and it is still there because nothing removed it.
	if path_ok {
		if cached, cached_ok := models_dev_cache_read(path, allocator); cached_ok { return cached, .None }
	}
	if unusable { return nil, .Invalid_Data }
	return nil, .Unavailable
}

// models_dev_cache_answers reports whether a cached document can serve a request for these
// providers: it must parse and yield at least one provider source. An empty request asks for
// every provider.
@(require_results)
models_dev_cache_answers :: proc(body: []u8, providers: []string) -> bool {
	arena: virtual.Arena
	if arena_err := virtual.arena_init_growing(&arena); arena_err != nil { return false }
	defer virtual.arena_destroy(&arena)
	sources, parse_err := models_dev_parse(body, providers, virtual.arena_allocator(&arena))
	return parse_err == .None && len(sources) > 0
}

// models_dev_validate reports whether an acquired document is usable, which is
// what decides whether it may replace the cache. The tree and the source records
// it would produce both live in an arena released here, so the check costs one
// parse per refresh and leaves nothing resident.
@(require_results)
models_dev_validate :: proc(data: []u8) -> bool {
	arena: virtual.Arena
	if arena_err := virtual.arena_init_growing(&arena); arena_err != nil { return false }
	defer virtual.arena_destroy(&arena)
	_, err := models_dev_parse(data, {}, virtual.arena_allocator(&arena))
	return err == .None
}

// models_dev_cached_sources parses the last cached document without checking its
// age and never performs a network request. It is the startup path.
@(require_results)
models_dev_cached_sources :: proc(providers: []string = {}, allocator := context.allocator) -> ([dynamic]Catalog_Provider_Source, Models_Dev_Error) {
	path, path_err := models_dev_cache_path(allocator)
	if path_err != .None { return {}, path_err }
	defer delete(path, allocator)
	body, cached := models_dev_cache_read(path, allocator)
	if !cached { return {}, .Unavailable }
	defer delete(body, allocator)
	sources, parse_err := models_dev_parse(body, providers, allocator)
	switch parse_err {
	case .None:
		return sources, .None
	case .Allocation:
		return {}, .Allocation
	case .Invalid_JSON:
		return {}, .Invalid_JSON
	case .Invalid_Structure:
		return {}, .Invalid_Structure
	case .Missing_Identity:
		return {}, .Missing_Identity
	}
	return {}, .Invalid_Data
}

// models_dev_sources produces the resolver input from models.dev: the document is taken from
// the cache when it is fresh and acquired otherwise, then parsed into provider source records.
// `providers` restricts extraction to those provider ids. The result is owned by the caller
// and released with catalog_sources_destroy.
@(require_results)
models_dev_sources :: proc(
	fetch: Models_Dev_Fetch = models_dev_fetch,
	user_data: rawptr = nil,
	providers: []string = {},
	allocator := context.allocator,
) -> (
	[dynamic]Catalog_Provider_Source,
	Models_Dev_Error,
) {
	body, body_err := models_dev_catalog(fetch, user_data, providers, allocator)
	if body_err != .None { return {}, body_err }
	defer delete(body, allocator)

	sources, parse_err := models_dev_parse(body, providers, allocator)
	switch parse_err {
	case .None:
		return sources, .None
	case .Allocation:
		return {}, .Allocation
	case .Invalid_JSON:
		return {}, .Invalid_JSON
	case .Invalid_Structure:
		return {}, .Invalid_Structure
	case .Missing_Identity:
		return {}, .Missing_Identity
	}
	return {}, .Invalid_Data
}

// models_dev_cache_path resolves where the document is cached and creates the directory.
// The result is owned by the caller.
@(require_results)
models_dev_cache_path :: proc(allocator := context.allocator) -> (string, Models_Dev_Error) {
	directory, directory_err := xdg_directory(.Cache, allocator)
	if directory_err != .None { return "", .Cache_Directory }
	defer delete(directory, allocator)
	if create_err := xdg_directory_create(directory); create_err != .None { return "", .Cache_Directory }
	path, join_err := filepath.join([]string{directory, MODELS_DEV_CACHE_FILE}, allocator)
	if join_err != nil { return "", .Cache_Directory }
	return path, .None
}

// models_dev_cache_fresh reports whether a cached catalog is recent enough to
// use. A missing file, an unreadable timestamp, and a timestamp ahead of the
// clock are all stale, so a damaged cache is replaced rather than trusted.
@(require_results)
models_dev_cache_fresh :: proc(path: string, now: time.Time) -> bool {
	modified, err := os.modification_time_by_path(path)
	if err != nil { return false }
	age := time.diff(modified, now)
	return age >= 0 && age < MODELS_DEV_FRESH
}

// models_dev_cache_read returns a cached catalog when one is present and not
// empty. The result is owned by the caller.
@(require_results)
models_dev_cache_read :: proc(path: string, allocator: mem.Allocator) -> ([]u8, bool) {
	body, read_err := os.read_entire_file(path, allocator)
	if read_err == nil && len(body) > 0 { return body, true }
	if body != nil { delete(body, allocator) }
	return nil, false
}

// models_dev_cache_write publishes a catalog through a temporary file in the
// same directory and renames it into place, so the visible cache is always a
// complete catalog and a write that fails or is interrupted leaves the previous
// one untouched. The temporary name carries the process id, so two concurrent
// refreshes cannot write to the same file; the rename is what publishes.
models_dev_cache_write :: proc(path: string, body: []u8) -> bool {
	temporary := fmt.tprintf("%s.%d.tmp", path, os.get_pid())
	if os.write_entire_file(temporary, body) != nil { return false }
	if os.rename(temporary, path) != nil {
		// A temporary file that cannot be removed is left behind; only the cache matters.
		_ = os.remove(temporary)
		return false
	}
	return true
}

// models_dev_fetch performs the one request this source needs. It is deliberately
// thin: freshness, caching, and persistence are the caller's decisions, so none
// of them has to be exercised to test them.
@(require_results)
models_dev_fetch :: proc(user_data: rawptr, allocator: mem.Allocator) -> ([]u8, bool) {
	body: Fetch_Body
	body.bytes.allocator = allocator

	control := Fetch_Control {
		deadline = ai.deadline_in(MODELS_DEV_TIMEOUT),
		cancel   = cast(^bool)user_data,
	}
	failure := client.stream_request(
		{url = MODELS_DEV_URL, method = .Get, expected_content_type = "application/json", allocator = allocator},
		{probe = {check = fetch_control_probe, user_data = &control}},
		&body,
		fetch_collect,
	)
	if failure.kind != .None {
		delete(body.bytes)
		return nil, false
	}
	return fetch_body_finish(&body, allocator)
}
