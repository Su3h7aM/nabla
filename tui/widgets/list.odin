package widgets

import "nabla:term"
import "nabla:tui"

// List_State is caller-owned list selection: selected is -1 when nothing is
// selected, offset is the index of the first visible item.
List_State :: struct {
	selected: int,
	offset:   int,
}

List :: struct {
	items:          []string,
	style:          term.Style,
	selected_style: term.Style,
}

list_select_next :: proc(state: ^List_State, count: int) {
	switch {
	case count <= 0:
		state.selected = -1
	case state.selected < 0:
		state.selected = 0
	case:
		state.selected = min(state.selected + 1, count - 1)
	}
}

list_select_previous :: proc(state: ^List_State, count: int) {
	switch {
	case count <= 0:
		state.selected = -1
	case state.selected < 0:
		state.selected = count - 1
	case:
		state.selected = max(state.selected - 1, 0)
	}
}

// draw_list draws the visible items into rect, scrolling offset so the selected
// item stays visible, and returns the rows written.
draw_list :: proc(buffer: ^term.Frame_Buffer, rect: tui.Cell_Rect, list: List, state: ^List_State) -> (rows: int) {
	if rect.width <= 0 || rect.height <= 0 {
		return 0
	}
	count := len(list.items)
	if count == 0 {
		state.selected = -1
		state.offset = 0
		return 0
	}
	if state.selected >= count {
		state.selected = count - 1
	}
	state.offset = clamp(state.offset, 0, max(count - rect.height, 0))
	if state.selected >= 0 {
		if state.selected < state.offset {
			state.offset = state.selected
		} else if state.selected >= state.offset + rect.height {
			state.offset = state.selected - rect.height + 1
		}
	}

	visible := min(rect.height, count - state.offset)
	for row in 0 ..< visible {
		index := state.offset + row
		line := tui.Cell_Rect {
			x      = rect.x,
			y      = rect.y + row,
			width  = rect.width,
			height = 1,
		}
		if index == state.selected {
			tui.fill(buffer, line, " ", list.selected_style)
			_, _ = tui.draw_text(buffer, line, list.items[index], list.selected_style)
		} else {
			_, _ = tui.draw_text(buffer, line, list.items[index], list.style)
		}
		rows += 1
	}
	return rows
}
