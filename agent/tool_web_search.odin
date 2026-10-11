package agent

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"

import "nabla:ai"
import "nabla:http/client"
import "nabla:web"

TOOL_WEB_SEARCH_NAME :: "web_search"

// TOOL_WEB_SEARCH_DESCRIPTION is a format: the default count, then the default timeout in seconds.
TOOL_WEB_SEARCH_DESCRIPTION :: `Search the web and return titles, URLs, and snippets. The search service does not know today's date: put the year in the query when you look for recent events.

query is required. count is the number of results wanted (default %d); the search service's maximum applies, and the result says when the count was lowered. freshness limits results to the last day, week, month, or year (default any). include_domains and exclude_domains restrict or remove sites. The timeout is %d seconds unless you set timeout_ms, and there is no maximum.

The result gives results (their count), an optional notice and answer, and after a blank line the numbered results, each with a title, a URL, published when available, and a snippet. A search with no results succeeds and suggests a broader query.`

TOOL_WEB_SEARCH_SCHEMA ::
	`{"type":"object","properties":{` +
	`"query":{"type":"string","description":"What to search for. Put the year in the query for recent events."},` +
	`"count":{"type":["integer","null"],"description":"Number of results wanted. Leave out or pass null for the default the tool description states."},` +
	`"freshness":{"type":["string","null"],"enum":["any","day","week","month","year",null],"description":"Only results from the last day, week, month, or year. Default: any."},` +
	`"include_domains":{"type":["array","null"],"items":{"type":"string"},"description":"Only results from these domains."},` +
	`"exclude_domains":{"type":["array","null"],"items":{"type":"string"},"description":"No results from these domains."},` +
	`"timeout_ms":{"type":["integer","null"],"description":"Positive timeout in milliseconds, with no maximum. Leave out or pass null for the default the tool description states."}` +
	`,"provider":{"type":"string","enum":%s,"description":"Search with this service first; the others remain as fallbacks. Leave it out to use the default order."}},"required":["query"],"additionalProperties":false}`

TOOL_WEB_SEARCH_FIELDS :: []string{"query", "count", "freshness", "include_domains", "exclude_domains", "timeout_ms", "provider"}

TOOL_WEB_SEARCH_DEFAULT_COUNT :: 8

// TOOL_WEB_SEARCH_DEFAULT_TIMEOUT applies when the model gives no timeout. There is no maximum.
TOOL_WEB_SEARCH_DEFAULT_TIMEOUT :: 30 * time.Second

TOOL_WEB_SEARCH_DEFINITION :: Tool_Definition {
	name = TOOL_WEB_SEARCH_NAME,
	description = TOOL_WEB_SEARCH_DESCRIPTION,
	input_schema = "",
	hints = {read_only = .Yes, destructive = .No, idempotent = .No, open_world = .Yes},
	timeout = TOOL_WEB_SEARCH_DEFAULT_TIMEOUT,
	kind = .Web_Search,
	execute = tool_web_search_execute,
}

// tool_web_search_definition returns the web search tool with its defaults in the description,
// and config as the providers it searches. config must not be nil. The caller owns the
// description and schema, allocated with allocator. The backend borrows config, which
// must outlive the registered definition.
@(require_results)
tool_web_search_definition :: proc(config: ^Web_Search_Config, allocator := context.allocator) -> (definition: Tool_Definition, err: mem.Allocator_Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	definition = TOOL_WEB_SEARCH_DEFINITION
	definition.description = ""
	defer if err != nil {
		delete(definition.description, allocator)
		delete(definition.input_schema, allocator)
		definition = {}
	}
	description := fmt.tprintf(TOOL_WEB_SEARCH_DESCRIPTION, TOOL_WEB_SEARCH_DEFAULT_COUNT, int(TOOL_WEB_SEARCH_DEFAULT_TIMEOUT / time.Second))
	definition.description = strings.clone(description, allocator) or_return
	services := config.services
	names := web.PROVIDER_NAMES
	choices := make([]string, len(services), context.temp_allocator) or_return
	for service, index in services { choices[index] = names[service] }
	encoded, encode_error := json.marshal(choices, allocator = context.temp_allocator)
	if encode_error != nil { return definition, .Out_Of_Memory }
	before, _, after := strings.partition(TOOL_WEB_SEARCH_SCHEMA, "%s")
	definition.input_schema = strings.concatenate({before, string(encoded), after}, allocator) or_return
	definition.backend = config
	return definition, nil
}

// TOOL_WEB_SEARCH_KIND_TEXT is how a failure kind reads in a failed line.
@(private)
TOOL_WEB_SEARCH_KIND_TEXT :: [web.Error_Kind]string {
	.None               = "",
	.Missing_Credential = "missing credential",
	.Unauthorized       = "unauthorized",
	.Quota              = "quota exhausted",
	.Rate_Limited       = "rate limited",
	.Rejected           = "rejected",
	.Server             = "server error",
	.Transport          = "transport failed",
	.Timed_Out          = "timed out",
	.Cancelled          = "cancelled",
	.Invalid_Response   = "invalid response",
	.Out_Of_Memory      = "out of memory",
}

// tool_web_search_args reads the search's arguments. A timeout the model gives is honored as
// given; otherwise the definition's default applies.
@(require_results)
tool_web_search_args :: proc(ctx: ^Tool_Context, arguments: json.Object, config: ^Web_Search_Config) -> (args: Web_Search_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_WEB_SEARCH_FIELDS, allocator = ctx.allocator) or_return
	args.query = tool_field_string(arguments, "query", allocator = ctx.allocator) or_return
	if strings.trim_space(args.query) == "" {
		return {}, tool_argument_error(.Invalid_Value, "query", "a non-empty search query", ctx.allocator)
	}
	if value, present := arguments["provider"]; present {
		name, is_string := value.(json.String)
		if !is_string { return {}, tool_argument_error(.Wrong_Type, "provider", "a string", ctx.allocator) }
		provider, parsed := web.provider_parse(string(name))
		service := web.engine(provider)
		matched := false
		if config != nil && parsed {
			for allowed in config.services {
				if allowed == service { matched = true; break }
			}
		}
		if !matched {
			allowed: []web.Provider
			if config != nil { allowed = config.services }
			choices, make_error := make([]string, len(allowed), context.temp_allocator)
			if make_error != nil { return {}, tool_argument_error(.Out_Of_Memory) }
			names := web.PROVIDER_NAMES
			for allowed_service, index in allowed { choices[index] = names[allowed_service] }
			return {}, tool_argument_error(.Invalid_Value, "provider", strings.join(choices, ", ", context.temp_allocator), ctx.allocator)
		}
		args.provider = service
	}
	args.count = tool_field_optional_int(arguments, "count", TOOL_WEB_SEARCH_DEFAULT_COUNT, 1, max(int), &ctx.repairs, allocator = ctx.allocator) or_return
	freshness := tool_field_optional_string(arguments, "freshness", allocator = ctx.allocator) or_return
	switch freshness {
	case "", "any":
		args.freshness = .Any
	case "day":
		args.freshness = .Day
	case "week":
		args.freshness = .Week
	case "month":
		args.freshness = .Month
	case "year":
		args.freshness = .Year
	case:
		return {}, tool_argument_error(.Invalid_Value, "freshness", "any, day, week, month, or year", ctx.allocator)
	}
	timeout_ms := tool_field_optional_int(
		arguments,
		"timeout_ms",
		int(ctx.timeout / time.Millisecond),
		1,
		int(max(time.Duration) / time.Millisecond),
		&ctx.repairs,
		allocator = ctx.allocator,
	) or_return
	args.timeout = time.Duration(timeout_ms) * time.Millisecond
	args.include_domains = tool_field_optional_strings(arguments, "include_domains", allocator = ctx.allocator) or_return
	args.exclude_domains, err = tool_field_optional_strings(arguments, "exclude_domains", allocator = ctx.allocator)
	if err != nil {
		delete(args.include_domains, ctx.allocator)
		return {}, err
	}
	return
}

// tool_web_search_endpoints returns the configured ordered endpoints a search tries. A configured
// api_key is resolved here, at use; an entry without one takes the key or URL the
// environment would give that provider. The result is owned by allocator and released with
// web.endpoints_destroy.
@(private, require_results)
tool_web_search_endpoints :: proc(config: ^Web_Search_Config, allocator: mem.Allocator) -> (endpoints: []web.Endpoint, err: mem.Allocator_Error) {
	detected := web.endpoints_from_environment(allocator) or_return
	defer web.endpoints_destroy(detected, allocator)
	list := make([]web.Endpoint, len(config.endpoints), allocator) or_return
	filled := 0
	defer if err != nil { web.endpoints_destroy(list[:filled], allocator) }
	for entry, index in config.endpoints {
		fallback: web.Endpoint
		for candidate in detected {
			if candidate.provider == entry.provider {
				fallback = candidate
				break
			}
		}
		list[index].provider = entry.provider
		base_url := entry.base_url if entry.base_url != "" else fallback.base_url
		list[index].base_url = strings.clone(base_url, allocator) or_return
		filled = index + 1
		if entry.api_key != "" {
			// A reference that resolves to nothing leaves the key empty, which the provider reports as a missing credential.
			list[index].api_key, _ = config_resolve_credential(entry.api_key, allocator)
		} else {
			list[index].api_key = strings.clone(fallback.api_key, allocator) or_return
		}
	}
	return list, nil
}

// tool_web_search_reason describes the answering service and earlier failures for the user.
// The result's reason is a front-end summary, never part of the model's text or Lua output.
@(private, require_results)
tool_web_search_reason :: proc(found: bool, provider: web.Provider, count: int, failures: []web.Failure) -> (text: string, err: mem.Allocator_Error) {
	builder := strings.builder_make(context.temp_allocator) or_return
	names := web.PROVIDER_NAMES
	kinds := TOOL_WEB_SEARCH_KIND_TEXT
	if found {
		render_text(&builder, fmt.tprintf("%d results from %s", count, names[web.engine(provider)])) or_return
	}
	for failure, index in failures {
		if found || index > 0 { render_text(&builder, "; ") or_return }
		render_text(&builder, names[failure.provider]) or_return
		render_text(&builder, ": ") or_return
		render_text(&builder, kinds[failure.error.kind]) or_return
		if failure.error.status > 0 { render_text(&builder, fmt.tprintf(" (HTTP %d)", failure.error.status)) or_return }
		if failure.error.retry_after > 0 { render_text(&builder, fmt.tprintf(" (retry after %v)", failure.error.retry_after)) or_return }
		if failure.error.detail != "" {
			render_text(&builder, ": ") or_return
			render_value(&builder, failure.error.detail) or_return
		}
		if failure.error.kind == .Missing_Credential {
			field := "base_url" if failure.provider == .SearXNG else "api_key"
			for variable in web.ENVIRONMENT_VARIABLES {
				if variable.provider == failure.provider {
					render_text(&builder, fmt.tprintf(" (set %s or %s in web_search)", variable.name, field)) or_return
				}
			}
		}
	}
	return strings.to_string(builder), nil
}

@(require_results)
tool_web_search_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(Web_Search_Args)
	config := (^Web_Search_Config)(ctx.backend)
	if config == nil { return tool_result_failure(ctx, .Unavailable, "web search is unavailable", "unavailable") }
	endpoints, endpoints_error := tool_web_search_endpoints(config, ctx.allocator)
	if endpoints_error != nil { return tool_result_failure(ctx, .Tool_Failed, "the web search could not run: out of memory", "out of memory") }
	defer web.endpoints_destroy(endpoints, ctx.allocator)

	control := ai.HTTP_Control {
		interrupt = ctx.control.interrupt,
	}
	if args.timeout > 0 { control.deadline = ai.deadline_in(args.timeout) }
	options := client.Options {
		probe = {check = ai.http_probe, user_data = &control},
	}
	query := web.Query {
		text            = args.query,
		count           = args.count,
		freshness       = args.freshness,
		include_domains = args.include_domains,
		exclude_domains = args.exclude_domains,
	}
	response, answered_by, failures, found, search_error := web.search_first(endpoints, query, options, args.provider, ctx.allocator)
	if search_error != nil { return tool_result_failure(ctx, .Tool_Failed, "the search could not run: out of memory", "out of memory") }
	defer web.failures_destroy(failures, ctx.allocator)
	defer if found { web.response_destroy(&response, ctx.allocator) }

	reason, reason_error := tool_web_search_reason(found, answered_by, len(response.results), failures)
	if reason_error != nil { return tool_result_failure(ctx, .Tool_Failed, "the web search could not be described: out of memory", "out of memory") }

	if !found {
		if len(failures) > 0 {
			#partial switch failures[len(failures) - 1].error.kind {
			case .Cancelled:
				return tool_result_failure(ctx, .Cancelled, "the search was cancelled", reason)
			case .Timed_Out:
				return tool_result_failure(ctx, .Timed_Out, "the search exceeded its timeout", reason)
			}
		}
		may_retry := false
		for failure in failures {
			#partial switch failure.error.kind {
			case .Rate_Limited, .Quota, .Server, .Transport, .Timed_Out:
				may_retry = true
			}
		}
		message := "the web search failed; trying again later may help" if may_retry else "the web search failed; trying again later is unlikely to help"
		return tool_result_failure(ctx, .Tool_Failed, message, reason)
	}

	output := Web_Search_Output {
		answer  = response.answer,
		results = response.results,
	}
	if response.count_clamped_to > 0 {
		output.notice = fmt.tprintf("returned at most %d results, the most the search service allows", response.count_clamped_to)
	}
	return tool_result_success(ctx, output, reason)
}
