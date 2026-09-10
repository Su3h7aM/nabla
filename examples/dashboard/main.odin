#+build linux
package main

// The dashboard example demonstrates the current layout and terminal
// packages end to end: a terminal session (raw mode, alternate screen), a
// per-frame viewport re-read with automatic resize re-render, a
// layout-composed scene (panels.odin), full-frame present with
// environment-based color depth and a visible cursor that follows the
// selection, and keyboard input driving the selection.
//
// Terminal features exercised here: open/close with options, viewport and
// resize re-read (the loop re-reads the viewport every wake and re-renders
// when the size moved — no keypress needed), the env-based default
// profile, depth-aware color emission, full-frame present with the corner
// reservation and run-gated style diff, Cursor_Intent.Position (the
// cursor tracks the selected row), and clean teardown. The layout features
// are exercised inside panels.odin; see README.md for the full list.
//
// Run: ./scripts/example (or `mise run example`). Requires a real
// terminal — outside a PTY, open reports No_Controlling_Tty.

import "core:fmt"
import "core:os"
import input "nabla:input"
import "nabla:layout"
import "nabla:tty"

// State is the app state the input loop drives and panels.render reads.
// main owns it (input updates it); panels.odin only reads it. selected is
// not clamped here — panels.render treats an out-of-range selection as no
// highlight.
State :: struct {
	selected: int,
}

// Render_Error classifies a failed frame; panels.render returns it
// (present()'s own failures stay on the terminal side, so
// .Presentation_Too_Small does not appear here). The loop keeps running on
// render failures — the session stays open, so the next frame can recover.
Render_Error :: enum u8 {
	None,
	Layout_Failed,
	Buffer_Too_Small,
	Not_Integral,
	Undrawable_Text,
}

// render and Render_Storage are defined in panels.odin (the layout
// showcase); this file consumes them. Contract: render builds the scene
// for (state, viewport) into caller-owned storage and returns the
// terminal frame ready for present.

main :: proc() {
	// The cursor stays visible so Cursor_Intent.Position is demonstrable:
	// it follows the selected row (panels.render returns it each frame).
	session, open_err := tty.open({alternate_screen = true, input_mode = .Raw})
	if open_err != nil {
		fmt.eprintln("dashboard: open:", open_err)
		os.exit(1)
	}
	defer { _ = tty.close(session) }

	tty_file, file_err := tty.session_file(session)
	if file_err != nil {
		fmt.eprintln("dashboard: session file:", file_err)
		os.exit(1)
	}

	parser: input.Parser
	input.parser_init(&parser)
	events: [dynamic]input.Event
	defer delete(events)

	state := State{}
	storage := new(Render_Storage)
	defer free(storage)

	// The input read blocks up to RESIZE_POLL_MS, so a terminal resize is
	// noticed without a keypress: the tty package's SIGWINCH handler
	// flags it, and this loop re-reads the viewport on every wake. The frame
	// re-renders only when something changed (input arrived or the size
	// moved), so an idle terminal does not redraw.
	last_columns, last_rows := -1, -1
	for {
		count, read_err := input.read_events(&parser, tty_file, &events, RESIZE_POLL_MS)
		if read_err != nil {
			fmt.eprintln("dashboard: input:", read_err)
			break
		}
		quit := false
		for event in events {
			#partial switch data in event {
			case input.Key_Event:
				#partial switch data.code {
				case .Down:
					state.selected += 1
				case .Up:
					state.selected -= 1
				case .Escape:
					quit = true
				case .Character:
					if data.character == 'q' {
						quit = true
					}
				case:
				}
			case input.Resize_Event:
			// Resize is handled structurally: the viewport is re-read below
			// and a size change triggers a re-render.
			case input.End_Of_Input:
				quit = true
			case input.Unknown_Input:
			}
		}
		clear(&events)

		viewport, vp_err := tty.viewport(session)
		if vp_err != nil {
			fmt.eprintln("dashboard: viewport:", vp_err)
			break
		}
		if count > 0 || viewport.columns != last_columns || viewport.rows != last_rows {
			frame, cursor, render_err := render(&state, layout.Vec2{layout.Scalar(viewport.columns), layout.Scalar(viewport.rows)}, storage)
			if render_err != .None {
				fmt.eprintln("dashboard: render:", render_err)
			} else if _, _, present_err := tty.present(session, frame, tty.profile_default(), cursor, storage.output[:]); present_err != nil {
				fmt.eprintln("dashboard: present:", present_err)
				break
			}
			last_columns, last_rows = viewport.columns, viewport.rows
		}
		if quit {
			break
		}
	}
}

// RESIZE_POLL_MS bounds how long the input read blocks between frames, so a
// terminal resize is re-rendered within that window without any input. An
// idle terminal simply wakes, sees the unchanged viewport, and blocks again.
RESIZE_POLL_MS :: 100
