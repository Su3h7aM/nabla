package web

import "nabla:http/client"

// The URL and the maximum count are from the Brave Search API reference, web search.
@(private)
BRAVE_URL :: "https://api.search.brave.com/res/v1/web/search"
@(private)
BRAVE_MAX_COUNT :: 20

// BRAVE_RESPONSE_TYPE is the type every search response carries. The web section
// is absent when nothing matched, so only the type tells a reply from an error document.
@(private)
BRAVE_RESPONSE_TYPE :: "search"

@(private)
Brave_Wire :: struct {
	type: string,
	web:  struct {
		results: []struct {
			title:       string,
			url:         string,
			description: string,
			age:         string,
		},
	},
}

@(private)
@(require_results)
brave_request :: proc(endpoint: Endpoint, query: Query) -> (request: client.Request, clamped_to: int, err: Error) {
	count: int
	count, clamped_to = clamp_count(query.count, BRAVE_MAX_COUNT)
	freshness: string
	switch query.freshness {
	case .Any:
	case .Day:
		freshness = "pd"
	case .Week:
		freshness = "pw"
	case .Month:
		freshness = "pm"
	case .Year:
		freshness = "py"
	}
	text: string
	if text, err = query_text(query); err.kind != .None { return }
	base := endpoint.base_url if endpoint.base_url != "" else BRAVE_URL
	if request.url, err = url_build(base, {{name = "q", value = text}, {name = "count", number = count}, {name = "freshness", value = freshness}});
	   err.kind != .None { return }
	request.method = .Get
	request.headers, err = headers_make({"X-Subscription-Token", endpoint.api_key}, {"Accept", "application/json"})
	return
}

@(private)
@(require_results)
brave_decode :: proc(body: []u8) -> (response: Response, err: Error) {
	wire: Brave_Wire
	if err = json_decode(body, &wire, "brave"); err.kind != .None { return }
	if wire.type != BRAVE_RESPONSE_TYPE {
		return {}, {kind = .Invalid_Response, detail = "brave: the response is not a search result"}
	}
	if response.results, err = results_make(len(wire.web.results)); err.kind != .None { return }
	for result, i in wire.web.results {
		title, title_err := markup_strip(result.title)
		snippet, snippet_err := markup_strip(result.description)
		if title_err != nil || snippet_err != nil { return {}, OUT_OF_MEMORY }
		response.results[i] = {
			title     = title,
			url       = result.url,
			snippet   = snippet,
			published = result.age,
		}
	}
	return
}
