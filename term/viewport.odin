package term

// Viewport is the terminal's current cell-grid dimensions. columns and rows
// are the logical cell size. There is no pixel field in the v1 surface: the
// resize contract is viewport polling only — viewport(session) is
// authoritative and returns the current size, the caller compares it with
// the previous value once per iteration, and a change invalidates
// width-dependent text measurements and forces a complete redraw.
Viewport :: struct {
	columns: int,
	rows:    int,
}
