#+test
package agent

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

import "nabla:agent/journal"

// web_fetch_test_document writes an argument document; fmt reads a brace as an argument index, so it is concatenated.
web_fetch_test_document :: proc(url: string, rest := "") -> string {
	return strings.concatenate({`{"url":`, fmt.tprintf("%q", url), rest, "}"}, context.temp_allocator)
}

// web_fetch_test_call runs web_fetch on an argument document and returns the result and the
// repairs the call needed. The caller destroys the result.
web_fetch_test_call :: proc(t: ^testing.T, document: string, timeout := TOOL_WEB_FETCH_DEFAULT_TIMEOUT) -> (result: Tool_Result, repairs: Tool_Repairs) {
	arguments, parse_error := json.parse_string(document)
	if !testing.expect_value(t, parse_error, nil) { return }
	defer json.destroy_value(arguments)
	ctx := Tool_Context {
		call_id   = "fetch_1",
		allocator = context.allocator,
		timeout   = timeout,
	}
	result = tool_test_execute(&ctx, TOOL_WEB_FETCH_DEFINITION, arguments.(json.Object))
	return result, ctx.repairs
}

@(test)
test_web_fetch_reads_a_page_and_follows_a_redirect :: proc(t: ^testing.T) {
	body := `<html><head><title>Release notes</title><meta name="description" content="What changed this week"></head><body><main><h1>New release</h1><p>Read the <a href="/guide">guide</a>.</p></main></body></html>`
	empty_body := `<html><head><title>Members</title></head><body><main></main><script>loadContent()</script></body></html>`
	page := fmt.tprintf("HTTP/1.1 200 OK\r\ncontent-type: text/html; charset=utf-8\r\ncontent-length: %d\r\n\r\n%s", len(body), body)
	empty := fmt.tprintf("HTTP/1.1 200 OK\r\ncontent-type: text/html; charset=utf-8\r\ncontent-length: %d\r\n\r\n%s", len(empty_body), empty_body)
	provider: Agent_Provider
	if !agent_provider_start(t, &provider, {agent_provider_refusal("302 Found", "", "location: /page\r\n"), page, page, empty, empty}) { return }
	defer agent_provider_stop(&provider)
	url := agent_provider_endpoint(&provider)
	defer delete(url)

	redirected, _ := web_fetch_test_call(t, web_fetch_test_document(url))
	defer tool_result_destroy(&redirected)
	testing.expect_value(t, redirected.outcome, journal.Tool_Outcome.Success)
	testing.expect(t, strings.has_prefix(redirected.content, "ok\nurl: "), redirected.content)
	testing.expect(
		t,
		strings.contains(redirected.content, "/page\ntitle: Release notes\ndescription: What changed this week\ncontent_type: text/html"),
		redirected.content,
	)
	testing.expect(t, strings.contains(redirected.content, "# New release") && strings.contains(redirected.content, "[guide]("), redirected.content)
	output, is_fetch := redirected.output.(Web_Fetch_Output)
	testing.expect(t, is_fetch && strings.has_suffix(output.url, "/page") && output.redirected, "Code Mode keeps the final URL")

	direct, _ := web_fetch_test_call(t, web_fetch_test_document(url, `,"format":null`))
	defer tool_result_destroy(&direct)
	testing.expect(t, strings.has_prefix(direct.content, "ok\ntitle: "), "an unchanged URL is not repeated")

	for format in ([?]string{"markdown", "html"}) {
		shell, _ := web_fetch_test_call(t, web_fetch_test_document(url, fmt.tprintf(`,"format":%q`, format)))
		defer tool_result_destroy(&shell)
		if format == "html" {
			testing.expect(t, shell.outcome == .Success && strings.contains(shell.content, empty_body), shell.content)
		} else {
			testing.expect_value(t, shell.outcome, journal.Tool_Outcome.Tool_Failed)
			testing.expect(t, strings.contains(shell.content, "has no readable text") && strings.contains(shell.content, `format "html"`), shell.content)
		}
	}
}

@(test)
test_web_fetch_failures_say_what_to_do_next :: proc(t: ^testing.T) {
	provider := Agent_Provider {
		hold_body = 3,
	}
	if !agent_provider_start(
		t,
		&provider,
		{agent_provider_refusal("404 Not Found", "{}"), agent_provider_refusal("403 Forbidden", "{}"), agent_provider_refusal("403 Forbidden", "{}")},
	) { return }
	defer agent_provider_stop(&provider)
	url := agent_provider_endpoint(&provider)
	defer delete(url)

	missing, _ := web_fetch_test_call(t, web_fetch_test_document(url))
	defer tool_result_destroy(&missing)
	testing.expect_value(t, missing.outcome, journal.Tool_Outcome.Tool_Failed)
	testing.expect(
		t,
		strings.contains(missing.content, "web_fetch failed: not found (HTTP 404)") && strings.contains(missing.content, "search for its current address"),
		missing.content,
	)

	denied, _ := web_fetch_test_call(t, web_fetch_test_document(url))
	defer tool_result_destroy(&denied)
	testing.expect(t, strings.contains(denied.content, "web_fetch failed: access denied (HTTP 403)"), denied.content)

	timed_out, _ := web_fetch_test_call(t, web_fetch_test_document(url, `,"timeout_ms":100`))
	defer tool_result_destroy(&timed_out)
	testing.expect_value(t, timed_out.outcome, journal.Tool_Outcome.Timed_Out)
	testing.expect(
		t,
		strings.contains(timed_out.content, "web_fetch failed: timed out") && strings.contains(timed_out.content, "raise timeout_ms"),
		timed_out.content,
	)
}

@(test)
test_web_fetch_repairs_a_url_and_refuses_what_it_cannot_read :: proc(t: ^testing.T) {
	body := `<html><body><main><p>hello</p></main></body></html>`
	page := fmt.tprintf("HTTP/1.1 200 OK\r\ncontent-type: text/html\r\ncontent-length: %d\r\n\r\n%s", len(body), body)
	provider: Agent_Provider
	if !agent_provider_start(t, &provider, {page}) { return }
	defer agent_provider_stop(&provider)
	url := agent_provider_endpoint(&provider)
	defer delete(url)

	// The fixture speaks plain HTTP, so a bare address is repaired to https and fails at the transport; the repair is still reported.
	bare := strings.trim_prefix(url, "http://")
	repaired, repairs := web_fetch_test_call(t, web_fetch_test_document(strings.concatenate({"  ", bare, " "}, context.temp_allocator)), 300_000_000)
	defer tool_result_destroy(&repaired)
	testing.expect_value(t, repairs, Tool_Repairs{.Url_Scheme_Added, .Text_Trimmed})

	for accepted in ([?]struct {
			input, expected: string,
			repairs:         Tool_Repairs,
		}{{"example.com:8080", "https://example.com:8080", {.Url_Scheme_Added}}, {"localhost:3000/x", "https://localhost:3000/x", {.Url_Scheme_Added}}, {"[::1]:8080/x", "https://[::1]:8080/x", {.Url_Scheme_Added}}, {"[::1]/x", "https://[::1]/x", {.Url_Scheme_Added}}, {"//example.com:65535/x?y#z", "https://example.com:65535/x?y#z", {.Url_Scheme_Added}}, {"example.com/path?link=http://other", "https://example.com/path?link=http://other", {.Url_Scheme_Added}}, {"https://example.com:1/x", "https://example.com:1/x", {}}, {"HTTP://[::1]:8080/x", "HTTP://[::1]:8080/x", {}}}) {
		document, parse_error := json.parse_string(web_fetch_test_document(accepted.input))
		if !testing.expect_value(t, parse_error, nil) { return }
		defer json.destroy_value(document)
		ctx := Tool_Context {
			allocator = context.allocator,
			timeout   = TOOL_WEB_FETCH_DEFAULT_TIMEOUT,
		}
		args, argument_error := tool_args_decode(&ctx, TOOL_WEB_FETCH_DEFINITION, document.(json.Object))
		defer tool_args_destroy(&args)
		defer tool_argument_error_destroy(&argument_error)
		if !testing.expect_value(t, argument_error, nil) { continue }
		testing.expect_value(t, args.(Web_Fetch_Args).url, accepted.expected)
		testing.expect_value(t, ctx.repairs, accepted.repairs)
		testing.expect_value(t, string(document.(json.Object)["url"].(json.String)), accepted.expected)
	}

	for invalid in ([?]string{`""`, `"ftp://example.com/file"`, `"https:///page"`, `"https://user:pass@example.com/"`, `"https://example.com/a b"`, `"https://example.com/\u0001"`, `"mailto:x"`, `"data:text/plain,x"`, `"http:example.com"`, `"foo.bar://host"`, `"example.com:0"`, `"localhost:65536/x"`, `"[::1]:0/x"`, `"[invalid]:8080/x"`, `"https://example.com:abc/x"`, `"//[::1"`}) {
		refused, refused_repairs := web_fetch_test_call(t, strings.concatenate({`{"url":`, invalid, `}`}, context.temp_allocator))
		defer tool_result_destroy(&refused)
		failure, is_failure := refused.output.(Argument_Failure)
		testing.expectf(t, is_failure && failure.field == "url" && refused_repairs == {}, "%s: %s", invalid, refused.content)
		if invalid == `"mailto:x"` || invalid == `"data:text/plain,x"` || invalid == `"http:example.com"` || invalid == `"foo.bar://host"` {
			testing.expect(t, strings.contains(failure.expected, "scheme"), refused.content)
		}

	}
	format, _ := web_fetch_test_call(t, `{"url":"https://example.com","format":"pdf"}`)
	defer tool_result_destroy(&format)
	failure, is_failure := format.output.(Argument_Failure)
	testing.expect(t, is_failure && failure.field == "format", format.content)
}
