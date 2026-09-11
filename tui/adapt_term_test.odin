#+build linux
#+test
#+private file
package tui

import "core:testing"
import "nabla:term"

@(test)
test_style_maps_to_the_terminal_vocabulary :: proc(t: ^testing.T) {
	style := Style {
		foreground = RGB_Color{10, 20, 30},
		background = Indexed_Color(7),
		modifiers  = {.Bold, .Underline},
	}
	mapped := presentation_style(style)
	testing.expect_value(t, mapped.foreground, term.Color(term.RGB_Color{10, 20, 30}))
	testing.expect_value(t, mapped.background, term.Color(term.Indexed_Color(7)))
	testing.expect_value(t, mapped.modifiers, term.Modifiers{.Bold, .Underline})

	// Every modifier maps one to one; a collision would collapse two tui
	// modifiers into one terminal modifier.
	seen: term.Modifiers
	for modifier in Modifier {
		term_modifier := presentation_modifier(modifier)
		testing.expect(t, term_modifier not_in seen, "modifiers must map one to one")
		seen += {term_modifier}
	}

	// nil means "inherit"; Default_Color means "reset to the terminal default".
	testing.expect_value(t, presentation_color(nil), term.Color(nil))
	testing.expect_value(t, presentation_color(Default_Color{}), term.Color(term.Default_Color{}))
}

@(test)
test_build_frame :: proc(t: ^testing.T) {
	storage: [6]Cell
	buffer: Cell_Buffer
	_ = init(&buffer, 3, 2, storage[:])
	put(&buffer, 1, 1, {grapheme = "x"})

	cells: [8]term.Cell
	frame, ok := build_frame(buffer, cells[:])
	testing.expect(t, ok, "build_frame must succeed with sufficient storage")
	testing.expect_value(t, frame.columns, 3)
	testing.expect_value(t, frame.rows, 2)
	// (1,1) in a 3-wide buffer is index 4.
	testing.expect_value(t, frame.cells[4].grapheme, "x")
	testing.expect_value(t, frame.cells[0].grapheme, " ")

	// Undersized storage is refused.
	small: [4]term.Cell
	_, small_ok := build_frame(buffer, small[:])
	testing.expect(t, !small_ok, "undersized storage must be refused")

	// A malformed buffer is refused without writing to the output.
	logical: [3]Cell
	malformed := Cell_Buffer {
		width  = 2,
		height = 2,
		cells  = logical[:],
	}
	terminal := [?]term.Cell{{grapheme = "kept", width = 1}, {}, {}, {}}
	original := terminal
	_, malformed_ok := build_frame(malformed, terminal[:])
	testing.expect(t, !malformed_ok)
	testing.expect_value(t, terminal, original)
}
