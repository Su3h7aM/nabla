package layout

import "core:math"

// _normalize_radius scales corner radii by one common factor so no pair exceeds its side.
@(private)
_normalize_radius :: proc "contextless" (radius: Radius, size: Vec2) -> Radius {
	values := [4]Scalar{radius.tl, radius.tr, radius.br, radius.bl}
	for &value in values {
		if !_scalar_is_finite(value) || value < 0 {
			value = 0
		}
		// `-0` compares equal to zero, so it survives the guard above and would
		// otherwise reach the published command.
		value = _canonical_zero(value)
	}
	// Paired sums per side: top, bottom, left, right.
	sums := [4]f64{f64(values[0]) + f64(values[1]), f64(values[3]) + f64(values[2]), f64(values[0]) + f64(values[3]), f64(values[1]) + f64(values[2])}
	extents := [4]f64{f64(size.x), f64(size.x), f64(size.y), f64(size.y)}
	factor := 1.0
	for sum, index in sums {
		if sum > 0 {
			factor = math.min(factor, extents[index] / sum)
		}
	}
	if factor >= 1 {
		return Radius{tl = values[0], tr = values[1], br = values[2], bl = values[3]}
	}
	factor = math.max(factor, 0)
	return Radius {
		tl = Scalar(f64(values[0]) * factor),
		tr = Scalar(f64(values[1]) * factor),
		br = Scalar(f64(values[2]) * factor),
		bl = Scalar(f64(values[3]) * factor),
	}
}

// _normalize_border_width scales border widths by one common factor so opposite sides cannot overlap.
@(private)
_normalize_border_width :: proc "contextless" (width: Edges, size: Vec2) -> Edges {
	values := [4]Scalar{width.left, width.top, width.right, width.bottom}
	for &value in values {
		if !_scalar_is_finite(value) || value < 0 {
			value = 0
		}
		value = _canonical_zero(value)
	}
	horizontal := f64(values[0]) + f64(values[2])
	vertical := f64(values[1]) + f64(values[3])
	factor := 1.0
	if horizontal > 0 {
		factor = math.min(factor, f64(size.x) / horizontal)
	}
	if vertical > 0 {
		factor = math.min(factor, f64(size.y) / vertical)
	}
	if factor >= 1 {
		return Edges{left = values[0], top = values[1], right = values[2], bottom = values[3]}
	}
	factor = math.max(factor, 0)
	return Edges {
		left = Scalar(f64(values[0]) * factor),
		top = Scalar(f64(values[1]) * factor),
		right = Scalar(f64(values[2]) * factor),
		bottom = Scalar(f64(values[3]) * factor),
	}
}

@(private, require_results)
_border_has_width :: proc "contextless" (width: Edges) -> bool {
	return width.left > 0 || width.top > 0 || width.right > 0 || width.bottom > 0
}

// _normalize_image_source clamps a source region into the unit square. A zero-area result emits no command.
@(private, require_results)
_normalize_image_source :: proc "contextless" (source: Image_Source) -> (Image_Source, bool) {
	if source.mode == .Whole {
		return Image_Source{mode = .Whole}, true
	}
	result := Image_Source {
		mode = .Normalized,
	}
	for axis in Axis {
		index := int(axis)
		low := source.uv.position[index]
		size := source.uv.size[index]
		if !_scalar_is_finite(low) || !_scalar_is_finite(size) {
			return {}, false
		}
		high := low + size
		if high < low {
			low, high = high, low
		}
		low = math.clamp(low, 0, 1)
		high = math.clamp(high, 0, 1)
		if high <= low {
			return {}, false
		}
		result.uv.position[index] = low
		result.uv.size[index] = high - low
	}
	return result, true
}

@(private, require_results)
_command_visible :: proc(state: ^_Context_State, bounds: Rect, clip: Clip_Handle) -> bool {
	if state._options.cull == .All {
		return true
	}
	return _rect_intersects(bounds, state._clips[clip].rect)
}

@(private, require_results)
_emit_command :: proc(state: ^_Context_State, node: Node_Handle, bounds: Rect, clip: Clip_Handle, data: Command_Data) -> bool {
	if !_command_visible(state, bounds, clip) {
		return true
	}
	command := Render_Command {
		bounds = bounds,
		clip   = clip,
		node   = node,
		layer  = state._nodes[node].layer,
		data   = data,
	}
	if !_try_append(&state._commands, command) {
		_latch_capacity_error(state, .Commands, state._node_inputs[node].loc)
		return false
	}
	_update_high_water(state, .Commands, len(state._commands))
	return true
}

@(private, require_results)
_emit_node_enter :: proc(state: ^_Context_State, node: Node_Handle) -> bool {
	input := &state._node_inputs[node]
	resolved := state._nodes[node]
	clip := resolved.clip
	radius := _normalize_radius(input.desc.paint.radius, resolved.outer.size)

	if input.desc.paint.background != 0 {
		if !_emit_command(state, node, resolved.outer, clip, Fill_Cmd{paint = input.desc.paint.background, radius = radius}) {
			return false
		}
	}

	switch content in input.desc.content {
	case Image_Content:
		source, usable := _normalize_image_source(content.source)
		emit := content.handle != 0 && usable && content.paint != 0 && resolved.inner.size.x > 0 && resolved.inner.size.y > 0
		if emit {
			data := Image_Cmd {
				handle = content.handle,
				paint  = content.paint,
				radius = _normalize_radius(input.desc.paint.radius, resolved.inner.size),
				source = source,
			}
			if !_emit_command(state, node, resolved.inner, clip, data) {
				return false
			}
		}
	case Custom_Content:
		data := Custom_Cmd {
			kind   = content.kind,
			data   = content.data,
			radius = _normalize_radius(input.desc.paint.radius, resolved.inner.size),
		}
		if !_emit_command(state, node, resolved.inner, clip, data) {
			return false
		}
	case:
	}

	if !input.is_text || input.text_paint == 0 {
		return true
	}
	for line_index in 0 ..< input.text_line_count {
		record := state._text_lines[input.text_line_start + line_index]
		data := Text_Cmd {
			text     = record.text,
			style    = input.text_style,
			paint    = input.text_paint,
			user     = input.desc.user,
			line     = record.line,
			baseline = record.baseline,
		}
		if !_emit_command(state, node, Rect{position = record.position, size = record.size}, clip, data) {
			return false
		}
	}
	return true
}

@(private, require_results)
_emit_between_children :: proc(state: ^_Context_State, node: Node_Handle) -> bool {
	input := &state._node_inputs[node]
	thickness := input.desc.paint.border.between_children
	if !_scalar_is_finite(thickness) || thickness <= 0 || input.desc.paint.border.paint == 0 {
		return true
	}
	main_axis := _flow_main_axis(input.desc.layout.flow)
	cross_axis := _other_axis(main_axis)
	main := int(main_axis)
	cross := int(cross_axis)
	inner := state._nodes[node].inner
	cross_origin := f64(inner.position[cross]) - f64(state._nodes[node].scroll_offset[cross])
	clip := input.child_clip

	previous := Node_Handle(0)
	for child in _direct_children(state, node) {
		if !state._node_inputs[child].in_flow {
			continue
		}
		if previous == 0 {
			previous = child
			continue
		}
		before := state._nodes[previous].outer
		previous = child
		after := state._nodes[child].outer
		gap_start := f64(before.position[main]) + f64(before.size[main])
		gap_length := f64(after.position[main]) - gap_start
		if gap_length <= 0 {
			continue
		}
		width := math.min(f64(thickness), gap_length)
		bounds: Rect
		bounds.position[main] = Scalar(gap_start + (gap_length - width) / 2)
		bounds.size[main] = Scalar(width)
		bounds.position[cross] = Scalar(cross_origin)
		bounds.size[cross] = inner.size[cross]
		if !_emit_command(state, node, bounds, clip, Fill_Cmd{paint = input.desc.paint.border.paint}) {
			return false
		}
	}
	return true
}

// _emit_node_exit emits the border after children so it covers any overdrawn edge.
@(private, require_results)
_emit_node_exit :: proc(state: ^_Context_State, node: Node_Handle) -> bool {
	if !_emit_between_children(state, node) {
		return false
	}
	input := &state._node_inputs[node]
	border := input.desc.paint.border
	if border.paint == 0 {
		return true
	}
	resolved := state._nodes[node]
	width := _normalize_border_width(border.width, resolved.outer.size)
	if !_border_has_width(width) {
		return true
	}
	data := Border_Cmd {
		paint  = border.paint,
		radius = _normalize_radius(input.desc.paint.radius, resolved.outer.size),
		width  = width,
	}
	return _emit_command(state, node, resolved.outer, resolved.clip, data)
}

@(private)
_mark_subtree_extents :: proc(state: ^_Context_State, root_index: i32) {
	nodes := _root_nodes_of(state, root_index)
	for node, slot in nodes {
		state._node_inputs[node].subtree_end = slot + 1
	}
	root_node := state._roots[root_index].node
	#reverse for node in nodes {
		parent := state._nodes[node].parent
		if node == root_node || parent == 0 {
			continue
		}
		end := state._node_inputs[node].subtree_end
		if end > state._node_inputs[parent].subtree_end {
			state._node_inputs[parent].subtree_end = end
		}
	}
}

// _emit_commands emits every command in exact paint order.
@(private)
_emit_commands :: proc(state: ^_Context_State) {
	for key in state._root_paint {
		root_index := _paint_root_index(key)
		root_node := state._roots[root_index].node
		_mark_subtree_extents(state, root_index)
		for node, slot in _root_nodes_of(state, root_index) {
			if !_emit_node_enter(state, node) {
				return
			}
			// A node closes only once the last node of its subtree has been
			// emitted, so every subtree ending here closes innermost first:
			// that is exactly the structural ancestor chain above this node.
			current := node
			for state._node_inputs[current].subtree_end == slot + 1 {
				if !_emit_node_exit(state, current) {
					return
				}
				if current == root_node {
					break
				}
				current = state._nodes[current].parent
			}
		}
	}
}
