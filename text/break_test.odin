#+test
#+private file
package text

import "core:testing"

@(test)
test_break_ascii_reports_each_run_and_separator :: proc(t: ^testing.T) {
	Case :: struct {
		value:     string,
		offset:    int,
		piece_end: int,
		next:      int,
		kind:      Break_Kind,
	}
	cases := [?]Case {
		// End of text: the run is empty and no break follows.
		{"", 0, 0, 0, .None},
		{"aaa bbb", 4, 7, 7, .None},
		// Horizontal whitespace is an optional separator, and the whole run is
		// skipped so the next call starts at the following word.
		{"aaa bbb", 0, 3, 4, .Optional},
		{"aaa\tbbb", 0, 3, 4, .Optional},
		{"aaa  bbb", 0, 3, 5, .Optional},
		{"a\rb", 0, 1, 2, .Optional},
		// A line terminator is mandatory, with CRLF counted as one terminator.
		{"aaa\nbbb", 0, 3, 4, .Mandatory},
		{"aaa\r\nbb", 0, 3, 5, .Mandatory},
		{"ab\n", 0, 2, 3, .Mandatory},
		{"ab\n", 3, 3, 3, .None},
	}
	for c in cases {
		piece_end, next, kind := break_ascii(c.value, c.offset)
		testing.expect_value(t, piece_end, c.piece_end)
		testing.expect_value(t, next, c.next)
		testing.expect_value(t, kind, c.kind)
		// Contract: the span is ordered and progresses unless it ends the text.
		testing.expect(t, c.offset <= piece_end && piece_end <= next && next <= len(c.value))
		testing.expect(t, next > c.offset || piece_end == len(c.value))
	}
}
