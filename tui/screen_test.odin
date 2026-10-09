#+build linux
#+test
package tui

import "../term"
import "core:os"
import "core:strings"
import "core:terminal/ansi"
import "core:testing"

// Screen_Pipe is a session whose terminal output is a pipe, so a test reads
// back the bytes screen_present wrote.
Screen_Pipe :: struct {
	session: term.Session,
	reader:  ^os.File,
}

screen_pipe_open :: proc(pipe: ^Screen_Pipe) -> bool {
	reader, writer, err := os.pipe()
	if err != nil {
		return false
	}
	pipe.reader = reader
	pipe.session = {
		opened = true,
		impl = {file = writer},
	}
	return true
}

screen_pipe_close :: proc(pipe: ^Screen_Pipe) {
	_ = os.close(pipe.session.impl.file)
	_ = os.close(pipe.reader)
}

// screen_pipe_take returns what the last present wrote. Every present is one
// write, so one read returns it whole.
screen_pipe_take :: proc(pipe: ^Screen_Pipe, storage: []byte) -> string {
	count, _ := os.read(pipe.reader, storage)
	return string(storage[:count])
}

screen_draw :: proc(t: ^testing.T, screen: ^Screen) -> bool {
	buffer, err := screen_begin(screen, 4, 2)
	if !testing.expect_value(t, err, nil) {
		return false
	}
	return testing.expect(t, put(buffer, 1, 1, "x", {}))
}

@(test)
test_screen_second_present_of_an_unchanged_frame_writes_only_the_wrap_and_cursor :: proc(t: ^testing.T) {
	pipe: Screen_Pipe
	if !testing.expect(t, screen_pipe_open(&pipe)) { return }
	defer screen_pipe_close(&pipe)
	screen: Screen
	screen_init(&screen, context.allocator)
	defer screen_destroy(&screen)
	storage: [4096]byte
	cursor := term.Cursor {
		visible = true,
	}

	if !screen_draw(t, &screen) { return }
	testing.expect_value(t, screen_present(&screen, &pipe.session, term.profile_default(), cursor), nil)
	first := screen_pipe_take(&pipe, storage[:])
	testing.expect(t, strings.contains(first, "x"), "the first frame writes the cells")

	if !screen_draw(t, &screen) { return }
	testing.expect_value(t, screen_present(&screen, &pipe.session, term.profile_default(), cursor), nil)
	second := screen_pipe_take(&pipe, storage[:])
	expected := strings.concatenate(
		{term.SYNC_BEGIN, ansi.CSI + ansi.SGR, ansi.CSI + ansi.DECTCEM_SHOW, ansi.CSI + ansi.SGR, term.SYNC_END},
		context.temp_allocator,
	)
	testing.expect_value(t, second, expected)
}

@(test)
test_screen_failed_present_forgets_the_snapshot :: proc(t: ^testing.T) {
	pipe: Screen_Pipe
	if !testing.expect(t, screen_pipe_open(&pipe)) { return }
	defer screen_pipe_close(&pipe)
	screen: Screen
	screen_init(&screen, context.allocator)
	defer screen_destroy(&screen)
	storage: [4096]byte

	if !screen_draw(t, &screen) { return }
	testing.expect_value(t, screen_present(&screen, &pipe.session, term.profile_default(), {}), nil)
	testing.expect(t, screen.previous_known, "a presented frame is remembered")
	_ = screen_pipe_take(&pipe, storage[:])

	closed: term.Session
	if !screen_draw(t, &screen) { return }
	err := screen_present(&screen, &closed, term.profile_default(), {})
	testing.expect_value(t, err, term.General_Error.Not_Open)
	testing.expect(t, !screen.previous_known, "a failed present forgets the frame")

	if !screen_draw(t, &screen) { return }
	testing.expect_value(t, screen_present(&screen, &pipe.session, term.profile_default(), {}), nil)
	full := screen_pipe_take(&pipe, storage[:])
	testing.expect(t, strings.contains(full, ansi.CSI + ansi.CUP), "the next frame is a full one")
}
