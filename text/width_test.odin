#+test
#+private file
package text

import "core:testing"

@(test)
test_truncate_text_never_splits_a_cluster :: proc(t: ^testing.T) {
	testing.expect_value(t, truncate_text("café", 3), "caf")
	testing.expect_value(t, truncate_text("café", 4), "café")
	// A wide cluster needs two columns, so it drops rather than splits.
	testing.expect_value(t, truncate_text("a界b", 2), "a")
	testing.expect_value(t, truncate_text("a界b", 3), "a界")
	// A combining cluster is one column.
	testing.expect_value(t, truncate_text("e\u0301x", 1), "e\u0301")
	testing.expect_value(t, truncate_text("abc", 0), "")
}

@(test)
test_truncate_text_keeps_a_tab_only_when_all_its_cells_fit :: proc(t: ^testing.T) {
	profile := Width_Profile {
		tab_width = 4,
	}
	// "a" then a tab to column 4: the tab is three cells.
	testing.expect_value(t, truncate_text("a\tb", 1, profile), "a")
	testing.expect_value(t, truncate_text("a\tb", 1 + 3, profile), "a\t")
	testing.expect_value(t, truncate_text("a\tb", 5, profile), "a\tb")
}

@(test)
test_truncate_text_at_measures_a_tab_from_its_start_column :: proc(t: ^testing.T) {
	profile := Width_Profile {
		tab_width = 4,
	}
	// A tab at column 0 is four cells; the same tab at column 1 is three.
	testing.expect_value(t, truncate_text_at("\t", 4, 0, profile), "\t")
	testing.expect_value(t, truncate_text_at("\t", 3, 0, profile), "")
	testing.expect_value(t, truncate_text_at("\t", 3, 1, profile), "\t")
	testing.expect_value(t, truncate_text_at("\t", 2, 1, profile), "")
	// From column 0 "a\tb" needs five cells and truncates; from column 1 it
	// needs four and fits, which is why a piece's start column matters.
	testing.expect_value(t, truncate_text_at("a\tb", 4, 0, profile), "a\t")
	testing.expect_value(t, truncate_text_at("a\tb", 4, 1, profile), "a\tb")
	testing.expect_value(t, text_columns_at("\tfoo", 1, profile), 3 + 3)
}

@(test)
test_grapheme_offsets_step_by_cluster :: proc(t: ^testing.T) {
	// A base plus a combining mark is one edit unit.
	accent := "e\u0301x"
	cluster := len("e\u0301")
	testing.expect_value(t, next_grapheme_offset(accent, 0), cluster)
	testing.expect_value(t, next_grapheme_offset(accent, cluster), len(accent))
	testing.expect_value(t, prev_grapheme_offset(accent, len(accent)), cluster)
	testing.expect_value(t, prev_grapheme_offset(accent, cluster), 0)

	// A ZWJ emoji sequence is one edit unit, not several code points.
	family := "👩\u200d👩"
	emoji := "👩\u200d👩x"
	testing.expect_value(t, next_grapheme_offset(emoji, 0), len(family))
	testing.expect_value(t, prev_grapheme_offset(emoji, len(family)), 0)
}

@(test)
test_text_columns_counts_cells :: proc(t: ^testing.T) {
	testing.expect_value(t, text_columns("hello"), 5)
	testing.expect_value(t, text_columns("café"), 4) // é is one cell
	testing.expect_value(t, text_columns("e\u0301"), 1) // one cluster
	testing.expect_value(t, text_columns("界"), 2)
	testing.expect_value(t, text_columns("界a"), 3)
	testing.expect_value(t, text_columns(""), 0)
}

@(test)
test_text_columns_at_measures_a_tab_at_its_line_position :: proc(t: ^testing.T) {
	profile := Width_Profile {
		tab_width = 4,
	}
	// A tab at column 0 advances four cells; at column 3 it advances one.
	testing.expect_value(t, text_columns_at("\t", 0, profile), 4)
	testing.expect_value(t, text_columns_at("\t", 3, profile), 1)
	testing.expect_value(t, text_columns_at("\t", 4, profile), 4)
}

@(test)
test_measure_text_counts_cells :: proc(t: ^testing.T) {
	result, err := measure_text("café")
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result, Measure_Result{columns = 4, rows = 1})

	// A combining cluster is one cell and a wide character is two.
	result, err = measure_text("e\u0301界")
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result, Measure_Result{columns = 3, rows = 1})

	// An emoji ZWJ sequence is one cluster (core:unicode/utf8 segmentation).
	result, err = measure_text("👩\u200d👩")
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result, Measure_Result{columns = 2, rows = 1})

	// A tab advances to the next stop under the active profile.
	profile := Width_Profile {
		tab_width = 4,
	}
	result, err = measure_text("a\tb", profile)
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result, Measure_Result{columns = 5, rows = 1})

	// A line break is always rejected; a control follows the policy.
	_, err = measure_text("a\nb")
	testing.expect_value(t, err, Measure_Error.Invalid_Text)
	_, err = measure_text("a\x1b", Width_Profile{tab_width = 4, invalid_text = .Reject})
	testing.expect_value(t, err, Measure_Error.Invalid_Text)
	result, err = measure_text("a\x1b", profile)
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result, Measure_Result{columns = 1, rows = 1})

	// A bound clamps the report.
	result, err = measure_text("abcdef", DEFAULT_WIDTH_PROFILE, 3)
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result, Measure_Result{columns = 3, rows = 1})
}

@(test)
test_measurement_and_column_count_agree_on_the_policy :: proc(t: ^testing.T) {
	// The whole reason display.odin exists: a string that measures N cells is
	// drawn as N cells, and one the policy refuses measures as its drawable
	// prefix.
	values := [?]string{"a\tb", "a\x1b" + "b", "界", "e\u0301", "👩\u200d👩", "❤️", "1️⃣"}
	for value in values {
		measured, err := measure_text(value)
		testing.expect_value(t, err, Measure_Error.None)
		testing.expect_value(t, text_columns(value), measured.columns)
	}

	// A rejected control yields no columns past the prefix.
	reject := Width_Profile {
		tab_width    = 4,
		invalid_text = .Reject,
	}
	_, err := measure_text("ab\x1b", reject)
	testing.expect_value(t, err, Measure_Error.Invalid_Text)
	testing.expect_value(t, text_columns("ab\x1b", reject), 2)
}

@(test)
test_emoji_presentation_is_a_policy :: proc(t: ^testing.T) {
	core := Width_Profile {
		tab_width    = 4,
		emoji        = .Core_Width,
		invalid_text = .Replace,
	}
	wide := Width_Profile {
		tab_width    = 4,
		emoji        = .Wide,
		invalid_text = .Replace,
	}
	// core:unicode/utf8 reports one cell for a VS16 sequence.
	result, err := measure_text("❤️", core)
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result.columns, 1)
	// The display policy counts the two cells most terminals use.
	result, err = measure_text("❤️", wide)
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result.columns, 2)

	// U+FE0E asks for text presentation and never widens.
	result, err = measure_text("\u2764\ufe0e", wide)
	testing.expect_value(t, err, Measure_Error.None)
	testing.expect_value(t, result.columns, 1)

	testing.expect_value(t, cluster_width("❤️", wide), 2)
	testing.expect_value(t, cluster_width("❤️", core), 1)
	testing.expect_value(t, cluster_width("界", wide), 2)
	testing.expect_value(t, cluster_width("a", wide), 1)
	testing.expect_value(t, cluster_width("", wide), 0)
	testing.expect_value(t, cluster_width("a\tb", wide), -1)
	testing.expect_value(t, cluster_width("\x1b", wide), -1)
}

@(test)
test_display_next_refuses_malformed_utf8 :: proc(t: ^testing.T) {
	it := display_iterator_make("a\xffb")
	_, first := display_next(&it)
	testing.expect_value(t, first, Display_Status.OK)
	_, second := display_next(&it)
	testing.expect_value(t, second, Display_Status.Invalid_Text)
}
