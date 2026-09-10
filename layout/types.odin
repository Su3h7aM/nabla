package layout

import "base:runtime"

Scalar :: f32
Vec2 :: distinct [2]Scalar
Rect :: struct {
	position, size: Vec2,
}
Edges :: struct {
	left, top, right, bottom: Scalar,
}
Radius :: struct {
	tl, tr, br, bl: Scalar,
}
Color :: distinct [4]u8

Axis :: enum u8 {
	X,
	Y,
}
Axis_Set :: distinct bit_set[Axis;u8]

SCALAR_TOLERANCE :: Scalar(1e-4)

Id :: distinct u64
Node_Handle :: distinct u32
Clip_Handle :: distinct u32
Image_Handle :: distinct u64
Font :: distinct u32
Custom_Kind :: distinct u32
User_Tag :: distinct u64

Size_Mode :: enum u8 {
	Fit,
	Grow,
	Fixed,
	Percent,
}

Axis_Size :: struct {
	mode:   Size_Mode,
	value:  Scalar,
	min:    Scalar,
	max:    Scalar,
	weight: Scalar,
}

Sizing :: struct {
	width, height: Axis_Size,
}
Flow :: enum u8 {
	Row,
	Column,
}
Justify :: enum u8 {
	Start,
	Center,
	End,
	Space_Between,
	Space_Around,
	Space_Evenly,
}
Align :: enum u8 {
	Start,
	Center,
	End,
	Stretch,
}

Layout_Style :: struct {
	flow:    Flow,
	sizing:  Sizing,
	padding: Edges,
	gap:     Scalar,
	justify: Justify,
	align:   Align,
	aspect:  Scalar,
}

Border_Style :: struct {
	color:            Color,
	width:            Edges,
	between_children: Scalar,
}

Paint_Style :: struct {
	background: Color,
	radius:     Radius,
	border:     Border_Style,
}

Constraint_Mode :: enum u8 {
	Unbounded,
	At_Most,
	Exact,
}
Axis_Constraint :: struct {
	mode:  Constraint_Mode,
	value: Scalar,
}

Measure_Request :: struct {
	axes:          [Axis]Axis_Constraint,
	want_baseline: bool,
}

Measure_Result :: struct {
	size:     Vec2,
	min_size: Vec2,
	baseline: Scalar,
}

Measure_Error :: enum u8 {
	None,
	Invalid_Text,
	Invalid_Constraint,
}

Measure_Proc :: #type proc(user_data: rawptr, request: Measure_Request) -> (Measure_Result, Measure_Error)

Wrap :: enum u8 {
	Words,
	Newlines,
	None,
}
Text_Align :: enum u8 {
	Start,
	Center,
	End,
}

Text_Style :: struct {
	font:           Font,
	size:           Scalar,
	color:          Color,
	line_height:    Scalar,
	letter_spacing: Scalar,
	wrap:           Wrap,
	align:          Text_Align,
}

Text_Measure_Proc :: #type proc(user_data: rawptr, text: string, style: Text_Style, request: Measure_Request) -> (Measure_Result, Measure_Error)

Text_Break_Kind :: enum u8 {
	// No further break: the run ends the text.
	None,
	// A break may be taken here; the wrapping policy decides (whitespace).
	Optional,
	// A break must be taken here (a line terminator).
	Mandatory,
}

Text_Break_Error :: enum u8 {
	None,
	Invalid_Text,
}

// Text_Break_Proc reports the next line-break opportunity in a text run.
//
// Starting at `offset`, `[offset, piece_end)` is the maximal unbreakable run —
// the span the caller measures. `[piece_end, next_offset)` is the separator
// that follows it: whitespace for an Optional break, a line terminator (CRLF
// counted as one) for a Mandatory break. `kind` is .None when the run ends the
// text, in which case `piece_end == next_offset == len(text)`.
//
// Contract: `offset <= piece_end <= next_offset <= len(text)`, and the breaker
// must make progress — `next_offset > offset` unless `piece_end == len(text)`.
// `.None` is only valid at the end of the text, and the end of the text is only
// valid as `.None`. It must not allocate and must not retain `text` (the buffer
// is borrowed).
Text_Break_Proc :: #type proc(user_data: rawptr, text: string, offset: int) -> (piece_end: int, next_offset: int, kind: Text_Break_Kind, err: Text_Break_Error)

Text_Flag :: enum u8 {
	Static,
}
Text_Flags :: distinct bit_set[Text_Flag;u8]

Text_Desc :: struct {
	id:     Id,
	text:   string,
	style:  Text_Style,
	flags:  Text_Flags,
	sizing: Sizing,
	user:   User_Tag,
}

Image_Source_Mode :: enum u8 {
	Whole,
	Normalized,
}

Image_Source :: struct {
	mode: Image_Source_Mode,
	uv:   Rect,
}

Image_Tint :: struct {
	enabled: bool,
	color:   Color,
}

Image_Content :: struct {
	handle:         Image_Handle,
	intrinsic_size: Vec2,
	source:         Image_Source,
	tint:           Image_Tint,
}

Custom_Content :: struct {
	kind:    Custom_Kind,
	data:    rawptr,
	measure: Measure_Proc,
}

Content :: union {
	Image_Content,
	Custom_Content,
}

Clip_Style :: struct {
	axes:   Axis_Set,
	offset: Vec2,
}

Attach_To :: enum u8 {
	None,
	Parent,
	Root,
	Element,
}

Attach_Point :: enum u8 {
	Left_Top,
	Left_Center,
	Left_Bottom,
	Center_Top,
	Center_Center,
	Center_Bottom,
	Right_Top,
	Right_Center,
	Right_Bottom,
}

Clip_To :: enum u8 {
	None,
	Attached_Parent,
}

Overlay_Style :: struct {
	attach:       Attach_To,
	target:       Id,
	self_point:   Attach_Point,
	target_point: Attach_Point,
	offset:       Vec2,
	expand:       Vec2,
	layer:        i16,
	clip_to:      Clip_To,
}

Hit_Mode :: enum u8 {
	Normal,
	Passthrough,
	Opaque,
}

Element_Desc :: struct {
	id:      Id,
	layout:  Layout_Style,
	paint:   Paint_Style,
	content: Content,
	clip:    Clip_Style,
	overlay: Overlay_Style,
	hit:     Hit_Mode,
	user:    User_Tag,
}

Pool_Id :: enum u8 {
	None,
	Nodes,
	Children,
	Clips,
	Commands,
	Text_Lines,
	Measured_Words,
	Overlays,
	Measure_Cache,
	Id_Table,
	Depth,
	Diagnostics,
	Debug_Labels,
	Solver_Scratch,
	Hit_Order,
	Id_Index,
}

Diagnostic_Kind :: enum u8 {
	Duplicate_Id,
	Invalid_Sizing,
	Percent_Out_Of_Range,
	Percent_Indefinite,
	// Grow on an axis the parent sizes from content (Fit) cannot express:
	// there is no available space to grow into, so it degrades to its content
	// size with no effect. Diagnosed symmetric with Percent_Indefinite; the
	// references both collapse silently here, which is precisely the bug a
	// hard rejection was meant to make observable.
	Grow_Indefinite,
	Min_Exceeds_Max,
	Aspect_Undetermined,
	Overflow,
	Missing_Overlay_Target,
	Overlay_Dependency_Cycle,
	Measure_Failed,
	Measure_Reentered,
	// The break callback failed to advance past its offset, which would spin
	// the wrapping loop. The frame is failed instead of looping forever.
	Text_Break_Stalled,
	Pool_Exhausted,
}

Diagnostic :: struct {
	kind:   Diagnostic_Kind,
	node:   Node_Handle,
	id:     Id,
	axis:   Axis,
	amount: Scalar,
	pool:   Pool_Id,
	loc:    runtime.Source_Code_Location,
}

Statistics :: struct {
	pool_high_water:  [Pool_Id]int,
	frames_started:   u64,
	frames_completed: u64,
	frames_failed:    u64,
	declarations:     u64,
}

Capacities :: struct {
	nodes, children, clips, commands, text_lines, overlays:    int,
	measure_cache, id_table, depth, diagnostics, debug_labels: int,
	// Words retained across a frame so wrapping reuses the advances intrinsic
	// sizing already measured instead of re-measuring each word. Zero disables
	// the reuse: wrapping still produces identical geometry, it just measures
	// each word again. Budget one entry per whitespace-separated word across
	// every text node declared in a frame.
	measured_words:                                            int,
}

Cull_Policy :: enum u8 {
	All,
	Visible,
}

Options :: struct {
	capacities:   Capacities,
	cull:         Cull_Policy,
	debug_labels: bool,
}

Services :: struct {
	measure_text:           Text_Measure_Proc,
	measure_text_user_data: rawptr,
	break_text:             Text_Break_Proc,
	break_text_user_data:   rawptr,
}

Context_Data_Error :: enum u8 {
	None,
	Invalid_Options,
	Storage_Too_Small,
}

Context_Error :: union #shared_nil {
	Context_Data_Error,
	runtime.Allocator_Error,
}

Frame_Error :: enum u8 {
	None,
	Not_Initialized,
	Frame_Already_Open,
	No_Completed_Frame,
	Unbalanced_Scope,
	Missing_Text_Measurer,
	Missing_Text_Breaker,
	Text_Break_Stalled,
	Measure_Failed,
	Invalid_Text,
	Capacity_Exhausted,
}
