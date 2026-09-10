package layout

import "core:math"
import "core:slice"

@(private)
_direct_children :: proc(state: ^_Context_State, parent: Node_Handle) -> []Node_Handle {
	if parent == 0 {
		return state._solver_scratch[:]
	}
	input := state._node_inputs[parent]
	if input.child_count == 0 {
		return nil
	}
	return state._children[input.child_start:input.child_start + input.child_count]
}

@(private)
_flow_child_count :: proc(state: ^_Context_State, parent: Node_Handle) -> int {
	count := 0
	for child in _direct_children(state, parent) {
		if state._node_inputs[child].in_flow {
			count += 1
		}
	}
	return count
}

@(private)
_clamp_axis_size :: proc "contextless" (value: Scalar, style: Axis_Size) -> Scalar {
	return _canonical_zero(math.clamp(value, style.min, style.max))
}

@(private)
_preferred_axis_size :: proc(state: ^_Context_State, node: Node_Handle, axis: Axis) -> Scalar {
	input := &state._node_inputs[node]
	style := _axis_size(&input.desc.layout.sizing, axis)^
	if style.mode == .Fixed {
		return _clamp_axis_size(style.value, style)
	}
	if input.aspect_derived[axis] {
		return _clamp_axis_size(input.aspect_size[axis], style)
	}
	return _clamp_axis_size(input.intrinsic_size[int(axis)], style)
}

@(private)
_minimum_axis_size :: proc(state: ^_Context_State, node: Node_Handle, axis: Axis) -> Scalar {
	input := &state._node_inputs[node]
	style := _axis_size(&input.desc.layout.sizing, axis)^
	if style.mode == .Fixed {
		return _clamp_axis_size(style.value, style)
	}
	return math.max(input.minimum_size[int(axis)], style.min)
}

@(private)
_finite_scalar :: proc(state: ^_Context_State, node: Node_Handle, axis: Axis, value: f64, record_overflow := true) -> Scalar {
	if math.is_nan(value) {
		return 0
	}
	maximum := f64(Scalar(math.F32_MAX))
	if value > maximum {
		if record_overflow {
			_record_overflow(state, node, axis, value - maximum)
		}
		return Scalar(math.F32_MAX)
	}
	if value < -maximum {
		if record_overflow {
			_record_overflow(state, node, axis, -maximum - value)
		}
		return -Scalar(math.F32_MAX)
	}
	return _canonical_zero(Scalar(value))
}

@(private)
_deflate_node_rect :: proc(state: ^_Context_State, node: Node_Handle, rect: Rect, padding: Edges) -> Rect {
	return Rect {
		position = {
			_finite_scalar(state, node, .X, f64(rect.position.x) + f64(padding.left)),
			_finite_scalar(state, node, .Y, f64(rect.position.y) + f64(padding.top)),
		},
		size = {
			_finite_scalar(state, node, .X, math.max(f64(rect.size.x) - f64(padding.left) - f64(padding.right), 0)),
			_finite_scalar(state, node, .Y, math.max(f64(rect.size.y) - f64(padding.top) - f64(padding.bottom), 0)),
		},
	}
}

@(private)
_recompute_intrinsic_sizes :: proc(state: ^_Context_State) {
	for node_index := len(state._node_inputs) - 1; node_index >= 1; node_index -= 1 {
		node := Node_Handle(node_index)
		input := &state._node_inputs[node]
		main_axis := _flow_main_axis(input.desc.layout.flow)
		cross_axis := _other_axis(main_axis)
		main_extent: f64
		cross_extent: f64
		main_minimum: f64
		cross_minimum: f64
		normal_children := 0
		for child in _direct_children(state, node) {
			if !state._node_inputs[child].in_flow {
				continue
			}
			main_extent += f64(_preferred_axis_size(state, child, main_axis))
			cross_extent = math.max(cross_extent, f64(_preferred_axis_size(state, child, cross_axis)))
			main_minimum += f64(_minimum_axis_size(state, child, main_axis))
			cross_minimum = math.max(cross_minimum, f64(_minimum_axis_size(state, child, cross_axis)))
			normal_children += 1
		}
		if normal_children > 1 {
			gap_total := f64(normal_children - 1) * f64(input.desc.layout.gap)
			main_extent += gap_total
			main_minimum += gap_total
		}

		flow_content: [Axis]f64
		flow_content[main_axis] = main_extent
		flow_content[cross_axis] = cross_extent
		flow_minimum: [Axis]f64
		flow_minimum[main_axis] = main_minimum
		flow_minimum[cross_axis] = cross_minimum
		for axis in Axis {
			inner_intrinsic := math.max(flow_content[axis], f64(input.content_size[int(axis)]))
			inner_minimum := math.max(flow_minimum[axis], f64(input.content_minimum[int(axis)]))
			padding := f64(_padding_before(input.desc.layout.padding, axis)) + f64(_padding_after(input.desc.layout.padding, axis))
			input.intrinsic_size[int(axis)] = _finite_scalar(state, node, axis, inner_intrinsic + padding, false)
			input.minimum_size[int(axis)] = _finite_scalar(state, node, axis, inner_minimum + padding, false)
		}
	}
}

@(private)
_measure_intrinsic_sizes :: proc(state: ^_Context_State) {
	for node_index in 1 ..< len(state._node_inputs) {
		node := Node_Handle(node_index)
		measured := _measure_node_intrinsic(state, node)
		state._node_inputs[node].content_size = measured.size
		state._node_inputs[node].content_minimum = measured.min_size
	}
	_recompute_intrinsic_sizes(state)
}

@(private)
_parent_inner_size :: proc(state: ^_Context_State, parent: Node_Handle) -> Vec2 {
	if parent == 0 {
		return state._viewport
	}
	return state._nodes[parent].inner.size
}

@(private)
_parent_flow :: proc(state: ^_Context_State, parent: Node_Handle) -> Flow {
	if parent == 0 {
		return .Row
	}
	return state._node_inputs[parent].desc.layout.flow
}

@(private)
_parent_gap :: proc(state: ^_Context_State, parent: Node_Handle) -> Scalar {
	if parent == 0 {
		return 0
	}
	return state._node_inputs[parent].desc.layout.gap
}

@(private)
_parent_align :: proc(state: ^_Context_State, parent: Node_Handle) -> Align {
	if parent == 0 {
		return .Start
	}
	return state._node_inputs[parent].desc.layout.align
}

@(private)
_mark_authored_definiteness :: proc(state: ^_Context_State) {
	state._node_inputs[0].definite = {
		.X = true,
		.Y = true,
	}
	state._node_inputs[0].authored_definite = {
		.X = true,
		.Y = true,
	}
	// An overlay resolves against its attach target's final border box, which is
	// definite on both axes, so only `Fit` leaves an overlay root indefinite.
	for root_index in 1 ..< len(state._roots) {
		input := &state._node_inputs[state._roots[root_index].node]
		for axis in Axis {
			definite := _axis_size(&input.desc.layout.sizing, axis).mode != .Fit
			input.authored_definite[axis] = definite
			input.definite[axis] = definite
			input.aspect_derived[axis] = false
		}
	}
	for parent_index in 0 ..< len(state._node_inputs) {
		parent := Node_Handle(parent_index)
		main_axis := _flow_main_axis(_parent_flow(state, parent))
		for child in _direct_children(state, parent) {
			input := &state._node_inputs[child]
			if !input.in_flow {
				continue
			}
			for axis in Axis {
				style := _axis_size(&input.desc.layout.sizing, axis)^
				definite := style.mode == .Fixed || ((style.mode == .Percent || style.mode == .Grow) && state._node_inputs[parent].definite[axis])
				if axis != main_axis && _parent_align(state, parent) == .Stretch && style.mode != .Fixed {
					definite = state._node_inputs[parent].definite[axis]
				}
				input.authored_definite[axis] = definite
				input.definite[axis] = definite
				input.aspect_derived[axis] = false
			}
		}
	}
}

@(private)
_axis_weight :: proc "contextless" (style: Axis_Size) -> f64 {
	if style.mode == .Grow {
		return f64(style.weight)
	}
	return 1
}

@(private)
_shrink_floor :: proc(state: ^_Context_State, child: Node_Handle, axis: Axis, style: Axis_Size) -> Scalar {
	floor := style.min
	if axis not_in state._node_inputs[child].desc.clip.axes {
		floor = math.max(floor, state._node_inputs[child].minimum_size[int(axis)])
	}
	return math.min(floor, style.max)
}

@(private)
_is_shrink_candidate :: proc "contextless" (input: ^_Node_Input, axis: Axis, style: Axis_Size) -> bool {
	// Unwrappable text cannot compress: it overflows instead.
	if input.is_text && input.text_style.wrap == .None {
		return false
	}
	return style.mode == .Fit || style.mode == .Grow || (style.mode == .Percent && !input.authored_definite[axis])
}

@(private)
_axis_child_sum :: proc(state: ^_Context_State, parent: Node_Handle, axis: Axis) -> f64 {
	total: f64
	for child in _direct_children(state, parent) {
		if state._node_inputs[child].in_flow {
			total += f64(state._nodes[child].outer.size[int(axis)])
		}
	}
	return total
}

@(private)
_record_overflow :: proc(state: ^_Context_State, parent: Node_Handle, axis: Axis, amount: f64) {
	if amount <= f64(SCALAR_TOLERANCE) {
		return
	}
	if parent != 0 {
		if axis == .X {
			state._nodes[parent].flags.overflow_x = true
		} else {
			state._nodes[parent].flags.overflow_y = true
		}
	}
	// Content exceeding a clipped axis is what makes an element scrollable: the
	// flag still records the geometric fact, but it is not worth diagnosing.
	if axis in state._node_inputs[parent].desc.clip.axes {
		return
	}
	diagnostic_amount := Scalar(math.min(amount, f64(Scalar(math.F32_MAX))))
	state._node_inputs[parent].pending_overflow[axis] = math.max(state._node_inputs[parent].pending_overflow[axis], diagnostic_amount)
}

@(private)
_clear_overflow_axis :: proc(state: ^_Context_State, axis: Axis) {
	for node_index in 0 ..< len(state._nodes) {
		state._node_inputs[node_index].pending_overflow[axis] = 0
		if node_index == 0 {
			continue
		}
		if axis == .X {
			state._nodes[node_index].flags.overflow_x = false
		} else {
			state._nodes[node_index].flags.overflow_y = false
		}
	}
}

@(private)
_publish_overflow_diagnostics :: proc(state: ^_Context_State) {
	for node_index in 0 ..< len(state._node_inputs) {
		node := Node_Handle(node_index)
		input := &state._node_inputs[node]
		for axis in Axis {
			amount := input.pending_overflow[axis]
			if amount > SCALAR_TOLERANCE {
				_append_diagnostic(state, .Overflow, node, axis = axis, amount = amount, loc = input.loc)
			}
		}
	}
}

@(private)
_grow_children :: proc(state: ^_Context_State, parent: Node_Handle, axis: Axis, free_space: f64) {
	remaining := free_space
	for remaining > 0 {
		total_weight: f64
		candidate_count := 0
		for child in _direct_children(state, parent) {
			input := &state._node_inputs[child]
			if !input.in_flow {
				continue
			}
			style := _axis_size(&input.desc.layout.sizing, axis)^
			current := state._nodes[child].outer.size[int(axis)]
			if style.mode == .Grow && current < style.max {
				total_weight += _axis_weight(style)
				candidate_count += 1
			}
		}
		if candidate_count == 0 || total_weight == 0 {
			return
		}

		iteration_remaining := remaining
		saturated := 0
		for child in _direct_children(state, parent) {
			input := &state._node_inputs[child]
			if !input.in_flow {
				continue
			}
			style := _axis_size(&input.desc.layout.sizing, axis)^
			current := state._nodes[child].outer.size[int(axis)]
			if style.mode != .Grow || current >= style.max {
				continue
			}
			proposed := f64(current) + iteration_remaining * _axis_weight(style) / total_weight
			if proposed > f64(style.max) {
				remaining -= f64(style.max - current)
				state._nodes[child].outer.size[int(axis)] = style.max
				saturated += 1
			}
		}
		if saturated == 0 {
			for child in _direct_children(state, parent) {
				input := &state._node_inputs[child]
				if !input.in_flow {
					continue
				}
				style := _axis_size(&input.desc.layout.sizing, axis)^
				current := state._nodes[child].outer.size[int(axis)]
				if style.mode == .Grow && current < style.max {
					value := f64(current) + remaining * _axis_weight(style) / total_weight
					state._nodes[child].outer.size[int(axis)] = _clamp_axis_size(Scalar(value), style)
				}
			}
			return
		}
	}
}

@(private)
_shrink_children :: proc(state: ^_Context_State, parent: Node_Handle, axis: Axis, deficit: f64) {
	remaining := deficit
	for remaining > 0 {
		total_weight: f64
		candidate_count := 0
		for child in _direct_children(state, parent) {
			input := &state._node_inputs[child]
			if !input.in_flow {
				continue
			}
			style := _axis_size(&input.desc.layout.sizing, axis)^
			floor := _shrink_floor(state, child, axis, style)
			current := state._nodes[child].outer.size[int(axis)]
			if _is_shrink_candidate(input, axis, style) && current > floor {
				total_weight += _axis_weight(style)
				candidate_count += 1
			}
		}
		if candidate_count == 0 || total_weight == 0 {
			return
		}

		iteration_remaining := remaining
		saturated := 0
		for child in _direct_children(state, parent) {
			input := &state._node_inputs[child]
			if !input.in_flow {
				continue
			}
			style := _axis_size(&input.desc.layout.sizing, axis)^
			floor := _shrink_floor(state, child, axis, style)
			current := state._nodes[child].outer.size[int(axis)]
			if !_is_shrink_candidate(input, axis, style) || current <= floor {
				continue
			}
			proposed := f64(current) - iteration_remaining * _axis_weight(style) / total_weight
			if proposed < f64(floor) {
				remaining -= f64(current - floor)
				state._nodes[child].outer.size[int(axis)] = floor
				saturated += 1
			}
		}
		if saturated == 0 {
			for child in _direct_children(state, parent) {
				input := &state._node_inputs[child]
				if !input.in_flow {
					continue
				}
				style := _axis_size(&input.desc.layout.sizing, axis)^
				floor := _shrink_floor(state, child, axis, style)
				current := state._nodes[child].outer.size[int(axis)]
				if _is_shrink_candidate(input, axis, style) && current > floor {
					value := math.max(Scalar(f64(current) - remaining * _axis_weight(style) / total_weight), floor)
					state._nodes[child].outer.size[int(axis)] = _clamp_axis_size(value, style)
				}
			}
			return
		}
	}
}

@(private)
_distribution_target :: proc(state: ^_Context_State, parent: Node_Handle, axis: Axis, available: Scalar, growing: bool) -> f64 {
	target: f64
	for child in _direct_children(state, parent) {
		input := &state._node_inputs[child]
		if !input.in_flow {
			continue
		}
		style := _axis_size(&input.desc.layout.sizing, axis)^
		baseline := input.axis_baseline[axis]
		if growing {
			upper := baseline
			if style.mode == .Grow {
				upper = style.max
			}
			target += f64(upper)
		} else {
			lower := baseline
			if _is_shrink_candidate(input, axis, style) {
				lower = _shrink_floor(state, child, axis, style)
			}
			target += f64(lower)
		}
	}
	if growing {
		return math.min(target, f64(available))
	}
	return math.max(target, f64(available))
}

@(private)
_correct_distribution :: proc(state: ^_Context_State, parent: Node_Handle, axis: Axis, target: f64, growing: bool) -> f64 {
	for child in _direct_children(state, parent) {
		state._node_inputs[child].correction_used[axis] = false
	}

	drift := target - _axis_child_sum(state, parent, axis)
	for drift > f64(SCALAR_TOLERANCE) || drift < -f64(SCALAR_TOLERANCE) {
		selected: Node_Handle
		selected_weight: f64
		for child in _direct_children(state, parent) {
			input := &state._node_inputs[child]
			if !input.in_flow || input.correction_used[axis] {
				continue
			}
			style := _axis_size(&input.desc.layout.sizing, axis)^
			if growing {
				if style.mode != .Grow {
					continue
				}
			} else if !_is_shrink_candidate(input, axis, style) {
				continue
			}
			current := state._nodes[child].outer.size[int(axis)]
			lower := input.axis_baseline[axis]
			upper := style.max
			if !growing {
				lower = _shrink_floor(state, child, axis, style)
				upper = input.axis_baseline[axis]
			}
			if (drift > 0 && current >= upper) || (drift < 0 && current <= lower) {
				continue
			}
			weight := _axis_weight(style)
			if selected == 0 || weight > selected_weight {
				selected = child
				selected_weight = weight
			}
		}
		if selected == 0 {
			break
		}

		input := &state._node_inputs[selected]
		input.correction_used[axis] = true
		style := _axis_size(&input.desc.layout.sizing, axis)^
		current := state._nodes[selected].outer.size[int(axis)]
		lower := input.axis_baseline[axis]
		upper := style.max
		if !growing {
			lower = _shrink_floor(state, selected, axis, style)
			upper = input.axis_baseline[axis]
		}
		corrected := f64(current) + drift
		corrected = math.clamp(corrected, f64(lower), f64(upper))
		state._nodes[selected].outer.size[int(axis)] = _canonical_zero(Scalar(corrected))
		drift = target - _axis_child_sum(state, parent, axis)
	}
	return drift
}

@(private)
_resolve_children_axis :: proc(state: ^_Context_State, parent: Node_Handle, axis: Axis) {
	parent_input := &state._node_inputs[parent]
	parent_inner := _parent_inner_size(state, parent)
	main_axis := _flow_main_axis(_parent_flow(state, parent))
	is_main_axis := axis == main_axis
	normal_children := _flow_child_count(state, parent)
	gap_total: f64
	if is_main_axis && normal_children > 1 {
		gap_total = f64(normal_children - 1) * f64(_parent_gap(state, parent))
	}
	available := _finite_scalar(state, parent, axis, math.max(f64(parent_inner[int(axis)]) - gap_total, 0))
	total_size: f64

	for child in _direct_children(state, parent) {
		input := &state._node_inputs[child]
		if !input.in_flow {
			continue
		}
		style := _axis_size(&input.desc.layout.sizing, axis)^
		resolved := input.intrinsic_size[int(axis)]
		if input.aspect_derived[axis] {
			resolved = input.aspect_size[axis]
		}
		definite := input.authored_definite[axis] || input.aspect_derived[axis]
		switch style.mode {
		case .Fixed:
			resolved = style.value
			definite = true
			input.authored_definite[axis] = true
			input.aspect_derived[axis] = false
		case .Percent:
			if parent_input.definite[axis] {
				resolved = _finite_scalar(state, child, axis, f64(available) * f64(style.value))
				definite = true
				input.authored_definite[axis] = true
				input.aspect_derived[axis] = false
			}
		case .Grow:
			if parent_input.definite[axis] {
				definite = true
				input.authored_definite[axis] = true
				input.aspect_derived[axis] = false
				if !is_main_axis {
					resolved = available
				}
			}
		case .Fit:
		}
		if !is_main_axis && _parent_align(state, parent) == .Stretch && style.mode != .Fixed {
			resolved = available
			definite = parent_input.definite[axis]
			if definite {
				input.authored_definite[axis] = true
				input.aspect_derived[axis] = false
			}
		}
		resolved = _clamp_axis_size(resolved, style)
		if !is_main_axis && resolved > available {
			if _is_shrink_candidate(input, axis, style) {
				resolved = math.max(available, _shrink_floor(state, child, axis, style))
				resolved = _clamp_axis_size(resolved, style)
			}
			_record_overflow(state, parent, axis, f64(resolved) - f64(available))
		}
		state._nodes[child].outer.size[int(axis)] = resolved
		input.definite[axis] = definite
		input.axis_baseline[axis] = resolved
		input.correction_used[axis] = false
		if is_main_axis {
			total_size += f64(resolved)
		}
	}

	if is_main_axis {
		free_space := f64(available) - total_size
		if free_space > f64(SCALAR_TOLERANCE) && parent_input.definite[axis] {
			target := _distribution_target(state, parent, axis, available, true)
			_grow_children(state, parent, axis, free_space)
			drift := _correct_distribution(state, parent, axis, target, true)
			if drift < -f64(SCALAR_TOLERANCE) {
				_record_overflow(state, parent, axis, -drift)
			}
		} else if free_space < -f64(SCALAR_TOLERANCE) {
			target := _distribution_target(state, parent, axis, available, false)
			_shrink_children(state, parent, axis, -free_space)
			_ = _correct_distribution(state, parent, axis, target, false)
		}
		actual_overflow := _axis_child_sum(state, parent, axis) + gap_total - f64(parent_inner[int(axis)])
		_record_overflow(state, parent, axis, actual_overflow)
	}

	for child in _direct_children(state, parent) {
		if !state._node_inputs[child].in_flow {
			continue
		}
		node := &state._nodes[child]
		node.inner = _deflate_node_rect(state, child, Rect{size = node.outer.size}, state._node_inputs[child].desc.layout.padding)
	}
}

/*
Resolve one axis for every paint root.

Roots are visited in dependency order so an overlay's attach target already has
its final border box when the overlay resolves against it. Within a root, the
grouped node order is declaration pre-order, so a parent is always resolved
before its children.
*/
@(private)
_resolve_axis :: proc(state: ^_Context_State, axis: Axis) {
	for root_index in state._root_order {
		if root_index == 0 {
			_resolve_children_axis(state, 0, axis)
		} else {
			_resolve_root_axis(state, root_index, axis)
		}
		for parent in _root_nodes_of(state, root_index) {
			_resolve_children_axis(state, parent, axis)
		}
	}
}

/*
Reflow width-dependent content once every width is resolved.

Text wraps at its resolved width and custom leaves are remeasured there. Both
can change a node's content extent, so intrinsic sizes are rebuilt bottom-up
afterwards and the caller resolves the height axis against the new values.
*/
@(private)
_reflow_at_width :: proc(state: ^_Context_State) {
	changed := _wrap_text_nodes(state)
	if state._frame_error != .None {
		return
	}
	for node_index in 1 ..< len(state._node_inputs) {
		node := Node_Handle(node_index)
		input := &state._node_inputs[node]
		if !input.in_flow {
			continue
		}
		switch content in input.desc.content {
		case Custom_Content:
			_ = content
			measured := _remeasure_node_at_width(state, node, state._nodes[node].inner.size.x)
			input.content_size = measured.size
			changed = true
		case Image_Content:
		case:
		}
	}
	if changed {
		_recompute_intrinsic_sizes(state)
	}
}

@(private)
_remeasure_custom_content_at_height :: proc(state: ^_Context_State) -> bool {
	changed := false
	for node_index in 1 ..< len(state._node_inputs) {
		node := Node_Handle(node_index)
		input := &state._node_inputs[node]
		if !input.in_flow || input.authored_definite[.X] || !input.authored_definite[.Y] {
			continue
		}
		switch content in input.desc.content {
		case Custom_Content:
			_ = content
			measured := _remeasure_node_at_height(state, node, state._nodes[node].inner.size.y)
			input.content_size = measured.size
			changed = true
		case Image_Content:
		case:
		}
	}
	if changed {
		_recompute_intrinsic_sizes(state)
	}
	return changed
}

@(private)
_derive_aspect_axis :: proc(state: ^_Context_State, node: Node_Handle, source, target: Axis) -> bool {
	input := &state._node_inputs[node]
	style := _axis_size(&input.desc.layout.sizing, target)^
	source_size := state._nodes[node].outer.size[int(source)]
	value: f64
	if target == .Y {
		value = f64(source_size) / f64(input.desc.layout.aspect)
	} else {
		value = f64(source_size) * f64(input.desc.layout.aspect)
	}
	resolved := _clamp_axis_size(_finite_scalar(state, node, target, value), style)
	changed := !input.aspect_derived[target] || input.aspect_size[target] != resolved
	input.aspect_derived[target] = true
	input.aspect_size[target] = resolved
	input.definite[target] = true
	return changed
}

@(private)
_derive_aspect_heights :: proc(state: ^_Context_State) -> bool {
	changed := false
	for node_index in 1 ..< len(state._node_inputs) {
		node := Node_Handle(node_index)
		input := &state._node_inputs[node]
		if !input.in_flow || input.desc.layout.aspect == 0 {
			continue
		}
		if input.authored_definite[.X] && !input.authored_definite[.Y] {
			changed = _derive_aspect_axis(state, node, .X, .Y) || changed
		}
	}
	return changed
}

@(private)
_derive_aspect_widths :: proc(state: ^_Context_State) -> bool {
	changed := false
	for node_index in 1 ..< len(state._node_inputs) {
		node := Node_Handle(node_index)
		input := &state._node_inputs[node]
		if !input.in_flow || input.desc.layout.aspect == 0 {
			continue
		}
		if !input.authored_definite[.X] && input.authored_definite[.Y] {
			changed = _derive_aspect_axis(state, node, .Y, .X) || changed
		}
	}
	return changed
}

@(private)
_diagnose_unresolved_constraints :: proc(state: ^_Context_State) {
	for node_index in 1 ..< len(state._node_inputs) {
		node := Node_Handle(node_index)
		input := &state._node_inputs[node]
		if !input.in_flow {
			continue
		}
		parent := state._nodes[node].parent
		for axis in Axis {
			style := _axis_size(&input.desc.layout.sizing, axis)^
			if style.mode == .Percent && !state._node_inputs[parent].definite[axis] {
				_append_diagnostic(state, .Percent_Indefinite, node, axis = axis, loc = input.loc)
			}
			if style.mode == .Grow && !state._node_inputs[parent].definite[axis] {
				_append_diagnostic(state, .Grow_Indefinite, node, axis = axis, loc = input.loc)
			}
		}
		if input.desc.layout.aspect > 0 && !input.authored_definite[.X] && !input.authored_definite[.Y] {
			_append_diagnostic(state, .Aspect_Undetermined, node, loc = input.loc)
		}
	}
}

@(private)
_justification_spacing :: proc "contextless" (mode: Justify, remaining: Scalar, count: int) -> (leading, between: Scalar) {
	switch mode {
	case .Start:
	case .Center:
		leading = remaining / 2
	case .End:
		leading = remaining
	case .Space_Between:
		if count > 1 {
			between = remaining / Scalar(count - 1)
		}
	case .Space_Around:
		if count > 0 {
			leading = remaining / Scalar(2 * count)
			between = remaining / Scalar(count)
		}
	case .Space_Evenly:
		if count > 0 {
			leading = remaining / Scalar(count + 1)
			between = leading
		}
	}
	return
}

@(private)
_rect_intersects :: proc "contextless" (left, right: Rect) -> bool {
	return(
		left.size.x > 0 &&
		left.size.y > 0 &&
		right.size.x > 0 &&
		right.size.y > 0 &&
		f64(left.position.x) < f64(right.position.x) + f64(right.size.x) &&
		f64(right.position.x) < f64(left.position.x) + f64(left.size.x) &&
		f64(left.position.y) < f64(right.position.y) + f64(right.size.y) &&
		f64(right.position.y) < f64(left.position.y) + f64(left.size.y) \
	)
}

@(private)
_rect_contains :: proc "contextless" (outer, inner: Rect) -> bool {
	return(
		inner.position.x >= outer.position.x &&
		inner.position.y >= outer.position.y &&
		f64(inner.position.x) + f64(inner.size.x) <= f64(outer.position.x) + f64(outer.size.x) &&
		f64(inner.position.y) + f64(inner.size.y) <= f64(outer.position.y) + f64(outer.size.y) \
	)
}

@(private)
_place_children :: proc(state: ^_Context_State, parent: Node_Handle) {
	parent_inner := Rect {
		size = state._viewport,
	}
	flow := Flow.Row
	gap: Scalar
	justify := Justify.Start
	align := Align.Start
	if parent != 0 {
		parent_inner = state._nodes[parent].inner
		layout := state._node_inputs[parent].desc.layout
		flow = layout.flow
		gap = layout.gap
		justify = layout.justify
		align = layout.align
	}
	main_axis := _flow_main_axis(flow)
	cross_axis := _other_axis(main_axis)
	normal_children := _flow_child_count(state, parent)
	content_main: f64
	content_cross: f64

	for child in _direct_children(state, parent) {
		input := &state._node_inputs[child]
		if !input.in_flow {
			continue
		}
		content_main += f64(state._nodes[child].outer.size[int(main_axis)])
		content_cross = math.max(content_cross, f64(state._nodes[child].outer.size[int(cross_axis)]))
	}
	if normal_children > 1 {
		content_main += f64(normal_children - 1) * f64(gap)
	}
	content_size: Vec2
	content_size[int(main_axis)] = _finite_scalar(state, parent, main_axis, content_main)
	content_size[int(cross_axis)] = _finite_scalar(state, parent, cross_axis, content_cross)
	remaining := math.max(f64(parent_inner.size[int(main_axis)]) - content_main, 0)
	leading, between := _justification_spacing(justify, Scalar(remaining), normal_children)
	cursor := f64(parent_inner.position[int(main_axis)]) + f64(leading)

	for child in _direct_children(state, parent) {
		input := &state._node_inputs[child]
		if !input.in_flow {
			continue
		}
		node := &state._nodes[child]
		node.outer.position[int(main_axis)] = _finite_scalar(state, child, main_axis, cursor)
		cross_space := f64(parent_inner.size[int(cross_axis)]) - f64(node.outer.size[int(cross_axis)])
		cross_offset: f64
		switch align {
		case .Start, .Stretch:
		case .Center:
			cross_offset = cross_space / 2
		case .End:
			cross_offset = cross_space
		}
		node.outer.position[int(cross_axis)] = _finite_scalar(state, child, cross_axis, f64(parent_inner.position[int(cross_axis)]) + cross_offset)
		node.inner = _deflate_node_rect(state, child, node.outer, input.desc.layout.padding)
		cursor += f64(node.outer.size[int(main_axis)]) + f64(gap) + f64(between)
	}

	if parent != 0 {
		node := &state._nodes[parent]
		node.content_size = content_size
		node.scroll_range = Vec2 {
			_finite_scalar(state, parent, .X, math.max(f64(content_size.x) - f64(node.inner.size.x), 0)),
			_finite_scalar(state, parent, .Y, math.max(f64(content_size.y) - f64(node.inner.size.y), 0)),
		}
	}
}

/*
Place every paint root's normal flow in its own local space.

Every overlay root keeps the local origin its axis resolution left it at;
attachment and scroll displacement are later phases, so this pass never sees an
offset and each root's `content_size` is its undisplaced content extent.
*/
@(private)
_place_local_flow :: proc(state: ^_Context_State) {
	for parent_index in 0 ..< len(state._node_inputs) {
		_place_children(state, Node_Handle(parent_index))
	}
}

@(private)
_build_result_order :: proc(state: ^_Context_State) {
	slice.sort_by(state._id_index[:], proc(left, right: Id_Index_Entry) -> bool {
		return u64(left.id) < u64(right.id)
	})
	_update_high_water(state, .Id_Index, len(state._id_index))
}

@(private)
_solve_frame :: proc(state: ^_Context_State) {
	assert(len(state._node_inputs) == len(state._nodes))
	_build_root_groups(state)
	_resolve_overlay_dependencies(state)
	if state._frame_error != .None {
		return
	}
	_measure_intrinsic_sizes(state)
	if state._frame_error != .None {
		return
	}
	_mark_authored_definiteness(state)
	_resolve_axis(state, .X)
	_reflow_at_width(state)
	if state._frame_error != .None {
		return
	}
	if _derive_aspect_heights(state) {
		_recompute_intrinsic_sizes(state)
	}
	_resolve_axis(state, .Y)
	if state._frame_error != .None {
		return
	}
	height_measurement_changed := _remeasure_custom_content_at_height(state)
	aspect_width_changed := _derive_aspect_widths(state)
	if height_measurement_changed || aspect_width_changed {
		if aspect_width_changed {
			_recompute_intrinsic_sizes(state)
		}
		_clear_overflow_axis(state, .X)
		_recompute_intrinsic_sizes(state)
		_resolve_axis(state, .X)
		_reflow_at_width(state)
		if state._frame_error != .None {
			return
		}
		if _derive_aspect_heights(state) {
			_recompute_intrinsic_sizes(state)
		}
		_clear_overflow_axis(state, .Y)
		_recompute_intrinsic_sizes(state)
		_resolve_axis(state, .Y)
	}
	if state._frame_error != .None {
		return
	}
	_diagnose_unresolved_constraints(state)
	_place_local_flow(state)
	_place_text_lines(state)
	_place_paint_roots(state)
	_resolve_clips(state)
	if state._frame_error != .None {
		return
	}
	_publish_overflow_diagnostics(state)
	_build_result_order(state)
	_build_paint_order(state)
	_emit_commands(state)
}
