package term

// Cell is a grapheme at a board position. grapheme holds the full cluster
// (UTF-8); width is its display width (1 or 2).
//
// Contract for wide graphemes: a width-2 grapheme occupies two physical
// columns but is stored as ONE cell. The serialization indexes one entry per
// physical column, so a width-2 cell must be followed in the grid by a
// zero-width placeholder cell (width = 0); present emits its style but no
// text, which keeps span style continuity.
//
// Wide rendering is not implemented: present rejects any frame containing a
// cell with width != 1 (.Unsupported) before writing anything, which
// keeps the corner reservation an exact physical-cell contract — a width-2
// cell at columns - 2 would otherwise span the reserved bottom-right cell
// and could trigger autowrap scroll. The placeholder rule lands with wide
// rendering.
Cell :: struct {
	grapheme: string,
	style:    Presentation_Style,
	width:    u8,
}
