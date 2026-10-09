package widgets

import "nabla:term"
import "nabla:tui"

// Scrollbar_Thumb is the thumb's extent along a track, in cells.
Scrollbar_Thumb :: struct {
	start:  int,
	length: int,
}

// Scrollbar styles and glyphs a vertical bar. An empty glyph draws nothing.
Scrollbar :: struct {
	track_style: term.Style,
	thumb_style: term.Style,
	track_glyph: string,
	thumb_glyph: string,
}

// scrollbar_thumb places the thumb on a track of track cells for a viewport of
// viewport rows over content rows, scrolled to offset. The thumb is zero when
// the content fits or the track is empty. Otherwise it is proportional to the
// viewport, at least one cell, and reaches the end of the track exactly when
// offset is content - viewport. offset is clamped to that range.
scrollbar_thumb :: proc(track, content, viewport, offset: int) -> Scrollbar_Thumb {
	if track <= 0 || viewport <= 0 || content <= viewport {
		return {}
	}
	length := clamp((viewport * track + content / 2) / content, 1, track)
	range := content - viewport
	start := (clamp(offset, 0, range) * (track - length) + range / 2) / range
	return {start = start, length = length}
}

// draw_scrollbar draws a vertical bar down the first column of rect: the track
// over its full height and the thumb for the scrolled position over it.
draw_scrollbar :: proc(buffer: ^term.Frame_Buffer, rect: tui.Cell_Rect, content, viewport, offset: int, scrollbar: Scrollbar) {
	if rect.width <= 0 || rect.height <= 0 {
		return
	}
	thumb := scrollbar_thumb(rect.height, content, viewport, offset)
	for row in 0 ..< rect.height {
		if row >= thumb.start && row < thumb.start + thumb.length {
			_ = tui.put(buffer, rect.x, rect.y + row, scrollbar.thumb_glyph, scrollbar.thumb_style)
		} else {
			_ = tui.put(buffer, rect.x, rect.y + row, scrollbar.track_glyph, scrollbar.track_style)
		}
	}
}
