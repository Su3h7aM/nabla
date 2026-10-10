package text

import "core:unicode/utf8"

// Display_Cluster is one drawable unit. text is borrowed from the source, or is
// the static " " a tab expands to; end is the byte offset just past the source
// cluster.
Display_Cluster :: struct {
	text:  string,
	width: int,
	end:   int,
}

Display_Status :: enum u8 {
	OK,
	Done,
	Invalid_Text,
}

// Display_Iterator walks one line of source text under a Width_Profile. A tab
// expands to spaces at the next stop, an undrawable cluster is dropped or
// rejected per the profile, and a line terminator or invalid UTF-8 ends the
// traversal. It borrows value and allocates nothing.
//
// Measurement, truncation, and drawing all run this traversal, so a string that
// measures N columns also draws as N columns.
//
// A printable ASCII byte followed by the end or another ASCII byte is a whole
// one-cell cluster, so it skips the grapheme iterator. offset is the byte where
// the next cluster starts; graphemes is resumed only while its continue_grapheme
// flag says it holds a cluster that starts at offset.
Display_Iterator :: struct {
	graphemes: Grapheme_Iterator,
	profile:   Width_Profile,
	column:    int,
	spaces:    int,
	tab_end:   int,
	offset:    int,
}

display_iterator_make :: proc(value: string, profile: Width_Profile = DEFAULT_WIDTH_PROFILE) -> Display_Iterator {
	return {graphemes = grapheme_iterator_make(value), profile = profile}
}

// display_next returns the next drawable cluster and advances the running
// column. A tab yields one space per cell, so callers only see widths 1 and 2.
@(require_results)
display_next :: proc(iterator: ^Display_Iterator) -> (cluster: Display_Cluster, status: Display_Status) {
	if iterator.spaces > 0 {
		iterator.spaces -= 1
		iterator.column += 1
		return {text = " ", width = 1, end = iterator.tab_end}, .OK
	}
	for {
		value := iterator.graphemes.str
		start := iterator.offset
		if start >= len(value) {
			return {}, .Done
		}
		if byte := value[start]; 0x20 <= byte && byte <= 0x7E && (start + 1 == len(value) || value[start + 1] < utf8.RUNE_SELF) {
			iterator.graphemes.continue_grapheme = false
			iterator.offset = start + 1
			iterator.column += 1
			return {text = value[start:start + 1], width = 1, end = start + 1}, .OK
		}
		if !iterator.graphemes.continue_grapheme {
			iterator.graphemes = {
				str         = value,
				curr_offset = start,
			}
		}
		_, grapheme, ok := grapheme_iterate(&iterator.graphemes)
		if !ok {
			return {}, .Done
		}
		end := grapheme.byte_index + len(grapheme.text)
		iterator.offset = end
		if !utf8.valid_string(grapheme.text) {
			return {}, .Invalid_Text
		}
		code_point, _ := utf8.decode_rune(grapheme.text)
		switch {
		case code_point == '\n' || code_point == '\r':
			return {}, .Invalid_Text
		case code_point == '\t':
			if iterator.profile.tab_width <= 0 {
				continue
			}
			iterator.tab_end = end
			iterator.spaces = iterator.profile.tab_width - (iterator.column % iterator.profile.tab_width) - 1
			iterator.column += 1
			return {text = " ", width = 1, end = end}, .OK
		case grapheme.width == 0:
			if iterator.profile.invalid_text == .Reject {
				return {}, .Invalid_Text
			}
			continue
		case:
			width := grapheme.width
			if width == 1 && iterator.profile.emoji == .Wide && _has_emoji_presentation(grapheme.text) {
				width = 2
			}
			iterator.column += width
			return {text = grapheme.text, width = width, end = end}, .OK
		}
	}
}

// prefix_covering_columns returns the shortest prefix whose drawable width is
// at least columns, rounded to a grapheme boundary. Invalid text returns the
// whole value.
prefix_covering_columns :: proc(value: string, columns: int, profile: Width_Profile = DEFAULT_WIDTH_PROFILE) -> string {
	if columns <= 0 {
		return ""
	}
	covered := 0
	iterator := display_iterator_make(value, profile)
	for {
		cluster, status := display_next(&iterator)
		if status != .OK {
			return value
		}
		covered += cluster.width
		if covered >= columns {
			return value[:cluster.end]
		}
	}
}

// cluster_width returns grapheme's display width: 0 for the empty placeholder,
// 1 or 2 for exactly one drawable cluster, and -1 otherwise.
cluster_width :: proc(grapheme: string, profile: Width_Profile = DEFAULT_WIDTH_PROFILE) -> int {
	if grapheme == "" {
		return 0
	}
	iterator := display_iterator_make(grapheme, profile)
	cluster, status := display_next(&iterator)
	if status != .OK || cluster.text != grapheme || cluster.end != len(grapheme) {
		return -1
	}
	if _, next := display_next(&iterator); next != .Done {
		return -1
	}
	return cluster.width
}

// _has_emoji_presentation reports whether the cluster contains VARIATION
// SELECTOR-16. U+FE0E requests text presentation and does not widen.
@(require_results)
_has_emoji_presentation :: proc(value: string) -> bool {
	for i := 0; i < len(value); {
		code_point, size := utf8.decode_rune(value[i:])
		if code_point == 0xFE0F {
			return true
		}
		i += size
	}
	return false
}
