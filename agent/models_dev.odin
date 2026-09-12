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

// The API representation is the models.dev endpoint for provider endpoints and
// the models they serve, which is exactly what this harness consumes. The
// catalog representation is the same provider records plus a provider-agnostic
// model registry this harness never reads, and its two model-shaped maps share
// ids -- so consuming it would mean fetching and discarding data, and risking a
// record taken from the wrong map.
MODELS_DEV_URL :: "https://models.dev/api.json"
MODELS_DEV_CACHE_FILE :: "models-dev-api.json"

// A cached catalog is used for a day before it is refreshed. A stale copy is a
// normal input rather than an error, so a refresh that fails keeps serving it:
// the catalog changes when providers add or retire models, not between requests.
MODELS_DEV_FRESH :: 24 * time.Hour
MODELS_DEV_TIMEOUT :: 60 * time.Second

// The published catalog is a few megabytes. The bound is a ceiling so a broken
// or hostile response cannot exhaust memory, not an expectation.
MODELS_DEV_MAX_BYTES :: 32 * 1024 * 1024

Models_Dev_Error :: enum {
	None,
	// The state directory could not be resolved or created, so the specification
	// permits nowhere to cache. Reported rather than worked around with a
	// home-relative path.
	State_Directory,
	// The document is neither cached nor reachable.
	Unavailable,
	// The document was acquired but is not a usable provider document, and no
	// cached copy could serve instead.
	Invalid_Data,
	// A document was acquired but cannot become provider source records.
	Invalid_JSON,
	Invalid_Structure,
	Missing_Identity,
}

// Models_Dev_Fetch delivers a catalog body owned by the caller. Production uses
// models_dev_fetch; a test supplies its own, which is how the cache policy is
// exercised without the network.
Models_Dev_Fetch :: #type proc(user_data: rawptr, allocator: mem.Allocator) -> ([]u8, bool)

// models_dev_catalog returns the catalog, preferring a cache that is still fresh
// and refreshing it otherwise.
//
// A stale cache is never destroyed before its replacement exists: when the
// refresh fails the cached copy is returned instead, so a network problem
// degrades to stale metadata rather than to none. The returned body is owned by
// the caller.
models_dev_catalog :: proc(fetch: Models_Dev_Fetch = models_dev_fetch, user_data: rawptr = nil, allocator := context.allocator) -> ([]u8, Models_Dev_Error) {
	return models_dev_catalog_at(time.now(), fetch, user_data, allocator)
}

// models_dev_catalog_at is the same policy against an explicit clock, so the
// freshness window is testable without waiting for it or forging file times.
models_dev_catalog_at :: proc(now: time.Time, fetch: Models_Dev_Fetch, user_data: rawptr, allocator: mem.Allocator) -> ([]u8, Models_Dev_Error) {
	path, path_err := models_dev_cache_path(allocator)
	if path_err != .None { return nil, path_err }
	defer delete(path, allocator)
	unusable := false
	if models_dev_cache_fresh(path, now) {
		if cached, cached_ok := models_dev_cache_read(path, allocator); cached_ok { return cached, .None }
		// An unreadable cache counts as absent: the refresh below replaces it.
	}
	if body, fetched := fetch(user_data, allocator); fetched {
		if models_dev_validate(body) {
			// Caching is best effort. A document already in hand is a usable source,
			// so a write that fails is not a failed acquisition.
			models_dev_cache_write(path, body)
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
	if cached, cached_ok := models_dev_cache_read(path, allocator); cached_ok { return cached, .None }
	if unusable { return nil, .Invalid_Data }
	return nil, .Unavailable
}

// models_dev_validate reports whether an acquired document is usable, which is
// what decides whether it may replace the cache. The tree and the source records
// it would produce both live in an arena released here, so the check costs one
// parse per refresh and leaves nothing resident.
models_dev_validate :: proc(data: []u8) -> bool {
	arena: virtual.Arena
	if arena_err := virtual.arena_init_growing(&arena); arena_err != nil { return false }
	defer virtual.arena_destroy(&arena)
	_, err := models_dev_parse(data, {}, virtual.arena_allocator(&arena))
	return err == .None
}

// models_dev_sources produces the resolver input from models.dev: the document is
// taken from the cache when it is fresh and acquired otherwise, then parsed into
// provider source records. This is the whole ingestion path, so no caller handles
// the raw document. `providers` restricts extraction to those provider ids, so a
// provider the user cannot select is never materialized. The result is owned by
// the caller and released with catalog_sources_destroy, exactly like the user
// configuration loader's result.
models_dev_sources :: proc(
	fetch: Models_Dev_Fetch = models_dev_fetch,
	user_data: rawptr = nil,
	providers: []string = {},
	allocator := context.allocator,
) -> (
	[dynamic]Catalog_Provider_Source,
	Models_Dev_Error,
) {
	body, body_err := models_dev_catalog(fetch, user_data, allocator)
	if body_err != .None { return {}, body_err }
	defer delete(body, allocator)

	sources, parse_err := models_dev_parse(body, providers, allocator)
	switch parse_err {
	case .None:
		return sources, .None
	case .Invalid_JSON:
		return {}, .Invalid_JSON
	case .Invalid_Structure:
		return {}, .Invalid_Structure
	case .Missing_Identity:
		return {}, .Missing_Identity
	}
	return {}, .Invalid_Data
}

// models_dev_cache_path resolves where the document is cached and creates the
// directory, so a caller always has somewhere to read from and write to. The
// state directory is the specification's place for regenerable state, and the
// application directory beneath it is lowercased. The result is owned by the
// caller.
models_dev_cache_path :: proc(allocator := context.allocator) -> (string, Models_Dev_Error) {
	directory, directory_err := xdg_directory(.State, allocator)
	if directory_err != .None { return "", .State_Directory }
	defer delete(directory, allocator)
	if create_err := xdg_directory_create(directory); create_err != .None { return "", .State_Directory }
	path, join_err := filepath.join([]string{directory, MODELS_DEV_CACHE_FILE}, allocator)
	if join_err != nil { return "", .State_Directory }
	return path, .None
}

// models_dev_cache_fresh reports whether a cached catalog is recent enough to
// use. A missing file, an unreadable timestamp, and a timestamp ahead of the
// clock are all stale, so a damaged cache is replaced rather than trusted.
models_dev_cache_fresh :: proc(path: string, now: time.Time) -> bool {
	modified, err := os.modification_time_by_path(path)
	if err != nil { return false }
	age := time.diff(modified, now)
	return age >= 0 && age < MODELS_DEV_FRESH
}

// models_dev_cache_read returns a cached catalog when one is present and within
// the size bound. The result is owned by the caller.
models_dev_cache_read :: proc(path: string, allocator: mem.Allocator) -> ([]u8, bool) {
	body, read_err := os.read_entire_file(path, allocator)
	if read_err == nil && len(body) > 0 && len(body) <= MODELS_DEV_MAX_BYTES { return body, true }
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
		os.remove(temporary)
		return false
	}
	return true
}

// Models_Dev_Body accumulates a response and remembers whether the size bound was
// exceeded, which is what turns an oversized response into a failure rather than
// a short body.
Models_Dev_Body :: struct {
	bytes:    [dynamic]u8,
	overflow: bool,
}

models_dev_collect :: proc(user_data: rawptr, chunk: []u8) {
	body := cast(^Models_Dev_Body)user_data
	if len(body.bytes) + len(chunk) > MODELS_DEV_MAX_BYTES {
		body.overflow = true
		return
	}
	append(&body.bytes, ..chunk)
}

// models_dev_probe stops the request once its deadline passes, so a peer that
// accepts the connection and then stalls cannot hold up the harness.
models_dev_probe :: proc(user_data: rawptr) -> client.Wait_Status {
	deadline := cast(^ai.Deadline)user_data
	if deadline != nil && ai.deadline_expired(deadline^) { return .Timed_Out }
	return .Ready
}

// models_dev_fetch performs the one request this source needs. It is deliberately
// thin: freshness, caching, and persistence are the caller's decisions, so none
// of them has to be exercised to test them.
models_dev_fetch :: proc(_: rawptr, allocator: mem.Allocator) -> ([]u8, bool) {
	body: Models_Dev_Body
	body.bytes.allocator = allocator

	deadline := ai.deadline_in(MODELS_DEV_TIMEOUT)
	failure := client.stream_request(
		{url = MODELS_DEV_URL, method = .Get, expected_content_type = "application/json", allocator = allocator},
		{probe = {check = models_dev_probe, user_data = &deadline}},
		&body,
		models_dev_collect,
	)
	if failure.kind != .None || body.overflow || len(body.bytes) == 0 {
		delete(body.bytes)
		return nil, false
	}

	// The caller frees the result the same way it frees the cached copy, so the
	// slice is sized exactly rather than sharing the accumulator's capacity.
	result := make([]u8, len(body.bytes), allocator)
	copy(result, body.bytes[:])
	delete(body.bytes)
	return result, true
}
