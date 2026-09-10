#+build linux
package tui

import "nabla:tty"

// presentation_modifier maps one tui modifier to its terminal counterpart.
//
// This is an explicit total mapping rather than a bit-set transmute. The two enums
// are declared independently in different packages, so a reinterpret would depend
// on their variants staying in the same order forever and would corrupt styling
// silently if either package reordered its own enum. Every current tui.Modifier
// variant is mapped above; the trailing fallback is required by Odin's return
// checker and must be extended when a variant is added (a new variant would
// otherwise silently map to .Bold).
presentation_modifier :: proc "contextless" (modifier: Modifier) -> tty.Modifier {
	switch modifier {
	case .Bold:
		return .Bold
	case .Dim:
		return .Dim
	case .Italic:
		return .Italic
	case .Underline:
		return .Underline
	case .Reverse:
		return .Reverse
	case .Strikethrough:
		return .Strikethrough
	}
	return .Bold
}

presentation_modifiers :: proc "contextless" (modifiers: Modifiers) -> tty.Modifiers {
	result: tty.Modifiers
	for modifier in Modifier {
		if modifier in modifiers {
			result += {presentation_modifier(modifier)}
		}
	}
	return result
}

presentation_color :: proc "contextless" (color: Color) -> tty.Color {
	switch value in color {
	case Default_Color:
		return tty.Default_Color{}
	case Indexed_Color:
		return tty.Indexed_Color(value)
	case RGB_Color:
		return tty.RGB_Color(value)
	case nil:
		return nil
	}
	return nil
}

presentation_style :: proc "contextless" (style: Style) -> tty.Presentation_Style {
	return {
		foreground = presentation_color(style.foreground),
		background = presentation_color(style.background),
		modifiers = presentation_modifiers(style.modifiers),
	}
}

// build_frame converts the rendered buffer into a full-redraw terminal
// frame in caller-owned storage.
//
// Ownership: cells are caller-owned storage; grapheme strings are borrowed
// from the logical buffer (they point at the caller's drawn text) and must
// stay valid until the frame is presented. Nothing is retained and nothing
// is allocated.
// Partial progress: none. If the cell storage is too small the call writes
// nothing and returns ok = false, so a failed frame never reaches the
// terminal half-drawn.
@(require_results)
build_frame :: proc(buffer: Cell_Buffer, cells: []tty.Cell) -> (frame: tty.Frame_Buffer, ok: bool) {
	if !_buffer_valid(buffer) {
		return {}, false
	}
	cell_count := 0
	if buffer.width > 0 && buffer.height > 0 {
		cell_count = buffer.width * buffer.height
	}
	if len(cells) < cell_count {
		return {}, false
	}
	for cell, index in buffer.cells[:cell_count] {
		cells[index] = tty.Cell {
			grapheme = cell.grapheme,
			style    = presentation_style(cell.style),
			width    = 1,
		}
	}
	return {columns = buffer.width, rows = buffer.height, cells = cells[:cell_count]}, true
}

_buffer_valid :: proc "contextless" (buffer: Cell_Buffer) -> bool {
	if buffer.width < 0 || buffer.height < 0 {
		return false
	}
	if buffer.width == 0 || buffer.height == 0 {
		return len(buffer.cells) == 0
	}
	if buffer.width > len(buffer.cells) / buffer.height {
		return false
	}
	return buffer.width * buffer.height == len(buffer.cells)
}
