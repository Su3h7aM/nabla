package web

import "base:runtime"
import "core:strings"

import "nabla:html"
import "nabla:http/client"

// The URL is the one every DuckDuckGo client uses for the no-JavaScript results page.
@(private)
DUCKDUCKGO_URL :: "https://html.duckduckgo.com/html/"

// Result links point at this host. Its /l/ path is the redirect whose uddg
// parameter holds the real URL, and its /y.js path is the sponsored-result tracker.
@(private)
DUCKDUCKGO_HOST :: "duckduckgo.com"

// DUCKDUCKGO_CHALLENGE_FORM is the id of the form on the bot challenge page.
@(private)
DUCKDUCKGO_CHALLENGE_FORM :: "challenge-form"

// Page accumulates the results of one decode pass.
@(private)
Duckduckgo_Page :: struct {
	results:   [dynamic]Result,
	current:   Result,
	open:      bool, // a result element has started
	ad:        bool, // the open result is sponsored
	container: bool, // the page has a results list, even an empty one
	challenge: bool, // the page is the bot challenge
}

@(private)
@(require_results)
duckduckgo_request :: proc(endpoint: Endpoint, query: Query) -> (request: client.Request, clamped_to: int, err: Error) {
	freshness: string
	switch query.freshness {
	case .Any:
	case .Day:
		freshness = "d"
	case .Week:
		freshness = "w"
	case .Month:
		freshness = "m"
	case .Year:
		freshness = "y"
	}
	text: string
	if text, err = query_text(query); err.kind != .None { return }
	form, form_err := strings.builder_make(context.temp_allocator)
	if form_err != nil { return {}, 0, OUT_OF_MEMORY }
	ok := write(&form, "q=") && percent_write(&form, text)
	if freshness != "" { ok &&= write(&form, "&df=", freshness) }
	if !ok { return {}, 0, OUT_OF_MEMORY }
	request.url = endpoint.base_url if endpoint.base_url != "" else DUCKDUCKGO_URL
	request.method = .Post
	request.body = form.buf[:]
	request.headers, err = headers_make(
		{"User-Agent", BROWSER_USER_AGENT},
		{"Accept", "text/html"},
		{"Accept-Language", "en-US,en;q=0.9"},
		{"Referer", DUCKDUCKGO_URL},
		{"Content-Type", "application/x-www-form-urlencoded"},
	)
	return
}

// duckduckgo_decode reads the results page. The bot challenge page, which
// DuckDuckGo serves in place of results when it suspects automation, is
// Challenged: a later retry or another provider can succeed. A page with an
// empty list is a search without results, and a page with neither is
// Invalid_Response.
@(private)
@(require_results)
duckduckgo_decode :: proc(body: []u8) -> (response: Response, err: Error) {
	page: Duckduckgo_Page
	page.results.allocator = context.temp_allocator
	tokenizer: html.Tokenizer
	html.init(&tokenizer, string(body))
	for token in html.next(&tokenizer) {
		if token.kind != .Start_Tag { continue }
		switch {
		case duckduckgo_id_is(token, DUCKDUCKGO_CHALLENGE_FORM), duckduckgo_class_has(token, "anomaly-modal__title"):
			page.challenge = true
		case duckduckgo_class_has(token, "results"), duckduckgo_class_has(token, "no-results"):
			page.container = true
		case duckduckgo_class_has(token, "result"):
			if duckduckgo_flush(&page) != nil { return {}, OUT_OF_MEMORY }
			page.open = true
			page.ad = duckduckgo_class_has(token, "result--ad")
		case duckduckgo_class_has(token, "result__a") && page.open:
			href, _ := html.attribute(token, "href")
			text_err: runtime.Allocator_Error
			page.current.url, text_err = duckduckgo_link(href)
			if text_err != nil { return {}, OUT_OF_MEMORY }
			page.current.title, text_err = duckduckgo_text(&tokenizer, token)
			if text_err != nil { return {}, OUT_OF_MEMORY }
		case duckduckgo_class_has(token, "result__snippet") && page.open:
			text_err: runtime.Allocator_Error
			page.current.snippet, text_err = duckduckgo_text(&tokenizer, token)
			if text_err != nil { return {}, OUT_OF_MEMORY }
		}
	}
	if duckduckgo_flush(&page) != nil { return {}, OUT_OF_MEMORY }
	if !page.container {
		if page.challenge {
			return {}, {kind = .Challenged, detail = "duckduckgo: the page is a bot challenge; retry later or use another provider"}
		}
		return {}, {kind = .Invalid_Response, detail = "duckduckgo: the page has neither results nor a challenge"}
	}
	response.results = page.results[:]
	return
}

// duckduckgo_flush ends the open result, keeping it when it is an organic result with a URL.
@(private)
@(require_results)
duckduckgo_flush :: proc(page: ^Duckduckgo_Page) -> runtime.Allocator_Error {
	result := page.current
	keep := page.open && !page.ad && result.url != ""
	page.current = {}
	page.open = false
	page.ad = false
	if keep {
		_, append_err := append(&page.results, result)
		return append_err
	}
	return nil
}

// duckduckgo_link returns the real URL of a result link, or "" for a link that is
// an ad or does not lead to a web page. Only links to DuckDuckGo's own host are
// interpreted; every other http or https URL is returned as written.
@(private)
@(require_results)
duckduckgo_link :: proc(href: string) -> (link: string, err: runtime.Allocator_Error) {
	builder := strings.builder_make(context.temp_allocator) or_return
	if !entities_write(&builder, href) { return "", .Out_Of_Memory }
	decoded := strings.to_string(builder)

	rest: string
	scheme_relative := false
	switch {
	case strings.has_prefix(decoded, "https://"):
		rest = decoded[len("https://"):]
	case strings.has_prefix(decoded, "http://"):
		rest = decoded[len("http://"):]
	case strings.has_prefix(decoded, "//"):
		rest = decoded[len("//"):]
		scheme_relative = true
	case:
		return "", nil
	}
	host_end := strings.index_any(rest, "/?#")
	if host_end < 0 { host_end = len(rest) }
	if !strings.equal_fold(rest[:host_end], DUCKDUCKGO_HOST) {
		if scheme_relative { return "", nil }
		return decoded, nil
	}

	target, _, _ := strings.partition(rest[host_end:], "#")
	path, _, query := strings.partition(target, "?")
	switch path {
	case "/y.js":
		return "", nil
	case "/l/", "/l":
		for parameter in strings.split_iterator(&query, "&") {
			if !strings.has_prefix(parameter, "uddg=") { continue }
			target_builder := strings.builder_make(context.temp_allocator) or_return
			if !percent_decode_write(&target_builder, parameter[len("uddg="):]) { return "", .Out_Of_Memory }
			real := strings.to_string(target_builder)
			if !strings.has_prefix(real, "http://") && !strings.has_prefix(real, "https://") { return "", nil }
			return real, nil
		}
		return "", nil
	}
	if scheme_relative { return "", nil }
	return decoded, nil
}

// duckduckgo_id_is reports whether a start tag has the given id.
@(private)
duckduckgo_id_is :: proc(token: html.Token, name: string) -> bool {
	id, _ := html.attribute(token, "id")
	return id == name
}

// duckduckgo_class_has reports whether a start tag's class attribute lists name.
@(private)
@(require_results)
duckduckgo_class_has :: proc(token: html.Token, name: string) -> bool {
	classes, _ := html.attribute(token, "class")
	for class in strings.fields_iterator(&classes) {
		if class == name { return true }
	}
	return false
}

// duckduckgo_text consumes tokens up to the end tag that closes start and returns
// the decoded text between them with nested tags dropped and white space collapsed.
@(private)
@(require_results)
duckduckgo_text :: proc(tokenizer: ^html.Tokenizer, start: html.Token) -> (text: string, err: runtime.Allocator_Error) {
	if start.self_closing { return "", nil }
	builder := strings.builder_make(context.temp_allocator) or_return
	depth := 1
	for token in html.next(tokenizer) {
		switch token.kind {
		case .Start_Tag:
			if html.name_equal(token.text, start.text) && !token.self_closing { depth += 1 }
		case .End_Tag:
			if html.name_equal(token.text, start.text) { depth -= 1 }
		case .Text:
			if !entities_write(&builder, token.text) { return "", .Out_Of_Memory }
		case .Comment, .Doctype:
		}
		if depth == 0 { break }
	}
	words := strings.fields(strings.to_string(builder), context.temp_allocator) or_return
	return strings.join(words, " ", context.temp_allocator)
}
