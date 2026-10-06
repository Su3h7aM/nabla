package agent

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"

import "nabla:ai"

// Model_Selection is one model resolved from the catalog into what a session needs to run it:
// the connection its requests use and the facts that shape them. Every string is owned by the
// allocator it was resolved with and released by model_selection_destroy.
Model_Selection :: struct {
	provider_id:   string,
	model_id:      string,
	connection:    ai.Provider_Connection, // Endpoint and Credential owned
	transport:     Provider_Transport,
	capacity:      Model_Capacity,
	cost:          Catalog_Cost,
	tools:         bool,
	effort_levels: []string, // lowest first, verbatim from the catalog
}

// Catalog_Ref is the catalog a session may resolve models from, borrowed from whoever
// publishes it. The publisher replaces the catalog only under mutex.
Catalog_Ref :: struct {
	catalog: ^Catalog,
	mutex:   ^sync.Mutex,
}

model_selection_destroy :: proc(selection: ^Model_Selection, allocator: mem.Allocator) {
	delete(selection.provider_id, allocator)
	delete(selection.model_id, allocator)
	delete(selection.connection.Endpoint, allocator)
	delete(selection.connection.Credential, allocator)
	for level in selection.effort_levels { delete(level, allocator) }
	delete(selection.effort_levels, allocator)
	selection^ = {}
}

// model_selection_effort returns preferred when target supports it, otherwise its lowest
// stated level, or the provider default when it states none. The result borrows target.
model_selection_effort :: proc(target: Model_Selection, preferred: string) -> string {
	if effort_level_index(target.effort_levels, preferred) >= 0 { return preferred }
	if len(target.effort_levels) > 0 { return target.effort_levels[0] }
	return ""
}

// provider_usable reports whether a provider states everything a connection needs.
@(require_results)
provider_usable :: proc(provider: ^Catalog_Provider) -> bool {
	return provider.base_url_present && provider.base_url != "" && provider.api_present && provider.api != "" && provider.api_key_present
}

// model_selection_resolve builds the selection for one serving identity. problem says why the
// model cannot run, in text owned by the temp allocator, and is "" on success. The caller
// holds whatever lock guards catalog.
@(require_results)
model_selection_resolve :: proc(catalog: ^Catalog, provider_id, model_id: string, allocator: mem.Allocator) -> (selection: Model_Selection, problem: string) {
	provider_index, provider_found := catalog_find_provider(catalog, provider_id)
	if !provider_found {
		return {}, fmt.tprintf("provider not found: %s; configured providers: %s", provider_id, catalog_provider_names(catalog))
	}
	provider := &catalog.providers[provider_index]
	if !provider_usable(provider) { return {}, fmt.tprintf("provider %s needs base_url, api, and api_key", provider_id) }
	model_index, model_found := catalog_find_model(catalog, provider_id, model_id)
	if !model_found { return {}, fmt.tprintf("model not found for provider: %s %s", provider_id, model_id) }
	model := &catalog.models[model_index]
	// Routing is per model: a model that states its own API family is served through it,
	// and the provider's family is what its other models use.
	api_name := provider.api
	if model.api_present { api_name = model.api }
	api, api_ok := chat_api_kind(api_name)
	if !api_ok { return {}, fmt.tprintf("unsupported api: %s", api_name) }
	if provider.transport == .WebSocket && .WebSocket not_in ai.Provider_API_Transports(api) {
		return {}, fmt.tprintf("provider %s requires WebSocket, which the %s API has no transport for", provider_id, api_name)
	}
	credential, credential_ok := config_resolve_credential(provider.api_key, allocator)
	if !credential_ok {
		return {}, fmt.tprintf("provider %s needs api_key: name an environment variable that is set, or provide the key", provider_id)
	}

	// Every field the selection owns is built before the caller receives it, and is
	// released here when one of them cannot be held.
	built: Model_Selection
	failed := true
	defer if failed { model_selection_destroy(&built, allocator) }
	built.connection = {
		API        = api,
		Credential = credential,
	}
	built.transport = provider.transport
	built.capacity = model.capacity
	built.cost = model.cost
	built.tools = model.tools_present && model.tools && chat_supports_tools(api)
	if model_selection_clone_identity(&built, provider_id, model_id, provider.base_url, allocator) != nil {
		return {}, "the model selection could not be held"
	}
	if model.thinking.levels_present {
		levels, levels_error := model_selection_clone_levels(model.thinking.levels, allocator)
		if levels_error != nil { return {}, "the model's effort levels could not be held" }
		built.effort_levels = levels
	}
	failed = false
	return built, ""
}

// catalog_model_provider finds which provider serves model_id: preferred when it does, else
// the only usable provider that does. problem, temp-allocated, names the candidates when the
// id is unknown or served by more than one provider.
@(require_results)
catalog_model_provider :: proc(catalog: ^Catalog, model_id, preferred: string) -> (provider_id: string, problem: string) {
	if index, found := catalog_find_model(catalog, preferred, model_id); found { return catalog.models[index].provider_id, "" }
	candidates, candidates_error := make([dynamic]string, 0, context.temp_allocator)
	if candidates_error != nil { return "", "the candidate providers could not be listed" }
	for model in catalog.models {
		if model.id != model_id { continue }
		index, found := catalog_find_provider(catalog, model.provider_id)
		if found && provider_usable(&catalog.providers[index]) { append(&candidates, model.provider_id) }
	}
	switch len(candidates) {
	case 1:
		return candidates[0], ""
	case 0:
		return "", fmt.tprintf(
			"no configured provider serves model %q; models of provider %s: %s",
			model_id,
			preferred,
			catalog_model_names(catalog, preferred),
		)
	}
	joined, join_error := strings.join(candidates[:], ", ", context.temp_allocator)
	if join_error != nil { return "", "the candidate providers could not be listed" }
	return "", fmt.tprintf("model %q is served by several providers (%s); name one in provider", model_id, joined)
}

// catalog_model_names lists the models one provider serves, temp-allocated. A list that
// cannot be held says so rather than reading as a provider with no models.
catalog_model_names :: proc(catalog: ^Catalog, provider_id: string) -> string {
	names, names_error := make([dynamic]string, 0, context.temp_allocator)
	if names_error != nil { return "the model list could not be listed" }
	for model in catalog.models {
		if model.provider_id == provider_id { append(&names, model.id) }
	}
	if len(names) == 0 { return "none" }
	joined, join_error := strings.join(names[:], ", ", context.temp_allocator)
	if join_error != nil { return "the model list could not be listed" }
	return joined
}

// catalog_provider_names lists the ids of the configured providers, those that state the
// base_url, api, and api_key a connection needs, temp-allocated. The catalog also holds
// providers known only from models.dev, which no request can use. A list that cannot be held
// says so rather than reading as no providers.
catalog_provider_names :: proc(catalog: ^Catalog) -> string {
	names, names_error := make([dynamic]string, 0, context.temp_allocator)
	if names_error != nil { return "the provider list could not be listed" }
	for &provider in catalog.providers {
		if provider_usable(&provider) { append(&names, provider.id) }
	}
	if len(names) == 0 { return "none" }
	joined, join_error := strings.join(names[:], ", ", context.temp_allocator)
	if join_error != nil { return "the provider list could not be listed" }
	return joined
}

// effort_step_down is a delegated model's effort when the orchestrator runs at current: the
// orchestrator's level one below it, or the next lower one the delegated model also states.
// Levels are ordered lowest first, and the lowest stays where it is. "" means the two share
// no level at or below current, or the orchestrator runs without effort.
effort_step_down :: proc(parent_levels, child_levels: []string, current: string) -> string {
	if current == "" { return "" }
	if parent_index := effort_level_index(parent_levels, current); parent_index >= 0 {
		for candidate := max(parent_index - 1, 0); candidate >= 0; candidate -= 1 {
			if effort_level_index(child_levels, parent_levels[candidate]) >= 0 { return parent_levels[candidate] }
		}
	}
	return ""
}

// effort_level_index is where level sits in levels, or -1.
effort_level_index :: proc(levels: []string, level: string) -> int {
	if level == "" { return -1 }
	for candidate, index in levels {
		if candidate == level { return index }
	}
	return -1
}

// chat_session_select installs a resolved model on an idle session and applies effort, which
// must be one of its levels or "" for the provider default. The session keeps its own copies.
// installed is false when the session could not hold the selection, in which case it keeps the
// selection it had; applied is what installing the effort returned.
@(require_results)
chat_session_select :: proc(chat: ^Chat_Session, selection: Model_Selection, effort: string) -> (installed: bool, applied: bool) {
	allocator := chat.allocator
	// The session's own copies are built before it releases the ones it holds, so a failure
	// leaves it on the model it was running rather than on none.
	provider_id, model_id, levels, clone_error := chat_selection_clone(selection, allocator)
	if clone_error != nil { return false, false }
	chat.capacity = selection.capacity
	chat.cost = selection.cost
	if selection.provider_id != chat.provider_id || selection.model_id != chat.model_id || selection.connection.API != chat.model_api {
		chat.calibration = {}
	}
	chat.model_api = selection.connection.API
	chat.refused_features = {}
	chat.compact.omitted_features = {}
	chat.tools_enabled = selection.tools
	chat.provider_transport = selection.transport
	chat.websocket_fallback_http = false
	delete(chat.provider_id, allocator)
	chat.provider_id = provider_id
	delete(chat.model_id, allocator)
	chat.model_id = model_id
	// An empty level always clears, so this reset cannot be refused.
	_ = chat_session_set_effort(chat, "")
	for level in chat.effort_levels { delete(level, allocator) }
	delete(chat.effort_levels)
	chat.effort_levels = levels
	return true, chat_session_set_effort(chat, effort)
}
@(private, require_results)
model_selection_clone_identity :: proc(selection: ^Model_Selection, provider_id, model_id, endpoint: string, allocator: mem.Allocator) -> mem.Allocator_Error {
	selection.provider_id = strings.clone(provider_id, allocator) or_return
	selection.model_id = strings.clone(model_id, allocator) or_return
	selection.connection.Endpoint = strings.clone(endpoint, allocator) or_return
	return nil
}

@(private, require_results)
model_selection_clone_levels :: proc(levels: []string, allocator: mem.Allocator) -> (result_value: []string, error: mem.Allocator_Error) {
	owned := make([]string, len(levels), allocator) or_return
	complete := false
	defer if !complete {
		for level in owned { delete(level, allocator) }
		delete(owned, allocator)
	}
	for level, index in levels { owned[index] = strings.clone(level, allocator) or_return }
	complete = true
	return owned, nil
}

@(private, require_results)
chat_selection_clone :: proc(selection: Model_Selection, allocator: mem.Allocator) -> (provider: string, model: string, owned_levels: [dynamic]string, error: mem.Allocator_Error) {
	provider_id, model_id: string
	levels: [dynamic]string
	levels.allocator = allocator
	complete := false
	defer if !complete {
		delete(provider_id, allocator)
		delete(model_id, allocator)
		for level in levels { delete(level, allocator) }
		delete(levels)
	}
	provider_id = strings.clone(selection.provider_id, allocator) or_return
	model_id = strings.clone(selection.model_id, allocator) or_return
	for level in selection.effort_levels {
		cloned := strings.clone(level, allocator) or_return
		if _, append_error := append(&levels, cloned); append_error != nil {
			delete(cloned, allocator)
			return "", "", nil, append_error
		}
	}
	complete = true
	return provider_id, model_id, levels, nil
}
