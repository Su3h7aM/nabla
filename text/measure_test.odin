#+test
#+private file
package text

import "core:testing"

@(test)
test_measure_ascii_counts_cells_per_line :: proc(t: ^testing.T) {
	// One cell per ASCII byte, and an empty line still occupies a row.
	result, err := measure_ascii("hello")
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result, Measure_Result{columns = 5, rows = 1})

	result, err = measure_ascii("")
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result, Measure_Result{columns = 0, rows = 1})
}

@(test)
test_measure_ascii_tab_stops :: proc(t: ^testing.T) {
	// A tab advances to the next multiple of the profile's tab width.
	profile := DEFAULT_WIDTH_PROFILE
	profile.tab_width = 4
	Case :: struct {
		value:   string,
		columns: int,
	}
	for c in ([?]Case{{"\t", 4}, {"a\t", 4}, {"abc\t", 4}, {"abcd\t", 8}, {"\t\t", 8}}) {
		result, err := measure_ascii(c.value, profile)
		testing.expect_value(t, err, Measure_Error.None)
		testing.expect_value(t, result.columns, c.columns)
	}
	// A zero tab width consumes no cells.
	profile.tab_width = 0
	result, err := measure_ascii("a\tb", profile)
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result.columns, 2)
}

@(test)
test_measure_ascii_column_limit :: proc(t: ^testing.T) {
	// A finite limit truncates the report; a limit above the text is inert and
	// zero is legal.
	result, err := measure_ascii("hello world", DEFAULT_WIDTH_PROFILE, 5)
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result.columns, 5)

	result, err = measure_ascii("hello", DEFAULT_WIDTH_PROFILE, 40)
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result.columns, 5)

	result, err = measure_ascii("hello", DEFAULT_WIDTH_PROFILE, 0)
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result.columns, 0)
}

@(test)
test_measure_ascii_invalid_constraints :: proc(t: ^testing.T) {
	// The unbounded sentinel is not a constraint error, but any other negative
	// bound is, as is a negative tab width.
	result, err := measure_ascii("hello", DEFAULT_WIDTH_PROFILE, NO_COLUMN_LIMIT)
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result.columns, 5)

	_, err = measure_ascii("hello", DEFAULT_WIDTH_PROFILE, -2)
	testing.expect_value(t, err, Measure_Error.Invalid_Constraint)

	bad_profile := DEFAULT_WIDTH_PROFILE
	bad_profile.tab_width = -1
	_, err = measure_ascii("a", bad_profile)
	testing.expect_value(t, err, Measure_Error.Invalid_Constraint)
}

@(test)
test_measure_ascii_invalid_text_policy :: proc(t: ^testing.T) {
	// A line break is rejected under every policy: this measures one line, and
	// flattening a break would corrupt the caller's text.
	for policy in Invalid_Text_Policy {
		profile := DEFAULT_WIDTH_PROFILE
		profile.invalid_text = policy
		for value in ([?]string{"a\nb", "a\rb"}) {
			_, err := measure_ascii(value, profile)
			testing.expect_value(t, err, Measure_Error.Invalid_Text)
		}
	}

	// Non-ASCII is rejected or counted one cell per byte, the documented bounded
	// inaccuracy of byte-wise measurement: "café" is four runes but five bytes.
	reject := DEFAULT_WIDTH_PROFILE
	reject.invalid_text = .Reject
	_, err := measure_ascii("café", reject)
	testing.expect_value(t, err, Measure_Error.Invalid_Text)

	replace := DEFAULT_WIDTH_PROFILE
	replace.invalid_text = .Replace
	result, replace_err := measure_ascii("café", replace)
	testing.expect_value(t, replace_err, Measure_Error.None)
	testing.expect_value(t, result.columns, 5)
}
