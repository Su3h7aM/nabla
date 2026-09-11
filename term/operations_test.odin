#+build linux
#+test
#+private file
package term

import "core:fmt"
import "core:testing"

// _encode_operations_stream serializes through the public `encode_operations`
// contract and checks the reported count against `encoded_operations_size`, so
// the byte fixtures pin the public path.
_encode_operations_stream :: proc(operations: []Presentation_Op, profile: Target_Profile, scratch: []byte) -> (out: string, ok: bool) {
	written, required, err := encode_operations(operations, profile, scratch)
	if err != nil {
		return "", false
	}
	required_size, size_err := encoded_operations_size(operations, profile)
	if size_err != nil || required != required_size || written != required {
		return "", false
	}
	return string(scratch[:written]), true
}

@(test)
test_operations_encode_reference_bytes :: proc(t: ^testing.T) {
	operations := []Presentation_Op {
		Move_Cursor_Op{{x = 1, y = 0}},
		Set_Style_Op{{foreground = Color(RGB_Color{255, 0, 0})}},
		Write_Grapheme_Op{grapheme = "x", width = 1},
		Write_Grapheme_Op{grapheme = "y", width = 1},
		Move_Cursor_Op{{x = 0, y = 1}},
		Erase_Cells_Op{count = 2},
	}
	scratch: [4096]byte
	out, ok := _encode_operations_stream(operations, {color_depth = .True_Color}, scratch[:])
	testing.expect(t, ok, "a valid op stream must encode")

	// The first move always emits CUP; the first style establishes the
	// baseline with a reset and same-style writes emit nothing; the styled
	// stream restores the base SGR at the end.
	testing.expect_value(t, out, "\x1b[1;2H\x1b[m\x1b[38;2;255;0;0mxy\x1b[2;1H\x1b[2X\x1b[m")

	// .None drops the color but keeps the reset that establishes the baseline.
	none_scratch: [4096]byte
	none, none_ok := _encode_operations_stream(operations[:4], {color_depth = .None}, none_scratch[:])
	testing.expect(t, none_ok, "none-depth ops must encode")
	testing.expect_value(t, none, "\x1b[1;2H\x1b[mxy\x1b[m")
}

@(test)
test_operations_suppress_no_ops_and_restore_style :: proc(t: ^testing.T) {
	profile := Target_Profile {
		color_depth = .True_Color,
	}

	// A move to the already-tracked position emits nothing; an empty stream, a
	// zero-count erase, and an empty grapheme are all deterministic no-ops.
	scratch: [4096]byte
	out, ok := _encode_operations_stream([]Presentation_Op{Move_Cursor_Op{{x = 1, y = 1}}, Move_Cursor_Op{{x = 1, y = 1}}}, profile, scratch[:])
	testing.expect(t, ok)
	testing.expect_value(t, out, "\x1b[2;2H")

	empty, empty_ok := _encode_operations_stream({}, profile, scratch[:])
	testing.expect(t, empty_ok)
	testing.expect_value(t, empty, "")

	erase, erase_ok := _encode_operations_stream([]Presentation_Op{Erase_Cells_Op{count = 0}}, profile, scratch[:])
	testing.expect(t, erase_ok)
	testing.expect_value(t, erase, "")

	// An empty grapheme must not advance the tracked cursor: a phantom advance
	// would suppress the following move and write x in the wrong column.
	blank, blank_ok := _encode_operations_stream(
		[]Presentation_Op {
			Move_Cursor_Op{{x = 0, y = 0}},
			Write_Grapheme_Op{grapheme = "", width = 1},
			Move_Cursor_Op{{x = 1, y = 0}},
			Write_Grapheme_Op{grapheme = "x", width = 1},
		},
		profile,
		scratch[:],
	)
	testing.expect(t, blank_ok)
	testing.expect_value(t, blank, "\x1b[1;1H\x1b[1;2Hx")

	// A repeated style emits nothing, but the base SGR is restored because the
	// stream ends styled. A baseline-only style op emits just the reset.
	styled, styled_ok := _encode_operations_stream(
		[]Presentation_Op{Set_Style_Op{{foreground = Color(RGB_Color{255, 0, 0})}}, Set_Style_Op{{foreground = Color(RGB_Color{255, 0, 0})}}},
		profile,
		scratch[:],
	)
	testing.expect(t, styled_ok)
	testing.expect_value(t, styled, "\x1b[m\x1b[38;2;255;0;0m\x1b[m")

	base, base_ok := _encode_operations_stream([]Presentation_Op{Set_Style_Op{}}, profile, scratch[:])
	testing.expect(t, base_ok)
	testing.expect_value(t, base, "\x1b[m")
}

@(test)
test_operations_validate_operands :: proc(t: ^testing.T) {
	profile := Target_Profile {
		color_depth = .True_Color,
	}
	scratch: [4096]byte

	_, _, err := encode_operations([]Presentation_Op{Move_Cursor_Op{{x = -1, y = 0}}}, profile, scratch[:])
	testing.expect_value(t, err, General_Error.Invalid_Cursor)
	_, _, err = encode_operations([]Presentation_Op{Move_Cursor_Op{{x = 0, y = -2}}}, profile, scratch[:])
	testing.expect_value(t, err, General_Error.Invalid_Cursor)
	_, _, err = encode_operations([]Presentation_Op{Erase_Cells_Op{count = -1}}, profile, scratch[:])
	testing.expect_value(t, err, General_Error.Invalid_Frame_Data)

	// Width-2 and width-0 writes are outside the v1 target.
	_, _, err = encode_operations([]Presentation_Op{Write_Grapheme_Op{grapheme = "界", width = 2}}, profile, scratch[:])
	testing.expect_value(t, err, General_Error.Unsupported)
	_, _, err = encode_operations([]Presentation_Op{Write_Grapheme_Op{grapheme = "", width = 0}}, profile, scratch[:])
	testing.expect_value(t, err, General_Error.Unsupported)

	for unsafe in ([?]string{"\x1b", "\x1b[31m", "a\x00b", "\x7f", "\xc3"}) {
		_, _, unsafe_err := encode_operations([]Presentation_Op{Write_Grapheme_Op{grapheme = unsafe, width = 1}}, profile, scratch[:])
		testing.expectf(t, unsafe_err == General_Error.Invalid_Cell, "unsafe grapheme %q must be rejected", unsafe)
	}
}

@(test)
test_operations_max_int_domain_does_not_overflow :: proc(t: ^testing.T) {
	profile := Target_Profile {
		color_depth = .True_Color,
	}

	// max(int) coordinates and counts are valid nonnegative operands: they
	// must size and encode without overflow. The CUP +1 runs in u64, and a
	// write after a max move saturates the tracked cursor so the repeated
	// move is suppressed.
	max_v := max(int)
	operations := []Presentation_Op {
		Move_Cursor_Op{{x = max_v, y = max_v}},
		Write_Grapheme_Op{grapheme = "x", width = 1},
		Move_Cursor_Op{{x = max_v, y = max_v}},
		Erase_Cells_Op{count = max_v},
	}
	required, size_err := encoded_operations_size(operations, profile)
	testing.expect_value(t, size_err, nil)

	scratch: [4096]byte
	written, got_required, err := encode_operations(operations, profile, scratch[:required])
	testing.expect_value(t, err, nil)
	testing.expect_value(t, written, required)
	testing.expect_value(t, got_required, required)

	one_based := u64(max_v) + 1
	testing.expect_value(t, string(scratch[:written]), fmt.tprintf("\x1b[%d;%dHx\x1b[%dX", one_based, one_based, u64(max_v)))
}

@(test)
test_operations_reports_exact_required_when_scratch_is_too_small :: proc(t: ^testing.T) {
	operations := []Presentation_Op{Move_Cursor_Op{{x = 4, y = 3}}, Write_Grapheme_Op{grapheme = "hello", width = 1}}
	profile := Target_Profile {
		color_depth = .True_Color,
	}
	required_size, size_err := encoded_operations_size(operations, profile)
	testing.expect_value(t, size_err, nil)

	scratch: [64]byte
	written, required, err := encode_operations(operations, profile, scratch[:required_size - 1])
	testing.expect_value(t, err, General_Error.Presentation_Workspace_Too_Small)
	testing.expect_value(t, written, 0)
	testing.expect_value(t, required, required_size)
}

@(test)
test_operations_present_requires_an_open_session :: proc(t: ^testing.T) {
	committed, required, err := present_operations(nil, {}, profile_default(), nil)
	testing.expect_value(t, err, General_Error.Not_Open)
	testing.expect_value(t, committed, 0)
	testing.expect_value(t, required, 0)
}
