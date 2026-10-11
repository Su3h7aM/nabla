package web

import "core:strings"
import "core:time"

import "nabla:http/client"

// The URL and the maximum count are from the Exa search API reference.
@(private)
EXA_URL :: "https://api.exa.ai/search"
@(private)
EXA_MAX_COUNT :: 100

@(private)
Exa_Contents :: struct {
	highlights: bool,
}

@(private)
Exa_Request :: struct {
	query:              string,
	numResults:         Maybe(int) `json:",omitempty"`,
	type:               string,
	contents:           Exa_Contents,
	startPublishedDate: string `json:",omitempty"`,
	includeDomains:     []string `json:",omitempty"`,
	excludeDomains:     []string `json:",omitempty"`,
}

@(private)
Exa_Wire :: struct {
	results: Maybe([]struct {
			title:         string,
			url:           string,
			publishedDate: string,
			highlights:    []string,
			text:          string,
		}),
}

@(private)
@(require_results)
exa_request :: proc(endpoint: Endpoint, query: Query) -> (request: client.Request, clamped_to: int, err: Error) {
	wire := Exa_Request {
		query = query.text,
		type = "auto",
		contents = {highlights = true},
		includeDomains = query.include_domains,
		excludeDomains = query.exclude_domains,
	}
	count: int
	count, clamped_to = clamp_count(query.count, EXA_MAX_COUNT)
	if count > 0 { wire.numResults = count }
	if wire.startPublishedDate, err = exa_start_date(query.freshness); err.kind != .None { return }
	if request.body, err = json_encode(wire); err.kind != .None { return }
	request.url = endpoint.base_url if endpoint.base_url != "" else EXA_URL
	request.method = .Post
	request.headers, err = headers_make({"x-api-key", endpoint.api_key}, {"Content-Type", "application/json"}, {"Accept", "application/json"})
	return
}

// exa_start_date returns the startPublishedDate for a freshness period: now minus
// the period in RFC 3339, or "" for Any. REST and MCP share it.
@(private)
@(require_results)
exa_start_date :: proc(freshness: Freshness) -> (since: string, err: Error) {
	period: time.Duration
	switch freshness {
	case .Any:
		return "", {}
	case .Day:
		period = 24 * time.Hour
	case .Week:
		period = 7 * 24 * time.Hour
	case .Month:
		period = 30 * 24 * time.Hour
	case .Year:
		period = 365 * 24 * time.Hour
	}
	formatted, ok := time.time_to_rfc3339(time.time_add(time.now(), -period), 0, false, context.temp_allocator)
	if !ok { return "", OUT_OF_MEMORY }
	return formatted, {}
}

@(private)
@(require_results)
exa_decode :: proc(body: []u8) -> (response: Response, err: Error) {
	wire: Exa_Wire
	if err = json_decode(body, &wire, "exa"); err.kind != .None { return }
	results, present := wire.results.?
	if !present { return {}, {kind = .Invalid_Response, detail = "exa: the response has no results list"} }
	if response.results, err = results_make(len(results)); err.kind != .None { return }
	for result, i in results {
		snippet := result.text
		if len(result.highlights) > 0 {
			joined, join_err := strings.join(result.highlights, " ", context.temp_allocator)
			if join_err != nil { return {}, OUT_OF_MEMORY }
			snippet = joined
		}
		response.results[i] = {
			title     = result.title,
			url       = result.url,
			snippet   = snippet,
			published = result.publishedDate,
		}
	}
	return
}
