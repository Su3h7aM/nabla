#+test
package agent

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// The listing shape this harness reads: an object whose "data" member is an array
// of records with an id. The second record states no id, so it must not become a
// model.
DISCOVERY_FIXTURE :: `{"object":"list","data":[{"id":"proxy/one","object":"model"},{"object":"model"},{"id":"proxy/two"}]}`

// DISCOVERY_UNKNOWN_CREDENTIAL names an environment variable no test sets, so a
// provider using it cannot be listed.
DISCOVERY_UNKNOWN_CREDENTIAL :: "${NABLA_TEST_ABSENT_KEY}"

Discovery_Stub :: struct {
	body:     string,
	calls:    int,
	base_url: string,
	api_key:  string,
}

discovery_stub_fetch :: proc(user_data: rawptr, base_url, api_key: string, allocator: mem.Allocator) -> ([]u8, bool) {
	stub := cast(^Discovery_Stub)user_data
	stub.calls += 1
	stub.base_url = base_url
	stub.api_key = api_key
	if stub.body == "" { return nil, false }
	bytes := make([]u8, len(stub.body), allocator)
	copy(bytes, stub.body)
	return bytes, true
}

discovery_source :: proc(provider_id, base_url, api_key: string) -> Catalog_Provider_Source {
	return Catalog_Provider_Source{id = provider_id, base_url = base_url, api_key = api_key}
}

@(test)
test_discovery_lists_a_provider_and_states_only_ids :: proc(t: ^testing.T) {
	stub := Discovery_Stub {
		body = DISCOVERY_FIXTURE,
	}
	providers := []Catalog_Provider_Source{discovery_source("proxy", "http://proxy.test/v1", "literal-key")}

	discovered, discovered_ok := discover_provider_models(providers, discovery_stub_fetch, &stub, context.allocator)
	testing.expect(t, discovered_ok)
	defer catalog_sources_destroy(&discovered, context.allocator)

	testing.expect_value(t, stub.calls, 1)
	testing.expect_value(t, stub.base_url, "http://proxy.test/v1")
	// A literal credential reaches the request as configured.
	testing.expect_value(t, stub.api_key, "literal-key")
	testing.expect_value(t, len(discovered), 1)
	testing.expect_value(t, discovered[0].id, "proxy")
	testing.expect_value(t, len(discovered[0].models), 2)
	testing.expect_value(t, discovered[0].models[0].id, "proxy/one")
	testing.expect_value(t, discovered[0].models[1].id, "proxy/two")
	// A listing states identity only, so nothing it reports can shadow the user on
	// some other field.
	testing.expect(t, discovered[0].models[0].context_window == nil)
	testing.expect(t, discovered[0].models[0].tools == nil)
}

@(test)
test_discovery_skips_a_provider_it_cannot_ask :: proc(t: ^testing.T) {
	stub := Discovery_Stub {
		body = DISCOVERY_FIXTURE,
	}
	providers := []Catalog_Provider_Source {
		// No endpoint: the request could only fail.
		{id = "no-endpoint", api_key = "literal-key"},
		// No credential, and a reference to a variable that is not set.
		{id = "no-credential", base_url = "http://proxy.test/v1"},
		discovery_source("unset-credential", "http://proxy.test/v1", DISCOVERY_UNKNOWN_CREDENTIAL),
		discovery_source("proxy", "http://proxy.test/v1", "literal-key"),
	}

	discovered, discovered_ok := discover_provider_models(providers, discovery_stub_fetch, &stub, context.allocator)
	testing.expect(t, discovered_ok)
	defer catalog_sources_destroy(&discovered, context.allocator)

	testing.expect_value(t, len(discovered), 1)
	testing.expect_value(t, discovered[0].id, "proxy")
}

@(test)
test_discovery_contributes_to_the_catalog_without_overriding_the_user :: proc(t: ^testing.T) {
	// The user configures one model with a window and states nothing about a
	// second; the listing reports both, so the configured model keeps its window
	// and gains the second.
	stub := Discovery_Stub {
		body = DISCOVERY_FIXTURE,
	}
	configured := Catalog_Model_Source {
		id             = "proxy/one",
		context_window = 500000,
	}
	user := []Catalog_Provider_Source{{id = "proxy", base_url = "http://proxy.test/v1", api_key = "literal-key", models = []Catalog_Model_Source{configured}}}

	discovered, discovered_ok := discover_provider_models(user, discovery_stub_fetch, &stub, context.allocator)
	testing.expect(t, discovered_ok)
	defer catalog_sources_destroy(&discovered, context.allocator)
	resolved, err := resolve_catalog(user, discovered[:], {})
	defer catalog_destroy(&resolved)

	testing.expect_value(t, err, Catalog_Error.None)
	testing.expect_value(t, len(resolved.models), 2)
	kept, kept_found := catalog_find_model(&resolved, "proxy", "proxy/one")
	testing.expect(t, kept_found)
	testing.expect_value(t, resolved.models[kept].context_window.?, 500000)
	discovered_two, two_found := catalog_find_model(&resolved, "proxy", "proxy/two")
	testing.expect(t, two_found)
	testing.expect(t, resolved.models[discovered_two].context_window == nil)
}

@(test)
test_provider_discovery_refreshes_once_and_serves_the_cache :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	models_dev_state_test(t, "provider-models", proc(t: ^testing.T, _: string) {
		providers := []Catalog_Provider_Source{discovery_source("proxy", "http://proxy.test/v1", "literal-key")}
		first := Discovery_Stub {
			body = DISCOVERY_FIXTURE,
		}
		refreshed, refreshed_ok := provider_models_refresh(providers, discovery_stub_fetch, &first, context.allocator)
		testing.expect(t, refreshed_ok)
		defer catalog_sources_destroy(&refreshed)
		testing.expect_value(t, first.calls, 1)
		testing.expect_value(t, len(refreshed), 1)

		second := Discovery_Stub {
			body = `{"data":[{"id":"wrong"}]}`,
		}
		fresh, fresh_ok := provider_models_refresh(providers, discovery_stub_fetch, &second, context.allocator)
		testing.expect(t, fresh_ok)
		defer catalog_sources_destroy(&fresh)
		testing.expect_value(t, second.calls, 0)
		testing.expect_value(t, fresh[0].models[0].id, "proxy/one")

		cached, cached_ok := provider_models_cached(providers, context.allocator)
		testing.expect(t, cached_ok)
		defer catalog_sources_destroy(&cached)
		testing.expect_value(t, len(cached), 1)
		testing.expect_value(t, cached[0].models[1].id, "proxy/two")
	})
}

@(test)
test_provider_discovery_replaces_an_invalid_fresh_cache :: proc(t: ^testing.T) {
	models_dev_state_test(t, "provider-models-invalid", proc(t: ^testing.T, _: string) {
		providers := []Catalog_Provider_Source{discovery_source("proxy", "http://proxy.test/v1", "literal-key")}
		path, path_ok := provider_models_cache_path(providers[0], context.temp_allocator)
		testing.expect(t, path_ok)
		testing.expect(t, os.write_entire_file(path, transmute([]u8)string(`{"not":"a listing"}`)) == nil)

		stub := Discovery_Stub {
			body = DISCOVERY_FIXTURE,
		}
		refreshed, refreshed_ok := provider_models_refresh(providers, discovery_stub_fetch, &stub, context.allocator)
		testing.expect(t, refreshed_ok)
		defer catalog_sources_destroy(&refreshed)
		testing.expect_value(t, stub.calls, 1)
		testing.expect_value(t, refreshed[0].models[0].id, "proxy/one")
	})
}

@(test)
test_provider_discovery_replaces_a_stale_listing_with_an_empty_listing :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	models_dev_state_test(t, "provider-models-empty", proc(t: ^testing.T, _: string) {
		providers := []Catalog_Provider_Source{discovery_source("proxy", "http://proxy.test/v1", "literal-key")}
		path, path_ok := provider_models_cache_path(providers[0], context.temp_allocator)
		if !testing.expect(t, path_ok) { return }
		testing.expect(t, os.write_entire_file(path, transmute([]u8)string(DISCOVERY_FIXTURE)) == nil)

		stub := Discovery_Stub {
			body = `{"data":[]}`,
		}
		stale_at := time.time_add(time.now(), PROVIDER_MODELS_FRESH * 2)
		refreshed, refreshed_ok := provider_models_refresh_at(stale_at, providers, discovery_stub_fetch, &stub, context.allocator)
		if !testing.expect(t, refreshed_ok) { return }
		defer catalog_sources_destroy(&refreshed)
		testing.expect_value(t, stub.calls, 1)
		testing.expect_value(t, len(refreshed), 1)
		testing.expect_value(t, len(refreshed[0].models), 0)

		cached, cached_ok := fetch_cache_read(path, context.temp_allocator)
		testing.expect(t, cached_ok)
		testing.expect_value(t, string(cached), `{"data":[]}`)
	})
}

@(test)
test_provider_discovery_fetches_without_a_cache_directory :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	root := fmt.tprintf("/tmp/nabla-provider-cache-blocked-%d", os.get_pid())
	os.remove_all(root)
	defer os.remove_all(root)
	_ = os.make_directory_all(root)
	blocking := fmt.tprintf("%s/blocking", root)
	testing.expect(t, os.write_entire_file(blocking, transmute([]u8)string("file")) == nil)

	previous, had_previous := os.lookup_env("XDG_CACHE_HOME", context.temp_allocator)
	defer if had_previous {
		os.set_env("XDG_CACHE_HOME", previous)
	} else {
		os.unset_env("XDG_CACHE_HOME")
	}
	testing.expect(t, os.set_env("XDG_CACHE_HOME", blocking) == nil)

	providers := []Catalog_Provider_Source{discovery_source("proxy", "http://proxy.test/v1", "literal-key")}
	stub := Discovery_Stub {
		body = DISCOVERY_FIXTURE,
	}
	refreshed, refreshed_ok := provider_models_refresh(providers, discovery_stub_fetch, &stub, context.allocator)
	if !testing.expect(t, refreshed_ok) { return }
	defer catalog_sources_destroy(&refreshed)
	testing.expect_value(t, stub.calls, 1)
	testing.expect_value(t, len(refreshed), 1)
	testing.expect_value(t, len(refreshed[0].models), 2)
}

// A listing is read whole whatever its size: the size of a provider's own listing
// is the provider's to choose, so a large one is neither refused nor truncated. The
// cached copy serves it without a request, which is the path a size bound would
// have turned into an empty catalog.
@(test)
test_provider_discovery_reads_a_listing_of_any_size :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	models_dev_state_test(t, "provider-models-large", proc(t: ^testing.T, _: string) {
		providers := []Catalog_Provider_Source{discovery_source("proxy", "http://proxy.test/v1", "literal-key")}
		path, path_ok := provider_models_cache_path(providers[0], context.temp_allocator)
		testing.expect(t, path_ok)

		id := strings.repeat("m", 5 * mem.Megabyte, context.temp_allocator)
		quoted := fmt.aprintf("%q", id, allocator = context.temp_allocator)
		body := strings.concatenate([]string{`{"data":[{"id":`, quoted, `}]}`}, context.temp_allocator)
		testing.expect(t, os.write_entire_file(path, transmute([]u8)body) == nil)

		stub := Discovery_Stub{}
		refreshed, refreshed_ok := provider_models_refresh(providers, discovery_stub_fetch, &stub, context.allocator)
		testing.expect(t, refreshed_ok)
		defer catalog_sources_destroy(&refreshed)
		testing.expect_value(t, stub.calls, 0)
		testing.expect_value(t, len(refreshed), 1)
		testing.expect_value(t, len(refreshed[0].models[0].id), len(id))
	})
}
