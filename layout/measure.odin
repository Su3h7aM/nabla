package layout

@(private)
_sanitize_measure_result :: proc(state: ^_Context_State, node: Node_Handle, result: Measure_Result, request: Measure_Request) -> Measure_Result {
	measured := result
	if !request.want_baseline {
		measured.baseline = 0
	}
	invalid := false
	values := [5]^Scalar{&measured.size.x, &measured.size.y, &measured.min_size.x, &measured.min_size.y, &measured.baseline}
	for value in values {
		if !_scalar_is_finite(value^) || value^ < 0 {
			value^ = 0
			invalid = true
		} else {
			value^ = _canonical_zero(value^)
		}
	}
	if invalid {
		_append_diagnostic(state, .Measure_Failed, node, loc = state._node_inputs[node].loc)
	}
	for axis in Axis {
		if request.axes[axis].mode == .Exact {
			measured.size[int(axis)] = request.axes[axis].value
		}
	}
	return measured
}

@(private)
_measure_custom :: proc(state: ^_Context_State, node: Node_Handle, content: Custom_Content, request: Measure_Request) -> Measure_Result {
	if content.measure == nil {
		return {}
	}
	if state._measuring {
		when ODIN_DEBUG {
			assert(false, "layout: measurement callback reentered the active context")
		}
		_append_diagnostic(state, .Measure_Reentered, node, loc = state._node_inputs[node].loc)
		return {}
	}
	state._measuring = true
	defer state._measuring = false

	measured, measure_error := content.measure(content.data, request)
	if measure_error != .None {
		_append_diagnostic(state, .Measure_Failed, node, loc = state._node_inputs[node].loc)
		state._frame_error = .Measure_Failed
		return {}
	}
	return _sanitize_measure_result(state, node, measured, request)
}

/*
Measure a text run through the configured text service.

`text` is a sub-slice of the node's declared string, so wrapping can measure
individual words without copying. Results are sanitized exactly like custom
measurements: non-finite or negative components become zero and record a
`Measure_Failed` diagnostic.
*/
@(private)
_measure_text_run :: proc(state: ^_Context_State, node: Node_Handle, text: string, request: Measure_Request) -> (Measure_Result, bool) {
	measurer := state._services.measure_text
	if measurer == nil {
		return {}, false
	}
	if state._measuring {
		when ODIN_DEBUG {
			assert(false, "layout: measurement callback reentered the active context")
		}
		_append_diagnostic(state, .Measure_Reentered, node, loc = state._node_inputs[node].loc)
		return {}, false
	}
	state._measuring = true
	defer state._measuring = false

	measured, measure_error := measurer(state._services.measure_text_user_data, text, state._node_inputs[node].text_style, request)
	if measure_error != .None {
		_append_diagnostic(state, .Measure_Failed, node, loc = state._node_inputs[node].loc)
		state._frame_error = .Measure_Failed
		return {}, false
	}
	return _sanitize_measure_result(state, node, measured, request), true
}

@(private)
_measure_text_run_cached :: proc(state: ^_Context_State, node: Node_Handle, text: string, request: Measure_Request) -> Measure_Result {
	key, cacheable := _measure_cache_key(state, node, text, request)
	if !cacheable {
		measured, _ := _measure_text_run(state, node, text, request)
		return measured
	}
	if cached, hit := _measure_cache_lookup(state, key); hit {
		return cached
	}
	// A failed measurement is never cached: caching it would hide the
	// `Measure_Failed` diagnostic on every later frame while its zero geometry
	// persisted until the next explicit invalidation.
	measured, succeeded := _measure_text_run(state, node, text, request)
	if succeeded {
		_measure_cache_store(state, key, measured)
	}
	return measured
}

@(private)
_measure_node_intrinsic :: proc(state: ^_Context_State, node: Node_Handle) -> Measure_Result {
	input := &state._node_inputs[node]
	if input.is_text {
		return _measure_text_intrinsic(state, node)
	}
	switch content in input.desc.content {
	case Image_Content:
		return Measure_Result{size = content.intrinsic_size}
	case Custom_Content:
		return _measure_custom(state, node, content, Measure_Request{axes = {.X = {mode = .Unbounded}, .Y = {mode = .Unbounded}}})
	case:
		return {}
	}
}

@(private)
_remeasure_node_at_width :: proc(state: ^_Context_State, node: Node_Handle, width: Scalar) -> Measure_Result {
	input := &state._node_inputs[node]
	switch content in input.desc.content {
	case Custom_Content:
		return _measure_custom(state, node, content, Measure_Request{axes = {.X = {mode = .Exact, value = width}, .Y = {mode = .Unbounded}}})
	case Image_Content:
		return Measure_Result{size = content.intrinsic_size}
	case:
		return {}
	}
}

@(private)
_remeasure_node_at_height :: proc(state: ^_Context_State, node: Node_Handle, height: Scalar) -> Measure_Result {
	input := &state._node_inputs[node]
	switch content in input.desc.content {
	case Custom_Content:
		return _measure_custom(state, node, content, Measure_Request{axes = {.X = {mode = .Unbounded}, .Y = {mode = .Exact, value = height}}})
	case Image_Content:
		return Measure_Result{size = content.intrinsic_size}
	case:
		return {}
	}
}
