package text

import "core:unicode/utf8"

// The Unicode width and grapheme-cluster rules live in core. The iterator and
// Grapheme come from core:unicode/utf8, whose UAX#29 implementation already
// handles emoji ZWJ sequences, regional-indicator flags, Hangul syllables,
// Indic conjuncts, spacing marks, prepend and extend classes, and CRLF, and
// whose Grapheme.width is the cluster's monospace cell width from normalized
// East Asian width. These aliases keep the text vocabulary so callers do not
// import core:unicode/utf8 directly.
//
// Width and drawability decisions live in display.odin; this file is the
// column arithmetic over that traversal.

Grapheme :: utf8.Grapheme
Grapheme_Iterator :: utf8.Grapheme_Iterator
grapheme_iterator_make :: utf8.decode_grapheme_iterator_make
grapheme_iterate :: utf8.decode_grapheme_iterate

// text_columns reports the terminal cells value occupies on one line when
// drawn from column 0 under profile. It reports the drawable prefix: a cluster
// the policy cannot draw ends the count, exactly as it ends drawing.
text_columns :: proc(value: string, profile: Width_Profile = DEFAULT_WIDTH_PROFILE) -> int {
	return text_columns_at(value, 0, profile)
}

// text_columns_at is text_columns for text that starts at start_column: a tab
// advances to the next stop measured from there, so a caller assembling a line
// one word at a time gets the columns drawing will produce.
text_columns_at :: proc(value: string, start_column: int, profile: Width_Profile = DEFAULT_WIDTH_PROFILE) -> int {
	it := display_iterator_make(value, profile)
	it.column = start_column
	for {
		_, status := display_next(&it)
		if status != .OK {
			return it.column - start_column
		}
	}
}

// truncate_text returns the longest prefix of value that fits in max_columns
// cells under profile. The result never splits a grapheme cluster and never
// occupies more than max_columns, so it is always drawable as-is.
truncate_text :: proc(value: string, max_columns: int, profile: Width_Profile = DEFAULT_WIDTH_PROFILE) -> string {
	return truncate_text_at(value, max_columns, 0, profile)
}

// truncate_text_at is truncate_text for text that starts at start_column: a
// tab advances to the next stop measured from there, so a caller assembling a
// line one piece at a time gets the prefix drawing will fit.
truncate_text_at :: proc(value: string, max_columns, start_column: int, profile: Width_Profile = DEFAULT_WIDTH_PROFILE) -> string {
	if max_columns <= 0 {
		return ""
	}
	start := max(start_column, 0)
	it := display_iterator_make(value, profile)
	it.column = start
	columns := 0
	result := 0
	for {
		cluster, status := display_next(&it)
		if status != .OK {
			break
		}
		if columns + cluster.width > max_columns {
			break
		}
		columns += cluster.width
		if it.spaces > 0 {
			// Mid-expansion: a tab is a valid prefix only once all its cells
			// fit, so do not commit its offset yet.
			continue
		}
		result = cluster.end
	}
	return value[:result]
}

// next_grapheme_offset returns the byte offset just past the grapheme cluster
// containing offset, or len(value) when offset is at or past the end. A cursor
// can move by clusters without splitting an accented letter or an emoji.
next_grapheme_offset :: proc(value: string, offset: int) -> int {
	if offset >= len(value) {
		return len(value)
	}
	it := grapheme_iterator_make(value)
	for _, cluster in grapheme_iterate(&it) {
		end := cluster.byte_index + len(cluster.text)
		if end > offset {
			return end
		}
	}
	return len(value)
}

// prev_grapheme_offset returns the byte offset of the start of the grapheme
// cluster containing offset, or 0 when offset is at or before the start.
prev_grapheme_offset :: proc(value: string, offset: int) -> int {
	if offset <= 0 {
		return 0
	}
	previous := 0
	it := grapheme_iterator_make(value)
	for _, cluster in grapheme_iterate(&it) {
		if cluster.byte_index + len(cluster.text) >= offset {
			return cluster.byte_index
		}
		previous = cluster.byte_index
	}
	return previous
}
