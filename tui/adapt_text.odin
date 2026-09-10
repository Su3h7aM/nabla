package tui

import "nabla:layout"
import "nabla:text"

// ASCII_Measure_Context is the caller-owned userdata for the ASCII measurer.
//
// Lifetime: the caller owns this value and must keep it alive, at a stable
// address, for as long as the layout.Services built from it can be invoked —
// that is, through the end of the resolve that uses it.
// Ownership: `profile` is caller-supplied data, copied by value here. This
// adapter does not discover it from the environment.
ASCII_Measure_Context :: struct {
	profile: text.Width_Profile,
}

// ascii_measure_proc is the layout.Services.measure_text callback.
//
// The reference signature passes the text to measure as an argument rather
// than carrying it in the userdata, so the context holds only the profile and
// one context serves every text node in a frame.
ascii_measure_proc :: proc(
	user_data: rawptr,
	value: string,
	style: layout.Text_Style,
	request: layout.Measure_Request,
) -> (
	layout.Measure_Result,
	layout.Measure_Error,
) {
	measure_context := cast(^ASCII_Measure_Context)user_data
	if measure_context == nil {
		return {}, .Invalid_Text
	}

	// An unbounded X axis is a request to measure the intrinsic width, not a
	// request to clamp to a garbage column count. At_Most and Exact clamp.
	max_columns := text.NO_COLUMN_LIMIT
	switch request.axes[.X].mode {
	case .Unbounded:
	case .At_Most, .Exact:
		width := request.axes[.X].value
		if width >= 0 && width < layout.Scalar(max(i32)) {
			max_columns = int(width)
		}
	}

	measured, err := text.measure_ascii(value, measure_context.profile, max_columns)
	if err != .None {
		return {}, .Invalid_Text
	}
	size := layout.Vec2{layout.Scalar(measured.columns), layout.Scalar(measured.rows)}
	// The ASCII stage is single-line and unwrappable, so its preferred and
	// minimum widths are identical. Unicode flow may report a smaller floor.
	return {size = size, min_size = size, baseline = 1}, .None
}

// ascii_break_proc is the layout.Services.break_text callback.
//
// It reports the next unbreakable run and the separator that follows it
// (whitespace or line terminator) exactly as layout's breaker contract
// expects. `user_data` is unused: the ASCII classifier is stateless.
ascii_break_proc :: proc(
	user_data: rawptr,
	value: string,
	offset: int,
) -> (
	piece_end: int,
	next_offset: int,
	kind: layout.Text_Break_Kind,
	err: layout.Text_Break_Error,
) {
	run_end, resume, text_kind := text.break_ascii(value, offset)
	piece_end = run_end
	next_offset = resume
	kind = layout.Text_Break_Kind.None
	switch text_kind {
	case text.Break_Kind.None:
	case text.Break_Kind.Optional:
		kind = .Optional
	case text.Break_Kind.Mandatory:
		kind = .Mandatory
	}
	return
}
