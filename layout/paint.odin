package layout

import "core:math"
import "core:slice"

/*
Group every node under the paint root that owns it.

A node is always declared after its parent and inside its own root, so grouping
by root while scanning ascending handles leaves each root's slice in
declaration pre-order. Every later phase depends on that: a parent always
precedes its descendants inside its root's slice.
*/
@(private)
_build_root_groups :: proc(state: ^_Context_State) {
	for &root in state._roots {
		root.node_count = 0
	}
	for node_index in 1 ..< len(state._node_inputs) {
		state._roots[state._node_inputs[node_index].root].node_count += 1
	}
	offset := 0
	for &root in state._roots {
		root.node_start = offset
		offset += root.node_count
		root.node_count = 0
	}
	assert(offset <= cap(state._root_nodes))
	resize(&state._root_nodes, offset)
	for node_index in 1 ..< len(state._node_inputs) {
		root := &state._roots[state._node_inputs[node_index].root]
		state._root_nodes[root.node_start + root.node_count] = Node_Handle(node_index)
		root.node_count += 1
	}
}

@(private)
_root_nodes_of :: proc(state: ^_Context_State, root_index: i32) -> []Node_Handle {
	root := state._roots[root_index]
	return state._root_nodes[root.node_start:root.node_start + root.node_count]
}

@(private)
_fall_back_to_viewport :: proc "contextless" (root: ^_Paint_Root) {
	root.attach = .Root
	root.target = 0
	root.dependency = -1
}

/*
Bind every overlay to its attach target and order the roots for placement.

Targets resolve after declaration closes, so a forward `Id` reference works. A
missing target or a dependency cycle is a diagnostic rather than a frame error:
the affected root attaches to the viewport for this frame.
*/
@(private)
_resolve_overlay_dependencies :: proc(state: ^_Context_State) {
	for root_index in 1 ..< len(state._roots) {
		root := &state._roots[root_index]
		switch root.attach {
		case .Root:
			root.target = 0
		case .Parent:
			root.target = state._nodes[root.node].parent
		case .Element:
			slot, found, available := _id_table_probe(state, root.target_id)
			if !available || !found {
				_append_diagnostic(state, .Missing_Overlay_Target, root.node, identifier = root.target_id, loc = state._node_inputs[root.node].loc)
				_fall_back_to_viewport(root)
				continue
			}
			root.target = state._id_table[slot].node
		case .None:
			unreachable()
		}
		root.dependency = state._node_inputs[root.target].root if root.target != 0 else -1
	}
	_break_dependency_cycles(state)
	_order_roots_by_dependency(state)
}

/*
Detach every root that transitively attaches to itself.

Each root has at most one dependency, so the graph is functional: following the
single out-edge from each unvisited root reaches every cycle exactly once, and
stamping each walk with its origin makes previously settled roots stop the walk
without a separate pass.
*/
@(private)
_break_dependency_cycles :: proc(state: ^_Context_State) {
	for &root in state._roots {
		root.walk_mark = -1
	}
	for start in 0 ..< i32(len(state._roots)) {
		if state._roots[start].walk_mark >= 0 {
			continue
		}
		current := start
		for current >= 0 && state._roots[current].walk_mark < 0 {
			state._roots[current].walk_mark = start
			current = state._roots[current].dependency
		}
		if current < 0 || state._roots[current].walk_mark != start {
			continue
		}
		member := current
		for {
			next := state._roots[member].dependency
			root := &state._roots[member]
			_append_diagnostic(state, .Overlay_Dependency_Cycle, root.node, identifier = root.target_id, loc = state._node_inputs[root.node].loc)
			_fall_back_to_viewport(root)
			if next == current || next < 0 {
				break
			}
			member = next
		}
	}
}

/*
Order roots so each is placed only after the root holding its attach target.

Scanning ascending keeps declaration sequence as the ready-set tie-break, and
the normal-flow tree is root zero with no dependency, so it always leads.
*/
@(private)
_order_roots_by_dependency :: proc(state: ^_Context_State) {
	for &root in state._roots {
		root.ordered = false
	}
	for len(state._root_order) < len(state._roots) {
		progressed := false
		for root_index in 0 ..< i32(len(state._roots)) {
			root := &state._roots[root_index]
			if root.ordered || (root.dependency >= 0 && !state._roots[root.dependency].ordered) {
				continue
			}
			root.ordered = true
			ok := _try_append(&state._root_order, root_index)
			assert(ok)
			progressed = true
		}
		// Cycles were broken above, so at least one root becomes ready per sweep.
		assert(progressed)
	}
}

@(private)
_root_target_box :: proc(state: ^_Context_State, root_index: i32) -> Rect {
	target := state._roots[root_index].target
	if target == 0 {
		return Rect{size = state._viewport}
	}
	return state._nodes[target].outer
}

/*
Size an overlay root against its attach target instead of its declaration parent.

`Grow` and `Percent` resolve against the target's border box, which is already
final because roots are resolved in dependency order.
*/
@(private)
_resolve_root_axis :: proc(state: ^_Context_State, root_index: i32, axis: Axis) {
	node := state._roots[root_index].node
	input := &state._node_inputs[node]
	style := _axis_size(&input.desc.layout.sizing, axis)^
	available := _root_target_box(state, root_index).size[int(axis)]
	resolved := input.intrinsic_size[int(axis)]
	if input.aspect_derived[axis] {
		resolved = input.aspect_size[axis]
	}
	definite := input.authored_definite[axis] || input.aspect_derived[axis]
	switch style.mode {
	case .Fixed:
		resolved = style.value
	case .Percent:
		resolved = _finite_scalar(state, node, axis, f64(available) * f64(style.value))
	case .Grow:
		resolved = available
	case .Fit:
	}
	if style.mode != .Fit {
		definite = true
		input.authored_definite[axis] = true
		input.aspect_derived[axis] = false
	}
	resolved = _clamp_axis_size(resolved, style)
	resolved_node := &state._nodes[node]
	resolved_node.outer.size[int(axis)] = resolved
	resolved_node.inner = _deflate_node_rect(state, node, Rect{size = resolved_node.outer.size}, input.desc.layout.padding)
	input.definite[axis] = definite
	input.axis_baseline[axis] = resolved
	input.correction_used[axis] = false
}

@(private)
_attach_fraction :: proc "contextless" (point: Attach_Point) -> Vec2 {
	steps := [3]Scalar{0, 0.5, 1}
	return Vec2{steps[int(point) / 3], steps[int(point) % 3]}
}

/*
Offset that moves an overlay root from its local origin onto its attach target.

`self_point` on the overlay's unexpanded box is aligned with `target_point` on
the target's final world border box, then `Overlay_Style.offset` is added.
*/
@(private)
_attach_delta :: proc(state: ^_Context_State, root_index: i32) -> Vec2 {
	node := state._roots[root_index].node
	overlay := state._node_inputs[node].desc.overlay
	box := state._nodes[node].outer
	target := _root_target_box(state, root_index)
	target_fraction := _attach_fraction(overlay.target_point)
	self_fraction := _attach_fraction(overlay.self_point)
	delta: Vec2
	for axis in Axis {
		index := int(axis)
		offset := overlay.offset[index]
		if !_scalar_is_finite(offset) {
			_append_diagnostic(state, .Invalid_Sizing, node, axis = axis, amount = offset, loc = state._node_inputs[node].loc)
			offset = 0
		}
		attached :=
			f64(target.position[index]) +
			f64(target.size[index]) * f64(target_fraction[index]) -
			f64(box.size[index]) * f64(self_fraction[index]) +
			f64(offset)
		delta[index] = _finite_scalar(state, node, axis, attached - f64(box.position[index]))
	}
	return delta
}

@(private)
_translate_node :: proc(state: ^_Context_State, node: Node_Handle, delta: Vec2) {
	if delta == {} {
		return
	}
	resolved := &state._nodes[node]
	for axis in Axis {
		index := int(axis)
		resolved.outer.position[index] = _finite_scalar(state, node, axis, f64(resolved.outer.position[index]) + f64(delta[index]))
		resolved.inner.position[index] = _finite_scalar(state, node, axis, f64(resolved.inner.position[index]) + f64(delta[index]))
	}
	input := state._node_inputs[node]
	for line_index in 0 ..< input.text_line_count {
		record := &state._text_lines[input.text_line_start + line_index]
		for axis in Axis {
			index := int(axis)
			record.position[index] = _finite_scalar(state, node, axis, f64(record.position[index]) + f64(delta[index]))
		}
	}
}

/*
Displacement a clipping node imposes on its descendants.

The core clamps nothing and stores nothing: it applies the offset it is given
and reports the legal range, so an out-of-range offset produces the
geometrically correct over-scrolled result plus an `Overflow` diagnostic.
*/
@(private)
_scroll_displacement :: proc(state: ^_Context_State, node: Node_Handle) -> Vec2 {
	input := state._node_inputs[node]
	if input.desc.clip.axes == {} {
		return {}
	}
	resolved := &state._nodes[node]
	applied: Vec2
	for axis in Axis {
		if axis not_in input.desc.clip.axes {
			continue
		}
		index := int(axis)
		offset := input.desc.clip.offset[index]
		if !_scalar_is_finite(offset) {
			_append_diagnostic(state, .Invalid_Sizing, node, axis = axis, amount = offset, loc = input.loc)
			continue
		}
		applied[index] = _canonical_zero(offset)
		// Content larger than the viewport is the point of a scroll container;
		// only an offset outside the legal range is worth reporting.
		over_scroll := math.max(-f64(offset), f64(offset) - f64(resolved.scroll_range[index]))
		if over_scroll > f64(SCALAR_TOLERANCE) {
			resolved.flags.overflow_x = axis == .X || resolved.flags.overflow_x
			resolved.flags.overflow_y = axis == .Y || resolved.flags.overflow_y
			_append_diagnostic(state, .Overflow, node, axis = axis, amount = Scalar(math.min(over_scroll, f64(Scalar(math.F32_MAX)))), loc = input.loc)
		}
	}
	resolved.scroll_offset = applied
	return -applied
}

/*
Inflate an attached overlay root's published box.

`expand` is applied after attachment: it never took part in intrinsic sizing
and never moves or resizes descendants.
*/
@(private)
_expand_root_box :: proc(state: ^_Context_State, node: Node_Handle) {
	expand := state._node_inputs[node].desc.overlay.expand
	if expand == {} {
		return
	}
	resolved := &state._nodes[node]
	for axis in Axis {
		index := int(axis)
		amount := expand[index]
		if !_scalar_is_finite(amount) || amount < 0 {
			_append_diagnostic(state, .Invalid_Sizing, node, axis = axis, amount = amount, loc = state._node_inputs[node].loc)
			continue
		}
		resolved.outer.position[index] = _finite_scalar(state, node, axis, f64(resolved.outer.position[index]) - f64(amount))
		resolved.outer.size[index] = _finite_scalar(state, node, axis, f64(resolved.outer.size[index]) + 2 * f64(amount))
	}
}

/*
Turn local per-root boxes into final world geometry.

Roots are visited in dependency order, so an overlay observes its target's
final scroll-displaced box. Within a root, ascending slice order is declaration
pre-order, so a node's accumulated parent displacement is always already known.
*/
@(private)
_place_paint_roots :: proc(state: ^_Context_State) {
	for root_index in state._root_order {
		root := state._roots[root_index]
		root_delta: Vec2
		if root_index != 0 {
			root_delta = _attach_delta(state, root_index)
		}
		for node in _root_nodes_of(state, root_index) {
			delta := root_delta
			if node != root.node {
				delta = state._node_inputs[state._nodes[node].parent].child_delta
			}
			_translate_node(state, node, delta)
			state._node_inputs[node].child_delta = delta + _scroll_displacement(state, node)
		}
		if root_index != 0 {
			_expand_root_box(state, root.node)
		}
	}
}

/*
Intersect a local clip rectangle with the inherited one.

An axis the clip does not constrain keeps the inherited range, and every chain
terminates at the viewport entry, so an effective rectangle is always finite.
*/
@(private)
_intersect_clip :: proc "contextless" (local, inherited: Rect, axes: Axis_Set) -> Rect {
	result: Rect
	for axis in Axis {
		index := int(axis)
		low := f64(inherited.position[index])
		high := low + f64(inherited.size[index])
		if axis in axes {
			low = math.max(low, f64(local.position[index]))
			high = math.min(high, f64(local.position[index]) + f64(local.size[index]))
		}
		result.position[index] = Scalar(low)
		result.size[index] = Scalar(math.max(high - low, 0))
	}
	return result
}

/*
Build the clip table and stamp each node's effective clip.

A clipping element's own entry constrains its descendants, not itself: its
padding ring and border belong to the surface its ancestors allowed, so the
owner keeps the inherited handle. Handles are allocated in placement order and
never reused, so `owner` always names the element that established the clip.
*/
@(private)
_resolve_clips :: proc(state: ^_Context_State) {
	for root_index in state._root_order {
		root := state._roots[root_index]
		inherited := Clip_Handle(0)
		if root_index != 0 && root.clip_to == .Attached_Parent && root.target != 0 {
			inherited = state._nodes[root.target].clip
		}
		for node in _root_nodes_of(state, root_index) {
			effective := inherited
			if node != root.node {
				effective = state._node_inputs[state._nodes[node].parent].child_clip
			}
			resolved := &state._nodes[node]
			clip_rect := state._clips[effective].rect
			resolved.clip = effective
			resolved.layer = root.layer
			resolved.flags.visible = _rect_intersects(resolved.outer, clip_rect)
			resolved.flags.clipped = resolved.flags.visible && !_rect_contains(clip_rect, resolved.outer)

			axes := state._node_inputs[node].desc.clip.axes
			if axes == {} {
				state._node_inputs[node].child_clip = effective
				continue
			}
			entry := Resolved_Clip {
				rect   = _intersect_clip(resolved.inner, clip_rect, axes),
				owner  = node,
				parent = effective,
				axes   = axes,
			}
			if !_try_append(&state._clips, entry) {
				_latch_capacity_error(state, .Clips, state._node_inputs[node].loc)
				return
			}
			_update_high_water(state, .Clips, len(state._clips))
			state._node_inputs[node].child_clip = Clip_Handle(len(state._clips) - 1)
		}
	}
}

/*
Sort key placing paint roots in `(layer ascending, declaration sequence ascending)`.

A root's index is its declaration sequence, so the index doubles as the
tie-break and the payload. Biasing the signed layer keeps the unsigned integer
comparison faithful, so no paint decision ever inspects geometry or a float.
*/
@(private)
_paint_root_key :: proc "contextless" (layer: i16, root_index: i32) -> u64 {
	biased := u64(u16(layer) ~ 0x8000)
	return biased << 32 | u64(u32(root_index))
}

@(private)
_paint_root_index :: proc "contextless" (key: u64) -> i32 {
	return i32(u32(key))
}

/*
Order paint roots, then build the front-to-back hit order.

Reversing paint order and walking each root's declaration pre-order backwards
gives descendants priority over ancestors and later siblings priority over
earlier ones, while preserving overlay stacking. Each node appears once.
*/
@(private)
_build_paint_order :: proc(state: ^_Context_State) {
	for root_index in 0 ..< i32(len(state._roots)) {
		ok := _try_append(&state._root_paint, _paint_root_key(state._roots[root_index].layer, root_index))
		assert(ok)
	}
	slice.sort(state._root_paint[:])

	for key_index := len(state._root_paint) - 1; key_index >= 0; key_index -= 1 {
		nodes := _root_nodes_of(state, _paint_root_index(state._root_paint[key_index]))
		for node_index := len(nodes) - 1; node_index >= 0; node_index -= 1 {
			ok := _try_append(&state._hit_order, nodes[node_index])
			assert(ok)
		}
	}
	_update_high_water(state, .Hit_Order, len(state._hit_order))
}
