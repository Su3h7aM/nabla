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

// Mouse_Button names which control produced a mouse report: the three
// physical buttons button-event tracking reports, plus the four wheel
// directions of the SGR protocol's 64..67 block.
Mouse_Button :: enum u8 {
	Left,
	Middle,
	Right,
	Wheel_Up,
	Wheel_Down,
	Wheel_Left,
	Wheel_Right,
}

// Mouse_Event is one SGR mouse report (DECSET 1002 + 1006). x and y are the
// cell coordinates as the protocol sends them, 1-based. release marks a
// button release and motion a drag report; wheel reports carry neither.
Mouse_Event :: struct {
	button:  Mouse_Button,
	x, y:    int,
	release: bool,
	motion:  bool,
}

// Paste is one bracketed paste (DECSET 2004), emitted when the parser sees
// CSI 200 ~ … CSI 201 ~. `text` owns its bytes: it is the only event payload
// that allocates, and the caller releases the whole event list with
// events_clear or events_destroy (or deletes the text individually). Every
// other event is a plain value.
//
// A paste past PASTE_LIMIT is discarded and reported as Unknown_Input rather
// than arriving truncated: the caller can tell an oversized paste from a
// keypress, and no event ever carries a silently shortened body.
Paste :: struct {
	text: string,
}

// End_Of_Input marks the tty closing (read returning zero). It is a distinct
// event, not an error.
End_Of_Input :: struct {}

// Unknown_Input is emitted for malformed or unsupported byte sequences; the
// parser resynchronizes immediately after. An oversized paste (past
// PASTE_LIMIT) is reported this way too, since its content is discarded rather
// than delivered. Malformed input is never an error.
Unknown_Input :: struct {}

Event :: union #no_nil {
	Key_Event,
	Resize_Event,
	Mouse_Event,
	Paste,
	End_Of_Input,
	Unknown_Input,
}

// events_clear releases every owned event payload and empties the list for
// reuse. `allocator` must be the one the events were produced with. Only Paste
// owns memory today.
events_clear :: proc(events: ^[dynamic]Event, allocator := context.allocator) {
	for event in events^ {
		if paste, ok := event.(Paste); ok && paste.text != "" {
			delete(paste.text, allocator)
		}
	}
	clear(events)
}

// events_destroy releases every owned event payload and the list itself.
events_destroy :: proc(events: ^[dynamic]Event, allocator := context.allocator) {
	events_clear(events, allocator)
	delete(events^)
}
