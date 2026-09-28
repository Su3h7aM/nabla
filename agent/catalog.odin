package agent

import "core:mem"
import "core:strings"

// Provider and model metadata: what a configuration source states, and what the runtime
// reads once that configuration has been resolved.
//
// Every optional field carries an explicit presence flag, so an absent value stays
// distinguishable from a present zero. Presence is independent of value: missing permits
// enrichment, while false, zero, and empty are present and final.
//
// A Catalog_*_Source is one source's statement about one entity; resolution merges the
// sources in priority order, first present value wins. Serving identity is the exact,
// case-sensitive pair of provider ID and model ID, never parsed out of a combined string.

// A token-budget control form: the range of reasoning budgets the model accepts.
// Each bound has its own presence, because upstream states neither, either, or
// both, and a stated bound is a fact rather than a default.
Catalog_Thinking_Budget :: struct {
	present:     bool,
	min_present: bool,
	min:         int,
	max_present: bool,
	max:         int,
}

Catalog_Thinking_Source :: struct {
	present:           bool,
	// A terminal negative. A blocked source prohibits all later thinking
	// enrichment, including its own toggle and level fields.
	blocked:           bool,
	supported_present: bool,
	supported:         bool,
	toggle_present:    bool,
	toggle:            bool,
	levels_present:    bool,
	levels:            []string,
	budget:            Catalog_Thinking_Budget,
}

Catalog_Model_Source :: struct {
	id:                        string,
	disabled_present:          bool,
	disabled:                  bool,
	// Absent means the model is served through its provider's family.
	api_present:               bool,
	api:                       string,
	display_name_present:      bool,
	display_name:              string,
	context_window_present:    bool,
	context_window:            int,
	max_output_tokens_present: bool,
	max_output_tokens:         int,
	input_modalities_present:  bool,
	input_modalities:          []string,
	output_modalities_present: bool,
	output_modalities:         []string,
	tools_present:             bool,
	tools:                     bool,
	thinking:                  Catalog_Thinking_Source,
}

Provider_Transport :: enum {
	HTTP,
	WebSocket,
	Auto,
}

provider_transport_name :: proc(transport: Provider_Transport) -> string {
	switch transport {
	case .HTTP:
		return "http"
	case .WebSocket:
		return "websocket"
	case .Auto:
		return "auto"
	}
	return "http"
}

Catalog_Provider_Source :: struct {
	id:                string,
	base_url_present:  bool,
	base_url:          string,
	api_present:       bool,
	api:               string,
	transport_present: bool,
	transport:         Provider_Transport,
	// A literal secret, or `${NAME}` naming an environment variable. Resolved
	// only when a connection is built, so no secret is ever held here.
	api_key_present:   bool,
	api_key:           string,
	// Read-only during resolution: sources state models, they are not extended
	// by it. The resolved catalog's own list is what grows.
	models:            []Catalog_Model_Source,
}

// Catalog_Model is one resolved model. `provider_id` is part of its identity
// rather than a back-pointer, which keeps the list flat and lookup trivial.
//
// `capacity` is derived, not stated: resolution fills it from the merged window and
// output fields, and everything that needs a context budget reads it from here.
Catalog_Model :: struct {
	provider_id:               string,
	id:                        string,
	// The family this model is served through: its own statement where it has
	// one, otherwise the provider's.
	api_present:               bool,
	api:                       string,
	display_name:              string,
	display_name_present:      bool,
	context_window:            int,
	context_window_present:    bool,
	max_output_tokens:         int,
	max_output_tokens_present: bool,
	capacity:                  Model_Capacity,
	input_modalities:          []string,
	input_modalities_present:  bool,
	output_modalities:         []string,
	output_modalities_present: bool,
	tools:                     bool,
	tools_present:             bool,
	thinking:                  Catalog_Thinking_Source,
}

Catalog_Provider :: struct {
	id:                string,
	base_url:          string,
	base_url_present:  bool,
	api:               string,
	api_present:       bool,
	transport:         Provider_Transport,
	transport_present: bool,
	api_key_present:   bool,
	api_key:           string,
}

Catalog_Error :: enum {
	None,
	// A model was excluded and customized at once. The capability fields would
	// be silently ignored, so the configuration is rejected instead.
	Invalid_Disabled_Model,
	// A resolved entry could not be built because an allocation failed.
	Allocation,
}

// Catalog is the single source of truth for provider and model metadata. The
// runtime reads metadata from here and nowhere else.
Catalog :: struct {
	providers: [dynamic]Catalog_Provider,
	models:    [dynamic]Catalog_Model,
	allocator: mem.Allocator,
}

@(require_results)
catalog_find_provider :: proc(catalog: ^Catalog, id: string) -> (int, bool) {
	for provider, index in catalog.providers {
		if provider.id == id { return index, true }
	}
	return 0, false
}

@(require_results)
catalog_find_model :: proc(catalog: ^Catalog, provider_id, model_id: string) -> (int, bool) {
	for model, index in catalog.models {
		if model.provider_id == provider_id && model.id == model_id { return index, true }
	}
	return 0, false
}

// catalog_model returns the resolved entry for a serving identity, or nil when the
// catalog has none.
@(require_results)
catalog_model :: proc(catalog: ^Catalog, provider_id, model_id: string) -> (^Catalog_Model, bool) {
	index, found := catalog_find_model(catalog, provider_id, model_id)
	if !found { return nil, false }
	return &catalog.models[index], true
}

// catalog_has_disabled reports whether the user configuration excludes a model.
// Exclusions are user-owned policy, so they are read from the user sources
// rather than inferred from whatever a later source reports.
@(require_results)
catalog_has_disabled :: proc(provider_id, model_id: string, user: []Catalog_Provider_Source) -> bool {
	for provider in user {
		if provider.id != provider_id { continue }
		for model in provider.models {
			if model.id == model_id && model.disabled_present && model.disabled { return true }
		}
	}
	return false
}

@(require_results)
catalog_model_has_customization :: proc(model: Catalog_Model_Source) -> bool {
	return(
		model.display_name_present ||
		model.context_window_present ||
		model.max_output_tokens_present ||
		model.input_modalities_present ||
		model.output_modalities_present ||
		model.tools_present ||
		model.thinking.present \
	)
}

// catalog_validate_user rejects configuration that could not take effect.
@(require_results)
catalog_validate_user :: proc(user: []Catalog_Provider_Source) -> Catalog_Error {
	for provider in user {
		for model in provider.models {
			if model.disabled_present && model.disabled && catalog_model_has_customization(model) {
				return .Invalid_Disabled_Model
			}
		}
	}
	return .None
}

// catalog_clone_strings copies a string list, and releases what it copied when an
// allocation fails part-way through.
@(require_results)
catalog_clone_strings :: proc(values: []string, allocator: mem.Allocator) -> ([]string, mem.Allocator_Error) {
	result, result_error := make([]string, len(values), allocator)
	if result_error != nil { return nil, result_error }
	for value, index in values {
		result[index], result_error = strings.clone(value, allocator)
		if result_error != nil {
			for owned in result[:index] { delete(owned, allocator) }
			delete(result, allocator)
			return nil, result_error
		}
	}
	return result, nil
}

// catalog_apply_thinking enriches a thinking record field by field, and stops
// entirely once the subtree is blocked. A model that cannot think must not
// acquire a level list, and neither must a model whose support is unresolved in
// the negative.
@(require_results)
catalog_apply_thinking :: proc(dst: ^Catalog_Thinking_Source, src: Catalog_Thinking_Source, allocator: mem.Allocator) -> Catalog_Error {
	if !src.present || dst.blocked || (dst.supported_present && !dst.supported) { return .None }
	if src.blocked || (src.supported_present && !src.supported) {
		if !dst.present {
			dst^ = Catalog_Thinking_Source {
				present           = true,
				blocked           = src.blocked,
				supported_present = src.supported_present,
				supported         = src.supported,
			}
		}
		return .None
	}
	if !dst.present { dst.present = true }
	if !dst.supported_present && src.supported_present {
		dst.supported_present = true
		dst.supported = src.supported
	}
	if !dst.toggle_present && src.toggle_present {
		dst.toggle_present = true
		dst.toggle = src.toggle
	}
	if !dst.levels_present && src.levels_present {
		levels, levels_error := catalog_clone_strings(src.levels, allocator)
		if levels_error != nil { return .Allocation }
		dst.levels_present = true
		dst.levels = levels
	}
	if src.budget.present && !dst.budget.present { dst.budget.present = true }
	if !dst.budget.min_present && src.budget.min_present {
		dst.budget.min_present = true
		dst.budget.min = src.budget.min
	}
	if !dst.budget.max_present && src.budget.max_present {
		dst.budget.max_present = true
		dst.budget.max = src.budget.max
	}
	return .None
}

@(require_results)
catalog_apply_model :: proc(dst: ^Catalog_Model, src: Catalog_Model_Source, allocator: mem.Allocator) -> Catalog_Error {
	if !dst.api_present && src.api_present {
		api, api_error := strings.clone(src.api, allocator)
		if api_error != nil { return .Allocation }
		dst.api_present = true
		dst.api = api
	}
	if !dst.display_name_present && src.display_name_present {
		display_name, display_name_error := strings.clone(src.display_name, allocator)
		if display_name_error != nil { return .Allocation }
		dst.display_name_present = true
		dst.display_name = display_name
	}
	if !dst.context_window_present && src.context_window_present {
		dst.context_window_present = true
		dst.context_window = src.context_window
	}
	if !dst.max_output_tokens_present && src.max_output_tokens_present {
		dst.max_output_tokens_present = true
		dst.max_output_tokens = src.max_output_tokens
	}
	if !dst.input_modalities_present && src.input_modalities_present {
		modalities, modalities_error := catalog_clone_strings(src.input_modalities, allocator)
		if modalities_error != nil { return .Allocation }
		dst.input_modalities_present = true
		dst.input_modalities = modalities
	}
	if !dst.output_modalities_present && src.output_modalities_present {
		modalities, modalities_error := catalog_clone_strings(src.output_modalities, allocator)
		if modalities_error != nil { return .Allocation }
		dst.output_modalities_present = true
		dst.output_modalities = modalities
	}
	if !dst.tools_present && src.tools_present {
		dst.tools_present = true
		dst.tools = src.tools
	}
	catalog_apply_thinking(&dst.thinking, src.thinking, allocator) or_return
	return .None
}

@(require_results)
catalog_apply_provider :: proc(dst: ^Catalog_Provider, src: Catalog_Provider_Source, allocator: mem.Allocator) -> Catalog_Error {
	if !dst.base_url_present && src.base_url_present {
		base_url, base_url_error := strings.clone(src.base_url, allocator)
		if base_url_error != nil { return .Allocation }
		dst.base_url_present = true
		dst.base_url = base_url
	}
	if !dst.api_present && src.api_present {
		api, api_error := strings.clone(src.api, allocator)
		if api_error != nil { return .Allocation }
		dst.api_present = true
		dst.api = api
	}
	if !dst.transport_present && src.transport_present {
		dst.transport_present = true
		dst.transport = src.transport
	}
	if !dst.api_key_present && src.api_key_present {
		api_key, api_key_error := strings.clone(src.api_key, allocator)
		if api_key_error != nil { return .Allocation }
		dst.api_key_present = true
		dst.api_key = api_key
	}
	return .None
}

// catalog_apply_source merges one source into the resolved catalog. Sources are
// never mutated and the published catalog is never rebuilt in place: a refresh
// resolves again from the current source snapshots.
//
// Linear scans over the resolved lists are deliberate at this scale; the
// alternative is a lookup map that nothing yet needs.
@(require_results)
catalog_apply_source :: proc(
	catalog: ^Catalog,
	source: []Catalog_Provider_Source,
	user: []Catalog_Provider_Source,
	allocator: mem.Allocator,
) -> Catalog_Error {
	for provider_source in source {
		provider_index, found := catalog_find_provider(catalog, provider_source.id)
		if !found {
			id, id_error := strings.clone(provider_source.id, allocator)
			if id_error != nil { return .Allocation }
			if _, append_error := append(&catalog.providers, Catalog_Provider{id = id}); append_error != nil {
				delete(id, allocator)
				return .Allocation
			}
			provider_index = len(catalog.providers) - 1
		}
		catalog_apply_provider(&catalog.providers[provider_index], provider_source, allocator) or_return
		for model_source in provider_source.models {
			// An excluded model is not enriched and does not appear in the
			// resolved list. It is a tombstone, not a selectable placeholder.
			if catalog_has_disabled(provider_source.id, model_source.id, user) { continue }
			model_index, model_found := catalog_find_model(catalog, provider_source.id, model_source.id)
			if !model_found {
				provider_id, provider_error := strings.clone(provider_source.id, allocator)
				if provider_error != nil { return .Allocation }
				model_id, model_id_error := strings.clone(model_source.id, allocator)
				if model_id_error != nil {
					delete(provider_id, allocator)
					return .Allocation
				}
				if _, append_error := append(&catalog.models, Catalog_Model{provider_id = provider_id, id = model_id}); append_error != nil {
					delete(provider_id, allocator)
					delete(model_id, allocator)
					return .Allocation
				}
				model_index = len(catalog.models) - 1
			}
			catalog_apply_model(&catalog.models[model_index], model_source, allocator) or_return
		}
	}
	return .None
}

// resolve_catalog builds the catalog from the three sources in priority order.
// Loading order is not merge priority: every source is an independent input, and
// the first one to define a field keeps it.
@(require_results)
resolve_catalog :: proc(user, provider, models_dev: []Catalog_Provider_Source, allocator := context.allocator) -> (Catalog, Catalog_Error) {
	if err := catalog_validate_user(user); err != .None { return {}, err }
	result := Catalog {
		allocator = allocator,
	}
	for source in ([3][]Catalog_Provider_Source{user, provider, models_dev}) {
		if err := catalog_apply_source(&result, source, user, allocator); err != .None {
			// A half-merged catalog is released; the caller retries or reports.
			catalog_destroy(&result)
			return {}, err
		}
	}
	// The budget is derived after every source has had its say, so it cannot be
	// computed from a half-merged window.
	for &model in result.models { model.capacity = model_capacity(model) }
	return result, .None
}

catalog_destroy :: proc(catalog: ^Catalog) {
	if catalog == nil { return }
	allocator := catalog.allocator
	for &provider in catalog.providers {
		delete(provider.id, allocator)
		if provider.base_url_present { delete(provider.base_url, allocator) }
		if provider.api_present { delete(provider.api, allocator) }
		if provider.api_key_present { delete(provider.api_key, allocator) }
	}
	for &model in catalog.models {
		delete(model.provider_id, allocator)
		delete(model.id, allocator)
		if model.api_present { delete(model.api, allocator) }
		if model.display_name_present { delete(model.display_name, allocator) }
		if model.input_modalities_present { catalog_strings_destroy(model.input_modalities, allocator) }
		if model.output_modalities_present { catalog_strings_destroy(model.output_modalities, allocator) }
		if model.thinking.levels_present { catalog_strings_destroy(model.thinking.levels, allocator) }
	}
	delete(catalog.models)
	delete(catalog.providers)
	catalog^ = {}
}

catalog_strings_destroy :: proc(values: []string, allocator: mem.Allocator) {
	for value in values { delete(value, allocator) }
	if values != nil { delete(values, allocator) }
}

// The source types have their own release routines: a source owns the strings it
// states, and resolution copies everything it keeps.
catalog_model_source_destroy :: proc(model: ^Catalog_Model_Source, allocator: mem.Allocator) {
	if model == nil { return }
	delete(model.id, allocator)
	if model.api_present { delete(model.api, allocator) }
	if model.display_name_present { delete(model.display_name, allocator) }
	if model.input_modalities_present { catalog_strings_destroy(model.input_modalities, allocator) }
	if model.output_modalities_present { catalog_strings_destroy(model.output_modalities, allocator) }
	if model.thinking.levels_present { catalog_strings_destroy(model.thinking.levels, allocator) }
	model^ = {}
}

// catalog_model_sources_destroy releases a model source list that no provider owns.
catalog_model_sources_destroy :: proc(models: []Catalog_Model_Source, allocator: mem.Allocator) {
	for &model in models { catalog_model_source_destroy(&model, allocator) }
	if models != nil { delete(models, allocator) }
}

catalog_provider_source_destroy :: proc(provider: ^Catalog_Provider_Source, allocator: mem.Allocator) {
	if provider == nil { return }
	delete(provider.id, allocator)
	if provider.base_url_present { delete(provider.base_url, allocator) }
	if provider.api_present { delete(provider.api, allocator) }
	if provider.api_key_present { delete(provider.api_key, allocator) }
	catalog_model_sources_destroy(provider.models, allocator)
	provider^ = {}
}

catalog_sources_destroy :: proc(sources: ^[dynamic]Catalog_Provider_Source, allocator := context.allocator) {
	for &provider in sources^ { catalog_provider_source_destroy(&provider, allocator) }
	delete(sources^)
	sources^ = nil
}
