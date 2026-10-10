#+test
#+private file
package markdown

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

// outline writes a document one block per line, nested blocks indented by two
// spaces, and styled spans as {flags:text}, so a case states the whole parse.
outline :: proc(document: Document) -> string {
	builder := strings.builder_make(context.temp_allocator)
	outline_blocks(&builder, document.blocks, 0)
	return strings.to_string(builder)
}

outline_blocks :: proc(builder: ^strings.Builder, blocks: []Block, depth: int) {
	for block in blocks {
		for _ in 0 ..< depth {
			strings.write_string(builder, "  ")
		}
		switch value in block {
		case Paragraph:
			strings.write_string(builder, "p ")
			outline_spans(builder, value.spans)
		case Heading:
			fmt.sbprintf(builder, "h%d ", value.level)
			outline_spans(builder, value.spans)
		case Code_Block:
			fmt.sbprintf(builder, "code %q %q", value.info, value.lines)
		case Quote:
			strings.write_string(builder, "quote\n")
			outline_blocks(builder, value.blocks, depth + 1)
			continue
		case List:
			fmt.sbprintf(builder, "list ordered=%v start=%d tight=%v\n", value.ordered, value.start, value.tight)
			for item in value.items {
				for _ in 0 ..< depth + 1 {
					strings.write_string(builder, "  ")
				}
				strings.write_string(builder, "item\n")
				outline_blocks(builder, item, depth + 2)
			}
			continue
		case Table:
			fmt.sbprintf(builder, "table %v", value.alignments)
			outline_row(builder, value.header)
			for row in value.rows {
				outline_row(builder, row)
			}
		case Thematic_Break:
			strings.write_string(builder, "hr")
		}
		strings.write_byte(builder, '\n')
	}
}

outline_row :: proc(builder: ^strings.Builder, cells: []Cell) {
	strings.write_string(builder, " |")
	for cell in cells {
		outline_spans(builder, cell)
		strings.write_byte(builder, '|')
	}
}

outline_spans :: proc(builder: ^strings.Builder, spans: []Span) {
	FLAG_LETTERS := [Style_Flag]byte {
		.Emphasis      = 'e',
		.Strong        = 's',
		.Strikethrough = 'x',
		.Code          = 'c',
		.Link          = 'l',
		.Soft_Break    = 0,
	}
	for span in spans {
		// The soft break flag marks a space, which the outline shows as the space.
		style := span.style - {.Soft_Break}
		if style == {} {
			strings.write_string(builder, span.text)
			continue
		}
		strings.write_byte(builder, '{')
		for flag in style {
			strings.write_byte(builder, FLAG_LETTERS[flag])
		}
		if .Link in span.style {
			fmt.sbprintf(builder, "=%s", span.url)
		}
		fmt.sbprintf(builder, ":%s}", span.text)
	}
}

expect_outline :: proc(t: ^testing.T, source, expected: string, location := #caller_location) {
	document, err := parse(source)
	defer destroy(&document)
	testing.expect_value(t, err, nil, location)
	testing.expect_value(t, outline(document), expected, location)
}

@(test)
test_agent_response :: proc(t: ^testing.T) {
	expect_outline(
		t,
		"# Answer\n\nUse **bold**, *em*, `code`, and [the docs](https://example.com).\n\n```odin\nmain :: proc() {\n\tx := 1\n}\n```\n\n- one\n- two\n\n| Name | Value |\n| :--- | ---: |\n| x | 1 |\n",
		"h1 Answer\n" +
		"p Use {s:bold}, {e:em}, {c:code}, and {l=https://example.com:the docs}.\n" +
		"code \"odin\" [\"main :: proc() {\", \"\\tx := 1\", \"}\"]\n" +
		"list ordered=false start=0 tight=true\n  item\n    p one\n  item\n    p two\n" +
		"table [\"Left\", \"Right\"] |Name|Value| |x|1|\n",
	)
}

@(test)
test_inline_markup :: proc(t: ^testing.T) {
	expect_outline(t, "**a *b***", "p {s:a }{es:b}\n")
	expect_outline(t, "foo_bar_baz and foo*bar*", "p foo_bar_baz and foo{e:bar}\n")
	expect_outline(t, "~~gone~~ ~~~kept~~~", "p {x:gone} ~~~kept~~~\n")
	expect_outline(t, "\\*not emphasis\\* \\q", "p *not emphasis* \\q\n")
	expect_outline(t, "``a ` b`` and `unclosed", "p {c:a ` b} and `unclosed\n")
	expect_outline(t, "<https://a.b/c> and <not a link>", "p {l=https://a.b/c:https://a.b/c} and <not a link>\n")
	expect_outline(t, "*[foo*](url) [a **b**](<u v> \"t\") [no link]", "p *{l=url:foo*} {l=u v:a }{sl=u v:b} [no link]\n")
	expect_outline(t, "![alt](image.png)", "p {l=image.png:alt}\n")
}

LINK_TARGET_CANDIDATE_COUNT :: 4_096

@(test)
test_link_target_parsing_handles_unmatched_and_nested_parentheses :: proc(t: ^testing.T) {
	builder := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< LINK_TARGET_CANDIDATE_COUNT {
		strings.write_string(&builder, "[x](")
	}
	strings.write_byte(&builder, ')')
	source := strings.to_string(builder)
	document, err := parse(source)
	if !testing.expect(t, err == nil, "unmatched link targets should remain text") { return }
	defer destroy(&document)
	if !testing.expect(t, len(document.blocks) == 1, "the line should parse as one block") { return }
	switch block in document.blocks[0] {
	case Paragraph:
		if !testing.expect(t, len(block.spans) == 1, "the line should remain one text span") { return }
		testing.expect_value(t, block.spans[0].text, source)
	case Heading, Code_Block, Quote, List, Table, Thematic_Break:
		testing.fail_now(t, "the line should parse as a paragraph")
	}
	expect_outline(t, "[x](a(b)c)", "p {l=a(b)c:x}\n")
}

@(test)
test_line_breaks :: proc(t: ^testing.T) {
	expect_outline(t, "soft\nbreak", "p soft break\n")
	document, err := parse("soft\nbreak")
	defer destroy(&document)
	testing.expect_value(t, err, nil)
	paragraph, is_paragraph := document.blocks[0].(Paragraph)
	testing.expect(t, is_paragraph && len(paragraph.spans) == 3 && paragraph.spans[1].style == {.Soft_Break}, "a soft break is a span flagged Soft_Break")
	expect_outline(t, "hard  \nbreak\\\nagain\\", "p hard\nbreak\nagain\\\n")
	expect_outline(t, "*across\nlines*", "p {e:across}{e: }{e:lines}\n")
}

@(test)
test_headings_and_breaks :: proc(t: ^testing.T) {
	expect_outline(t, "## Title ##\n#hashtag\n####### seven", "h2 Title\np #hashtag ####### seven\n")
	expect_outline(t, "Title\n===\n\nSub\ntitle\n---", "h1 Title\nh2 Sub title\n")
	expect_outline(t, "* * *\n- foo\n---", "hr\nlist ordered=false start=0 tight=true\n  item\n    p foo\nhr\n")
}

@(test)
test_code_blocks :: proc(t: ^testing.T) {
	expect_outline(t, "~~~\n```\n~~~\n  ```` sh\n  ls\n ````", "code \"\" [\"```\"]\ncode \"sh\" [\"ls\"]\n")
	expect_outline(t, "    indented\n\n    code\n\nafter", "code \"\" [\"indented\", \"\", \"code\"]\np after\n")
	expect_outline(t, "> ```\n> open\n\nafter", "quote\n  code \"\" [\"open\"]\np after\n")
}

@(test)
test_lists :: proc(t: ^testing.T) {
	expect_outline(
		t,
		"1. a\n2. b\n   - c\n   - d\n3. e",
		"list ordered=true start=1 tight=true\n  item\n    p a\n  item\n    p b\n    list ordered=false start=0 tight=true\n      item\n        p c\n      item\n        p d\n  item\n    p e\n",
	)
	expect_outline(
		t,
		"3) x\n4) y\n1. z",
		"list ordered=true start=3 tight=true\n  item\n    p x\n  item\n    p y\nlist ordered=true start=1 tight=true\n  item\n    p z\n",
	)
	expect_outline(t, "- a\n\n- b\n\nafter", "list ordered=false start=0 tight=false\n  item\n    p a\n  item\n    p b\np after\n")
	expect_outline(t, "- a\nlazy\n- b", "list ordered=false start=0 tight=true\n  item\n    p a lazy\n  item\n    p b\n")
	expect_outline(t, "Foo\n2. bar\n- baz", "p Foo 2. bar\nlist ordered=false start=0 tight=true\n  item\n    p baz\n")
	expect_outline(t, "- item\n\n  ```odin\n  x := 1\n  ```", "list ordered=false start=0 tight=false\n  item\n    p item\n    code \"odin\" [\"x := 1\"]\n")
}

@(test)
test_quotes :: proc(t: ^testing.T) {
	expect_outline(
		t,
		"> quoted\nlazy\n>\n> - item\n\n> second",
		"quote\n  p quoted lazy\n  list ordered=false start=0 tight=true\n    item\n      p item\nquote\n  p second\n",
	)
}

@(test)
test_tables :: proc(t: ^testing.T) {
	expect_outline(
		t,
		"intro\n| a | b | c |\n| :-- | :-: | -- |\n| short |\n| x | y | z | extra |\nafter",
		"p intro\ntable [\"Left\", \"Center\", \"None\"] |a|b|c| |short||| |x|y|z|\np after\n",
	)
	expect_outline(t, "a | b\n--|--\nx \\| y | `z`\n\nend", "table [\"None\", \"None\"] |a|b| |x | y|{c:z}|\np end\n")
	expect_outline(t, "a | b | c\n--|--\n", "p a | b | c --|--\n")
}

@(test)
test_destroy_releases_everything :: proc(t: ^testing.T) {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)

	document, err := parse(MIXED_SOURCE, mem.tracking_allocator(&tracker))
	testing.expect_value(t, err, nil)
	destroy(&document)
	testing.expect_value(t, len(tracker.allocation_map), 0)
	destroy(&document)
}

@(test)
test_allocation_failure_leaves_nothing :: proc(t: ^testing.T) {
	for allowed in 0 ..< 1000 {
		tracker: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracker, context.allocator)
		defer mem.tracking_allocator_destroy(&tracker)
		limit := Limit_Allocator {
			tracker = &tracker,
			allowed = allowed,
		}

		document, err := parse(MIXED_SOURCE, {procedure = limit_allocator_proc, data = &limit})
		if err == nil {
			destroy(&document)
			testing.expect_value(t, len(tracker.allocation_map), 0)
			return
		}
		testing.expect_value(t, err, mem.Allocator_Error.Out_Of_Memory)
		testing.expect_value(t, len(tracker.allocation_map), 0)
	}
	testing.fail_now(t, "parse never succeeded")
}

MIXED_SOURCE :: "# h\n\np **s** [l](u)\n\n```\ncode\n```\n\n> quote\n> - nested\n\n1. one\n2. two\n   - deep\n\n| a | b |\n| --- | --- |\n| c | d |\n"

DEEP_QUOTE_MARKER_COUNT :: 10_000

@(test)
test_deep_quote_text_is_rendered :: proc(t: ^testing.T) {
	builder := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< DEEP_QUOTE_MARKER_COUNT {
		strings.write_byte(&builder, '>')
	}
	strings.write_byte(&builder, 'x')
	source := strings.to_string(builder)

	document, err := parse(source)
	if !testing.expect(t, err == nil, "a deeply nested quote should parse") { return }
	defer destroy(&document)

	rendered := outline(document)
	testing.expect(t, strings.contains(rendered, source[MAX_CONTAINER_DEPTH:]), "deep quote text should be rendered")
}

// Limit_Allocator fails every allocation after the first allowed ones, so a test
// can fail parse at each allocation in turn.
Limit_Allocator :: struct {
	tracker: ^mem.Tracking_Allocator,
	allowed: int,
}

limit_allocator_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	limit := (^Limit_Allocator)(data)
	// Free, Free_All, and Query_* release or report memory and cannot fail.
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if limit.allowed == 0 {
			return nil, .Out_Of_Memory
		}
		limit.allowed -= 1
	}
	return mem.tracking_allocator_proc(limit.tracker, mode, size, alignment, old_memory, old_size, location)
}
