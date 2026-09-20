#+test
#+private file
package text

import "core:testing"

@(test)
test_wrap_prefers_spaces_and_keeps_wide_clusters_whole :: proc(t: ^testing.T) {
	iterator := wrap_iterator_make("hello world", 5)
	first, first_status := wrap_next(&iterator)
	second, second_status := wrap_next(&iterator)
	_, done := wrap_next(&iterator)
	testing.expect_value(t, first_status, Wrap_Status.OK)
	testing.expect_value(t, first, "hello")
	testing.expect_value(t, second_status, Wrap_Status.OK)
	testing.expect_value(t, second, "world")
	testing.expect_value(t, done, Wrap_Status.Done)

	wide := wrap_iterator_make("abcd界x", 5)
	wide_first, _ := wrap_next(&wide)
	wide_second, _ := wrap_next(&wide)
	testing.expect_value(t, wide_first, "abcd")
	testing.expect_value(t, wide_second, "界x")
}

@(test)
test_prefix_covering_columns_stops_on_a_cluster_boundary :: proc(t: ^testing.T) {
	testing.expect_value(t, prefix_covering_columns("a界b", 2), "a界")
	testing.expect_value(t, prefix_covering_columns("a界b", 3), "a界")
	testing.expect_value(t, prefix_covering_columns("a界b", 4), "a界b")
}

@(test)
test_wrap_reports_invalid_text :: proc(t: ^testing.T) {
	reject := Width_Profile {
		invalid_text = .Reject,
		tab_width    = 4,
	}
	iterator := wrap_iterator_make("ok\xff", 8, reject)
	_, status := wrap_next(&iterator)
	testing.expect_value(t, status, Wrap_Status.Invalid_Text)
	_, done := wrap_next(&iterator)
	testing.expect_value(t, done, Wrap_Status.Done)
}
