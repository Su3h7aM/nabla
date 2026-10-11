#+test
package web

import "core:strings"
import "core:testing"

RESULTS_PAGE :: #load("testdata/duckduckgo.html", string)

CHALLENGE_PAGE :: `<html><body><form id="challenge-form" action="//duckduckgo.com/anomaly.js?sv=html">
<div class="anomaly-modal__title">Unfortunately, bots use DuckDuckGo too.</div></form></body></html>`

HTML_HEADERS :: "content-type: text/html\r\n"

EMPTY_PAGE :: `<html><body><div class="serp__results"><div id="links" class="results"><div class="no-results">No results.</div></div></div></body></html>`

@(test)
test_duckduckgo_search_reads_results_and_skips_ads :: proc(t: ^testing.T) {
	server: Server
	if !server_start(t, &server, []string{reply(200, HTML_HEADERS, RESULTS_PAGE), reply(200, HTML_HEADERS, RESULTS_PAGE)}) { return }
	query := Query {
		text            = "odin language",
		freshness       = .Week,
		include_domains = {"odin-lang.org"},
	}
	response, err := search({provider = .DuckDuckGo, base_url = server.url}, query, {})
	defer response_destroy(&response)
	defer error_destroy(&err)
	truncated, truncated_err := search({provider = .DuckDuckGo, base_url = server.url}, {text = "odin", count = 2}, {})
	server_stop(&server)
	defer response_destroy(&truncated)
	defer error_destroy(&truncated_err)
	testing.expect_value(t, truncated_err.kind, Error_Kind.None)
	testing.expect_value(t, len(truncated.results), 2)

	request := received(&server, 0)
	testing.expect(t, strings.has_prefix(request, "post / "), "the request is a POST")
	testing.expect(t, strings.contains(request, "user-agent: mozilla/5.0"), "the request has a browser user agent")
	testing.expect(t, strings.contains(request, "q=odin%20language%20site%3aodin-lang.org&df=w"), request)

	testing.expect_value(t, err.kind, Error_Kind.None)
	if !testing.expect_value(t, len(response.results), 3) { return }
	testing.expect_value(
		t,
		response.results[0],
		Result {
			title = "Odin Programming Language",
			url = "https://odin-lang.org/",
			snippet = "Odin is a general-purpose programming language with distinct typing built for high performance, modern systems and data-oriented programming. Odin is the C alternative for the Joy of Programming.",
		},
	)
	// The redirect is unwrapped and percent-decoded, and entities in the text are decoded.
	testing.expect_value(t, response.results[1].url, "https://odin-lang.org/docs/?a=1&b=2")
	testing.expect_value(t, response.results[1].title, "Documentation | Odin & Friends")
	testing.expect(t, strings.contains(response.results[1].snippet, "You'll learn"), response.results[1].snippet)
	// A URL that merely mentions the tracker is an ordinary URL.
	testing.expect_value(t, response.results[2].url, "https://github.com/odin-lang/Odin?via=duckduckgo.com/y.js")
}

@(test)
test_duckduckgo_search_tells_challenge_from_no_results_from_garbage :: proc(t: ^testing.T) {
	Case :: struct {
		status: int,
		body:   string,
		kind:   Error_Kind,
	}
	cases := []Case{{202, CHALLENGE_PAGE, .Rate_Limited}, {200, EMPTY_PAGE, .None}, {200, "<html><body>hello</body></html>", .Invalid_Response}}
	for test_case in cases {
		server: Server
		if !server_start(t, &server, []string{reply(test_case.status, HTML_HEADERS, test_case.body)}) { return }
		response, err := search({provider = .DuckDuckGo, base_url = server.url}, {text = "odin"}, {})
		server_stop(&server)
		defer response_destroy(&response)
		defer error_destroy(&err)

		testing.expect_value(t, err.kind, test_case.kind)
		testing.expect_value(t, len(response.results), 0)
	}
}
