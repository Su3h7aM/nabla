package tty

Default_Color :: struct {}
Indexed_Color :: distinct u8
RGB_Color :: distinct [3]u8

Color :: union {
	Default_Color,
	Indexed_Color,
	RGB_Color,
}

Modifier :: enum u8 {
	Bold,
	Dim,
	Italic,
	Underline,
	Reverse,
	Strikethrough,
}

Modifiers :: distinct bit_set[Modifier;u8]

Presentation_Style :: struct {
	foreground: Color,
	background: Color,
	modifiers:  Modifiers,
}
