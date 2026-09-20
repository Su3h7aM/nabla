package tui

import "base:runtime"

import "nabla:layout"
import "nabla:term"
import width_text "nabla:text"

// MAX_SCOPE_DEPTH bounds the lexical render tree kept inline in Context.
MAX_SCOPE_DEPTH :: 64

Box :: enum u8 {
	Outer,
	Inner,
}

Element_Desc :: struct {
	id:  layout.Id,
	box: Box,
}

Element_Node_Desc :: struct {
	node: layout.Node_Handle,
	box:  Box,
}

Frame_Error :: enum u8 {
	None,
	Frame_Already_Open,
	No_Completed_Frame,
	Invalid_Layout_Result,
	Buffer_Too_Small,
	Non_Integral_Geometry,
	Scope_Exhausted,
	Element_Not_Found,
	Element_Outside_Scope,
	Unbalanced_Scope,
	Invalid_Text,
	Invalid_Cursor,
}

Frame :: struct {
	buffer: term.Frame_Buffer,
	cursor: term.Cursor,
}

@(private)
_Scope :: struct {
	node:        layout.Node_Handle,
	outer:       Cell_Rect,
	inner:       Cell_Rect,
	bounds:      Cell_Rect,
	clip:        Cell_Rect,
	frame_scope: bool,
}

// Context is a zero-initialized, allocation-free renderer for one frame at a
// time. It borrows the layout result, cell storage, and every drawn grapheme
// until result is consumed by term.present or the next frame begins.
Context :: struct {
	_result:       layout.Frame_Result,
	_buffer:       term.Frame_Buffer,
	_cursor:       term.Cursor,
	_scopes:       [MAX_SCOPE_DEPTH]_Scope,
	_scope_count:  int,
	_profile:      width_text.Width_Profile,
	_error:        Frame_Error,
	_frame_open:   bool,
	_result_ready: bool,
}

// frame opens a terminal render scope over a completed layout frame. The
// viewport initializes the cell grid, and the block closes with a complete
// Frame available from result.
@(deferred_in_out = _frame_leave)
frame :: proc(
	ctx: ^Context,
	#by_ptr frame_result: layout.Frame_Result,
	storage: []term.Cell,
	base: term.Style = {},
	profile: width_text.Width_Profile = width_text.DEFAULT_WIDTH_PROFILE,
	loc := #caller_location,
) -> bool {
	if ctx == nil {
		return false
	}
	if ctx._frame_open {
		ctx._error = .Frame_Already_Open
		when ODIN_DEBUG {
			assert(false, "tui: frame called while another frame is open", loc)
		}
		return false
	}

	ctx._result_ready = false
	ctx._error = .None
	ctx._scope_count = 0
	if len(frame_result.nodes) == 0 || len(frame_result.clips) == 0 {
		ctx._error = .Invalid_Layout_Result
		return false
	}
	viewport, projection_error := project_rect_integral(layout.Rect{size = frame_result.viewport})
	clip, clip_error := project_rect_integral(layout.clip_of(frame_result, 0).rect)
	if projection_error != .None || clip_error != .None {
		ctx._error = .Non_Integral_Geometry
		return false
	}
	if !init(&ctx._buffer, viewport.width, viewport.height, storage, base) {
		ctx._error = .Buffer_Too_Small
		return false
	}

	ctx._result = frame_result
	ctx._cursor = {}
	ctx._profile = profile
	ctx._scopes[0] = _Scope {
		outer       = viewport,
		inner       = viewport,
		bounds      = viewport,
		clip        = clip,
		frame_scope = true,
	}
	ctx._scope_count = 1
	ctx._frame_open = true
	return true
}

@(private)
_frame_leave :: proc(
	ctx: ^Context,
	#by_ptr frame_result: layout.Frame_Result,
	storage: []term.Cell,
	base: term.Style,
	profile: width_text.Width_Profile,
	loc: runtime.Source_Code_Location,
	entered: bool,
) {
	if !entered {
		return
	}
	_ = frame_result
	_ = storage
	_ = base
	_ = profile
	_ = loc

	balanced := ctx != nil && ctx._frame_open && ctx._scope_count == 1 && ctx._scopes[0].frame_scope
	if !balanced {
		if ctx != nil {
			ctx._error = .Unbalanced_Scope
			ctx._frame_open = false
			ctx._result_ready = false
			ctx._scope_count = 0
		}
		assert(false, "tui: unbalanced internal scope stack")
		return
	}
	ctx._scope_count = 0
	ctx._frame_open = false
	ctx._result_ready = ctx._error == .None
}

// element enters the resolved outer or inner box for id. Lexical nesting must
// match the layout tree, so a child cannot be rendered outside its parent.
@(deferred_in_out = _element_leave)
element :: proc(ctx: ^Context, desc: Element_Desc, loc := #caller_location) -> bool {
	if ctx == nil || !ctx._frame_open || ctx._error != .None {
		return false
	}
	handle, found := layout.lookup_handle(ctx._result, desc.id)
	if !found {
		ctx._error = .Element_Not_Found
		return false
	}
	return _element_enter(ctx, handle, desc.box, loc)
}

// element_node is the handle-based form used while iterating a Frame_Result.
// It has the same lexical nesting and clipping contract as element.
@(deferred_in_out = _element_node_leave)
element_node :: proc(ctx: ^Context, desc: Element_Node_Desc, loc := #caller_location) -> bool {
	return _element_enter(ctx, desc.node, desc.box, loc)
}

@(private)
_element_enter :: proc(ctx: ^Context, handle: layout.Node_Handle, box: Box, loc: runtime.Source_Code_Location) -> bool {
	if ctx == nil || !ctx._frame_open || ctx._error != .None {
		return false
	}
	if ctx._scope_count >= len(ctx._scopes) {
		ctx._error = .Scope_Exhausted
		return false
	}
	resolved, found := layout.node(ctx._result, handle)
	if !found {
		ctx._error = .Element_Not_Found
		return false
	}
	parent := ctx._scopes[ctx._scope_count - 1]
	if resolved.parent != parent.node {
		ctx._error = .Element_Outside_Scope
		when ODIN_DEBUG {
			assert(false, "tui: render scope does not match the layout tree", loc)
		}
		return false
	}
	outer, outer_error := project_rect_integral(resolved.outer)
	inner, inner_error := project_rect_integral(resolved.inner)
	clip, clip_error := project_rect_integral(layout.clip_of(ctx._result, resolved.clip).rect)
	if outer_error != .None || inner_error != .None || clip_error != .None {
		ctx._error = .Non_Integral_Geometry
		return false
	}
	bounds := outer
	if box == .Inner {
		bounds = inner
	}
	ctx._scopes[ctx._scope_count] = _Scope {
		node   = handle,
		outer  = outer,
		inner  = inner,
		bounds = bounds,
		clip   = clip,
	}
	ctx._scope_count += 1
	return true
}

@(private)
_element_pop :: proc(ctx: ^Context) {
	if ctx == nil || !ctx._frame_open || ctx._scope_count <= 1 {
		if ctx != nil {
			ctx._error = .Unbalanced_Scope
		}
		assert(false, "tui: unbalanced internal element scope")
		return
	}
	ctx._scope_count -= 1
}

@(private)
_element_leave :: proc(ctx: ^Context, desc: Element_Desc, loc: runtime.Source_Code_Location, entered: bool) {
	if !entered {
		return
	}
	_ = desc
	_ = loc
	_element_pop(ctx)
}

@(private)
_element_node_leave :: proc(ctx: ^Context, desc: Element_Node_Desc, loc: runtime.Source_Code_Location, entered: bool) {
	if !entered {
		return
	}
	_ = desc
	_ = loc
	_element_pop(ctx)
}

// current_node returns the active layout node. The frame root is handle zero.
current_node :: proc(ctx: ^Context) -> (layout.Node_Handle, bool) #optional_ok {
	if ctx == nil || !ctx._frame_open || ctx._scope_count == 0 {
		return 0, false
	}
	return ctx._scopes[ctx._scope_count - 1].node, true
}

// bounds returns the active scope's selected box.
bounds :: proc(ctx: ^Context) -> (Cell_Rect, bool) #optional_ok {
	if ctx == nil || !ctx._frame_open || ctx._scope_count == 0 {
		return {}, false
	}
	return ctx._scopes[ctx._scope_count - 1].bounds, true
}

// width_profile returns the width policy bound to the active frame.
width_profile :: proc(ctx: ^Context) -> (width_text.Width_Profile, bool) #optional_ok {
	if ctx == nil || !ctx._frame_open {
		return {}, false
	}
	return ctx._profile, true
}

// boxes returns the active element's outer and inner boxes.
boxes :: proc(ctx: ^Context) -> (outer, inner: Cell_Rect, ok: bool) {
	if ctx == nil || !ctx._frame_open || ctx._scope_count == 0 {
		return {}, {}, false
	}
	scope := ctx._scopes[ctx._scope_count - 1]
	return scope.outer, scope.inner, true
}

// result returns the completed terminal frame. Its cells and grapheme strings
// retain the lifetimes supplied to frame and the draw calls.
@(require_results)
result :: proc(ctx: ^Context) -> (Frame, Frame_Error) {
	if ctx == nil || ctx._frame_open || !ctx._result_ready {
		if ctx != nil && ctx._error != .None {
			return {}, ctx._error
		}
		return {}, .No_Completed_Frame
	}
	return Frame{buffer = ctx._buffer, cursor = ctx._cursor}, .None
}

// set_cursor sets the terminal cursor intent for the current frame.
set_cursor :: proc(ctx: ^Context, cursor: term.Cursor) -> bool {
	if ctx == nil || !ctx._frame_open || ctx._error != .None {
		return false
	}
	if cursor.placed && (cursor.position.x < 0 || cursor.position.y < 0 || cursor.position.x >= ctx._buffer.columns || cursor.position.y >= ctx._buffer.rows) {
		ctx._error = .Invalid_Cursor
		return false
	}
	ctx._cursor = cursor
	return true
}

put_context :: proc(ctx: ^Context, x, y: int, grapheme: string, style: term.Style) -> bool {
	if ctx == nil || !ctx._frame_open || ctx._error != .None || ctx._scope_count == 0 {
		return false
	}
	scope := ctx._scopes[ctx._scope_count - 1]
	return put_at(ctx, scope.bounds.x + x, scope.bounds.y + y, grapheme, style)
}

// put_at writes one grapheme at an absolute cell coordinate, clipped to the
// active scope.
put_at :: proc(ctx: ^Context, x, y: int, grapheme: string, style: term.Style) -> bool {
	if ctx == nil || !ctx._frame_open || ctx._error != .None || ctx._scope_count == 0 {
		return false
	}
	scope := ctx._scopes[ctx._scope_count - 1]
	visible := _intersect_rect(scope.bounds, scope.clip)
	width := width_text.cluster_width(grapheme, ctx._profile)
	if width < 1 || x < visible.x || y < visible.y || x + width > _rect_end(visible.x, visible.width) || y >= _rect_end(visible.y, visible.height) {
		return false
	}
	return put_cell(&ctx._buffer, x, y, grapheme, style, ctx._profile)
}

fill_context :: proc(ctx: ^Context, grapheme: string, style: term.Style) -> int {
	if ctx == nil || !ctx._frame_open || ctx._error != .None || ctx._scope_count == 0 {
		return 0
	}
	if width_text.cluster_width(grapheme, ctx._profile) != 1 {
		return 0
	}
	scope := ctx._scopes[ctx._scope_count - 1]
	return _fill_clipped(&ctx._buffer, scope.bounds, scope.clip, grapheme, style)
}

// fill_at fills an absolute cell rectangle, clipped to the active scope.
fill_at :: proc(ctx: ^Context, rect: Cell_Rect, grapheme: string, style: term.Style) -> int {
	if ctx == nil || !ctx._frame_open || ctx._error != .None || ctx._scope_count == 0 {
		return 0
	}
	if width_text.cluster_width(grapheme, ctx._profile) != 1 {
		return 0
	}
	scope := ctx._scopes[ctx._scope_count - 1]
	return _fill_clipped(&ctx._buffer, _intersect_rect(rect, scope.bounds), scope.clip, grapheme, style)
}

@(require_results)
draw_text_context :: proc(ctx: ^Context, value: string, style: term.Style) -> (int, bool) {
	if ctx == nil || !ctx._frame_open || ctx._error != .None || ctx._scope_count == 0 {
		return 0, false
	}
	scope := ctx._scopes[ctx._scope_count - 1]
	written, ok := _draw_text_clipped(&ctx._buffer, scope.bounds, scope.clip, value, style, ctx._profile)
	if !ok {
		ctx._error = .Invalid_Text
	}
	return written, ok
}

// text draws the active layout text node's resolved lines. Wrapping and line
// positions come from layout; style supplies the terminal-specific paint.
@(require_results)
text :: proc(ctx: ^Context, style: term.Style) -> (written: int, ok: bool) {
	if ctx == nil || !ctx._frame_open || ctx._error != .None || ctx._scope_count <= 1 {
		return 0, false
	}
	scope := ctx._scopes[ctx._scope_count - 1]
	ok = true
	for command in ctx._result.commands {
		if command.node != scope.node {
			continue
		}
		text_command, is_text := command.data.(layout.Text_Cmd)
		if !is_text {
			continue
		}
		rect, rect_error := project_rect_integral(command.bounds)
		clip, clip_error := project_rect_integral(layout.clip_of(ctx._result, command.clip).rect)
		if rect_error != .None || clip_error != .None {
			ctx._error = .Non_Integral_Geometry
			return written, false
		}
		line_written, line_ok := _draw_text_clipped(&ctx._buffer, rect, _intersect_rect(scope.bounds, clip), text_command.text, style, ctx._profile)
		if !line_ok {
			ctx._error = .Invalid_Text
			return written, false
		}
		written += line_written
	}
	return written, true
}

// draw_text_at draws one line in an absolute cell rectangle, clipped to the
// active scope. Text still advances from rect.x when its left edge is clipped.
@(require_results)
draw_text_at :: proc(ctx: ^Context, rect: Cell_Rect, value: string, style: term.Style) -> (int, bool) {
	if ctx == nil || !ctx._frame_open || ctx._error != .None || ctx._scope_count == 0 {
		return 0, false
	}
	scope := ctx._scopes[ctx._scope_count - 1]
	written, ok := _draw_text_clipped(&ctx._buffer, rect, _intersect_rect(scope.bounds, scope.clip), value, style, ctx._profile)
	if !ok {
		ctx._error = .Invalid_Text
	}
	return written, ok
}
