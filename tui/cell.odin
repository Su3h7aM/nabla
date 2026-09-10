package tui

// Cell is one logical composition cell: a borrowed grapheme plus a style.
// Graphemes point into caller-owned text (draw_ascii stores slices of the
// drawn string) and must stay valid until the frame is presented; an empty
// grapheme means a blank cell, matching the terminal cell contract. The
// logical buffer is the sole owner of this shape — tty.Cell is the
// terminal-facing projection.
Cell :: struct {
	grapheme: string,
	style:    Style,
}

Cell_Buffer :: struct {
	width:  int,
	height: int,
	cells:  []Cell,
}

// init binds caller-owned storage to a logical cell grid and fills the grid
// with blank cells. The buffer borrows storage; storage and every borrowed
// grapheme written into it must remain valid through composition and
// presentation.
//
// Zero-sized grids are valid. On failure buffer and storage are unchanged.
@(require_results)
init :: proc(buffer: ^Cell_Buffer, width, height: int, storage: []Cell, base: Style = {}) -> bool {
	if buffer == nil || width < 0 || height < 0 {
		return false
	}
	cell_count := 0
	if width > 0 && height > 0 {
		// Division-first validation prevents width * height from overflowing.
		if width > len(storage) / height {
			return false
		}
		cell_count = width * height
	}

	initialized := Cell_Buffer {
		width  = width,
		height = height,
		cells  = storage[:cell_count],
	}
	for &cell in initialized.cells {
		cell = {
			grapheme = " ",
			style    = base,
		}
	}
	buffer^ = {
		width  = initialized.width,
		height = initialized.height,
		cells  = initialized.cells,
	}
	return true
}

put :: proc(buffer: ^Cell_Buffer, x, y: int, cell: Cell) -> bool {
	if buffer == nil || x < 0 || y < 0 || x >= buffer.width || y >= buffer.height {
		return false
	}
	if buffer.width <= 0 || buffer.height <= 0 || buffer.width > len(buffer.cells) / buffer.height {
		return false
	}
	buffer.cells[y * buffer.width + x] = cell
	return true
}
