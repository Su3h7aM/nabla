package layout

import "core:math"

@(private)
_snap_value :: proc "contextless" (pitch: Scalar, value: Scalar) -> Scalar {
	if pitch == 0 {
		return value
	}
	return _canonical_zero(Scalar(math.floor(f64(value) / f64(pitch) + 0.5) * f64(pitch)))
}

// _snap_rect rounds the four edges, not the size, so rects that share an edge keep sharing it.
@(private)
_snap_rect :: proc "contextless" (pitch: Scalar, rect: Rect) -> Rect {
	if pitch == 0 {
		return rect
	}
	result: Rect
	for axis in Axis {
		index := int(axis)
		low := _snap_value(pitch, rect.position[index])
		high := _snap_value(pitch, rect.position[index] + rect.size[index])
		result.position[index] = low
		result.size[index] = high - low
	}
	return result
}

@(private)
_snap_vec2 :: proc "contextless" (pitch: Scalar, value: Vec2) -> Vec2 {
	return {_snap_value(pitch, value.x), _snap_value(pitch, value.y)}
}

// _snap_geometry rounds every placed node and text line to the grid. Clips and
// commands derive from these boxes, so they follow.
@(private)
_snap_geometry :: proc(state: ^_Context_State) {
	pitch := state._options.snap
	if pitch == 0 {
		return
	}
	state._clips[0].rect = _snap_rect(pitch, state._clips[0].rect)
	for node_index in 1 ..< len(state._nodes) {
		node := &state._nodes[node_index]
		node.outer = _snap_rect(pitch, node.outer)
		node.inner = _snap_rect(pitch, node.inner)
		node.content_size = _snap_vec2(pitch, node.content_size)
		node.scroll_range = _snap_vec2(pitch, node.scroll_range)
		node.scroll_offset = _snap_vec2(pitch, node.scroll_offset)

		input := state._node_inputs[node_index]
		for line_index in 0 ..< input.text_line_count {
			record := &state._text_lines[input.text_line_start + line_index]
			bounds := _snap_rect(pitch, Rect{position = record.position, size = record.size})
			record.position = bounds.position
			record.size = bounds.size
			record.baseline = _snap_value(pitch, record.baseline)
		}
	}
}
