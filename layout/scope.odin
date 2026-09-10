package layout

import "base:runtime"
import "core:mem"

@(private)
_reset_frame_state :: proc(state: ^_Context_State) {
	clear(&state._node_inputs)
	clear(&state._nodes)
	clear(&state._children)
	clear(&state._clips)
	clear(&state._commands)
	clear(&state._text_lines)
	clear(&state._measured_words)
	clear(&state._roots)
	clear(&state._root_order)
	clear(&state._root_paint)
	clear(&state._root_nodes)
	clear(&state._scopes)
	clear(&state._solver_scratch)
	clear(&state._hit_order)
	clear(&state._id_index)
	clear(&state._diagnostics)
	mem.zero_slice(state._id_table)
	state._result_ready = false
	state._frame_error = .None
	state._failed_pool = .None
	state._id_table_count = 0
	state._reserved_child_links = 0
}

@(private)
_discard_unpublished_result :: proc(state: ^_Context_State) {
	clear(&state._nodes)
	clear(&state._clips)
	clear(&state._commands)
	clear(&state._hit_order)
	clear(&state._id_index)
	state._result_ready = false
}

// frame opens a new frame on the context and resets its frame-local state.
//
// Declare the tree inside the `if frame(&ui, viewport) { ... }` block; the
// block's body runs only when the frame opened. The frame stays open until the
// block exits, then resolves and publishes its result. Only one frame may be
// open at a time, and no frame may be open when `result` is called.
@(deferred_in_out = _frame_leave)
frame :: proc(ctx: ^Context, viewport: Vec2, loc := #caller_location) -> bool {
	if ctx == nil || !_context_state(ctx)._initialized {
		if ctx != nil {
			_context_state(ctx)._frame_error = .Not_Initialized
		}
		when ODIN_DEBUG {
			assert(false, "layout: frame called with an uninitialized context", loc)
		}
		return false
	}
	state := _context_state(ctx)
	if state._measuring {
		when ODIN_DEBUG {
			assert(false, "layout: measurement callback reentered the active context", loc)
		}
		_append_diagnostic(state, .Measure_Reentered, 0, loc = loc)
		return false
	}
	if state._frame_open {
		if state._frame_error == .None {
			state._frame_error = .Frame_Already_Open
		}
		when ODIN_DEBUG {
			assert(false, "layout: frame called while another frame is open", loc)
		}
		return false
	}

	_reset_frame_state(state)
	normalized_viewport := viewport
	_normalize_nonnegative(state, &normalized_viewport.x, 0, .X, loc)
	_normalize_nonnegative(state, &normalized_viewport.y, 0, .Y, loc)
	state._viewport = normalized_viewport

	assert(cap(state._node_inputs) >= 1)
	assert(cap(state._nodes) >= 1)
	assert(cap(state._clips) >= 1)
	assert(cap(state._scopes) >= 1)

	ok := _try_append(&state._node_inputs, _Node_Input{private_id = Id(FNV64_OFFSET_BASIS), definite = {.X = true, .Y = true}, in_flow = true})
	assert(ok)
	ok = _try_append(&state._nodes, Resolved_Node{})
	assert(ok)
	ok = _try_append(&state._clips, Resolved_Clip{rect = {size = normalized_viewport}, axes = {.X, .Y}})
	assert(ok)
	ok = _try_append(&state._scopes, _Scope_Record{kind = .Frame})
	assert(ok)
	// The normal-flow tree is paint root zero, at absolute layer 0 and
	// declaration sequence 0, so it is registered before any overlay.
	ok = _try_append(&state._roots, _Paint_Root{dependency = -1})
	assert(ok)

	state._frame_open = true
	state._statistics.frames_started += 1
	_update_high_water(state, .Nodes, len(state._nodes))
	_update_high_water(state, .Clips, len(state._clips))
	_update_high_water(state, .Depth, len(state._scopes))
	return true
}

@(private)
_frame_leave :: proc(ctx: ^Context, viewport: Vec2, loc: runtime.Source_Code_Location, entered: bool) {
	if !entered {
		return
	}
	_ = viewport
	_ = loc

	state := _context_state(ctx)
	balanced := ctx != nil && state._frame_open && len(state._scopes) == 1 && state._scopes[len(state._scopes) - 1].kind == .Frame
	if !balanced {
		if ctx != nil {
			state._frame_error = .Unbalanced_Scope
			state._frame_open = false
			state._statistics.frames_failed += 1
			_discard_unpublished_result(state)
		}
		assert(false, "layout: unbalanced internal scope stack")
		return
	}

	_ = pop(&state._scopes)
	state._frame_open = false
	assert(len(state._solver_scratch) == state._node_inputs[0].child_count)

	if state._frame_error == .None {
		_solve_frame(state)
	}
	clear(&state._solver_scratch)
	if state._frame_error == .None {
		state._generation += 1
		state._result_ready = true
		state._statistics.frames_completed += 1
	} else {
		_discard_unpublished_result(state)
		state._statistics.frames_failed += 1
	}
	// Service callbacks and their user data are borrowed only for this solve.
	// Clearing them at the publication boundary prevents a later frame from
	// accidentally invoking stale caller-owned state.
	state._services = {}
}

@(private)
_complete_node_declaration :: proc(state: ^_Context_State, node: Node_Handle) {
	input := &state._node_inputs[node]
	child_count := input.child_count
	assert(child_count >= 0 && child_count <= len(state._solver_scratch))
	input.child_start = len(state._children)
	start := len(state._solver_scratch) - child_count
	for child in state._solver_scratch[start:] {
		ok := _try_append(&state._children, child)
		assert(ok)
	}
	for _ in 0 ..< child_count {
		_ = pop(&state._solver_scratch)
	}
	state._reserved_child_links -= child_count
	assert(state._reserved_child_links >= 0)

	ok := _try_append(&state._solver_scratch, node)
	assert(ok)
	_update_high_water(state, .Children, len(state._children) + state._reserved_child_links)
}

@(private)
_declare_node :: proc(
	ctx: ^Context,
	#by_ptr desc: Element_Desc,
	scoped: bool,
	loc: runtime.Source_Code_Location,
	extra_diagnostics := 0,
) -> (
	Node_Handle,
	bool,
) {
	if ctx == nil {
		return 0, false
	}
	state := _context_state(ctx)
	if state._measuring {
		when ODIN_DEBUG {
			assert(false, "layout: measurement callback reentered the active context", loc)
		}
		_append_diagnostic(state, .Measure_Reentered, 0, loc = loc)
		return 0, false
	}
	if !state._initialized || !state._frame_open || state._frame_error != .None {
		return 0, false
	}

	parent := state._scopes[len(state._scopes) - 1].node
	parent_input := &state._node_inputs[parent]
	needs_child_link := parent != 0
	needs_overlay_record := desc.overlay.attach != .None
	needs_identifier := desc.id != 0
	needs_scope := scoped

	if len(state._node_inputs) >= cap(state._node_inputs) || len(state._nodes) >= cap(state._nodes) {
		_latch_capacity_error(state, .Nodes, loc)
		return 0, false
	}
	if needs_scope && len(state._scopes) >= cap(state._scopes) {
		_latch_capacity_error(state, .Depth, loc)
		return 0, false
	}
	if parent != 0 && parent_input.child_count >= int(max(u16)) {
		_latch_capacity_error(state, .Children, loc)
		return 0, false
	}
	if needs_child_link && len(state._children) + state._reserved_child_links >= cap(state._children) {
		_latch_capacity_error(state, .Children, loc)
		return 0, false
	}
	if needs_overlay_record && len(state._roots) >= cap(state._roots) {
		_latch_capacity_error(state, .Overlays, loc)
		return 0, false
	}

	id_slot := 0
	duplicate_identifier := false
	if needs_identifier {
		available := false
		id_slot, duplicate_identifier, available = _id_table_probe(state, desc.id)
		if !available {
			_latch_capacity_error(state, .Id_Table, loc)
			return 0, false
		}
		if !duplicate_identifier && len(state._id_index) >= cap(state._id_index) {
			_latch_capacity_error(state, .Id_Index, loc)
			return 0, false
		}
	}

	required_diagnostics := _element_diagnostic_count(desc) + extra_diagnostics
	if duplicate_identifier {
		required_diagnostics += 1
	}
	ordinary_diagnostic_limit := cap(state._diagnostics) - 1
	if required_diagnostics > ordinary_diagnostic_limit - len(state._diagnostics) {
		_latch_capacity_error(state, .Diagnostics, loc)
		return 0, false
	}

	node := Node_Handle(len(state._node_inputs))
	normalized_desc := _normalize_element_desc(state, desc, node, loc)
	if state._frame_error != .None {
		return 0, false
	}
	sibling_ordinal := u64(parent_input.child_count)
	private_identifier := _auto_id(parent_input.private_id, sibling_ordinal)
	previous_sibling := parent_input.last_child
	depth := len(state._scopes) - 1
	// An overlay leaves its declaration parent's flow and starts a new paint
	// root; everything below it is in that root's own normal flow.
	in_flow := !needs_overlay_record
	root := parent_input.root
	if needs_overlay_record {
		root = i32(len(state._roots))
	}

	ok := _try_append(&state._node_inputs, _Node_Input{desc = normalized_desc, loc = loc, private_id = private_identifier, root = root, in_flow = in_flow})
	assert(ok)
	ok = _try_append(
		&state._nodes,
		Resolved_Node {
			id = normalized_desc.id,
			parent = parent,
			user = normalized_desc.user,
			flags = {
				is_overlay = needs_overlay_record,
				hit_testable = normalized_desc.hit != .Passthrough,
				hit_opaque = normalized_desc.hit == .Opaque,
				depth = u16(depth),
			},
		},
	)
	assert(ok)

	if previous_sibling != 0 {
		state._nodes[previous_sibling].next_sibling = node
	} else if parent != 0 {
		state._nodes[parent].first_child = node
	}
	parent_input = &state._node_inputs[parent]
	parent_input.last_child = node
	parent_input.child_count += 1
	if parent != 0 {
		state._nodes[parent].child_count = u16(parent_input.child_count)
	}
	if needs_child_link {
		state._reserved_child_links += 1
	}

	if needs_identifier {
		if duplicate_identifier {
			_append_diagnostic(state, .Duplicate_Id, node, identifier = normalized_desc.id, loc = loc)
		} else {
			_id_table_insert(state, id_slot, normalized_desc.id, node)
			ok = _try_append(&state._id_index, Id_Index_Entry{id = normalized_desc.id, node = node})
			assert(ok)
		}
	}
	if needs_overlay_record {
		ok = _try_append(
			&state._roots,
			_Paint_Root {
				node = node,
				target_id = normalized_desc.overlay.target,
				attach = normalized_desc.overlay.attach,
				clip_to = normalized_desc.overlay.clip_to,
				layer = normalized_desc.overlay.layer,
				dependency = -1,
			},
		)
		assert(ok)
	}
	if needs_scope {
		ok = _try_append(&state._scopes, _Scope_Record{kind = .Element, node = node})
		assert(ok)
	} else {
		_complete_node_declaration(state, node)
	}

	state._statistics.declarations += 1
	_update_high_water(state, .Nodes, len(state._nodes))
	_update_high_water(state, .Overlays, len(state._roots) - 1)
	_update_high_water(state, .Depth, len(state._scopes))
	_update_high_water(state, .Id_Index, len(state._id_index))
	return node, true
}

@(deferred_in_out = _element_leave)
// element declares an element node and, when it returns true, opens a scope
// that its children are declared into. Pair each call with the closing `}` of
// the conditional so the scope closes at the right point.
element :: proc(ctx: ^Context, #by_ptr desc: Element_Desc, loc := #caller_location) -> bool {
	_, entered := _declare_node(ctx, desc, true, loc)
	return entered
}

// content declares a leaf node with no children. Unlike `element` it opens no
// scope, so it is valid anywhere a node may be declared, including as a
// one-line body.
content :: proc(ctx: ^Context, #by_ptr desc: Element_Desc, loc := #caller_location) {
	_, _ = _declare_node(ctx, desc, false, loc)
}

@(private)
_element_leave :: proc(ctx: ^Context, #by_ptr desc: Element_Desc, loc: runtime.Source_Code_Location, entered: bool) {
	if !entered {
		return
	}
	_ = desc
	_ = loc

	state := _context_state(ctx)
	balanced := ctx != nil && state._frame_open && len(state._scopes) > 1 && state._scopes[len(state._scopes) - 1].kind == .Element
	if !balanced {
		if ctx != nil {
			state._frame_error = .Unbalanced_Scope
		}
		assert(false, "layout: unbalanced internal element scope")
		return
	}
	node := state._scopes[len(state._scopes) - 1].node
	_complete_node_declaration(state, node)
	_ = pop(&state._scopes)
}
