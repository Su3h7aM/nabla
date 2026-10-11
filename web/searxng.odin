package web

import "core:strings"

import "nabla:http/client"

@(private)
Searxng_Wire :: struct {
	results: Maybe([]struct {
			title:         string,
			url:           string,
			content:       string,
			publishedDate: string,
		}),
}

@(private)
@(require_results)
searxng_request :: proc(endpoint: Endpoint, query: Query) -> (request: client.Request, clamped_to: int, err: Error) {
	// SearXNG offers day, month, and year; a week is the nearest period it covers.
	time_range: string
	switch query.freshness {
	case .Any:
	case .Day:
		time_range = "day"
	case .Week, .Month:
		time_range = "month"
	case .Year:
		time_range = "year"
	}
	// /search belongs to the path, so it goes before any query string or fragment of the instance URL, and a fragment is dropped.
	location, _, _ := strings.partition(endpoint.base_url, "#")
	root, separator, tail := strings.partition(location, "?")
	base, concat_err := strings.concatenate({strings.trim_right(root, "/"), "/search", separator, tail}, context.temp_allocator)
	if concat_err != nil { return {}, 0, OUT_OF_MEMORY }
	text: string
	if text, err = query_text(query); err.kind != .None { return }
	if request.url, err = url_build(base, {{name = "q", value = text}, {name = "format", value = "json"}, {name = "time_range", value = time_range}});
	   err.kind != .None { return }
	request.method = .Get
	request.headers, err = headers_make({"Accept", "application/json"})
	return
}

@(private)
@(require_results)
searxng_decode :: proc(body: []u8) -> (response: Response, err: Error) {
	wire: Searxng_Wire
	if err = json_decode(body, &wire, "searxng"); err.kind != .None { return }
	results, present := wire.results.?
	if !present { return {}, {kind = .Invalid_Response, detail = "searxng: the response has no results list"} }
	if response.results, err = results_make(len(results)); err.kind != .None { return }
	for result, i in results {
		response.results[i] = {
			title     = result.title,
			url       = result.url,
			snippet   = result.content,
			published = result.publishedDate,
		}
	}
	return
}
