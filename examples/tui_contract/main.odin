package main

// Compile-only example of the core TUI storage and full-frame call shape.
// The caller owns render cadence and all reusable storage.

import "nabla:tty"
import "nabla:tui"

main :: proc() {
	cell_storage: [80 * 24]tui.Cell
	buffer: tui.Cell_Buffer
	if !tui.init(&buffer, 80, 24, cell_storage[:]) {
		return
	}

	_ = tui.put(&buffer, 0, 0, tui.Cell{grapheme = "N"})

	terminal_storage: [80 * 24]tty.Cell
	frame, frame_ok := tui.build_frame(buffer, terminal_storage[:])
	if !frame_ok {
		return
	}

	// A real application passes frame to tty.present after opening a
	// session and providing reusable output scratch. No package retains it.
	_ = frame

	empty: tui.Cell_Buffer
	if tui.init(&empty, 0, 0, nil) {
		empty_frame, empty_ok := tui.build_frame(empty, nil)
		_ = empty_frame
		_ = empty_ok
	}
}
