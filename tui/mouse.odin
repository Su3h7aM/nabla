package tui

import "nabla:layout"

// rect_contains reports whether the cell at x, y is inside rect.
@(require_results)
rect_contains :: proc "contextless" (rect: Cell_Rect, x, y: int) -> bool {
	return x >= rect.x && y >= rect.y && x < rect.x + rect.width && y < rect.y + rect.height
}

// layout_point returns the point for layout's hit queries when the frame was solved in
// the coordinates of the area drawn at rect and the cell at x, y is the pointer. Layout
// rectangles are half-open, so the cell's origin is inside exactly the nodes that cover
// the cell, which the cell's centre would also select for whole-cell rectangles.
@(require_results)
layout_point :: proc "contextless" (rect: Cell_Rect, x, y: int) -> layout.Vec2 {
	return {layout.Scalar(x - rect.x), layout.Scalar(y - rect.y)}
}
