package layout

import "base:runtime"
import "core:math"

@(private, require_results)
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
	// Diagnostics are advisory, not structural: a frame that produces more of
	// them than the pool holds still publishes, and the pool's high-water mark
	// records that some were dropped. Only running out of a structural pool
	// fails the frame.
	_ = _try_append_diagnostic(
		state,
		Diagnostic{kind = kind, node = node, id = identifier, axis = axis, amount = _diagnostic_amount(amount), pool = pool, loc = loc},
	)
}

// DECLARATION_DIAGNOSTIC_LIMIT bounds the diagnostics one declaration can produce: 12 from
// its two sizes, 6 from padding, gap, and aspect, 2 from an image's intrinsic size, and 4
// from text style and runs.
DECLARATION_DIAGNOSTIC_LIMIT :: 20

// _Declaration_Diagnostics holds a declaration's diagnostics until the pool has room for
// them. Normalization fills it without touching frame state, so a declaration the pool
// refuses leaves nothing behind.
@(private)
_Declaration_Diagnostics :: struct {
	items: [DECLARATION_DIAGNOSTIC_LIMIT]_Pending_Diagnostic,
	count: int,
}

@(private)
_Pending_Diagnostic :: struct {
	kind:   Diagnostic_Kind,
	axis:   Axis,
	amount: Scalar,
}

@(private)
_diagnostic_amount :: proc "contextless" (amount: Scalar) -> Scalar {
	if math.is_nan(amount) {
		return 0
	}
	if math.is_inf(amount) {
		return -Scalar(math.F32_MAX) if amount < 0 else Scalar(math.F32_MAX)
	}
	return _canonical_zero(amount)
}

@(private)
_batch_add :: proc(batch: ^_Declaration_Diagnostics, kind: Diagnostic_Kind, axis: Axis, amount: Scalar) {
	assert(batch.count < len(batch.items), "layout: a declaration produced more diagnostics than its bound")
	batch.items[batch.count] = _Pending_Diagnostic {
		kind   = kind,
		axis   = axis,
		amount = _diagnostic_amount(amount),
	}
	batch.count += 1
}

// _batch_flush moves the batch into the pool as diagnostics of node. The caller checks
// that the pool has room first; false means it did not.
@(private, require_results)
_batch_flush :: proc(state: ^_Context_State, batch: ^_Declaration_Diagnostics, node: Node_Handle, loc: runtime.Source_Code_Location) -> bool {
	for item in batch.items[:batch.count] {
		if !_try_append_diagnostic(state, Diagnostic{kind = item.kind, node = node, axis = item.axis, amount = item.amount, loc = loc}) {
			return false
		}
	}
	return true
}

@(private)
_normalize_nonnegative :: proc(batch: ^_Declaration_Diagnostics, value: ^Scalar, axis: Axis) {
	if !_scalar_is_finite(value^) || value^ < 0 {
		_batch_add(batch, .Invalid_Sizing, axis, value^)
		value^ = 0
	}
	value^ = _canonical_zero(value^)
}

@(private)
_normalize_axis_size :: proc(batch: ^_Declaration_Diagnostics, size: ^Axis_Size, axis: Axis) {
	original_value := size.value
	percent_out_of_range := size.mode == .Percent && _scalar_is_finite(original_value) && (original_value < 0 || original_value > 1)
	_normalize_nonnegative(batch, &size.value, axis)
	_normalize_nonnegative(batch, &size.min, axis)
	_normalize_nonnegative(batch, &size.max, axis)
	_normalize_nonnegative(batch, &size.weight, axis)

	if percent_out_of_range {
		_batch_add(batch, .Percent_Out_Of_Range, axis, original_value)
		size.value = math.clamp(size.value, 0, 1)
	}
	if size.mode == .Grow && size.weight == 0 {
		size.weight = 1
	}
	if size.max == 0 {
		size.max = math.inf_f32(1)
	}
	if size.min > size.max {
		_batch_add(batch, .Min_Exceeds_Max, axis, size.min - size.max)
		size.max = size.min
	}
}

@(private)
_normalize_element_desc :: proc(batch: ^_Declaration_Diagnostics, desc: ^Element_Desc) {
	_normalize_axis_size(batch, _axis_size(&desc.layout.sizing, .X), .X)
	_normalize_axis_size(batch, _axis_size(&desc.layout.sizing, .Y), .Y)

	_normalize_nonnegative(batch, &desc.layout.padding.left, .X)
	_normalize_nonnegative(batch, &desc.layout.padding.right, .X)
	_normalize_nonnegative(batch, &desc.layout.padding.top, .Y)
	_normalize_nonnegative(batch, &desc.layout.padding.bottom, .Y)
	_normalize_nonnegative(batch, &desc.layout.gap, _flow_main_axis(desc.layout.flow))
	_normalize_nonnegative(batch, &desc.layout.aspect, .X)

	switch &content in desc.content {
	case Image_Content:
		_normalize_nonnegative(batch, &content.intrinsic_size.x, .X)
		_normalize_nonnegative(batch, &content.intrinsic_size.y, .Y)
	case Custom_Content:
	case:
	}
}

@(private)
_deflate_rect :: proc "contextless" (rect: Rect, padding: Edges) -> Rect {
	width := math.max(rect.size.x - padding.left - padding.right, 0)
	height := math.max(rect.size.y - padding.top - padding.bottom, 0)
	return Rect{position = {rect.position.x + padding.left, rect.position.y + padding.top}, size = {width, height}}
}
