package term

// Frame_Buffer is the output of the render pipeline: a cell grid and a
// cursor intent. It is consumed by present and is never retained after the
// call returns.
Frame_Buffer :: struct {
	columns: int,
	rows:    int,
	cells:   []Cell,
	// links are the hyperlink destinations cells refer to: Link_Id n is links[n - 1].
	// They are borrowed for the call to present. A URI with a byte outside printable
	// ASCII, or an id past the table, is written as plain cells without a hyperlink.
	links:   []string,
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
	// shape is the DECSCUSR cursor style; .Default leaves the terminal's own
	// style untouched.
	shape:    Cursor_Shape,
	position: Position,
	// placed moves the cursor to position; when false the cursor stays where
	// the last written cell left it.
	placed:   bool,
}

// Cursor_Shape is a DECSCUSR style. The values are the sequence parameters.
Cursor_Shape :: enum u8 {
	Default,
	Block_Blink,
	Block,
	Underline_Blink,
	Underline,
	Beam_Blink,
	Beam,
}

// Position is a zero-based cell coordinate, origin at the top-left. The
// encoder emits it 1-based in a CUP sequence.
Position :: struct {
	x, y: int,
}
