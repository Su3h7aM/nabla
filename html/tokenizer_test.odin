package html

import "core:strings"
import "core:testing"

// Describe renders a token as one short string so tests compare whole streams.
// Tags are "<name>" or "</name>", text is quoted, comments and doctypes are
// prefixed.
@(private = "file")
describe :: proc(source: string, allocator := context.temp_allocator) -> string {
	builder := strings.builder_make(allocator)
	tokenizer: Tokenizer
	init(&tokenizer, source)
	for token in next(&tokenizer) {
		switch token.kind {
		case .Start_Tag:
			strings.write_string(&builder, "<")
			strings.write_string(&builder, token.text)
			strings.write_string(&builder, token.self_closing ? "/>" : ">")
		case .End_Tag:
			strings.write_string(&builder, "</")
			strings.write_string(&builder, token.text)
			strings.write_string(&builder, ">")
		case .Text:
			strings.write_string(&builder, "\"")
			strings.write_string(&builder, token.text)
			strings.write_string(&builder, "\"")
		case .Comment:
			strings.write_string(&builder, "<!--")
			strings.write_string(&builder, token.text)
			strings.write_string(&builder, "-->")
		case .Doctype:
			strings.write_string(&builder, "<!doctype ")
			strings.write_string(&builder, token.text)
			strings.write_string(&builder, ">")
		}
	}
	return strings.to_string(builder)
}

@(test)
test_page_with_mixed_attribute_quoting :: proc(t: ^testing.T) {
	source := `<!DOCTYPE html><HTML lang=en><body class='a b' data-x="1>2" hidden ID = main><br/><img source=a.png alt="x" />hi <3 there</body>`
	testing.expect_value(t, describe(source), `<!doctype html><HTML><body><br/><img/>"hi <3 there"</body>`)

	tokenizer: Tokenizer
	init(&tokenizer, source)
	_, _ = next(&tokenizer)
	html_tag, _ := next(&tokenizer)
	lang, has_lang := attribute(html_tag, "LANG")
	testing.expect(t, has_lang && lang == "en")

	body, _ := next(&tokenizer)
	class, has_class := attribute(body, "class")
	testing.expect(t, has_class && class == "a b")
	data, has_data := attribute(body, "data-x")
	testing.expect(t, has_data && data == "1>2")
	hidden, has_hidden := attribute(body, "hidden")
	testing.expect(t, has_hidden && hidden == "")
	id, has_id := attribute(body, "id")
	testing.expect(t, has_id && id == "main")
	_, has_missing := attribute(body, "style")
	testing.expect(t, !has_missing)
	_, has_folded := attribute(body, "claſs")
	testing.expect(t, !has_folded)

	br, _ := next(&tokenizer)
	testing.expect(t, br.self_closing)
	img, _ := next(&tokenizer)
	src_value, _ := attribute(img, "source")
	testing.expect(t, img.self_closing && src_value == "a.png")
}

@(test)
test_unquoted_value_ending_in_slash_is_not_self_closing :: proc(t: ^testing.T) {
	tokenizer: Tokenizer
	init(&tokenizer, `<a href=/docs/>x`)
	token, _ := next(&tokenizer)
	href, _ := attribute(token, "href")
	testing.expect(t, !token.self_closing && href == "/docs/")

	// Only a '/' directly before the closing '>' closes the tag.
	testing.expect_value(t, describe(`<br/ ><br/><a href="x"/><b/`), `<br><br/><a/><b>`)
}

@(test)
test_raw_text_elements :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		describe(`<script>if (a < b) { x = "</div>"; }</script><STYLE>a>b{}</Style ><title>a <b> c</title><p>`),
		`<script>"if (a < b) { x = "</div>"; }"</script><STYLE>"a>b{}"</Style><title>"a <b> c"</title><p>`,
	)
	// A near miss of the end tag name stays inside the script.
	testing.expect_value(t, describe(`<script>x</scripts></script>`), `<script>"x</scripts>"</script>`)
	// Names compare bytewise: Unicode folding would match "ſ" to "s".
	testing.expect_value(t, describe("<script>x</scripſ></script>"), "<script>\"x</scripſ>\"</script>")
	testing.expect_value(t, describe(`<xmp><b></xmp><plaintext></x><b>`), `<xmp>"<b>"</xmp><plaintext>"</x><b>"`)
	// An unterminated script keeps the rest as text.
	testing.expect_value(t, describe(`<script>var a = "<b>`), `<script>"var a = "<b>"`)
}

@(test)
test_comments_and_bogus_comments :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		describe(`a<!-- <b>x</b> -->b<!---->c<!-->d<?xml v?>e<![CDATA[z]]>f</>g<!-- a --!>h<!-- b -- c -->`),
		`"a"<!-- <b>x</b> -->"b"<!---->"c"<!---->"d"<!--xml v?-->"e"<!--[CDATA[z]]-->"f""g"<!-- a -->"h"<!-- b -- c -->`,
	)
}

@(test)
test_malformed_input_ends_at_end_of_input :: proc(t: ^testing.T) {
	inputs := []string {
		"<",
		"</",
		"<a",
		"<a ",
		"<a href",
		"<a href=",
		`<a href="x`,
		`<a href='x' b="`,
		"<!--x",
		"<!",
		"<!doctype",
		"</a",
		"<a/",
		"<<<>>>",
		"<a =>",
	}
	for input in inputs {
		// Every prefix terminates, which also shows no token loops on the end of input.
		for end in 0 ..= len(input) {
			_ = describe(input[:end])
		}
	}

	testing.expect_value(t, describe(`ok<a href="x`), `"ok"<a>`)
	tokenizer: Tokenizer
	init(&tokenizer, `<a href="x`)
	token, _ := next(&tokenizer)
	href, has_href := attribute(token, "href")
	testing.expect(t, has_href && href == "x")
	_, more := next(&tokenizer)
	testing.expect(t, !more)

	testing.expect_value(t, describe("</"), `"</"`)
	testing.expect_value(t, describe("a<"), `"a<"`)
	testing.expect_value(t, describe("<a href="), `<a>`)
}

@(test)
test_search_results_fragment :: proc(t: ^testing.T) {
	source := `<div class="result results_links results_links_deep web-result ">
<h2 class="result__title"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fodin-lang.org%2Fdocs%2F&amp;rut=abc">The <b>Odin</b> Programming Language</a></h2>
<a class="result__snippet" href="//duckduckgo.com/l/?uddg=x">Odin is a <b>fast</b>, &amp; concise language.</a>
</div>`
	tokenizer: Tokenizer
	init(&tokenizer, source)

	link_href: string
	title_depth_text: [dynamic]string
	snippet_text: [dynamic]string
	defer delete(title_depth_text)
	defer delete(snippet_text)
	collecting: ^[dynamic]string
	result_count := 0
	for token in next(&tokenizer) {
		switch token.kind {
		case .Start_Tag:
			class, _ := attribute(token, "class")
			switch {
			case name_equal(token.text, "div") && strings.contains(class, "result "):
				result_count += 1
			case name_equal(token.text, "a") && strings.contains(class, "result__a"):
				link_href, _ = attribute(token, "href")
				collecting = &title_depth_text
			case name_equal(token.text, "a") && strings.contains(class, "result__snippet"):
				collecting = &snippet_text
			}
		case .End_Tag:
			if name_equal(token.text, "a") {
				collecting = nil
			}
		case .Text:
			if collecting != nil {
				append(collecting, token.text)
			}
		case .Comment, .Doctype:
		}
	}

	testing.expect_value(t, result_count, 1)
	testing.expect_value(t, link_href, "//duckduckgo.com/l/?uddg=https%3A%2F%2Fodin-lang.org%2Fdocs%2F&amp;rut=abc")
	testing.expect_value(t, strings.concatenate(title_depth_text[:], context.temp_allocator), "The Odin Programming Language")
	testing.expect_value(t, strings.concatenate(snippet_text[:], context.temp_allocator), "Odin is a fast, &amp; concise language.")
}
