#+build linux
package main

// Compile-only example of the exact target call shapes of the terminal
// package (frozen spec §6.2 session lifecycle, §6.3 viewport, §6.7
// encoding/presentation). It is verified by scripts/check / odin build;
// running it requires a real controlling terminal, so it is never executed
// by the test suite.

import "core:fmt"
import "core:os"
import "nabla:term"

main :: proc() {
	session, open_err := term.open({alternate_screen = true, hide_cursor = true, input_mode = .Raw})
	if open_err != nil {
		fmt.eprintln("open:", open_err)
		os.exit(1)
	}
	// Ownership (§6.2): close frees the Session with its stored allocator.
	// The caller never calls free(session); after a successful close the
	// pointer is dead. A teardown failure leaves the session allocated and
	// close can be retried with the same pointer.
	defer {
		if close_err := term.close(session); close_err != nil {
			fmt.eprintln("close:", close_err)
		}
	}

	// The tty file is borrowed by the session: the input parser may read it
	// but must never close it.
	tty, file_err := term.session_file(session)
	if file_err != nil {
		fmt.eprintln("session_file:", file_err)
		os.exit(1)
	}
	_ = tty

	// Viewport polling (§6.3) is the sole resize contract: compare with the
	// previous value each iteration, invalidate text metrics on change, and
	// force a complete redraw.
	viewport, vp_err := term.viewport(session)
	if vp_err != nil {
		fmt.eprintln("viewport:", vp_err)
		os.exit(1)
	}

	frame := term.Frame_Buffer {
		columns = viewport.columns,
		rows    = viewport.rows,
		cells   = make([]term.Cell, viewport.columns * viewport.rows),
	}
	defer delete(frame.cells)
	for &cell in frame.cells {
		cell = {
			grapheme = " ",
			width    = 1,
		}
	}
	profile := term.profile_default()
	cursor := term.Cursor_Intent(term.Hide{})

	// Caller-owned reusable output scratch (§6.7): size once with the exact
	// required count, encode, then present — one buffered write per frame.
	output := make([]byte, 1 << 20)
	defer delete(output)

	required, size_err := term.encoded_size(frame, profile, cursor)
	if size_err != nil {
		fmt.eprintln("encoded_size:", size_err)
		os.exit(1)
	}
	if required > len(output) {
		fmt.eprintln("output scratch too small:", required)
		os.exit(1)
	}

	written, _, encode_err := term.encode(frame, profile, cursor, output)
	if encode_err != nil {
		fmt.eprintln("encode:", encode_err)
		os.exit(1)
	}
	_ = written // the caller consumes output[:written]

	_, _, present_err := term.present(session, frame, profile, cursor, output)
	if present_err != nil {
		fmt.eprintln("present:", present_err)
		os.exit(1)
	}

	_ = term.close(nil) // documented no-op
}
