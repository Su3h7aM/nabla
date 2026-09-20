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

// Block draws a border and title. Layout padding, not the widget, reserves the
// content inset.
Block :: struct {
	border: Border,
	style:  term.Style,
	title:  string,
}

draw_block_rect :: proc(buffer: ^term.Frame_Buffer, rect: tui.Cell_Rect, block: Block) {
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

// draw_block draws around the active layout element's outer box. The element's
// layout padding reserves its content inset; the widget does no layout math.
draw_block_context :: proc(ctx: ^tui.Context, block: Block) {
	rect, _, ok := tui.boxes(ctx)
	if !ok || block.border.horizontal == "" || rect.width < 2 || rect.height < 2 {
		return
	}
	right := rect.x + rect.width - 1
	bottom := rect.y + rect.height - 1
	tui.fill_at(ctx, {x = rect.x, y = rect.y, width = rect.width, height = 1}, block.border.horizontal, block.style)
	tui.fill_at(ctx, {x = rect.x, y = bottom, width = rect.width, height = 1}, block.border.horizontal, block.style)
	tui.fill_at(ctx, {x = rect.x, y = rect.y, width = 1, height = rect.height}, block.border.vertical, block.style)
	tui.fill_at(ctx, {x = right, y = rect.y, width = 1, height = rect.height}, block.border.vertical, block.style)
	_ = tui.put_at(ctx, rect.x, rect.y, block.border.top_left, block.style)
	_ = tui.put_at(ctx, right, rect.y, block.border.top_right, block.style)
	_ = tui.put_at(ctx, rect.x, bottom, block.border.bottom_left, block.style)
	_ = tui.put_at(ctx, right, bottom, block.border.bottom_right, block.style)
	if block.title != "" {
		_, _ = tui.draw_text_at(ctx, {x = rect.x + 1, y = rect.y, width = rect.width - 2, height = 1}, block.title, block.style)
	}
}

draw_block :: proc {
	draw_block_rect,
	draw_block_context,
}
