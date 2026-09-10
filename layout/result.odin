package layout

Node_Flags :: bit_field u32 {
	visible:      bool | 1,
	clipped:      bool | 1,
	overflow_x:   bool | 1,
	overflow_y:   bool | 1,
	is_overlay:   bool | 1,
	is_text:      bool | 1,
	hit_testable: bool | 1,
	hit_opaque:   bool | 1,
	depth:        u16  | 12,
}

#assert(size_of(Node_Flags) == 4)

Resolved_Node :: struct {
	id:            Id,
	parent:        Node_Handle,
	first_child:   Node_Handle,
	next_sibling:  Node_Handle,
	outer:         Rect,
	inner:         Rect,
	content_size:  Vec2,
	scroll_range:  Vec2,
	scroll_offset: Vec2,
	clip:          Clip_Handle,
	user:          User_Tag,
	layer:         i16,
	child_count:   u16,
	flags:         Node_Flags,
}

Resolved_Clip :: struct {
	rect:   Rect,
	owner:  Node_Handle,
	parent: Clip_Handle,
	axes:   Axis_Set,
}

Fill_Cmd :: struct {
	color:  Color,
	radius: Radius,
}

Border_Cmd :: struct {
	color:  Color,
	radius: Radius,
	width:  Edges,
}

Text_Cmd :: struct {
	text:     string,
	style:    Text_Style,
	line:     u16,
	baseline: Scalar,
}

Image_Cmd :: struct {
	handle: Image_Handle,
	tint:   Color,
	radius: Radius,
	source: Image_Source,
}

Custom_Cmd :: struct {
	kind:   Custom_Kind,
	data:   rawptr,
	radius: Radius,
}

Command_Data :: union #no_nil {
	Fill_Cmd,
	Border_Cmd,
	Text_Cmd,
	Image_Cmd,
	Custom_Cmd,
}

Render_Command :: struct {
	bounds: Rect,
	clip:   Clip_Handle,
	node:   Node_Handle,
	layer:  i16,
	data:   Command_Data,
}

Id_Index_Entry :: struct {
	id:   Id,
	node: Node_Handle,
}

// Frame_Result is a borrowed view of one completed frame's published tables.
//
// Every slice aliases the context's storage and is valid only until the next
// `frame` on the same context, or until the context is `destroy`ed or
// `reserve`d. The caller must not retain these slices across frames.
Frame_Result :: struct {
	generation: u32,
	viewport:   Vec2,
	nodes:      []Resolved_Node,
	clips:      []Resolved_Clip,
	commands:   []Render_Command,
	hit_order:  []Node_Handle,
	id_index:   []Id_Index_Entry,
}

// result returns the most recently completed frame as a borrowed view.
//
// No frame may be open when this is called. The returned `Frame_Result` shares
// its slices' validity with the context (see `Frame_Result`); a completed frame
// with a frame error reports that error instead of a result.
@(require_results)
result :: proc(ctx: ^Context) -> (Frame_Result, Frame_Error) {
	if ctx == nil || !_context_state(ctx)._initialized {
		return {}, .Not_Initialized
	}
	state := _context_state(ctx)
	if state._measuring {
		when ODIN_DEBUG {
			assert(false, "layout: result called from a measurement callback")
		}
		_append_diagnostic(state, .Measure_Reentered, 0)
		return {}, .No_Completed_Frame
	}
	if state._frame_open {
		return {}, .No_Completed_Frame
	}
	if !state._result_ready {
		if state._frame_error != .None {
			return {}, state._frame_error
		}
		return {}, .No_Completed_Frame
	}
	return Frame_Result {
			generation = state._generation,
			viewport = state._viewport,
			nodes = state._nodes[:],
			clips = state._clips[:],
			commands = state._commands[:],
			hit_order = state._hit_order[:],
			id_index = state._id_index[:],
		},
		.None
}

// lookup finds the node carrying `identifier`, binary-searching the frame's
// id index. The returned node is a copy drawn from `frame_result.nodes`, which
// shares its lifetime with `frame_result`.
lookup :: proc(frame_result: Frame_Result, identifier: Id) -> (Resolved_Node, bool) #optional_ok {
	if identifier == 0 {
		return {}, false
	}
	left := 0
	right := len(frame_result.id_index)
	for left < right {
		middle := left + (right - left) / 2
		entry := frame_result.id_index[middle]
		if u64(entry.id) < u64(identifier) {
			left = middle + 1
		} else {
			right = middle
		}
	}
	if left >= len(frame_result.id_index) || frame_result.id_index[left].id != identifier {
		return {}, false
	}
	handle := frame_result.id_index[left].node
	index, valid := _node_index(frame_result, handle)
	if !valid || index == 0 {
		return {}, false
	}
	return frame_result.nodes[index], true
}

// node returns the node at `handle`, or false when the handle is out of
// range. The returned node is a copy drawn from `frame_result.nodes`, which
// shares its lifetime with `frame_result`.
@(private)
_node_index :: proc "contextless" (frame_result: Frame_Result, handle: Node_Handle) -> (int, bool) {
	index := u64(handle)
	if index >= u64(len(frame_result.nodes)) {
		return 0, false
	}
	return int(index), true
}

node :: proc(frame_result: Frame_Result, handle: Node_Handle) -> (Resolved_Node, bool) #optional_ok {
	index, valid := _node_index(frame_result, handle)
	if !valid || index == 0 {
		return {}, false
	}
	return frame_result.nodes[index], true
}
