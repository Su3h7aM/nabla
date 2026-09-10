package tui

// Printable ASCII bounds. Everything outside this range needs either a width
// decision (tabs, wide characters) or an escape (control bytes), and this
// package makes neither.
FIRST_PRINTABLE_ASCII :: 0x20
DELETE_ASCII :: 0x7f

// clip_to_buffer intersects `rect` with the buffer, in cells.
//
// Returns a rect of zero width and height when the intersection is empty, so a
// caller can loop over the result without checking for that case first.
clip_to_buffer :: proc "contextless" (buffer: Cell_Buffer, rect: Cell_Rect) -> Cell_Rect {
	left := max(rect.x, 0)
	top := max(rect.y, 0)
	right := min(rect.x + rect.width, buffer.width)
	bottom := min(rect.y + rect.height, buffer.height)

	if right <= left || bottom <= top {
		return {}
	}
	return {x = left, y = top, width = right - left, height = bottom - top}
}

// is_drawable_ascii reports whether every byte of `value` occupies exactly one
// terminal cell.
//
// Tabs and line breaks are excluded along with every other control byte: their
// width depends on the cursor position, and this package draws a glyph per cell.
is_drawable_ascii :: proc "contextless" (value: string) -> bool {
	for character in transmute([]byte)value {
		if character < FIRST_PRINTABLE_ASCII || character >= DELETE_ASCII {
			return false
		}
	}
	return true
}

// fill writes `cell` over every position of `rect` that lies inside `buffer`.
//
// Units: `rect` is in terminal cells.
// Clipping: area outside the buffer is skipped rather than reported. A rect that
// misses the buffer entirely writes nothing, which is the normal outcome for a
// resolved box sized or scrolled out of view, not a failure.
// Returns the number of cells written.
fill :: proc(buffer: ^Cell_Buffer, rect: Cell_Rect, cell: Cell) -> (written: int) {
	visible := clip_to_buffer(buffer^, rect)

	for row in visible.y ..< visible.y + visible.height {
		row_start := row * buffer.width
		for column in visible.x ..< visible.x + visible.width {
			buffer.cells[row_start + column] = cell
		}
	}
	return visible.width * visible.height
}

// draw_ascii writes one line of ASCII text into `rect`, starting at its origin.
//
// Scope: this is the drawing counterpart of `text.measure_ascii` and shares its
// limits -- one byte is one cell, one line, no segmentation. It is deliberately
// stricter than measurement: a byte this procedure cannot place as a single cell
// fails the whole call instead of being replaced, because a glyph substituted at
// draw time would no longer match the width the solver was given.
//
// Partial progress: none. On failure nothing is written, so a rejected string
// never leaves half a line in the buffer.
// Clipping: text is confined to `rect` and to the buffer; a string longer than
// the rect is truncated, which is not a failure.
// Returns the number of cells written.
draw_ascii :: proc(buffer: ^Cell_Buffer, rect: Cell_Rect, value: string, style: Style) -> (written: int, ok: bool) {
	if !is_drawable_ascii(value) {
		return 0, false
	}
	if rect.height <= 0 {
		return 0, true
	}

	// Only the first row of the rect can hold text: this draws a single line.
	first_row := Cell_Rect {
		x      = rect.x,
		y      = rect.y,
		width  = rect.width,
		height = 1,
	}
	visible := clip_to_buffer(buffer^, first_row)
	if visible.width == 0 {
		return 0, true
	}

	// Clipping the left edge removes leading columns of the rect. Skipping the
	// same number of characters keeps the text anchored to the rect rather than
	// sliding it over to the buffer edge.
	skipped_characters := visible.x - rect.x
	row_start := visible.y * buffer.width

	for column in 0 ..< visible.width {
		character_index := skipped_characters + column
		if character_index >= len(value) {
			break
		}
		buffer.cells[row_start + visible.x + column] = Cell {
			grapheme = value[character_index:character_index + 1],
			style    = style,
		}
		written += 1
	}
	return written, true
}
