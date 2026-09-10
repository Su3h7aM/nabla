#+build linux
package tty

import "core:c"
import "core:strings"
import "core:sys/posix"
import "core:thread"

// The suite exercises only real, tty-free logic: frame encoding bytes, the
// env-based default profile, validation, and the write loop. Session
// lifecycle against a real terminal is exercised end to end by the demo and
// by the PTY tests.
//
// Expected bytes are written with \x1b hex escapes (not \e) so a mangled ESC
// literal cannot satisfy the expectation vacuously.

// encode_frame serializes buffer through the public encode contract and
// returns the exact output bytes. Tests use this instead of the internal
// serializer so the byte fixtures pin the public path.
@(private)
encode_frame :: proc(buffer: Frame_Buffer, profile: Target_Profile, cursor: Cursor_Intent, scratch: []byte) -> (out: string, ok: bool) {
	written, required, err := encode(buffer, profile, cursor, scratch)
	if err != nil {
		return "", false
	}
	// The exact required count is part of the contract: written must equal
	// it, and encoded_size must agree.
	required_size, size_err := encoded_size(buffer, profile, cursor)
	if size_err != nil {
		return "", false
	}
	if required != required_size || written != required {
		return "", false
	}
	return string(scratch[:written]), true
}

@(private)
test_present_requires_an_open_session :: proc(t: ^T) {
	committed, required, err := present(nil, {}, profile_default(), {}, nil)
	expect(t, err == General_Error.Not_Open, "present on a nil session must report .Not_Open")
	expect_value(t, committed, 0)
	expect_value(t, required, 0)
}

@(private)
test_encode_matches_the_reference_bytes :: proc(t: ^T) {
	buffer := Frame_Buffer {
		columns = 2,
		rows    = 2,
		cells   = []Cell {
			{grapheme = "a", width = 1},
			{grapheme = "b", width = 1, style = {foreground = Color(RGB_Color{255, 0, 0})}},
			{grapheme = "c", width = 1},
			{grapheme = "d", width = 1},
		},
	}
	profile := Target_Profile {
		color_depth = .True_Color,
	}

	scratch: [4096]byte
	out, ok := encode_frame(buffer, profile, {}, scratch[:])
	expect(t, ok, "a valid frame must encode")

	// Baseline, row 0 (default cell, styled cell), row 1 (default cell; the
	// bottom-right cell is reserved), then the frame-end restore. No cursor.
	// The row-1 default cell emits its own reset because row 0 ended styled
	// (CUP does not reset SGR attributes).
	expected := "\x1b[H\x1b[m\x1b[1;1Ha\x1b[m\x1b[38;2;255;0;0mb\x1b[2;1H\x1b[mc\x1b[m"
	expect_value(t, out, expected)
}

@(private)
test_encode_emits_the_cursor_intent :: proc(t: ^T) {
	// 3x1: x and y write; z is the reserved bottom-right corner.
	buffer := Frame_Buffer {
		columns = 3,
		rows    = 1,
		cells   = []Cell{{grapheme = "x", width = 1}, {grapheme = "y", width = 1}, {grapheme = "z", width = 1}},
	}
	profile := Target_Profile {
		color_depth = .True_Color,
	}

	// Position is emitted as a CUP sequence (1-based) after validation.
	position_scratch: [4096]byte
	out, ok := encode_frame(buffer, profile, Position{1, 0}, position_scratch[:])
	expect(t, ok, "an in-bounds position must encode")
	expect_value(t, out, "\x1b[H\x1b[m\x1b[1;1Hxy\x1b[1;2H\x1b[m")

	// Hide and Show are the DECTCEM private sequences.
	hide_show := [?]bool{true, false}
	for hiding in hide_show {
		scratch: [4096]byte
		intent := Cursor_Intent(Show{})
		sequence := "\x1b[?25h"
		if hiding {
			intent = Cursor_Intent(Hide{})
			sequence = "\x1b[?25l"
		}
		hide_out, hide_ok := encode_frame(buffer, profile, intent, scratch[:])
		expect(t, hide_ok, "hide/show must encode")
		expected := strings.concatenate({"\x1b[H\x1b[m\x1b[1;1Hxy", sequence, "\x1b[m"})
		defer delete(expected)
		expect_value(t, hide_out, expected)
	}
}

@(private)
test_encoded_bytes_use_real_escape_characters :: proc(t: ^T) {
	buffer := Frame_Buffer {
		columns = 2,
		rows    = 2,
		cells   = []Cell{{grapheme = "a", width = 1}, {grapheme = "b", width = 1}, {grapheme = "c", width = 1}, {grapheme = "d", width = 1}},
	}

	scratch: [4096]byte
	out, ok := encode_frame(buffer, profile_default(), Position{1, 1}, scratch[:])
	expect(t, ok, "a valid frame must encode")

	// The stream starts with a real ESC and contains no literal backslash
	// (a mangled "\\e" literal is the exact regression this pins).
	expect(t, len(out) > 0 && out[0] == 0x1b, "encoded frame must start with a real ESC byte")
	for i in 0 ..< len(out) {
		if out[i] == '\\' {
			expect(t, i + 1 >= len(out) || out[i + 1] != 'e', "backslash before 'e' — mangled ESC literal")
		}
	}
}

@(private)
test_control_sequences_start_with_esc :: proc(t: ^T) {
	sequences := [?]string{ALT_SCREEN_ENTER, ALT_SCREEN_LEAVE, CURSOR_HIDE, CURSOR_SHOW}
	for sequence in sequences {
		expect(t, len(sequence) > 0 && sequence[0] == 0x1b, "control sequence must start with a real ESC byte")
		for i in 0 ..< len(sequence) {
			if sequence[i] == '\\' {
				expect(t, i + 1 >= len(sequence) || sequence[i + 1] != 'e', "backslash before 'e' — mangled ESC literal")
			}
		}
	}
}

@(private)
test_color_reduction_helpers :: proc(t: ^T) {
	// xterm cube: 16 + 36r + 6g + b over the 6x6x6 cube.
	expect_value(t, _rgb_to_256(RGB_Color{0, 0, 0}), u8(16))
	expect_value(t, _rgb_to_256(RGB_Color{255, 255, 255}), u8(231))
	expect_value(t, _rgb_to_256(RGB_Color{255, 0, 0}), u8(196))

	// Nearest ANSI: pure red is index 9 (bright) in 16, index 1 in 8.
	expect_value(t, _nearest_ansi(RGB_Color{255, 0, 0}, 16), u8(9))
	expect_value(t, _nearest_ansi(RGB_Color{255, 0, 0}, 8), u8(1))

	// xterm-256 decode: 16/231 are the cube corners, 196 is cube red,
	// 232 is the first grayscale step.
	expect_value(t, _xterm_256_to_rgb(16), RGB_Color{0, 0, 0})
	expect_value(t, _xterm_256_to_rgb(196), RGB_Color{255, 0, 0})
	expect_value(t, _xterm_256_to_rgb(231), RGB_Color{255, 255, 255})
	expect_value(t, _xterm_256_to_rgb(232), RGB_Color{8, 8, 8})

	// SGR codes: 30-37/90-97 foreground, 40-47/100-107 background.
	expect_value(t, _ansi_4bit(38, 0), u8(30))
	expect_value(t, _ansi_4bit(38, 9), u8(91))
	expect_value(t, _ansi_4bit(48, 15), u8(107))
}

@(private)
test_encode_reduces_colors_by_depth :: proc(t: ^T) {
	// One styled cell after a default cell (the trailing cell is the
	// reserved corner); every depth's emission is byte-exact, so a change
	// to any depth's reduction fails here.
	buffer := Frame_Buffer {
		columns = 3,
		rows    = 1,
		cells   = []Cell {
			{grapheme = "a", width = 1},
			{grapheme = "b", width = 1, style = {foreground = Color(RGB_Color{255, 0, 0})}},
			{grapheme = "c", width = 1},
		},
	}
	true_color := "\x1b[H\x1b[m\x1b[1;1Ha\x1b[m\x1b[38;2;255;0;0mb\x1b[m"
	eight_bit := "\x1b[H\x1b[m\x1b[1;1Ha\x1b[m\x1b[38;5;196mb\x1b[m"
	four_bit := "\x1b[H\x1b[m\x1b[1;1Ha\x1b[m\x1b[91mb\x1b[m"
	none := "\x1b[H\x1b[m\x1b[1;1Ha\x1b[mb\x1b[m"

	cases := []struct {
		depth:    Color_Depth,
		expected: string,
	} {
		{depth = .True_Color, expected = true_color},
		{depth = .Eight_Bit, expected = eight_bit},
		{depth = .Four_Bit, expected = four_bit},
		{depth = .None, expected = none},
	}
	for c in cases {
		scratch: [4096]byte
		out, ok := encode_frame(buffer, {color_depth = c.depth}, {}, scratch[:])
		expect(t, ok, "a valid frame must encode")
		expect_value(t, out, c.expected)
	}
}

@(private)
test_encode_emits_style_once_per_run :: proc(t: ^T) {
	// Two adjacent cells with the same style: one SGR group for the run,
	// not one per cell (the fourth cell is the reserved corner).
	buffer := Frame_Buffer {
		columns = 4,
		rows    = 1,
		cells   = []Cell {
			{grapheme = "a", width = 1},
			{grapheme = "b", width = 1, style = {foreground = Color(RGB_Color{255, 0, 0})}},
			{grapheme = "c", width = 1, style = {foreground = Color(RGB_Color{255, 0, 0})}},
			{grapheme = "d", width = 1, style = {foreground = Color(RGB_Color{255, 0, 0})}},
		},
	}
	scratch: [4096]byte
	out, ok := encode_frame(buffer, {color_depth = .True_Color}, {}, scratch[:])
	expect(t, ok, "a valid frame must encode")
	expected := "\x1b[H\x1b[m\x1b[1;1Ha\x1b[m\x1b[38;2;255;0;0mbc\x1b[m"
	expect_value(t, out, expected)
}

@(private)
test_encode_ignores_unused_trailing_cells :: proc(t: ^T) {
	// cells beyond columns * rows are unused backing capacity (zero
	// initialized, width 0); they must not veto the visible frame.
	cells := make([]Cell, 4)
	defer delete(cells)
	cells[0] = Cell {
		grapheme = "a",
		width    = 1,
	}
	cells[1] = Cell {
		grapheme = "b",
		width    = 1,
	}
	cells[2] = Cell {
		grapheme = "c",
		width    = 1,
	}
	buffer := Frame_Buffer {
		columns = 3,
		rows    = 1,
		cells   = cells,
	}

	scratch: [4096]byte
	out, ok := encode_frame(buffer, profile_default(), {}, scratch[:])
	expect(t, ok, "unused trailing cells must not veto the frame")
	// a and b are written; c is the reserved bottom-right corner.
	expect_value(t, out, "\x1b[H\x1b[m\x1b[1;1Hab\x1b[m")
}

@(private)
test_encode_reduces_indexed_colors_by_depth :: proc(t: ^T) {
	// xterm-256 red (196) must reduce to ANSI red (91), never wrap to blue
	// (the modulo bug: 196 % 16 == 4). The trailing cell is the reserved
	// corner.
	//
	// The cells are built at runtime and the payload flows through a
	// variable: a constant Color holding an Indexed_Color (integer payload)
	// makes the release backend panic during constant folding
	// (llvm_backend_const.cpp:909 "(value.kind=Integer) term::Color vs
	// term::Color" — same family as the SELECTED_STYLE note in
	// widgets/slice_test.odin; RGB payloads are unaffected).
	cells := make([]Cell, 3)
	defer delete(cells)
	cells[0] = Cell {
		grapheme = "a",
		width    = 1,
	}
	index: u8
	index = 196
	cells[1] = Cell {
		grapheme = "b",
		width = 1,
		style = {foreground = Color(Indexed_Color(index))},
	}
	cells[2] = Cell {
		grapheme = "c",
		width    = 1,
	}
	buffer := Frame_Buffer {
		columns = 3,
		rows    = 1,
		cells   = cells,
	}

	scratch: [4096]byte
	out, ok := encode_frame(buffer, {color_depth = .Four_Bit}, {}, scratch[:])
	expect(t, ok, "a valid frame must encode")
	expect_value(t, out, "\x1b[H\x1b[m\x1b[1;1Ha\x1b[m\x1b[91mb\x1b[m")
}

@(private)
test_encode_rejects_cells_wider_than_one_column :: proc(t: ^T) {
	// Wide rendering is not implemented: any non-width-1 cell is rejected
	// before a single byte is produced (the width-0/1/2 continuation
	// contract is the complete target).
	cells := make([]Cell, 2)
	defer delete(cells)
	cells[0] = Cell {
		grapheme = "w",
		width    = 2,
	}
	cells[1] = Cell {
		grapheme = "",
		width    = 0,
	}
	buffer := Frame_Buffer {
		columns = 2,
		rows    = 1,
		cells   = cells,
	}

	scratch: [4096]byte
	written, required, err := encode(buffer, profile_default(), {}, scratch[:])
	expect(t, err == General_Error.Unsupported, "a frame with a wide cell must be rejected")
	expect_value(t, written, 0)
	expect_value(t, required, 0)
	for i in 0 ..< len(scratch) {
		expect(t, scratch[i] == 0, "nothing may be written for a rejected frame")
	}
}

@(private)
test_encode_rejects_unsafe_graphemes :: proc(t: ^T) {
	// A cell grapheme must be valid UTF-8 and carry no C0, C1, or DEL
	// controls — ESC included — so a frame can never inject terminal
	// control into the output stream.
	unsafe_graphemes := []string {
		"\x1b", // lone ESC byte
		"\x01", // C0: SOH
		"\x7f", // DEL
		"\xc2\x85", // C1: U+0085 NEL
		"\xc0\xaf", // malformed UTF-8 (overlong)
		"\xff", // malformed UTF-8 (invalid byte)
	}
	for grapheme in unsafe_graphemes {
		buffer := Frame_Buffer {
			columns = 1,
			rows    = 1,
			cells   = []Cell{{grapheme = grapheme, width = 1}},
		}
		scratch: [4096]byte
		_, _, err := encode(buffer, profile_default(), {}, scratch[:])
		expectf(t, err == General_Error.Invalid_Cell, "unsafe grapheme %q must be rejected", grapheme)
	}

	// A safe non-ASCII grapheme (e.g. U+00E9 é, whose continuation byte is
	// in the C1 range as a raw byte but not as a code point) must pass.
	safe := Frame_Buffer {
		columns = 1,
		rows    = 1,
		cells   = []Cell{{grapheme = "\xc3\xa9", width = 1}},
	}
	scratch: [4096]byte
	_, _, err := encode(safe, profile_default(), {}, scratch[:])
	expect(t, err == nil, "a valid non-ASCII grapheme must encode")
}

@(private)
test_encode_rejects_out_of_bounds_cursor :: proc(t: ^T) {
	buffer := Frame_Buffer {
		columns = 2,
		rows    = 1,
		cells   = []Cell{{grapheme = "a", width = 1}, {grapheme = "b", width = 1}},
	}
	positions := [?]Position {
		{x = -1, y = 0},
		{x = 0, y = -1},
		{x = 2, y = 0}, // x == columns is out of bounds
		{x = 0, y = 1}, // y == rows is out of bounds
	}
	for position in positions {
		scratch: [4096]byte
		_, _, err := encode(buffer, profile_default(), position, scratch[:])
		expectf(t, err == General_Error.Invalid_Cursor, "out-of-bounds cursor %v must be rejected", position)
	}

	// The reserved bottom-right corner is a legal cursor target: writing it
	// is forbidden, placing the cursor there is not.
	scratch: [4096]byte
	_, _, err := encode(buffer, profile_default(), Position{1, 0}, scratch[:])
	expect(t, err == nil, "cursor placement at the reserved corner is allowed")
}

@(private)
test_encode_rejects_invalid_frame_data :: proc(t: ^T) {
	// Too few cells for the declared dimensions.
	too_few := Frame_Buffer {
		columns = 3,
		rows    = 2,
		cells   = []Cell{{grapheme = "a", width = 1}, {grapheme = "b", width = 1}},
	}
	scratch: [4096]byte
	_, _, err := encode(too_few, profile_default(), {}, scratch[:])
	expect(t, err == General_Error.Invalid_Frame_Data, "too few cells must be rejected")

	// Negative dimensions.
	negative := Frame_Buffer {
		columns = -1,
		rows    = 2,
		cells   = []Cell{{grapheme = "a", width = 1}, {grapheme = "b", width = 1}},
	}
	_, _, err = encode(negative, profile_default(), {}, scratch[:])
	expect(t, err == General_Error.Invalid_Frame_Data, "negative dimensions must be rejected")
}

@(private)
test_encode_zero_size_is_a_noop :: proc(t: ^T) {
	zero := Frame_Buffer {
		columns = 0,
		rows    = 4,
		cells   = nil,
	}
	scratch: [4096]byte
	written, required, err := encode(zero, profile_default(), {}, scratch[:])
	expect(t, err == nil, "zero-sized frames are a deterministic no-op")
	expect_value(t, written, 0)
	expect_value(t, required, 0)

	// But an invalid cursor intent on a zero-sized frame is still an error.
	_, _, err = encode(zero, profile_default(), Position{0, 0}, scratch[:])
	expect(t, err == General_Error.Invalid_Cursor, "an invalid cursor on a zero-sized frame is an error")
}

@(private)
test_encode_reports_exact_required_when_scratch_is_too_small :: proc(t: ^T) {
	buffer := Frame_Buffer {
		columns = 3,
		rows    = 1,
		cells   = []Cell {
			{grapheme = "a", width = 1},
			{grapheme = "b", width = 1, style = {foreground = Color(RGB_Color{255, 0, 0})}},
			{grapheme = "c", width = 1},
		},
	}
	profile := Target_Profile {
		color_depth = .True_Color,
	}
	required, size_err := encoded_size(buffer, profile, {})
	expect(t, size_err == nil, "encoded_size must succeed")

	// A scratch one byte short: exact required is reported, nothing written.
	small := make([]byte, required - 1)
	defer delete(small)
	written, reported, err := encode(buffer, profile, {}, small)
	expect(t, err == General_Error.Presentation_Workspace_Too_Small, "a too-small scratch must report .Presentation_Workspace_Too_Small")
	expect_value(t, written, 0)
	expect_value(t, reported, required)
	for i in 0 ..< len(small) {
		expect(t, small[i] == 0, "a too-small scratch must not receive a usable prefix")
	}

	// An exactly-sized scratch encodes cleanly and written == required.
	exact := make([]byte, required)
	defer delete(exact)
	written, reported, err = encode(buffer, profile, {}, exact)
	expect(t, err == nil, "an exactly-sized scratch must encode")
	expect_value(t, written, required)
	expect_value(t, reported, required)
	expect(t, len(exact) > 0 && exact[0] == 0x1b, "the encoded frame must start with ESC")
}

@(private)
test_modifiers_empty_set_is_the_neutral_value :: proc(t: ^T) {
	// Modifiers{} is the empty bit set and the sole neutral presentation
	// value; the enum starts with a real flag and has no .None member.
	empty := Modifiers{}
	expect(t, empty == Modifiers{}, "Modifiers{} must be empty")
	// Iterating the enum yields only real flags (the serializer maps each
	// to a settable SGR code; a .None member would produce a bogus code).
	seen: Modifiers
	for modifier in Modifier {
		expect(t, modifier not_in seen, "Modifier enumerants must be distinct")
		seen += {modifier}
		expect(t, _modifier_sgr(modifier) != 0, "every Modifier must map to a real SGR code")
	}
}

// _drain_pipe reads from t.data until it has consumed limit bytes. The
// backpressure test needs a concurrent reader: a full pipe with no reader
// never becomes writable, so _session_write_bytes would wait forever.
_drain_pipe :: proc(t: ^thread.Thread) {
	drain := cast(^struct {
		fd:    posix.FD,
		total: int,
		limit: int,
	})t.data
	buffer := make([]byte, 4096)
	defer delete(buffer)
	for drain.total < drain.limit {
		n := posix.read(drain.fd, raw_data(buffer), c.size_t(len(buffer)))
		if n <= 0 {
			break
		}
		drain.total += int(n)
	}
}

// sigpipe_ignored is a no-op SIGPIPE handler: writing to a pipe whose read
// end closed raises SIGPIPE, and the default disposition would terminate the
// process. With a handler installed the write loop observes EPIPE instead.
sigpipe_ignored :: proc "c" (sig: posix.Signal) {  }

// _epipe_reader consumes a little from the pipe, then closes the read end so
// the writer observes EPIPE after a committed prefix.
_epipe_reader :: proc(t: ^thread.Thread) {
	data := cast(^struct {
		fd: posix.FD,
	})t.data
	buf := make([]byte, 4096)
	defer delete(buf)
	posix.read(data.fd, raw_data(buf), c.size_t(len(buf)))
	posix.close(data.fd)
}

@(private)
test_session_write_bytes_preserves_the_cause_after_a_committed_prefix :: proc(t: ^T) {
	// A hard write failure after a committed prefix must preserve the
	// underlying cause: the reader closes mid-write, so the writer gets
	// EPIPE with committed > 0 (and never a fabricated stage error).
	action := posix.sigaction_t {
		sa_handler = sigpipe_ignored,
	}
	previous: posix.sigaction_t
	posix.sigaction(posix.Signal(posix.SIGPIPE), &action, &previous)
	defer posix.sigaction(posix.Signal(posix.SIGPIPE), &previous, nil)

	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		expect(t, false, "pipe must open")
		return
	}
	defer posix.close(fds[0])
	defer posix.close(fds[1])

	payload := make([]byte, 256 * 1024)
	defer delete(payload)
	for i in 0 ..< len(payload) {
		payload[i] = 'p'
	}

	reader_data := struct {
		fd: posix.FD,
	} {
		fd = fds[0],
	}
	reader := thread.create(_epipe_reader)
	reader.data = &reader_data
	thread.start(reader)
	defer thread.destroy(reader)

	committed, err := _session_write_bytes(fds[1], payload)
	thread.join(reader)

	platform_err, is_platform := err.(Platform_Error)
	expect(t, is_platform, "a broken pipe must preserve its platform cause")
	if is_platform {
		expectf(t, platform_err == .EPIPE, "a broken pipe must report EPIPE, got %v", platform_err)
	}
	expect(t, committed > 0, "bytes committed before the failure must be reported")
}

@(private)
test_session_write_bytes_recovers_from_backpressure :: proc(t: ^T) {
	// The tty is O_NONBLOCK, so control sequences and frames can hit EAGAIN.
	// This pins the shared write loop (_session_write_bytes): a full pipe
	// must wait for POLLOUT and complete short writes, not fail or truncate.
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		expect(t, false, "pipe must open")
		return
	}
	defer posix.close(fds[0])
	defer posix.close(fds[1])

	flags := posix.fcntl(fds[1], .GETFL)
	posix.fcntl(fds[1], .SETFL, flags | c.int(posix.O_NONBLOCK))

	payload := make([]byte, 128 * 1024)
	defer delete(payload)
	for i in 0 ..< len(payload) {
		payload[i] = 'x'
	}

	// Fill the pipe so the first helper write hits EAGAIN deterministically.
	chunk := make([]byte, 4096)
	defer delete(chunk)
	for i in 0 ..< len(chunk) {
		chunk[i] = 'y'
	}
	filled := 0
	for {
		n := posix.write(fds[1], raw_data(chunk), c.size_t(len(chunk)))
		if n < 0 {
			break
		}
		filled += int(n)
	}

	drain := struct {
		fd:    posix.FD,
		total: int,
		limit: int,
	} {
		fd    = fds[0],
		limit = filled + len(payload),
	}
	drain_thread := thread.create(_drain_pipe)
	drain_thread.data = &drain
	thread.start(drain_thread)
	defer thread.destroy(drain_thread)

	committed, err := _session_write_bytes(fds[1], payload)
	if err != nil {
		// The loop bailed early: close the WRITE end so the drain's blocked
		// read sees EOF and returns, instead of hanging the join forever
		// (fail fast). Closing the read end would not wake it — a blocked
		// read holds its own file reference. The deferred close below then
		// returns EBADF, which is ignored.
		posix.close(fds[1])
	}
	thread.join(drain_thread)
	expect(t, err == nil, "the write loop must complete against backpressure")
	expect_value(t, committed, len(payload))
	expect_value(t, drain.total, filled + len(payload))
}

@(private)
test_profile_default_follows_the_package_color_state :: proc(t: ^T) {
	previous_depth := color_depth
	previous_enabled := color_enabled
	defer {
		color_depth = previous_depth
		color_enabled = previous_enabled
	}

	color_enabled = true
	color_depth = .True_Color
	expect_value(t, profile_default().color_depth, Color_Depth.True_Color)

	// NO_COLOR (color_enabled == false) collapses the depth to .None.
	color_enabled = false
	expect_value(t, profile_default().color_depth, Color_Depth.None)
}
