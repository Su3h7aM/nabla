#+build linux
package main

// The pending-steer component: the messages typed while a turn runs that have not reached
// the model, drawn as a rounded box directly above the prompt box. A steering line waits for
// the worker to deliver it at a settled point of the turn; a follow-up waits for the turn to
// end. Both are queues of the same shape, copied once per frame, so a delivery and an edit
// both show on the next frame.
//
// A message is selected with Alt+Up and Alt+Down or a click, and Enter edits it in place:
// the prompt shows its text until Enter saves it back to the same place in its queue or
// Escape leaves it as it was. The prompt's own draft waits aside while it is edited.

import "core:fmt"
import "core:strings"

import "nabla:agent"
import input "nabla:input"
import "nabla:text"
import "nabla:tui"
import "nabla:tui/widgets"

STEER_HINT :: " alt+↑ select · click select, again expand "
STEER_HINT_SELECTED :: " alt+↑↓ select · enter edit · esc unselect "
STEER_HINT_EDITING :: " enter save · esc cancel "
STEER_KIND :: "steer    "
FOLLOW_UP_KIND :: "follow-up"
STEER_EDITING_KIND :: "editing  "
STEER_MARKER :: "> "
// STEER_CHROME_ROWS is the box's top and bottom border.
STEER_CHROME_ROWS :: 2
// STEER_MIN_ROWS is the smallest component worth drawing: one message and the borders.
STEER_MIN_ROWS :: STEER_CHROME_ROWS + 1
// STEER_INSET is the columns the rows keep from each side of the box, which puts them
// under the prompt's own text.
STEER_INSET :: 2
// STEER_LEAD_COLUMNS is what precedes a message's text: the selection marker, the kind
// and a space.
STEER_LEAD_COLUMNS :: len(STEER_MARKER) + len(STEER_KIND) + 1

// Steer_Key names one queued message for as long as it is queued. Each queue numbers its own
// entries, so the key also says which queue the id belongs to.
Steer_Key :: struct {
	id:        u64,
	follow_up: bool,
}

Steer_Line :: struct {
	key:      Steer_Key,
	text:     string, // owned by the runtime allocator
	expanded: bool,
}

// Steer_View is the front-end thread's copy of the queues: the queued steering lines
// followed by the follow-ups as of the last frame, and the user's selection and edit.
Steer_View :: struct {
	lines:    [dynamic]Steer_Line, // owned by the runtime allocator
	selected: Maybe(Steer_Key),
	// editing is set while the prompt holds the text of the selected message, and draft is
	// what the prompt held before, set aside until the edit ends. The queue holds the
	// message back meanwhile.
	editing:  bool,
	draft:    string, // owned by the runtime allocator
	// top is the first body row shown when the component is shorter than its rows.
	top:      int,
}

// Steer_Row is one drawn body row and the queued line it belongs to. The kind label is
// set on a message's first row only.
Steer_Row :: struct {
	kind: string,
	text: string,
	line: int,
}

steer_view_destroy :: proc(app: ^App) {
	steer_lines_destroy(app.steer.lines)
	delete(app.steer.draft, app.run.alloc)
	app.steer = {}
}

steer_lines_destroy :: proc(lines: [dynamic]Steer_Line) {
	for line in lines { delete(line.text, lines.allocator) }
	delete(lines)
}

// steer_queue_of returns the queue that holds the message key names.
steer_queue_of :: proc(app: ^App, key: Steer_Key) -> ^agent.Steer_Queue {
	return &app.run.follow_ups if key.follow_up else &app.run.steer
}

// steer_editing returns the message whose text the prompt holds.
steer_editing :: proc(view: Steer_View) -> (key: Steer_Key, ok: bool) {
	key, ok = view.selected.?
	return key, ok && view.editing
}

// steer_line_index returns where the message with key is in the view.
steer_line_index :: proc(view: Steer_View, key: Steer_Key) -> (index: int, found: bool) {
	for line, position in view.lines {
		if line.key == key { return position, true }
	}
	return 0, false
}

// steer_view_sync replaces the view with the queues as they are now. A message keeps its
// expanded and selected state while it stays queued. When a queue cannot be copied, the
// previous view stays.
steer_view_sync :: proc(app: ^App) {
	view := &app.steer
	steering, steering_ok := agent.steer_snapshot(&app.run.steer, app.run.alloc)
	if !steering_ok { return }
	follow_ups, follow_ups_ok := agent.steer_snapshot(&app.run.follow_ups, app.run.alloc)
	lines, lines_error := make([dynamic]Steer_Line, 0, len(steering) + len(follow_ups), app.run.alloc)
	if !follow_ups_ok || lines_error != nil {
		agent.steer_snapshot_destroy(steering)
		agent.steer_snapshot_destroy(follow_ups)
		return
	}
	// The capacity covers every message, so these appends cannot allocate. Each text moves
	// from its snapshot to the view.
	for entry in steering { _, _ = append(&lines, Steer_Line{key = {id = entry.id}, text = entry.text}) }
	for entry in follow_ups { _, _ = append(&lines, Steer_Line{key = {id = entry.id, follow_up = true}, text = entry.text}) }
	delete(steering)
	delete(follow_ups)
	for &line in lines {
		if index, found := steer_line_index(view^, line.key); found { line.expanded = view.lines[index].expanded }
	}
	if key, selected := view.selected.?; selected {
		if _, found := steer_line_index({lines = lines}, key); !found { view.selected = nil }
	}
	steer_lines_destroy(view.lines)
	view.lines = lines
	if len(lines) == 0 { view.top = 0 }
}

// steer_body returns the body rows for a text width: one truncated row for each collapsed
// message, and the whole wrapped text for an expanded one. Rows are in temporary memory.
steer_body :: proc(view: Steer_View, width: int) -> []Steer_Row {
	rows := make([dynamic]Steer_Row, context.temp_allocator)
	text_width := max(width - STEER_LEAD_COLUMNS, 1)
	for line, index in view.lines {
		kind := FOLLOW_UP_KIND if line.key.follow_up else STEER_KIND
		if key, editing := steer_editing(view); editing && key == line.key { kind = STEER_EDITING_KIND }
		if !line.expanded {
			first := line.text
			if split := strings.index_byte(first, '\n'); split >= 0 { first = first[:split] }
			if text.text_columns(first) > text_width {
				first = strings.concatenate({text.truncate_text(first, text_width - 1), "…"}, context.temp_allocator) or_else ""
			}
			_, _ = append(&rows, Steer_Row{kind = kind, text = first, line = index})
			continue
		}
		remaining := line.text
		for paragraph in strings.split_iterator(&remaining, "\n") {
			wrap := text.wrap_iterator_make(paragraph, text_width)
			for {
				wrapped, status := text.wrap_next(&wrap)
				if status != .OK { break }
				_, _ = append(&rows, Steer_Row{kind = kind, text = wrapped, line = index})
				kind = ""
			}
		}
	}
	return rows[:]
}

// steer_height is the rows the component takes for queued lines whose body is body_rows
// tall. The component never takes more than limit rows, and a limit too small for a line
// hides it. A body taller than the component scrolls.
steer_height :: proc(queued, body_rows, limit: int) -> int {
	if queued == 0 || limit < STEER_MIN_ROWS { return 0 }
	return min(body_rows + STEER_CHROME_ROWS, limit)
}

// draw_steer draws the box, its title and key hint, and the visible body rows into rect.
// The box uses the prompt box's border; the selected message is marked and bold, the way
// a menu marks its selection.
draw_steer :: proc(app: ^App, storage: ^Frame_Storage, rect: tui.Cell_Rect, body: []Steer_Row) {
	if rect.height < STEER_MIN_ROWS || rect.width <= 2 * STEER_INSET { return }
	buffer := &storage.screen.buffer
	widgets.draw_block(buffer, rect, widgets.Block{border = tui.BORDER_ROUNDED, style = RULE_STYLE})
	inner_width := rect.width - 2 * STEER_INSET
	edge := tui.Cell_Rect {
		x      = rect.x + STEER_INSET,
		y      = rect.y,
		height = 1,
	}
	title := fmt.tprintf(" Queued · %d ", len(app.steer.lines))
	edge.width = min(text.text_columns(title), inner_width)
	_, _ = tui.draw_text(buffer, edge, title, TITLE_STYLE)
	hint := STEER_HINT
	if app.steer.editing {
		hint = STEER_HINT_EDITING
	} else if app.steer.selected != nil {
		hint = STEER_HINT_SELECTED
	}
	edge.y = rect.y + rect.height - 1
	edge.width = min(text.text_columns(hint), inner_width)
	_, _ = tui.draw_text(buffer, edge, hint, HINT_STYLE)

	visible := rect.height - STEER_CHROME_ROWS
	app.steer.top = clamp(app.steer.top, 0, max(len(body) - visible, 0))
	row := tui.Cell_Rect {
		x      = rect.x + STEER_INSET,
		width  = inner_width,
		height = 1,
	}
	selected, has_selected := app.steer.selected.?
	for shown in 0 ..< min(visible, len(body) - app.steer.top) {
		row.y = rect.y + 1 + shown
		shown_row := body[app.steer.top + shown]
		picked := has_selected && app.steer.lines[shown_row.line].key == selected
		text_style := PICKED_STYLE if picked else HINT_STYLE
		marker := STEER_MARKER if picked && shown_row.kind != "" else "  "
		lead := strings.concatenate({marker, shown_row.kind}, context.temp_allocator) or_else ""
		_, _ = tui.draw_text(buffer, row, lead, LABEL_STYLE)
		text_row := row
		text_row.x += STEER_LEAD_COLUMNS
		text_row.width -= STEER_LEAD_COLUMNS
		if text_row.width > 0 { _, _ = tui.draw_text(buffer, text_row, shown_row.text, text_style) }
	}
}

// steer_press selects the queued message under a left press, or toggles its expansion when
// it is the selected one, and reports whether the press was on the component, which then
// takes it. While a message is edited the selection stays on it.
steer_press :: proc(app: ^App, mouse: input.Mouse_Event) -> bool {
	rect := app.steer_rect
	if mouse.motion || mouse.release || !tui.rect_contains(rect, mouse.x, mouse.y) { return false }
	row := mouse.y - rect.y - 1
	body := steer_body(app.steer, rect.width - 2 * STEER_INSET)
	index := app.steer.top + row
	if row >= 0 && row < rect.height - STEER_CHROME_ROWS && index < len(body) {
		line := &app.steer.lines[body[index].line]
		if selected, has_selected := app.steer.selected.?; has_selected && selected == line.key {
			line.expanded = !line.expanded
		} else if !app.steer.editing {
			app.steer.selected = line.key
		}
	}
	return true
}

// steer_wheel scrolls the component's body when the pointer is over it and reports whether it was.
steer_wheel :: proc(app: ^App, mouse: input.Mouse_Event, delta: int) -> bool {
	if !tui.rect_contains(app.steer_rect, mouse.x, mouse.y) { return false }
	app.steer.top = max(app.steer.top + delta, 0)
	return true
}

// steer_select moves the selection by delta messages, clamped to the queue, and scrolls the
// component to show it. With nothing selected, moving up selects the last message and
// moving down does nothing. The selection stays put while a message is edited.
steer_select :: proc(app: ^App, delta: int) {
	steer_view_sync(app)
	view := &app.steer
	if len(view.lines) == 0 || view.editing { return }
	index := len(view.lines) - 1
	if key, selected := view.selected.?; selected {
		position, found := steer_line_index(view^, key)
		if found { index = clamp(position + delta, 0, len(view.lines) - 1) }
	} else if delta > 0 {
		return
	}
	view.selected = view.lines[index].key
	visible := max(app.steer_rect.height - STEER_CHROME_ROWS, 1)
	body := steer_body(view^, app.steer_rect.width - 2 * STEER_INSET)
	for row, position in body {
		if row.line != index { continue }
		view.top = clamp(view.top, position - visible + 1, position)
		return
	}
}

// steer_escape ends what the user is doing in the component and reports whether there was
// anything: an edit is cancelled, else the selection is cleared.
steer_escape :: proc(app: ^App) -> bool {
	if app.steer.editing {
		steer_edit_cancel(app)
		return true
	}
	if app.steer.selected != nil {
		app.steer.selected = nil
		return true
	}
	return false
}

// steer_enter handles Enter for the component and reports whether it did: with a message
// selected it starts editing it, and while one is edited it saves the edit.
steer_enter :: proc(app: ^App) -> bool {
	if app.steer.editing {
		steer_edit_commit(app, force = false)
		return true
	}
	if app.steer.selected == nil { return false }
	steer_edit_begin(app)
	return true
}

// steer_edit_begin loads the selected message into the prompt, setting the prompt's draft
// aside, and holds the message in its queue so the session leaves it alone. A steering
// line the session delivered meanwhile is no longer the user's to edit, and a notice says so.
steer_edit_begin :: proc(app: ^App) {
	view := &app.steer
	key, selected := view.selected.?
	if !selected { return }
	queue := steer_queue_of(app, key)
	message, held := agent.steer_hold(queue, key.id)
	if !held {
		view.selected = nil
		snap_append(app, .Notice, "that message was already delivered to the model")
		return
	}
	defer agent.steer_line_free(queue, message)
	draft, draft_error := strings.clone(widgets.input_text(&app.input), app.run.alloc)
	if draft_error != nil || widgets.input_replace(&app.input, message) != nil {
		delete(draft, app.run.alloc)
		agent.steer_unhold(queue, key.id)
		snap_append(app, .Warning, "the message could not be moved to the prompt; it stays queued")
		return
	}
	completion_reset(app)
	widgets.history_reset(&app.history)
	view.draft, view.editing = draft, true
}

// steer_edit_commit saves the prompt's text as the edited message, in its place in the queue,
// and gives the prompt its draft back. An empty text removes the message. A text the
// message cannot take, or a message that is gone, leaves the text in the prompt in front of
// the draft with a warning, so nothing is lost. Unless force is set, a text that reads as a
// command is refused and the edit goes on.
steer_edit_commit :: proc(app: ^App, force: bool) {
	key, editing := steer_editing(app.steer)
	if !editing { return }
	expanded, expand_error := widgets.input_expanded(&app.input, app.run.alloc)
	if expand_error != nil {
		snap_append(app, .Warning, "the prompt could not be prepared; the edit goes on")
		return
	}
	defer delete(expanded, app.run.alloc)
	edited := strings.trim_space(expanded)
	if !force && command_shaped(edited) {
		snap_append(app, .Notice, "a command cannot be queued; it runs when sent")
		return
	}
	queue := steer_queue_of(app, key)
	saved := agent.steer_release(queue, key.id, edited)
	if !saved { agent.steer_unhold(queue, key.id) }
	steer_edit_restore(app)
	if saved { return }
	if edited != "" && !steer_prepend(app, {edited}) {
		snap_append(app, .Warning, "that message could not be updated, and the edited text could not be put in the prompt")
		return
	}
	snap_append(app, .Warning, "that message could not be updated; the edited text is in the prompt")
}

// steer_edit_cancel leaves the edited message as it was and gives the prompt its draft back.
steer_edit_cancel :: proc(app: ^App) {
	key, editing := steer_editing(app.steer)
	if !editing { return }
	agent.steer_unhold(steer_queue_of(app, key), key.id)
	steer_edit_restore(app)
}

// steer_edit_finish ends an edit the user left open, because the turn ended: the text is
// saved as the message, and failing that the edit is cancelled.
steer_edit_finish :: proc(app: ^App) {
	steer_edit_commit(app, force = true)
	steer_edit_cancel(app)
}

// steer_edit_restore puts the draft back in the prompt and ends the edit and the selection.
steer_edit_restore :: proc(app: ^App) {
	view := &app.steer
	if widgets.input_replace(&app.input, view.draft) != nil { snap_append(app, .Warning, "the prompt's draft could not be restored") }
	delete(view.draft, app.run.alloc)
	view.draft, view.editing, view.selected = "", false, nil
	completion_reset(app)
	widgets.history_reset(&app.history)
}

// steer_retrieve takes every message still queued, steering lines first and then follow-ups,
// and puts them, separated by a blank line, in front of what the prompt holds, with the
// caret after them. A line the session already accepted is no longer queued and stays where
// it is. Nothing happens when nothing is queued.
steer_retrieve :: proc(app: ^App) {
	queues := [2]^agent.Steer_Queue{&app.run.steer, &app.run.follow_ups}
	taken: [2][dynamic]string
	messages := make([dynamic]string, context.temp_allocator)
	ok := true
	for queue, index in queues {
		taken[index], ok = agent.steer_take_all(queue)
		if !ok { break }
		if _, append_error := append(&messages, ..taken[index][:]); append_error != nil {
			ok = false
			break
		}
	}
	if ok && (len(messages) == 0 || steer_prepend(app, messages[:])) {
		for queue, index in queues { agent.steer_taken_destroy(queue, taken[index]) }
		return
	}
	// The prompt could not take them, so they go back to their queues in their order.
	for queue, index in queues {
		if !agent.steer_requeue(queue, taken[index]) { snap_append(app, .Warning, "a queued line could not be kept") }
	}
	snap_append(app, .Warning, "the queued lines could not be moved to the prompt; they stay queued")
}

// steer_turn_ended decides what the messages queued during a turn become when it ends. A
// turn the user stopped sends nothing: everything queued goes back to the prompt. Otherwise
// the steering lines the turn never accepted are sent together as the next prompt, and
// with none of those the first follow-up is, so the rest wait for the next turn's end.
steer_turn_ended :: proc(app: ^App) {
	steer_edit_finish(app)
	if app.turn_stopped {
		app.turn_stopped = false
		steer_retrieve(app)
		return
	}
	taken, taken_ok := agent.steer_take_all(&app.run.steer)
	if !taken_ok {
		snap_append(app, .Warning, "input queued during that turn could not be sent")
		return
	}
	if len(taken) > 0 {
		joined, join_error := strings.join(taken[:], "\n\n", context.temp_allocator)
		if join_error != nil {
			if !agent.steer_requeue(&app.run.steer, taken) { snap_append(app, .Warning, "a queued line could not be kept") }
			snap_append(app, .Warning, "input queued during that turn could not be sent; it stays queued")
			return
		}
		agent.steer_taken_destroy(&app.run.steer, taken)
		transcript_jump_bottom(app)
		enqueue(app, .Prompt, joined)
		return
	}
	delete(taken)
	line, popped := agent.steer_pop(&app.run.follow_ups)
	if !popped { return }
	defer agent.steer_line_free(&app.run.follow_ups, line)
	transcript_jump_bottom(app)
	enqueue(app, .Prompt, line)
}

// steer_prepend inserts lines before the prompt's text, with a blank line between them
// and that text, and leaves the caret after the inserted block. False means the prompt is unchanged.
steer_prepend :: proc(app: ^App, lines: []string) -> bool {
	block, join_error := strings.join(lines, "\n\n", context.temp_allocator)
	if join_error != nil { return false }
	if widgets.input_text(&app.input) != "" {
		block, join_error = strings.concatenate({block, "\n\n"}, context.temp_allocator)
		if join_error != nil { return false }
	}
	_ = widgets.input_move_text_start(&app.input)
	if widgets.input_insert(&app.input, block) != nil { return false }
	completion_reset(app)
	// What the prompt holds is a draft now, not a recalled entry.
	widgets.history_reset(&app.history)
	return true
}
