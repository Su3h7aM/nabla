package tui

import "nabla:term"

// Image_Placement is an image at a size in cells.
Image_Placement :: struct {
	id:      term.Image_Id,
	columns: int,
	rows:    int,
}

// draw_image_rect fills rect with the placeholder cells of the image id, in the shape
// term.graphics_place gave it, and returns the cells written. The first cell of each row
// names column 0, so a rect whose left edge is clipped draws nothing; rows past
// term.GRAPHICS_MAX_ROWS are left alone.
draw_image_rect :: proc(buffer: ^term.Frame_Buffer, rect: Cell_Rect, id: term.Image_Id) -> (written: int) {
	if buffer == nil || !_grid_valid(buffer^) {
		return 0
	}
	return _draw_image_clipped(buffer, rect, Cell_Rect{width = buffer.columns, height = buffer.rows}, id)
}

// draw_image_context fills the active scope's bounds with the image id, clipped to the scope.
draw_image_context :: proc(ctx: ^Context, id: term.Image_Id) -> int {
	if ctx == nil || !ctx._frame_open || ctx._error != .None {
		return 0
	}
	scope := ctx._current
	return _draw_image_clipped(&ctx._buffer, scope.bounds, scope.clip, id)
}

// draw_image_at fills an absolute cell rectangle with the image id, clipped to the active scope.
draw_image_at :: proc(ctx: ^Context, rect: Cell_Rect, id: term.Image_Id) -> int {
	if ctx == nil || !ctx._frame_open || ctx._error != .None {
		return 0
	}
	scope := ctx._current
	return _draw_image_clipped(&ctx._buffer, rect, _intersect_rect(scope.bounds, scope.clip), id)
}

draw_image :: proc {
	draw_image_rect,
	draw_image_context,
}

@(private)
_draw_image_clipped :: proc(buffer: ^term.Frame_Buffer, rect, clip: Cell_Rect, id: term.Image_Id) -> (written: int) {
	if id <= 0 || id >= term.IMAGE_ID_LIMIT {
		return 0
	}
	visible := _intersect_rect(clip_to_buffer(buffer^, rect), clip)
	if visible.width <= 0 || visible.height <= 0 || visible.x != rect.x {
		return 0
	}
	style := term.Style {
		foreground = term.RGB_Color{u8(id >> 16), u8(id >> 8), u8(id)},
	}
	for row in visible.y ..< min(_rect_end(visible.y, visible.height), rect.y + term.GRAPHICS_MAX_ROWS) {
		first := term.graphics_placeholder_rows[row - rect.y]
		for column in visible.x ..< _rect_end(visible.x, visible.width) {
			// Width 1 is stated, not measured: text.cluster_width drops the combining marks the first cell carries.
			if _write_cluster(buffer, column, row, first if column == rect.x else term.GRAPHICS_PLACEHOLDER, style, 1) {
				written += 1
			}
		}
	}
	return written
}
