package web

import "base:runtime"
import "core:os"
import "core:strings"

import "nabla:http/client"

// PROVIDER_NAMES are the lowercase names a command line or a file uses for each provider.
PROVIDER_NAMES :: [Provider]string {
	.DuckDuckGo = "duckduckgo",
	.Brave      = "brave",
	.Tavily     = "tavily",
	.Exa        = "exa",
	.Exa_MCP    = "exa_mcp",
	.SearXNG    = "searxng",
}

// provider_parse returns the provider named name, ignoring case.
provider_parse :: proc(name: string) -> (provider: Provider, ok: bool) {
	names := PROVIDER_NAMES
	for candidate, candidate_provider in names {
		if strings.equal_fold(name, candidate) { return candidate_provider, true }
	}
	return {}, false
}

// engine returns the service a provider belongs to. Exa's REST and MCP endpoints are
// the same service; every other provider is its own service.
engine :: proc(provider: Provider) -> Provider {
	return .Exa if provider == .Exa_MCP else provider
}

// Failure is one provider's refusal during search_first.
Failure :: struct {
	provider: Provider,
	error:    Error,
}

// failures_destroy releases the failures returned by search_first.
failures_destroy :: proc(failures: []Failure, allocator := context.allocator) {
	for &failure in failures {
		error_destroy(&failure.error, allocator)
	}
	delete(failures, allocator)
}

// search_first tries each endpoint in order and returns the first success, with
// the provider that answered. failures lists, in order, the endpoints that failed
// before it.
// When first is present, endpoints of that service are tried first in list order,
// followed by the remaining endpoints in list order. Exa's REST and MCP endpoints
// belong to the same service.
// The search stops early when an endpoint reports Cancelled or
// Timed_Out, since both come from the caller's probe and would end every later
// attempt too; ok is then false and the last failure says which. ok is also false
// when every endpoint failed or endpoints is empty.
//
// response, failures, and the failure details are owned by allocator; release
// them with response_destroy and failures_destroy. The failures slice is
// reserved before the first request, so a failure is never dropped: when that
// reservation fails nothing is sent and err is the allocation error.
@(require_results)
search_first :: proc(
	endpoints: []Endpoint,
	query: Query,
	options: client.Options,
	first: Maybe(Provider) = nil,
	allocator := context.allocator,
) -> (
	response: Response,
	answered_by: Provider,
	failures: []Failure,
	ok: bool,
	err: runtime.Allocator_Error,
) {
	recorded := make([]Failure, len(endpoints), allocator) or_return
	used := 0
	preferred, has_preference := first.?
	for pass in 0 ..< (2 if has_preference else 1) {
		for endpoint in endpoints {
			if has_preference && (engine(endpoint.provider) == engine(preferred)) != (pass == 0) { continue }
			result, search_err := search(endpoint, query, options, allocator)
			if search_err.kind == .None { return result, endpoint.provider, recorded[:used], true, nil }
			recorded[used] = {
				provider = endpoint.provider,
				error    = search_err,
			}
			used += 1
			if search_err.kind == .Cancelled || search_err.kind == .Timed_Out { return {}, {}, recorded[:used], false, nil }
		}
	}
	return {}, {}, recorded[:used], false, nil
}

// ENVIRONMENT_VARIABLES names the variable that configures each provider that needs
// one, in the default provider order: an API key, or for SearXNG the instance URL.
ENVIRONMENT_VARIABLES :: [?]struct {
	provider: Provider,
	name:     string,
}{{.Brave, "BRAVE_API_KEY"}, {.Tavily, "TAVILY_API_KEY"}, {.Exa, "EXA_API_KEY"}, {.SearXNG, "SEARXNG_URL"}}

// endpoints_from_environment returns the default ordered endpoint list: Brave,
// Tavily, and Exa when BRAVE_API_KEY, TAVILY_API_KEY, or EXA_API_KEY is set and
// not empty, SearXNG when SEARXNG_URL is, and always the keyless Exa_MCP and
// DuckDuckGo last. The slice and the key and URL strings in it are owned by
// allocator; release them with endpoints_destroy.
@(require_results)
endpoints_from_environment :: proc(allocator := context.allocator) -> (endpoints: []Endpoint, err: runtime.Allocator_Error) {
	variables := ENVIRONMENT_VARIABLES
	list := make([dynamic]Endpoint, 0, len(variables) + 2, allocator) or_return
	defer if err != nil {
		endpoints_destroy(list[:], allocator)
	}
	for variable in variables {
		value, found := os.lookup_env(variable.name, allocator)
		if !found || value == "" {
			delete(value, allocator)
			continue
		}
		endpoint := Endpoint {
			provider = variable.provider,
		}
		if variable.provider == .SearXNG { endpoint.base_url = value } else { endpoint.api_key = value }
		if _, append_err := append(&list, endpoint); append_err != nil {
			delete(value, allocator)
			return nil, append_err
		}
	}
	// Reserved above, so these cannot grow the list.
	append(&list, Endpoint{provider = .Exa_MCP}, Endpoint{provider = .DuckDuckGo})
	return list[:], nil
}

// endpoints_destroy releases a list returned by endpoints_from_environment.
endpoints_destroy :: proc(endpoints: []Endpoint, allocator := context.allocator) {
	for endpoint in endpoints {
		delete(endpoint.api_key, allocator)
		delete(endpoint.base_url, allocator)
	}
	delete(endpoints, allocator)
}
