package tui

import "nabla:layout"
import "nabla:term"

// A packed color is an index plus one, so each field needs nine bits.
@(private = "file")
FONT_FOREGROUND_SHIFT :: 8
@(private = "file")
FONT_BACKGROUND_SHIFT :: 17
@(private = "file")
FONT_COLOR_MASK :: 0x1ff

// text_style packs a terminal style into a layout.Text_Style, whose font layout
// never interprets. The modifiers go in the low byte, then the indexed
// foreground and background, each stored plus one so zero means no color.
// Default_Color, no color, and RGB_Color are not carried: they unpack as no
// color. The result has size 1, wrap .None, and an opaque black color, because
// layout reads alpha as command visibility and the terminal ignores RGB. Wrap
// is the declaration's choice.
//
// term_style inverts text_style for the modifiers and the indexed colors.
text_style :: proc(style: term.Style) -> layout.Text_Style {
	font := u32(transmute(u8)style.modifiers)
	if index, ok := style.foreground.(term.Indexed_Color); ok {
		font |= (u32(index) + 1) << FONT_FOREGROUND_SHIFT
	}
	if index, ok := style.background.(term.Indexed_Color); ok {
		font |= (u32(index) + 1) << FONT_BACKGROUND_SHIFT
	}
	return layout.Text_Style{size = 1, font = layout.Font(font), wrap = .None, color = layout.Color{0, 0, 0, 255}}
}

// term_style unpacks the modifiers and indexed colors that text_style packed
// into style.font and ignores every other field. A style that did not come
// from text_style yields whatever its font bits spell. For every style whose
// colors are nil or Indexed_Color, term_style(text_style(s)) == s. A color that
// is Default_Color or RGB_Color comes back as nil.
term_style :: proc(style: layout.Text_Style) -> term.Style {
	font := u32(style.font)
	result: term.Style
	result.modifiers = transmute(term.Modifiers)u8(font)
	if foreground := (font >> FONT_FOREGROUND_SHIFT) & FONT_COLOR_MASK; foreground != 0 {
		result.foreground = term.Indexed_Color(foreground - 1)
	}
	if background := (font >> FONT_BACKGROUND_SHIFT) & FONT_COLOR_MASK; background != 0 {
		result.background = term.Indexed_Color(background - 1)
	}
	return result
}
