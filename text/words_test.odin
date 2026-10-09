#+test
#+private file
package text

import "core:testing"

@(test)
test_word_offsets_follow_readline_motion :: proc(t: ^testing.T) {
	value := "  foo_1 .. bar  "
	testing.expect_value(t, word_next_offset(value, 0), 7)
	testing.expect_value(t, word_next_offset(value, 7), 10)
	testing.expect_value(t, word_next_offset(value, 10), 14)
	testing.expect_value(t, word_next_offset(value, 14), len(value))
	testing.expect_value(t, word_next_offset(value, len(value)), len(value))
	testing.expect_value(t, word_previous_offset(value, len(value)), 11)
	testing.expect_value(t, word_previous_offset(value, 11), 8)
	testing.expect_value(t, word_previous_offset(value, 8), 2)
	testing.expect_value(t, word_previous_offset(value, 2), 0)
	testing.expect_value(t, word_previous_offset(value, 0), 0)
}

@(test)
test_word_offsets_treat_clusters_as_units :: proc(t: ^testing.T) {
	value := "e\u0301x 界a"
	testing.expect_value(t, word_next_offset(value, 0), len("e\u0301x"))
	testing.expect_value(t, word_next_offset(value, len("e\u0301x")), len(value))
	testing.expect_value(t, word_previous_offset(value, len(value)), len("e\u0301x "))
}
