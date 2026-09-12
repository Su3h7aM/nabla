package agent

import "core:encoding/json"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"

// models.dev catalog parsing: bytes in, provider source records out.
//
// The document is models.dev's API representation, a map of provider id to
// provider record, each carrying the models that provider serves. It is external
// input, so it is read defensively. A field of the wrong type is treated as
// absent rather than as a failure -- upstream adding a string where a number used
// to be must not take the harness down -- while identity that is missing is a
// failure, because a source record that cannot be keyed would corrupt the
// resolved catalog rather than merely be incomplete. Unknown fields are ignored:
// models.dev carries far more than this harness reads.
//
// Nothing here decides precedence, exclusion, credentials, or endpoint defaults
// for the user. It only transforms bytes, so it performs no I/O, and its input is
// the raw document the cache layer acquired.

Models_Dev_Parse_Error :: enum {
	None,
	// The bytes are not valid JSON.
	Invalid_JSON,
	// The document is not an object of provider records.
	Invalid_Structure,
	// A provider or model does not state the id its source record is keyed on.
	// A record that cannot be keyed is refused rather than invented.
	Missing_Identity,
}

// models_dev_parse turns a catalog into one source record per provider, each
// holding the models that provider serves. The result is owned by the caller and
// released with catalog_sources_destroy, exactly like the result of the user
// configuration loader, so both are the same kind of resolver input.
//
// `providers` restricts the result to those provider ids; an empty list keeps
// every provider. The resolved catalog only carries providers the user
// configured, so the rest of the document is traversed but never materialized.
models_dev_parse :: proc(data: []u8, providers: []string = {}, allocator := context.allocator) -> ([dynamic]Catalog_Provider_Source, Models_Dev_Parse_Error) {
	// The document is megabyte-scale and its tree is several times that, so the
	// tree lives in a dedicated arena that is unmapped when extraction finishes.
	// The process-wide temp allocator would hold the pages until its next reset.
	ast: virtual.Arena
	if arena_err := virtual.arena_init_growing(&ast); arena_err != nil { return {}, .Invalid_JSON }
	defer virtual.arena_destroy(&ast)

	root, parse_err := json.parse_bytes(data, .JSON, true, virtual.arena_allocator(&ast))
	if parse_err != .None { return {}, .Invalid_JSON }

	root_object, root_is_object := root.(json.Object)
	if !root_is_object { return {}, .Invalid_Structure }

	result: [dynamic]Catalog_Provider_Source
	result.allocator = allocator
	failed := true
	defer if failed {
		for &provider in result { catalog_provider_source_destroy(&provider, allocator) }
		delete(result)
	}

	for provider_id, provider_value in root_object {
		if len(providers) > 0 && !_models_dev_wanted(providers, provider_id) { continue }
		provider_object, provider_is_object := provider_value.(json.Object)
		if !provider_is_object { return {}, .Invalid_Structure }

		// The record's own id is the provider's identity; the map key only
		// reaches it. Both are upstream-controlled, and an identity that is
		// absent cannot be reconstructed from the key without guessing.
		stated_id, id_present := models_dev_member_string(provider_object, "id")
		if !id_present || stated_id != provider_id { return {}, .Missing_Identity }

		models_value, has_models := provider_object["models"]
		models_object, models_is_object := models_value.(json.Object)
		if !has_models || !models_is_object { return {}, .Invalid_Structure }

		provider := models_dev_provider_source(provider_object, stated_id, allocator)
		still_failed := true
		defer if still_failed { catalog_provider_source_destroy(&provider, allocator) }

		models := make([dynamic]Catalog_Model_Source, 0, len(models_object), allocator)
		// The models are handed to the provider on success; until then this loop owns
		// them, so a refusal part-way through releases what it built.
		models_owned := true
		defer if models_owned {
			for &model in models { catalog_model_source_destroy(&model, allocator) }
			delete(models)
		}
		for _, model_value in models_object {
			model_object, model_is_object := model_value.(json.Object)
			if !model_is_object { return {}, .Invalid_Structure }
			model_id, model_id_present := models_dev_member_string(model_object, "id")
			if !model_id_present || model_id == "" { return {}, .Missing_Identity }

			model, skip := models_dev_model_source(model_object, provider.api, allocator)
			if skip { continue }
			model.id = strings.clone(model_id, allocator)
			append(&models, model)
		}
		provider.models = models[:]
		slice.sort_by(provider.models, models_dev_model_less)
		models_owned = false

		append(&result, provider)
		still_failed = false
	}

	failed = false
	// The document is a JSON object, so its members arrive in hash order. Sorting
	// by id keeps the result fully deterministic, so a catalog that changed order
	// between runs cannot make diagnostics or first-match logic unstable.
	slice.sort_by(result[:], models_dev_provider_less)
	return result, .None
}

models_dev_provider_less :: proc(a, b: Catalog_Provider_Source) -> bool { return a.id < b.id }
models_dev_model_less :: proc(a, b: Catalog_Model_Source) -> bool { return a.id < b.id }

// models_dev_provider_source maps the provider fields that the source type can
// represent. Everything else models.dev states about a provider -- its display
// name, documentation link, and SDK version among them -- has no consumer here.
models_dev_provider_source :: proc(object: json.Object, provider_id: string, allocator: mem.Allocator) -> Catalog_Provider_Source {
	provider := Catalog_Provider_Source {
		id = strings.clone(provider_id, allocator),
	}
	// The endpoint the provider's SDK talks to. Providers that rely on their
	// SDK's built-in default do not state one, and leaving it absent is what makes
	// the provider require an explicit base_url in configuration.
	if base_url, base_url_present := models_dev_member_string(object, "api"); base_url_present && base_url != "" {
		provider.base_url_present = true
		provider.base_url = strings.clone(base_url, allocator)
	}
	if npm, npm_present := models_dev_member_string(object, "npm"); npm_present {
		if api, api_known := models_dev_api_family(npm); api_known {
			provider.api_present = true
			provider.api = strings.clone(api, allocator)
		}
	}
	// The catalog names the environment variable a credential is read from. Only
	// the first is the credential: a later entry is a project, location, or
	// account the SDK also needs, not an interchangeable key.
	if variables, variables_present := models_dev_member_strings(object, "env", allocator); variables_present {
		defer catalog_strings_destroy(variables, allocator)
		if len(variables) > 0 && variables[0] != "" {
			provider.api_key_present = true
			provider.api_key = strings.concatenate([]string{"${", variables[0], "}"}, allocator = allocator)
		}
	}
	return provider
}

// models_dev_model_source maps one provider-nested model record. `skip` reports a
// model whose own routing selects a different API family than its provider's:
// routing is represented per provider in the source records, so such a model
// cannot be stated correctly and is left out rather than emitted under the wrong
// wire protocol. A model is only skipped when both families are known and
// disagree; an unstated family on either side is not a conflict.
models_dev_model_source :: proc(object: json.Object, provider_api: string, allocator: mem.Allocator) -> (model: Catalog_Model_Source, skip: bool) {
	if override_value, has_override := object["provider"]; has_override {
		if override, override_is_object := override_value.(json.Object); override_is_object {
			if npm, npm_present := models_dev_member_string(override, "npm"); npm_present {
				if override_api, override_known := models_dev_api_family(npm); override_known {
					if provider_api != "" && override_api != provider_api { return {}, true }
				}
			}
		}
	}

	if display_name, display_name_present := models_dev_member_string(object, "name"); display_name_present {
		model.display_name_present = true
		model.display_name = strings.clone(display_name, allocator)
	}
	if limit_value, has_limit := object["limit"]; has_limit {
		if limit, limit_is_object := limit_value.(json.Object); limit_is_object {
			if context_window, context_present := models_dev_member_integer(limit, "context"); context_present {
				model.context_window_present = true
				model.context_window = context_window
			}
			if output, output_present := models_dev_member_integer(limit, "output"); output_present {
				model.max_output_tokens_present = true
				model.max_output_tokens = output
			}
		}
	}
	if modalities_value, has_modalities := object["modalities"]; has_modalities {
		if modalities, modalities_is_object := modalities_value.(json.Object); modalities_is_object {
			if input, input_present := models_dev_member_strings(modalities, "input", allocator); input_present {
				model.input_modalities_present = true
				model.input_modalities = input
			}
			if output, output_present := models_dev_member_strings(modalities, "output", allocator); output_present {
				model.output_modalities_present = true
				model.output_modalities = output
			}
		}
	}
	if tools, tools_present := models_dev_member_bool(object, "tool_call"); tools_present {
		model.tools_present = true
		model.tools = tools
	}
	model.thinking = models_dev_thinking(object, allocator)
	return model, false
}

// models_dev_thinking maps the reasoning fields of one model. `reasoning` is the
// support flag every record carries, and `reasoning_options` adds the control
// forms the provider accepts, which are independent of one another.
models_dev_thinking :: proc(object: json.Object, allocator: mem.Allocator) -> Catalog_Thinking_Source {
	thinking: Catalog_Thinking_Source
	supported, supported_present := models_dev_member_bool(object, "reasoning")
	if !supported_present { return thinking }
	thinking.present = true
	thinking.supported_present = true
	thinking.supported = supported
	// A model that cannot reason is a terminal negative: no control form below it
	// can apply, and resolution relies on that to block the whole subtree.
	if !supported {
		thinking.blocked = true
		return thinking
	}
	options_value, has_options := object["reasoning_options"]
	if !has_options { return thinking }
	options, options_is_array := options_value.(json.Array)
	if !options_is_array { return thinking }

	for option in options {
		option_object, option_is_object := option.(json.Object)
		if !option_is_object { continue }
		kind, kind_present := models_dev_member_string(option_object, "type")
		if !kind_present { continue }
		switch kind {
		case "toggle":
			thinking.toggle_present = true
			thinking.toggle = true
		case "effort":
			// The first effort list wins, and one is kept at most, so a record
			// that repeats the control form cannot leak the earlier list.
			if thinking.levels_present { continue }
			if levels, levels_present := models_dev_member_strings(option_object, "values", allocator); levels_present {
				thinking.levels_present = true
				thinking.levels = levels
			}
		case "budget_tokens":
			thinking.budget.present = true
			if minimum, minimum_present := models_dev_member_integer(option_object, "min"); minimum_present {
				thinking.budget.min_present = true
				thinking.budget.min = minimum
			}
			if maximum, maximum_present := models_dev_member_integer(option_object, "max"); maximum_present {
				thinking.budget.max_present = true
				thinking.budget.max = maximum
			}
		case:
		// A control form this harness does not implement is ignored rather
		// than guessed at.
		}
	}
	return thinking
}

// models_dev_api_family translates the package that speaks a provider's wire
// protocol into the API family this harness implements.
//
// Only identifiers whose protocol is unambiguous appear here. @ai-sdk/openai
// defaults to the Responses API, while @ai-sdk/openai-compatible speaks Chat
// Completions. An SDK for another vendor, or a gateway package, is left unstated
// so the provider requires an explicit api in configuration instead of being sent
// the wrong wire format.
models_dev_api_family :: proc(npm: string) -> (api: string, known: bool) {
	switch npm {
	case "@ai-sdk/openai":
		return "openai_responses", true
	case "@ai-sdk/openai-compatible":
		return "openai_chat_completions", true
	case "@ai-sdk/anthropic":
		return "anthropic_messages", true
	}
	return "", false
}

// _models_dev_wanted reports whether a provider id is one of the ids the caller
// asked for. The configured set is small, so a scan beats a lookup structure.
@(private)
_models_dev_wanted :: proc(providers: []string, id: string) -> bool {
	for provider in providers { if provider == id { return true } }
	return false
}

models_dev_member_string :: proc(object: json.Object, key: string) -> (value: string, present: bool) {
	member, found := object[key]
	if !found { return "", false }
	text, is_string := member.(json.String)
	if !is_string { return "", false }
	return string(text), true
}

models_dev_member_bool :: proc(object: json.Object, key: string) -> (value: bool, present: bool) {
	member, found := object[key]
	if !found { return false, false }
	flag, is_bool := member.(json.Boolean)
	if !is_bool { return false, false }
	return bool(flag), true
}

// models_dev_member_integer reads a member that must be a non-negative integer. A
// fractional value is refused rather than truncated: a limit is a count, and
// rounding one would invent a number upstream did not state.
models_dev_member_integer :: proc(object: json.Object, key: string) -> (value: int, present: bool) {
	member, found := object[key]
	if !found { return 0, false }
	number, is_integer := member.(json.Integer)
	if !is_integer || number < 0 { return 0, false }
	return int(number), true
}

// models_dev_member_strings reads a member that must be an array of strings. The
// list is copied, because the parsed document is released as soon as parsing
// finishes. A non-string element is dropped rather than failing the catalog: the
// list is metadata a caller matches against by exact value, so a malformed entry
// can never be one of them.
models_dev_member_strings :: proc(object: json.Object, key: string, allocator: mem.Allocator) -> (values: []string, present: bool) {
	member, found := object[key]
	if !found { return nil, false }
	array, is_array := member.(json.Array)
	if !is_array { return nil, false }

	collected: [dynamic]string
	collected.allocator = allocator
	for element in array {
		text, is_string := element.(json.String)
		if !is_string { continue }
		append(&collected, strings.clone(string(text), allocator))
	}
	// The result is a slice the catalog's own release routine can free, so it is
	// copied out of the accumulator rather than sharing its capacity.
	result := make([]string, len(collected), allocator)
	copy(result, collected[:])
	delete(collected)
	return result, true
}
