#+build linux
package main

import "core:fmt"
import "core:strings"
import "core:sync"

import "nabla:agent"
import input "nabla:input"
import "nabla:layout"
import "nabla:term"
import "nabla:text"
import "nabla:tui"
import "nabla:tui/widgets"

// --- input handling -------------------------------------------------------

// Command_Id names what a slash command does. The id is what dispatch switches
// on; everything else about a command lives in its table row.
Command_Id :: enum {
	Quit,
	Help,
	New_Session,
	Resume,
	Compact,
	Status,
	Effort,
	Model,
}

// Command is one slash command. name is what the user types, summary is what /help says
// about it, and open_menu shows the list its argument is chosen from, nil when it takes
// no argument. The table is the only place a command is declared, so completion, help,
// and dispatch cannot disagree.
Command :: struct {
	id:        Command_Id,
	name:      string,
	summary:   string,
	open_menu: proc(app: ^App),
}

@(rodata)
COMMANDS := [?]Command {
	Command{id = .Quit, name = "/quit", summary = "exit; during a turn, cancel it first"},
	Command{id = .Help, name = "/help", summary = "list the commands"},
	Command{id = .New_Session, name = "/new", summary = "start a new session"},
	Command{id = .Resume, name = "/resume", summary = "choose a session to resume", open_menu = menu_open_session},
	Command{id = .Compact, name = "/compact", summary = "summarize the active context now"},
	Command{id = .Status, name = "/status", summary = "show the session, model, and context"},
	Command{id = .Effort, name = "/effort", summary = "choose a reasoning effort level", open_menu = menu_open_effort},
	Command{id = .Model, name = "/model", summary = "choose a provider and model", open_menu = menu_open_model},
}

// command_find looks a command up by its exact name, ignoring case.
@(require_results)
command_find :: proc(name: string) -> (Command, bool) {
	for command in COMMANDS {
		if strings.equal_fold(command.name, name) { return command, true }
	}
	return {}, false
}

command_split :: proc(text: string) -> (name, argument: string) {
	trimmed := strings.trim_space(text)
	space := strings.index_byte(trimmed, ' ')
	if space < 0 { return trimmed, "" }
	return trimmed[:space], strings.trim_space(trimmed[space + 1:])
}

// command_shaped reports whether text starts with a slash and a word of letters, digits, '-' or '_'; such a word is a command, known or not.
@(require_results)
command_shaped :: proc(text: string) -> bool {
	name, _ := command_split(text)
	if len(name) < 2 || name[0] != '/' { return false }
	for character in name[1:] {
		switch character {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_':
		case:
			return false
		}
	}
	return true
}

// command_prefixed reports whether the typed text is a prefix of a command,
// ignoring case so a capital is a typo rather than a miss.
@(require_results)
command_prefixed :: proc(command, typed: string) -> bool {
	if len(typed) > len(command) { return false }
	return strings.equal_fold(command[:len(typed)], typed)
}

// complete_command advances the slash command at the prompt. Tab cycles: the first press
// reaches the first match of what is typed and the next moves to the one after it,
// wrapping around. A completed name whose command takes a list opens that list. Matching
// ignores case; the command's own lowercase name is written back.
complete_command :: proc(app: ^App) -> (handled: bool) {
	typed := widgets.input_text(&app.input)
	if !strings.has_prefix(typed, "/") || strings.contains_rune(typed, ' ') {
		completion_reset(app)
		return false
	}

	// A second Tab still refers to the prefix the cycle began with, because the
	// input now holds the name the previous press wrote.
	query := typed
	after := -1
	if app.completion_active {
		query = app.completion_query
		after = app.completion_index
	}

	index, found := command_next_match(query, after)
	if !found {
		completion_reset(app)
		return false
	}
	command := COMMANDS[index]
	if !app.completion_active && query == command.name {
		completion_reset(app)
		if command.open_menu != nil { command.open_menu(app) }
		return true
	}

	// The query is stored only when a cycle begins, because the stored copy is
	// what a later press reads and the input buffer is what it was taken from.
	if !app.completion_active { completion_query_set(app, typed) }
	app.completion_index = index
	app.completion_active = true
	prompt_clear(app)
	if widgets.input_insert(&app.input, command.name) != nil {
		snap_append(app, .Warning, "the completed command could not be written into the prompt")
	}
	return true
}

// command_next_match finds the next command after `after` whose name starts with
// query, wrapping around. -1 starts at the beginning.
@(require_results)
command_next_match :: proc(query: string, after: int) -> (int, bool) {
	for offset in 1 ..= len(COMMANDS) {
		index := (after + offset) % len(COMMANDS)
		if command_prefixed(COMMANDS[index].name, query) { return index, true }
	}
	return 0, false
}

// completion_reset ends a Tab cycle. Any key other than Tab calls it, so an edit
// starts the next cycle from what is on screen.
completion_reset :: proc(app: ^App) {
	app.completion_active = false
	app.completion_index = 0
	delete(app.completion_query, app.run.alloc)
	app.completion_query = ""
}

@(private)
completion_query_set :: proc(app: ^App, query: string) {
	cloned, clone_error := strings.clone(query, app.run.alloc)
	delete(app.completion_query, app.run.alloc)
	app.completion_query = cloned
	if clone_error != nil {
		// The cycle keeps no prefix to anchor on; the next Tab starts from the
		// first match of an empty query rather than from a stored one.
		snap_append(app, .Warning, "the completion prefix could not be stored")
	}
}

// command_help prints the command table and the keys the prompt answers to. It is
// generated from the same table completion and dispatch read, so it cannot go
// stale.
command_help :: proc(app: ^App) {
	snap_append(app, .Notice, "commands")
	for command in COMMANDS {
		snap_append(app, .Notice, fmt.tprintf("  %-11s %s", command.name, command.summary))
	}
	snap_append(app, .Notice, "  tab completes a command and cycles through the matches")
	snap_append(app, .Notice, "  a command that names a list opens it when given no argument")
	snap_append(app, .Notice, "keys: escape interrupt | ctrl+c clear, cancel, then quit")
	snap_append(app, .Notice, "  the wheel and page up/page down scroll the transcript")
	snap_append(app, .Notice, "  dragging over the transcript copies the rows it covers")
	snap_append(app, .Notice, "tool boxes show their first lines; click a box to expand and select it, and click the selected box again to collapse it")
	snap_append(app, .Notice, "  over an expanded box the wheel scrolls its output; dragging anywhere on a box copies only its content")
	snap_append(app, .Notice, "  tab (when it completes nothing) moves the keyboard between the prompt and the transcript")
	snap_append(
		app,
		.Notice,
		"  in the transcript: up/down move through text rows and tool boxes, enter activates a selected tool, then up/down scroll its output",
	)
	snap_append(app, .Notice, "  enter collapses the active box; escape deactivates it, then escape or tab returns to the prompt")
}

// MOUSE_WHEEL_LINES is how many rows one wheel tick scrolls.
MOUSE_WHEEL_LINES :: 3

// tool_box_entry_id returns the entry id of the front-most tool box covering a
// screen cell, or 0 when the cell is not on one. A node hidden by a clip or
// covered by an opaque node is not hit.
//
// It asks the frame that is on screen rather than a rectangle remembered from a previous
// frame, so a box that scrolled or resized cannot take a report aimed at whatever now
// covers those cells.
@(require_results)
tool_box_entry_id :: proc(app: ^App, x, y: int) -> u64 {
	frame_result, frame_error := layout.result(&app.storage.layout_ctx)
	if frame_error != .None { return 0 }
	point := tui.layout_point(app.conversation_rect, x, y)
	// The innermost hit is usually a text row inside the box, which carries no entry id.
	stack_storage: [32]layout.Node_Handle
	hits, _ := layout.hit_stack(frame_result, point, stack_storage[:])
	for handle in hits {
		if hit, found := layout.node(frame_result, handle); found && hit.user != 0 {
			return u64(hit.user)
		}
	}
	return 0
}

// wheel_scroll turns a vertical wheel report inside the transcript into a scroll. An expanded
// box under the pointer takes it, becomes the target, and consumes the report even at its first
// or last row, as the arrow keys do. Anywhere else the transcript scrolls, drops any active box,
// and focus moves to the box nearest the middle of the view, if any.
wheel_scroll :: proc(app: ^App, mouse: input.Mouse_Event) {
	delta: int
	#partial switch mouse.button {
	case .Wheel_Up:
		delta = -MOUSE_WHEEL_LINES
	case .Wheel_Down:
		delta = MOUSE_WHEEL_LINES
	case:
		return
	}
	if !tui.rect_contains(app.conversation_rect, mouse.x, mouse.y) { return }
	if id := tool_box_entry_id(app, mouse.x, mouse.y); id != 0 {
		sync.mutex_guard(&app.run.mu)
		if entry := entry_find(app, id); entry != nil && entry.call in app.transcript.expanded {
			transcript_target(app, entry)
			app.transcript.selection_step = 0
			app.transcript.active_call = entry.call
			if transcript_tool_scroll(app, delta) { return }
			app.transcript.active_call = 0
		}
	}
	transcript_scroll_by(app, delta)
	transcript_reselect(app)
}

// Cell_Point is one cell of the transcript grid, in the transcript's own
// coordinates: the origin is the conversation rect's top-left cell.
Cell_Point :: struct {
	x, y: int,
}

// selection_point converts a mouse report into a transcript cell, clamped to the
// transcript so a drag that leaves the area still selects up to its edge. The
// frame is solved in the transcript's own coordinates, which is the offset
// conversation_rect carries.
@(require_results)
selection_point :: proc(app: ^App, mouse: input.Mouse_Event) -> (point: Cell_Point, inside: bool) {
	x := mouse.x - app.conversation_rect.x
	y := mouse.y - app.conversation_rect.y
	inside = tui.rect_contains(app.conversation_rect, mouse.x, mouse.y)
	return {clamp(x, 0, max(app.conversation_rect.width - 1, 0)), clamp(y, 0, max(app.conversation_rect.height - 1, 0))}, inside
}

// selection_bounds orders the drag's two ends, so a drag in any direction
// describes the same selection.
selection_bounds :: proc(app: ^App) -> (start, end: Cell_Point) {
	start, end = app.selection_anchor, app.selection_cursor
	if end.y < start.y || (end.y == start.y && end.x < start.x) {
		return end, start
	}
	return
}

// selection_mouse runs one step of a transcript drag: the press anchors it and makes its target,
// the motion extends it, and the release copies what it covers and ends it. A press outside the
// transcript returns the keyboard to the prompt.
selection_mouse :: proc(app: ^App, mouse: input.Mouse_Event) {
	point, inside := selection_point(app, mouse)
	switch {
	case mouse.motion:
		if app.box_drag.active {
			box_drag_move(app, mouse)
		} else if app.selecting {
			app.selection_cursor = point
		}
	case mouse.release:
		switch {
		case app.box_drag.active:
			box_drag_end(app)
		case app.selecting:
			selection_copy(app)
		}
		app.selecting = false
		app.box_drag = {}
	case inside:
		if box_drag_begin(app, mouse) { return }
		transcript_press_document(app)
		app.selecting = true
		app.selection_anchor = point
		app.selection_cursor = point
	case:
		app.selecting = false
		transcript_blur(app)
	}
}

// selection_copy puts the selected transcript text on the terminal's clipboard.
// The cells are read back from the frame that is on screen, so what is copied is
// what the selection covers rather than what the snapshot holds.
selection_copy :: proc(app: ^App) {
	start, end := selection_bounds(app)
	if start == end { return }
	text, text_ok := selection_text(app, app.storage, context.temp_allocator)
	if !text_ok {
		snap_append(app, .Error, "the selection could not be copied: out of memory")
		return
	}
	clipboard_copy(app, text)
}

// clipboard_copy puts text on the terminal's clipboard and says how many lines it was.
clipboard_copy :: proc(app: ^App, text: string) {
	if text == "" { return }
	if _, copy_err := term.clipboard_set(app.terminal, text); copy_err != nil {
		snap_append(app, .Error, fmt.tprintf("the selection could not be copied: %v", copy_err))
		return
	}
	snap_append(app, .Notice, fmt.tprintf("copied %d line(s) to the clipboard", strings.count(text, "\n") + 1))
}

// Box_Drag is a drag that began anywhere on a tool box. anchor and cursor are content
// rows in its displayed preview or full result, so an expanded box can scroll under the drag. moved says the
// pointer left the press, which tells a drag from a click.
Box_Drag :: struct {
	active:         bool,
	moved:          bool,
	id:             u64,
	anchor, cursor: int,
}

// tool_box_rect returns where the last frame put the tool box with entry id, in transcript cells.
tool_box_rect :: proc(app: ^App, id: u64) -> (rect: layout.Rect, found: bool) {
	frame_result, frame_error := layout.result(&app.storage.layout_ctx)
	if frame_error != .None { return {}, false }
	for node in frame_result.nodes {
		if u64(node.user) == id { return node.outer, true }
	}
	return {}, false
}

// box_result_row is the row of the box's result a mouse report is on, relative to the first
// row the box shows; it is outside 0 ..< entry.tool_rows when the report is above or below them.
box_result_row :: proc(app: ^App, id: u64, mouse: input.Mouse_Event) -> (row: int, found: bool) {
	rect, rect_found := tool_box_rect(app, id)
	if !rect_found { return 0, false }
	return mouse.y - app.conversation_rect.y - int(rect.position.y) - 1, true
}

// box_drag_begin starts a content drag on any part of a tool box, makes the box the target, and reports whether it did.
box_drag_begin :: proc(app: ^App, mouse: input.Mouse_Event) -> bool {
	id := tool_box_entry_id(app, mouse.x, mouse.y)
	row, found := box_result_row(app, id, mouse)
	if id == 0 || !found { return false }
	sync.mutex_guard(&app.run.mu)
	entry := entry_find(app, id)
	if entry == nil { return false }
	transcript_target(app, entry)
	app.transcript.selection_step = 0
	row = clamp(row, 0, max(entry.tool_rows - 1, 0))
	offset := widgets.scroll_offset(entry.tool_scroll) if entry.full != "" || entry.running else 0
	app.box_drag = {
		active = true,
		id     = id,
		anchor = offset + row,
		cursor = offset + row,
	}
	return true
}

// box_drag_move extends the drag and scrolls an expanded box when the pointer leaves its outer bounds vertically.
box_drag_move :: proc(app: ^App, mouse: input.Mouse_Event) {
	drag := &app.box_drag
	rect, found := tool_box_rect(app, drag.id)
	row := mouse.y - app.conversation_rect.y - int(rect.position.y) - 1
	sync.mutex_guard(&app.run.mu)
	entry := entry_find(app, drag.id)
	if entry == nil || !found { return }
	drag.moved = true
	if entry.full != "" {
		switch {
		case row < -1:
			_ = widgets.scroll_by(&entry.tool_scroll, -MOUSE_WHEEL_LINES)
		case row >= int(rect.size.y) - 1:
			_ = widgets.scroll_by(&entry.tool_scroll, MOUSE_WHEEL_LINES)
		}
	}
	offset := widgets.scroll_offset(entry.tool_scroll) if entry.full != "" || entry.running else 0
	drag.cursor = offset + clamp(row, 0, max(entry.tool_rows - 1, 0))
}

// box_drag_end copies the dragged content rows. A press and release without motion activates the box instead, as Enter does.
box_drag_end :: proc(app: ^App) {
	drag := app.box_drag
	if !drag.moved {
		sync.mutex_lock(&app.run.mu)
		transcript_target(app, entry_find(app, drag.id))
		app.transcript.selection_step = 0
		sync.mutex_unlock(&app.run.mu)
		transcript_activate(app)
		return
	}
	sync.mutex_lock(&app.run.mu)
	rows: string
	if entry := entry_find(app, drag.id); entry != nil {
		value := entry.full if entry.full != "" else string(entry.text[:])
		rows = box_rows_text(value, max(app.conversation_rect.width, 4) - 4, min(drag.anchor, drag.cursor), max(drag.anchor, drag.cursor))
	}
	sync.mutex_unlock(&app.run.mu)
	clipboard_copy(app, rows)
}

// box_rows_text returns content rows first through last from a box's text, wrapped at content_width,
// one per line, in the temporary allocator. The title is excluded.
box_rows_text :: proc(value: string, content_width, first, last: int) -> string {
	split := strings.index_byte(value, '\n')
	if split < 0 { return "" }
	remaining := text.sanitize_text(value[split + 1:], context.temp_allocator) or_else ""
	builder := strings.builder_make(context.temp_allocator)
	for index := 0; len(remaining) > 0 && index <= last; index += 1 {
		piece, rest := tool_row_next(remaining, content_width, TOOL_CONTENT_START)
		remaining = rest
		if index < first { continue }
		if index > first { strings.write_byte(&builder, '\n') }
		strings.write_string(&builder, piece)
	}
	return strings.to_string(builder)
}

// handle_mouse routes a mouse report: the wheel scrolls the transcript, and the left button
// presses, drags, and releases on it.
handle_mouse :: proc(app: ^App, mouse: input.Mouse_Event) {
	#partial switch mouse.button {
	case .Wheel_Up, .Wheel_Down, .Wheel_Left, .Wheel_Right:
		wheel_scroll(app, mouse)
	case .Left:
		selection_mouse(app, mouse)
	}
}

handle_event :: proc(app: ^App, event: input.Event) {
	#partial switch data in event {
	case input.Key_Event:
		if app.menu_open {
			handle_menu_key(app, data)
		} else {
			handle_key(app, data)
		}
	case input.Mouse_Event:
		if !app.menu_open {
			handle_mouse(app, data)
		}
	case input.Paste:
		paste_insert(app, data.text)
	case input.End_Of_Input:
		app.quit = true
	case input.Unknown_Input:
	}
}

cancel_or_quit :: proc(app: ^App) {
	if runtime_busy(app) && !runtime_following(app) {
		stop_turn(app)
		return
	}
	app.quit = true
}

// stop_turn asks the running turn to stop. A follower has no turn to stop: the runner's
// process owns it, so the request is refused with a notice.
stop_turn :: proc(app: ^App) {
	if runtime_following(app) {
		follower_refuse(app, "cancelling the turn")
		return
	}
	agent.turn_control_stop(&app.run.control)
}

// interrupt resolves one Ctrl+C press in the order the prompt's state demands:
// text being composed is discarded first, then a running request is cancelled,
// and an empty prompt exits when idle or following another process. The first state that applies wins, so a
// half-written prompt can neither cancel work nor end the session.
interrupt :: proc(app: ^App) {
	if len(widgets.input_text(&app.input)) > 0 {
		prompt_clear(app)
		return
	}
	cancel_or_quit(app)
}

// scroll_page scrolls the transcript by the height of its viewport.
scroll_page :: proc(app: ^App, up: bool) {
	page := app.conversation_rect.height
	if app.transcript.active_call == 0 { app.transcript.selected_entry, app.transcript.selection_step = 0, 0 }
	transcript_scroll_by(app, -page if up else page)
}

// handle_key sends a key to the prompt, or to the transcript while it has the keyboard.
// A key the transcript does not use returns the keyboard to the prompt and is typed there.
handle_key :: proc(app: ^App, key: input.Key_Event) {
	if !app.transcript.focused {
		handle_prompt_key(app, key)
		return
	}
	#partial switch key.code {
	case .Tab:
		transcript_blur(app)
	case .Escape:
		if app.transcript.active_call != 0 {
			app.transcript.active_call = 0
		} else {
			transcript_blur(app)
		}
	case .Up:
		transcript_arrow(app, -1)
	case .Down:
		transcript_arrow(app, 1)
	case .Enter:
		transcript_activate(app)
	case .Page_Up:
		scroll_page(app, up = true)
	case .Page_Down:
		scroll_page(app, up = false)
	case:
		transcript_blur(app)
		handle_prompt_key(app, key)
	}
}

handle_prompt_key :: proc(app: ^App, key: input.Key_Event) {
	#partial switch key.code {
	case .Enter:
		if key.modifiers & {.Shift, .Alt} == {} {
			submit(app)
			return
		}
	case .Up, .Down:
		completion_reset(app)
		// The caret moves between the rows of a multi-line prompt. With no row
		// in that direction, the key walks the prompts submitted this run.
		handled, err := widgets.input_key(&app.input, key, input_content_width(app), text.DEFAULT_WIDTH_PROFILE)
		if err != nil {
			snap_append(app, .Warning, "the prompt could not be edited")
		} else if !handled {
			history_recall(app, older = key.code == .Up)
		}
		return
	case .Escape:
		if runtime_busy(app) {
			stop_turn(app)
		} else {
			prompt_clear(app)
		}
		return
	case .Page_Up:
		scroll_page(app, up = true)
		return
	case .Page_Down:
		scroll_page(app, up = false)
		return
	case .Tab:
		if !complete_command(app) { transcript_focus(app) }
		return
	case .Character:
		if .Control in key.modifiers {
			switch key.character {
			case 'c':
				interrupt(app)
				return
			case 'd':
				cancel_or_quit(app)
				return
			}
		}
	}
	completion_reset(app)
	if _, err := widgets.input_key(&app.input, key, input_content_width(app), text.DEFAULT_WIDTH_PROFILE); err != nil {
		snap_append(app, .Warning, "the prompt could not be edited")
	}
}

// submit sends the prompt line as a turn prompt, a steering line, or a slash command. A
// line typed while a turn runs is queued for the next request boundary instead of being
// dropped. A prompt line also enters the history the arrow keys walk; a slash command
// does not.
submit :: proc(app: ^App) {
	text := strings.trim_space(widgets.input_text(&app.input))
	if text == "" {
		prompt_clear(app)
		completion_reset(app)
		return
	}
	if command_shaped(text) {
		if !dispatch_command(app, text) {
			// An unknown command stays in the prompt, so a typo is fixed rather than retyped.
			completion_reset(app)
			return
		}
	} else {
		// A follower has no turn of its own to steer: its line goes to the runner as a
		// prompt, and the runner delivers it at its next settled point.
		if runtime_busy(app) && !runtime_following(app) {
			// A steering line is not a command: commands keep their own path, which
			// decides what can happen while a turn is running.
			transcript_jump_bottom(app)
			if !agent.steer_push(&app.run.steer, text) {
				// The line could not be queued, and the prompt still holds it: the text stays
				// where the user put it rather than being cleared into a warning.
				snap_append(app, .Warning, "the steering line could not be queued; it is still in the prompt")
				completion_reset(app)
				return
			}
			// The notice that the line is queued comes from the worker once the journal
			// holds it, so the transcript never claims a line the session does not have.
		} else {
			transcript_jump_bottom(app)
			enqueue(app, .Prompt, text)
		}
		// The line left the prompt, so it enters the history the arrow keys walk.
		if !widgets.history_push(&app.history, text) {
			snap_append(app, .Warning, "the prompt could not be added to the history")
		}
	}
	prompt_clear(app)
	completion_reset(app)
}

// restore_steering returns input the session never accepted. The turn commits the lines
// it finds queued as it runs, so what is left here arrived after its last look: the text
// is still the user's, and it goes back to the prompt for an explicit submit. Nothing here
// starts a turn, and nothing here reads the text as a command.
restore_steering :: proc(app: ^App) {
	taken, taken_ok := agent.steer_take_all(&app.run.steer)
	defer agent.steer_taken_destroy(&app.run.steer, taken)
	if !taken_ok {
		// The lines could not be copied out, so they are still queued rather than lost.
		snap_append(app, .Warning, "input queued during that turn could not be restored")
		return
	}
	if len(taken) == 0 { return }
	restored, join_err := strings.join(taken[:], "\n", app.run.alloc)
	if join_err != nil {
		snap_append(app, .Warning, "input queued during that turn could not be restored")
		return
	}
	defer delete(restored, app.run.alloc)
	if widgets.input_insert(&app.input, restored) != nil {
		snap_append(app, .Warning, "input queued during that turn could not be restored")
		return
	}
	completion_reset(app)
	// The line is a fresh prompt now, restored text or not: the arrow keys must
	// treat what it holds as a draft rather than as a recalled entry.
	widgets.history_reset(&app.history)
	if len(taken) == 1 {
		snap_append(app, .Notice, "the line you typed while that turn ran was not sent; it is back in the prompt")
	} else {
		snap_append(app, .Notice, fmt.tprintf("%d lines you typed while that turn ran were not sent; they are back in the prompt", len(taken)))
	}
}

// dispatch_command routes one slash command. The name comes from the command
// table, so a command that completion and help know about is always one dispatch
// can run; the switch decides what that command does. Everything else is reported
// as unknown rather than sent to the model, and dispatch_command returns false.
dispatch_command :: proc(app: ^App, text: string) -> bool {
	name, argument := command_split(text)
	command, found := command_find(name)
	if !found {
		snap_append(app, .Notice, fmt.tprintf("unknown command: %s (try /help)", name))
		return false
	}
	// A command whose argument is chosen from a list opens that list when given no
	// argument. One rule covers every such command, and it is the same rule
	// completion applies to a completed name.
	if argument == "" && command.open_menu != nil {
		command.open_menu(app)
		return true
	}
	switch command.id {
	case .Quit:
		if runtime_busy(app) { agent.turn_control_stop(&app.run.control) }
		app.quit = true
	case .Help:
		command_help(app)
	case .New_Session:
		enqueue(app, .New_Session)
	case .Resume:
		enqueue(app, .Resume_Session, argument)
	case .Compact:
		if !runtime_stopping(app) {
			sync.atomic_store(&app.run.compact_pending, true)
			agent.owner_wake_signal()
		}
	case .Status:
		enqueue(app, .Status)
	case .Effort:
		enqueue(app, .Effort, argument)
	case .Model:
		provider_id, model_id, ok := resolve_model_reference(app, argument)
		if ok {
			selection_request(app, provider_id, model_id)
		}
	}
	return true
}

enqueue :: proc(app: ^App, kind: Work_Kind, text: string = "") {
	// The worker abandons the queue on the way out, so a command that entered now
	// would never run. Dropping it here is what makes shutdown's "no new work"
	// promise hold without reaching through the queue.
	if runtime_stopping(app) { return }
	item := Work {
		kind = kind,
	}
	if text != "" {
		cloned, clone_error := strings.clone(text, app.run.alloc)
		if clone_error != nil {
			snap_append(app, .Warning, "the line could not be stored; it was dropped")
			return
		}
		item.text = cloned
	}
	if work_send(app, item) { return }
	if item.text != "" {
		delete(item.text, app.run.alloc)
	}
	snap_append(app, .Warning, "input queue full; line dropped")
}

// --- prompt line editing --------------------------------------------------

// paste_insert inserts a bracketed paste at the caret. The prompt applies its text rule, so
// line breaks are kept and CR and CRLF read as the one break they mean.
paste_insert :: proc(app: ^App, text_value: string) {
	if widgets.input_insert(&app.input, text_value) != nil {
		snap_append(app, .Warning, "the prompt could not hold the pasted text")
	}
}

// --- prompt history -------------------------------------------------------

// prompt_clear empties the prompt line and ends any history browsing, so the next up
// arrow starts from the newest prompt. Every clear of the whole line goes through it.
prompt_clear :: proc(app: ^App) {
	widgets.input_clear(&app.input)
	widgets.history_reset(&app.history)
}

// history_recall replaces the prompt line with the next older prompt, or the next newer
// one, and past the newest the line is the composed one again. What a recall shows is
// ordinary input, so it can be edited and submitted like anything typed.
history_recall :: proc(app: ^App, older: bool) {
	entry: string
	ok: bool
	if older {
		entry, ok = widgets.history_previous(&app.history, widgets.input_text(&app.input))
	} else {
		entry, ok = widgets.history_next(&app.history)
	}
	if !ok { return }
	widgets.input_clear(&app.input)
	if widgets.input_insert(&app.input, entry) != nil {
		snap_append(app, .Warning, "the recalled prompt could not be shown")
	}
}
