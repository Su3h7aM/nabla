package tui

import "base:runtime"

import "nabla:layout"
import "nabla:term"

// Border is the glyph set a Border_Cmd draws with. An empty glyph draws as a space.
Border :: struct {
	top_left, top_right, bottom_left, bottom_right: string,
	horizontal, vertical:                           string,
}

BORDER_SINGLE :: Border {
	top_left     = "┌",
	top_right    = "┐",
	bottom_left  = "└",
	bottom_right = "┘",
	horizontal   = "─",
	vertical     = "│",
}

BORDER_ROUNDED :: Border {
	top_left     = "╭",
	top_right    = "╮",
	bottom_left  = "╰",
	bottom_right = "╯",
	horizontal   = "─",
	vertical     = "│",
}

// Paint is what a layout.Paint id stands for in the terminal. A command resolves
// the fields it uses and ignores the rest: Fill_Cmd draws fill in style,
// Border_Cmd draws border in style, and Text_Cmd draws its text in style under
// link.
Paint :: struct {
	style:  term.Style,
	// fill is the grapheme a Fill_Cmd repeats over its bounds; "" means " ".
	fill:   string,
	border: Border,
	link:   term.Link_Id,
}

// Paints is a frame's paint table. The caller owns it and clears it before
// declaring the next frame; a layout.Paint it handed out names an entry only
// until the table is cleared, so the table must outlive the draw of the frame's
// commands and the strings it holds must outlive the present.
Paints :: [dynamic]Paint

// paint appends value to paints and returns the layout.Paint that names it. The
// id is the entry's index plus one, so it is never 0. Equal values are not
// shared; every call adds an entry. On an allocation error the id is 0, which
// layout reads as "emit nothing".
paint :: proc(paints: ^Paints, value: Paint) -> (layout.Paint, runtime.Allocator_Error) {
	_, err := append(paints, value)
	if err != nil {
		return 0, err
	}
	return layout.Paint(len(paints)), nil
}

// paint_of returns the entry id names in paints, or false when id is 0 or does
// not index the table.
@(require_results)
paint_of :: proc "contextless" (paints: []Paint, id: layout.Paint) -> (Paint, bool) {
	if id == 0 || u64(id) > u64(len(paints)) {
		return {}, false
	}
	return paints[id - 1], true
}
