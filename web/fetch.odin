package web

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"

import "nabla:html"
import "nabla:http"
import "nabla:http/client"

Format :: enum {
	Markdown,
	Text,
	HTML,
}

// Page holds the final response URL, its Content-Type header, title, description,
// and content. description is the page's own summary, or empty when absent.
// All strings are owned by the allocator passed to fetch.
Page :: struct {
	url:          string,
	content_type: string,
	title:        string,
	description:  string,
	content:      string,
}

// page_destroy releases a Page returned by fetch with the same allocator.
page_destroy :: proc(page: ^Page, allocator := context.allocator) {
	delete(page.url, allocator)
	delete(page.content_type, allocator)
	delete(page.title, allocator)
	delete(page.description, allocator)
	delete(page.content, allocator)
	page^ = {}
}

// fetch retrieves an HTTP or HTTPS page, following at most twenty redirects as
// specified by WHATWG Fetch. HTML becomes Markdown or Text unless format is HTML;
// other textual media are retained. Unsupported media or charsets return
// Unsupported_Content. The caller owns Page and Error.detail with allocator and
// releases them with page_destroy and error_destroy. options carries the caller's
// cancellation probe and deadline; fetch replaces its response_head observer.
@(require_results)
fetch :: proc(url: string, format: Format, options: client.Options, allocator := context.allocator) -> (page: Page, err: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	borrowed, html_source, failure := fetch_scratch(url, format, options)
	if failure.kind != .None {
		detail, clone_err := strings.clone(failure.detail, allocator)
		if clone_err != nil { return {}, OUT_OF_MEMORY }
		failure.detail = detail
		return {}, failure
	}
	cloned, clone_err := page_clone(borrowed, html_source, allocator)
	if clone_err != nil { return {}, OUT_OF_MEMORY }
	return cloned, {}
}

@(private)
@(require_results)
page_clone :: proc(source: Page, html_source: string, allocator: runtime.Allocator) -> (page: Page, err: runtime.Allocator_Error) {
	defer if err != nil { page_destroy(&page, allocator) }
	page.url = strings.clone(source.url, allocator) or_return
	page.content_type = strings.clone(source.content_type, allocator) or_return
	page.title = strings.clone(source.title, allocator) or_return
	page.content = strings.clone(source.content, allocator) or_return
	page.description = html_description(html_source, allocator) or_return
	return page, nil
}

// The WHATWG Fetch HTTP-redirect fetch algorithm rejects a twenty-first redirect.
@(private)
FETCH_REDIRECT_LIMIT :: 20

@(private)
@(require_results)
fetch_scratch :: proc(url: string, format: Format, options: client.Options) -> (page: Page, html_source: string, err: Error) {
	current := url
	accept: string
	switch format {
	case .Markdown:
		accept = "text/markdown, text/html;q=0.9, text/plain;q=0.8, */*;q=0.1"
	case .Text:
		accept = "text/plain, text/html;q=0.9, text/markdown;q=0.8, */*;q=0.1"
	case .HTML:
		accept = "text/html, application/xhtml+xml;q=0.9, */*;q=0.1"
	}
	headers, headers_err := headers_make({"User-Agent", BROWSER_USER_AGENT}, {"Accept", accept}, {"Accept-Language", "en-US,en;q=0.9"})
	if headers_err.kind != .None { return {}, "", headers_err }
	for redirects := 0;; redirects += 1 {
		parsed := http.url_parse(current)
		if (!strings.equal_fold(parsed.scheme, "http") && !strings.equal_fold(parsed.scheme, "https")) || parsed.host == "" {
			return {}, "", {kind = .Rejected, detail = "fetch requires an absolute http or https URL"}
		}
		metadata: Exchange
		body, failure := exchange({url = current, method = .Get, headers = headers}, options, &metadata, true)
		if location, present := metadata.location.?; failure.kind == .None && redirect_status(metadata.status) && present {
			if redirects == FETCH_REDIRECT_LIMIT {
				return {}, "", {kind = .Rejected, status = metadata.status, detail = "fetch exceeded the WHATWG Fetch limit of 20 redirects"}
			}
			resolved, resolve_err := http.url_resolve(current, strings.trim_space(location), context.temp_allocator)
			if resolve_err != nil { return {}, "", OUT_OF_MEMORY }
			current = resolved
			continue
		}
		if failure.kind != .None { return {}, "", failure }
		source := string(body)
		// A byte order mark wins over the Content-Type charset and is not part of the HTML signature.
		charset := content_type_charset(metadata.content_type)
		if bom, bom_size := byte_order_mark(source); bom != "" {
			if bom == "utf-16" { return {}, "", charset_unsupported(bom) }
			charset = bom
			source = source[bom_size:]
		}
		media_type, _, _ := strings.partition(metadata.content_type, ";")
		media_type = strings.trim_space(media_type)
		if metadata.content_type == "" {
			media_type = media_type_sniff(source)
			if media_type == "" {
				return {}, "", {kind = .Unsupported_Content, detail = "fetch received binary content without a media type"}
			}
		} else if !media_type_valid(media_type) {
			return {}, "", {kind = .Unsupported_Content, detail = "fetch received a missing or invalid media type"}
		}
		is_html := strings.equal_fold(media_type, "text/html") || strings.equal_fold(media_type, "application/xhtml+xml")
		if !is_html && !textual_media_type(media_type) {
			detail, detail_err := strings.concatenate({"unsupported media type: ", media_type}, context.temp_allocator)
			if detail_err != nil { return {}, "", OUT_OF_MEMORY }
			return {}, "", {kind = .Unsupported_Content, detail = detail}
		}
		if binary_content(source) {
			return {}, "", {kind = .Unsupported_Content, detail = "the body is binary although the media type is textual"}
		}
		if charset == "" && is_html { charset = html_charset(source) }
		decoded, decode_err := charset_decode(source, charset)
		if decode_err.kind != .None { return {}, "", decode_err }
		page.url = current
		page.content_type = metadata.content_type
		page.content = decoded
		if is_html {
			conversion_err: runtime.Allocator_Error
			if format == .HTML {
				page.title, conversion_err = html_title(decoded, context.temp_allocator)
			} else {
				page.title, page.content, conversion_err = html_to_markdown(decoded, current, format == .Text, context.temp_allocator)
			}
			if conversion_err != nil { return {}, "", OUT_OF_MEMORY }
		}
		return page, decoded if is_html else "", {}
	}
}

@(private)
redirect_status :: proc(status: int) -> bool {
	return status == 301 || status == 302 || status == 303 || status == 307 || status == 308
}

// SNIFF_HTML_TAGS are the WHATWG MIME Sniffing HTML signatures. Each matches
// case-insensitively when a space or ">" follows.
@(private)
SNIFF_HTML_TAGS :: [?]string {
	"<!doctype html",
	"<html",
	"<head",
	"<script",
	"<iframe",
	"<h1",
	"<div",
	"<font",
	"<table",
	"<a",
	"<style",
	"<title",
	"<b",
	"<body",
	"<br",
	"<p",
	"<!--",
}

// BINARY_SIGNATURES are file magic numbers of common binary formats whose first
// bytes would otherwise pass the control byte test.
@(private)
BINARY_SIGNATURES :: [?]string{"%PDF-", "GIF87a", "GIF89a", "PK\x03\x04", "\x1f\x8b\x08", "\x89PNG\r\n\x1a\n", "\xff\xd8\xff"}

// binary_content reports whether the start of body has a control byte that text never holds (WHATWG MIME
// Sniffing "binary data byte") within the first 1024 bytes.
@(private)
binary_content :: proc(body: string) -> bool {
	for character in transmute([]u8)body[:min(len(body), 1024)] {
		switch character {
		case 0x00 ..= 0x08, 0x0b, 0x0e ..= 0x1a, 0x1c ..= 0x1f:
			return true
		}
	}
	return false
}

// media_type_sniff returns the media type of a response that sent no
// Content-Type: text/html for an HTML signature, text/xml for an XML
// declaration, text/plain for other text, and "" for binary data.
@(private)
media_type_sniff :: proc(body: string) -> string {
	signatures := BINARY_SIGNATURES
	for signature in signatures {
		if strings.has_prefix(body, signature) { return "" }
	}
	if binary_content(body) { return "" }
	text := strings.trim_left(body, "\t\n\x0c\r ")
	tags := SNIFF_HTML_TAGS
	for tag in tags {
		if len(text) > len(tag) && strings.equal_fold(text[:len(tag)], tag) && (text[len(tag)] == ' ' || text[len(tag)] == '>') {
			return "text/html"
		}
	}
	if strings.has_prefix(text, "<?xml") { return "text/xml" }
	return "text/plain"
}

// byte_order_mark returns the charset a leading byte order mark announces and
// the mark's size, or "" when body has none.
@(private)
byte_order_mark :: proc(body: string) -> (charset: string, size: int) {
	switch {
	case strings.has_prefix(body, "\xef\xbb\xbf"):
		return "utf-8", 3
	case strings.has_prefix(body, "\xff\xfe"), strings.has_prefix(body, "\xfe\xff"):
		return "utf-16", 2
	}
	return "", 0
}

@(private)
media_token_valid :: proc(text: string) -> bool {
	if text == "" { return false }
	for character in text {
		switch character {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
		case:
			return false
		}
	}
	return true
}

@(private)
media_type_valid :: proc(text: string) -> bool {
	type_name, slash, subtype := strings.partition(text, "/")
	return slash != "" && media_token_valid(type_name) && media_token_valid(subtype)
}

@(private)
textual_media_type :: proc(media_type: string) -> bool {
	type_name, _, subtype := strings.partition(media_type, "/")
	if strings.equal_fold(type_name, "text") { return true }
	if !strings.equal_fold(type_name, "application") { return false }
	for name in ([?]string{"json", "xml", "javascript", "ecmascript"}) {
		if strings.equal_fold(subtype, name) { return true }
	}
	if len(subtype) >= 5 && strings.equal_fold(subtype[len(subtype) - 5:], "+json") { return true }
	if len(subtype) >= 4 && strings.equal_fold(subtype[len(subtype) - 4:], "+xml") { return true }
	return false
}

@(private)
content_type_charset :: proc(content_type: string) -> string {
	_, _, rest := strings.partition(content_type, ";")
	for parameter in strings.split_iterator(&rest, ";") {
		name, _, value := strings.partition(parameter, "=")
		if !strings.equal_fold(strings.trim_space(name), "charset") { continue }
		value = strings.trim_space(value)
		if len(value) >= 2 && value[0] == '"' && value[len(value) - 1] == '"' { value = value[1:len(value) - 1] }
		return value
	}
	return ""
}

@(private)
html_charset :: proc(source: string) -> string {
	tokenizer: html.Tokenizer
	html.init(&tokenizer, source)
	for token in html.next(&tokenizer) {
		if token.kind == .End_Tag && html.name_equal(token.text, "head") { break }
		if token.kind != .Start_Tag { continue }
		if html.name_equal(token.text, "body") { break }
		if !html.name_equal(token.text, "meta") { continue }
		if charset, present := html.attribute(token, "charset"); present { return strings.trim_space(charset) }
		equiv, _ := html.attribute(token, "http-equiv")
		if html.name_equal(strings.trim_space(equiv), "content-type") {
			content, _ := html.attribute(token, "content")
			if charset := content_type_charset(content); charset != "" { return charset }
		}
	}
	return ""
}

@(private)
Charset :: enum {
	UTF_8,
	Windows_1252,
}

// CHARSET_LABELS are the WHATWG Encoding labels this package decodes. The
// standard decodes every ISO-8859-1 and US-ASCII label as windows-1252.
@(private)
CHARSET_LABELS :: [?]struct {
	label:   string,
	charset: Charset,
} {
	{"utf-8", .UTF_8},
	{"utf8", .UTF_8},
	{"unicode-1-1-utf-8", .UTF_8},
	{"unicode11utf8", .UTF_8},
	{"unicode20utf8", .UTF_8},
	{"x-unicode20utf8", .UTF_8},
	{"windows-1252", .Windows_1252},
	{"cp1252", .Windows_1252},
	{"cp819", .Windows_1252},
	{"csisolatin1", .Windows_1252},
	{"ibm819", .Windows_1252},
	{"x-cp1252", .Windows_1252},
	{"iso-8859-1", .Windows_1252},
	{"iso8859-1", .Windows_1252},
	{"iso88591", .Windows_1252},
	{"iso_8859-1", .Windows_1252},
	{"iso_8859-1:1987", .Windows_1252},
	{"iso-ir-100", .Windows_1252},
	{"latin1", .Windows_1252},
	{"l1", .Windows_1252},
	{"us-ascii", .Windows_1252},
	{"ascii", .Windows_1252},
	{"ansi_x3.4-1968", .Windows_1252},
}

// WINDOWS_1252_CONTROL maps bytes 0x80 through 0x9f to Unicode. Undefined bytes
// retain their control code points, as in the WHATWG Encoding index.
@(private)
WINDOWS_1252_CONTROL :: [32]rune {
	0x20ac,
	0x81,
	0x201a,
	0x192,
	0x201e,
	0x2026,
	0x2020,
	0x2021,
	0x2c6,
	0x2030,
	0x160,
	0x2039,
	0x152,
	0x8d,
	0x17d,
	0x8f,
	0x90,
	0x2018,
	0x2019,
	0x201c,
	0x201d,
	0x2022,
	0x2013,
	0x2014,
	0x2dc,
	0x2122,
	0x161,
	0x203a,
	0x153,
	0x9d,
	0x17e,
	0x178,
}

// charset_decode returns source as UTF-8, borrowing source when it already is.
// An empty label means UTF-8.
@(private)
@(require_results)
charset_decode :: proc(source, label: string) -> (text: string, err: Error) {
	charset := Charset.UTF_8
	if label != "" {
		labels := CHARSET_LABELS
		known := false
		for entry in labels {
			if strings.equal_fold(strings.trim_space(label), entry.label) {
				charset, known = entry.charset, true
				break
			}
		}
		if !known { return "", charset_unsupported(label) }
	}
	if charset == .UTF_8 && utf8.valid_string(source) { return source, {} }
	builder, make_err := strings.builder_make(0, len(source), context.temp_allocator)
	if make_err != nil { return "", OUT_OF_MEMORY }
	switch charset {
	case .Windows_1252:
		controls := WINDOWS_1252_CONTROL
		for i in 0 ..< len(source) {
			character := rune(source[i])
			if source[i] >= 0x80 && source[i] <= 0x9f { character = controls[source[i] - 0x80] }
			bytes, size := utf8.encode_rune(character)
			if !write(&builder, string(bytes[:size])) { return "", OUT_OF_MEMORY }
		}
	case .UTF_8:
		for character in source {
			bytes, size := utf8.encode_rune(character)
			if !write(&builder, string(bytes[:size])) { return "", OUT_OF_MEMORY }
		}
	}
	return strings.to_string(builder), {}
}

@(private)
charset_unsupported :: proc(label: string) -> Error {
	detail := "unsupported charset: invalid charset name"
	if media_token_valid(label) {
		if joined, join_err := strings.concatenate({"unsupported charset: ", label}, context.temp_allocator); join_err == nil { detail = joined }
	}
	return {kind = .Unsupported_Content, detail = detail}
}
