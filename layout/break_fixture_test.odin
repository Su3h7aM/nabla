#+test
package layout

import "core:testing"

/*
The ASCII break classifier as a test fixture.

C5 requires layout's own tests to exercise the seam without importing
`nabla:text` (which would make layout depend on text under -test). This
procedure mirrors `text.break_ascii` byte for byte; the geometry the two
produce is cross-checked from `tui`/`widgets`, where both packages are visible.
*/
@(private)
_ascii_break_fixture :: proc(
	user_data: rawptr,
	value: string,
	offset: int,
) -> (
	piece_end: int,
	next_offset: int,
	kind: Text_Break_Kind,
	err: Text_Break_Error,
) {
	index := offset
	for index < len(value) {
		switch value[index] {
		case ' ', '\t', '\r', '\n':
			piece_end = index
			if value[index] == '\n' {
				return piece_end, index + 1, .Mandatory, .None
			}
			if value[index] == '\r' && index + 1 < len(value) && value[index + 1] == '\n' {
				return piece_end, index + 2, .Mandatory, .None
			}
			return piece_end, _ascii_break_fixture_skip(value, index), .Optional, .None
		}
		index += 1
	}
	return len(value), len(value), .None, .None
}

@(private)
_ascii_break_fixture_skip :: proc "contextless" (value: string, offset: int) -> int {
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

@(test)
test_ascii_break_fixture_matches_text_package_contract :: proc(t: ^testing.T) {
	// Spot-check the seam contract on the same strings layout wraps in tests.
	cases := []struct {
		value:     string,
		offset:    int,
		piece_end: int,
		next:      int,
		kind:      Text_Break_Kind,
	} {
		{"aaa bbb", 0, 3, 4, .Optional},
		{"aaa bbb", 4, 7, 7, .None},
		{"aaa\tbbb", 0, 3, 4, .Optional},
		{"aaa\r\nbb", 0, 3, 5, .Mandatory},
		{"aaa\r\nbb", 5, 7, 7, .None},
		{"a\rb", 0, 1, 2, .Optional},
		{"a\rb", 2, 3, 3, .None},
		{"ab\n", 0, 2, 3, .Mandatory},
		{"ab\n", 3, 3, 3, .None},
		{"", 0, 0, 0, .None},
	}
	for test_case in cases {
		piece_end, next, kind, _ := _ascii_break_fixture(nil, test_case.value, test_case.offset)
		testing.expect_value(t, piece_end, test_case.piece_end)
		testing.expect_value(t, next, test_case.next)
		testing.expect_value(t, kind, test_case.kind)
		// Contract: the span is ordered and progresses (or ends the text).
		testing.expect(t, test_case.offset <= piece_end && piece_end <= next && next <= len(test_case.value))
		testing.expect(t, next > test_case.offset || piece_end == len(test_case.value))
	}
}
