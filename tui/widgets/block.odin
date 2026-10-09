package widgets

import "base:runtime"

import "nabla:layout"
import "nabla:term"
import "nabla:tui"

// Block is a border with a title on the top edge and a footer on the bottom edge,
// drawn straight into a frame buffer by draw_block. Both labels start one cell
// inside the corner and are truncated to the room the edge has. Inside a layout
// frame use block instead.
Block :: struct {
	border: tui.Border,
	style:  term.Style,
	title:  string,
	footer: string,
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
	if block.footer != "" {
		_, _ = tui.draw_text(buffer, {x = rect.x + 1, y = bottom, width = rect.width - 2, height = 1}, block.footer, block.style)
	}
}

// Block_Desc describes a box declared by block. The border glyphs and the title
// and footer draw in style. The title and footer start one cell inside their
// corner and are cut at the box's inner width; the caller supplies any spacing
// around them.
Block_Desc :: struct {
	// id names the box, which the title and footer attach to; it must be nonzero
	// when either is set.
	id:     layout.Id,
	user:   layout.User_Tag,
	sizing: layout.Sizing,
	border: tui.Border,
	style:  term.Style,
	title:  string,
	footer: string,
}

// block declares a column box with a one-cell border and, when it returns true,
// opens the scope its children are declared into; the one-cell padding keeps
// them inside the border. tui.draw_commands draws the border. The title and
// footer are overlay elements attached to the box's top-left and bottom-left
// edges. paints receives the entries the box refers to and must outlive the draw
// of the frame's commands.
@(deferred_in_out = block_end)
block :: proc(ctx: ^layout.Context, paints: ^tui.Paints, desc: Block_Desc, loc := #caller_location) -> bool {
	border_paint, _ := tui.paint(paints, tui.Paint{style = desc.style, border = desc.border})
	box := layout.Element_Desc {
		id = desc.id,
		layout = {flow = .Column, sizing = desc.sizing, padding = layout.pad_all(1)},
		paint = {border = {paint = border_paint, width = layout.pad_all(1)}},
		user = desc.user,
	}
	if !layout.element_begin(ctx, box, loc) {
		return false
	}
	label_paint, _ := tui.paint(paints, tui.Paint{style = desc.style})
	_block_label(ctx, desc.id, desc.title, label_paint, .Left_Top, loc)
	_block_label(ctx, desc.id, desc.footer, label_paint, .Left_Bottom, loc)
	return true
}

block_end :: proc(ctx: ^layout.Context, paints: ^tui.Paints, desc: Block_Desc, loc: runtime.Source_Code_Location, entered: bool) {
	if entered {
		layout.element_end(ctx)
	}
}

@(private)
_block_label :: proc(
	ctx: ^layout.Context,
	target: layout.Id,
	label: string,
	paint: layout.Paint,
	point: layout.Attach_Point,
	loc: runtime.Source_Code_Location,
) {
	if label == "" {
		return
	}
	// The overlay is as wide as the box; its padding and clip cut the label to the
	// columns between the corners.
	overlay := layout.Element_Desc {
		layout = {sizing = {layout.grow(), layout.fit()}, padding = {left = 1, right = 1}},
		clip = {axes = {.X}},
		overlay = {attach = .Element, target = target, self_point = point, target_point = point, clip_to = .Attached_Parent},
		hit = .Passthrough,
	}
	if layout.element(ctx, overlay, loc) {
		layout.text(ctx, {text = label, style = {size = 1, wrap = .None}, paint = paint}, loc)
	}
}
