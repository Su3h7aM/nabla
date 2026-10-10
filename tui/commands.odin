package tui

import "nabla:layout"
import "nabla:term"
import width_text "nabla:text"

Draw_Error :: enum u8 {
	None,
	Non_Integral_Geometry,
	Allocation_Failed,
	Invalid_Border,
}

// draw_commands paints a solved frame's render commands into buffer in paint
// order. Layout coordinates map to cells with target's origin as the layout
// origin, and nothing is drawn outside target, outside the buffer, or outside a
// command's own clip. A command whose paint is not in paints draws nothing.
//
// Fill_Cmd repeats paint.fill (a space when empty) in paint.style. Border_Cmd
// draws paint.border in paint.style on each edge whose width is positive, with
// a corner where two drawn edges meet. Text_Cmd draws its line in paint.style
// under paint.link; a line the width policy rejects is skipped. Image_Cmd draws
// the placeholder cells of the image handle and, when images is not nil,
// appends the placement it drew; its paint only has to be nonzero. Radius
// is ignored, because a terminal cell cannot be rounded: the border glyph set
// is the paint's choice. Custom_Cmd draws nothing.
//
// An empty border glyph draws as a space. Draw_Error is Non_Integral_Geometry
// when a command or clip is not on the cell grid, Invalid_Border when a border
// glyph is not one cell wide under profile, and Allocation_Failed when images
// could not grow; commands before the failing one stay drawn.
@(require_results)
draw_commands :: proc(
	buffer: ^term.Frame_Buffer,
	paints: []Paint,
	frame_result: layout.Frame_Result,
	target: Cell_Rect,
	images: ^[dynamic]Image_Placement = nil,
	profile: width_text.Width_Profile = width_text.DEFAULT_WIDTH_PROFILE,
) -> Draw_Error {
	if buffer == nil || !_grid_valid(buffer^) {
		return .None
	}
	for command in frame_result.commands {
		bounds, bounds_error := project_rect_integral(command.bounds)
		clip, clip_error := project_rect_integral(layout.clip_of(frame_result, command.clip).rect)
		if bounds_error != .None || clip_error != .None {
			return .Non_Integral_Geometry
		}
		bounds.x += target.x
		bounds.y += target.y
		clip.x += target.x
		clip.y += target.y
		clip = _intersect_rect(clip, target)
		switch data in command.data {
		case layout.Fill_Cmd:
			value, found := paint_of(paints, data.paint)
			fill := value.fill if value.fill != "" else " "
			if found && width_text.cluster_width(fill, profile) == 1 {
				_ = _fill_clipped(buffer, bounds, clip, fill, value.style)
			}
		case layout.Border_Cmd:
			if value, found := paint_of(paints, data.paint); found {
				_draw_border(buffer, bounds, clip, value.border, data.width, value.style, profile) or_return
			}
		case layout.Text_Cmd:
			if value, found := paint_of(paints, data.paint); found {
				_, _ = _draw_text_clipped(buffer, bounds, clip, data.text, value.style, profile, value.link)
			}
		case layout.Image_Cmd:
			id := term.Image_Id(data.handle)
			if _draw_image_clipped(buffer, bounds, clip, id) > 0 && images != nil {
				if _, err := append(images, Image_Placement{id = id, columns = bounds.width, rows = bounds.height}); err != nil {
					return .Allocation_Failed
				}
			}
		case layout.Custom_Cmd:
		}
	}
	return .None
}

@(private)
_border_glyph :: proc(glyph: string, profile: width_text.Width_Profile) -> (cell: string, ok: bool) {
	if glyph == "" {
		return " ", true
	}
	return glyph, width_text.cluster_width(glyph, profile) == 1
}

@(private)
_draw_border :: proc(
	buffer: ^term.Frame_Buffer,
	rect, clip: Cell_Rect,
	border: Border,
	width: layout.Edges,
	style: term.Style,
	profile: width_text.Width_Profile,
) -> Draw_Error {
	top_left, top_left_ok := _border_glyph(border.top_left, profile)
	top_right, top_right_ok := _border_glyph(border.top_right, profile)
	bottom_left, bottom_left_ok := _border_glyph(border.bottom_left, profile)
	bottom_right, bottom_right_ok := _border_glyph(border.bottom_right, profile)
	horizontal, horizontal_ok := _border_glyph(border.horizontal, profile)
	vertical, vertical_ok := _border_glyph(border.vertical, profile)
	if !(top_left_ok && top_right_ok && bottom_left_ok && bottom_right_ok && horizontal_ok && vertical_ok) {
		return .Invalid_Border
	}
	if rect.width <= 0 || rect.height <= 0 {
		return .None
	}
	right := rect.x + rect.width - 1
	bottom := rect.y + rect.height - 1
	top_edge, bottom_edge := width.top > 0, width.bottom > 0
	left_edge, right_edge := width.left > 0, width.right > 0
	if top_edge {
		_ = _fill_clipped(buffer, {rect.x, rect.y, rect.width, 1}, clip, horizontal, style)
	}
	if bottom_edge {
		_ = _fill_clipped(buffer, {rect.x, bottom, rect.width, 1}, clip, horizontal, style)
	}
	if left_edge {
		_ = _fill_clipped(buffer, {rect.x, rect.y, 1, rect.height}, clip, vertical, style)
	}
	if right_edge {
		_ = _fill_clipped(buffer, {right, rect.y, 1, rect.height}, clip, vertical, style)
	}
	if top_edge && left_edge {
		_ = _fill_clipped(buffer, {rect.x, rect.y, 1, 1}, clip, top_left, style)
	}
	if top_edge && right_edge {
		_ = _fill_clipped(buffer, {right, rect.y, 1, 1}, clip, top_right, style)
	}
	if bottom_edge && left_edge {
		_ = _fill_clipped(buffer, {rect.x, bottom, 1, 1}, clip, bottom_left, style)
	}
	if bottom_edge && right_edge {
		_ = _fill_clipped(buffer, {right, bottom, 1, 1}, clip, bottom_right, style)
	}
	return .None
}
