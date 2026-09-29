#+test
#+private file
package main

import "core:strings"
import "core:testing"

import "nabla:term"
import "nabla:text"

rendered_lines :: proc(t: ^testing.T, source: string, width: int) -> Markdown_Lines {
	lines, err := markdown_lines(source, width, context.temp_allocator)
	if !testing.expect_value(t, err, nil) {
		return {}
	}
	return lines
}

rendered_text :: proc(lines: Markdown_Lines) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for line_index in 0 ..< len(lines.line_ends) {
		if line_index > 0 {
			strings.write_byte(&builder, '\n')
		}
		line := markdown_line(lines, line_index)
		for segment in line {
			strings.write_string(&builder, segment.text)
		}
	}
	return strings.to_string(builder)
}

rendered_line_text :: proc(line: []Styled_Segment) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for segment in line {
		strings.write_string(&builder, segment.text)
	}
	return strings.to_string(builder)
}

@(test)
test_markdown_paragraph_wraps_words_and_splits_long_words :: proc(t: ^testing.T) {
	lines := rendered_lines(t, "ab cd efghijk lm", 5)
	testing.expect_value(t, rendered_text(lines), "ab cd\nefghi\njk lm")

	separated := rendered_lines(t, "one\n\ntwo", 10)
	testing.expect_value(t, rendered_text(separated), "one\n\ntwo")
}

@(test)
test_markdown_preserves_strong_and_code_styles :: proc(t: ^testing.T) {
	lines := rendered_lines(t, "**bold** and `code`", 20)
	found_bold := false
	found_cyan_code := false
	for line_index in 0 ..< len(lines.line_ends) {
		line := markdown_line(lines, line_index)
		for segment in line {
			if segment.text == "bold" {
				found_bold = true
				testing.expect(t, .Bold in segment.style.modifiers, "strong text must be bold")
			}
			if segment.text == "code" {
				found_cyan_code = true
				foreground, ok := segment.style.foreground.(term.Indexed_Color)
				testing.expect(t, ok && foreground == term.Indexed_Color(6), "inline code must be cyan")
			}
		}
	}
	testing.expect(t, found_bold, "bold span must be rendered")
	testing.expect(t, found_cyan_code, "code span must be rendered")

	links := rendered_lines(t, "[docs](https://example.com)", 80)
	testing.expect_value(t, rendered_text(links), "docs (https://example.com)")
}

@(test)
test_markdown_link_segments_keep_safe_destination_through_wrap :: proc(t: ^testing.T) {
	lines := rendered_lines(t, "[docs](https://example.com)", 8)
	testing.expect(t, len(lines.line_ends) > 1)
	for line_index in 0 ..< len(lines.line_ends) {
		for segment in markdown_line(lines, line_index) {
			testing.expect_value(t, segment.link, "https://example.com")
		}
	}
	testing.expect_value(t, rendered_text(lines), "docs\n(https:/\n/example\n.com)")

	unsafe := rendered_lines(t, "[bad](javascript:alert)", 80)
	for line_index in 0 ..< len(unsafe.line_ends) {
		for segment in markdown_line(unsafe, line_index) {
			testing.expect_value(t, segment.link, "")
		}
	}
}

@(test)
test_markdown_tight_nested_list_aligns_ordered_numbers :: proc(t: ^testing.T) {
	lines := rendered_lines(t, "9. first\n10. second\n    - child\n    - next\n11. third", 40)
	testing.expect_value(t, rendered_text(lines), " 9. first\n10. second\n    • child\n    • next\n11. third")
}

@(test)
test_markdown_quote_prefixes_wrapped_content :: proc(t: ^testing.T) {
	lines := rendered_lines(t, "> quoted text\n> continues", 12)
	testing.expect_value(t, rendered_text(lines), "│ quoted\n│ text\n│ continues")
}

@(test)
test_markdown_code_block_hard_wraps_and_keeps_cyan_style :: proc(t: ^testing.T) {
	lines := rendered_lines(t, "```odin\nabcdefghijk\n```", 8)
	testing.expect_value(t, rendered_text(lines), "  odin\n  abcdef\n  ghijk")
	for line_index in 0 ..< len(lines.line_ends) {
		line := markdown_line(lines, line_index)
		if line_index == 0 {
			continue
		}
		for segment in line {
			foreground, ok := segment.style.foreground.(term.Indexed_Color)
			testing.expect(t, ok && foreground == term.Indexed_Color(6), "code block segments must be cyan")
		}
	}
}

@(test)
test_markdown_tables_fit_and_shrink_to_width :: proc(t: ^testing.T) {
	fits := rendered_lines(t, "| A | B |\n| - | -: |\n| x | 9 |", 16)
	testing.expect(t, len(fits.line_ends) >= 4, "table must have borders and rows")
	for line_index in 0 ..< len(fits.line_ends) {
		line := markdown_line(fits, line_index)
		testing.expect(t, text.text_columns(rendered_line_text(line)) <= 16, "fitting table lines must stay within width")
	}

	shrinks := rendered_lines(t, "| firstlong | secondlong | thirdlong |\n| --- | --- | --- |\n| abcdefgh | ijklmnop | qrstuvwx |", 20)
	testing.expect(t, len(shrinks.line_ends) >= 4, "shrunk table must have borders and rows")
	for line_index in 0 ..< len(shrinks.line_ends) {
		line := markdown_line(shrinks, line_index)
		testing.expect(t, text.text_columns(rendered_line_text(line)) <= 20, "shrunk table lines must stay within width")
	}
}

@(test)
test_markdown_width_one_terminates :: proc(t: ^testing.T) {
	lines := rendered_lines(t, "abcdefgh", 1)
	testing.expect_value(t, rendered_text(lines), "a\nb\nc\nd\ne\nf\ng\nh")
}
