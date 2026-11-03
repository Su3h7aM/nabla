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

Discovery_Stub :: struct {
	body:     string,
	calls:    int,
	base_url: string,
	api_key:  string,
}

discovery_stub_fetch :: proc(user_data: rawptr, base_url, api_key: string, allocator: mem.Allocator) -> ([]u8, bool) {
	stub := (^Discovery_Stub)(user_data)
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
test_provider_discovery_refreshes_once_and_serves_the_cache :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	models_dev_state_test(t, "provider-models", proc(t: ^testing.T, _: string) {
		providers := []Catalog_Provider_Source{discovery_source("proxy", "http://proxy.test/v1", "literal-key")}
		first := Discovery_Stub {
			body = DISCOVERY_FIXTURE,
		}
		refreshed, refreshed_ok := provider_models_refresh(providers, &first, discovery_stub_fetch, context.allocator)
		testing.expect(t, refreshed_ok)
		defer catalog_sources_destroy(&refreshed)
		testing.expect_value(t, first.calls, 1)
		testing.expect_value(t, len(refreshed), 1)

		second := Discovery_Stub {
			body = `{"data":[{"id":"wrong"}]}`,
		}
		fresh, fresh_ok := provider_models_refresh(providers, &second, discovery_stub_fetch, context.allocator)
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
		refreshed, refreshed_ok := provider_models_refresh(providers, &stub, discovery_stub_fetch, context.allocator)
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
		refreshed, refreshed_ok := provider_models_refresh_at(stale_at, providers, &stub, discovery_stub_fetch, context.allocator)
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
	refreshed, refreshed_ok := provider_models_refresh(providers, &stub, discovery_stub_fetch, context.allocator)
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
		refreshed, refreshed_ok := provider_models_refresh(providers, &stub, discovery_stub_fetch, context.allocator)
		testing.expect(t, refreshed_ok)
		defer catalog_sources_destroy(&refreshed)
		testing.expect_value(t, stub.calls, 0)
		testing.expect_value(t, len(refreshed), 1)
		testing.expect_value(t, len(refreshed[0].models[0].id), len(id))
	})
}
