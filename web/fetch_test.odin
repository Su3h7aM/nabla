#+test
package web

import "core:strings"
import "core:testing"

@(test)
test_fetch_keeps_empty_encoded_responses :: proc(t: ^testing.T) {
	for status in ([]int{200, 204}) {
		server: Server
		if !server_start(t, &server, []string{reply(status, "content-encoding: gzip\r\n", "")}) { return }
		page, err := fetch(server.url, .Text, {})
		server_stop(&server)
		defer page_destroy(&page)
		defer error_destroy(&err)
		testing.expect_value(t, err.kind, Error_Kind.None)
		testing.expect_value(t, page.content, "")
	}
}

@(test)
test_fetch_redirects_to_plain_text :: proc(t: ^testing.T) {
	server: Server
	responses := []string {
		reply(302, "location: ../next\r\n", ""),
		reply(307, "location: final?ok=1\r\n", ""),
		reply(200, "content-type: text/plain; charset=utf-8\r\n", "plain text\nwithout markup\n"),
	}
	if !server_start(t, &server, responses) { return }
	initial, initial_err := strings.concatenate({server.url, "/start/page"}, context.temp_allocator)
	if !testing.expect_value(t, initial_err, nil) { return }
	page, err := fetch(initial, .Markdown, {})
	server_stop(&server)
	defer page_destroy(&page)
	defer error_destroy(&err)
	testing.expect_value(t, err.kind, Error_Kind.None)
	final_url, final_err := strings.concatenate({server.url, "/final?ok=1"}, context.temp_allocator)
	testing.expect_value(t, final_err, nil)
	testing.expect_value(t, page.url, final_url)
	testing.expect_value(t, page.content_type, "text/plain; charset=utf-8")
	testing.expect_value(t, page.content, "plain text\nwithout markup\n")
	testing.expect_value(t, page.title, "")
	for i in 0 ..< len(responses) {
		request := received(&server, i)
		testing.expect(t, strings.has_prefix(request, "get "), request)
		testing.expect(t, strings.contains(request, "user-agent: mozilla/5.0"), request)
		testing.expect(t, strings.contains(request, "accept: text/markdown, text/html;q=0.9, text/plain;q=0.8, */*;q=0.1"), request)
	}
	testing.expect(t, strings.has_prefix(received(&server, 1), "get /next "), received(&server, 1))
	testing.expect(t, strings.has_prefix(received(&server, 2), "get /final?ok=1 "), received(&server, 2))
}

@(test)
test_fetch_distinguishes_absent_and_empty_location :: proc(t: ^testing.T) {
	for location_present in ([]bool{false, true}) {
		server: Server
		responses := []string{reply(302, "", "refused"), reply(200, "content-type: text/plain\r\n", "retried")}
		if location_present {
			responses[0] = reply(302, "location: \r\n", "")
		} else {
			responses = responses[:1]
		}
		if !server_start(t, &server, responses) { return }
		page, err := fetch(server.url, .Text, {})
		server_stop(&server)
		defer page_destroy(&page)
		defer error_destroy(&err)
		if location_present {
			testing.expect_value(t, err.kind, Error_Kind.None)
			testing.expect_value(t, page.url, server.url)
			testing.expect_value(t, page.content, "retried")
			testing.expect_value(t, received(&server, 1), received(&server, 0))
		} else {
			testing.expect_value(t, err.kind, Error_Kind.Rejected)
			testing.expect_value(t, err.status, 302)
		}
	}
}

@(test)
test_fetch_keeps_description_and_empty_converted_content :: proc(t: ^testing.T) {
	source := `<html><head><title>Doc</title><meta property="og:description" content="fallback"><meta name="description" content=" A &amp; B.&#10; Summary "></head><body><main hidden>navigation only</main></body></html>`
	for format in ([]Format{.Markdown, .Text, .HTML}) {
		server: Server
		if !server_start(t, &server, []string{reply(200, "content-type: text/html\r\n", source)}) { return }
		page, err := fetch(server.url, format, {})
		server_stop(&server)
		defer page_destroy(&page)
		defer error_destroy(&err)
		testing.expect_value(t, err.kind, Error_Kind.None)
		testing.expect_value(t, page.title, "Doc")
		testing.expect_value(t, page.description, "A & B. Summary")
		testing.expect_value(t, page.content, source if format == .HTML else "")
	}
}

@(test)
test_fetch_rejects_binary_and_decodes_charsets :: proc(t: ^testing.T) {
	Fetch_Case :: struct {
		content_type: string,
		body:         string,
		format:       Format,
		kind:         Error_Kind,
		content:      string,
		title:        string,
		detail_has:   string,
	}
	cases := []Fetch_Case {
		{"image/png", "\x89PNG\r\n", .Markdown, .Unsupported_Content, "", "", "image/png"},
		{
			"text/html; charset=windows-1252",
			"<html><head><title>Caf\xe9</title></head><body><p>\x93Caf\xe9\x94 costs \x80 5.</p></body></html>",
			.Markdown,
			.None,
			"“Café” costs € 5.",
			"Café",
			"",
		},
		{"text/html", "<head><meta charset=windows-1252><title>\x80</title></head><body><p>\x80</p></body>", .Text, .None, "€", "€", ""},
		{"text/plain; charset=ISO-8859-1", "Caf\xe9", .HTML, .None, "Café", "", ""},
		{"application/json", "{\"word\":\"\xff\"}", .Markdown, .None, "{\"word\":\"�\"}", "", ""},
		{"text/plain; charset=koi8-r", "body", .Text, .Unsupported_Content, "", "", "koi8-r"},
		{"image/png\x01", "body", .Markdown, .Unsupported_Content, "", "", "invalid media type"},
		{"", "\n<!DOCTYPE HTML><title>Sniffed</title><p>x</p>", .HTML, .None, "\n<!DOCTYPE HTML><title>Sniffed</title><p>x</p>", "Sniffed", ""},
		{"", "plain words", .Text, .None, "plain words", "", ""},
		{"", "\x89PNG\r\n\x1a\n", .Text, .Unsupported_Content, "", "", "binary"},
		{"text/plain", "a\x00b", .Text, .Unsupported_Content, "", "", "binary"},
		{"text/plain", "GIF89a is the GIF file signature", .Text, .None, "GIF89a is the GIF file signature", "", ""},
		{"text/plain", "GIF89a\x01\x00\x01\x00", .Text, .Unsupported_Content, "", "", "binary"},
		{"", "GIF89a\x01\x00\x01\x00", .Text, .Unsupported_Content, "", "", "binary"},
		{"", "\xef\xbb\xbf<html><head><title>BOM</title></head><body><p>Converted</p></body></html>", .Text, .None, "Converted", "BOM", ""},
		{"text/plain; charset=latin1", "Caf\xe9", .Text, .None, "Café", "", ""},
		{"text/plain; charset=iso88591", "\x80", .Text, .None, "€", "", ""},
		{"text/plain; charset=iso_8859-1:1987", "\x80", .Text, .None, "€", "", ""},
		{"text/plain; charset=cp819", "Caf\xe9", .Text, .None, "Café", "", ""},
		{"text/plain; charset=csisolatin1", "\x80", .Text, .None, "€", "", ""},
		{"text/plain; charset=x-unicode20utf8", "Café", .Text, .None, "Café", "", ""},
		{"text/plain; charset=utf8", "\xef\xbb\xbfCaf\xc3\xa9", .Text, .None, "Café", "", ""},
		{"text/plain; charset=utf-8", "\xff\xfeh\x00", .Text, .Unsupported_Content, "", "", "utf-16"},
		{
			"text/html; charset=utf-8",
			"<head><title>Raw &amp; title</title></head><body><p>raw</p></body>",
			.HTML,
			.None,
			"<head><title>Raw &amp; title</title></head><body><p>raw</p></body>",
			"Raw & title",
			"",
		},
	}
	for entry in cases {
		server: Server
		headers, headers_err := strings.concatenate({"content-type: ", entry.content_type, "\r\n"}, context.temp_allocator)
		if !testing.expect_value(t, headers_err, nil) { return }
		responses := []string{reply(200, headers, entry.body)}
		if !server_start(t, &server, responses) { return }
		page, err := fetch(server.url, entry.format, {})
		server_stop(&server)
		defer page_destroy(&page)
		defer error_destroy(&err)
		testing.expectf(t, err.kind == entry.kind, "%s: %v, %s", entry.content_type, err.kind, err.detail)
		testing.expect_value(t, page.content, entry.content)
		testing.expect_value(t, page.title, entry.title)
		if entry.detail_has != "" { testing.expect(t, strings.contains(err.detail, entry.detail_has), err.detail) }
		if entry.format == .HTML {
			testing.expect(t, strings.contains(received(&server, 0), "accept: text/html"), received(&server, 0))
		}
	}
}
