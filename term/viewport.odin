package term

// Viewport is the terminal's current cell-grid dimensions. columns and rows
// are the logical cell size. The resize contract is viewport polling only —
// viewport(session) is authoritative and returns the current size, the caller
// compares it with the previous value once per iteration, and a change
// invalidates width-dependent text measurements and forces a complete redraw.
//
// width_pixels and height_pixels are the size of the whole cell area in
// pixels, or zero when the terminal does not report it. Dividing by columns and
// rows gives the cell size, which is what scales an image to a cell placement.
Viewport :: struct {
	columns:       int,
	rows:          int,
	width_pixels:  int,
	height_pixels: int,
}
