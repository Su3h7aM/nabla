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

// measure_ascii measures a single line of ASCII text under an explicit profile.
//
// Scope: this is deliberately not a Unicode implementation. It walks bytes, not
// runes or grapheme clusters, and `profile.ambiguous_width` is therefore unused
// here -- it exists for the real text implementation to honour.
//
// Non-ASCII input is governed by `profile.invalid_text`:
//   .Reject  -- returns .Invalid_Text. Use this when a wrong width is worse than
//               a failure, which is the honest choice for arbitrary input.
//   .Replace -- counts one cell per *byte*. A multi-byte character therefore
//               measures wider than it renders: an accented "cafe" reports 5
//               cells, not 4. This is a known, bounded inaccuracy of byte-wise
//               measurement, not a width policy, and it disappears when real
//               segmentation replaces this procedure.
//
// Line breaks are always rejected regardless of policy, because this measures one
// line and silently flattening a break would corrupt the caller's text.
//
// Units: `max_columns` and the result are terminal cells. Pass NO_COLUMN_LIMIT
// for unbounded measurement.
// Allocation: none. `value` is borrowed and not retained.
// Errors: .Invalid_Constraint for a negative bound other than NO_COLUMN_LIMIT;
// .Invalid_Text when the profile's policy is .Reject and the input contains a
// byte this procedure cannot represent.
measure_ascii :: proc "contextless" (
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

	columns := 0
	for byte_value in transmute([]byte)value {
		switch {
		case byte_value == '\t':
			// Advance to the next tab stop. A zero tab width consumes no cells.
			if profile.tab_width > 0 {
				columns += profile.tab_width - (columns % profile.tab_width)
			}
		case byte_value == '\n' || byte_value == '\r':
			// Single-line measurement: a line break is never representable here,
			// and replacing it would silently flatten the caller's text.
			return {}, .Invalid_Text
		case byte_value < 0x20 || byte_value == 0x7f || byte_value >= 0x80:
			if profile.invalid_text == .Reject {
				return {}, .Invalid_Text
			}
			columns += 1
		case:
			columns += 1
		}
	}

	if max_columns != NO_COLUMN_LIMIT {
		columns = min(columns, max_columns)
	}
	return {columns = columns, rows = 1}, .None
}
