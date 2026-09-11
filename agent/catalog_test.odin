#+test
package agent

import "core:testing"

catalog_test_find :: proc(catalog: Catalog, provider_id, model_id: string) -> ^Catalog_Model {
	for &model in catalog.models {
		if model.provider_id == provider_id && model_id == model.id { return &model }
	}
	return nil
}

@(test)
test_catalog_resolution :: proc(t: ^testing.T) {
	user_models := []Catalog_Model_Source {
		{
			id = "kept",
			context_window_present = true,
			context_window = 500000,
			thinking = Catalog_Thinking_Source{present = true, levels_present = true, levels = []string{"high", "max"}},
		},
		{id = "false-tools", tools_present = true, tools = false},
		{id = "empty-customization", input_modalities_present = true, input_modalities = {}},
		{id = "blocked", thinking = Catalog_Thinking_Source{present = true, blocked = true}},
		{id = "disabled", disabled_present = true, disabled = true},
	}
	provider_models := []Catalog_Model_Source {
		{id = "kept", context_window_present = true, context_window = 750000},
		{id = "false-tools", tools_present = true, tools = true},
		{id = "empty-customization", display_name_present = true, display_name = "Discovered"},
		{
			id = "blocked",
			thinking = Catalog_Thinking_Source {
				present = true,
				supported_present = true,
				supported = true,
				toggle_present = true,
				toggle = true,
				levels_present = true,
				levels = []string{"low"},
			},
		},
		{id = "disabled", context_window_present = true, context_window = 99},
		{id = "remote-only", context_window_present = true, context_window = 333},
	}
	models_dev_models := []Catalog_Model_Source {
		{id = "kept", context_window_present = true, context_window = 1000000},
		{id = "catalog-only", display_name_present = true, display_name = "Catalog"},
		{id = "disabled", display_name_present = true, display_name = "Nope"},
	}
	user := []Catalog_Provider_Source{{id = "exact/provider", models = user_models}}
	provider := []Catalog_Provider_Source{{id = "exact/provider", models = provider_models}}
	models_dev := []Catalog_Provider_Source{{id = "exact/provider", models = models_dev_models}}
	catalog, err := resolve_catalog(user, provider, models_dev)
	testing.expect_value(t, err, Catalog_Error.None)
	defer catalog_destroy(&catalog)

	// The user's window is never replaced by a later source's larger one.
	kept := catalog_test_find(catalog, "exact/provider", "kept")
	testing.expect(t, kept != nil)
	testing.expect_value(t, kept.context_window, 500000)
	testing.expect_value(t, len(kept.thinking.levels), 2)
	testing.expect_value(t, kept.thinking.levels[0], "high")

	// An explicit false is a value, not an absence.
	false_tools := catalog_test_find(catalog, "exact/provider", "false-tools")
	testing.expect(t, false_tools != nil && !false_tools.tools)

	// An explicit empty collection is present and stays empty.
	empty := catalog_test_find(catalog, "exact/provider", "empty-customization")
	testing.expect(t, empty != nil && empty.input_modalities_present)
	testing.expect_value(t, len(empty.input_modalities), 0)

	// A blocked subtree never acquires subordinate controls.
	blocked := catalog_test_find(catalog, "exact/provider", "blocked")
	testing.expect(t, blocked != nil && blocked.thinking.blocked)
	testing.expect(t, !blocked.thinking.toggle_present)
	testing.expect(t, !blocked.thinking.levels_present)

	// An excluded model is neither enriched nor published, by any source.
	testing.expect(t, catalog_test_find(catalog, "exact/provider", "disabled") == nil)

	// Discovery and the shared catalog both extend the model list.
	testing.expect(t, catalog_test_find(catalog, "exact/provider", "remote-only") != nil)
	testing.expect(t, catalog_test_find(catalog, "exact/provider", "catalog-only") != nil)
}

@(test)
test_catalog_rejects_disabled_customization :: proc(t: ^testing.T) {
	user := []Catalog_Provider_Source {
		{id = "p", models = []Catalog_Model_Source{{id = "m", disabled_present = true, disabled = true, tools_present = true, tools = true}}},
	}
	catalog, err := resolve_catalog(user, {}, {})
	testing.expect_value(t, err, Catalog_Error.Invalid_Disabled_Model)
	testing.expect_value(t, len(catalog.models), 0)
	catalog_destroy(&catalog)
}

@(test)
test_catalog_fresh_resolution_updates_remote :: proc(t: ^testing.T) {
	user := []Catalog_Provider_Source{{id = "p", models = []Catalog_Model_Source{{id = "m", display_name_present = true, display_name = "User"}}}}
	remote_1 := []Catalog_Provider_Source{{id = "p", models = []Catalog_Model_Source{{id = "m", context_window_present = true, context_window = 100}}}}
	remote_2 := []Catalog_Provider_Source{{id = "p", models = []Catalog_Model_Source{{id = "m", context_window_present = true, context_window = 200}}}}
	first, first_err := resolve_catalog(user, remote_1, {})
	second, second_err := resolve_catalog(user, remote_2, {})
	testing.expect_value(t, first_err, Catalog_Error.None)
	testing.expect_value(t, second_err, Catalog_Error.None)
	defer catalog_destroy(&first)
	defer catalog_destroy(&second)

	// First-present wins per resolution, not forever: a fresh source snapshot is
	// allowed to update its own value.
	testing.expect_value(t, catalog_test_find(first, "p", "m").context_window, 100)
	testing.expect_value(t, catalog_test_find(second, "p", "m").context_window, 200)
	testing.expect_value(t, catalog_test_find(second, "p", "m").display_name, "User")
}

@(test)
test_catalog_owns_every_retained_string :: proc(t: ^testing.T) {
	// The catalog must copy what it keeps, so a source can free its own buffers
	// immediately after resolution. Every retained string is built in a buffer
	// that is corrupted and released before the catalog is read.
	allocator := context.allocator
	provider_bytes := make([dynamic]u8, 0, 1, allocator)
	model_bytes := make([dynamic]u8, 0, 1, allocator)
	display_bytes := make([dynamic]u8, 0, 4, allocator)
	url_bytes := make([dynamic]u8, 0, 3, allocator)
	api_bytes := make([dynamic]u8, 0, 3, allocator)
	key_bytes := make([dynamic]u8, 0, 3, allocator)
	modality_bytes := make([dynamic]u8, 0, 3, allocator)
	level_bytes := make([dynamic]u8, 0, 4, allocator)

	append(&provider_bytes, 'p')
	append(&model_bytes, 'm')
	append(&display_bytes, ..transmute([]u8)string("User"))
	append(&url_bytes, ..transmute([]u8)string("url"))
	append(&api_bytes, ..transmute([]u8)string("api"))
	append(&key_bytes, ..transmute([]u8)string("KEY"))
	append(&modality_bytes, ..transmute([]u8)string("img"))
	append(&level_bytes, ..transmute([]u8)string("high"))

	source_model := Catalog_Model_Source {
		id = string(model_bytes[:]),
		display_name_present = true,
		display_name = string(display_bytes[:]),
		input_modalities_present = true,
		input_modalities = []string{string(modality_bytes[:])},
		thinking = Catalog_Thinking_Source{present = true, levels_present = true, levels = []string{string(level_bytes[:])}},
	}
	user := []Catalog_Provider_Source {
		{
			id = string(provider_bytes[:]),
			base_url_present = true,
			base_url = string(url_bytes[:]),
			api_present = true,
			api = string(api_bytes[:]),
			api_key_present = true,
			api_key = string(key_bytes[:]),
			models = []Catalog_Model_Source{source_model},
		},
	}
	catalog, err := resolve_catalog(user, {}, {})
	testing.expect_value(t, err, Catalog_Error.None)
	defer catalog_destroy(&catalog)

	for i in 0 ..< len(provider_bytes) { provider_bytes[i] = 'x' }
	for i in 0 ..< len(model_bytes) { model_bytes[i] = 'x' }
	for i in 0 ..< len(display_bytes) { display_bytes[i] = 'x' }
	for i in 0 ..< len(url_bytes) { url_bytes[i] = 'x' }
	for i in 0 ..< len(api_bytes) { api_bytes[i] = 'x' }
	for i in 0 ..< len(key_bytes) { key_bytes[i] = 'x' }
	for i in 0 ..< len(modality_bytes) { modality_bytes[i] = 'x' }
	for i in 0 ..< len(level_bytes) { level_bytes[i] = 'x' }
	delete(provider_bytes)
	delete(model_bytes)
	delete(display_bytes)
	delete(url_bytes)
	delete(api_bytes)
	delete(key_bytes)
	delete(modality_bytes)
	delete(level_bytes)

	provider := catalog.providers[0]
	model := catalog_test_find(catalog, "p", "m")
	testing.expect(t, model != nil)
	testing.expect_value(t, provider.id, "p")
	testing.expect_value(t, provider.base_url, "url")
	testing.expect_value(t, provider.api, "api")
	testing.expect_value(t, provider.api_key, "KEY")
	testing.expect_value(t, model.id, "m")
	testing.expect_value(t, model.display_name, "User")
	testing.expect_value(t, model.input_modalities[0], "img")
	testing.expect_value(t, model.thinking.levels[0], "high")
}
