package widgets

import "nabla:term"
import "nabla:tui"

Border :: struct {
	top_left, top_right, bottom_left, bottom_right: string,
	horizontal, vertical:                           string,
}

BORDER_SINGLE :: Border {
	top_left     = "┌",
	top_right    = "┐",
	bottom_left  = "└",
	bottom_right = "┘",
	horizontal   = "─",
	vertical     = "│",
}

BORDER_ROUNDED :: Border {
	top_left     = "╭",
	top_right    = "╮",
	bottom_left  = "╰",
	bottom_right = "╯",
	horizontal   = "─",
	vertical     = "│",
}

// Block is a bordered container. A border without glyphs draws nothing left of
// the inner area; title is drawn on the top edge, starting after the corner.
Block :: struct {
	border: Border,
	style:  term.Style,
	title:  string,
}

// block_inner returns the content area inside the border.
block_inner :: proc(rect: tui.Cell_Rect, block: Block) -> tui.Cell_Rect {
	if block.border.horizontal == "" || rect.width < 2 || rect.height < 2 {
		return rect
	}
	return {x = rect.x + 1, y = rect.y + 1, width = rect.width - 2, height = rect.height - 2}
}

draw_block :: proc(buffer: ^term.Frame_Buffer, rect: tui.Cell_Rect, block: Block) {
	if block.border.horizontal == "" || rect.width < 2 || rect.height < 2 {
		return
	}
	right := rect.x + rect.width - 1
	bottom := rect.y + rect.height - 1
	tui.fill(buffer, {x = rect.x, y = rect.y, width = rect.width, height = 1}, block.border.horizontal, block.style)
	tui.fill(buffer, {x = rect.x, y = bottom, width = rect.width, height = 1}, block.border.horizontal, block.style)
	tui.fill(buffer, {x = rect.x, y = rect.y, width = 1, height = rect.height}, block.border.vertical, block.style)
	tui.fill(buffer, {x = right, y = rect.y, width = 1, height = rect.height}, block.border.vertical, block.style)
	_ = tui.put(buffer, rect.x, rect.y, block.border.top_left, block.style)
	_ = tui.put(buffer, right, rect.y, block.border.top_right, block.style)
	_ = tui.put(buffer, rect.x, bottom, block.border.bottom_left, block.style)
	_ = tui.put(buffer, right, bottom, block.border.bottom_right, block.style)
	if block.title != "" {
		_, _ = tui.draw_text(buffer, {x = rect.x + 1, y = rect.y, width = rect.width - 2, height = 1}, block.title, block.style)
	}
}
