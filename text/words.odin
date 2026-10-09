package text

import "core:unicode"
import "core:unicode/utf8"

@(private = "file")
Word_Class :: enum {
	Space,
	Word,
	Other,
}

@(private = "file")
word_class :: proc(grapheme: string) -> Word_Class {
	first, _ := utf8.decode_rune_in_string(grapheme)
	switch {
	case unicode.is_space(first):
		return .Space
	case unicode.is_letter(first), unicode.is_digit(first), first == '_':
		return .Word
	}
	return .Other
}

// word_previous_offset returns the byte offset of the start of the word before
// offset: it skips spaces backward, then a run of graphemes of one class (word
// characters, or anything else). It returns 0 when nothing but spaces precedes
// offset. It does not allocate.
word_previous_offset :: proc(value: string, offset: int) -> int {
	start := 0
	previous := Word_Class.Space
	iterator := grapheme_iterator_make(value)
	for _, cluster in grapheme_iterate(&iterator) {
		if cluster.byte_index >= offset {
			break
		}
		class := word_class(cluster.text)
		if class != .Space && class != previous {
			start = cluster.byte_index
		}
		previous = class
	}
	return start
}

// word_next_offset returns the byte offset just past the word after offset: it
// skips spaces forward, then a run of graphemes of one class. It returns
// len(value) when nothing but spaces follows offset. It does not allocate.
word_next_offset :: proc(value: string, offset: int) -> int {
	if offset >= len(value) {
		return len(value)
	}
	end := len(value)
	run := Word_Class.Space
	from := max(offset, 0)
	iterator := grapheme_iterator_make(value[from:])
	for _, cluster in grapheme_iterate(&iterator) {
		class := word_class(cluster.text)
		if run != .Space && class != run {
			break
		}
		run = class
		end = from + cluster.byte_index + len(cluster.text)
	}
	return end
}
