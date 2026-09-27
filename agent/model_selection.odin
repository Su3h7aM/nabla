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

// provider_usable reports whether a provider states everything a connection needs.
provider_usable :: proc(provider: ^Catalog_Provider) -> bool {
	return provider.base_url_present && provider.base_url != "" && provider.api_present && provider.api != "" && provider.api_key_present
}

// model_selection_resolve builds the selection for one serving identity. problem says why the
// model cannot run, in text owned by the temp allocator, and is "" on success. The caller
// holds whatever lock guards catalog.
model_selection_resolve :: proc(catalog: ^Catalog, provider_id, model_id: string, allocator: mem.Allocator) -> (selection: Model_Selection, problem: string) {
	provider_index, provider_found := catalog_find_provider(catalog, provider_id)
	if !provider_found { return {}, fmt.tprintf("provider not found: %s", provider_id) }
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

	selection = Model_Selection {
		provider_id = strings.clone(provider_id, allocator),
		model_id = strings.clone(model_id, allocator),
		connection = {API = api, Endpoint = strings.clone(provider.base_url, allocator), Credential = credential},
		transport = provider.transport,
		capacity = model.capacity,
		tools = model.tools_present && model.tools && chat_supports_tools(api),
	}
	if model.thinking.levels_present {
		selection.effort_levels = make([]string, len(model.thinking.levels), allocator)
		for level, index in model.thinking.levels { selection.effort_levels[index] = strings.clone(level, allocator) }
	}
	return selection, ""
}

// catalog_model_provider finds which provider serves model_id: preferred when it does, else
// the only usable provider that does. problem, temp-allocated, names the candidates when the
// id is unknown or served by more than one provider.
catalog_model_provider :: proc(catalog: ^Catalog, model_id, preferred: string) -> (provider_id: string, problem: string) {
	if index, found := catalog_find_model(catalog, preferred, model_id); found { return catalog.models[index].provider_id, "" }
	candidates := make([dynamic]string, 0, context.temp_allocator)
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
	return "", fmt.tprintf(
		"model %q is served by several providers (%s); name one in provider",
		model_id,
		strings.join(candidates[:], ", ", context.temp_allocator),
	)
}

// catalog_model_names lists the models one provider serves, temp-allocated.
catalog_model_names :: proc(catalog: ^Catalog, provider_id: string) -> string {
	names := make([dynamic]string, 0, context.temp_allocator)
	for model in catalog.models {
		if model.provider_id == provider_id { append(&names, model.id) }
	}
	if len(names) == 0 { return "none" }
	return strings.join(names[:], ", ", context.temp_allocator)
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
chat_session_select :: proc(chat: ^Chat_Session, selection: Model_Selection, effort: string) -> bool {
	chat.capacity = selection.capacity
	chat.tools_enabled = selection.tools
	chat.provider_transport = selection.transport
	chat.websocket_fallback_http = false
	delete(chat.provider_id, chat.allocator)
	chat.provider_id = strings.clone(selection.provider_id, chat.allocator)
	delete(chat.model_id, chat.allocator)
	chat.model_id = strings.clone(selection.model_id, chat.allocator)
	chat_session_set_effort(chat, "")
	for level in chat.effort_levels { delete(level, chat.allocator) }
	clear(&chat.effort_levels)
	for level in selection.effort_levels { append(&chat.effort_levels, strings.clone(level, chat.allocator)) }
	return chat_session_set_effort(chat, effort)
}
