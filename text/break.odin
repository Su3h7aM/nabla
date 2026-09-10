package text

// Break_Kind classifies the separator that follows an unbreakable run.
Break_Kind :: enum u8 {
	// No further break: the run ends the text.
	None,
	// The separator is horizontal whitespace; a break may be taken here.
	Optional,
	// The separator is a line terminator (CRLF counted as one); a break must
	// be taken here.
	Mandatory,
}

// break_ascii reports the next unbreakable run in `value` and the separator
// that follows it, starting at `offset`.
//
// `[offset, piece_end)` is the maximal run of bytes that are not a break
// opportunity; `[piece_end, next_offset)` is the separator that follows:
// horizontal whitespace for an Optional break, a line terminator (CRLF as one
// terminator) for a Mandatory break. When the run ends the text,
// `piece_end == next_offset == len(value)` and kind is .None.
//
// Scope: ASCII only, mirroring `measure_ascii`. Whitespace is space, tab and a
// lone carriage return; a CR immediately followed by LF belongs to the
// terminator, which is how CRLF stops glueing an invisible character onto the
// last word of a line.
//
// Contract: `offset <= piece_end <= next_offset <= len(value)`, and progress is
// guaranteed — `next_offset > offset` unless `piece_end == len(value)`.
// Allocation: none; `value` is borrowed and not retained.
break_ascii :: proc "contextless" (value: string, offset: int) -> (piece_end: int, next_offset: int, kind: Break_Kind) {
	index := offset
	for index < len(value) {
		switch value[index] {
		case ' ', '\t', '\r', '\n':
			piece_end = index
			if value[index] == '\n' {
				return piece_end, index + 1, .Mandatory
			}
			if value[index] == '\r' && index + 1 < len(value) && value[index + 1] == '\n' {
				return piece_end, index + 2, .Mandatory
			}
			return piece_end, _skip_break_spaces(value, index), .Optional
		}
		index += 1
	}
	return len(value), len(value), .None
}

// _skip_break_spaces returns the offset just past the run of horizontal
// whitespace starting at `offset`. A CRLF is not whitespace: the run stops
// before it so the next call reports the mandatory terminator.
@(private)
_skip_break_spaces :: proc "contextless" (value: string, offset: int) -> int {
	index := offset
	for index < len(value) {
		switch value[index] {
		case ' ', '\t':
			index += 1
		case '\r':
			if index + 1 < len(value) && value[index + 1] == '\n' {
				return index
			}
			index += 1
		case '\n':
			return index
		case:
			return index
		}
	}
	return index
}
