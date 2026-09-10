package widgets

import "nabla:layout"
import "nabla:tui"

Label :: struct {
	id:    layout.Id,
	text:  string,
	style: tui.Style,
}

// label_desc builds the text descriptor for this label.
//
// Descriptor rather than a wrapper proc on purpose: `layout.text` is a leaf
// declaration, and callers declare it inside whatever scope they hold, so the
// widget hands back a descriptor the caller passes straight to `layout.text`.
label_desc :: proc(label: Label, sizing: layout.Sizing) -> layout.Text_Desc {
	return {id = label.id, text = label.text, sizing = sizing}
}
