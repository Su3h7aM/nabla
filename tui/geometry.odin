package tui

@(private)
_rect_end :: proc "contextless" (origin, extent: int) -> int {
	if extent <= 0 {
		return origin
	}
	if origin > max(int) - extent {
		return max(int)
	}
	return origin + extent
}

@(private)
_intersect_rect :: proc "contextless" (left, right: Cell_Rect) -> Cell_Rect {
	x := max(left.x, right.x)
	y := max(left.y, right.y)
	x_end := min(_rect_end(left.x, left.width), _rect_end(right.x, right.width))
	y_end := min(_rect_end(left.y, left.height), _rect_end(right.y, right.height))
	if left.width <= 0 || left.height <= 0 || right.width <= 0 || right.height <= 0 || x_end <= x || y_end <= y {
		return {}
	}
	return {x = x, y = y, width = x_end - x, height = y_end - y}
}

// rows splits area top to bottom, cols left to right. A positive size is a
// cell count, a negative size is a grow child sharing the leftover; the
// remainder goes to the last grow child. The call is all-or-nothing: it returns
// false and writes nothing when out is shorter than sizes, either axis is
// negative, or the fixed sizes do not fit.
@(require_results)
rows :: proc(area: Cell_Rect, heights: []int, out: []Cell_Rect) -> bool {
	return _split(area, heights, out, true)
}

@(require_results)
cols :: proc(area: Cell_Rect, widths: []int, out: []Cell_Rect) -> bool {
	return _split(area, widths, out, false)
}

_split :: proc(area: Cell_Rect, sizes: []int, out: []Cell_Rect, vertical: bool) -> bool {
	if len(out) < len(sizes) || area.width < 0 || area.height < 0 {
		return false
	}
	extent := area.width
	if vertical {
		extent = area.height
	}

	fixed := 0
	grows := 0
	for size in sizes {
		if size < 0 {
			grows += 1
		} else {
			if size > extent - fixed {
				return false
			}
			fixed += size
		}
	}
	grow_size := 0
	if grows > 0 {
		grow_size = (extent - fixed) / grows
	}

	position := 0
	remaining_grows := grows
	fixed_remaining := fixed
	for size, index in sizes {
		length := size
		if size >= 0 {
			fixed_remaining -= size
		} else {
			remaining_grows -= 1
			length = grow_size
			if remaining_grows == 0 {
				length = extent - position - fixed_remaining
			}
		}
		if vertical {
			out[index] = Cell_Rect {
				x      = area.x,
				y      = area.y + position,
				width  = area.width,
				height = length,
			}
		} else {
			out[index] = Cell_Rect {
				x      = area.x + position,
				y      = area.y,
				width  = length,
				height = area.height,
			}
		}
		position += length
	}
	return true
}
