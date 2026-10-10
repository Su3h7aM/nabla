package tui

import "../term"
import "base:runtime"
import "core:mem"
import "core:slice"

// Screen owns the frame lifecycle of one terminal: the buffer a frame is drawn
// into, the scratch term.present serializes into, and a private copy of the
// last frame that reached the terminal, which the next present diffs against.
// The zero value is inert; screen_init sets the allocator that every later
// allocation uses.
Screen :: struct {
	buffer:         term.Frame_Buffer,
	cells:          []term.Cell,
	output:         []byte,
	// The snapshot's strings live in previous_text because the buffer's own strings borrow
	// from storage that the next frame recycles.
	previous:       Maybe(term.Frame_Buffer),
	previous_cells: []term.Cell,
	previous_text:  []byte,
	previous_links: []string,
	allocator:      runtime.Allocator,
}

// screen_init prepares an uninitialized screen to allocate from allocator.
// It allocates nothing, and screen must not own storage.
screen_init :: proc(screen: ^Screen, allocator: runtime.Allocator) {
	screen^ = {
		allocator = allocator,
	}
}

// screen_destroy releases everything screen owns and returns it to the zero value.
screen_destroy :: proc(screen: ^Screen) {
	delete(screen.cells, screen.allocator)
	delete(screen.output, screen.allocator)
	delete(screen.previous_cells, screen.allocator)
	delete(screen.previous_text, screen.allocator)
	delete(screen.previous_links, screen.allocator)
	screen^ = {}
}

// screen_begin sizes the buffer to columns by rows, fills it with blanks, and
// returns it for drawing. The buffer and its cells are valid until the next
// screen_begin or screen_destroy; the caller sets its links before
// screen_present. The snapshot is kept, since the terminal still shows it.
// It returns .Invalid_Frame_Data for a negative size and an allocator error
// when the cells cannot be grown, leaving the screen as it was.
@(require_results)
screen_begin :: proc(screen: ^Screen, columns, rows: int) -> (buffer: ^term.Frame_Buffer, err: term.Error) {
	if columns < 0 || rows < 0 {
		return nil, term.General_Error.Invalid_Frame_Data
	}
	_screen_reserve(&screen.cells, columns * rows, screen.allocator) or_return
	if !init(&screen.buffer, columns, rows, screen.cells) {
		return nil, term.General_Error.Invalid_Frame_Data
	}
	return &screen.buffer, nil
}

// screen_present writes the frame drawn since screen_begin to session. It sends
// only the cells that differ from the last presented frame when the snapshot is
// valid, and the whole frame otherwise. A scratch that is too small is grown to
// the size term.present reports and the frame is retried once.
//
// On success the frame becomes the snapshot. A failed present forgets the
// snapshot, since the terminal may show a partial frame, so the next frame is a
// full one; its error is returned unchanged. An allocator error is returned when
// the scratch cannot grow (the snapshot stays valid, nothing was written) or
// when the frame cannot be copied (the frame was written, the snapshot is
// forgotten).
@(require_results)
screen_present :: proc(screen: ^Screen, session: ^term.Session, profile: term.Target_Profile, cursor: term.Cursor) -> term.Error {
	previous, have_previous := screen.previous.?
	previous_frame := &previous if have_previous else nil
	_, required, err := term.present(session, screen.buffer, profile, cursor, screen.output, previous_frame)
	if err == term.General_Error.Presentation_Workspace_Too_Small {
		_screen_reserve(&screen.output, required, screen.allocator) or_return
		_, _, err = term.present(session, screen.buffer, profile, cursor, screen.output, previous_frame)
	}
	if err != nil {
		screen.previous = nil
		return err
	}
	return _screen_remember(screen)
}

// screen_invalidate forgets the snapshot, so the next present is a full frame.
// Call it when the terminal's contents are no longer the last presented frame.
screen_invalidate :: proc(screen: ^Screen) {
	screen.previous = nil
}

_screen_reserve :: proc(items: ^[]$T, count: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
	if len(items^) >= count {
		return nil
	}
	grown := mem.resize_non_zeroed(raw_data(items^), len(items^) * size_of(T), count * size_of(T), align_of(T), allocator) or_return
	if grown == nil {
		return .Out_Of_Memory
	}
	items^ = slice.from_ptr(cast(^T)grown, count)
	return nil
}

_screen_remember :: proc(screen: ^Screen) -> runtime.Allocator_Error {
	screen.previous = nil
	buffer := screen.buffer
	count := len(buffer.cells)
	text_size := 0
	for cell in buffer.cells {
		text_size += len(cell.grapheme)
	}
	for uri in buffer.links {
		text_size += len(uri)
	}
	_screen_reserve(&screen.previous_text, text_size, screen.allocator) or_return
	_screen_reserve(&screen.previous_cells, count, screen.allocator) or_return
	_screen_reserve(&screen.previous_links, len(buffer.links), screen.allocator) or_return

	used := 0
	copy_text :: proc(text: []byte, used: ^int, value: string) -> string {
		copy(text[used^:], value)
		copied := string(text[used^:][:len(value)])
		used^ += len(value)
		return copied
	}
	for uri, i in buffer.links {
		screen.previous_links[i] = copy_text(screen.previous_text, &used, uri)
	}
	for cell, i in buffer.cells {
		screen.previous_cells[i] = cell
		screen.previous_cells[i].grapheme = copy_text(screen.previous_text, &used, cell.grapheme)
	}
	screen.previous = term.Frame_Buffer {
		columns = buffer.columns,
		rows    = buffer.rows,
		cells   = screen.previous_cells[:count],
		links   = screen.previous_links[:len(buffer.links)],
	}
	return nil
}
