package layout

import "base:runtime"
import "core:math"

@(private)
_scalar_is_finite :: proc "contextless" (value: Scalar) -> bool {
	return !math.is_nan(value) && !math.is_inf(value)
}

@(private)
_canonical_zero :: proc "contextless" (value: Scalar) -> Scalar {
	if value == 0 {
		return 0
	}
	return value
}

@(private)
_axis_size :: proc "contextless" (sizing: ^Sizing, axis: Axis) -> ^Axis_Size {
	switch axis {
	case .X:
		return &sizing.width
	case .Y:
		return &sizing.height
	}
	unreachable()
}

@(private)
_padding_before :: proc "contextless" (edges: Edges, axis: Axis) -> Scalar {
	return edges.left if axis == .X else edges.top
}

@(private)
_padding_after :: proc "contextless" (edges: Edges, axis: Axis) -> Scalar {
	return edges.right if axis == .X else edges.bottom
}

@(private)
_padding_total :: proc "contextless" (edges: Edges, axis: Axis) -> Scalar {
	return _padding_before(edges, axis) + _padding_after(edges, axis)
}

@(private)
_flow_main_axis :: proc "contextless" (flow: Flow) -> Axis {
	return .X if flow == .Row else .Y
}

@(private)
_other_axis :: proc "contextless" (axis: Axis) -> Axis {
	return .Y if axis == .X else .X
}

@(private)
_append_diagnostic :: proc(
	state: ^_Context_State,
	kind: Diagnostic_Kind,
	node: Node_Handle,
	identifier: Id = 0,
	axis: Axis = .X,
	amount: Scalar = 0,
	pool: Pool_Id = .None,
	loc: runtime.Source_Code_Location = {},
) {
	diagnostic_amount := amount
	if math.is_nan(diagnostic_amount) {
		diagnostic_amount = 0
	} else if math.is_inf(diagnostic_amount) {
		diagnostic_amount = Scalar(math.F32_MAX)
		if amount < 0 {
			diagnostic_amount = -diagnostic_amount
		}
	}
	diagnostic_amount = _canonical_zero(diagnostic_amount)
	if !_try_append_diagnostic(state, Diagnostic{kind = kind, node = node, id = identifier, axis = axis, amount = diagnostic_amount, pool = pool, loc = loc}) {
		_latch_capacity_error(state, .Diagnostics, loc)
	}
}

@(private)
_normalize_nonnegative :: proc(state: ^_Context_State, value: ^Scalar, node: Node_Handle, axis: Axis, loc: runtime.Source_Code_Location) {
	if !_scalar_is_finite(value^) || value^ < 0 {
		_append_diagnostic(state, .Invalid_Sizing, node, axis = axis, amount = value^, loc = loc)
		value^ = 0
	}
	value^ = _canonical_zero(value^)
}

@(private)
_axis_size_diagnostic_count :: proc "contextless" (size: Axis_Size) -> int {
	normalized := size
	count := 0
	original_value := normalized.value
	percent_out_of_range := normalized.mode == .Percent && _scalar_is_finite(original_value) && (original_value < 0 || original_value > 1)
	values := [4]^Scalar{&normalized.value, &normalized.min, &normalized.max, &normalized.weight}
	for value in values {
		if !_scalar_is_finite(value^) || value^ < 0 {
			count += 1
			value^ = 0
		}
	}
	if percent_out_of_range {
		count += 1
		normalized.value = math.clamp(normalized.value, 0, 1)
	}
	if normalized.mode == .Grow && normalized.weight == 0 {
		normalized.weight = 1
	}
	if normalized.max == 0 {
		normalized.max = math.inf_f32(1)
	}
	if normalized.min > normalized.max {
		count += 1
	}
	return count
}

@(private)
_element_diagnostic_count :: proc "contextless" (#by_ptr desc: Element_Desc) -> int {
	count := _axis_size_diagnostic_count(desc.layout.sizing.width) + _axis_size_diagnostic_count(desc.layout.sizing.height)
	values := [6]Scalar {
		desc.layout.padding.left,
		desc.layout.padding.right,
		desc.layout.padding.top,
		desc.layout.padding.bottom,
		desc.layout.gap,
		desc.layout.aspect,
	}
	for value in values {
		if !_scalar_is_finite(value) || value < 0 {
			count += 1
		}
	}
	switch content in desc.content {
	case Image_Content:
		if !_scalar_is_finite(content.intrinsic_size.x) || content.intrinsic_size.x < 0 {
			count += 1
		}
		if !_scalar_is_finite(content.intrinsic_size.y) || content.intrinsic_size.y < 0 {
			count += 1
		}
	case Custom_Content:
	case:
	}
	return count
}

@(private)
_normalize_axis_size :: proc(state: ^_Context_State, size: ^Axis_Size, node: Node_Handle, axis: Axis, loc: runtime.Source_Code_Location) {
	original_value := size.value
	percent_out_of_range := size.mode == .Percent && _scalar_is_finite(original_value) && (original_value < 0 || original_value > 1)
	_normalize_nonnegative(state, &size.value, node, axis, loc)
	_normalize_nonnegative(state, &size.min, node, axis, loc)
	_normalize_nonnegative(state, &size.max, node, axis, loc)
	_normalize_nonnegative(state, &size.weight, node, axis, loc)

	if percent_out_of_range {
		_append_diagnostic(state, .Percent_Out_Of_Range, node, axis = axis, amount = original_value, loc = loc)
		size.value = math.clamp(size.value, 0, 1)
	}
	if size.mode == .Grow && size.weight == 0 {
		size.weight = 1
	}
	if size.max == 0 {
		size.max = math.inf_f32(1)
	}
	if size.min > size.max {
		_append_diagnostic(state, .Min_Exceeds_Max, node, axis = axis, amount = size.min - size.max, loc = loc)
		size.max = size.min
	}
}

@(private)
_normalize_element_desc :: proc(state: ^_Context_State, #by_ptr desc: Element_Desc, node: Node_Handle, loc: runtime.Source_Code_Location) -> Element_Desc {
	result := desc
	_normalize_axis_size(state, _axis_size(&result.layout.sizing, .X), node, .X, loc)
	_normalize_axis_size(state, _axis_size(&result.layout.sizing, .Y), node, .Y, loc)

	_normalize_nonnegative(state, &result.layout.padding.left, node, .X, loc)
	_normalize_nonnegative(state, &result.layout.padding.right, node, .X, loc)
	_normalize_nonnegative(state, &result.layout.padding.top, node, .Y, loc)
	_normalize_nonnegative(state, &result.layout.padding.bottom, node, .Y, loc)
	_normalize_nonnegative(state, &result.layout.gap, node, _flow_main_axis(result.layout.flow), loc)
	_normalize_nonnegative(state, &result.layout.aspect, node, .X, loc)

	switch content in result.content {
	case Image_Content:
		image := content
		_normalize_nonnegative(state, &image.intrinsic_size.x, node, .X, loc)
		_normalize_nonnegative(state, &image.intrinsic_size.y, node, .Y, loc)
		result.content = image
	case Custom_Content:
	case:
	}
	return result
}

@(private)
_deflate_rect :: proc "contextless" (rect: Rect, padding: Edges) -> Rect {
	width := math.max(rect.size.x - padding.left - padding.right, 0)
	height := math.max(rect.size.y - padding.top - padding.bottom, 0)
	return Rect{position = {rect.position.x + padding.left, rect.position.y + padding.top}, size = {width, height}}
}
