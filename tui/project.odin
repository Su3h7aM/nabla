package tui

import "nabla:layout"

// Cell_Rect is a cell rectangle: origin plus extent, in cells.
Cell_Rect :: struct {
	x:      int,
	y:      int,
	width:  int,
	height: int,
}

Projection_Error :: enum u8 {
	None,
	Non_Integral,
	Negative_Size,
}

// project_rect_integral converts a layout.Rect to cells. It fails when a
// coordinate is not integral or an extent is negative.
project_rect_integral :: proc "contextless" (rect: layout.Rect) -> (result: Cell_Rect, err: Projection_Error) {
	x := int(rect.position[0])
	y := int(rect.position[1])
	width := int(rect.size[0])
	height := int(rect.size[1])
	if layout.Scalar(x) != rect.position[0] ||
	   layout.Scalar(y) != rect.position[1] ||
	   layout.Scalar(width) != rect.size[0] ||
	   layout.Scalar(height) != rect.size[1] {
		return {}, .Non_Integral
	}
	if width < 0 || height < 0 {
		return {}, .Negative_Size
	}
	return {x = x, y = y, width = width, height = height}, .None
}
