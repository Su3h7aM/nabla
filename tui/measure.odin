package tui

import "nabla:layout"
import "nabla:text"

// Measure_Context is caller-owned userdata for the layout measurer. The caller
// keeps it alive, at a stable address, for the resolve that uses it; the zero
// profile is the strict policy, so renderers that expand tabs set
// text.DEFAULT_WIDTH_PROFILE.
Measure_Context :: struct {
	profile: text.Width_Profile,
}

// measure_proc is the layout.Services.measure_text callback.
measure_proc :: proc(
	user_data: rawptr,
	value: string,
	style: layout.Text_Style,
	request: layout.Measure_Request,
) -> (
	layout.Measure_Result,
	layout.Measure_Error,
) {
	measure_context := cast(^Measure_Context)user_data
	if measure_context == nil {
		return {}, .Invalid_Text
	}
	measured, err := text.measure_text(value, measure_context.profile, _measure_max_columns(request))
	if err != .None {
		return {}, .Invalid_Text
	}
	size := layout.Vec2{layout.Scalar(measured.columns), layout.Scalar(measured.rows)}
	return {size = size, min_size = size, baseline = 1}, .None
}

// break_proc is the layout.Services.break_text callback. user_data is unused:
// the classifier is stateless.
break_proc :: proc(
	user_data: rawptr,
	value: string,
	offset: int,
) -> (
	piece_end: int,
	next_offset: int,
	kind: layout.Text_Break_Kind,
	err: layout.Text_Break_Error,
) {
	run_end, resume, text_kind := text.break_text(value, offset)
	piece_end = run_end
	next_offset = resume
	switch text_kind {
	case text.Break_Kind.None:
	case text.Break_Kind.Optional:
		kind = .Optional
	case text.Break_Kind.Mandatory:
		kind = .Mandatory
	}
	return
}

// _measure_max_columns maps the request's X axis onto a column bound: an
// unbounded axis measures intrinsic width, At_Most and Exact clamp.
_measure_max_columns :: proc(request: layout.Measure_Request) -> int {
	max_columns := text.NO_COLUMN_LIMIT
	switch request.axes[.X].mode {
	case .Unbounded:
	case .At_Most, .Exact:
		width := request.axes[.X].value
		if width >= 0 && width < layout.Scalar(max(i32)) {
			max_columns = int(width)
		}
	}
	return max_columns
}
