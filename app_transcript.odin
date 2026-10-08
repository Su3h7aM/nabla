#+build linux
package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:sync"

import "nabla:agent"
import "nabla:agent/journal"
import "nabla:ai"
import "nabla:layout"

// TRANSCRIPT_WINDOW_SCREENS is the screens of the conversation area the window holds: the
// visible one, two above, and two below. The user asked to scroll back to the first prompt
// of any session without memory growing with it, so memory follows what can be seen next.
TRANSCRIPT_WINDOW_SCREENS :: 5

// TRANSCRIPT_LOAD_SCREENS is how near the window's edge the view may come before the next page is read.
TRANSCRIPT_LOAD_SCREENS :: 1

// TRANSCRIPT_PAGE_NODES is how many whole nodes one read adds to the window.
TRANSCRIPT_PAGE_NODES :: 16

// WINDOW_ENTRY_FLAG marks window entry ids, which are made from the node and the entry's
// place in it. Live entry ids count from one and never carry the flag.
WINDOW_ENTRY_FLAG :: u64(1) << 63
WINDOW_ORDINAL_BITS :: 20

CHECKPOINT_NOTICE :: "(earlier turns are summarized)"

// Transcript is the committed history on screen: a window onto the session's node path.
// Only the main thread uses it. The zero value shows nothing.
Transcript :: struct {
	store:         journal.Journal, // read-only, opened by the first read
	session:       journal.Session_Id,
	path:          []journal.Node_Id, // owned by the run's allocator; the active branch, oldest first, as of head
	head:          journal.Node_Id,
	first:         int, // the window is path[first:end]
	end:           int,
	entries:       [dynamic]Entry, // owned; the entries of the window's nodes, oldest first
	failed:        bool, // a page read failed; cleared by a new head or session
	measured:      bool, // the transcript was laid out since the last slide
	viewport_rows: int,
	anchor:        Maybe(int), // rows above the view when a page was loaded below it
}

transcript_destroy :: proc(app: ^App) {
	transcript := &app.transcript
	entries_destroy(&transcript.entries)
	delete(transcript.path, app.run.alloc)
	_ = journal.close(&transcript.store)
	transcript^ = {}
}

entries_destroy :: proc(entries: ^[dynamic]Entry) {
	for &entry in entries { entry_destroy(&entry) }
	delete(entries^)
	entries^ = nil
}

// transcript_sync brings the window to the session and head the worker published, then
// drops the live entries the window covers. It reads the first page only.
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
		app.scroll = 0
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
			entries_destroy(&transcript.entries)
			transcript.first, transcript.end = 0, 0
			transcript.anchor = nil
			loaded = false
		}
	}
	delete(transcript.path, app.run.alloc)
	transcript.path = path
	if !loaded && len(path) > 0 { transcript_page_tail(app) }
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

// transcript_page_newer reads the window's last node again with the page, because the
// results of its tool calls may have been committed since.
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
	return entries, nil
}

// window_entries maps a projection to the entries a live turn shows. A call with no
// committed completion has no entry: only the live layer shows it running.
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
			kind := Entry_Kind.Notice
			if payload.origin == .Prompt || payload.origin == .Agent { kind = user_entry_kind(payload.origin) }
			_ = window_push(app, entries, item.node, kind, payload.text) or_return
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
		id   = WINDOW_ENTRY_FLAG | u64(node) << WINDOW_ORDINAL_BITS | u64(ordinal),
		node = node,
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
		entry := window_push(app, entries, node, .Codemode, text) or_return
		entry.call = stored.call
		entry.tool_outcome = result.outcome
		return nil
	}
	text := tool_entry_text(display, result.content, fallback, result.outcome)
	return window_tool(app, entries, node, .Tool, stored.call, text, result.outcome, result.attachments)
}

@(require_results)
window_tool :: proc(
	app: ^App,
	entries: ^[dynamic]Entry,
	node: journal.Node_Id,
	kind: Entry_Kind,
	call: journal.Call_Id,
	text: string,
	outcome: journal.Tool_Outcome,
	attachments: []ai.Provider_Attachment,
) -> mem.Allocator_Error {
	image := image_prepare(app, attachments)
	defer delete(image.pixels)
	entry := window_push(app, entries, node, kind, text) or_return
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
			text := tool_entry_text_titled(display, codemode_inner_title(child.name), child.content, journal.TOOL_OUTCOME_NAMES[child.outcome], child.outcome)
			window_tool(app, entries, item.node, .Codemode, child.call, text, child.outcome, child.attachments) or_return
			break
		}
	}
	return nil
}

// codemode_inner_list lists the calls of parent_call for its box. The list and the strings
// it borrows live as long as nested and the temporary allocator.
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

// transcript_order lists the entries a frame draws, oldest first, in the temporary
// allocator. A live entry follows the entries of its node, and is not drawn while the
// window has not reached it.
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
	return order[:]
}

// transcript_measure records the rows each entry of order took in the solved frame, which declared them in that order.
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
}

// transcript_slide moves the window after a frame was laid out and reports whether the
// frame has to be laid out again. Within a screen of the window's edge it reads the next
// page there, and it drops whole nodes more than two screens beyond the other side. The
// scroll, which counts rows from the bottom, changes by the rows added or removed below
// the view, so the view does not move.
transcript_slide :: proc(app: ^App) -> bool {
	moved := transcript_slide_step(app)
	if moved { transcript_reduce(app) }
	return moved
}

transcript_slide_step :: proc(app: ^App) -> bool {
	transcript := &app.transcript
	if !transcript.measured || transcript.failed { return false }
	transcript.measured = false
	if anchor, pending := transcript.anchor.?; pending {
		transcript.anchor = nil
		app.scroll = max(app.conv_scroll_range - anchor, 0)
		return true
	}
	height := transcript.viewport_rows
	above := app.conv_scroll_range - app.scroll
	below := app.scroll
	near := TRANSCRIPT_LOAD_SCREENS * height
	far := (TRANSCRIPT_WINDOW_SCREENS - 1) / 2 * height
	if above < near && transcript.first > 0 {
		transcript_page_older(app)
		return !transcript.failed
	}
	if below < near && transcript.end < len(transcript.path) {
		transcript_page_newer(app)
		if transcript.failed { return false }
		transcript.anchor = above
		return true
	}
	if transcript.end - transcript.first <= 1 { return false }
	last := transcript.path[transcript.end - 1]
	if rows := transcript_node_rows(transcript, last); below - rows >= far {
		transcript_pop_node(app, last)
		transcript.end -= 1
		app.scroll = max(app.scroll - rows, 0)
		return true
	}
	first := transcript.path[transcript.first]
	if rows := transcript_node_rows(transcript, first); above - rows >= far {
		count := 0
		for count < len(transcript.entries) && transcript.entries[count].node == first { count += 1 }
		for &entry in transcript.entries[:count] { entry_destroy(&entry) }
		remove_range(&transcript.entries, 0, count)
		transcript.first += 1
		return true
	}
	return false
}

transcript_node_rows :: proc(transcript: ^Transcript, node: journal.Node_Id) -> (rows: int) {
	for entry in transcript.entries {
		if entry.node == node { rows += entry.rows }
	}
	return rows
}

// transcript_reduce drops the live entries whose committed form the window shows: a
// finished box whose call has a box there, a complete answer once the window holds a newer
// node, and a sent line the window shows. It also drops the entries that are not running or
// streaming when the window starts after their node, since notices are never journaled.
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
		case entry.kind == .User || entry.kind == .Subagent:
			covered ||= transcript_has_text(transcript, entry)
		}
		if !covered { continue }
		app.run.snap.image_bytes -= entry.image.bytes
		entry_destroy(entry)
		ordered_remove(entries, index)
	}
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
