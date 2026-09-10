#+test
package text

import "core:testing"

@(test)
test_break_ascii_reports_optional_whitespace_separator :: proc(t: ^testing.T) {
	piece_end, next, kind := break_ascii("aaa bbb", 0)
	testing.expect_value(t, piece_end, 3)
	testing.expect_value(t, next, 4)
	testing.expect_value(t, kind, Break_Kind.Optional)
}

@(test)
test_break_ascii_reports_end_of_text :: proc(t: ^testing.T) {
	piece_end, next, kind := break_ascii("aaa bbb", 4)
	testing.expect_value(t, piece_end, 7)
	testing.expect_value(t, next, 7)
	testing.expect_value(t, kind, Break_Kind.None)
}

@(test)
test_break_ascii_reports_hard_break_at_newline :: proc(t: ^testing.T) {
	piece_end, next, kind := break_ascii("aaa\nbbb", 0)
	testing.expect_value(t, piece_end, 3)
	testing.expect_value(t, next, 4)
	testing.expect_value(t, kind, Break_Kind.Mandatory)
}

@(test)
test_break_ascii_collapses_crlf_into_one_separator :: proc(t: ^testing.T) {
	// A CR immediately before an LF belongs to the terminator, not to the last
	// word of the line.
	piece_end, next, kind := break_ascii("aaa\r\nbbb", 0)
	testing.expect_value(t, piece_end, 3)
	testing.expect_value(t, next, 5)
	testing.expect_value(t, kind, Break_Kind.Mandatory)
}

@(test)
test_break_ascii_lone_carriage_return_is_whitespace :: proc(t: ^testing.T) {
	piece_end, next, kind := break_ascii("a\rb", 0)
	testing.expect_value(t, piece_end, 1)
	testing.expect_value(t, next, 2)
	testing.expect_value(t, kind, Break_Kind.Optional)
}

@(test)
test_break_ascii_tab_is_whitespace :: proc(t: ^testing.T) {
	piece_end, next, kind := break_ascii("aaa\tbbb", 0)
	testing.expect_value(t, piece_end, 3)
	testing.expect_value(t, next, 4)
	testing.expect_value(t, kind, Break_Kind.Optional)
}

@(test)
test_break_ascii_empty_input_ends_immediately :: proc(t: ^testing.T) {
	piece_end, next, kind := break_ascii("", 0)
	testing.expect_value(t, piece_end, 0)
	testing.expect_value(t, next, 0)
	testing.expect_value(t, kind, Break_Kind.None)
}

@(test)
test_break_ascii_trailing_newline_yields_an_empty_break :: proc(t: ^testing.T) {
	piece_end, next, kind := break_ascii("ab\n", 0)
	testing.expect_value(t, piece_end, 2)
	testing.expect_value(t, next, 3)
	testing.expect_value(t, kind, Break_Kind.Mandatory)
	// The remainder is the empty run that closes the final empty segment.
	piece_end, next, kind = break_ascii("ab\n", 3)
	testing.expect_value(t, piece_end, 3)
	testing.expect_value(t, next, 3)
	testing.expect_value(t, kind, Break_Kind.None)
}

@(test)
test_break_ascii_skips_a_full_whitespace_run :: proc(t: ^testing.T) {
	piece_end, next, kind := break_ascii("aaa  bbb", 0)
	testing.expect_value(t, piece_end, 3)
	testing.expect_value(t, next, 5)
	testing.expect_value(t, kind, Break_Kind.Optional)
}

@(test)
test_break_ascii_breaks_at_the_given_offset :: proc(t: ^testing.T) {
	piece_end, next, kind := break_ascii("abc def", 4)
	testing.expect_value(t, piece_end, 7)
	testing.expect_value(t, next, 7)
	testing.expect_value(t, kind, Break_Kind.None)
}
