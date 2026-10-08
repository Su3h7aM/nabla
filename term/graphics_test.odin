#+build linux
#+test
#+private file
package term

import "core:strings"
import "core:testing"

@(test)
test_graphics_transmit_chunks_the_payload :: proc(t: ^testing.T) {
	// 3073 zero bytes encode to 4096 'A's and one more group, so the payload
	// splits into a full chunk and a one-group chunk.
	data := make([]byte, 3073)
	defer delete(data)
	sequence, err := _graphics_transmit_sequence(7, {data = data, format = .PNG}, 3, 2, context.allocator)
	if !testing.expect_value(t, err, nil) {
		return
	}
	defer delete(sequence)
	full := strings.repeat("A", 4096)
	defer delete(full)
	expected := strings.concatenate({"\x1b_Ga=T,U=1,q=2,i=7,c=3,r=2,f=100,m=1;", full, "\x1b\\\x1b_Gm=0;AA==\x1b\\"})
	defer delete(expected)
	testing.expect_value(t, sequence, expected)

	raw, raw_err := _graphics_transmit_sequence(0xABCDEF, {data = {255, 0, 0, 0, 255, 0}, format = .RGB, width = 2, height = 1}, 4, 1, context.allocator)
	if !testing.expect_value(t, raw_err, nil) {
		return
	}
	defer delete(raw)
	testing.expect_value(t, raw, "\x1b_Ga=T,U=1,q=2,i=11259375,c=4,r=1,f=24,s=2,v=1,m=0;/wAAAP8A\x1b\\")
}

@(test)
test_graphics_place_and_delete_bytes :: proc(t: ^testing.T) {
	placed, place_err := _graphics_place_sequence(7, 5, 3, context.allocator)
	if testing.expect_value(t, place_err, nil) {
		defer delete(placed)
		testing.expect_value(t, placed, "\x1b_Ga=d,d=i,i=7,q=2\x1b\\\x1b_Ga=p,U=1,q=2,i=7,c=5,r=3\x1b\\")
	}
	deleted, delete_err := _graphics_delete_sequence(7, context.allocator)
	if testing.expect_value(t, delete_err, nil) {
		defer delete(deleted)
		testing.expect_value(t, deleted, "\x1b_Ga=d,d=I,i=7,q=2\x1b\\")
	}
}

@(test)
test_graphics_refuses_what_the_protocol_cannot_express :: proc(t: ^testing.T) {
	pixels := [4]byte{1, 2, 3, 4}
	_, err := _graphics_transmit_sequence(0, {data = pixels[:], format = .PNG}, 1, 1, context.allocator)
	testing.expect_value(t, err, General_Error.Unsupported)
	_, err = _graphics_transmit_sequence(IMAGE_ID_LIMIT, {data = pixels[:], format = .PNG}, 1, 1, context.allocator)
	testing.expect_value(t, err, General_Error.Unsupported)
	_, err = _graphics_transmit_sequence(1, {data = pixels[:], format = .PNG}, 1, GRAPHICS_MAX_ROWS + 1, context.allocator)
	testing.expect_value(t, err, General_Error.Unsupported)
	_, err = _graphics_transmit_sequence(1, {data = pixels[:], format = .RGBA, width = 2, height = 1}, 1, 1, context.allocator)
	testing.expect_value(t, err, General_Error.Unsupported)
	_, err = _graphics_delete_sequence(0, context.allocator)
	testing.expect_value(t, err, General_Error.Unsupported)

	ok_sequence, ok_err := _graphics_transmit_sequence(1, {data = pixels[:], format = .RGBA, width = 1, height = 1}, 1, 1, context.allocator)
	testing.expect_value(t, ok_err, nil)
	delete(ok_sequence)
}

@(test)
test_graphics_detect_decision :: proc(t: ^testing.T) {
	Case :: struct {
		depth:       Color_Depth,
		environment: _Graphics_Environment,
		supported:   bool,
	}
	cases := [?]Case {
		{.True_Color, {term = "xterm-kitty"}, true},
		{.True_Color, {term = "xterm-256color", kitty_window = true}, true},
		{.True_Color, {term = "xterm-ghostty"}, true},
		{.True_Color, {term = "xterm-256color", term_program = "ghostty"}, true},
		{.True_Color, {term = "xterm-256color"}, false},
		{.True_Color, {term = "xterm-256color", term_program = "iTerm.app"}, false},
		{.Eight_Bit, {term = "xterm-kitty"}, false},
		{.None, {term = "xterm-kitty"}, false},
		{.True_Color, {term = "xterm-kitty", multiplexed = true}, false},
		{.True_Color, {term_program = "ghostty", multiplexed = true}, false},
	}
	for fixture in cases {
		testing.expectf(t, _graphics_supported(fixture.depth, fixture.environment) == fixture.supported, "%v", fixture)
	}
}

// A placeholder cell is ordinary text to present: the frame must validate and
// the combining marks must reach the output.
@(test)
test_graphics_placeholders_are_a_valid_frame :: proc(t: ^testing.T) {
	style := Style {
		foreground = RGB_Color{0, 0, 7},
	}
	buffer := Frame_Buffer {
		columns = 2,
		rows    = 2,
		cells   = {
			{grapheme = graphics_placeholder_rows[0], style = style, width = 1},
			{grapheme = GRAPHICS_PLACEHOLDER, style = style, width = 1},
			{grapheme = graphics_placeholder_rows[GRAPHICS_MAX_ROWS - 1], style = style, width = 1},
			{grapheme = GRAPHICS_PLACEHOLDER, style = style, width = 1},
		},
	}
	scratch: [256]byte
	written, _, err := encode(buffer, {color_depth = .True_Color}, {}, scratch[:])
	if !testing.expect_value(t, err, nil) {
		return
	}
	output := string(scratch[:written])
	testing.expect(t, strings.contains(output, "\x1b[38;2;0;0;7m\U0010EEEE\u0305\u0305\U0010EEEE"), "the first row's marks and the inherited cell")
	testing.expect(t, strings.contains(output, "\U0010EEEE\U0001D244\u0305"), "the last row's mark")
}
