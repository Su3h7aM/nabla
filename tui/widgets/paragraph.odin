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
		wrap := _Wrap {
			rest    = line.value,
			width   = width - line.indent,
			profile = profile,
		}
		for {
			if _, ok := _wrap_next(&wrap); !ok {
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
		wrap := _Wrap {
			rest    = line.value,
			width   = width,
			profile = profile,
		}
		for {
			value, ok := _wrap_next(&wrap)
			if !ok {
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
		wrap := _Wrap {
			rest    = line.value,
			width   = width,
			profile = profile,
		}
		for {
			value, has_line := _wrap_next(&wrap)
			if !has_line {
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

_Wrap :: struct {
	rest:    string,
	width:   int,
	profile: text.Width_Profile,
	done:    bool,
}

// _wrap_next yields the next wrapped piece of rest, breaking at the last space
// that fits and hard-breaking a word longer than width.
_wrap_next :: proc(wrap: ^_Wrap) -> (line: string, ok: bool) {
	if wrap.done {
		return "", false
	}
	// A separator at a break is consumed with the line it followed, so a
	// continuation line never starts with the space the previous break left.
	for len(wrap.rest) > 0 && wrap.rest[0] == ' ' {
		wrap.rest = wrap.rest[1:]
	}
	if len(wrap.rest) == 0 {
		wrap.done = true
		return "", true
	}
	if wrap.width <= 0 {
		wrap.done = true
		return "", true
	}

	fitted := 0
	last_space := 0
	columns := 0
	it := text.display_iterator_make(wrap.rest, wrap.profile)
	for {
		cluster, status := text.display_next(&it)
		if status != .OK {
			break
		}
		if columns + cluster.width > wrap.width {
			if columns == 0 {
				fitted = cluster.end
			}
			break
		}
		columns += cluster.width
		fitted = cluster.end
		if cluster.text == " " {
			last_space = cluster.end
		}
	}
	if fitted == 0 {
		wrap.done = true
		return "", true
	}
	if fitted == len(wrap.rest) {
		line = wrap.rest
		wrap.rest = ""
		wrap.done = true
		return line, true
	}

	end := fitted
	next := fitted
	if last_space > 0 {
		end = last_space - 1
		next = last_space
		for next < len(wrap.rest) && wrap.rest[next] == ' ' {
			next += 1
		}
	}
	line = wrap.rest[:end]
	wrap.rest = wrap.rest[next:]
	if len(wrap.rest) == 0 {
		wrap.done = true
	}
	return line, true
}
