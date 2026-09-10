#+test
package text

import "core:testing"

@(test)
test_ascii_measures_one_cell_per_character :: proc(t: ^testing.T) {
	result, err := measure_ascii("hello")
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result, Measure_Result{columns = 5, rows = 1})
}

@(test)
test_empty_text_measures_one_row :: proc(t: ^testing.T) {
	// An empty string still occupies a line: reporting zero rows would let a
	// caller collapse a line that the terminal will still advance past.
	result, err := measure_ascii("")
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result, Measure_Result{columns = 0, rows = 1})
}

@(test)
test_tab_advances_to_the_next_stop :: proc(t: ^testing.T) {
	profile := DEFAULT_WIDTH_PROFILE
	profile.tab_width = 4
	Case :: struct {
		value:    string,
		expected: int,
	}
	cases := [?]Case{{"\t", 4}, {"a\t", 4}, {"abc\t", 4}, {"abcd\t", 8}, {"\t\t", 8}}
	for test_case in cases {
		result, err := measure_ascii(test_case.value, profile)
		testing.expect_value(t, err, Measure_Error.None)
		testing.expect_value(t, result.columns, test_case.expected)
	}
}

@(test)
test_zero_tab_width_consumes_no_cells :: proc(t: ^testing.T) {
	profile := DEFAULT_WIDTH_PROFILE
	profile.tab_width = 0
	result, err := measure_ascii("a\tb", profile)
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result.columns, 2)
}

@(test)
test_negative_tab_width_is_an_invalid_constraint :: proc(t: ^testing.T) {
	profile := DEFAULT_WIDTH_PROFILE
	profile.tab_width = -1
	_, err := measure_ascii("a", profile)
	testing.expect_value(t, err, Measure_Error.Invalid_Constraint)
}

@(test)
test_line_breaks_are_rejected_under_every_policy :: proc(t: ^testing.T) {
	for policy in Invalid_Text_Policy {
		profile := DEFAULT_WIDTH_PROFILE
		profile.invalid_text = policy
		for value in ([?]string{"a\nb", "a\rb"}) {
			_, err := measure_ascii(value, profile)
			testing.expect_value(t, err, Measure_Error.Invalid_Text)
		}
	}
}

@(test)
test_reject_policy_refuses_non_ascii :: proc(t: ^testing.T) {
	profile := DEFAULT_WIDTH_PROFILE
	profile.invalid_text = .Reject
	_, err := measure_ascii("café", profile)
	testing.expect_value(t, err, Measure_Error.Invalid_Text)
}

@(test)
test_replace_policy_counts_bytes_not_runes :: proc(t: ^testing.T) {
	// Documented, bounded inaccuracy of byte-wise measurement: "café" is four
	// runes but five bytes. This test pins the behaviour so that replacing this
	// procedure with real segmentation is a visible, deliberate change.
	profile := DEFAULT_WIDTH_PROFILE
	profile.invalid_text = .Replace
	result, err := measure_ascii("café", profile)
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result.columns, 5)
}

@(test)
test_column_limit_truncates_the_report :: proc(t: ^testing.T) {
	result, err := measure_ascii("hello world", DEFAULT_WIDTH_PROFILE, 5)
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result.columns, 5)
}

@(test)
test_column_limit_above_the_text_is_inert :: proc(t: ^testing.T) {
	result, err := measure_ascii("hello", DEFAULT_WIDTH_PROFILE, 40)
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result.columns, 5)
}

@(test)
test_zero_column_limit_is_legal :: proc(t: ^testing.T) {
	result, err := measure_ascii("hello", DEFAULT_WIDTH_PROFILE, 0)
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result.columns, 0)
}

@(test)
test_negative_column_limit_is_an_invalid_constraint :: proc(t: ^testing.T) {
	_, err := measure_ascii("hello", DEFAULT_WIDTH_PROFILE, -2)
	testing.expect_value(t, err, Measure_Error.Invalid_Constraint)
}

@(test)
test_unbounded_sentinel_is_not_a_constraint_error :: proc(t: ^testing.T) {
	result, err := measure_ascii("hello", DEFAULT_WIDTH_PROFILE, NO_COLUMN_LIMIT)
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result.columns, 5)
}

@(test)
test_measurement_is_pure :: proc(t: ^testing.T) {
	first, first_err := measure_ascii("deterministic")
	second, second_err := measure_ascii("deterministic")
	testing.expect_value(t, first_err, second_err)
	testing.expect_value(t, first, second)
}
