package layout

/*
Resolve a clip handle to its entry.

`Clip_Handle(0)` is the viewport clip and always exists, so an out-of-range
handle resolves there rather than failing: every chain terminates at the
viewport and no consumer needs an "unclipped" case.
*/
@(private)
_clip_index :: proc "contextless" (frame_result: Frame_Result, handle: Clip_Handle) -> (int, bool) {
	index := u64(handle)
	if index >= u64(len(frame_result.clips)) {
		return 0, false
	}
	return int(index), true
}

clip_of :: proc(frame_result: Frame_Result, handle: Clip_Handle) -> Resolved_Clip {
	index, valid := _clip_index(frame_result, handle)
	if !valid {
		if len(frame_result.clips) == 0 {
			return {}
		}
		return frame_result.clips[0]
	}
	return frame_result.clips[index]
}

/*
Iterate the structural children of a node in declaration order.

An iterator rather than a slice: children are a linked sibling chain in the
published node table, so a slice would need either an allocation or a hidden
scratch buffer.
*/
Child_Iterator :: struct {
	_result: Frame_Result,
	_next:   Node_Handle,
}

// children iterates the structural children of a node in declaration order,
// via the linked sibling chain in `frame_result.nodes`. The returned iterator
// borrows `frame_result`, which shares its lifetime with `frame_result`.
children :: proc(frame_result: Frame_Result, handle: Node_Handle) -> Child_Iterator {
	parent, found := node(frame_result, handle)
	if !found {
		return Child_Iterator{_result = frame_result}
	}
	return Child_Iterator{_result = frame_result, _next = parent.first_child}
}

next_child :: proc(iterator: ^Child_Iterator) -> (child: Resolved_Node, handle: Node_Handle, ok: bool) {
	handle = iterator._next
	child, ok = node(iterator._result, handle)
	if !ok {
		iterator._next = 0
		return {}, 0, false
	}
	iterator._next = child.next_sibling
	return child, handle, true
}

@(private)
_point_in_rect :: proc "contextless" (rect: Rect, point: Vec2) -> bool {
	return(
		rect.size.x > 0 &&
		rect.size.y > 0 &&
		point.x >= rect.position.x &&
		point.y >= rect.position.y &&
		f64(point.x) < f64(rect.position.x) + f64(rect.size.x) &&
		f64(point.y) < f64(rect.position.y) + f64(rect.size.y) \
	)
}

/*
Whether a point may select this node.

Padding is part of an element's interactive surface, so eligibility uses the
border box. The effective clip is already an intersected world rectangle, so a
node hidden by any clipping ancestor is rejected by one test.
*/
@(private)
_hit_eligible_node :: proc(frame_result: Frame_Result, handle: Node_Handle, point: Vec2) -> (Resolved_Node, bool) {
	candidate, found := node(frame_result, handle)
	if !found || !candidate.flags.hit_testable {
		return {}, false
	}
	if !_point_in_rect(candidate.outer, point) || !_point_in_rect(clip_of(frame_result, candidate.clip).rect, point) {
		return {}, false
	}
	return candidate, true
}

@(private)
_hit_eligible :: proc(frame_result: Frame_Result, handle: Node_Handle, point: Vec2) -> bool {
	_, eligible := _hit_eligible_node(frame_result, handle, point)
	return eligible
}

/*
Front-most node under a point.

`hit_order` is already front-to-back, so the first eligible entry is the
answer and the scan exits there.
*/
hit_test :: proc(frame_result: Frame_Result, point: Vec2) -> (Resolved_Node, bool) #optional_ok {
	for handle in frame_result.hit_order {
		candidate, eligible := _hit_eligible_node(frame_result, handle, point)
		if eligible {
			return candidate, true
		}
	}
	return {}, false
}

/*
Every node under a point, front to back.

This is an overlap stack, not an ancestor chain: siblings and nodes from
different paint roots may all appear. `Hit_Mode.Opaque` ends it, which is how a
modal overlay stops events reaching the content behind it.

The returned `complete` flag is false only when an eligible hit did not fit in
`out`. The scan continues after a full output buffer so callers can distinguish
an exact result from a truncated prefix without guessing a larger buffer.
*/
hit_stack :: proc(frame_result: Frame_Result, point: Vec2, out: []Node_Handle) -> (hits: []Node_Handle, complete: bool) {
	count := 0
	for handle in frame_result.hit_order {
		if !_hit_eligible(frame_result, handle, point) {
			continue
		}
		if count >= len(out) {
			return out[:count], false
		}
		out[count] = handle
		count += 1
		candidate, found := node(frame_result, handle)
		if found && candidate.flags.hit_opaque {
			return out[:count], true
		}
	}
	return out[:count], true
}

/*
Structural ancestry of a node, innermost first.

This is not a hit query: it inspects neither overlap nor `Hit_Mode`, and it
crosses overlay boundaries because the published links are lexical. It is the
basis for event bubbling.

`found` reports whether `target` was a node in the published frame. A valid
path is walked to completion even after `out` fills, so `complete` reports
whether the returned prefix contains the whole ancestry.
*/
ancestor_path :: proc(frame_result: Frame_Result, target: Node_Handle, out: []Node_Handle) -> (path: []Node_Handle, complete: bool, found: bool) {
	count := 0
	complete = true
	current := target
	for {
		resolved, current_found := node(frame_result, current)
		if !current_found {
			if !found {
				return out[:0], true, false
			}
			return out[:count], complete, true
		}
		found = true
		if count < len(out) {
			out[count] = current
			count += 1
		} else {
			complete = false
		}
		current = resolved.parent
	}
}

/*
Iterate the commands whose bounds meet a rectangle.

Culling tests `bounds` alone. The effective clip is deliberately not consulted:
a command hidden by an empty clip is still emitted under `Cull_Policy.All`
precisely so a retained backend can see that it exists and is hidden, and the
supplied rectangle is an arbitrary world-space region that need not have any
relationship to a clip. Clip-based omission is the cull policy's job.

Culling is a view over the published stream, so the yielded commands are always
a subsequence of `commands` in the same order, and the node table is untouched.
The iterator borrows the result tables; it remains valid only while the supplied
`Frame_Result` remains valid (until the next frame, destroy, or reserve).
*/
Command_Iterator :: struct {
	_result:   Frame_Result,
	_viewport: Rect,
	_next:     int,
}

// visible_commands iterates the frame's render commands that intersect
// `viewport`, in paint order. The iterator draws from `frame_result.commands`,
// which shares its lifetime with `frame_result`. A non-positive viewport extent
// yields no commands.
visible_commands :: proc(frame_result: Frame_Result, viewport: Rect) -> Command_Iterator {
	return Command_Iterator{_result = frame_result, _viewport = viewport}
}

next_command :: proc(iterator: ^Command_Iterator) -> (command: Render_Command, index: int, ok: bool) {
	for iterator._next < len(iterator._result.commands) {
		index = iterator._next
		iterator._next += 1
		candidate := iterator._result.commands[index]
		if !_rect_intersects(candidate.bounds, iterator._viewport) {
			continue
		}
		return candidate, index, true
	}
	return {}, 0, false
}
