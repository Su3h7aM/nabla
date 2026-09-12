package term

// Frame_Buffer is the output of the render pipeline: a cell grid and a
// cursor intent. It is consumed by present and is never retained after the
// call returns.
Frame_Buffer :: struct {
	columns: int,
	rows:    int,
	cells:   []Cell,
}

// Cursor is the desired cursor state after a frame. Visibility and position
// are independent pieces of state, so they are two fields rather than a union
// of mutually exclusive commands: a frame can place the caret and show it,
// place it while hidden, or change only visibility.
//
// The zero value hides the cursor where the frame writer left it (the
// bottom-right cell). That is the safe default for a full-frame redraw: an
// interactive application sets visible and placed when it wants an editing
// caret.
Cursor :: struct {
	visible:  bool,
	position: Position,
	// placed moves the cursor to position; when false the cursor stays where
	// the last written cell left it.
	placed:   bool,
}

// Position is a zero-based cell coordinate, origin at the top-left. The
// encoder emits it 1-based in a CUP sequence.
Position :: struct {
	x, y: int,
}
