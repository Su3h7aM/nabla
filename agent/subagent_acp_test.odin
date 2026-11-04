#+test
package agent

import "core:strings"
import "core:testing"

@(test)
test_disabled_model_is_not_offered_by_selection :: proc(t: ^testing.T) {
	catalog: Catalog
	catalog.providers = make([dynamic]Catalog_Provider, 0, 1, context.allocator)
	append(&catalog.providers, Catalog_Provider{id = "p", base_url = "https://api.test", api = "openai_chat_completions", api_key = "KEY"})
	catalog.models = make([dynamic]Catalog_Model, 0, 2, context.allocator)
	append(&catalog.models, Catalog_Model{provider_id = "p", id = "kept", tools = true})
	append(&catalog.models, Catalog_Model{provider_id = "p", id = "off", disabled = true})
	defer catalog_destroy(&catalog)
	parent: Agent_Parent
	parent.provider_id = "p"
	parent.model_id = "kept"
	parent.catalog = {
		catalog = &catalog,
	}
	_, _, problem := acp_native_model("p", "off", "", &parent, {})
	testing.expect(t, problem == "model not found for provider: p off")
	_, _, unknown := acp_native_model("p", "missing", "", &parent, {})
	testing.expect(t, unknown == "model not found for provider: p missing")
	team: Agent_Team
	team.parent = parent
	text, err := tool_agents_models(&team)
	testing.expect(t, err == nil)
	testing.expect(t, strings.contains(text, "kept"))
	testing.expect(t, !strings.contains(text, "off"))
}
