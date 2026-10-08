package widgets

// Scroll is the vertical position of a viewport over content taller than the
// viewport. range is the number of rows the content exceeds the viewport, as
// layout reports it after solve. top is the first visible row, or nil while the
// view follows the bottom, so content that grows stays in view. The zero value
// follows the bottom with nothing to scroll.
//
// A viewport that never follows, such as a list, keeps a plain row offset and
// uses scroll_reveal.
Scroll :: struct {
	top:   Maybe(int),
	range: int,
}

// scroll_offset returns the first visible row to draw at.
scroll_offset :: proc(scroll: Scroll) -> int {
	return scroll.top.? or_else scroll.range
}

// scroll_to shows the content from row, clamped to at least 0. It follows the
// bottom when row reaches range.
scroll_to :: proc(scroll: ^Scroll, row: int) {
	top := max(row, 0)
	scroll.top = top if top < scroll.range else nil
}

// scroll_by moves the view by delta rows, clamped to [0, range], and reports
// whether the view moved. A false result at a boundary lets the caller pass the
// scroll to an enclosing viewport.
scroll_by :: proc(scroll: ^Scroll, delta: int) -> (moved: bool) {
	current := scroll_offset(scroll^)
	target := clamp(current + delta, 0, scroll.range)
	scroll_to(scroll, target)
	return target != current
}

// scroll_follow returns the view to the bottom.
scroll_follow :: proc(scroll: ^Scroll) {
	scroll.top = nil
}

// scroll_set_range records a new range after layout. A pinned view stays on its
// row while the range grows, and follows the bottom when the content shrank to
// it.
scroll_set_range :: proc(scroll: ^Scroll, range: int) {
	scroll.range = max(range, 0)
	if top, pinned := scroll.top.?; pinned && top >= scroll.range {
		scroll.top = nil
	}
}

// scroll_reveal returns the first visible row for a view of height rows
// currently at top, moved the least that shows rows [first, first + count).
// When the span is taller than the view, it shows the span's first row.
scroll_reveal :: proc(top, height, first: int, count := 1) -> int {
	if first < top || count >= height {
		return first
	}
	return max(top, first + count - height)
}
