#+build linux
package tty

import "core:fmt"

// Operation-stream suite. Expected bytes are written with \x1b hex escapes
// (not \e) so a mangled ESC literal cannot satisfy the expectation
// vacuously, matching the frame-encoding tests.

// encode_operations_stream serializes ops through the public
// encode_operations contract and returns the exact output bytes, so the byte
// fixtures pin the public path (written == required == encoded_operations_size).
@(private)
encode_operations_stream :: proc(operations: []Presentation_Op, profile: Target_Profile, scratch: []byte) -> (out: string, ok: bool) {
	written, required, err := encode_operations(operations, profile, scratch)
	if err != nil {
		return "", false
	}
	required_size, size_err := encoded_operations_size(operations, profile)
	if size_err != nil {
		return "", false
	}
	if required != required_size || written != required {
		return "", false
	}
	return string(scratch[:written]), true
}

@(private)
test_operations_encode_reference_bytes :: proc(t: ^T) {
	operations := []Presentation_Op {
		Move_Cursor_Op{{x = 1, y = 0}},
		Set_Style_Op{{foreground = Color(RGB_Color{255, 0, 0})}},
		Write_Grapheme_Op{grapheme = "x", width = 1},
		Write_Grapheme_Op{grapheme = "y", width = 1},
		Move_Cursor_Op{{x = 0, y = 1}},
		Erase_Cells_Op{count = 2},
	}
	profile := Target_Profile {
		color_depth = .True_Color,
	}

	scratch: [4096]byte
	out, ok := encode_operations_stream(operations, profile, scratch[:])
	expect(t, ok, "a valid op stream must encode")

	// First move always emits CUP (no cross-frame state); the first style op
	// establishes the baseline with an unconditional reset; same-style writes
	// emit no SGR; the erase is ECH; the styled stream restores the base SGR
	// at the end.
	expected := "\x1b[1;2H\x1b[m\x1b[38;2;255;0;0mxy\x1b[2;1H\x1b[2X\x1b[m"
	expect_value(t, out, expected)
}

@(private)
test_operations_suppress_redundant_moves :: proc(t: ^T) {
	profile := Target_Profile {
		color_depth = .True_Color,
	}

	// A move to the already-tracked position emits nothing.
	scratch: [4096]byte
	out, ok := encode_operations_stream([]Presentation_Op{Move_Cursor_Op{{x = 1, y = 1}}, Move_Cursor_Op{{x = 1, y = 1}}}, profile, scratch[:])
	expect(t, ok, "redundant moves must encode")
	expect_value(t, out, "\x1b[2;2H")

	// An empty stream is a deterministic no-op.
	empty_scratch: [16]byte
	empty, empty_ok := encode_operations_stream({}, profile, empty_scratch[:])
	expect(t, empty_ok, "an empty stream must encode")
	expect_value(t, empty, "")

	// A zero-count erase serializes nothing.
	erase_scratch: [4096]byte
	erase, erase_ok := encode_operations_stream([]Presentation_Op{Erase_Cells_Op{count = 0}}, profile, erase_scratch[:])
	expect(t, erase_ok, "a zero-count erase must encode")
	expect_value(t, erase, "")

	// An empty grapheme write is a documented no-op.
	blank_scratch: [4096]byte
	blank, blank_ok := encode_operations_stream([]Presentation_Op{Write_Grapheme_Op{grapheme = "", width = 1}}, profile, blank_scratch[:])
	expect(t, blank_ok, "an empty-grapheme write must encode")
	expect_value(t, blank, "")
}

@(private)
test_operations_empty_grapheme_does_not_advance_cursor :: proc(t: ^T) {
	profile := Target_Profile {
		color_depth = .True_Color,
	}

	// An empty grapheme is a documented no-op: it emits no bytes and must
	// not advance the tracked cursor. A phantom advance would suppress the
	// following move and write x at column 0 instead of column 1 (review
	// repro: Move(0,0), Write(""), Move(1,0), Write("x")).
	scratch: [4096]byte
	out, ok := encode_operations_stream(
		[]Presentation_Op {
			Move_Cursor_Op{{x = 0, y = 0}},
			Write_Grapheme_Op{grapheme = "", width = 1},
			Move_Cursor_Op{{x = 1, y = 0}},
			Write_Grapheme_Op{grapheme = "x", width = 1},
		},
		profile,
		scratch[:],
	)
	expect(t, ok, "an empty-grapheme stream must encode")
	expect_value(t, out, "\x1b[1;1H\x1b[1;2Hx")
}

@(private)
test_operations_max_int_domain_does_not_overflow :: proc(t: ^T) {
	profile := Target_Profile {
		color_depth = .True_Color,
	}

	// max(int) coordinates and counts are valid nonnegative operands: they
	// must size and encode without overflowing or panicking (the old fixed
	// 16-digit buffer ran out of range at runtime, and the CUP +1 wrapped).
	// The write after a max move saturates the tracked cursor at max(int),
	// so the second move to the same position is still suppressed.
	max_v := max(int)
	operations := []Presentation_Op {
		Move_Cursor_Op{{x = max_v, y = max_v}},
		Write_Grapheme_Op{grapheme = "x", width = 1},
		Move_Cursor_Op{{x = max_v, y = max_v}},
		Erase_Cells_Op{count = max_v},
	}

	required, size_err := encoded_operations_size(operations, profile)
	expect(t, size_err == nil, "max-boundary ops must size")

	scratch: [4096]byte
	written, got_required, err := encode_operations(operations, profile, scratch[:required])
	expect(t, err == nil, "max-boundary ops must encode")
	expect_value(t, written, required)
	expect_value(t, got_required, required)

	one_based := u64(max_v) + 1
	expected := fmt.tprintf("\x1b[%d;%dHx\x1b[%dX", one_based, one_based, u64(max_v))
	expect_value(t, string(scratch[:written]), expected)
}

@(private)
test_operations_style_baseline_and_restore :: proc(t: ^T) {
	profile := Target_Profile {
		color_depth = .True_Color,
	}

	// The first Set_Style_Op establishes the baseline (reset + attributes);
	// a repeated style emits nothing; the base SGR state is restored at the
	// end because the stream ends styled.
	scratch: [4096]byte
	out, ok := encode_operations_stream(
		[]Presentation_Op{Set_Style_Op{{foreground = Color(RGB_Color{255, 0, 0})}}, Set_Style_Op{{foreground = Color(RGB_Color{255, 0, 0})}}},
		profile,
		scratch[:],
	)
	expect(t, ok, "styled ops must encode")
	expect_value(t, out, "\x1b[m\x1b[38;2;255;0;0m\x1b[m")

	// A baseline-only style op (the base style) emits just the reset, and an
	// all-default stream needs no trailing restore.
	base_scratch: [4096]byte
	base, base_ok := encode_operations_stream([]Presentation_Op{Set_Style_Op{}}, profile, base_scratch[:])
	expect(t, base_ok, "a base-style op must encode")
	expect_value(t, base, "\x1b[m")
}

@(private)
test_operations_validate_moves_and_erases :: proc(t: ^T) {
	profile := Target_Profile {
		color_depth = .True_Color,
	}
	scratch: [4096]byte

	_, _, err := encode_operations([]Presentation_Op{Move_Cursor_Op{{x = -1, y = 0}}}, profile, scratch[:])
	expect(t, err == General_Error.Invalid_Cursor, "a negative move must be rejected")

	_, _, err = encode_operations([]Presentation_Op{Move_Cursor_Op{{x = 0, y = -2}}}, profile, scratch[:])
	expect(t, err == General_Error.Invalid_Cursor, "a negative row must be rejected")

	_, _, err = encode_operations([]Presentation_Op{Erase_Cells_Op{count = -1}}, profile, scratch[:])
	expect(t, err == General_Error.Invalid_Frame_Data, "a negative erase count must be rejected")
}

@(private)
test_operations_validate_widths_and_graphemes :: proc(t: ^T) {
	profile := Target_Profile {
		color_depth = .True_Color,
	}
	scratch: [4096]byte

	_, _, err := encode_operations([]Presentation_Op{Write_Grapheme_Op{grapheme = "界", width = 2}}, profile, scratch[:])
	expect(t, err == General_Error.Unsupported, "a width-2 op must be rejected in v1")

	_, _, err = encode_operations([]Presentation_Op{Write_Grapheme_Op{grapheme = "", width = 0}}, profile, scratch[:])
	expect(t, err == General_Error.Unsupported, "a width-0 op must be rejected in v1")

	unsafe_graphemes := [?]string{"\x1b", "\x1b[31m", "a\x00b", "\x7f", "\xc3"}
	for unsafe in unsafe_graphemes {
		_, _, err = encode_operations([]Presentation_Op{Write_Grapheme_Op{grapheme = unsafe, width = 1}}, profile, scratch[:])
		expectf(t, err == General_Error.Invalid_Cell, "unsafe grapheme %q must be rejected", unsafe)
	}
}

@(private)
test_operations_reports_exact_required_when_scratch_is_too_small :: proc(t: ^T) {
	operations := []Presentation_Op{Move_Cursor_Op{{x = 4, y = 3}}, Write_Grapheme_Op{grapheme = "hello", width = 1}}
	profile := Target_Profile {
		color_depth = .True_Color,
	}
	required_size, size_err := encoded_operations_size(operations, profile)
	expect(t, size_err == nil, "a valid stream must size")

	// One byte short: no usable prefix, exact required returned.
	scratch: [64]byte
	small := scratch[:required_size - 1]
	written, required, err := encode_operations(operations, profile, small)
	expect(t, err == General_Error.Presentation_Workspace_Too_Small, "a short scratch must report too-small")
	expect_value(t, written, 0)
	expect_value(t, required, required_size)
}

@(private)
test_operations_present_requires_an_open_session :: proc(t: ^T) {
	committed, required, err := present_operations(nil, {}, profile_default(), nil)
	expect(t, err == General_Error.Not_Open, "present_operations on a nil session must report .Not_Open")
	expect_value(t, committed, 0)
	expect_value(t, required, 0)
}

@(private)
test_operations_reduce_colors_by_depth :: proc(t: ^T) {
	operations := []Presentation_Op{Set_Style_Op{{foreground = Color(RGB_Color{255, 0, 0})}}, Write_Grapheme_Op{grapheme = "a", width = 1}}

	// TrueColor: the authored RGB is emitted verbatim.
	tc_scratch: [4096]byte
	tc, tc_ok := encode_operations_stream(operations, {color_depth = .True_Color}, tc_scratch[:])
	expect(t, tc_ok, "truecolor ops must encode")
	expect_value(t, tc, "\x1b[m\x1b[38;2;255;0;0ma\x1b[m")

	// None: colors are dropped; the reset still establishes the baseline.
	none_scratch: [4096]byte
	none, none_ok := encode_operations_stream(operations, {color_depth = .None}, none_scratch[:])
	expect(t, none_ok, "none-depth ops must encode")
	expect_value(t, none, "\x1b[ma\x1b[m")
}
