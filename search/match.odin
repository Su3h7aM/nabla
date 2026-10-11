package search

import "core:unicode"
import "core:unicode/utf8"

// has_upper reports whether text holds an ASCII uppercase letter, which is
// what makes a smart-case pattern case-sensitive.
@(private, require_results)
has_upper :: proc(text: string) -> bool {
	for ch in text {
		if ch >= 'A' && ch <= 'Z' {
			return true
		}
	}
	return false
}

// ascii_fold lowercases one ASCII byte; other bytes pass through.
@(private)
ascii_fold :: #force_inline proc(value: byte) -> byte {
	if value >= 'A' && value <= 'Z' {
		return value + ('a' - 'A')
	}
	return value
}

// fold_rune_equal reports whether two runes match case-insensitively: equal,
// sharing a lowercase or uppercase mapping, or cycling through the same
// Unicode simple-fold orbit. Orbits cross the ASCII boundary: the Kelvin sign
// (U+212A) folds with k, the long s (U+017F) with s, and the dotless i
// (U+0131) and dotted İ (U+0130) with i. A non-ASCII rune can therefore match
// an ASCII one, so comparing ASCII bytes alone is exact only when both texts
// are pure ASCII.
@(private, require_results)
fold_rune_equal :: proc(first, second: rune) -> bool {
	if first == second {
		return true
	}
	if unicode.to_lower(first) == unicode.to_lower(second) {
		return true
	}
	if unicode.to_upper(first) == unicode.to_upper(second) {
		return true
	}
	low, high := first, second
	if high < low {
		low, high = high, low
	}
	if high < utf8.RUNE_SELF {
		return false
	}
	folded := unicode.simple_fold(low)
	for folded != low && folded < high {
		folded = unicode.simple_fold(folded)
	}
	return folded == high
}

// fold_index returns the byte offset of needle in haystack under
// fold_rune_equal, or -1. ASCII byte pairs compare inline with no decoding;
// only a pair with a byte at or above 0x80 pays for rune decoding, so a
// non-ASCII rune still folds against an ASCII one. It starts matches on rune
// boundaries only and allocates nothing.
@(private, require_results)
fold_index :: proc(haystack, needle: string) -> int {
	if len(needle) == 0 {
		return 0
	}
	for i := 0; i < len(haystack); {
		if (haystack[i] & 0xC0) == 0x80 {
			i += 1 // continuation byte, never a match start
			continue
		}
		rest, want := haystack[i:], needle
		matched := true
		for len(want) > 0 {
			if len(rest) == 0 {
				matched = false
				break
			}
			if rest[0] < utf8.RUNE_SELF && want[0] < utf8.RUNE_SELF {
				if ascii_fold(rest[0]) != ascii_fold(want[0]) {
					matched = false
					break
				}
				rest = rest[1:]
				want = want[1:]
			} else {
				have_rune, have_width := utf8.decode_rune_in_string(rest)
				want_rune, want_width := utf8.decode_rune_in_string(want)
				if !fold_rune_equal(have_rune, want_rune) {
					matched = false
					break
				}
				rest = rest[have_width:]
				want = want[want_width:]
			}
		}
		if matched {
			return i
		}
		if haystack[i] < utf8.RUNE_SELF {
			i += 1
		} else {
			_, width := utf8.decode_rune_in_string(haystack[i:])
			i += width
		}
	}
	return -1
}
