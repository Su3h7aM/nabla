package input

// Key_Code enumerates the normalized keys the parser can produce. The set is
// intentionally minimal: text (Character), the C0 keys, navigation keys, and
// the common function keys.
Key_Code :: enum u8 {
	Character,
	Tab,
	Enter,
	Escape,
	Backspace,
	Up,
	Down,
	Left,
	Right,
	Home,
	End,
	Page_Up,
	Page_Down,
	Insert,
	Delete,
	F1,
	F2,
	F3,
	F4,
	F5,
}

Key_Modifier :: enum u8 {
	Shift,
	Control,
	Alt,
	Super,
}

Key_Modifiers :: distinct bit_set[Key_Modifier;u8]

Key_Event :: struct {
	code:      Key_Code,
	character: rune, // set when code is .Character
	modifiers: Key_Modifiers,
	repeat:    bool,
}

Resize_Event :: struct {
	columns: int,
	rows:    int,
}

// End_Of_Input marks the tty closing (read returning zero). It is a distinct
// event, not an error.
End_Of_Input :: struct {}

// Unknown_Input is emitted for malformed or unsupported byte sequences; the
// parser resynchronizes immediately after. Malformed input is never an error.
Unknown_Input :: struct {}

Event :: union #no_nil {
	Key_Event,
	Resize_Event,
	End_Of_Input,
	Unknown_Input,
}
