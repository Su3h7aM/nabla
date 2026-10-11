#+test
package agent

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent/journal"

@(test)
test_web_search_falls_back_to_the_next_provider :: proc(t: ^testing.T) {
	body := `{"results":[{"title":"Bun v1.2","url":"https://bun.sh/blog/bun-v1.2","content":"Bun 1.2 adds SQL","publishedDate":"2025-01-22"},{"title":"Second","url":"https://example.com/b","content":"other"}]}`
	responses := []string{agent_provider_refusal("429 Too Many Requests", "{}", "retry-after: 30\r\n"), agent_provider_refusal("200 OK", body)}
	provider: Agent_Provider
	if !agent_provider_start(t, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	url := agent_provider_endpoint(&provider)
	defer delete(url)

	config := Web_Search_Config {
		endpoints = {{provider = .Brave, api_key = "test-key", base_url = url}, {provider = .SearXNG, base_url = url}},
	}
	services, services_error := web_search_services(config.endpoints)
	if !testing.expect_value(t, services_error, nil) { return }
	config.services = services
	defer delete(config.services)
	ctx := Tool_Context {
		call_id   = "call_1",
		allocator = context.allocator,
		timeout   = TOOL_WEB_SEARCH_DEFAULT_TIMEOUT,
		backend   = &config,
	}
	arguments, parse_error := json.parse_string(`{"query":"bun release 2025"}`)
	if !testing.expect_value(t, parse_error, nil) { return }
	defer json.destroy_value(arguments)
	object, is_object := arguments.(json.Object)
	if !testing.expect(t, is_object) { return }

	result := tool_test_execute(&ctx, TOOL_WEB_SEARCH_DEFINITION, object)
	defer tool_result_destroy(&result)
	testing.expect_value(t, result.outcome, journal.Tool_Outcome.Success)
	testing.expect(t, strings.has_prefix(result.content, "ok\nresults: 2\n"), result.content)
	testing.expect(t, !strings.contains(result.content, "brave") && !strings.contains(result.content, "searxng"), result.content)
	testing.expect(t, strings.contains(result.reason, "brave: rate limited (HTTP 429)"), result.reason)
	testing.expect(t, strings.contains(result.content, "1. Bun v1.2\nhttps://bun.sh/blog/bun-v1.2\npublished: 2025-01-22\nBun 1.2 adds SQL\n"), result.content)
	testing.expect(t, strings.contains(result.content, "2. Second\nhttps://example.com/b\nother\n"), result.content); preferred: Agent_Provider
	if !agent_provider_start(t, &preferred, {agent_provider_refusal("200 OK", body)}) { return }
	defer agent_provider_stop(&preferred)
	preferred_url := agent_provider_endpoint(&preferred)
	defer delete(preferred_url)
	preferred_config := Web_Search_Config {
		endpoints = {{provider = .Brave, api_key = "test-key", base_url = preferred_url}, {provider = .SearXNG, base_url = preferred_url}},
	}
	preferred_services, preferred_services_error := web_search_services(preferred_config.endpoints)
	if !testing.expect_value(t, preferred_services_error, nil) { return }
	preferred_config.services = preferred_services
	defer delete(preferred_config.services)
	definition, definition_error := tool_web_search_definition(&preferred_config)
	if !testing.expect_value(t, definition_error, nil) { return }
	defer delete(definition.description)
	defer delete(definition.input_schema)
	temporary_definition, temporary_definition_error := tool_web_search_definition(&preferred_config, context.temp_allocator)
	if !testing.expect_value(t, temporary_definition_error, nil) { return }
	defer delete(temporary_definition.description, context.temp_allocator)
	defer delete(temporary_definition.input_schema, context.temp_allocator)
	testing.expect_value(t, tool_definition_validate(temporary_definition).kind, Tool_Registry_Error_Kind.None)
	ctx.backend = &preferred_config
	preferred_arguments, preferred_parse_error := json.parse_string(`{"query":"bun release 2025","provider":"searxng"}`)
	if !testing.expect_value(t, preferred_parse_error, nil) { return }
	defer json.destroy_value(preferred_arguments)
	preferred_result := tool_test_execute(&ctx, definition, preferred_arguments.(json.Object))
	defer tool_result_destroy(&preferred_result)
	testing.expect_value(t, preferred_result.outcome, journal.Tool_Outcome.Success)
	testing.expect(t, strings.has_prefix(agent_provider_request(&preferred, 0), "GET /search?"), "the requested second service was tried first")
	testing.expect(t, !strings.contains(preferred_result.content, "brave") && !strings.contains(preferred_result.content, "searxng"), preferred_result.content)
	unknown_arguments, unknown_parse_error := json.parse_string(`{"query":"bun","provider":"exa"}`)
	if !testing.expect_value(t, unknown_parse_error, nil) { return }
	defer json.destroy_value(unknown_arguments)
	refused := tool_test_execute(&ctx, definition, unknown_arguments.(json.Object))
	defer tool_result_destroy(&refused)
	testing.expect_value(t, refused.outcome, journal.Tool_Outcome.Invalid_Arguments)
	testing.expect(t, strings.contains(refused.content, "brave, searxng"), refused.content)

}

@(test)
test_web_search_timeout_ends_the_request_without_results :: proc(t: ^testing.T) {
	// The provider reads the request and holds its answer until the fixture stops.
	provider: Agent_Provider
	provider.hold = 1
	if !agent_provider_start(t, &provider, {agent_provider_refusal("200 OK", "{}")}) { return }
	defer agent_provider_stop(&provider)
	url := agent_provider_endpoint(&provider)
	defer delete(url)

	config := Web_Search_Config {
		endpoints = {{provider = .Brave, api_key = "test-key", base_url = url}},
	}
	services, services_error := web_search_services(config.endpoints)
	if !testing.expect_value(t, services_error, nil) { return }
	config.services = services
	defer delete(config.services)
	ctx := Tool_Context {
		call_id   = "call_1",
		allocator = context.allocator,
		timeout   = TOOL_WEB_SEARCH_DEFAULT_TIMEOUT,
		backend   = &config,
	}
	arguments, parse_error := json.parse_string(`{"query":"slow","timeout_ms":100}`)
	if !testing.expect_value(t, parse_error, nil) { return }
	defer json.destroy_value(arguments)
	object, is_object := arguments.(json.Object)
	if !testing.expect(t, is_object) { return }

	result := tool_test_execute(&ctx, TOOL_WEB_SEARCH_DEFINITION, object)
	defer tool_result_destroy(&result)
	testing.expect_value(t, result.outcome, journal.Tool_Outcome.Timed_Out)
	testing.expect(t, result.output == nil, "a timed-out search has no partial results")
	testing.expect(t, !strings.contains(result.content, "results:"), result.content)
}

@(test)
test_web_search_recommends_retry_after_a_mixed_failure :: proc(t: ^testing.T) {
	provider: Agent_Provider
	responses := []string{agent_provider_refusal("401 Unauthorized", "{}"), agent_provider_refusal("500 Internal Server Error", "{}")}
	if !agent_provider_start(t, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	url := agent_provider_endpoint(&provider)
	defer delete(url)
	config := Web_Search_Config {
		endpoints = {{provider = .Brave, api_key = "test-key", base_url = url}, {provider = .Tavily, api_key = "test-key", base_url = url}},
	}
	services, services_error := web_search_services(config.endpoints)
	if !testing.expect_value(t, services_error, nil) { return }
	config.services = services
	defer delete(config.services)
	definition, definition_error := tool_web_search_definition(&config)
	if !testing.expect_value(t, definition_error, nil) { return }
	defer delete(definition.description)
	defer delete(definition.input_schema)
	ctx := Tool_Context {
		allocator = context.allocator,
		timeout   = TOOL_WEB_SEARCH_DEFAULT_TIMEOUT,
		backend   = &config,
	}
	arguments, parse_error := json.parse_string(`{"query":"bun"}`)
	if !testing.expect_value(t, parse_error, nil) { return }
	defer json.destroy_value(arguments)
	result := tool_test_execute(&ctx, definition, arguments.(json.Object))
	defer tool_result_destroy(&result)
	testing.expect_value(t, result.outcome, journal.Tool_Outcome.Tool_Failed)
	testing.expect(t, strings.contains(result.content, "trying again later may help"), result.content)
	testing.expect(t, !strings.contains(result.content, "brave") && !strings.contains(result.content, "tavily"), result.content)
}

@(test)
test_web_search_config_reads_providers_and_refuses_unknown_ones :: proc(t: ^testing.T) {
	load :: proc(t: ^testing.T, name, body: string) -> (options: Harness_Options, err: Config_Error, detail: string) {
		path := fmt.aprintf("/tmp/nabla-web-search-%s-%d.lua", name, os.get_pid(), allocator = context.temp_allocator)
		defer os.remove(path)
		testing.expect(t, os.write_entire_file(path, body) == nil)
		_, options, _, err, detail = load_lua_config(path)
		return
	}

	options, err, detail := load(
		t,
		"list",
		`return { web_search = { providers = {
			{ provider = "searxng", base_url = "http://localhost:8888" },
			{ provider = "brave", api_key = "${WORK_BRAVE_KEY}" },
			{ provider = "exa_mcp" },
			{ provider = "exa", api_key = "test-key" },
		} } }`,
	)
	defer web_search_config_destroy(options.web_search)
	if !testing.expect_value(t, err, Config_Error.None) { return }
	if !testing.expect(t, options.web_search != nil && len(options.web_search.endpoints) == 4) { return }
	testing.expect_value(t, options.web_search.endpoints[0].provider, .SearXNG)
	testing.expect_value(t, options.web_search.endpoints[0].base_url, "http://localhost:8888")
	testing.expect_value(t, options.web_search.endpoints[1].provider, .Brave)
	testing.expect_value(t, options.web_search.endpoints[1].api_key, "${WORK_BRAVE_KEY}")
	if !testing.expect_value(t, len(options.web_search.services), 3) { return }
	testing.expect_value(t, options.web_search.services[0], .SearXNG)
	testing.expect_value(t, options.web_search.services[1], .Brave)
	testing.expect_value(t, options.web_search.services[2], .Exa)

	disabled, disabled_err, _ := load(t, "off", `return { web_search = false }`)
	defer web_search_config_destroy(disabled.web_search)
	testing.expect_value(t, disabled_err, Config_Error.None)
	testing.expect(t, disabled.web_search == nil)

	registry, registry_error := tool_registry_make(context.allocator, disabled.web_search)
	if !testing.expect_value(t, registry_error.kind, Tool_Registry_Error_Kind.None) { return }
	defer tool_registry_destroy(&registry)
	_, present := tool_registry_find(&registry, TOOL_WEB_SEARCH_NAME)
	testing.expect(t, !present, "web_search = false removes the tool")

	refused := []string {
		`return { web_search = { providers = { { provider = "bing" } } } }`,
		`return { web_search = { providers = { { provider = "brave", key = "k" } } } }`,
		`return { web_search = { providers = {} } }`,
		`return { web_search = { providers = { { api_key = "k" } } } }`,
	}
	for body, index in refused {
		_, refused_err, refused_detail := load(t, "refuse", body)
		testing.expectf(t, refused_err == .Invalid, "case %d: %v", index, refused_err)
		testing.expectf(t, strings.has_prefix(refused_detail, "web_search"), "case %d: %q", index, refused_detail)
		delete(refused_detail)
	}
	delete(detail)
}
