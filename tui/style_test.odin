#+build linux
#+test
#+private file
package tui

import "core:testing"
import "nabla:term"

@(test)
test_style_round_trip :: proc(t: ^testing.T) {
	style := term.Style {
		foreground = term.Indexed_Color(0),
		background = term.Indexed_Color(255),
		modifiers  = {.Bold, .Strikethrough},
	}
	testing.expect_value(t, term_style(text_style(style)), style)

	plain := term.Style {
		foreground = term.RGB_Color{1, 2, 3},
		modifiers  = {.Italic},
	}
	testing.expect_value(t, term_style(text_style(plain)), term.Style{modifiers = {.Italic}})
}
