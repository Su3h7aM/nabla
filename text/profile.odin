package text

Ambiguous_Width :: enum u8 {
	Narrow,
	Wide,
}

// Invalid_Text_Policy selects what a measurement does with input it cannot
// represent under the active profile. It is named for the policy, not for the
// condition, so it does not collide with Measure_Error.Invalid_Text.
Invalid_Text_Policy :: enum u8 {
	Replace,
	Reject,
}

// Width_Profile is caller-supplied data. This package never discovers it from
// the environment, the locale, or a terminal; the application selects it, using
// terminal capabilities as an input if it wishes, and passes it in explicitly.
//
// Units: `tab_width` is a count of terminal cells.
Width_Profile :: struct {
	ambiguous_width: Ambiguous_Width,
	invalid_text:    Invalid_Text_Policy,
	tab_width:       int,
}

DEFAULT_WIDTH_PROFILE :: Width_Profile {
	ambiguous_width = .Narrow,
	invalid_text    = .Replace,
	tab_width       = 4,
}
