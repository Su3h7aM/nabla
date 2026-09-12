#+test
package agent

import "core:mem"
import "core:testing"

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
	return Catalog_Provider_Source{id = provider_id, base_url_present = true, base_url = base_url, api_key_present = true, api_key = api_key}
}

@(test)
test_discovery_lists_a_provider_and_states_only_ids :: proc(t: ^testing.T) {
	stub := Discovery_Stub {
		body = DISCOVERY_FIXTURE,
	}
	providers := []Catalog_Provider_Source{discovery_source("proxy", "http://proxy.test/v1", "literal-key")}

	discovered := discover_provider_models(providers, discovery_stub_fetch, &stub, context.allocator)
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
	testing.expect(t, !discovered[0].models[0].context_window_present)
	testing.expect(t, !discovered[0].models[0].tools_present)
}

@(test)
test_discovery_skips_a_provider_it_cannot_ask :: proc(t: ^testing.T) {
	stub := Discovery_Stub {
		body = DISCOVERY_FIXTURE,
	}
	providers := []Catalog_Provider_Source {
		// No endpoint: the request could only fail.
		{id = "no-endpoint", api_key_present = true, api_key = "literal-key"},
		// No credential, and a reference to a variable that is not set.
		{id = "no-credential", base_url_present = true, base_url = "http://proxy.test/v1"},
		discovery_source("unset-credential", "http://proxy.test/v1", DISCOVERY_UNKNOWN_CREDENTIAL),
		discovery_source("proxy", "http://proxy.test/v1", "literal-key"),
	}

	discovered := discover_provider_models(providers, discovery_stub_fetch, &stub, context.allocator)
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
		id                     = "proxy/one",
		context_window_present = true,
		context_window         = 500000,
	}
	user := []Catalog_Provider_Source {
		{
			id = "proxy",
			base_url_present = true,
			base_url = "http://proxy.test/v1",
			api_key_present = true,
			api_key = "literal-key",
			models = []Catalog_Model_Source{configured},
		},
	}

	discovered := discover_provider_models(user, discovery_stub_fetch, &stub, context.allocator)
	defer catalog_sources_destroy(&discovered, context.allocator)
	resolved, err := resolve_catalog(user, discovered[:], {})
	defer catalog_destroy(&resolved)

	testing.expect_value(t, err, Catalog_Error.None)
	testing.expect_value(t, len(resolved.models), 2)
	kept, kept_found := catalog_find_model(&resolved, "proxy", "proxy/one")
	testing.expect(t, kept_found)
	testing.expect_value(t, resolved.models[kept].context_window, 500000)
	discovered_two, two_found := catalog_find_model(&resolved, "proxy", "proxy/two")
	testing.expect(t, two_found)
	testing.expect(t, !resolved.models[discovered_two].context_window_present)
}
