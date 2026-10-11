#+test
package web

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

import "nabla:http/client"

// The tests run search against a local listener that answers each connection with
// a canned response and records what it received.

MAX_CONNECTIONS :: 4
CAPTURE_SIZE :: 8192

Captured :: struct {
	bytes:  [CAPTURE_SIZE]u8,
	length: int,
}

Server :: struct {
	listener:  net.TCP_Socket,
	responses: []string,
	captured:  [MAX_CONNECTIONS]Captured,
	worker:    ^thread.Thread,
	url:       string,
}

// server_start listens on a free local port and serves responses, one per
// connection, in order. The test must make exactly len(responses) connections.
server_start :: proc(t: ^testing.T, server: ^Server, responses: []string) -> bool {
	listener, listen_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, MAX_CONNECTIONS)
	if !testing.expectf(t, listen_err == nil, "the test endpoint could not listen: %v", listen_err) { return false }
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if !testing.expectf(t, endpoint_err == nil, "the test endpoint could not be read: %v", endpoint_err) {
		net.close(listener)
		return false
	}
	server.listener = listener
	server.responses = responses
	server.url = fmt.tprintf("http://127.0.0.1:%d", endpoint.port)
	server.worker = thread.create(server_serve, name = "nabla-web-test")
	if server.worker == nil {
		net.close(listener)
		testing.fail_now(t, "the test server thread could not be created")
	}
	server.worker.data = server
	thread.start(server.worker)
	return true
}

server_stop :: proc(server: ^Server) {
	thread.join(server.worker)
	thread.destroy(server.worker)
	net.close(server.listener)
}

server_serve :: proc(worker: ^thread.Thread) {
	server := cast(^Server)worker.data
	for response, i in server.responses {
		socket, _, accept_err := net.accept_tcp(server.listener)
		if accept_err != nil { return }
		server_exchange(socket, &server.captured[i], response)
		net.close(socket)
	}
}

server_exchange :: proc(socket: net.TCP_Socket, captured: ^Captured, response: string) {
	head_end := -1
	for head_end < 0 && captured.length < CAPTURE_SIZE {
		count, recv_err := net.recv_tcp(socket, captured.bytes[captured.length:])
		if recv_err != nil || count <= 0 { return }
		captured.length += count
		head_end = strings.index(string(captured.bytes[:captured.length]), "\r\n\r\n")
	}
	if head_end < 0 { return }
	head_end += len("\r\n\r\n")

	// Read the whole request body before answering, so closing the socket never resets the client's write.
	want := 0
	head := string(captured.bytes[:head_end])
	for line in strings.split_lines_iterator(&head) {
		if len(line) > len("content-length:") && strings.equal_fold(line[:len("content-length:")], "content-length:") {
			want, _ = strconv.parse_int(strings.trim_space(line[len("content-length:"):]))
		}
	}
	for captured.length < head_end + want && captured.length < CAPTURE_SIZE {
		count, recv_err := net.recv_tcp(socket, captured.bytes[captured.length:])
		if recv_err != nil || count <= 0 { return }
		captured.length += count
	}

	remaining := transmute([]u8)response
	for len(remaining) > 0 {
		count, send_err := net.send_tcp(socket, remaining)
		if send_err != nil || count <= 0 { return }
		remaining = remaining[count:]
	}
}

// received returns what connection i sent, lowercased so header names compare freely.
received :: proc(server: ^Server, i: int) -> string {
	return strings.to_lower(string(server.captured[i].bytes[:server.captured[i].length]), context.temp_allocator)
}

reply :: proc(status: int, headers: string, body: string) -> string {
	return fmt.tprintf("HTTP/1.1 %d X\r\ncontent-length: %d\r\nconnection: close\r\n%s\r\n%s", status, len(body), headers, body)
}

Normalized_Case :: struct {
	endpoint:     Endpoint,
	query:        Query,
	headers:      string,
	body:         string,
	request_has:  []string,
	first:        Result,
	result_count: int,
	clamped_to:   int,
	answer:       string,
}

MCP_TEXT :: `{\"results\":[{\"title\":\"Bun v1.2\",\"url\":\"https://bun.sh/blog/bun-v1.2\",\"publishedDate\":\"2025-01-22\",\"highlights\":[\"Bun 1.2 adds\",\"SQL support.\"]},{\"title\":\"B\",\"url\":\"https://example.com/b\",\"text\":\"second\"}]}`

@(test)
test_search_normalizes_every_provider :: proc(t: ^testing.T) {
	cases := []Normalized_Case {
		{
			endpoint = {provider = .Brave, api_key = "brave-key"},
			query = {text = "bun release", count = 50, freshness = .Week},
			body = `{"type":"search","web":{"results":[{"title":"Bun <strong>v1.2</strong>","url":"https://bun.sh/blog/bun-v1.2","description":"Bun 1.2 adds &#x27;x&#x27;","age":"2 days ago","extra":1},{"title":"B","url":"https://b","description":"d"},{"title":"again","url":"https://b","description":"duplicate"}]}}`,
			request_has = {"get /?q=bun%20release&count=20&freshness=pw ", "x-subscription-token: brave-key", "accept-encoding: gzip, deflate"},
			first = {"Bun v1.2", "https://bun.sh/blog/bun-v1.2", "Bun 1.2 adds 'x'", "2 days ago"},
			result_count = 2,
			clamped_to = 20,
		},
		{
			endpoint = {provider = .Tavily, api_key = "tavily-key"},
			query = {text = "bun", count = 3, freshness = .Month, include_domains = {"bun.sh"}},
			body = `{"answer":"Bun is a runtime.","results":[{"title":"Bun","url":"https://bun.sh","content":"fast","published_date":"2025-01-22"}]}`,
			request_has = {"post / ", "authorization: bearer tavily-key", `"max_results":3`, `"time_range":"month"`, `"include_domains":["bun.sh"]`},
			first = {"Bun", "https://bun.sh", "fast", "2025-01-22"},
			result_count = 1,
			answer = "Bun is a runtime.",
		},
		{
			endpoint = {provider = .Exa, api_key = "exa-key"},
			query = {text = "bun", count = 5, freshness = .Day, exclude_domains = {"spam.example"}},
			body = `{"results":[{"title":"Bun","url":"https://bun.sh","publishedDate":"2025-01-22T00:00:00.000Z","highlights":["one","two"],"text":"ignored"},{"title":"T","url":"https://t","text":"body text"}]}`,
			request_has = {"x-api-key: exa-key", `"numresults":5`, `"startpublisheddate":"20`, `"highlights":true`, `"excludedomains":["spam.example"]`},
			first = {"Bun", "https://bun.sh", "one two", "2025-01-22T00:00:00.000Z"},
			result_count = 2,
		},
		{
			endpoint = {provider = .Exa_MCP},
			query = {text = "bun", count = 500, freshness = .Day, include_domains = {"bun.sh"}, exclude_domains = {"spam.example"}},
			headers = "content-type: text/event-stream\r\n",
			body = "event: message\ndata: " + `{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"` + MCP_TEXT + `"}]}}` + "\n\n",
			request_has = {
				"accept: application/json, text/event-stream",
				`"name":"web_search_advanced_exa"`,
				`"numresults":100`,
				`"enablehighlights":true`,
				`"includedomains":["bun.sh"]`,
				`"excludedomains":["spam.example"]`,
				`"startpublisheddate":"20`,
			},
			first = {"Bun v1.2", "https://bun.sh/blog/bun-v1.2", "Bun 1.2 adds SQL support.", "2025-01-22"},
			result_count = 2,
			clamped_to = 100,
		},
		{
			endpoint = {provider = .SearXNG},
			query = {text = "bun", count = 1, freshness = .Week, exclude_domains = {"spam.example"}},
			body = `{"results":[{"title":"Bun","url":"https://bun.sh","content":"fast","publishedDate":null},{"title":"B","url":"https://b","content":"x"}]}`,
			request_has = {"get /search?q=bun%20-site%3aspam.example&format=json&time_range=month ", "accept: application/json"},
			first = {"Bun", "https://bun.sh", "fast", ""},
			result_count = 1,
		},
	}
	for test_case in cases {
		server: Server
		responses := []string{reply(200, test_case.headers, test_case.body)}
		if !server_start(t, &server, responses) { return }
		endpoint := test_case.endpoint
		endpoint.base_url = server.url
		if endpoint.provider == .SearXNG { endpoint.base_url = strings.concatenate({server.url, "/"}, context.temp_allocator) }

		response, err := search(endpoint, test_case.query, {})
		server_stop(&server)
		defer response_destroy(&response)
		defer error_destroy(&err)

		name := PROVIDER_NAMES
		testing.expectf(t, err.kind == .None, "%s: %v %s", name[endpoint.provider], err.kind, err.detail)
		if err.kind != .None { continue }
		request := received(&server, 0)
		for expected in test_case.request_has {
			testing.expectf(t, strings.contains(request, expected), "%s: the request lacks %q:\n%s", name[endpoint.provider], expected, request)
		}
		testing.expect_value(t, len(response.results), test_case.result_count)
		if len(response.results) > 0 { testing.expect_value(t, response.results[0], test_case.first) }
		testing.expect_value(t, response.count_clamped_to, test_case.clamped_to)
		testing.expect_value(t, response.answer, test_case.answer)
	}
}

@(test)
test_search_fills_empty_titles_for_every_provider :: proc(t: ^testing.T) {
	Case :: struct {
		provider: Provider,
		body:     string,
	}
	cases := []Case {
		{.DuckDuckGo, `<div class="results"><div class="result"><a class="result__a" href="https://reader:secret@empty.example:8443/path"></a></div></div>`},
		{.Brave, `{"type":"search","web":{"results":[{"url":"https://reader:secret@empty.example:8443/path"}]}}`},
		{.Tavily, `{"results":[{"url":"https://reader:secret@empty.example:8443/path"}]}`},
		{.Exa, `{"results":[{"url":"https://reader:secret@empty.example:8443/path"}]}`},
		{
			.Exa_MCP,
			`{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"results\":[{\"url\":\"https://reader:secret@empty.example:8443/path\"}]}"}]}}`,
		},
		{.SearXNG, `{"results":[{"url":"https://reader:secret@empty.example:8443/path"}]}`},
	}
	for entry in cases {
		server: Server
		if !server_start(t, &server, []string{reply(200, "", entry.body)}) { return }
		response, err := search({provider = entry.provider, api_key = "key", base_url = server.url}, {text = "empty title"}, {})
		server_stop(&server)
		defer response_destroy(&response)
		defer error_destroy(&err)
		testing.expectf(t, err.kind == .None, "%v: %v %s", entry.provider, err.kind, err.detail)
		if testing.expect_value(t, len(response.results), 1) {
			testing.expect_value(t, response.results[0].title, "empty.example:8443")
			testing.expect_value(t, response.results[0].url, "https://reader:secret@empty.example:8443/path")
		}
	}
}

@(test)
test_fetch_and_search_classify_documented_challenges :: proc(t: ^testing.T) {
	Case :: struct {
		response:    string,
		kind:        Error_Kind,
		status:      int,
		retry_after: time.Duration,
	}
	headers := "content-type: text/html\r\ncf-mitigated: \tChAlLeNgE \t\r\nretry-after: 7\r\n"
	body := "<html><head><title>Just a moment...</title></head><body>challenge</body></html>"
	cases := []Case {
		{reply(403, headers, body), .Challenged, 403, 7 * time.Second},
		{reply(200, headers, body), .Challenged, 200, 7 * time.Second},
		{reply(403, "cf-mitigated: other\r\n", body), .Unauthorized, 403, 0},
		{"HTTP/1.1 403 Forbidden\r\ncf-mitigated: challenge\r\ncontent-length: 99\r\nconnection: close\r\n\r\nx", .Transport, 403, 0},
		{"HTTP/1.1 403 Forbidden\r\ncf-mitigated: challenge\r\ncontent-length: invalid\r\nconnection: close\r\n\r\n", .Transport, 403, 0},
	}
	for entry in cases {
		server: Server
		if !server_start(t, &server, []string{entry.response, entry.response}) { return }
		page, fetch_err := fetch(server.url, .Markdown, {})
		response, search_err := search({provider = .Brave, api_key = "key", base_url = server.url}, {text = "query"}, {})
		server_stop(&server)
		defer page_destroy(&page)
		defer response_destroy(&response)
		defer error_destroy(&fetch_err)
		defer error_destroy(&search_err)
		for err in ([]Error{fetch_err, search_err}) {
			testing.expect_value(t, err.kind, entry.kind)
			testing.expect_value(t, err.status, entry.status)
			testing.expect_value(t, err.retry_after, entry.retry_after)
			if entry.kind == .Challenged { testing.expect_value(t, err.detail, "the site answered with a bot challenge instead of the page") }
		}
		testing.expect_value(t, page.content, "")
		testing.expect_value(t, len(response.results), 0)
	}
}

@(test)
test_search_maps_failures_to_error_kinds :: proc(t: ^testing.T) {
	Failure_Case :: struct {
		endpoint:    Endpoint,
		path:        string, // appended to the listener URL
		response:    string,
		kind:        Error_Kind,
		status:      int,
		retry_after: time.Duration,
	}
	brave := Endpoint {
		provider = .Brave,
		api_key  = "secret-key",
	}
	echo := `{"jsonrpc":"2.0","id":1,"error":{"message":"bad mcp-key at /mcp?token=qs-secret"}}`
	cases := []Failure_Case {
		{brave, "", reply(401, "", `{"error":"bad key"}`), .Unauthorized, 401, 0},
		{brave, "", reply(429, "retry-after: 30\r\n", ""), .Rate_Limited, 429, 30 * time.Second},
		{brave, "", reply(500, "retry-after: 7\r\n", "oops"), .Server, 500, 7 * time.Second},
		{{provider = .Tavily, api_key = "secret-key"}, "", reply(432, "", ""), .Quota, 432, 0},
		{brave, "", reply(200, "", "<html>not json</html>"), .Invalid_Response, 0, 0},
		{brave, "", reply(200, "", `{}`), .Invalid_Response, 0, 0},
		{{provider = .Tavily, api_key = "secret-key"}, "", reply(200, "", `{"detail":"x"}`), .Invalid_Response, 0, 0},
		{{provider = .Exa_MCP, api_key = "mcp-key"}, "/mcp?token=qs-secret", reply(200, "", echo), .Rejected, 0, 0},
	}
	for test_case in cases {
		server: Server
		responses := []string{test_case.response}
		if !server_start(t, &server, responses) { return }
		endpoint := test_case.endpoint
		endpoint.base_url = strings.concatenate({server.url, test_case.path}, context.temp_allocator)
		response, err := search(endpoint, {text = "bun"}, {})
		server_stop(&server)
		defer error_destroy(&err)

		testing.expect_value(t, err.kind, test_case.kind)
		testing.expect_value(t, err.status, test_case.status)
		testing.expect_value(t, err.retry_after, test_case.retry_after)
		testing.expect(t, len(response.results) == 0, "a failed search returns no results")
		// Whatever a provider says in its body stays out of the detail.
		for secret in ([]string{"secret-key", "mcp-key", "qs-secret", "bad"}) {
			testing.expectf(t, !strings.contains(err.detail, secret), "the detail holds %q: %s", secret, err.detail)
		}
	}

	// A search without matches is a success: Brave leaves out the web section.
	server: Server
	responses := []string{reply(200, "", `{"type":"search"}`)}
	if !server_start(t, &server, responses) { return }
	response, err := search(
		{provider = .Brave, api_key = "key", base_url = strings.concatenate({server.url, "/x?a=1"}, context.temp_allocator)},
		{text = "bun"},
		{},
	)
	server_stop(&server)
	defer response_destroy(&response)
	defer error_destroy(&err)
	testing.expect_value(t, err.kind, Error_Kind.None)
	testing.expect_value(t, len(response.results), 0)
	testing.expect(t, strings.has_prefix(received(&server, 0), "get /x?a=1&q=bun "), received(&server, 0))

	// A provider that needs a credential never sends without one.
	for provider in ([]Provider{.Brave, .Tavily, .Exa, .SearXNG}) {
		_, err := search({provider = provider}, {text = "bun"}, {})
		defer error_destroy(&err)
		testing.expect_value(t, err.kind, Error_Kind.Missing_Credential)
	}
}

@(test)
test_fetch_and_search_decode_content_codings :: proc(t: ^testing.T) {
	// Precomputed stored DEFLATE blocks, wrapped with gzip CRC32/ISIZE or zlib Adler32.
	content := `{"type":"search","web":{"results":[{"title":"Decoded","url":"https://example.com/"}]}}`
	gzip_body := "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff\x01\x56\x00\xa9\xff\x7b\x22\x74\x79\x70\x65\x22\x3a\x22\x73\x65\x61\x72\x63\x68\x22\x2c\x22\x77\x65\x62\x22\x3a\x7b\x22\x72\x65\x73\x75\x6c\x74\x73\x22\x3a\x5b\x7b\x22\x74\x69\x74\x6c\x65\x22\x3a\x22\x44\x65\x63\x6f\x64\x65\x64\x22\x2c\x22\x75\x72\x6c\x22\x3a\x22\x68\x74\x74\x70\x73\x3a\x2f\x2f\x65\x78\x61\x6d\x70\x6c\x65\x2e\x63\x6f\x6d\x2f\x22\x7d\x5d\x7d\x7d\x93\xf1\x63\x92\x56\x00\x00\x00"
	deflate_body := "\x78\x01\x01\x56\x00\xa9\xff\x7b\x22\x74\x79\x70\x65\x22\x3a\x22\x73\x65\x61\x72\x63\x68\x22\x2c\x22\x77\x65\x62\x22\x3a\x7b\x22\x72\x65\x73\x75\x6c\x74\x73\x22\x3a\x5b\x7b\x22\x74\x69\x74\x6c\x65\x22\x3a\x22\x44\x65\x63\x6f\x64\x65\x64\x22\x2c\x22\x75\x72\x6c\x22\x3a\x22\x68\x74\x74\x70\x73\x3a\x2f\x2f\x65\x78\x61\x6d\x70\x6c\x65\x2e\x63\x6f\x6d\x2f\x22\x7d\x5d\x7d\x7d\xe5\x4e\x1d\x33"
	stacked_body := "\x78\x01\x01\x6d\x00\x92\xff\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff\x01\x56\x00\xa9\xff\x7b\x22\x74\x79\x70\x65\x22\x3a\x22\x73\x65\x61\x72\x63\x68\x22\x2c\x22\x77\x65\x62\x22\x3a\x7b\x22\x72\x65\x73\x75\x6c\x74\x73\x22\x3a\x5b\x7b\x22\x74\x69\x74\x6c\x65\x22\x3a\x22\x44\x65\x63\x6f\x64\x65\x64\x22\x2c\x22\x75\x72\x6c\x22\x3a\x22\x68\x74\x74\x70\x73\x3a\x2f\x2f\x65\x78\x61\x6d\x70\x6c\x65\x2e\x63\x6f\x6d\x2f\x22\x7d\x5d\x7d\x7d\x93\xf1\x63\x92\x56\x00\x00\x00\x4e\xf0\x23\xb2"
	Case :: struct {
		coding: string,
		body:   string,
		kind:   Error_Kind,
	}
	forged_size, forged_error := strings.concatenate({gzip_body[:len(gzip_body) - 4], "\xff\xff\xff\xff"}, context.temp_allocator)
	if !testing.expect_value(t, forged_error, nil) { return }
	cases := []Case {
		{"GZip", gzip_body, .None},
		{"deflate", deflate_body, .None},
		{"x-gzip, identity, DeFlAtE", stacked_body, .None},
		{"br", "compressed", .Unsupported_Content},
		{"gzip", "\x1f\x8b\x08\x00", .Invalid_Response},
		{"gzip", forged_size, .Invalid_Response},
		{"deflate", "broken", .Invalid_Response},
	}
	for entry in cases {
		headers := fmt.tprintf("content-encoding: %s\r\n", entry.coding)
		server: Server
		if !server_start(t, &server, []string{reply(200, headers, entry.body), reply(200, headers, entry.body)}) { return }
		page, fetch_err := fetch(server.url, .Text, {})
		response, search_err := search({provider = .Brave, api_key = "key", base_url = server.url}, {text = "query"}, {})
		server_stop(&server)
		defer page_destroy(&page)
		defer response_destroy(&response)
		defer error_destroy(&fetch_err)
		defer error_destroy(&search_err)
		testing.expectf(t, fetch_err.kind == entry.kind, "%s fetch: %v %s", entry.coding, fetch_err.kind, fetch_err.detail)
		testing.expectf(t, search_err.kind == entry.kind, "%s search: %v %s", entry.coding, search_err.kind, search_err.detail)
		if entry.kind == .None {
			testing.expect_value(t, page.content, content)
			if testing.expect_value(t, len(response.results), 1) {
				testing.expect_value(t, response.results[0].title, "Decoded")
				testing.expect_value(t, response.results[0].url, "https://example.com/")
			}
		} else {
			testing.expect_value(t, page.content, "")
			testing.expect_value(t, len(response.results), 0)
		}
		for i in 0 ..< 2 {
			testing.expect(t, strings.contains(received(&server, i), "accept-encoding: gzip, deflate"), received(&server, i))
		}
	}
}
always_cancelled :: proc(_: rawptr) -> client.Wait_Status {
	return .Cancelled
}

@(test)
test_search_first_falls_through_and_stops_on_cancel :: proc(t: ^testing.T) {
	server: Server
	responses := []string {
		reply(429, "retry-after: 5\r\n", ""),
		reply(
			200,
			"content-type: application/json\r\n",
			`{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"results\":[{\"title\":\"Bun\",\"url\":\"https://bun.sh\"}]}"}]}}`,
		),
	}
	if !server_start(t, &server, responses) { return }
	endpoints := []Endpoint{{provider = .Brave, api_key = "key", base_url = server.url}, {provider = .Exa_MCP, base_url = server.url}}
	response, answered_by, failures, ok, _ := search_first(endpoints, {text = "bun"}, {})
	server_stop(&server)
	defer response_destroy(&response)
	defer failures_destroy(failures)

	testing.expect(t, ok, "the second endpoint answers")
	testing.expect_value(t, answered_by, Provider.Exa_MCP)
	testing.expect_value(t, len(response.results), 1)
	if len(failures) == 1 {
		testing.expect_value(t, failures[0].provider, Provider.Brave)
		testing.expect_value(t, failures[0].error.kind, Error_Kind.Rate_Limited)
	} else {
		testing.expect_value(t, len(failures), 1)
	}

	preferred_server: Server
	if !server_start(t, &preferred_server, responses[1:]) { return }
	preferred_endpoints := []Endpoint {
		{provider = .Brave, api_key = "key", base_url = preferred_server.url},
		{provider = .Exa_MCP, base_url = preferred_server.url},
	}
	preferred_response, preferred_provider, preferred_failures, preferred_ok, preferred_error := search_first(preferred_endpoints, {text = "bun"}, {}, .Exa)
	server_stop(&preferred_server)
	defer response_destroy(&preferred_response)
	defer failures_destroy(preferred_failures)
	testing.expect_value(t, preferred_error, nil)
	testing.expect(t, preferred_ok, "preferring Exa tries its MCP endpoint before Brave")
	testing.expect_value(t, preferred_provider, Provider.Exa_MCP)
	testing.expect_value(t, len(preferred_failures), 0)
	testing.expect(t, strings.contains(received(&preferred_server, 0), "post "), "the first request was to the MCP endpoint")

	// A cancelled search ends the list without trying the rest.
	cancelled := client.Options {
		probe = {check = always_cancelled},
	}
	_, _, cancelled_failures, cancelled_ok, _ := search_first(endpoints, {text = "bun"}, cancelled)
	defer failures_destroy(cancelled_failures)
	testing.expect(t, !cancelled_ok, "a cancelled search has no answer")
	testing.expect_value(t, len(cancelled_failures), 1)
	if len(cancelled_failures) == 1 { testing.expect_value(t, cancelled_failures[0].error.kind, Error_Kind.Cancelled) }
}
