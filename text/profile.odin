package text

// Invalid_Text_Policy selects what a traversal does with a cluster it cannot
// draw.
Invalid_Text_Policy :: enum u8 {
	Replace, // drop it
	Reject, // fail with Invalid_Text
}

// Emoji_Presentation selects the width of an emoji-presentation sequence, a
// cluster containing VARIATION SELECTOR-16 (U+FE0F) such as "❤️" or "1️⃣".
// core:unicode/utf8 reports one cell for these; most terminals use two, so the
// choice is explicit.
Emoji_Presentation :: enum u8 {
	Core_Width, // one cell, the zero value
	Wide, // two cells
}

// Width_Profile is caller-supplied width policy, never discovered from the
// environment. Width comes from normalized East Asian width plus the emoji
// policy; an Ambiguous character counts narrow. tab_width is in cells, and the
// zero value drops unrepresentable clusters and advances no columns for a tab.
Width_Profile :: struct {
	invalid_text: Invalid_Text_Policy,
	tab_width:    int,
	emoji:        Emoji_Presentation,
}

DEFAULT_WIDTH_PROFILE :: Width_Profile {
	invalid_text = .Replace,
	tab_width    = 4,
	emoji        = .Wide,
}
