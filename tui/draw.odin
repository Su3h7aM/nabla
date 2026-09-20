package tui

import "nabla:term"
import "nabla:text"

// Drawing over term.Frame_Buffer. Every operation is caller-owned and
// allocates nothing; a grapheme stored in the grid borrows from the drawn text
// and must stay valid until term.present runs.

// init binds storage to a frame grid and fills it with blanks in base. A
// zero-sized grid is valid; on failure buffer and storage are unchanged.
@(require_results)
init :: proc(buffer: ^term.Frame_Buffer, columns, rows: int, storage: []term.Cell, base: term.Style = {}) -> bool {
	if buffer == nil || columns < 0 || rows < 0 {
		return false
	}
	cell_count := 0
	if columns > 0 && rows > 0 {
		if columns > len(storage) / rows {
			return false
		}
		cell_count = columns * rows
	}
	for index in 0 ..< cell_count {
		storage[index] = term.Cell {
			grapheme = " ",
			style    = base,
			width    = 1,
		}
	}
	buffer^ = term.Frame_Buffer {
		columns = columns,
		rows    = rows,
		cells   = storage[:cell_count],
	}
	return true
}

// clip_to_buffer intersects rect with the grid.
clip_to_buffer :: proc "contextless" (buffer: term.Frame_Buffer, rect: Cell_Rect) -> Cell_Rect {
	left := max(rect.x, 0)
	top := max(rect.y, 0)
	right := min(_rect_end(rect.x, rect.width), buffer.columns)
	bottom := min(_rect_end(rect.y, rect.height), buffer.rows)
	if right <= left || bottom <= top {
		return {}
	}
	return {x = left, y = top, width = right - left, height = bottom - top}
}

// put writes one grapheme cluster at (x, y), with its placeholder when the
// cluster is width 2. A cluster the policy cannot draw is refused.
@(require_results)
put_cell :: proc(
	buffer: ^term.Frame_Buffer,
	x, y: int,
	grapheme: string,
	style: term.Style,
	profile: text.Width_Profile = text.DEFAULT_WIDTH_PROFILE,
) -> bool {
	if buffer == nil || !_grid_valid(buffer^) || y < 0 || y >= buffer.rows {
		return false
	}
	width := text.cluster_width(grapheme, profile)
	if width != 1 && width != 2 {
		return false
	}
	return _write_cluster(buffer, x, y, grapheme, style, width)
}

// fill writes one width-1 grapheme over every cell of rect inside the grid and
// returns the cells written. A wide grapheme is refused.
fill_rect :: proc(
	buffer: ^term.Frame_Buffer,
	rect: Cell_Rect,
	grapheme: string,
	style: term.Style,
	profile: text.Width_Profile = text.DEFAULT_WIDTH_PROFILE,
) -> (
	written: int,
) {
	if buffer == nil || !_grid_valid(buffer^) || text.cluster_width(grapheme, profile) != 1 {
		return 0
	}
	return _fill_clipped(buffer, rect, Cell_Rect{width = buffer.columns, height = buffer.rows}, grapheme, style)
}

// draw_text writes one line into rect and returns the cells written. A line
// the policy rejects writes nothing; a cluster crossing the rect's right edge
// is truncated rather than split.
@(require_results)
draw_text_rect :: proc(
	buffer: ^term.Frame_Buffer,
	rect: Cell_Rect,
	value: string,
	style: term.Style,
	profile: text.Width_Profile = text.DEFAULT_WIDTH_PROFILE,
) -> (
	written: int,
	ok: bool,
) {
	if buffer == nil {
		return 0, false
	}
	return _draw_text_clipped(buffer, rect, Cell_Rect{width = buffer.columns, height = buffer.rows}, value, style, profile)
}

put :: proc {
	put_cell,
	put_context,
}

fill :: proc {
	fill_rect,
	fill_context,
}

draw_text :: proc {
	draw_text_rect,
	draw_text_context,
}

@(private)
_fill_clipped :: proc(buffer: ^term.Frame_Buffer, rect, clip: Cell_Rect, grapheme: string, style: term.Style) -> (written: int) {
	visible := _intersect_rect(clip_to_buffer(buffer^, rect), clip)
	for row in visible.y ..< visible.y + visible.height {
		for column in visible.x ..< visible.x + visible.width {
			if _write_cluster(buffer, column, row, grapheme, style, 1) {
				written += 1
			}
		}
	}
	return written
}

@(private)
_draw_text_clipped :: proc(
	buffer: ^term.Frame_Buffer,
	rect, clip: Cell_Rect,
	value: string,
	style: term.Style,
	profile: text.Width_Profile,
) -> (
	written: int,
	ok: bool,
) {
	if !_grid_valid(buffer^) {
		return 0, false
	}
	check := text.display_iterator_make(value, profile)
	for {
		_, status := text.display_next(&check)
		if status == .Done {
			break
		}
		if status == .Invalid_Text {
			return 0, false
		}
	}
	if rect.height <= 0 || rect.width <= 0 {
		return 0, true
	}

	visible := _intersect_rect(clip_to_buffer(buffer^, {x = rect.x, y = rect.y, width = rect.width, height = 1}), clip)
	if visible.width == 0 {
		return 0, true
	}

	right := _rect_end(rect.x, rect.width)
	column := rect.x
	it := text.display_iterator_make(value, profile)
	for {
		cluster, status := text.display_next(&it)
		if status != .OK {
			break
		}
		if column + cluster.width > right {
			break
		}
		if column >= visible.x && column + cluster.width <= _rect_end(visible.x, visible.width) {
			if _write_cluster(buffer, column, visible.y, cluster.text, style, cluster.width) {
				written += cluster.width
			}
		}
		column += cluster.width
	}
	return written, true
}

// _write_cluster writes one cluster and resets every cell it overwrites,
// including any wide-cluster partner, so no orphaned half survives.
_write_cluster :: proc(buffer: ^term.Frame_Buffer, x, y: int, grapheme: string, style: term.Style, width: int) -> bool {
	if x < 0 || x >= buffer.columns {
		return false
	}
	if width == 2 && x + 1 >= buffer.columns {
		return false
	}
	row := y * buffer.columns
	for offset in 0 ..< width {
		_clear_cluster(buffer, x + offset, row, style)
	}
	buffer.cells[row + x] = term.Cell {
		grapheme = grapheme,
		style    = style,
		width    = u8(width),
	}
	if width == 2 {
		buffer.cells[row + x + 1] = term.Cell {
			grapheme = "",
			style    = style,
			width    = 0,
		}
	}
	return true
}

// _clear_cluster blanks the cell at x and its wide-cluster partner, if any.
_clear_cluster :: proc(buffer: ^term.Frame_Buffer, x, row: int, style: term.Style) {
	blank := term.Cell {
		grapheme = " ",
		style    = style,
		width    = 1,
	}
	switch buffer.cells[row + x].width {
	case 0:
		if x > 0 {
			buffer.cells[row + x - 1] = blank
		}
	case 2:
		if x + 1 < buffer.columns {
			buffer.cells[row + x + 1] = blank
		}
	case:
	}
	buffer.cells[row + x] = blank
}

// _grid_valid reports whether the cell slice can hold the grid.
_grid_valid :: proc "contextless" (buffer: term.Frame_Buffer) -> bool {
	if buffer.columns < 0 || buffer.rows < 0 {
		return false
	}
	if buffer.columns == 0 || buffer.rows == 0 {
		return len(buffer.cells) == 0
	}
	return buffer.columns <= len(buffer.cells) / buffer.rows
}
