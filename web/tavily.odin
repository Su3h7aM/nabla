package web

import "core:strings"

import "nabla:http/client"

// The URL and the maximum count are from the Tavily Search API reference.
@(private)
TAVILY_URL :: "https://api.tavily.com/search"
@(private)
TAVILY_MAX_COUNT :: 20

@(private)
Tavily_Request :: struct {
	query:                  string,
	max_results:            Maybe(int) `json:",omitempty"`,
	search_depth:           string,
	include_answer:         string,
	include_published_date: bool,
	time_range:             string `json:",omitempty"`,
	include_domains:        []string `json:",omitempty"`,
	exclude_domains:        []string `json:",omitempty"`,
}

@(private)
Tavily_Wire :: struct {
	answer:  string,
	results: Maybe([]struct {
			title:          string,
			url:            string,
			content:        string,
			published_date: string,
		}),
}

@(private)
@(require_results)
tavily_request :: proc(endpoint: Endpoint, query: Query) -> (request: client.Request, clamped_to: int, err: Error) {
	wire := Tavily_Request {
		query                  = query.text,
		search_depth           = "basic",
		include_answer         = "basic",
		include_published_date = true,
		include_domains        = query.include_domains,
		exclude_domains        = query.exclude_domains,
	}
	count: int
	count, clamped_to = clamp_count(query.count, TAVILY_MAX_COUNT)
	if count > 0 { wire.max_results = count }
	switch query.freshness {
	case .Any:
	case .Day:
		wire.time_range = "day"
	case .Week:
		wire.time_range = "week"
	case .Month:
		wire.time_range = "month"
	case .Year:
		wire.time_range = "year"
	}
	if request.body, err = json_encode(wire); err.kind != .None { return }
	authorization, concat_err := strings.concatenate({"Bearer ", endpoint.api_key}, context.temp_allocator)
	if concat_err != nil { return {}, 0, OUT_OF_MEMORY }
	request.url = endpoint.base_url if endpoint.base_url != "" else TAVILY_URL
	request.method = .Post
	request.headers, err = headers_make({"Authorization", authorization}, {"Content-Type", "application/json"}, {"Accept", "application/json"})
	return
}

@(private)
@(require_results)
tavily_decode :: proc(body: []u8) -> (response: Response, err: Error) {
	wire: Tavily_Wire
	if err = json_decode(body, &wire, "tavily"); err.kind != .None { return }
	results, present := wire.results.?
	if !present { return {}, {kind = .Invalid_Response, detail = "tavily: the response has no results list"} }
	response.answer = wire.answer
	if response.results, err = results_make(len(results)); err.kind != .None { return }
	for result, i in results {
		response.results[i] = {
			title     = result.title,
			url       = result.url,
			snippet   = result.content,
			published = result.published_date,
		}
	}
	return
}
