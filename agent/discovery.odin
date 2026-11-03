package agent

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:mem/virtual"
import "core:path/filepath"
import "core:strings"
import "core:thread"
import "core:time"

import "nabla:http/client"

// The second enrichment stage: each configured provider's own model listing, served from
// cache at startup and refreshed in the background. It contributes identity alone, and a
// provider that cannot be reached contributes nothing.

// The listing hangs off the configured base URL, which already carries the API
// version prefix: a base_url of ".../v1" lists ".../v1/models".
PROVIDER_MODELS_SUFFIX :: "models"
PROVIDER_MODELS_TIMEOUT :: 10 * time.Second
PROVIDER_MODELS_FRESH :: 5 * time.Minute
PROVIDER_MODELS_CACHE_PREFIX :: "provider-models"

// provider_models_cached reads every usable cache entry without performing I/O
// beyond the local filesystem. Stale entries remain valid inputs while a later
// refresh is in flight. ok is false when a source record could not be allocated.
@(require_results)
provider_models_cached :: proc(providers: []Catalog_Provider_Source, allocator := context.allocator) -> ([dynamic]Catalog_Provider_Source, bool) {
	result: [dynamic]Catalog_Provider_Source
	result.allocator = allocator
	for provider in providers {
		path, path_ok := provider_models_cache_path(provider, allocator)
		if !path_ok { continue }
		body, cached := fetch_cache_read(path, allocator)
		delete(path, allocator)
		if !cached { continue }
		if provider_models_add_body(&result, provider.id, body, allocator) == .Failed {
			catalog_sources_destroy(&result, allocator)
			return {}, false
		}
	}
	return result, true
}

// provider_sources_add appends one provider's model listing to a source list, taking
// ownership of models. It reports false when the source record could not be allocated, and
// models stays with the caller.
@(require_results)
provider_sources_add :: proc(result: ^[dynamic]Catalog_Provider_Source, id: string, models: []Catalog_Model_Source, allocator: mem.Allocator) -> bool {
	owned, clone_error := strings.clone(id, allocator)
	if clone_error != nil { return false }
	if _, append_error := append(result, Catalog_Provider_Source{id = owned, models = models}); append_error != nil {
		delete(owned, allocator)
		return false
	}
	return true
}

// Provider_Models_Add reports what provider_models_add_body did with a listing body.
@(private)
Provider_Models_Add :: enum {
	Skipped,
	Added,
	Failed,
}

// provider_models_add_body lists the models in body and appends them as one source.
// It takes ownership of body and releases it in every case; models that cannot be
// appended are destroyed. Skipped means body held no listing, Failed means the source
// record could not be allocated.
@(private, require_results)
provider_models_add_body :: proc(result: ^[dynamic]Catalog_Provider_Source, id: string, body: []u8, allocator: mem.Allocator) -> Provider_Models_Add {
	models, listed := provider_models_list(body, allocator)
	delete(body, allocator)
	if !listed { return .Skipped }
	if !provider_sources_add(result, id, models, allocator) {
		catalog_model_sources_destroy(models, allocator)
		return .Failed
	}
	return .Added
}

// Listing_Fetch_Proc requests one provider's listing and returns its body, owned by the
// caller. user_data is what the refresh was given. It runs on a thread of its own, so it
// and the allocator it is given must be safe for concurrent use.
Listing_Fetch_Proc :: proc(user_data: rawptr, base_url, api_key: string, allocator: mem.Allocator) -> ([]u8, bool)

// provider_models_refresh returns the freshest source available for each provider. A
// fresh cache avoids the network. A stale cache remains the fallback when acquisition or
// validation fails. The listings a refresh needs are requested together, one thread per
// provider, so the wait is the slowest provider rather than the sum of them. ok is false
// when a source record could not be allocated.
@(require_results)
provider_models_refresh :: proc(
	providers: []Catalog_Provider_Source,
	user_data: rawptr,
	fetch: Listing_Fetch_Proc,
	allocator := context.allocator,
) -> (
	[dynamic]Catalog_Provider_Source,
	bool,
) {
	return provider_models_refresh_at(time.now(), providers, user_data, fetch, allocator)
}

// Provider_Refresh is one provider's state across a refresh: its cache entry, read before
// any request starts, and the listing request it needs, if any.
@(private)
Provider_Refresh :: struct {
	path:          string, // owned; empty when the provider has no cache path
	cached_models: []Catalog_Model_Source, // owned until it moves into the result
	cache_valid:   bool,
	fresh:         bool,
	credential:    string, // owned; the key the request was made with
	request:       Listing_Fetch,
	thread:        ^thread.Thread,
}

// Listing_Fetch is one request for a provider's listing. It runs on the thread its
// Provider_Refresh owns and is read back only after that thread is joined.
@(private)
Listing_Fetch :: struct {
	fetch:     Listing_Fetch_Proc,
	user_data: rawptr,
	base_url:  string,
	api_key:   string,
	allocator: mem.Allocator,
	body:      []u8, // owned once fetched is true
	fetched:   bool,
}

@(private)
listing_fetch_run :: proc(data: rawptr) {
	request := (^Listing_Fetch)(data)
	request.body, request.fetched = request.fetch(request.user_data, request.base_url, request.api_key, request.allocator)
}

// listing_fetch_start runs the request on a new thread. When no thread can be created the
// request runs on this one, so the refresh never drops a provider.
@(private)
listing_fetch_start :: proc(request: ^Listing_Fetch) -> ^thread.Thread {
	worker := thread.create_and_start_with_data(request, listing_fetch_run)
	if worker == nil {
		listing_fetch_run(request)
	}
	return worker
}

@(private)
provider_refreshes_join :: proc(refreshes: []Provider_Refresh) {
	for &refresh in refreshes {
		if refresh.thread == nil { continue }
		thread.join(refresh.thread)
		thread.destroy(refresh.thread)
		refresh.thread = nil
	}
}

// provider_refreshes_destroy waits for every request and releases what the refresh still
// owns. The refresh's results are moved out before this runs, so only leftovers are freed.
@(private)
provider_refreshes_destroy :: proc(refreshes: []Provider_Refresh, allocator: mem.Allocator) {
	provider_refreshes_join(refreshes)
	for refresh in refreshes {
		delete(refresh.path, allocator)
		catalog_model_sources_destroy(refresh.cached_models, allocator)
		delete(refresh.credential, allocator)
		delete(refresh.request.body, allocator)
	}
	delete(refreshes, allocator)
}

@(private, require_results)
provider_models_refresh_at :: proc(
	now: time.Time,
	providers: []Catalog_Provider_Source,
	user_data: rawptr,
	fetch: Listing_Fetch_Proc,
	allocator: mem.Allocator,
) -> (
	[dynamic]Catalog_Provider_Source,
	bool,
) {
	refreshes, make_error := make([]Provider_Refresh, len(providers), allocator)
	if make_error != nil { return {}, false }
	defer provider_refreshes_destroy(refreshes, allocator)

	// Phase one reads each cache entry and starts the requests that are needed. The
	// requests run while the rest of the phase and the later providers are prepared.
	for provider, index in providers {
		refresh := &refreshes[index]
		path, path_ok := provider_models_cache_path(provider, allocator)
		if path_ok { refresh.path = path }
		body: []u8
		cached := false
		if path_ok { body, cached = fetch_cache_read(path, allocator) }
		if cached { refresh.cached_models, refresh.cache_valid = provider_models_list(body, allocator) }
		delete(body, allocator)
		refresh.fresh = path_ok && refresh.cache_valid && fetch_cache_fresh(path, now, PROVIDER_MODELS_FRESH)
		if refresh.fresh { continue }
		if (provider.base_url.? or_else "") == "" || (provider.api_key.? or_else "") == "" { continue }
		credential, credential_ok := config_resolve_credential(provider.api_key.?, allocator)
		if !credential_ok { continue }
		refresh.credential = credential
		refresh.request = Listing_Fetch {
			fetch     = fetch,
			user_data = user_data,
			base_url  = provider.base_url.?,
			api_key   = credential,
			allocator = allocator,
		}
		refresh.thread = listing_fetch_start(&refresh.request)
	}

	// Phase two waits for every request. Phase three reads them back in provider order.
	provider_refreshes_join(refreshes)
	result: [dynamic]Catalog_Provider_Source
	result.allocator = allocator
	for provider, index in providers {
		refresh := &refreshes[index]
		if refresh.fresh {
			if !provider_sources_add(&result, provider.id, refresh.cached_models, allocator) {
				catalog_sources_destroy(&result, allocator)
				return {}, false
			}
			refresh.cached_models = nil
			continue
		}
		if refresh.request.fetched {
			models, listed := provider_models_list(refresh.request.body, allocator)
			// Caching is best effort: the listing in hand is what answers.
			if listed && refresh.path != "" { _ = fetch_cache_write(refresh.path, refresh.request.body) }
			delete(refresh.request.body, allocator)
			refresh.request.body = nil
			if listed {
				if !provider_sources_add(&result, provider.id, models, allocator) {
					catalog_model_sources_destroy(models, allocator)
					catalog_sources_destroy(&result, allocator)
					return {}, false
				}
				continue
			}
		}
		if refresh.cache_valid {
			if !provider_sources_add(&result, provider.id, refresh.cached_models, allocator) {
				catalog_sources_destroy(&result, allocator)
				return {}, false
			}
			refresh.cached_models = nil
		}
	}
	return result, true
}

@(require_results)
provider_models_cache_path :: proc(provider: Catalog_Provider_Source, allocator: mem.Allocator) -> (string, bool) {
	directory, directory_err := xdg_directory(.Cache, allocator)
	if directory_err != .None { return "", false }
	defer delete(directory, allocator)
	if xdg_directory_create(directory) != .None { return "", false }
	identity, identity_error := strings.concatenate([]string{provider.id, "\x00", provider.base_url.? or_else ""}, context.temp_allocator)
	if identity_error != nil { return "", false }
	defer delete(identity, context.temp_allocator)
	key := hash.fnv64a(transmute([]byte)identity)
	name_buffer: [len(PROVIDER_MODELS_CACHE_PREFIX) + len("-.json") + 16]u8
	name := fmt.bprintf(name_buffer[:], "%s-%016x.json", PROVIDER_MODELS_CACHE_PREFIX, key)
	path, join_err := filepath.join([]string{directory, name}, allocator)
	return path, join_err == nil
}

// provider_models_list reads a listing into model sources that state identity
// only. The response shape is the one this harness's APIs speak: an object whose
// "data" member is an array of records with an id. Anything else is no listing at
// all, which leaves the other stages to answer.
//
// Duplicate ids need no handling: the resolver keys models by identity, so a
// listing that repeats one enriches the entry it already has.
@(require_results)
provider_models_list :: proc(body: []u8, allocator: mem.Allocator) -> ([]Catalog_Model_Source, bool) {
	// The tree is a whole response and none of it is kept, so it lives in a
	// dedicated arena that is unmapped when the ids have been copied out.
	arena: virtual.Arena
	if arena_err := virtual.arena_init_growing(&arena); arena_err != nil { return nil, false }
	defer virtual.arena_destroy(&arena)

	root, parse_err := json.parse_bytes(body, .JSON, true, virtual.arena_allocator(&arena))
	if parse_err != .None { return nil, false }
	root_object, root_is_object := root.(json.Object)
	if !root_is_object { return nil, false }
	data_value, has_data := root_object["data"]
	if !has_data { return nil, false }
	entries, entries_is_array := data_value.(json.Array)
	if !entries_is_array { return nil, false }
	if len(entries) == 0 { return nil, true }

	count := 0
	for entry in entries {
		if _, present := provider_models_id(entry); present { count += 1 }
	}
	if count == 0 { return nil, false }

	result, result_error := make([]Catalog_Model_Source, count, allocator)
	if result_error != nil { return nil, false }
	index := 0
	for entry in entries {
		id, present := provider_models_id(entry)
		if !present { continue }
		owned, clone_error := strings.clone(id, allocator)
		if clone_error != nil {
			for &model in result[:index] { catalog_model_source_destroy(&model, allocator) }
			delete(result, allocator)
			return nil, false
		}
		result[index] = Catalog_Model_Source {
			id = owned,
		}
		index += 1
	}
	return result, true
}

// provider_models_id reads one listing record's id. A record without a usable id
// is not a model, so it is left out rather than invented.
@(require_results)
provider_models_id :: proc(entry: json.Value) -> (id: string, present: bool) {
	object, is_object := entry.(json.Object)
	if !is_object { return "", false }
	member, found := object["id"]
	if !found { return "", false }
	text, is_string := member.(json.String)
	if !is_string || text == "" { return "", false }
	return string(text), true
}

// provider_models_fetch performs the one request this stage needs. The request ends early
// when cancel, if not nil, becomes true. The content type is not asserted: the provider is
// the user's own endpoint, and a body that is not a listing is refused by parsing rather
// than by a header.
@(require_results)
provider_models_fetch :: proc(user_data: rawptr, base_url, api_key: string, allocator: mem.Allocator) -> ([]u8, bool) {
	cancel := (^bool)(user_data)
	url, url_error := strings.concatenate([]string{strings.trim_right(base_url, "/"), "/", PROVIDER_MODELS_SUFFIX}, allocator)
	if url_error != nil { return nil, false }
	defer delete(url, allocator)
	authorization, authorization_error := strings.concatenate([]string{"Bearer ", api_key}, allocator = allocator)
	if authorization_error != nil { return nil, false }
	defer delete(authorization, allocator)

	headers := [1]client.Header{{"authorization", authorization}}
	return fetch_get({url = url, method = .Get, headers = headers[:], allocator = allocator}, PROVIDER_MODELS_TIMEOUT, cancel, allocator)
}
