#+build linux
package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:sync"

import "nabla:agent"
import "nabla:agent/journal"
import "nabla:ai"
import "nabla:layout"
import "nabla:tui/widgets"

// TRANSCRIPT_WINDOW_SCREENS is the screens of history kept in memory: the visible one, two above, two below.
// Memory then follows what can be seen next, however far the user scrolls back.
TRANSCRIPT_WINDOW_SCREENS :: 5

// TRANSCRIPT_LOAD_SCREENS is how near the window's edge the view may come before the next page is read.
TRANSCRIPT_LOAD_SCREENS :: 1

// TRANSCRIPT_PAGE_NODES is how many whole nodes one read adds to the window.
TRANSCRIPT_PAGE_NODES :: 16

// WINDOW_ENTRY_FLAG marks window entry ids, made from the node and the entry's place in it; live ids never carry it.
WINDOW_ENTRY_FLAG :: u64(1) << 63
WINDOW_ORDINAL_BITS :: 20

CHECKPOINT_NOTICE :: "(earlier turns are summarized)"

// Transcript is the window onto the shown session's node path. Main thread only.
Transcript :: struct {
	store:          journal.Journal, // read-only, opened by the first read
	session:        journal.Session_Id,
	path:           []journal.Node_Id, // owned by the run's allocator; the active branch, oldest first, as of head
	head:           journal.Node_Id,
	first:          int, // the window is path[first:end]
	end:            int,
	entries:        [dynamic]Entry, // owned; the entries of the window's nodes, oldest first
	failed:         bool, // a page read failed; cleared by a new head or session
	measured:       bool, // the transcript was laid out since the last slide
	viewport_rows:  int,
	anchor:         Maybe(int), // rows below the view when a page was loaded above it
	expanded:       map[journal.Call_Id]string, // owned; the whole text of each expanded box
	focused:        bool, // the keyboard drives the transcript instead of the prompt
	selected_entry: u64, // the tool box the keyboard or a press selected; zero is none
	selection_step: int, // arrow moves waiting for a page and its measured rows
	active_call:    journal.Call_Id, // the expanded box whose content takes the arrow keys
}

transcript_destroy :: proc(app: ^App) {
	transcript := &app.transcript
	entries_destroy(&transcript.entries)
	delete(transcript.path, app.run.alloc)
	boxes_collapse_all(app)
	delete(transcript.expanded)
	_ = journal.close(&transcript.store)
	transcript^ = {}
}

entries_destroy :: proc(entries: ^[dynamic]Entry) {
	for &entry in entries { entry_destroy(&entry) }
	delete(entries^)
	entries^ = nil
}

// transcript_sync moves the window to the published session and head and drops the live entries it covers. It reads the first page only.
transcript_sync :: proc(app: ^App) {
	transcript := &app.transcript
	session, head := transcript_published(app)
	if session != transcript.session {
		entries_destroy(&transcript.entries)
		delete(transcript.path, app.run.alloc)
		transcript.path = nil
		transcript.session = session
		transcript.head, transcript.first, transcript.end = 0, 0, 0
		transcript.failed = false
		transcript.measured = false
		transcript.anchor = nil
		transcript.focused = false
		transcript.selected_entry = 0
		transcript.selection_step = 0
		boxes_collapse_all(app)
		widgets.scroll_follow(&app.conversation_scroll)
	}
	if head != transcript.head { transcript_follow(app, head) }
	transcript_reduce(app)
}

transcript_published :: proc(app: ^App) -> (session: journal.Session_Id, head: journal.Node_Id) {
	sync.mutex_guard(&app.run.mu)
	return app.run.snap.head_session, app.run.snap.head
}

// transcript_follow reads the path to head. A head that cannot be read is not tried again.
transcript_follow :: proc(app: ^App, head: journal.Node_Id) {
	transcript := &app.transcript
	transcript.head = head
	transcript.failed = false
	if !transcript_open(app) { return }
	path: []journal.Node_Id
	if head != 0 {
		read_error: journal.Error
		path, read_error = journal.read_path(&transcript.store, transcript.session, head, app.run.alloc)
		if read_error != nil {
			transcript_fail(app, read_error)
			return
		}
	}
	loaded := transcript.first < transcript.end
	if loaded {
		old := transcript.path
		kept := transcript.end <= len(path) && path[transcript.first] == old[transcript.first] && path[transcript.end - 1] == old[transcript.end - 1]
		if !kept {
			// The replacement read borrows scroll state before releasing the old entries.
			transcript.first, transcript.end = 0, 0
			transcript.anchor = nil
			loaded = false
		}
	}
	delete(transcript.path, app.run.alloc)
	transcript.path = path
	if !loaded {
		if len(path) > 0 { transcript_page_tail(app) }
		if len(path) == 0 || transcript.failed { entries_destroy(&transcript.entries) }
	}
}

@(require_results)
transcript_open :: proc(app: ^App) -> bool {
	transcript := &app.transcript
	if transcript.store.open { return true }
	if open_error := journal.open(&transcript.store, app.setup.journal_directory, "", app.setup.run, .Read_Only, app.run.alloc); open_error != nil {
		transcript_fail(app, open_error)
		return false
	}
	return true
}

transcript_fail :: proc(app: ^App, error: journal.Error) {
	app.transcript.failed = true
	detail := journal.error_text(error, context.temp_allocator)
	snap_append(app, .Error, fmt.tprintf("cannot read the session history: %s", detail))
}

transcript_page_tail :: proc(app: ^App) {
	transcript := &app.transcript
	first, end := max(len(transcript.path) - TRANSCRIPT_PAGE_NODES, 0), len(transcript.path)
	entries, read_error := transcript_read(app, first, end)
	if read_error != nil {
		transcript_fail(app, read_error)
		return
	}
	entries_destroy(&transcript.entries)
	transcript.entries = entries
	transcript.first, transcript.end = first, end
}

// transcript_scroll_to follows only at the history's bottom, not a loaded window's bottom.
transcript_scroll_to :: proc(app: ^App, row: int) {
	scroll := &app.conversation_scroll
	widgets.scroll_to(scroll, row)
	if app.transcript.end < len(app.transcript.path) {
		scroll.top = clamp(row, 0, scroll.range)
	}
}

transcript_scroll_by :: proc(app: ^App, delta: int) {
	scroll := &app.conversation_scroll
	transcript_scroll_to(app, clamp(widgets.scroll_offset(scroll^) + delta, 0, scroll.range))
}

// transcript_scroll_set_range keeps a pin at a partial window's bottom while layout settles.
transcript_scroll_set_range :: proc(app: ^App, range: int) {
	scroll := &app.conversation_scroll
	top := scroll.top
	widgets.scroll_set_range(scroll, range)
	if row, pinned := top.?; pinned && app.transcript.end < len(app.transcript.path) {
		transcript_scroll_to(app, row)
	}
}

// transcript_jump_bottom follows the newest content, reattaching a window that was paged away from the tail.
transcript_jump_bottom :: proc(app: ^App) {
	transcript := &app.transcript
	widgets.scroll_follow(&app.conversation_scroll)
	transcript.anchor = nil
	if transcript.end < len(transcript.path) && !transcript.failed { transcript_page_tail(app) }
}

transcript_page_older :: proc(app: ^App) {
	transcript := &app.transcript
	first := max(transcript.first - TRANSCRIPT_PAGE_NODES, 0)
	entries, read_error := transcript_read(app, first, transcript.first)
	if read_error != nil {
		transcript_fail(app, read_error)
		return
	}
	if _, inject_error := inject_at_elems(&transcript.entries, 0, ..entries[:]); inject_error != nil {
		entries_destroy(&entries)
		transcript_fail(app, inject_error)
		return
	}
	delete(entries)
	transcript.first = first
}

// transcript_page_newer reads the window's last node again, because its tool results may have been committed since.
transcript_page_newer :: proc(app: ^App) {
	transcript := &app.transcript
	last := transcript.end - 1
	end := min(transcript.end + TRANSCRIPT_PAGE_NODES, len(transcript.path))
	entries, read_error := transcript_read(app, last, end)
	if read_error != nil {
		transcript_fail(app, read_error)
		return
	}
	transcript_pop_node(app, transcript.path[last])
	if _, append_error := append(&transcript.entries, ..entries[:]); append_error != nil {
		entries_destroy(&entries)
		transcript_fail(app, append_error)
		return
	}
	delete(entries)
	transcript.end = end
}

transcript_pop_node :: proc(app: ^App, node: journal.Node_Id) {
	entries := &app.transcript.entries
	for len(entries) > 0 && entries[len(entries) - 1].node == node {
		entry := pop(entries)
		entry_destroy(&entry)
	}
}

// transcript_read returns the entries of path[first:end], owned by the run's allocator.
@(require_results)
transcript_read :: proc(app: ^App, first, end: int) -> (entries: [dynamic]Entry, error: journal.Error) {
	transcript := &app.transcript
	arena: virtual.Arena
	virtual.arena_init_growing(&arena) or_return
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	nodes := journal.read_nodes(&transcript.store, transcript.session, transcript.path[first:end], allocator) or_return
	projection := agent.projection_load_nodes(&transcript.store, transcript.session, nodes, allocator) or_return
	entries.allocator = app.run.alloc
	defer if error != nil { entries_destroy(&entries) }
	window_entries(app, projection, &entries) or_return
	selected_call: journal.Call_Id
	for previous in transcript.entries {
		if previous.id == transcript.selected_entry { selected_call = previous.call; break }
	}
	if selected_call != 0 {
		for entry in entries {
			if entry.call == selected_call { transcript.selected_entry = entry.id; break }
		}
	}
	previous_index := 0
	for &entry in entries {
		for previous_index < len(transcript.entries) && transcript.entries[previous_index].id < entry.id { previous_index += 1 }
		if previous_index == len(transcript.entries) { break }
		previous := &transcript.entries[previous_index]
		if previous.id == entry.id && previous.call == entry.call { entry.tool_scroll = previous.tool_scroll }
	}
	return entries, nil
}

// window_entries maps a projection to entries. A call with no committed completion has none: only the live layer shows it running.
@(require_results)
window_entries :: proc(app: ^App, projection: agent.Projection, entries: ^[dynamic]Entry) -> mem.Allocator_Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	answers := make(map[journal.Call_Id]agent.Projected_Result, len(projection.items), context.temp_allocator) or_return
	for item in projection.items {
		if result, is_result := item.payload.(agent.Projected_Result); is_result { answers[result.call] = result }
	}
	for result in projection.unanswered { answers[result.call] = result }

	summary_pending := projection.summary != ""
	group_start := 0
	for item, index in projection.items {
		if summary_pending && item.node > projection.checkpoint {
			summary_pending = false
			_ = window_push(app, entries, projection.checkpoint, .Notice, CHECKPOINT_NOTICE) or_return
		}
		#partial switch payload in item.payload {
		case agent.Projected_User:
			_ = window_push(app, entries, item.node, user_entry_kind(payload.origin), payload.text) or_return
		case agent.Projected_Assistant:
			_ = window_push(app, entries, item.node, .Assistant, payload.text) or_return
		case agent.Projected_Call:
			if index == 0 || !projected_same_call_group(projection.items[index - 1], item) { group_start = index }
			if result, answered := answers[payload.call]; answered { window_call(app, entries, item.node, payload, result, projection.nested) or_return }
			// A script's calls are admitted after every call of its response.
			if index + 1 == len(projection.items) || !projected_same_call_group(item, projection.items[index + 1]) {
				window_children(app, entries, projection.nested, projection.items[group_start:index + 1], answers) or_return
			}
		}
	}
	if summary_pending { _ = window_push(app, entries, projection.checkpoint, .Notice, CHECKPOINT_NOTICE) or_return }
	return nil
}

projected_same_call_group :: proc(item, next: agent.Projection_Item) -> bool {
	_, is_call := item.payload.(agent.Projected_Call)
	_, next_is_call := next.payload.(agent.Projected_Call)
	return is_call && next_is_call && item.node == next.node
}

// window_push appends an entry of node to entries. The pointer is valid until entries changes.
@(require_results)
window_push :: proc(
	app: ^App,
	entries: ^[dynamic]Entry,
	node: journal.Node_Id,
	kind: Entry_Kind,
	text: string,
) -> (
	entry: ^Entry,
	error: mem.Allocator_Error,
) {
	ordinal := 0
	for index := len(entries) - 1; index >= 0 && entries[index].node == node; index -= 1 { ordinal += 1 }
	made := Entry {
		kind = kind,
		id = WINDOW_ENTRY_FLAG | u64(node) << WINDOW_ORDINAL_BITS | u64(ordinal),
		node = node,
		tool_scroll = {top = 0},
	}
	made.text.allocator = app.run.alloc
	made.stream.allocator = app.run.alloc
	defer if error != nil { entry_destroy(&made) }
	if len(text) > 0 {
		resize(&made.text, len(text)) or_return
		copy(made.text[:], text)
		made.revision = 1
	}
	append(entries, made) or_return
	return &entries[len(entries) - 1], nil
}

@(require_results)
window_call :: proc(
	app: ^App,
	entries: ^[dynamic]Entry,
	node: journal.Node_Id,
	stored: agent.Projected_Call,
	result: agent.Projected_Result,
	nested: []agent.Projected_Nested_Call,
) -> mem.Allocator_Error {
	display := tool_display_call(stored.name, stored.proposed)
	fallback := journal.TOOL_OUTCOME_NAMES[result.outcome]
	if stored.name == agent.TOOL_CODEMODE_NAME {
		inner := codemode_inner_list(nested, stored.call)
		text := codemode_entry_text(display, result.content, fallback, result.outcome, inner)
		return window_tool(app, entries, node, .Codemode, stored.call, text, tool_preview(result.content, fallback), result.outcome, nil)
	}
	text := tool_entry_text(display, result.content, fallback, result.outcome)
	return window_tool(app, entries, node, .Tool, stored.call, text, tool_preview(result.content, fallback), result.outcome, result.attachments)
}

@(require_results)
window_tool :: proc(
	app: ^App,
	entries: ^[dynamic]Entry,
	node: journal.Node_Id,
	kind: Entry_Kind,
	call: journal.Call_Id,
	text, preview: string,
	outcome: journal.Tool_Outcome,
	attachments: []ai.Provider_Attachment,
) -> mem.Allocator_Error {
	image := image_prepare(app, attachments)
	defer delete(image.pixels)
	kept, preview_at, hidden := tool_text_collapse(text, preview)
	entry := window_push(app, entries, node, kind, kept) or_return
	entry.preview_at = preview_at
	entry.hidden_lines = hidden
	entry.call = call
	entry.tool_outcome = outcome
	image_attach(app, entry, &image)
	return nil
}

// window_children appends the boxes of the calls the scripts of one response made, for
// scripts that have a completion. A call that never settled shows as unknown.
@(require_results)
window_children :: proc(
	app: ^App,
	entries: ^[dynamic]Entry,
	nested: []agent.Projected_Nested_Call,
	response: []agent.Projection_Item,
	answers: map[journal.Call_Id]agent.Projected_Result,
) -> mem.Allocator_Error {
	for child in nested {
		if child.parent_call not_in answers { continue }
		for item in response {
			stored, is_call := item.payload.(agent.Projected_Call)
			if !is_call || stored.call != child.parent_call { continue }
			display := tool_display_call(child.name, child.proposed)
			fallback := journal.TOOL_OUTCOME_NAMES[child.outcome]
			text := tool_entry_text_titled(display, codemode_inner_title(child.name), child.content, fallback, child.outcome)
			window_tool(
				app,
				entries,
				item.node,
				.Codemode,
				child.call,
				text,
				tool_preview(child.content, fallback),
				child.outcome,
				child.attachments,
			) or_return
			break
		}
	}
	return nil
}

// codemode_inner_list lists the calls of parent_call; it borrows nested and the temporary allocator.
codemode_inner_list :: proc(nested: []agent.Projected_Nested_Call, parent_call: journal.Call_Id) -> []Codemode_Inner {
	list := make([dynamic]Codemode_Inner, context.temp_allocator)
	for child in nested {
		if child.parent_call != parent_call { continue }
		inner := Codemode_Inner {
			call      = child.call,
			name      = child.name,
			arguments = child.proposed,
			outcome   = child.outcome,
		}
		append(&list, inner) or_break
	}
	return list[:]
}

// transcript_order returns the entries a frame draws, oldest first, in the temporary allocator.
// A live entry follows its node's entries and is hidden until the window reaches it.
transcript_order :: proc(app: ^App) -> []^Entry {
	transcript := &app.transcript
	live := app.run.snap.entries[:]
	order := make([dynamic]^Entry, 0, len(transcript.entries) + len(live), context.temp_allocator)
	unloaded := journal.Node_Id(max(u64))
	if transcript.first < transcript.end && transcript.end < len(transcript.path) { unloaded = transcript.path[transcript.end] }
	next := 0
	for &entry in transcript.entries {
		for next < len(live) && live[next].after < entry.node {
			append(&order, &live[next])
			next += 1
		}
		append(&order, &entry)
	}
	for ; next < len(live); next += 1 {
		if live[next].after < unloaded { append(&order, &live[next]) }
	}
	if transcript.active_call != 0 {
		for entry in order {
			if entry.call == transcript.active_call { transcript.selected_entry = entry.id; break }
		}
	}
	selected_found := false
	for entry in order {
		entry.full = transcript.expanded[entry.call] or_else ""
		selected_found ||= entry.id == transcript.selected_entry
		entry.selected = transcript.focused && entry.id == transcript.selected_entry
	}
	if transcript.selected_entry != 0 && !selected_found { transcript.selected_entry, transcript.selection_step = 0, 0 }
	return order[:]
}

// transcript_measure records the rows each entry of order took; the frame declared them in that order.
transcript_measure :: proc(app: ^App, order: []^Entry, frame_result: layout.Frame_Result, viewport_rows: int) {
	app.transcript.measured = true
	app.transcript.viewport_rows = viewport_rows
	handle, found := layout.lookup_handle(frame_result, CONVERSATION_ID)
	if !found { return }
	children := layout.children(frame_result, handle)
	for entry in order {
		child, _, more := layout.next_child(&children)
		if !more { return }
		entry.rows = int(child.outer.size.y)
	}
	transcript := &app.transcript
	if transcript.focused && transcript.active_call == 0 {
		if transcript.anchor == nil {
			for transcript.selection_step != 0 {
				delta := 1 if transcript.selection_step > 0 else -1
				if !transcript_move(app, order, delta) {
					if transcript.failed || (delta < 0 && transcript.first == 0) || (delta > 0 && transcript.end == len(transcript.path)) {
						transcript.selection_step = 0
					} else {
						transcript_scroll_to(app, 0 if delta < 0 else app.conversation_scroll.range)
					}
					break
				}
				transcript.selection_step -= delta
			}
		}
	}
	for entry in order { entry.selected = transcript.focused && entry.id == transcript.selected_entry }
}

// transcript_slide reads or releases pages after a layout and reports whether the frame must be laid out again. It adjusts the scroll so the view does not move.
transcript_slide :: proc(app: ^App) -> bool {
	moved := transcript_slide_step(app)
	if moved { transcript_reduce(app) }
	return moved
}

transcript_slide_step :: proc(app: ^App) -> bool {
	transcript := &app.transcript
	scroll := &app.conversation_scroll
	if !transcript.measured || transcript.failed { return false }
	transcript.measured = false
	if anchor, pending := transcript.anchor.?; pending {
		transcript.anchor = nil
		if scroll.top != nil { transcript_scroll_to(app, scroll.range - anchor) }
		return true
	}
	height := transcript.viewport_rows
	above := widgets.scroll_offset(scroll^)
	below := scroll.range - above
	near := TRANSCRIPT_LOAD_SCREENS * height
	far := (TRANSCRIPT_WINDOW_SCREENS - 1) / 2 * height
	if above < near && transcript.first > 0 {
		transcript_page_older(app)
		if transcript.failed { return false }
		if scroll.top != nil { transcript.anchor = below }
		return true
	}
	if below < near && transcript.end < len(transcript.path) {
		transcript_page_newer(app)
		return !transcript.failed
	}
	moved := false
	for transcript.end - transcript.first > 1 {
		last := transcript.path[transcript.end - 1]
		rows := transcript_node_rows(transcript, last)
		if below - rows < far { break }
		transcript_pop_node(app, last)
		transcript.end -= 1
		below -= rows
		moved = true
	}
	removed_rows, count := 0, 0
	for transcript.end - transcript.first > 1 {
		first := transcript.path[transcript.first]
		rows := transcript_node_rows(transcript, first)
		if above - removed_rows - rows < far { break }
		for count < len(transcript.entries) && transcript.entries[count].node == first { count += 1 }
		transcript.first += 1
		removed_rows += rows
		moved = true
	}
	if count > 0 {
		for &entry in transcript.entries[:count] { entry_destroy(&entry) }
		remove_range(&transcript.entries, 0, count)
	}
	if removed_rows > 0 && scroll.top != nil { transcript_scroll_to(app, above - removed_rows) }
	return moved
}

transcript_node_rows :: proc(transcript: ^Transcript, node: journal.Node_Id) -> (rows: int) {
	for entry in transcript.entries {
		if entry.node == node { rows += entry.rows }
	}
	return rows
}

// transcript_reduce drops the live entries the window now shows (a follower reports notice nodes live too), and those not running or streaming that lie before the window.
transcript_reduce :: proc(app: ^App) {
	transcript := &app.transcript
	last: journal.Node_Id
	if transcript.end > transcript.first { last = transcript.path[transcript.end - 1] }
	first: journal.Node_Id
	if transcript.first > 0 { first = transcript.path[transcript.first] }

	sync.mutex_guard(&app.run.mu)
	entries := &app.run.snap.entries
	for index := len(entries) - 1; index >= 0; index -= 1 {
		entry := &entries[index]
		covered := entry.after < first && !entry.running && (entry.kind != .Assistant || entry.complete)
		switch {
		case entry.call != 0 && !entry.running:
			covered ||= transcript_has_call(transcript, entry.call)
		case entry.kind == .Assistant:
			covered ||= entry.complete && last > entry.after
		case entry.kind == .User || entry.kind == .Subagent || entry.kind == .Notice:
			covered ||= transcript_has_text(transcript, entry)
		}
		if !covered { continue }
		if entry.call != 0 {
			for &stored in transcript.entries {
				if stored.call != entry.call { continue }
				stored.tool_scroll = entry.tool_scroll
				if entry.id == transcript.selected_entry { transcript.selected_entry = stored.id }
				break
			}
		}
		app.run.snap.image_bytes -= entry.image.bytes
		entry_destroy(entry)
		ordered_remove(entries, index)
	}
	boxes_prune(app)
}

transcript_has_call :: proc(transcript: ^Transcript, call: journal.Call_Id) -> bool {
	for entry in transcript.entries {
		if entry.call == call { return true }
	}
	return false
}

transcript_has_text :: proc(transcript: ^Transcript, live: ^Entry) -> bool {
	for entry in transcript.entries {
		if entry.kind == live.kind && entry.node >= live.after && string(entry.text[:]) == string(live.text[:]) { return true }
	}
	return false
}

// entry_find returns the entry with id from the window or the live layer, or nil. The
// caller holds the runtime mutex; the pointer is valid until the entries change.
@(require_results)
entry_find :: proc(app: ^App, id: u64) -> ^Entry {
	for &entry in app.transcript.entries {
		if entry.id == id { return &entry }
	}
	#reverse for &entry in app.run.snap.entries {
		if entry.id == id { return &entry }
	}
	return nil
}

// boxes_collapse_all frees the whole text of every expanded box.
boxes_collapse_all :: proc(app: ^App) {
	app.transcript.active_call = 0
	for _, full in app.transcript.expanded { delete(full, app.run.alloc) }
	clear(&app.transcript.expanded)
}

// boxes_prune collapses the boxes that left the window and the live layer. The caller holds the runtime mutex.
boxes_prune :: proc(app: ^App) {
	transcript := &app.transcript
	if transcript.selected_entry != 0 && entry_find(app, transcript.selected_entry) == nil {
		transcript.selected_entry, transcript.selection_step = 0, 0
	}
	if call := transcript.active_call; call != 0 && !transcript_has_call(transcript, call) && snap_tool_entry_locked(app, call) == nil {
		transcript.active_call = 0
	}
	gone := make([dynamic]journal.Call_Id, context.temp_allocator)
	for call in transcript.expanded {
		if transcript_has_call(transcript, call) || snap_tool_entry_locked(app, call) != nil { continue }
		append(&gone, call)
	}
	for call in gone {
		delete(transcript.expanded[call], app.run.alloc)
		delete_key(&transcript.expanded, call)
	}
}

// box_prefix returns a copy in the temporary allocator of the text of the settled box of
// call that precedes its result, or false when the box cannot be expanded.
box_prefix :: proc(app: ^App, call: journal.Call_Id) -> (prefix: string, found: bool) {
	sync.mutex_guard(&app.run.mu)
	for &entry in app.transcript.entries {
		if entry.call == call { return box_prefix_of(&entry) }
	}
	if entry := snap_tool_entry_locked(app, call); entry != nil { return box_prefix_of(entry) }
	return "", false
}

box_prefix_of :: proc(entry: ^Entry) -> (prefix: string, found: bool) {
	if entry.running || entry.preview_at <= 0 || entry.preview_at > len(entry.text) { return "", false }
	return strings.clone(string(entry.text[:entry.preview_at]), context.temp_allocator) or_else "", true
}

// box_toggle collapses the box of call if it is expanded. Otherwise it reads the call's
// completion from the journal and keeps the box's whole text until it is collapsed or
// leaves the transcript. Main thread only; it reads the journal, so the runtime mutex must not be held.
box_toggle :: proc(app: ^App, call: journal.Call_Id) {
	transcript := &app.transcript
	if call == 0 { return }
	if full, expanded := transcript.expanded[call]; expanded {
		delete(full, app.run.alloc)
		delete_key(&transcript.expanded, call)
		if transcript.active_call == call { transcript.active_call = 0 }
		return
	}
	prefix, found := box_prefix(app, call)
	if !found || !transcript_open(app) { return }
	records, _, read_error := journal.read_records(
		&transcript.store,
		{session = transcript.session, kinds = {.Tool_Completed}, call = call},
		0,
		1,
		context.temp_allocator,
	)
	if read_error != nil {
		snap_append(app, .Error, fmt.tprintf("cannot read the result: %s", journal.error_text(read_error, context.temp_allocator)))
		return
	}
	if len(records) == 0 {
		snap_append(app, .Warning, "the result of that call is not in the journal")
		return
	}
	completion: journal.Tool_Completed
	if decode_error := journal.payload_decode(records[0].data, &completion, context.temp_allocator); decode_error != nil {
		snap_append(app, .Error, "cannot read the result: the record is damaged")
		return
	}
	outcome, _ := journal.enum_from_name(journal.TOOL_OUTCOME_NAMES, completion.outcome)
	content := string(records[0].body)
	if content == "" { content = completion.detail }
	full, concatenate_error := strings.concatenate({prefix, tool_preview(content, journal.TOOL_OUTCOME_NAMES[outcome])}, app.run.alloc)
	if concatenate_error != nil {
		snap_append(app, .Error, "cannot read the result: out of memory")
		return
	}
	if transcript.expanded.allocator.procedure == nil { transcript.expanded.allocator = app.run.alloc }
	_, slot, _, map_error := map_entry(&transcript.expanded, call)
	if map_error != nil {
		delete(full, app.run.alloc)
		snap_append(app, .Error, "cannot read the result: out of memory")
		return
	}
	slot^ = full
}

// transcript_focus gives the keyboard to the transcript and focuses the box nearest the middle of the view, if any.
transcript_focus :: proc(app: ^App) {
	sync.mutex_guard(&app.run.mu)
	transcript := &app.transcript
	transcript.selection_step = 0
	transcript_select_visible(app, transcript_order(app))
}

// transcript_target is the one setter for the keyboard and mouse target. It focuses the transcript and
// selects entry when it is a box; ordinary text and nil select no box. A box that is not entry's
// deactivates. It does not touch selection_step, which the caller resets for new input intent.
// The caller holds the runtime mutex.
transcript_target :: proc(app: ^App, entry: ^Entry) {
	transcript := &app.transcript
	transcript.focused = true
	transcript.selected_entry = entry.id if entry != nil && transcript_is_box(entry) else 0
	if entry == nil || transcript.active_call != entry.call { transcript.active_call = 0 }
}

// transcript_blur returns the keyboard to the prompt and drops the target and any active box.
transcript_blur :: proc(app: ^App) {
	transcript := &app.transcript
	transcript.active_call = 0
	transcript.focused = false
	transcript.selected_entry, transcript.selection_step = 0, 0
}

// transcript_press_document handles a press that is not on a tool box: it focuses the transcript and
// drops the box selection, any active box, and pending keyboard steps. The press maps no row.
transcript_press_document :: proc(app: ^App) {
	sync.mutex_guard(&app.run.mu)
	transcript := &app.transcript
	transcript.selection_step = 0
	transcript_target(app, nil)
}

// transcript_reselect focuses the box nearest the middle of the view after a wheel scroll that did not land on
// an expanded box, and drops any active box.
transcript_reselect :: proc(app: ^App) {
	sync.mutex_guard(&app.run.mu)
	transcript := &app.transcript
	transcript.active_call = 0
	transcript.selection_step = 0
	transcript_select_visible(app, transcript_order(app))
}

// transcript_tool_scroll moves the window of the active box by delta rows. The wheel and the arrow keys
// share this step. It scrolls the selected entry itself, and reports false when that entry is not the
// active box, so the caller can drop the activation. The caller holds the runtime mutex.
@(require_results)
transcript_tool_scroll :: proc(app: ^App, delta: int) -> bool {
	transcript := &app.transcript
	entry := entry_find(app, transcript.selected_entry)
	if entry == nil || transcript.active_call == 0 || entry.call != transcript.active_call { return false }
	_ = widgets.scroll_by(&entry.tool_scroll, delta)
	return true
}

// transcript_is_box reports whether entry is an atomic box: a tool or a Code Mode call.
transcript_is_box :: proc(entry: ^Entry) -> bool {
	return entry.kind == .Tool || entry.kind == .Codemode
}

// transcript_select_visible selects the box in view nearest the middle of the viewport, or no box when none is in view.
// Focus follows the scroll offset; it never moves it. The caller holds the runtime mutex.
transcript_select_visible :: proc(app: ^App, order: []^Entry) {
	top := widgets.scroll_offset(app.conversation_scroll)
	bottom := top + app.transcript.viewport_rows
	middle := top + app.transcript.viewport_rows / 2
	best: ^Entry
	best_distance := max(int)
	start := 0
	for entry in order {
		if transcript_is_box(entry) && entry.rows > 0 && start + entry.rows > top && start < bottom {
			distance := max(start - middle, middle - (start + entry.rows - 1), 0)
			if distance < best_distance { best, best_distance = entry, distance }
		}
		start += entry.rows
	}
	transcript_target(app, best)
}

// transcript_select_neighbor selects the nearest box in view beyond the selected one in delta, for a
// view that cannot scroll that way, so the boxes at the true edge stay reachable. It reports false
// when no such box is left. The caller holds the runtime mutex.
@(require_results)
transcript_select_neighbor :: proc(app: ^App, order: []^Entry, delta: int) -> bool {
	transcript := &app.transcript
	top := widgets.scroll_offset(app.conversation_scroll)
	bottom := top + transcript.viewport_rows
	anchor := top - 1 if delta > 0 else bottom
	start := 0
	for entry in order {
		if transcript.selected_entry != 0 && entry.id == transcript.selected_entry {
			anchor = start
			break
		}
		start += entry.rows
	}
	chosen: ^Entry
	start = 0
	for entry in order {
		if transcript_is_box(entry) && entry.rows > 0 && start + entry.rows > top && start < bottom {
			if delta > 0 && start > anchor {
				chosen = entry
				break
			}
			if delta < 0 && start < anchor { chosen = entry }
		}
		start += entry.rows
	}
	if chosen == nil { return false }
	transcript_target(app, chosen)
	return true
}

// transcript_move scrolls the view one row, reading only the actual scroll offset, then focuses the box
// nearest the middle of the view. A box never moves the offset, so scrolling up and down is the same smooth step.
// At the offset's true edge with no step left, it selects the next box in view instead. It returns false when
// the offset cannot move and either the loaded window ends before the step, so the caller loads a page and
// replays, or no box is left at the edge. The caller holds the runtime mutex.
@(require_results)
transcript_move :: proc(app: ^App, order: []^Entry, delta: int) -> bool {
	transcript := &app.transcript
	scroll := &app.conversation_scroll
	top := widgets.scroll_offset(scroll^)
	target := clamp(top + delta, 0, scroll.range)
	if target != top {
		transcript_scroll_to(app, target)
		transcript_select_visible(app, order)
		return true
	}
	edge := transcript.failed || (delta < 0 && transcript.first == 0) || (delta > 0 && transcript.end == len(transcript.path))
	return edge && transcript_select_neighbor(app, order, delta)
}

// transcript_arrow scrolls the active box, consuming boundary arrows, or steps the transcript one row or box.
transcript_arrow :: proc(app: ^App, delta: int) {
	sync.mutex_guard(&app.run.mu)
	transcript := &app.transcript
	order := transcript_order(app)
	if transcript.active_call != 0 {
		if transcript_tool_scroll(app, delta) { return }
		transcript.active_call = 0
	}
	if transcript.selection_step == 0 && transcript_move(app, order, delta) { return }
	transcript.selection_step += delta
	if transcript.selection_step == 0 { return }
	if transcript.failed ||
	   (transcript.selection_step < 0 && transcript.first == 0) ||
	   (transcript.selection_step > 0 && transcript.end == len(transcript.path)) {
		transcript.selection_step = 0
		return
	}
	transcript_scroll_to(app, 0 if transcript.selection_step < 0 else app.conversation_scroll.range)
}

// transcript_activate toggles off the active box or activates the selected toolbox. Ordinary blocks do not activate tools.
transcript_activate :: proc(app: ^App) {
	transcript := &app.transcript
	if transcript.active_call != 0 {
		box_toggle(app, transcript.active_call)
		return
	}
	call: journal.Call_Id
	if sync.mutex_guard(&app.run.mu) {
		if entry := entry_find(app, transcript.selected_entry); entry != nil && (entry.kind == .Tool || entry.kind == .Codemode) {
			call = entry.call
		}
	}
	if call == 0 { return }
	transcript.selection_step = 0
	if call not_in transcript.expanded { box_toggle(app, call) }
	if call in transcript.expanded { transcript.active_call = call }
}
