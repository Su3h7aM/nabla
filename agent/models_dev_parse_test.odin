package agent

import "core:os"
import "core:path/filepath"
import "core:testing"

// A representative document in the shape models.dev publishes at its API
// endpoint: providers keyed by id, each carrying its own models keyed by model
// id. It is deliberately small and exercises the fields this harness reads plus
// several it does not.
MODELS_DEV_FIXTURE :: `{
  "acme": {
    "id": "acme",
    "name": "Acme",
    "doc": "https://docs.acme.test",
    "env": ["ACME_API_KEY"],
    "npm": "@ai-sdk/openai-compatible",
    "api": "https://api.acme.test/v1",
    "models": {
      "acme/thinker": {
        "id": "acme/thinker",
        "name": "Acme Thinker",
        "description": "A reasoning model",
        "reasoning": true,
        "reasoning_options": [
          {"type": "effort", "values": ["low", "high", "max"]},
          {"type": "toggle"},
          {"type": "budget_tokens", "min": 1024, "max": 81920}
        ],
        "tool_call": true,
        "attachment": true,
        "cost": {"input": 1.0, "output": 2.0},
        "modalities": {"input": ["text", "image"], "output": ["text"]},
        "limit": {"context": 200000, "output": 64000}
      },
      "acme/plain": {
        "id": "acme/plain",
        "name": "Acme Plain",
        "reasoning": false,
        "tool_call": false,
        "modalities": {"input": ["text"], "output": ["text"]},
        "limit": {"context": 8192, "output": 4096}
      },
      "acme/zeroed": {
        "id": "acme/zeroed",
        "name": "Acme Zeroed",
        "reasoning": false,
        "tool_call": false,
        "modalities": {"input": [], "output": []},
        "limit": {"context": 0, "output": 0}
      }
    }
  },
  "beta": {
    "id": "beta",
    "name": "Beta",
    "env": ["BETA_KEY", "BETA_PROJECT"],
    "npm": "@ai-sdk/anthropic",
    "models": {
      "beta/talker": {
        "id": "beta/talker",
        "name": "Beta Talker",
        "reasoning": true,
        "reasoning_options": [{"type": "budget_tokens"}],
        "tool_call": true,
        "modalities": {"input": ["text"], "output": ["text"]},
        "limit": {"context": 100000, "output": 32000}
      }
    }
  }
}`

// models_dev_parse_text parses a fixture. The cast is a view of the literal,
// which the parser reads and never retains.
models_dev_parse_text :: proc(body: string) -> ([dynamic]Catalog_Provider_Source, Models_Dev_Parse_Error) {
	return models_dev_parse(transmute([]u8)body)
}

models_dev_fixture_source :: proc(t: ^testing.T, provider_id: string, catalog: []Catalog_Provider_Source) -> ^Catalog_Provider_Source {
	for &provider in catalog {
		if provider.id == provider_id { return &provider }
	}
	testing.expectf(t, false, "provider %s is missing from the parsed catalog", provider_id)
	return nil
}

models_dev_fixture_model :: proc(t: ^testing.T, provider: ^Catalog_Provider_Source, model_id: string) -> ^Catalog_Model_Source {
	for &model in provider.models {
		if model.id == model_id { return &model }
	}
	testing.expectf(t, false, "model %s is missing from %s", model_id, provider.id)
	return nil
}

@(test)
test_models_dev_parse_reads_providers_and_models :: proc(t: ^testing.T) {
	catalog, err := models_dev_parse_text(MODELS_DEV_FIXTURE)
	testing.expect_value(t, err, Models_Dev_Parse_Error.None)
	defer catalog_sources_destroy(&catalog)

	// One source record per provider, each holding only its own models, in id order
	// so the document's hash order cannot leak into the result.
	testing.expect_value(t, len(catalog), 2)
	testing.expect_value(t, catalog[0].id, "acme")
	testing.expect_value(t, catalog[1].id, "beta")
	acme := models_dev_fixture_source(t, "acme", catalog[:])
	beta := models_dev_fixture_source(t, "beta", catalog[:])
	testing.expect_value(t, len(acme.models), 3)
	testing.expect_value(t, len(beta.models), 1)

	// Provider identity, endpoint, protocol, and the credential reference.
	testing.expect_value(t, acme.base_url, "https://api.acme.test/v1")
	testing.expect_value(t, acme.api, "openai_chat_completions")
	testing.expect_value(t, acme.api_key, "${ACME_API_KEY}")
	// A provider that relies on its SDK's default endpoint states none, and a
	// later entry in env is not an interchangeable credential.
	testing.expect(t, !beta.base_url_present)
	testing.expect_value(t, beta.api, "anthropic_messages")
	testing.expect_value(t, beta.api_key, "${BETA_KEY}")

	// Model identity keeps the provider's namespace rather than being rewritten.
	thinker := models_dev_fixture_model(t, acme, "acme/thinker")
	testing.expect_value(t, thinker.display_name, "Acme Thinker")
	testing.expect_value(t, thinker.context_window, 200000)
	testing.expect_value(t, thinker.max_output_tokens, 64000)
	testing.expect(t, thinker.tools_present && thinker.tools)
	testing.expect_value(t, len(thinker.input_modalities), 2)
	testing.expect_value(t, thinker.input_modalities[1], "image")
	testing.expect_value(t, len(thinker.output_modalities), 1)
	testing.expect_value(t, thinker.output_modalities[0], "text")

	// Reasoning support and each control form it advertises.
	testing.expect(t, thinker.thinking.present && thinker.thinking.supported)
	testing.expect(t, thinker.thinking.toggle_present && thinker.thinking.toggle)
	testing.expect(t, thinker.thinking.levels_present)
	testing.expect_value(t, len(thinker.thinking.levels), 3)
	testing.expect_value(t, thinker.thinking.levels[0], "low")
	testing.expect_value(t, thinker.thinking.levels[2], "max")
	testing.expect(t, thinker.thinking.budget.present)
	testing.expect_value(t, thinker.thinking.budget.min, 1024)
	testing.expect_value(t, thinker.thinking.budget.max, 81920)

	// A model that cannot reason is a terminal negative, so its subtree is blocked.
	plain := models_dev_fixture_model(t, acme, "acme/plain")
	testing.expect(t, plain.thinking.present && plain.thinking.supported_present)
	testing.expect(t, !plain.thinking.supported)
	testing.expect(t, plain.thinking.blocked)
	testing.expect(t, !plain.thinking.toggle_present)
	testing.expect(t, !plain.thinking.levels_present)
	testing.expect(t, !plain.thinking.budget.present)

	// Budget bounds are independent of each other and of the control form.
	talker := models_dev_fixture_model(t, beta, "beta/talker")
	testing.expect(t, talker.thinking.budget.present)
	testing.expect(t, !talker.thinking.budget.min_present)
	testing.expect(t, !talker.thinking.budget.max_present)
}

@(test)
test_models_dev_parse_distinguishes_explicit_values_from_absent :: proc(t: ^testing.T) {
	catalog, err := models_dev_parse_text(MODELS_DEV_FIXTURE)
	testing.expect_value(t, err, Models_Dev_Parse_Error.None)
	defer catalog_sources_destroy(&catalog)

	acme := models_dev_fixture_source(t, "acme", catalog[:])
	// A stated false is a value the merge must not overwrite, and a stated zero is
	// a limit rather than an unconfigured one.
	plain := models_dev_fixture_model(t, acme, "acme/plain")
	testing.expect(t, plain.tools_present)
	testing.expect(t, !plain.tools)

	zeroed := models_dev_fixture_model(t, acme, "acme/zeroed")
	testing.expect(t, zeroed.context_window_present)
	testing.expect_value(t, zeroed.context_window, 0)
	testing.expect(t, zeroed.max_output_tokens_present)
	testing.expect_value(t, zeroed.max_output_tokens, 0)
	testing.expect(t, zeroed.input_modalities_present)
	testing.expect_value(t, len(zeroed.input_modalities), 0)
	testing.expect(t, zeroed.output_modalities_present)
	testing.expect_value(t, len(zeroed.output_modalities), 0)
}

@(test)
test_models_dev_parse_ignores_unknown_and_mistyped_fields :: proc(t: ^testing.T) {
	// Upstream carries far more than this harness reads, and must be able to add
	// to it or change a type without taking the catalog down. Every mistyped field
	// below is treated as absent rather than fatal; the record still parses and
	// still states the identity it is keyed on.
	fixture :: `{
	  "gamma": {
	    "id": "gamma",
	    "name": "Gamma",
	    "future_field": {"nested": [1, 2, 3]},
	    "env": "GAMMA_KEY",
	    "npm": "@ai-sdk/some-future-sdk",
	    "api": 42,
	    "models": {
	      "gamma/odd": {
	        "id": "gamma/odd",
	        "name": 7,
	        "reasoning": "yes",
	        "reasoning_options": [{"type": "effort", "values": "low"}, {"type": "budget_tokens", "min": "1024"}],
	        "tool_call": 1,
	        "modalities": {"input": "text"},
	        "limit": {"context": "big", "output": 1.5},
	        "unknown_model_field": true
	      }
	    }
	  }
	}`
	catalog, err := models_dev_parse_text(fixture)
	testing.expect_value(t, err, Models_Dev_Parse_Error.None)
	defer catalog_sources_destroy(&catalog)

	gamma := models_dev_fixture_source(t, "gamma", catalog[:])
	// An unrecognized SDK leaves the protocol unstated rather than guessed.
	testing.expect(t, !gamma.api_present)
	testing.expect(t, !gamma.base_url_present)
	testing.expect(t, !gamma.api_key_present)

	odd := models_dev_fixture_model(t, gamma, "gamma/odd")
	testing.expect(t, !odd.display_name_present)
	testing.expect(t, !odd.context_window_present)
	testing.expect(t, !odd.max_output_tokens_present)
	testing.expect(t, !odd.tools_present)
	testing.expect(t, !odd.input_modalities_present)
	testing.expect(t, !odd.thinking.present)
	testing.expect(t, !odd.thinking.budget.present)
}

@(test)
test_models_dev_parse_drops_non_string_list_entries :: proc(t: ^testing.T) {
	// An effort list is metadata a caller matches by exact value, so a null or a
	// number can never be one of its members and is dropped rather than kept.
	fixture :: `{"delta": {"id": "delta", "npm": "@ai-sdk/openai", "models": {
	  "delta/mixed": {"id": "delta/mixed", "reasoning": true,
	    "reasoning_options": [{"type": "effort", "values": ["low", null, 3, "high"]}],
	    "modalities": {"input": ["text", null], "output": []},
	    "limit": {"context": 1, "output": 1}}}}}`
	catalog, err := models_dev_parse_text(fixture)
	testing.expect_value(t, err, Models_Dev_Parse_Error.None)
	defer catalog_sources_destroy(&catalog)

	delta := models_dev_fixture_source(t, "delta", catalog[:])
	testing.expect_value(t, delta.api, "openai_responses")
	mixed := models_dev_fixture_model(t, delta, "delta/mixed")
	testing.expect(t, mixed.thinking.levels_present)
	testing.expect_value(t, len(mixed.thinking.levels), 2)
	testing.expect_value(t, mixed.thinking.levels[0], "low")
	testing.expect_value(t, mixed.thinking.levels[1], "high")
	testing.expect(t, mixed.input_modalities_present)
	testing.expect_value(t, len(mixed.input_modalities), 1)
	testing.expect(t, mixed.output_modalities_present)
	testing.expect_value(t, len(mixed.output_modalities), 0)
}

@(test)
test_models_dev_parse_skips_a_model_with_its_own_foreign_routing :: proc(t: ^testing.T) {
	// Route metadata is represented per provider, so a model that selects a
	// different API family cannot be stated correctly. Emitting it under its
	// provider's protocol would send the wrong wire format, so it is left out. A
	// model whose own route agrees, or names an SDK this harness does not
	// implement, is kept.
	fixture :: `{"eps": {"id": "eps", "npm": "@ai-sdk/openai-compatible", "models": {
	  "eps/foreign":   {"id": "eps/foreign",   "provider": {"npm": "@ai-sdk/anthropic"}},
	  "eps/other-wire":{"id": "eps/other-wire","provider": {"npm": "@ai-sdk/openai"}},
	  "eps/agreeing":  {"id": "eps/agreeing",  "provider": {"npm": "@ai-sdk/openai-compatible"}},
	  "eps/unknown":   {"id": "eps/unknown",   "provider": {"npm": "@ai-sdk/some-future-sdk"}},
	  "eps/plain":     {"id": "eps/plain"}}}}`
	catalog, err := models_dev_parse_text(fixture)
	testing.expect_value(t, err, Models_Dev_Parse_Error.None)
	defer catalog_sources_destroy(&catalog)

	eps := models_dev_fixture_source(t, "eps", catalog[:])
	testing.expect_value(t, len(eps.models), 3)
	testing.expect(t, models_dev_fixture_model(t, eps, "eps/agreeing") != nil)
	testing.expect(t, models_dev_fixture_model(t, eps, "eps/unknown") != nil)
	testing.expect(t, models_dev_fixture_model(t, eps, "eps/plain") != nil)
	for &model in eps.models {
		testing.expect(t, model.id != "eps/foreign" && model.id != "eps/other-wire")
	}
}

@(test)
test_models_dev_parse_rejects_unusable_input :: proc(t: ^testing.T) {
	cases := []struct {
		body: string,
		err:  Models_Dev_Parse_Error,
	} {


		// Not JSON at all.
		{`{"acme":`, .Invalid_JSON},
		{`not json`, .Invalid_JSON},
		// JSON, but not a document of provider records.
		{`[]`, .Invalid_Structure},
		{`"acme"`, .Invalid_Structure},
		{`{"acme": 1}`, .Invalid_Structure},
		{`{"acme": []}`, .Invalid_Structure},
		// A provider without the models object that associates its models.
		{`{"acme": {"id": "acme"}}`, .Invalid_Structure},
		// Identity that cannot be keyed is refused rather than invented.
		{`{"acme": {"models": {}}}`, .Missing_Identity},
		{`{"acme": {"id": "other", "models": {}}}`, .Missing_Identity},
		{`{"acme": {"id": "acme", "models": {"m": {"name": "no id"}}}}`, .Missing_Identity},
	}
	for entry in cases {
		catalog, err := models_dev_parse_text(entry.body)
		testing.expectf(t, err == entry.err, "%s produced %v, want %v", entry.body, err, entry.err)
		testing.expect_value(t, len(catalog), 0)
		catalog_sources_destroy(&catalog)
	}
}

@(test)
test_models_dev_parse_accepts_a_document_with_no_providers :: proc(t: ^testing.T) {
	catalog, err := models_dev_parse_text(`{}`)
	testing.expect_value(t, err, Models_Dev_Parse_Error.None)
	testing.expect_value(t, len(catalog), 0)
	catalog_sources_destroy(&catalog)
}

@(test)
test_models_dev_parse_feeds_the_resolver_unchanged :: proc(t: ^testing.T) {
	catalog, parse_err := models_dev_parse_text(MODELS_DEV_FIXTURE)
	testing.expect_value(t, parse_err, Models_Dev_Parse_Error.None)
	defer catalog_sources_destroy(&catalog)

	// The parser's output is exactly the resolver's input: no adapter, and user
	// configuration still wins over everything the catalog states.
	user := []Catalog_Provider_Source {
		{id = "acme", models = []Catalog_Model_Source{{id = "acme/thinker", context_window_present = true, context_window = 999}}},
	}
	resolved, resolve_err := resolve_catalog(user, {}, catalog[:])
	testing.expect_value(t, resolve_err, Catalog_Error.None)
	defer catalog_destroy(&resolved)

	thinking := catalog_test_find(resolved, "acme", "acme/thinker")
	testing.expect(t, thinking != nil)
	testing.expect_value(t, thinking.context_window, 999)
	testing.expect_value(t, thinking.display_name, "Acme Thinker")
	testing.expect(t, thinking.thinking.budget.present)
	testing.expect_value(t, thinking.thinking.budget.max, 81920)
	testing.expect_value(t, len(thinking.thinking.levels), 3)

	// Every provider the catalog stated is resolvable, and each model keeps the
	// provider identity from its source record.
	testing.expect_value(t, len(resolved.providers), 2)
	testing.expect(t, catalog_test_find(resolved, "beta", "beta/talker") != nil)
	testing.expect(t, catalog_test_find(resolved, "acme", "acme/plain") != nil)

	// A disabled model is still excluded even when the catalog reports it.
	excluding := []Catalog_Provider_Source{{id = "acme", models = []Catalog_Model_Source{{id = "acme/plain", disabled_present = true, disabled = true}}}}
	excluded, excluded_err := resolve_catalog(excluding, {}, catalog[:])
	testing.expect_value(t, excluded_err, Catalog_Error.None)
	defer catalog_destroy(&excluded)
	testing.expect(t, catalog_test_find(excluded, "acme", "acme/plain") == nil)
	testing.expect(t, catalog_test_find(excluded, "acme", "acme/thinker") != nil)
}

@(test)
test_models_dev_parse_survives_a_cached_document :: proc(t: ^testing.T) {
	// The published catalog is the input this has to survive, so when one has been
	// cached the real file is parsed. The path is resolved without creating it, and
	// nothing here fetches: without a cache the check simply does not run, so no
	// test depends on the network.
	directory, directory_err := xdg_directory(.State, context.temp_allocator)
	if directory_err != .None { return }
	path, join_err := filepath.join([]string{directory, MODELS_DEV_CACHE_FILE}, context.temp_allocator)
	if join_err != nil { return }
	body, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil || len(body) == 0 { return }

	catalog, err := models_dev_parse(body)
	testing.expect_value(t, err, Models_Dev_Parse_Error.None)
	defer catalog_sources_destroy(&catalog)
	testing.expect(t, len(catalog) > 100)
	for &provider in catalog {
		testing.expect(t, provider.id != "")
		testing.expect(t, len(provider.models) > 0)
		for &model in provider.models { testing.expect(t, model.id != "") }
	}
}
