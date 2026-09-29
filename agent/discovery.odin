package agent

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "nabla:ai"
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

// Provider_Models_Fetch delivers one provider's model listing, owned by the
// caller. Production uses provider_models_fetch; a test supplies its own, which
// is how discovery is exercised without a network.
Provider_Models_Fetch :: #type proc(user_data: rawptr, base_url, api_key: string, allocator: mem.Allocator) -> ([]u8, bool)

// discover_provider_models turns each configured provider's listing into one more
// catalog source. Providers are listed independently, so one that cannot be
// reached does not hold up the others. The result is owned by the caller and
// released with catalog_sources_destroy, exactly like the result of the other two
// stages. ok is false when a source record could not be allocated.
@(require_results)
discover_provider_models :: proc(
	providers: []Catalog_Provider_Source,
	fetch: Provider_Models_Fetch = provider_models_fetch,
	user_data: rawptr = nil,
	allocator := context.allocator,
) -> (
	[dynamic]Catalog_Provider_Source,
	bool,
) {
	result: [dynamic]Catalog_Provider_Source
	result.allocator = allocator
	for provider in providers {
		// A provider with no endpoint or no credential is not asked: the request
		// could only fail, and the other stages still describe it.
		if provider.base_url == "" || provider.api_key == "" { continue }
		credential, credential_ok := config_resolve_credential(provider.api_key, allocator)
		if !credential_ok { continue }
		body, fetched := fetch(user_data, provider.base_url, credential, allocator)
		delete(credential, allocator)
		if !fetched { continue }
		models, listed := provider_models_list(body, allocator)
		delete(body, allocator)
		if !listed { continue }
		if !provider_sources_add(&result, provider.id, models, allocator) {
			catalog_model_sources_destroy(models, allocator)
			catalog_sources_destroy(&result, allocator)
			return {}, false
		}
	}
	return result, true
}

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
		body, cached := provider_models_cache_read(path, allocator)
		delete(path, allocator)
		if !cached { continue }
		models, listed := provider_models_list(body, allocator)
		delete(body, allocator)
		if !listed { continue }
		if !provider_sources_add(&result, provider.id, models, allocator) {
			catalog_model_sources_destroy(models, allocator)
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

// provider_models_refresh returns the freshest source available for each
// provider. A fresh cache avoids the network. A stale cache remains the fallback
// when acquisition or validation fails. ok is false when a source record could not be
// allocated.
@(require_results)
provider_models_refresh :: proc(
	providers: []Catalog_Provider_Source,
	fetch: Provider_Models_Fetch = provider_models_fetch,
	user_data: rawptr = nil,
	allocator := context.allocator,
) -> (
	[dynamic]Catalog_Provider_Source,
	bool,
) {
	return provider_models_refresh_at(time.now(), providers, fetch, user_data, allocator)
}

@(private, require_results)
provider_models_refresh_at :: proc(
	now: time.Time,
	providers: []Catalog_Provider_Source,
	fetch: Provider_Models_Fetch,
	user_data: rawptr,
	allocator: mem.Allocator,
) -> (
	[dynamic]Catalog_Provider_Source,
	bool,
) {
	result: [dynamic]Catalog_Provider_Source
	result.allocator = allocator
	for provider in providers {
		path, path_ok := provider_models_cache_path(provider, allocator)
		body: []u8
		cached := false
		if path_ok { body, cached = provider_models_cache_read(path, allocator) }
		cached_models: []Catalog_Model_Source
		cache_valid := false
		if cached { cached_models, cache_valid = provider_models_list(body, allocator) }
		fresh := path_ok && cache_valid && provider_models_cache_fresh(path, now)
		if fresh {
			added := provider_sources_add(&result, provider.id, cached_models, allocator)
			delete(body, allocator)
			delete(path, allocator)
			if !added {
				catalog_model_sources_destroy(cached_models, allocator)
				catalog_sources_destroy(&result, allocator)
				return {}, false
			}
			continue
		}
		if provider.base_url != "" && provider.api_key != "" {
			credential, credential_ok := config_resolve_credential(provider.api_key, allocator)
			if credential_ok {
				acquired, fetched := fetch(user_data, provider.base_url, credential, allocator)
				delete(credential, allocator)
				if fetched {
					models, listed := provider_models_list(acquired, allocator)
					if listed {
						// Caching is best effort: the listing in hand is what answers.
						if path_ok { _ = provider_models_cache_write(path, acquired) }
						added := provider_sources_add(&result, provider.id, models, allocator)
						catalog_model_sources_destroy(cached_models, allocator)
						delete(body, allocator)
						delete(acquired, allocator)
						if path_ok { delete(path, allocator) }
						if !added {
							catalog_model_sources_destroy(models, allocator)
							catalog_sources_destroy(&result, allocator)
							return {}, false
						}
						continue
					}
					delete(acquired, allocator)
				}
			}
		}
		if cache_valid {
			if !provider_sources_add(&result, provider.id, cached_models, allocator) {
				catalog_model_sources_destroy(cached_models, allocator)
				delete(body, allocator)
				if path_ok { delete(path, allocator) }
				catalog_sources_destroy(&result, allocator)
				return {}, false
			}
		}
		delete(body, allocator)
		if path_ok { delete(path, allocator) }
	}
	return result, true
}

@(require_results)
provider_models_cache_path :: proc(provider: Catalog_Provider_Source, allocator: mem.Allocator) -> (string, bool) {
	directory, directory_err := xdg_directory(.Cache, allocator)
	if directory_err != .None { return "", false }
	defer delete(directory, allocator)
	if xdg_directory_create(directory) != .None { return "", false }
	identity := fmt.aprintf("%s\x00%s", provider.id, provider.base_url, allocator = context.temp_allocator)
	key := hash.fnv64a(transmute([]byte)identity)
	name := fmt.aprintf("%s-%016x.json", PROVIDER_MODELS_CACHE_PREFIX, key, allocator = context.temp_allocator)
	path, join_err := filepath.join([]string{directory, name}, allocator)
	return path, join_err == nil
}

@(require_results)
provider_models_cache_fresh :: proc(path: string, now: time.Time) -> bool {
	modified, err := os.modification_time_by_path(path)
	if err != nil { return false }
	age := time.diff(modified, now)
	return age >= 0 && age < PROVIDER_MODELS_FRESH
}

@(require_results)
provider_models_cache_read :: proc(path: string, allocator: mem.Allocator) -> ([]u8, bool) {
	body, read_err := os.read_entire_file(path, allocator)
	if read_err == nil && len(body) > 0 { return body, true }
	if body != nil { delete(body, allocator) }
	return nil, false
}

provider_models_cache_write :: proc(path: string, body: []u8) -> bool {
	temporary := fmt.tprintf("%s.%d.tmp", path, os.get_pid())
	if os.write_entire_file(temporary, body) != nil { return false }
	if os.rename(temporary, path) != nil {
		// A temporary file that cannot be removed is left behind; only the cache matters.
		_ = os.remove(temporary)
		return false
	}
	return true
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

// provider_models_fetch performs the one request this stage needs. The content
// type is not asserted: the provider is the user's own endpoint, and a body that
// is not a listing is refused by parsing rather than by a header.
@(require_results)
provider_models_fetch :: proc(user_data: rawptr, base_url, api_key: string, allocator: mem.Allocator) -> ([]u8, bool) {
	url := fmt.aprintf("%s/%s", strings.trim_right(base_url, "/"), PROVIDER_MODELS_SUFFIX, allocator = allocator)
	defer delete(url, allocator)
	authorization, authorization_error := strings.concatenate([]string{"Bearer ", api_key}, allocator = allocator)
	if authorization_error != nil { return nil, false }
	defer delete(authorization, allocator)

	body: Fetch_Body
	body.bytes.allocator = allocator
	headers := [1]client.Header{{"authorization", authorization}}

	control := Fetch_Control {
		deadline = ai.deadline_in(PROVIDER_MODELS_TIMEOUT),
		cancel   = cast(^bool)user_data,
	}
	failure := client.stream_request(
		{url = url, method = .Get, headers = headers[:], allocator = allocator},
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
