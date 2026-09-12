package text

Measure_Error :: enum u8 {
	None,
	Invalid_Text,
	Invalid_Constraint,
}

// Measure_Result reports terminal cells, not bytes or runes.
Measure_Result :: struct {
	columns: int,
	rows:    int,
}

// NO_COLUMN_LIMIT requests measurement without an upper column bound.
NO_COLUMN_LIMIT :: -1

// measure_text measures a single line of text under profile: a combining
// cluster is one cell, an East Asian wide character is two, a tab advances to
// the next stop, and an emoji-presentation sequence follows the profile's
// Emoji_Presentation policy. It is the error-reporting view of the traversal
// in display.odin, so it agrees with drawing and truncation cell for cell.
//
// A line break is always rejected: this measures one line. A cluster the
// policy cannot draw follows profile.invalid_text — .Reject returns
// .Invalid_Text, .Replace contributes no cell. Invalid UTF-8 is always
// .Invalid_Text.
//
// Allocation: none; value is borrowed and not retained.
// Errors: .Invalid_Constraint for a negative bound other than NO_COLUMN_LIMIT
// or a negative tab width.
measure_text :: proc(
	value: string,
	profile: Width_Profile = DEFAULT_WIDTH_PROFILE,
	max_columns: int = NO_COLUMN_LIMIT,
) -> (
	result: Measure_Result,
	err: Measure_Error,
) {
	if max_columns < 0 && max_columns != NO_COLUMN_LIMIT {
		return {}, .Invalid_Constraint
	}
	if profile.tab_width < 0 {
		return {}, .Invalid_Constraint
	}

	it := display_iterator_make(value, profile)
	for {
		_, status := display_next(&it)
		switch status {
		case .OK:
		case .Done:
			columns := it.column
			if max_columns != NO_COLUMN_LIMIT {
				columns = min(columns, max_columns)
			}
			return {columns = columns, rows = 1}, .None
		case .Invalid_Text:
			return {}, .Invalid_Text
		}
	}
}
