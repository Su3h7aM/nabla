package widgets

import "nabla:term"
import "nabla:text"
import "nabla:tui"

// Text_Line is one styled paragraph line. indent is the left inset in cells,
// applied to every wrapped piece of the line.
Text_Line :: struct {
	value:  string,
	style:  term.Style,
	indent: int,
}

// Paragraph is scrollable text: each source line is wrapped to the drawing
// width, and scroll is the number of wrapped rows skipped from the top.
Paragraph :: struct {
	lines:  []Text_Line,
	scroll: int,
}

// paragraph_height reports the wrapped rows lines occupy at width.
paragraph_height :: proc(lines: []Text_Line, width: int, profile: text.Width_Profile = text.DEFAULT_WIDTH_PROFILE) -> int {
	rows := 0
	for line in lines {
		wrap := text.wrap_iterator_make(line.value, width - line.indent, profile)
		for {
			_, status := text.wrap_next(&wrap)
			if status != .OK {
				break
			}
			rows += 1
		}
	}
	return rows
}

// draw_paragraph draws the visible part of paragraph into rect and returns the
// rows written.
draw_paragraph_rect :: proc(
	buffer: ^term.Frame_Buffer,
	rect: tui.Cell_Rect,
	paragraph: Paragraph,
	profile: text.Width_Profile = text.DEFAULT_WIDTH_PROFILE,
) -> (
	rows: int,
) {
	if rect.width <= 0 || rect.height <= 0 {
		return 0
	}
	skipped := 0
	for line in paragraph.lines {
		width := rect.width - line.indent
		wrap := text.wrap_iterator_make(line.value, width, profile)
		for {
			value, status := text.wrap_next(&wrap)
			if status != .OK {
				break
			}
			if skipped < paragraph.scroll {
				skipped += 1
				continue
			}
			if rows >= rect.height {
				return rows
			}
			_, _ = tui.draw_text(buffer, {x = rect.x + line.indent, y = rect.y + rows, width = width, height = 1}, value, line.style, profile)
			rows += 1
		}
	}
	return rows
}

// draw_paragraph draws into the active layout box with the frame's width
// policy.
draw_paragraph_context :: proc(ctx: ^tui.Context, paragraph: Paragraph) -> (rows: int) {
	rect, ok := tui.bounds(ctx)
	if !ok || rect.width <= 0 || rect.height <= 0 {
		return 0
	}
	profile, profile_ok := tui.width_profile(ctx)
	if !profile_ok {
		return 0
	}
	skipped := 0
	for line in paragraph.lines {
		width := rect.width - line.indent
		wrap := text.wrap_iterator_make(line.value, width, profile)
		for {
			value, status := text.wrap_next(&wrap)
			if status != .OK {
				break
			}
			if skipped < paragraph.scroll {
				skipped += 1
				continue
			}
			if rows >= rect.height {
				return rows
			}
			_, _ = tui.draw_text_at(ctx, {x = rect.x + line.indent, y = rect.y + rows, width = width, height = 1}, value, line.style)
			rows += 1
		}
	}
	return rows
}

draw_paragraph :: proc {
	draw_paragraph_rect,
	draw_paragraph_context,
}
