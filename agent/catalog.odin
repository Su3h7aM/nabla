package agent

import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"

// Provider and model metadata: what a configuration source states, and what the runtime
// reads once that configuration has been resolved.
//
// Every optional field is a Maybe, so an absent value stays
// distinguishable from a present zero. Presence is independent of value: missing permits
// enrichment, while false, zero, and empty are present and final.
//
// A Catalog_*_Source is one source's statement about one entity; resolution merges the
// sources in priority order, first present value wins. Serving identity is the exact,
// case-sensitive pair of provider ID and model ID, never parsed out of a combined string.

// A token-budget control form: the range of reasoning budgets the model accepts.
// Each bound is a Maybe, because upstream states neither, either, or
// both, and a stated bound is a fact rather than a default.
Catalog_Thinking_Budget :: struct {
	present: bool,
	min:     Maybe(int),
	max:     Maybe(int),
}

Catalog_Thinking_Source :: struct {
	present:   bool,
	// A terminal negative. A blocked source prohibits all later thinking
	// enrichment, including its own toggle and level fields.
	blocked:   bool,
	supported: Maybe(bool),
	toggle:    Maybe(bool),
	levels:    Maybe([]string),
	budget:    Catalog_Thinking_Budget,
}

// Catalog_Cost is a model's price in US dollars per million tokens. Each price is a Maybe
// and merges on its own, so a source that states only input and output still
// leaves the cache prices open to enrichment.
Catalog_Cost :: struct {
	input:       Maybe(f64),
	output:      Maybe(f64),
	cache_read:  Maybe(f64),
	cache_write: Maybe(f64),
}

CATALOG_COST_TOKENS_PER_UNIT :: 1_000_000

// catalog_cost_of prices one response's usage. input counts every input token, cache reads
// and cache writes included, which is how every API family's usage is normalized. A cache
// price the model does not state is charged at its input price. It reports false when the
// input or output price, or the input or output count, is missing, because any total built
// without them would understate the cost.
@(require_results)
catalog_cost_of :: proc(cost: Catalog_Cost, input, output, cache_read, cache_write: Maybe(i64)) -> (dollars: f64, ok: bool) {
	input_price := cost.input.? or_return
	output_price := cost.output.? or_return
	input_tokens := input.? or_return
	output_tokens := output.? or_return
	read := cache_read.? or_else 0
	written := cache_write.? or_else 0
	uncached := max(input_tokens - read - written, 0)
	read_price := cost.cache_read.? or_else input_price
	write_price := cost.cache_write.? or_else input_price
	dollars = f64(uncached) * input_price + f64(read) * read_price + f64(written) * write_price + f64(output_tokens) * output_price
	return dollars / CATALOG_COST_TOKENS_PER_UNIT, true
}

Catalog_Model_Source :: struct {
	id:                 string,
	disabled:           Maybe(bool),
	// Absent means the model is served through its provider's family.
	api:                Maybe(string),
	display_name:       Maybe(string),
	context_window:     Maybe(int),
	compaction_trigger: Maybe(int),
	max_output_tokens:  Maybe(int),
	input_modalities:   Maybe([]string),
	output_modalities:  Maybe([]string),
	tools:              Maybe(bool),
	thinking:           Catalog_Thinking_Source,
	cost:               Catalog_Cost,
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
	id:                  string,
	base_url:            Maybe(string),
	api:                 Maybe(string),
	transport:           Maybe(Provider_Transport),
	// stream_idle_timeout is the longest a response of this provider may go without a
	// byte before the attempt is cut. Off by default (zero), because no provider
	// documents an idle limit; the user opts in per provider. It restarts on every byte
	// and never bounds the total time of a response.
	stream_idle_timeout: Maybe(time.Duration),
	// A literal secret, or `${NAME}` naming an environment variable. Resolved
	// only when a connection is built, so no secret is ever held here.
	api_key:             Maybe(string),
	// Read-only during resolution: sources state models, they are not extended
	// by it. The resolved catalog's own list is what grows.
	models:              []Catalog_Model_Source,
}

// Catalog_Model is one resolved model. `provider_id` is part of its identity
// rather than a back-pointer, which keeps the list flat and lookup trivial.
//
// `capacity` is derived, not stated: resolution fills it from the merged window and
// output fields, and everything that needs a context budget reads it from here.
Catalog_Model :: struct {
	provider_id:        string,
	id:                 string,
	// The family this model is served through: its own statement where it has
	// one, otherwise the provider's.
	api:                Maybe(string),
	display_name:       Maybe(string),
	context_window:     Maybe(int),
	compaction_trigger: Maybe(int),
	max_output_tokens:  Maybe(int),
	capacity:           Model_Capacity,
	input_modalities:   Maybe([]string),
	output_modalities:  Maybe([]string),
	tools:              Maybe(bool),
	thinking:           Catalog_Thinking_Source,
	cost:               Catalog_Cost,
}

Catalog_Provider :: struct {
	id:                  string,
	base_url:            Maybe(string),
	api:                 Maybe(string),
	transport:           Maybe(Provider_Transport),
	stream_idle_timeout: Maybe(time.Duration),
	api_key:             Maybe(string),
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

// STREAM_IDLE_TIMEOUT_DEFAULT is how long a provider's response may go without a byte
// before the attempt is cut, when the provider's configuration states no
// `stream_idle_timeout_ms`. It is zero, which is no timeout: no provider documents an
// idle limit, and a long request such as a compaction summary can legitimately stay
// quiet for many minutes, so the harness imposes none until the user asks for one.
STREAM_IDLE_TIMEOUT_DEFAULT :: time.Duration(0)

// catalog_stream_idle_timeout reads the idle timeout of provider_id's responses from the
// live catalog, so a configuration change reaches the next request. A catalog that is
// not published, a provider it does not list, and a provider that states no value get
// STREAM_IDLE_TIMEOUT_DEFAULT. Zero means no timeout, and no other bound is derived from
// the value: it never limits how long a response may take in total.
@(require_results)
catalog_stream_idle_timeout :: proc(ref: Catalog_Ref, provider_id: string) -> time.Duration {
	if ref.catalog == nil { return STREAM_IDLE_TIMEOUT_DEFAULT }
	if ref.mutex != nil {
		sync.mutex_guard(ref.mutex)
		return catalog_provider_idle_timeout(ref.catalog, provider_id)
	}
	return catalog_provider_idle_timeout(ref.catalog, provider_id)
}

@(private, require_results)
catalog_provider_idle_timeout :: proc(catalog: ^Catalog, provider_id: string) -> time.Duration {
	index, found := catalog_find_provider(catalog, provider_id)
	if !found { return STREAM_IDLE_TIMEOUT_DEFAULT }
	provider := &catalog.providers[index]
	return provider.stream_idle_timeout.? or_else STREAM_IDLE_TIMEOUT_DEFAULT
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
			if model.id == model_id && (model.disabled.? or_else false) { return true }
		}
	}
	return false
}

@(require_results)
catalog_model_has_customization :: proc(model: Catalog_Model_Source) -> bool {
	return(
		model.api != nil ||
		model.display_name != nil ||
		model.context_window != nil ||
		model.compaction_trigger != nil ||
		model.max_output_tokens != nil ||
		model.input_modalities != nil ||
		model.output_modalities != nil ||
		model.tools != nil ||
		model.thinking.present ||
		model.cost.input != nil ||
		model.cost.output != nil ||
		model.cost.cache_read != nil ||
		model.cost.cache_write != nil \
	)
}

// catalog_validate_user rejects configuration that could not take effect.
@(require_results)
catalog_validate_user :: proc(user: []Catalog_Provider_Source) -> Catalog_Error {
	for provider in user {
		for model in provider.models {
			if (model.disabled.? or_else false) && catalog_model_has_customization(model) {
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
	dst_supported := dst.supported.? or_else true
	if !src.present || dst.blocked || !dst_supported { return .None }
	src_supported := src.supported.? or_else true
	if src.blocked || !src_supported {
		if !dst.present {
			dst^ = Catalog_Thinking_Source {
				present   = true,
				blocked   = src.blocked,
				supported = src.supported,
			}
		}
		return .None
	}
	if !dst.present { dst.present = true }
	if dst.supported == nil && src.supported != nil {
		dst.supported = src.supported
	}
	if dst.toggle == nil && src.toggle != nil {
		dst.toggle = src.toggle
	}
	if dst.levels == nil && src.levels != nil {
		levels, levels_error := catalog_clone_strings(src.levels.?, allocator)
		if levels_error != nil { return .Allocation }
		dst.levels = levels
	}
	if src.budget.present && !dst.budget.present { dst.budget.present = true }
	if dst.budget.min == nil && src.budget.min != nil {
		dst.budget.min = src.budget.min
	}
	if dst.budget.max == nil && src.budget.max != nil {
		dst.budget.max = src.budget.max
	}
	return .None
}

// catalog_apply_cost enriches a cost record field by field. Each price merges on
// its own, so a source that states only input and output still leaves the cache
// prices open to a later source.
catalog_apply_cost :: proc(dst: ^Catalog_Cost, src: Catalog_Cost) {
	if dst.input == nil && src.input != nil {
		dst.input = src.input
	}
	if dst.output == nil && src.output != nil {
		dst.output = src.output
	}
	if dst.cache_read == nil && src.cache_read != nil {
		dst.cache_read = src.cache_read
	}
	if dst.cache_write == nil && src.cache_write != nil {
		dst.cache_write = src.cache_write
	}
}

@(require_results)
catalog_apply_model :: proc(dst: ^Catalog_Model, src: Catalog_Model_Source, allocator: mem.Allocator) -> Catalog_Error {
	if dst.api == nil && src.api != nil {
		api, api_error := strings.clone(src.api.?, allocator)
		if api_error != nil { return .Allocation }
		dst.api = api
	}
	if dst.display_name == nil && src.display_name != nil {
		display_name, display_name_error := strings.clone(src.display_name.?, allocator)
		if display_name_error != nil { return .Allocation }
		dst.display_name = display_name
	}
	if dst.context_window == nil && src.context_window != nil {
		dst.context_window = src.context_window
	}
	if dst.compaction_trigger == nil && src.compaction_trigger != nil {
		dst.compaction_trigger = src.compaction_trigger
	}
	if dst.max_output_tokens == nil && src.max_output_tokens != nil {
		dst.max_output_tokens = src.max_output_tokens
	}
	if dst.input_modalities == nil && src.input_modalities != nil {
		modalities, modalities_error := catalog_clone_strings(src.input_modalities.?, allocator)
		if modalities_error != nil { return .Allocation }
		dst.input_modalities = modalities
	}
	if dst.output_modalities == nil && src.output_modalities != nil {
		modalities, modalities_error := catalog_clone_strings(src.output_modalities.?, allocator)
		if modalities_error != nil { return .Allocation }
		dst.output_modalities = modalities
	}
	if dst.tools == nil && src.tools != nil {
		dst.tools = src.tools
	}
	catalog_apply_thinking(&dst.thinking, src.thinking, allocator) or_return
	catalog_apply_cost(&dst.cost, src.cost)
	return .None
}

@(require_results)
catalog_apply_provider :: proc(dst: ^Catalog_Provider, src: Catalog_Provider_Source, allocator: mem.Allocator) -> Catalog_Error {
	if dst.base_url == nil && src.base_url != nil {
		base_url, base_url_error := strings.clone(src.base_url.?, allocator)
		if base_url_error != nil { return .Allocation }
		dst.base_url = base_url
	}
	if dst.api == nil && src.api != nil {
		api, api_error := strings.clone(src.api.?, allocator)
		if api_error != nil { return .Allocation }
		dst.api = api
	}
	if dst.transport == nil && src.transport != nil {
		dst.transport = src.transport
	}
	if dst.stream_idle_timeout == nil && src.stream_idle_timeout != nil {
		dst.stream_idle_timeout = src.stream_idle_timeout
	}
	if dst.api_key == nil && src.api_key != nil {
		api_key, api_key_error := strings.clone(src.api_key.?, allocator)
		if api_key_error != nil { return .Allocation }
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
		if provider.base_url != nil { delete(provider.base_url.?, allocator) }
		if provider.api != nil { delete(provider.api.?, allocator) }
		if provider.api_key != nil { delete(provider.api_key.?, allocator) }
	}
	for &model in catalog.models {
		delete(model.provider_id, allocator)
		delete(model.id, allocator)
		if model.api != nil { delete(model.api.?, allocator) }
		if model.display_name != nil { delete(model.display_name.?, allocator) }
		if model.input_modalities != nil { catalog_strings_destroy(model.input_modalities.?, allocator) }
		if model.output_modalities != nil { catalog_strings_destroy(model.output_modalities.?, allocator) }
		if model.thinking.levels != nil { catalog_strings_destroy(model.thinking.levels.?, allocator) }
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
	if model.api != nil { delete(model.api.?, allocator) }
	if model.display_name != nil { delete(model.display_name.?, allocator) }
	if model.input_modalities != nil { catalog_strings_destroy(model.input_modalities.?, allocator) }
	if model.output_modalities != nil { catalog_strings_destroy(model.output_modalities.?, allocator) }
	if model.thinking.levels != nil { catalog_strings_destroy(model.thinking.levels.?, allocator) }
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
	if provider.base_url != nil { delete(provider.base_url.?, allocator) }
	if provider.api != nil { delete(provider.api.?, allocator) }
	if provider.api_key != nil { delete(provider.api_key.?, allocator) }
	catalog_model_sources_destroy(provider.models, allocator)
	provider^ = {}
}

catalog_sources_destroy :: proc(sources: ^[dynamic]Catalog_Provider_Source, allocator := context.allocator) {
	for &provider in sources^ { catalog_provider_source_destroy(&provider, allocator) }
	delete(sources^)
	sources^ = nil
}
