#+test
#+private file
package text

import "core:testing"
import "core:unicode/utf8"

Reference_Step :: struct {
	cluster: Display_Cluster,
	status:  Display_Status,
}

// reference_steps walks value with the grapheme iterator alone, the way
// display_next did before it skipped the iterator for printable ASCII.
reference_steps :: proc(value: string, profile: Width_Profile, allocator := context.temp_allocator) -> [dynamic]Reference_Step {
	steps := make([dynamic]Reference_Step, allocator)
	graphemes := grapheme_iterator_make(value)
	column := 0
	for _, grapheme in grapheme_iterate(&graphemes) {
		end := grapheme.byte_index + len(grapheme.text)
		if !utf8.valid_string(grapheme.text) {
			append(&steps, Reference_Step{status = .Invalid_Text})
			return steps
		}
		code_point, _ := utf8.decode_rune(grapheme.text)
		switch {
		case code_point == '\n' || code_point == '\r':
			append(&steps, Reference_Step{status = .Invalid_Text})
			return steps
		case code_point == '\t':
			if profile.tab_width <= 0 {
				continue
			}
			cells := profile.tab_width - column % profile.tab_width
			for _ in 0 ..< cells {
				append(&steps, Reference_Step{cluster = {text = " ", width = 1, end = end}})
			}
			column += cells
		case grapheme.width == 0:
			if profile.invalid_text == .Reject {
				append(&steps, Reference_Step{status = .Invalid_Text})
				return steps
			}
		case:
			width := grapheme.width
			if width == 1 && profile.emoji == .Wide {
				for member in grapheme.text {
					if member == 0xFE0F {
						width = 2
					}
				}
			}
			column += width
			append(&steps, Reference_Step{cluster = {text = grapheme.text, width = width, end = end}})
		}
	}
	append(&steps, Reference_Step{status = .Done})
	return steps
}

@(test)
test_display_next_matches_the_grapheme_iterator_walk :: proc(t: ^testing.T) {
	values := [?]string {
		"",
		"hello world",
		"a",
		" ~",
		"1\uFE0F\u20E3",
		"1\uFE0F\u20E3x",
		"#\uFE0F\u20E3 #",
		"x1\uFE0F",
		"e\u0301",
		"abe\u0301cd",
		"a\u200Db",
		"a\u200D",
		"\u200Da",
		"a\tb\tcd\t",
		"\t",
		"a\x01b\x7Fc\x1Bd",
		"a\nb",
		"a\r\nb",
		"a界b",
		"日本語 text 日本語",
		"a😀b",
		"👩\u200D👩x",
		"🇯🇵🇺🇸x",
		"❤\uFE0F \u2764\uFE0E",
		"a\xffb",
		"ab\xe3\x81",
		"\xff",
		"é\xffa",
	}
	profiles := [?]Width_Profile {
		DEFAULT_WIDTH_PROFILE,
		{invalid_text = .Reject, tab_width = 4, emoji = .Core_Width},
		{invalid_text = .Reject, tab_width = 0, emoji = .Wide},
		{invalid_text = .Replace, tab_width = 8, emoji = .Core_Width},
	}
	for value in values {
		for profile in profiles {
			expected := reference_steps(value, profile)
			iterator := display_iterator_make(value, profile)
			for step in expected {
				cluster, status := display_next(&iterator)
				testing.expect_value(t, status, step.status)
				if status != .OK {
					break
				}
				testing.expect_value(t, cluster, step.cluster)
			}
		}
	}
}
