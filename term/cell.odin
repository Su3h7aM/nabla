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
// Wide rendering is supported through the placeholder rule. present validates
// the grid before writing anything: a width-2 cell must not sit in the last
// column and its placeholder must be the next cell and carry no text. Any
// other width is .Unsupported. The whole frame is written, bottom-right cell
// included, because the session disables autowrap.
Cell :: struct {
	grapheme: string,
	style:    Style,
	width:    u8,
}
