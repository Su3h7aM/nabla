package tty

// Frame_Buffer is the output of the render pipeline: a cell grid and a
// cursor intent. It is consumed by present and is never retained after the
// call returns.
Frame_Buffer :: struct {
	columns: int,
	rows:    int,
	cells:   []Cell,
}

// Cursor_Intent specifies where the cursor should be placed after the frame.
// An empty union member means unspecified (the frame does not change it).
Cursor_Intent :: union {
	Hide,
	Show,
	Position,
}

// Position puts the cursor at (x, y) after the frame, origin at the
// top-left cell (1-based in the emitted CUP sequence).
Position :: struct {
	x, y: int,
}

Hide :: struct {}
Show :: struct {}
