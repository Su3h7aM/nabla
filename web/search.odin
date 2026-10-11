package web

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import "nabla:http"
import "nabla:http/client"

// BROWSER_USER_AGENT identifies browser-compatible requests to public sites.
@(private)
BROWSER_USER_AGENT :: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

Provider :: enum {
	DuckDuckGo, // zero value: needs no key
	Brave,
	Tavily,
	Exa, // the REST API; needs an api_key
	Exa_MCP, // Exa's public MCP endpoint; needs no key
	SearXNG,
}

Freshness :: enum {
	Any,
	Day,
	Week,
	Month,
	Year,
}

// Query is one search. Strings and slices are borrowed for the call.
Query :: struct {
	text:            string,
	count:           int, // 0 means the provider's default
	freshness:       Freshness,
	include_domains: []string,
	exclude_domains: []string,
}

// Endpoint is one configured provider. api_key is "" for keyless providers.
// base_url replaces the provider's documented URL; for SearXNG it is the
// instance root, to which /search is appended, and it is required.
Endpoint :: struct {
	provider: Provider,
	api_key:  string,
	base_url: string,
}

Result :: struct {
	title:     string, // provider's title, or the URL host and port without userinfo when empty
	url:       string,
	snippet:   string,
	published: string, // as the provider wrote it; "" when absent
}

Response :: struct {
	results:          []Result,
	answer:           string, // a provider's synthesized answer (Tavily), "" when none
	count_clamped_to: int, // the provider's maximum when Query.count exceeded it and was lowered; 0 otherwise
}

Error_Kind :: enum {
	None,
	Missing_Credential, // the provider needs api_key or base_url
	Unauthorized, // 401, 403
	Challenged, // Cloudflare's documented cf-mitigated: challenge response, or a search engine's bot challenge page
	Quota, // 402
	Rate_Limited, // 429; retry_after when the response stated one
	Rejected, // other statuses outside 2xx below 500, or an error the provider reported in a 2xx reply
	Server, // 5xx
	Transport, // DNS, TLS, connection, framing
	Timed_Out,
	Cancelled,
	Invalid_Response, // the body did not decode into results
	Unsupported_Content, // the media type, character encoding, or content coding cannot be converted
	Out_Of_Memory,
}

Error :: struct {
	kind:        Error_Kind,
	status:      int, // the HTTP status, 0 when none was received
	retry_after: time.Duration, // from Retry-After on any HTTP refusal, 0 when absent
	detail:      string, // "" when kind and status say it all; owned by the allocator passed to search or fetch; never holds the API key
}

// error_destroy releases the detail of an Error returned by search or fetch.
error_destroy :: proc(err: ^Error, allocator := context.allocator) {
	if err.detail != "" { delete(err.detail, allocator) }
	err^ = {}
}

// search sends query to endpoint and returns the normalized results. The
// Response is owned by allocator and released with response_destroy; an Error's
// detail is owned by allocator too and released with error_destroy. options
// carries the caller's probe, so cancellation and the deadline belong to the
// caller.
//
// A provider that needs a credential and has none returns Missing_Credential
// before any request is sent. Scratch memory comes from context.temp_allocator
// and is released before search returns. A failure to allocate anywhere is
// Out_Of_Memory. An Error detail is static text plus numbers the package owns,
// such as a status or a JSON-RPC code; text a provider sent never enters it.
@(require_results)
search :: proc(endpoint: Endpoint, query: Query, options: client.Options, allocator := context.allocator) -> (response: Response, err: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	borrowed, failure := search_scratch(endpoint, query, options)
	if failure.kind != .None {
		cloned_detail, clone_err := strings.clone(failure.detail, allocator)
		if clone_err != nil { return {}, OUT_OF_MEMORY }
		failure.detail = cloned_detail
		return {}, failure
	}
	cloned, clone_err := response_clone(borrowed, allocator)
	if clone_err != nil { return {}, OUT_OF_MEMORY }
	return cloned, {}
}

// response_destroy releases a Response returned by search.
response_destroy :: proc(response: ^Response, allocator := context.allocator) {
	for result in response.results {
		delete(result.title, allocator)
		delete(result.url, allocator)
		delete(result.snippet, allocator)
		delete(result.published, allocator)
	}
	delete(response.results, allocator)
	delete(response.answer, allocator)
	response^ = {}
}

// search_scratch does the whole exchange with strings that borrow from
// context.temp_allocator, so search copies the outcome once at its end.
@(private)
search_scratch :: proc(endpoint: Endpoint, query: Query, options: client.Options) -> (response: Response, err: Error) {
	if err = credential_require(endpoint); err.kind != .None { return }
	request: client.Request
	clamped_to: int
	switch endpoint.provider {
	case .DuckDuckGo:
		request, clamped_to, err = duckduckgo_request(endpoint, query)
	case .Brave:
		request, clamped_to, err = brave_request(endpoint, query)
	case .Tavily:
		request, clamped_to, err = tavily_request(endpoint, query)
	case .Exa:
		request, clamped_to, err = exa_request(endpoint, query)
	case .Exa_MCP:
		request, clamped_to, err = exa_mcp_request(endpoint, query)
	case .SearXNG:
		request, clamped_to, err = searxng_request(endpoint, query)
	}
	if err.kind != .None { return }

	body: []u8
	body, err = exchange(request, options)
	// Tavily documents 432 and 433 as plan and pay-as-you-go quota refusals.
	if endpoint.provider == .Tavily && err.kind == .Rejected && (err.status == 432 || err.status == 433) { err.kind = .Quota }
	// A SearXNG instance answers 403 when its settings do not list json under search.formats.
	if endpoint.provider == .SearXNG && err.kind == .Unauthorized && err.status == 403 {
		err.detail = "the instance refused the request; it may not enable the json format"
	}
	if err.kind != .None { return }

	switch endpoint.provider {
	case .DuckDuckGo:
		response, err = duckduckgo_decode(body)
	case .Brave:
		response, err = brave_decode(body)
	case .Tavily:
		response, err = tavily_decode(body)
	case .Exa:
		response, err = exa_decode(body)
	case .Exa_MCP:
		response, err = exa_mcp_decode(body)
	case .SearXNG:
		response, err = searxng_decode(body)
	}
	if err.kind != .None { return {}, err }
	response.results = results_unique(response.results)
	if query.count > 0 { response.results = response.results[:min(len(response.results), query.count)] }
	for &result in response.results {
		if result.title != "" { continue }
		host := http.url_parse(result.url).host
		if separator := strings.last_index_byte(host, '@'); separator >= 0 { host = host[separator + 1:] }
		result.title = host
	}
	response.count_clamped_to = clamped_to
	return response, {}
}

@(private)
credential_require :: proc(endpoint: Endpoint) -> Error {
	switch endpoint.provider {
	case .Brave, .Tavily, .Exa:
		if endpoint.api_key == "" { return {kind = .Missing_Credential, detail = fmt.tprintf("%v needs an api_key", endpoint.provider)} }
	case .SearXNG:
		if endpoint.base_url == "" { return {kind = .Missing_Credential, detail = "SearXNG needs a base_url"} }
	case .DuckDuckGo, .Exa_MCP:
	}
	return {}
}

// OUT_OF_MEMORY is the Error for a failed allocation.
@(private)
OUT_OF_MEMORY :: Error {
	kind = .Out_Of_Memory,
}

// response_clone copies a Response whose strings borrow scratch memory. Each
// field is stored as soon as it is cloned, so a failure leaves only what
// response_destroy releases.
@(private)
@(require_results)
response_clone :: proc(source: Response, allocator: runtime.Allocator) -> (response: Response, err: runtime.Allocator_Error) {
	defer if err != nil { response_destroy(&response, allocator) }
	response.count_clamped_to = source.count_clamped_to
	response.answer = strings.clone(source.answer, allocator) or_return
	response.results = make([]Result, len(source.results), allocator) or_return
	for result, i in source.results {
		destination := &response.results[i]
		destination.title = strings.clone(result.title, allocator) or_return
		destination.url = strings.clone(result.url, allocator) or_return
		destination.snippet = strings.clone(result.snippet, allocator) or_return
		destination.published = strings.clone(result.published, allocator) or_return
	}
	return response, nil
}

// results_make returns count zeroed results in scratch memory.
@(private)
@(require_results)
results_make :: proc(count: int) -> (results: []Result, err: Error) {
	made, make_err := make([]Result, count, context.temp_allocator)
	if make_err != nil { return nil, OUT_OF_MEMORY }
	return made, {}
}

// results_unique drops, in place, every result whose URL an earlier result has,
// and returns the shortened slice.
@(private)
results_unique :: proc(results: []Result) -> []Result {
	kept := 0
	outer: for result in results {
		for earlier in results[:kept] {
			if earlier.url == result.url { continue outer }
		}
		results[kept] = result
		kept += 1
	}
	return results[:kept]
}

// clamp_count returns the count to send for a provider whose documented maximum
// is maximum, and the maximum when the request was lowered to it or 0.
@(private)
clamp_count :: proc(count, maximum: int) -> (sent, clamped_to: int) {
	if count > maximum { return maximum, maximum }
	return count, 0
}

// write appends every part to builder and reports whether all of it fit.
@(private)
@(require_results)
write :: proc(builder: ^strings.Builder, parts: ..string) -> bool {
	for part in parts {
		if strings.write_string(builder, part) != len(part) { return false }
	}
	return true
}

// query_text returns the query with domain filters folded in as site: terms, for
// providers without native domain filters.
@(private)
@(require_results)
query_text :: proc(query: Query) -> (text: string, err: Error) {
	if len(query.include_domains) == 0 && len(query.exclude_domains) == 0 { return query.text, {} }
	builder, make_err := strings.builder_make(context.temp_allocator)
	if make_err != nil { return "", OUT_OF_MEMORY }
	ok := write(&builder, query.text)
	if len(query.include_domains) == 1 {
		ok &&= write(&builder, " site:", query.include_domains[0])
	} else if len(query.include_domains) > 1 {
		ok &&= write(&builder, " (")
		for domain, i in query.include_domains {
			if i > 0 { ok &&= write(&builder, " OR ") }
			ok &&= write(&builder, "site:", domain)
		}
		ok &&= write(&builder, ")")
	}
	for domain in query.exclude_domains {
		ok &&= write(&builder, " -site:", domain)
	}
	if !ok { return "", OUT_OF_MEMORY }
	return strings.to_string(builder), {}
}

@(private)
Param :: struct {
	name:   string,
	value:  string, // percent-encoded into the URL
	number: int, // sent in place of an empty value when positive
}

// url_build appends the parameters that have a value or a positive number to
// base, after & when base already has a query string. A fragment of base is
// dropped, since it is never sent.
@(private)
@(require_results)
url_build :: proc(base: string, params: []Param) -> (url: string, err: Error) {
	builder, make_err := strings.builder_make(context.temp_allocator)
	if make_err != nil { return "", OUT_OF_MEMORY }
	location, _, _ := strings.partition(base, "#")
	ok := write(&builder, location)
	separator := "&" if strings.contains_rune(location, '?') else "?"
	for param in params {
		if param.value == "" && param.number <= 0 { continue }
		ok &&= write(&builder, separator, param.name, "=")
		separator = "&"
		if param.value != "" {
			ok &&= percent_write(&builder, param.value)
		} else {
			digits: [20]u8
			ok &&= write(&builder, strconv.write_int(digits[:], i64(param.number), 10))
		}
	}
	if !ok { return "", OUT_OF_MEMORY }
	return strings.to_string(builder), {}
}

// percent_write writes value with every byte outside the RFC 3986 unreserved set escaped.
@(private)
@(require_results)
percent_write :: proc(builder: ^strings.Builder, value: string) -> bool {
	DIGITS :: "0123456789ABCDEF"
	hex := DIGITS
	for i in 0 ..< len(value) {
		switch value[i] {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '.', '_', '~':
			if !write(builder, value[i:i + 1]) { return false }
		case:
			if !write(builder, "%", hex[value[i] >> 4:][:1], hex[value[i] & 15:][:1]) { return false }
		}
	}
	return true
}

@(private)
@(require_results)
headers_make :: proc(headers: ..client.Header) -> (made: []client.Header, err: Error) {
	cloned, clone_err := slice.clone(headers, context.temp_allocator)
	if clone_err != nil { return nil, OUT_OF_MEMORY }
	return cloned, {}
}

// json_encode marshals a request body into scratch memory.
@(private)
@(require_results)
json_encode :: proc(value: any) -> (body: []u8, err: Error) {
	encoded, marshal_err := json.marshal(value, {}, context.temp_allocator)
	if marshal_err != nil { return nil, OUT_OF_MEMORY }
	return encoded, {}
}

// json_decode unmarshals a response body into scratch memory. provider names the
// source in the Error detail.
@(private)
@(require_results)
json_decode :: proc(body: []u8, wire: ^$T, provider: string) -> (err: Error) {
	unmarshal_err := json.unmarshal(body, wire, allocator = context.temp_allocator)
	if unmarshal_err == nil { return {} }
	if json_error, is_json := unmarshal_err.(json.Error); is_json && json_error == .Out_Of_Memory { return OUT_OF_MEMORY }
	return {kind = .Invalid_Response, detail = fmt.tprintf("%s: the response is not the expected JSON", provider)}
}

// Exchange collects one response body and what the head said about retrying.
@(private)
Exchange :: struct {
	body:           [dynamic]u8,
	retry_after:    time.Duration,
	status:         int,
	content_type:   string,
	content_coding: string,
	location:       Maybe(string),
	stop_redirects: bool,
	challenged:     bool,
	failed:         bool,
}

@(private)
exchange_collect :: proc(state: ^Exchange, chunk: []u8) {
	if state.failed { return }
	if _, append_err := append(&state.body, ..chunk); append_err != nil { state.failed = true }
}

// exchange_header returns a header value cloned into scratch memory. An
// allocation failure marks the exchange failed.
@(private)
exchange_header :: proc(state: ^Exchange, headers: http.Headers, name: string) -> (value: string, found: bool) {
	borrowed := http.headers_get_unsafe(headers, name) or_return
	cloned, clone_err := strings.clone(borrowed, context.temp_allocator)
	if clone_err != nil {
		state.failed = true
		return "", false
	}
	return cloned, true
}

@(private)
exchange_head :: proc(user_data: rawptr, head: client.Response_Head, headers: http.Headers) -> client.Response_Head_Action {
	state := cast(^Exchange)user_data
	state.status = head.status
	// Cloudflare documents this header as the marker for every challenge response.
	if value, found := http.headers_get_unsafe(headers, "cf-mitigated"); found {
		state.challenged = strings.equal_fold(strings.trim_space(value), "challenge")
	}
	state.content_type, _ = exchange_header(state, headers, "content-type")
	state.content_coding, _ = exchange_header(state, headers, "content-encoding")
	if value, found := exchange_header(state, headers, "location"); found { state.location = value }
	if state.failed { return .Stop }
	if state.stop_redirects && redirect_status(head.status) {
		if _, present := state.location.?; present { return .Stop }
	}
	if head.usable && !state.challenged { return .Continue }
	if value, found := http.headers_get_unsafe(headers, "retry-after"); found {
		state.retry_after = retry_after_parse(value)
	}
	return .Continue
}

// retry_after_parse reads a Retry-After value, which RFC 9110 10.2.3 makes either
// a number of seconds or an HTTP date. An unreadable or past value is 0.
@(private)
retry_after_parse :: proc(value: string) -> time.Duration {
	trimmed := strings.trim_space(value)
	if seconds, ok := strconv.parse_i64(trimmed); ok { return time.Duration(max(seconds, 0)) * time.Second }
	if instant, ok := http.date_parse(trimmed); ok { return max(time.diff(time.now(), instant), 0) }
	return 0
}

// exchange performs the request and returns the body of a 2xx response, in scratch
// memory. Every other outcome is an Error decided from the status, with the
// Retry-After of any refusal. A cancellation or deadline that ended the transfer
// wins over the status of the refusal it interrupted.
// With stop_redirects, a redirect with a Location header returns success and an
// empty body immediately after its head; metadata retains the status and location.
@(private)
@(require_results)
exchange :: proc(request: client.Request, options: client.Options, metadata: ^Exchange = nil, stop_redirects: bool = false) -> (body: []u8, err: Error) {
	request := request
	request.allocator = context.temp_allocator
	headers, headers_err := make([]client.Header, len(request.headers) + 1, context.temp_allocator)
	if headers_err != nil { return nil, OUT_OF_MEMORY }
	copy(headers, request.headers)
	headers[len(request.headers)] = {"Accept-Encoding", "gzip, deflate"}
	request.headers = headers
	state: Exchange
	state.stop_redirects = stop_redirects
	state.body.allocator = context.temp_allocator
	defer if err.kind != .None { delete(state.body) }
	options := options
	options.response_head = {
		user_data = &state,
		observed  = exchange_head,
	}
	failure := client.stream_request(request, options, &state, exchange_collect)
	if metadata != nil {
		metadata^ = state
		metadata.body = nil
	}
	if state.failed { return nil, OUT_OF_MEMORY }
	err.status = failure.status if failure.status != 0 else state.status
	err.detail = failure.detail
	switch {
	case failure.kind == .Cancelled, failure.cause == .Cancelled:
		err.kind = .Cancelled
	case failure.kind == .Timed_Out, failure.cause == .Timed_Out:
		err.kind = .Timed_Out
	case failure.cause != .None:
		err.kind = .Transport
	case state.challenged && (failure.kind == .None || failure.kind == .HTTP_Status):
		err.kind = .Challenged
		err.retry_after = state.retry_after
		err.detail = "the site answered with a bot challenge instead of the page"
	case failure.kind == .None:
		if !stop_redirects || !redirect_status(state.status) {
			err = content_decode(&state)
			if err.kind != .None {
				err.status = state.status
				return nil, err
			}
		}
		return state.body[:], {}
	case failure.kind == .HTTP_Status:
		err.kind = error_kind_from_status(failure.status)
		err.retry_after = state.retry_after
		// The client's detail only restates the status, which err.status carries.
		err.detail = ""
	case:
		err.kind = .Transport
	}
	return nil, err
}

// error_kind_from_status is the one mapping from an HTTP status outside 2xx to an
// Error_Kind.
@(private)
error_kind_from_status :: proc(status: int) -> Error_Kind {
	switch {
	case status == 401, status == 403:
		return .Unauthorized
	case status == 402:
		return .Quota
	case status == 429:
		return .Rate_Limited
	case status >= 500:
		return .Server
	}
	return .Rejected
}
