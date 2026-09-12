package agent

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:time"

import "nabla:ai"
import "nabla:http/client"

// The second enrichment stage: each configured provider's own model listing, read
// live at startup.
//
// The endpoint this harness speaks reports model ids and little else, so
// discovery contributes identity. A model the user did not configure joins the
// catalog here, and every field discovery cannot state stays absent, which leaves
// the user's configuration ahead of it and models.dev behind it.
//
// A provider that cannot be reached contributes nothing. That is the whole
// failure policy: the catalog without this stage is still usable, so enrichment
// degrades to the sources that answered rather than failing the launch.

// The listing hangs off the configured base URL, which already carries the API
// version prefix: a base_url of ".../v1" lists ".../v1/models".
PROVIDER_MODELS_SUFFIX :: "models"
PROVIDER_MODELS_TIMEOUT :: 10 * time.Second
// The bound is a ceiling so a broken or hostile response cannot exhaust memory,
// not an expectation: a listing is small.
PROVIDER_MODELS_MAX_BYTES :: 4 * 1024 * 1024

// Provider_Models_Fetch delivers one provider's model listing, owned by the
// caller. Production uses provider_models_fetch; a test supplies its own, which
// is how discovery is exercised without a network.
Provider_Models_Fetch :: #type proc(user_data: rawptr, base_url, api_key: string, allocator: mem.Allocator) -> ([]u8, bool)

// discover_provider_models turns each configured provider's listing into one more
// catalog source. Providers are listed independently, so one that cannot be
// reached does not hold up the others. The result is owned by the caller and
// released with catalog_sources_destroy, exactly like the result of the other two
// stages.
discover_provider_models :: proc(
	providers: []Catalog_Provider_Source,
	fetch: Provider_Models_Fetch = provider_models_fetch,
	user_data: rawptr = nil,
	allocator := context.allocator,
) -> [dynamic]Catalog_Provider_Source {
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
		append(&result, Catalog_Provider_Source{id = strings.clone(provider.id, allocator), models = models})
	}
	return result
}

// provider_models_list reads a listing into model sources that state identity
// only. The response shape is the one this harness's APIs speak: an object whose
// "data" member is an array of records with an id. Anything else is no listing at
// all, which leaves the other stages to answer.
//
// Duplicate ids need no handling: the resolver keys models by identity, so a
// listing that repeats one enriches the entry it already has.
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

	count := 0
	for entry in entries {
		if _, present := provider_models_id(entry); present { count += 1 }
	}
	if count == 0 { return nil, false }

	result := make([]Catalog_Model_Source, count, allocator)
	index := 0
	for entry in entries {
		id, present := provider_models_id(entry)
		if !present { continue }
		result[index] = Catalog_Model_Source {
			id = strings.clone(id, allocator),
		}
		index += 1
	}
	return result, true
}

// provider_models_id reads one listing record's id. A record without a usable id
// is not a model, so it is left out rather than invented.
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
provider_models_fetch :: proc(_: rawptr, base_url, api_key: string, allocator: mem.Allocator) -> ([]u8, bool) {
	url := fmt.aprintf("%s/%s", strings.trim_right(base_url, "/"), PROVIDER_MODELS_SUFFIX, allocator = allocator)
	defer delete(url, allocator)
	authorization := strings.concatenate([]string{"Bearer ", api_key}, allocator = allocator)
	defer delete(authorization, allocator)

	body: Fetch_Body
	body.bytes.allocator = allocator
	body.limit = PROVIDER_MODELS_MAX_BYTES
	headers := [1]client.Header{{"authorization", authorization}}

	deadline := ai.deadline_in(PROVIDER_MODELS_TIMEOUT)
	failure := client.stream_request(
		{url = url, method = .Get, headers = headers[:], allocator = allocator},
		{probe = {check = fetch_probe, user_data = &deadline}},
		&body,
		fetch_collect,
	)
	if failure.kind != .None {
		delete(body.bytes)
		return nil, false
	}
	return fetch_body_finish(&body, allocator)
}
