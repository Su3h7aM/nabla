package agent

import "core:encoding/json"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"

// models.dev catalog parsing: bytes in, provider source records out.
//
// A field of the wrong type is treated as absent and an unknown field is ignored, while a
// missing identity is a failure: a source record that cannot be keyed would corrupt the
// resolved catalog. Precedence, exclusion, credentials, and endpoint defaults are decided
// elsewhere; this transforms bytes and performs no I/O.

Models_Dev_Parse_Error :: enum {
	None,
	// A source record could not be built because an allocation failed.
	Allocation,
	// The bytes are not valid JSON.
	Invalid_JSON,
	// The document is not an object of provider records.
	Invalid_Structure,
	// A provider or model does not state the id its source record is keyed on.
	// A record that cannot be keyed is refused rather than invented.
	Missing_Identity,
}

// models_dev_parse turns a catalog into one source record per provider, each holding the
// models that provider serves. `providers` restricts the result to those provider ids; an
// empty list keeps every provider. The result is owned by the caller and released with
// catalog_sources_destroy.
@(require_results)
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

		provider: Catalog_Provider_Source
		if provider_error := models_dev_provider_source(provider_object, stated_id, allocator, &provider); provider_error != nil {
			return {}, .Allocation
		}
		still_failed := true
		defer if still_failed { catalog_provider_source_destroy(&provider, allocator) }

		models, models_error := make([dynamic]Catalog_Model_Source, 0, len(models_object), allocator)
		if models_error != nil { return {}, .Allocation }
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

			model: Catalog_Model_Source
			if model_error := models_dev_model_source(model_object, allocator, &model); model_error != nil { return {}, .Allocation }
			model.id, models_error = strings.clone(model_id, allocator)
			if models_error != nil {
				catalog_model_source_destroy(&model, allocator)
				return {}, .Allocation
			}
			if _, models_error = append(&models, model); models_error != nil {
				catalog_model_source_destroy(&model, allocator)
				return {}, .Allocation
			}
		}
		provider.models = models[:]
		slice.sort_by(provider.models, models_dev_model_less)
		models_owned = false

		if _, append_error := append(&result, provider); append_error != nil { return {}, .Allocation }
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
// represent into out. Everything else models.dev states about a provider -- its
// display name, documentation link, and SDK version among them -- has no consumer
// here. A failure releases what it built and leaves out empty.
@(require_results)
models_dev_provider_source :: proc(object: json.Object, provider_id: string, allocator: mem.Allocator, out: ^Catalog_Provider_Source) -> mem.Allocator_Error {
	failed := true
	defer if failed { catalog_provider_source_destroy(out, allocator) }
	out.id = strings.clone(provider_id, allocator) or_return
	// The endpoint the provider's SDK talks to. Providers that rely on their
	// SDK's built-in default do not state one, and leaving it absent is what makes
	// the provider require an explicit base_url in configuration.
	if base_url, base_url_present := models_dev_member_string(object, "api"); base_url_present && base_url != "" {
		out.base_url = strings.clone(base_url, allocator) or_return
		out.base_url_present = true
	}
	if npm, npm_present := models_dev_member_string(object, "npm"); npm_present {
		if api, api_known := models_dev_api_family(npm); api_known {
			out.api = strings.clone(api, allocator) or_return
			out.api_present = true
		}
	}
	// The catalog names the environment variable a credential is read from. Only
	// the first is the credential: a later entry is a project, location, or
	// account the SDK also needs, not an interchangeable key.
	variables, variables_present, variables_error := models_dev_member_strings(object, "env", allocator)
	if variables_error != nil { return variables_error }
	if variables_present {
		defer catalog_strings_destroy(variables, allocator)
		if len(variables) > 0 && variables[0] != "" {
			out.api_key = strings.concatenate([]string{"${", variables[0], "}"}, allocator = allocator) or_return
			out.api_key_present = true
		}
	}
	failed = false
	return nil
}

// models_dev_model_source maps one provider-nested model record into out. A model that names
// its own SDK is served through that family regardless of its provider's. The family is stated
// only when it is one this harness implements, so an unrecognized one leaves the provider's. A
// failure releases what it built and leaves out empty.
@(require_results)
models_dev_model_source :: proc(object: json.Object, allocator: mem.Allocator, out: ^Catalog_Model_Source) -> mem.Allocator_Error {
	failed := true
	defer if failed { catalog_model_source_destroy(out, allocator) }
	if override_value, has_override := object["provider"]; has_override {
		if override, override_is_object := override_value.(json.Object); override_is_object {
			if npm, npm_present := models_dev_member_string(override, "npm"); npm_present {
				if api, api_known := models_dev_api_family(npm); api_known {
					out.api = strings.clone(api, allocator) or_return
					out.api_present = true
				}
			}
		}
	}

	if display_name, display_name_present := models_dev_member_string(object, "name"); display_name_present {
		out.display_name = strings.clone(display_name, allocator) or_return
		out.display_name_present = true
	}
	if limit_value, has_limit := object["limit"]; has_limit {
		if limit, limit_is_object := limit_value.(json.Object); limit_is_object {
			if context_window, context_present := models_dev_member_integer(limit, "context"); context_present {
				out.context_window_present = true
				out.context_window = context_window
			}
			if output, output_present := models_dev_member_integer(limit, "output"); output_present {
				out.max_output_tokens_present = true
				out.max_output_tokens = output
			}
		}
	}
	if modalities_value, has_modalities := object["modalities"]; has_modalities {
		if modalities, modalities_is_object := modalities_value.(json.Object); modalities_is_object {
			input, input_present, input_error := models_dev_member_strings(modalities, "input", allocator)
			if input_error != nil { return input_error }
			if input_present {
				out.input_modalities_present = true
				out.input_modalities = input
			}
			output, output_present, output_error := models_dev_member_strings(modalities, "output", allocator)
			if output_error != nil { return output_error }
			if output_present {
				out.output_modalities_present = true
				out.output_modalities = output
			}
		}
	}
	if tools, tools_present := models_dev_member_bool(object, "tool_call"); tools_present {
		out.tools_present = true
		out.tools = tools
	}
	models_dev_thinking(object, allocator, &out.thinking) or_return
	failed = false
	return nil
}

// models_dev_thinking maps the reasoning fields of one model into out. `reasoning` is the
// support flag every record carries, and `reasoning_options` adds the control forms the
// provider accepts, which are independent of one another. out owns nothing until a level
// list is read, and that is the last thing this can fail on.
@(require_results)
models_dev_thinking :: proc(object: json.Object, allocator: mem.Allocator, out: ^Catalog_Thinking_Source) -> mem.Allocator_Error {
	supported, supported_present := models_dev_member_bool(object, "reasoning")
	if !supported_present { return nil }
	out.present = true
	out.supported_present = true
	out.supported = supported
	// A model that cannot reason is a terminal negative: no control form below it
	// can apply, and resolution relies on that to block the whole subtree.
	if !supported {
		out.blocked = true
		return nil
	}
	options_value, has_options := object["reasoning_options"]
	if !has_options { return nil }
	options, options_is_array := options_value.(json.Array)
	if !options_is_array { return nil }

	for option in options {
		option_object, option_is_object := option.(json.Object)
		if !option_is_object { continue }
		kind, kind_present := models_dev_member_string(option_object, "type")
		if !kind_present { continue }
		switch kind {
		case "toggle":
			out.toggle_present = true
			out.toggle = true
		case "effort":
			// The first effort list wins, and one is kept at most, so a record
			// that repeats the control form cannot leak the earlier list.
			if out.levels_present { continue }
			levels, levels_present, levels_error := models_dev_member_strings(option_object, "values", allocator)
			if levels_error != nil { return levels_error }
			if levels_present {
				out.levels_present = true
				out.levels = levels
			}
		case "budget_tokens":
			out.budget.present = true
			if minimum, minimum_present := models_dev_member_integer(option_object, "min"); minimum_present {
				out.budget.min_present = true
				out.budget.min = minimum
			}
			if maximum, maximum_present := models_dev_member_integer(option_object, "max"); maximum_present {
				out.budget.max_present = true
				out.budget.max = maximum
			}
		case:
		// A control form this harness does not implement is ignored rather
		// than guessed at.
		}
	}
	return nil
}

// models_dev_api_family translates the package that speaks a provider's wire
// protocol into the API family this harness implements.
//
// Only identifiers whose protocol is unambiguous appear here. @ai-sdk/openai
// defaults to the Responses API, while @ai-sdk/openai-compatible speaks Chat
// Completions. An SDK for another vendor, or a gateway package, is left unstated
// so the provider requires an explicit api in configuration instead of being sent
// the wrong wire format.
@(require_results)
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
@(private, require_results)
_models_dev_wanted :: proc(providers: []string, id: string) -> bool {
	for provider in providers {
		if provider == id { return true }
	}
	return false
}

@(require_results)
models_dev_member_string :: proc(object: json.Object, key: string) -> (value: string, present: bool) {
	member, found := object[key]
	if !found { return "", false }
	text, is_string := member.(json.String)
	if !is_string { return "", false }
	return string(text), true
}

@(require_results)
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
@(require_results)
models_dev_member_integer :: proc(object: json.Object, key: string) -> (value: int, present: bool) {
	member, found := object[key]
	if !found { return 0, false }
	number, is_integer := member.(json.Integer)
	if !is_integer || number < 0 { return 0, false }
	return int(number), true
}

// models_dev_member_strings reads a member that must be an array of strings. The list is
// copied, because the parsed document is released as soon as parsing finishes. A non-string
// element is dropped rather than failing the catalog. An allocation failure is reported rather
// than returning a short list.
@(require_results)
models_dev_member_strings :: proc(object: json.Object, key: string, allocator: mem.Allocator) -> (values: []string, present: bool, err: mem.Allocator_Error) {
	member, found := object[key]
	if !found { return nil, false, nil }
	array, is_array := member.(json.Array)
	if !is_array { return nil, false, nil }

	collected: [dynamic]string
	collected.allocator = allocator
	for element in array {
		text, is_string := element.(json.String)
		if !is_string { continue }
		cloned, clone_error := strings.clone(string(text), allocator)
		if clone_error != nil {
			for owned in collected { delete(owned, allocator) }
			delete(collected)
			return nil, false, clone_error
		}
		if _, append_error := append(&collected, cloned); append_error != nil {
			delete(cloned, allocator)
			for owned in collected { delete(owned, allocator) }
			delete(collected)
			return nil, false, append_error
		}
	}
	// The result is a slice the catalog's own release routine can free, so it is
	// copied out of the accumulator rather than sharing its capacity.
	result, result_error := make([]string, len(collected), allocator)
	if result_error != nil {
		for owned in collected { delete(owned, allocator) }
		delete(collected)
		return nil, false, result_error
	}
	copy(result, collected[:])
	delete(collected)
	return result, true, nil
}
