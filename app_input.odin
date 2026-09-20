#+build linux
package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sync/chan"

import "nabla:agent"
import input "nabla:input"
import "nabla:layout"
import "nabla:term"
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

// Command is one slash command. name is what the user types, summary is what
// /help says about it, and open_menu shows the list its argument is chosen from
// (nil when it takes no argument). The table is the only place a command is
// declared, so completion, help, and dispatch cannot disagree about what exists
// or about which commands offer a list.
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
command_find :: proc(name: string) -> (Command, bool) {
	for command in COMMANDS {
		if strings.equal_fold(command.name, name) { return command, true }
	}
	return {}, false
}

// command_split separates a command's name from its argument.
command_split :: proc(text: string) -> (name, argument: string) {
	trimmed := strings.trim_space(text)
	space := strings.index_byte(trimmed, ' ')
	if space < 0 { return trimmed, "" }
	return trimmed[:space], strings.trim_space(trimmed[space + 1:])
}

// command_prefixed reports whether the typed text is a prefix of a command,
// ignoring case so a capital is a typo rather than a miss.
command_prefixed :: proc(command, typed: string) -> bool {
	if len(typed) > len(command) { return false }
	return strings.equal_fold(command[:len(typed)], typed)
}

// complete_command advances the slash command at the prompt. Tab cycles: the
// first press reaches the first match of what is typed, and the next press moves
// to the one after it, wrapping around, so pressing Tab on "/" walks the whole
// set. A completed name whose command takes a list opens that list. Matching
// ignores case; what is written back is the command's own lowercase name.
complete_command :: proc(app: ^App) {
	typed := widgets.input_text(&app.input)
	if !strings.has_prefix(typed, "/") || strings.contains_rune(typed, ' ') {
		completion_reset(app)
		return
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
		return
	}
	command := COMMANDS[index]
	if !app.completion_active && query == command.name {
		completion_reset(app)
		if command.open_menu != nil { command.open_menu(app) }
		return
	}

	// The query is stored only when a cycle begins, because the stored copy is
	// what a later press reads and the input buffer is what it was taken from.
	if !app.completion_active { completion_query_set(app, typed) }
	app.completion_index = index
	app.completion_active = true
	widgets.input_clear(&app.input)
	widgets.input_insert(&app.input, command.name)
}

// command_next_match finds the next command after `after` whose name starts with
// query, wrapping around. -1 starts at the beginning.
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
	delete(app.completion_query, app.run.alloc)
	app.completion_query = strings.clone(query, app.run.alloc)
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
	snap_append(app, .Notice, "  over a tool box the wheel scrolls that box's output")
	snap_append(app, .Notice, "  dragging over the transcript copies the rows it covers")
}

// MOUSE_WHEEL_LINES is how many rows one wheel tick scrolls.
MOUSE_WHEEL_LINES :: 3

// tool_box_entry_at returns the entry ordinal of the tool box covering a screen
// cell, or -1 when the cell is not on one.
//
// It asks the frame that is on screen rather than a rectangle remembered from a
// previous frame, so a box that scrolled or resized cannot take a report aimed
// at whatever now covers those cells. A box carries its entry ordinal on its
// node, which is what the scan reads.
tool_box_entry_at :: proc(app: ^App, x, y: int) -> int {
	frame_result, frame_error := layout.result(&app.storage.layout_ctx)
	if frame_error != .None { return -1 }
	point := layout.Vec2{layout.Scalar(x - app.conversation_rect.x), layout.Scalar(y - app.conversation_rect.y)}
	for node in frame_result.nodes {
		if node.user == 0 { continue }
		if point.x < node.outer.position.x || point.y < node.outer.position.y { continue }
		if point.x >= node.outer.position.x + node.outer.size.x { continue }
		if point.y >= node.outer.position.y + node.outer.size.y { continue }
		return tool_box_ordinal(node.user)
	}
	return -1
}

// tool_box_scroll moves a tool box's window one wheel tick and reports whether
// the box could take it. The box owns the wheel only while it has rows left in
// the direction asked for: at its boundary the report is left to the transcript,
// so scrolling continues there instead of stopping at the box's edge.
tool_box_scroll :: proc(entry: ^Entry, button: input.Mouse_Button) -> bool {
	#partial switch button {
	case .Wheel_Up:
		if entry.tool_scroll <= 0 { return false }
		entry.tool_scroll = max(entry.tool_scroll - MOUSE_WHEEL_LINES, 0)
		return true
	case .Wheel_Down:
		if entry.tool_scroll >= entry.tool_scroll_max { return false }
		entry.tool_scroll = min(entry.tool_scroll + MOUSE_WHEEL_LINES, entry.tool_scroll_max)
		return true
	}
	return false
}

// wheel_scroll turns a mouse wheel report into a scroll. Over a tool box that can
// still move the way the wheel asks, it scrolls that box's window, so a long
// result can be read without leaving the transcript; everywhere else in the
// messages area it scrolls the transcript, which is what page up and page down
// do.
//
// The box is asked first, and asked of the frame itself, so a box keeps the wheel
// wherever it sits in the transcript. The transcript's own guard stays a bound on
// the footer rather than on the frame, because a report there has nothing to
// scroll.
wheel_scroll :: proc(app: ^App, mouse: input.Mouse_Event) {
	// The terminal reports mouse cells one-based; the frame is solved from zero.
	if ordinal := tool_box_entry_at(app, mouse.x - 1, mouse.y - 1); ordinal >= 0 {
		sync.mutex_lock(&app.run.mu)
		consumed := tool_box_scroll(&app.run.snap.entries[ordinal], mouse.button)
		sync.mutex_unlock(&app.run.mu)
		if consumed { return }
	}
	if mouse.y > app.rows - TUI_FOOTER_ROWS {
		return
	}
	#partial switch mouse.button {
	case .Wheel_Up:
		app.scroll += MOUSE_WHEEL_LINES
	case .Wheel_Down:
		app.scroll -= MOUSE_WHEEL_LINES
		if app.scroll < 0 {
			app.scroll = 0
		}
	case:
	}
}

// Cell_Point is one cell of the transcript grid, in the transcript's own
// coordinates: the origin is the conversation rect's top-left cell.
Cell_Point :: struct {
	x, y: int,
}

// selection_point converts a mouse report into a transcript cell, clamped to the
// transcript so a drag that leaves the area still selects up to its edge. The
// report is 1-based and in screen cells; the frame is 0-based and solved in the
// transcript's own coordinates, which is the offset conversation_rect carries.
selection_point :: proc(app: ^App, mouse: input.Mouse_Event) -> (point: Cell_Point, inside: bool) {
	x := mouse.x - 1 - app.conversation_rect.x
	y := mouse.y - 1 - app.conversation_rect.y
	inside = x >= 0 && y >= 0 && x < app.conversation_rect.width && y < app.conversation_rect.height
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

// selection_mouse runs one step of a transcript drag: the press anchors it, the
// motion extends it, and the release copies what it covers and ends it. A press
// anywhere else only drops whatever the drag had selected.
selection_mouse :: proc(app: ^App, mouse: input.Mouse_Event) {
	point, inside := selection_point(app, mouse)
	switch {
	case mouse.motion:
		if app.selecting { app.selection_cursor = point }
	case mouse.release:
		if app.selecting { selection_copy(app) }
		app.selecting = false
	case inside:
		app.selecting = true
		app.selection_anchor = point
		app.selection_cursor = point
	case:
		app.selecting = false
	}
}

// selection_copy puts the selected transcript text on the terminal's clipboard.
// The cells are read back from the frame that is on screen, so what is copied is
// what the selection covers rather than what the snapshot holds.
selection_copy :: proc(app: ^App) {
	start, end := selection_bounds(app)
	if start == end { return }
	text := selection_text(app, app.storage, context.temp_allocator)
	if text == "" { return }
	if _, copy_err := term.clipboard_set(app.terminal, text); copy_err != nil {
		snap_append(app, .Error, fmt.tprintf("the selection could not be copied: %v", copy_err))
		return
	}
	snap_append(app, .Notice, fmt.tprintf("copied %d line(s) to the clipboard", strings.count(text, "\n") + 1))
}

// handle_mouse routes a mouse report: the wheel scrolls, and the left button
// selects text in the transcript.
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
	case input.Resize_Event:
	case input.Paste:
		paste_insert(app, data.text)
	case input.End_Of_Input:
		app.quit = true
	case input.Unknown_Input:
	}
}

// cancel_or_quit cancels the running request, or exits when nothing is running. A
// cancel this front-end requested is remembered, so the retirement that follows
// ends the turn rather than the session.
cancel_or_quit :: proc(app: ^App) {
	if runtime_busy(app) {
		app.cancel_seen = true
		agent.chat_cancel_request()
		return
	}
	app.quit = true
}

// interrupt resolves one Ctrl+C press in the order the prompt's state demands:
// text being composed is discarded first, then a running request is cancelled,
// and only an empty, idle prompt exits. The first state that applies wins, so a
// half-written prompt can neither cancel work nor end the session.
interrupt :: proc(app: ^App) {
	if len(widgets.input_text(&app.input)) > 0 {
		widgets.input_clear(&app.input)
		return
	}
	cancel_or_quit(app)
}

handle_key :: proc(app: ^App, key: input.Key_Event) {
	switch key.code {
	case .Enter:
		if .Shift in key.modifiers {
			completion_reset(app)
			_ = widgets.input_insert_newline(&app.input)
		} else {
			submit(app)
		}
	case .Backspace:
		completion_reset(app)
		widgets.input_backspace(&app.input)
	case .Delete:
		completion_reset(app)
		widgets.input_delete(&app.input)
	case .Left:
		widgets.input_move_left(&app.input)
	case .Right:
		widgets.input_move_right(&app.input)
	case .Home:
		widgets.input_move_home(&app.input)
	case .End:
		widgets.input_move_end(&app.input)
	case .Escape:
		if runtime_busy(app) {
			app.cancel_seen = true
			agent.chat_cancel_request()
		} else {
			widgets.input_clear(&app.input)
		}
	case .Page_Up:
		page := app.rows - 3
		if page < 1 {
			page = 1
		}
		app.scroll += page
	case .Page_Down:
		page := app.rows - 3
		if page < 1 {
			page = 1
		}
		app.scroll -= page
		if app.scroll < 0 {
			app.scroll = 0
		}
	case .Tab:
		complete_command(app)
	case .Up, .Down:
	case .Character:
		if .Control in key.modifiers {
			switch key.character {
			case '\x03':
				interrupt(app)
			case '\x04':
				cancel_or_quit(app)
			}
		} else if key.character >= 0x20 && key.character != 0x7f {
			completion_reset(app)
			widgets.input_insert_rune(&app.input, key.character)
		}
	case .Insert, .F1, .F2, .F3, .F4, .F5:
	}
}

// submit sends the prompt line as a turn prompt, a steering line, or a slash
// command. A line typed while a turn runs is queued for the next request boundary
// instead of being dropped, which is the only point at which it can safely change
// what the model is asked next.
submit :: proc(app: ^App) {
	text := strings.trim_space(widgets.input_text(&app.input))
	if text == "" {
		widgets.input_clear(&app.input)
		completion_reset(app)
		return
	}
	if strings.has_prefix(text, "/") {
		dispatch_command(app, text)
	} else if runtime_busy(app) {
		// A steering line is not a command: commands keep their own path, which
		// decides what can happen while a turn is running.
		if agent.steer_push(&app.run.steer, text) {
			snap_append(app, .Notice, "queued; the model sees this at its next request boundary")
		} else {
			snap_append(app, .Warning, "steering queue full; line dropped")
		}
	} else {
		enqueue(app, .Prompt, text)
	}
	widgets.input_clear(&app.input)
	completion_reset(app)
}

// dispatch_command routes one slash command. The name comes from the command
// table, so a command that completion and help know about is always one dispatch
// can run; the switch decides what that command does. Everything else is reported
// as unknown rather than sent to the model.
dispatch_command :: proc(app: ^App, text: string) {
	name, argument := command_split(text)
	command, found := command_find(name)
	if !found {
		snap_append(app, .Notice, fmt.tprintf("unknown command: %s (try /help)", name))
		return
	}
	// A command whose argument is chosen from a list opens that list when given no
	// argument. One rule covers every such command, and it is the same rule
	// completion applies to a completed name.
	if argument == "" && command.open_menu != nil {
		command.open_menu(app)
		return
	}
	switch command.id {
	case .Quit:
		if runtime_busy(app) {
			app.cancel_seen = true
			agent.chat_cancel_request()
		}
		app.quit = true
	case .Help:
		command_help(app)
	case .New_Session:
		enqueue(app, .New_Session)
	case .Resume:
		enqueue(app, .Resume_Session, argument)
	case .Compact:
		enqueue(app, .Compact)
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
		item.text = strings.clone(text, app.run.alloc)
	}
	if chan.try_send(app.run.work, item) {
		return
	}
	if item.text != "" {
		delete(item.text, app.run.alloc)
	}
	snap_append(app, .Warning, "input queue full; line dropped")
}

// --- prompt line editing --------------------------------------------------

// paste_insert inserts a bracketed paste at the cursor. A single-line prompt
// has no place for a line break, so CR/LF become spaces and other controls are
// dropped.
paste_insert :: proc(app: ^App, text_value: string) {
	if text_value == "" {
		return
	}
	run := strings.builder_make(0, 0, context.temp_allocator)
	for r in text_value {
		switch {
		case r == '\r' || r == '\n':
			strings.write_byte(&run, ' ')
		case r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f):
		// A control code point has no place in the prompt line.
		case:
			strings.write_rune(&run, r)
		}
	}
	widgets.input_insert(&app.input, strings.to_string(run))
}
