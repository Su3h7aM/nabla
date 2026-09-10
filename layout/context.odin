package layout

import "base:runtime"
import "core:mem"

@(private)
_Node_Input :: struct {
	desc:              Element_Desc,
	loc:               runtime.Source_Code_Location,
	private_id:        Id,
	child_start:       int,
	child_count:       int,
	last_child:        Node_Handle,
	intrinsic_size:    Vec2,
	minimum_size:      Vec2,
	content_size:      Vec2,
	content_minimum:   Vec2,
	definite:          [Axis]bool,
	authored_definite: [Axis]bool,
	aspect_derived:    [Axis]bool,
	aspect_size:       [Axis]Scalar,
	axis_baseline:     [Axis]Scalar,
	correction_used:   [Axis]bool,
	pending_overflow:  [Axis]Scalar,
	root:              i32,
	child_delta:       Vec2,
	child_clip:        Clip_Handle,
	subtree_end:       int,
	in_flow:           bool,
	text:              string,
	text_style:        Text_Style,
	text_flags:        Text_Flags,
	// Identity of this node's text and style, folded once at declaration.
	// Measurement keys extend it with the offset and length of the run being
	// measured, so a lookup costs a few multiplies rather than a hash over the
	// whole string.
	text_key:          u64,
	text_line_start:   int,
	text_line_count:   int,
	// Range of this node's records in `_measured_words`, filled by intrinsic
	// measurement and consumed by wrapping.
	word_start:        int,
	word_count:        int,
	segment_count:     int,
	line_height:       Scalar,
	is_text:           bool,
}

@(private)
_Text_Line_Record :: struct {
	text:     string,
	position: Vec2,
	size:     Vec2,
	line:     u16,
	baseline: Scalar,
}

/*
One word of a text node, measured once per frame.

Intrinsic sizing already has to visit every word to find the shrink floor, so
it records each word's advance here and wrapping consumes the record instead of
re-measuring. Offsets are relative to the node's own text, so the records stay
valid however the string is sliced later.

`separator_width` is the advance of the whitespace run that follows the word,
folded in here so packing a line is a running sum with no lookups at all.
*/
@(private)
_Measured_Word :: struct {
	offset:          i32,
	length:          i32,
	separator_end:   i32,
	width:           Scalar,
	separator_width: Scalar,
	height:          Scalar,
	// Index of the hard segment this word belongs to, so wrapping can find
	// segment boundaries without rescanning the string for newlines.
	segment:         i32,
}

/*
One independently placed paint root.

Entry zero is the normal-flow tree; every overlay adds one more. `dependency`
names the root that must be placed first because this root attaches to a node
inside it, and `node_start`/`node_count` delimit this root's slice of
`_root_nodes`.
*/
@(private)
_Paint_Root :: struct {
	node:       Node_Handle,
	target:     Node_Handle,
	target_id:  Id,
	attach:     Attach_To,
	clip_to:    Clip_To,
	layer:      i16,
	dependency: i32,
	walk_mark:  i32,
	node_start: int,
	node_count: int,
	ordered:    bool,
}

@(private)
_Measure_Cache_Entry :: struct {
	key:        u64,
	result:     Measure_Result,
	generation: u32,
	occupied:   bool,
}

@(private)
_Id_Table_Entry :: struct {
	id:       Id,
	node:     Node_Handle,
	label:    string,
	occupied: bool,
}

@(private)
_Debug_Label_Entry :: struct {
	id:    Id,
	label: string,
}

@(private)
_Scope_Kind :: enum u8 {
	Frame,
	Element,
}

@(private)
_Scope_Record :: struct {
	kind: _Scope_Kind,
	node: Node_Handle,
}

@(private)
_Storage_Partition :: struct {
	base:   uintptr,
	limit:  int,
	offset: int,
}

@(private)
_Context_State :: struct {
	_initialized:          bool,
	_owns_storage:         bool,
	_frame_open:           bool,
	_result_ready:         bool,
	_measuring:            bool,
	_allocator:            runtime.Allocator,
	_storage:              []byte,
	_options:              Options,
	_services:             Services,
	_metrics_generation:   u32,
	_generation:           u32,
	_viewport:             Vec2,
	_frame_error:          Frame_Error,
	_failed_pool:          Pool_Id,
	_id_table_count:       int,
	_measure_cache_count:  int,
	_reserved_child_links: int,
	_node_inputs:          [dynamic]_Node_Input,
	_nodes:                [dynamic]Resolved_Node,
	_children:             [dynamic]Node_Handle,
	_clips:                [dynamic]Resolved_Clip,
	_commands:             [dynamic]Render_Command,
	_text_lines:           [dynamic]_Text_Line_Record,
	_measured_words:       [dynamic]_Measured_Word,
	_roots:                [dynamic]_Paint_Root,
	_measure_cache:        [dynamic]_Measure_Cache_Entry,
	_id_table:             []_Id_Table_Entry,
	_scopes:               [dynamic]_Scope_Record,
	_solver_scratch:       [dynamic]Node_Handle,
	_root_nodes:           [dynamic]Node_Handle,
	_root_order:           [dynamic]i32,
	_root_paint:           [dynamic]u64,
	_hit_order:            [dynamic]Node_Handle,
	_id_index:             [dynamic]Id_Index_Entry,
	_diagnostics:          [dynamic]Diagnostic,
	_debug_labels:         [dynamic]byte,
	_debug_label_entries:  [dynamic]_Debug_Label_Entry,
	_statistics:           Statistics,
	_payload_size:         int,
}

/*
Context owns the state for one independent layout instance.

Its zero value is ready for `init` or `init_from_buffer`. Do not copy a Context after
successful initialization. Call `destroy` when finished; it frees only storage
allocated by `init`, never storage supplied to `init_from_buffer`.
*/
// Context is a frame-local solver handle over storage owned by the caller.
//
// `init` allocates the storage and frees it in `destroy`; `init_from_buffer` borrows
// the storage slice passed to it and never frees it. In either case the caller
// must keep the backing storage alive and at stable addresses until the context
// is discarded or initialized again. The context does not resize, reallocate,
// or share its storage.
Context :: struct {
	_state: _Context_State,
}

@(private)
_context_state :: proc(ctx: ^Context) -> ^_Context_State {
	return &ctx._state
}

// Bind measurement and line-breaking services for the next frame. The
// callback pointers and user data are borrowed only during that frame's solve;
// they are cleared after publication and never retained in cached results.
set_services :: proc(ctx: ^Context, services: Services) {
	if ctx == nil || !_context_state(ctx)._initialized {
		return
	}
	state := _context_state(ctx)
	if state._measuring || state._frame_open {
		when ODIN_DEBUG {
			assert(false, "layout: set_services must be called before frame")
		}
		return
	}
	state._services = services
}

@(private)
STORAGE_ALIGNMENT :: max(
	align_of(_Node_Input),
	align_of(Resolved_Node),
	align_of(Node_Handle),
	align_of(Resolved_Clip),
	align_of(Render_Command),
	align_of(_Text_Line_Record),
	align_of(_Paint_Root),
	align_of(i32),
	align_of(u64),
	align_of(_Measure_Cache_Entry),
	align_of(_Id_Table_Entry),
	align_of(_Scope_Record),
	align_of(Id_Index_Entry),
	align_of(Diagnostic),
	align_of(byte),
	align_of(_Debug_Label_Entry),
)

storage_alignment :: proc "contextless" () -> int {
	return STORAGE_ALIGNMENT
}

@(private)
_checked_add_int :: proc "contextless" (left, right: int) -> (int, bool) {
	if left < 0 || right < 0 || left > max(int) - right {
		return 0, false
	}
	return left + right, true
}

@(private)
_checked_mul_int :: proc "contextless" (left, right: int) -> (int, bool) {
	if left < 0 || right < 0 {
		return 0, false
	}
	if left != 0 && right > max(int) / left {
		return 0, false
	}
	return left * right, true
}

@(private)
_align_offset :: proc "contextless" (offset, alignment: int) -> (int, bool) {
	if offset < 0 || alignment <= 0 || alignment & (alignment - 1) != 0 {
		return 0, false
	}
	mask := alignment - 1
	padding := (alignment - (offset & mask)) & mask
	return _checked_add_int(offset, padding)
}

@(private)
_partition_take_bytes :: proc "contextless" (partition: ^_Storage_Partition, count: int, element_size: int, element_alignment: int) -> ([]byte, bool) {
	start, ok := _align_offset(partition.offset, element_alignment)
	if !ok {
		return nil, false
	}
	byte_count: int
	byte_count, ok = _checked_mul_int(count, element_size)
	if !ok {
		return nil, false
	}
	end: int
	end, ok = _checked_add_int(start, byte_count)
	if !ok || end > partition.limit {
		return nil, false
	}
	partition.offset = end
	if byte_count == 0 || partition.base == 0 {
		return nil, true
	}
	return ([^]byte)(partition.base + uintptr(start))[:byte_count], true
}

@(private)
_partition_take_slice :: proc "contextless" (partition: ^_Storage_Partition, $T: typeid, count: int) -> ([]T, bool) {
	region, ok := _partition_take_bytes(partition, count, size_of(T), align_of(T))
	if !ok {
		return nil, false
	}
	if count == 0 || partition.base == 0 {
		return nil, true
	}
	return ([^]T)(raw_data(region))[:count], true
}

@(private)
_partition_storage :: proc(state: ^_Context_State, partition: ^_Storage_Partition, capacities: Capacities) -> bool {
	node_inputs, ok := _partition_take_slice(partition, _Node_Input, capacities.nodes)
	if !ok {
		return false
	}
	nodes: []Resolved_Node
	nodes, ok = _partition_take_slice(partition, Resolved_Node, capacities.nodes)
	if !ok {
		return false
	}
	children: []Node_Handle
	children, ok = _partition_take_slice(partition, Node_Handle, capacities.children)
	if !ok {
		return false
	}
	clips: []Resolved_Clip
	clips, ok = _partition_take_slice(partition, Resolved_Clip, capacities.clips)
	if !ok {
		return false
	}
	commands: []Render_Command
	commands, ok = _partition_take_slice(partition, Render_Command, capacities.commands)
	if !ok {
		return false
	}
	text_lines: []_Text_Line_Record
	text_lines, ok = _partition_take_slice(partition, _Text_Line_Record, capacities.text_lines)
	if !ok {
		return false
	}
	measured_words: []_Measured_Word
	measured_words, ok = _partition_take_slice(partition, _Measured_Word, capacities.measured_words)
	if !ok {
		return false
	}
	// The normal-flow tree is always a paint root, so the pool holds one more
	// entry than the configured overlay budget. The count is computed with a
	// checked add because `storage_size` is public and unvalidated, and because
	// the `u32` bound in `_config_is_valid` cannot reject `max(int)` where `int`
	// is 32 bits wide.
	root_count: int
	root_count, ok = _checked_add_int(capacities.overlays, 1)
	if !ok {
		return false
	}
	roots: []_Paint_Root
	roots, ok = _partition_take_slice(partition, _Paint_Root, root_count)
	if !ok {
		return false
	}
	root_order: []i32
	root_order, ok = _partition_take_slice(partition, i32, root_count)
	if !ok {
		return false
	}
	root_paint: []u64
	root_paint, ok = _partition_take_slice(partition, u64, root_count)
	if !ok {
		return false
	}
	root_nodes: []Node_Handle
	root_nodes, ok = _partition_take_slice(partition, Node_Handle, capacities.nodes)
	if !ok {
		return false
	}
	measure_cache: []_Measure_Cache_Entry
	measure_cache, ok = _partition_take_slice(partition, _Measure_Cache_Entry, capacities.measure_cache)
	if !ok {
		return false
	}
	id_table: []_Id_Table_Entry
	id_table, ok = _partition_take_slice(partition, _Id_Table_Entry, capacities.id_table)
	if !ok {
		return false
	}
	scopes: []_Scope_Record
	scopes, ok = _partition_take_slice(partition, _Scope_Record, capacities.depth)
	if !ok {
		return false
	}
	solver_scratch: []Node_Handle
	solver_scratch, ok = _partition_take_slice(partition, Node_Handle, capacities.nodes)
	if !ok {
		return false
	}
	hit_order: []Node_Handle
	hit_order, ok = _partition_take_slice(partition, Node_Handle, capacities.nodes)
	if !ok {
		return false
	}
	id_index: []Id_Index_Entry
	id_index, ok = _partition_take_slice(partition, Id_Index_Entry, capacities.nodes)
	if !ok {
		return false
	}
	diagnostics: []Diagnostic
	diagnostics, ok = _partition_take_slice(partition, Diagnostic, capacities.diagnostics)
	if !ok {
		return false
	}
	debug_label_entries: []_Debug_Label_Entry
	debug_label_entries, ok = _partition_take_slice(partition, _Debug_Label_Entry, capacities.nodes)
	if !ok {
		return false
	}
	debug_labels: []byte
	debug_labels, ok = _partition_take_slice(partition, byte, capacities.debug_labels)
	if !ok {
		return false
	}

	if state != nil {
		state._node_inputs = mem.buffer_from_slice(node_inputs)
		state._nodes = mem.buffer_from_slice(nodes)
		state._children = mem.buffer_from_slice(children)
		state._clips = mem.buffer_from_slice(clips)
		state._commands = mem.buffer_from_slice(commands)
		state._text_lines = mem.buffer_from_slice(text_lines)
		state._measured_words = mem.buffer_from_slice(measured_words)
		state._roots = mem.buffer_from_slice(roots)
		state._root_order = mem.buffer_from_slice(root_order)
		state._root_paint = mem.buffer_from_slice(root_paint)
		state._root_nodes = mem.buffer_from_slice(root_nodes)
		state._measure_cache = mem.buffer_from_slice(measure_cache)
		// The cache is an open-addressed table, so every slot must be addressable.
		resize(&state._measure_cache, len(measure_cache))
		state._id_table = id_table
		state._scopes = mem.buffer_from_slice(scopes)
		state._solver_scratch = mem.buffer_from_slice(solver_scratch)
		state._hit_order = mem.buffer_from_slice(hit_order)
		state._id_index = mem.buffer_from_slice(id_index)
		state._diagnostics = mem.buffer_from_slice(diagnostics)
		state._debug_labels = mem.buffer_from_slice(debug_labels)
		state._debug_label_entries = mem.buffer_from_slice(debug_label_entries)
	}
	return true
}

@(private)
_storage_payload_size :: proc(capacities: Capacities) -> (int, bool) {
	partition := _Storage_Partition {
		limit = max(int),
	}
	if !_partition_storage(nil, &partition, capacities) {
		return 0, false
	}
	return partition.offset, true
}

storage_size :: proc(capacities: Capacities) -> int {
	payload_size, ok := _storage_payload_size(capacities)
	if !ok {
		return 0
	}
	total_size: int
	total_size, ok = _checked_add_int(payload_size, storage_alignment() - 1)
	if !ok {
		return 0
	}
	return total_size
}

@(private)
_config_is_valid :: proc(config: Options) -> bool {
	capacities := config.capacities
	if capacities.nodes < 1 || capacities.clips < 1 || capacities.depth < 1 || capacities.diagnostics < 1 {
		return false
	}
	if capacities.children < 0 ||
	   capacities.commands < 0 ||
	   capacities.text_lines < 0 ||
	   capacities.measured_words < 0 ||
	   capacities.overlays < 0 ||
	   capacities.measure_cache < 0 ||
	   capacities.id_table < 0 ||
	   capacities.debug_labels < 0 {
		return false
	}
	if u64(capacities.nodes) > u64(max(u32)) || capacities.depth > 4096 || u64(capacities.overlays) > u64(max(u32)) {
		return false
	}
	return storage_size(capacities) > 0
}

@(private)
_storage_aligned_base :: proc "contextless" (storage: []byte) -> (aligned_base: uintptr, leading_byte_count: int, ok: bool) {
	if len(storage) == 0 {
		return
	}
	storage_base := uintptr(raw_data(storage))
	alignment := uintptr(storage_alignment())
	aligned_base = (storage_base + alignment - 1) & ~(alignment - 1)
	leading_byte_count_unsigned := aligned_base - storage_base
	if leading_byte_count_unsigned > uintptr(len(storage)) {
		return 0, 0, false
	}
	return aligned_base, int(leading_byte_count_unsigned), true
}

@(private)
_init_with_storage :: proc(ctx: ^Context, config: Options, storage: []byte, allocator: runtime.Allocator, owns_storage: bool) -> Context_Error {
	payload_size, ok := _storage_payload_size(config.capacities)
	if !ok {
		return .Invalid_Options
	}
	aligned_base: uintptr
	leading_byte_count: int
	aligned_base, leading_byte_count, ok = _storage_aligned_base(storage)
	if !ok || len(storage) - leading_byte_count < payload_size {
		return .Storage_Too_Small
	}

	state := _Context_State {
		_initialized        = true,
		_owns_storage       = owns_storage,
		_allocator          = allocator,
		_storage            = storage,
		_options            = config,
		_metrics_generation = 0,
		_payload_size       = payload_size,
	}
	partition := _Storage_Partition {
		base  = aligned_base,
		limit = len(storage) - leading_byte_count,
	}
	if !_partition_storage(&state, &partition, config.capacities) || partition.offset != payload_size {
		return .Storage_Too_Small
	}
	_context_state(ctx)^ = state
	return nil
}

// init allocates fresh storage for the context from the supplied allocator.
//
// The context takes ownership of the allocation and frees it in `destroy`.
// Initialization is transactional: on failure the context is left untouched,
// still usable at its previous capacities. On success the context is ready to
// `frame`.
@(require_results)
init :: proc(ctx: ^Context, config: Options, allocator := context.allocator) -> Context_Error {
	if ctx != nil && _context_state(ctx)._initialized && _context_state(ctx)._measuring {
		when ODIN_DEBUG {
			assert(false, "layout: init called from a measurement callback")
		}
		_append_diagnostic(_context_state(ctx), .Measure_Reentered, 0)
		return .Invalid_Options
	}
	if ctx == nil || _context_state(ctx)._initialized || !_config_is_valid(config) || allocator.procedure == nil {
		return .Invalid_Options
	}
	size := storage_size(config.capacities)
	if size == 0 {
		return .Invalid_Options
	}
	storage, alloc_err := mem.alloc_bytes(size, storage_alignment(), allocator)
	if alloc_err != nil || len(storage) != size {
		if len(storage) > 0 {
			_ = mem.free_bytes(storage, allocator)
		}
		return alloc_err if alloc_err != nil else runtime.Allocator_Error.Out_Of_Memory
	}
	err := _init_with_storage(ctx, config, storage, allocator, true)
	if err != nil {
		_ = mem.free_bytes(storage, allocator)
	}
	return err
}

// init_from_buffer binds a caller-owned storage block to the context.
//
// `storage` must be at least `storage_size(config.capacities)` bytes. Unlike
// `init`, the context never frees or replaces this block: the caller retains
// ownership for its lifetime and must keep it alive and at a stable address
// until the context is discarded or initialized again. A context created this
// way cannot `reserve`.
@(require_results)
init_from_buffer :: proc(ctx: ^Context, config: Options, storage: []byte) -> Context_Error {
	if ctx != nil && _context_state(ctx)._initialized && _context_state(ctx)._measuring {
		when ODIN_DEBUG {
			assert(false, "layout: init_from_buffer called from a measurement callback")
		}
		_append_diagnostic(_context_state(ctx), .Measure_Reentered, 0)
		return .Invalid_Options
	}
	if ctx == nil || _context_state(ctx)._initialized || !_config_is_valid(config) {
		return .Invalid_Options
	}
	if len(storage) < storage_size(config.capacities) {
		return .Storage_Too_Small
	}
	return _init_with_storage(ctx, config, storage, {}, false)
}

/*
Raise capacities on a dynamically allocated context.

Follows the `reserve` convention of the core library: capacities are raised to
at least the requested values and never lowered, so the call is idempotent and
cannot discard live contents. A request that asks for no more than the current
capacities does nothing and allocates nothing.

Only contexts created by `init` can grow, because `init_from_buffer` storage belongs
to the caller. The call is rejected inside a frame and inside a measurement
callback, since it moves the storage every pool is carved from.

The operation is transactional: on any failure the context is left exactly as
it was, still usable at its previous capacities.

Growth allocates a new block and migrates, as the core map does, rather than
resizing in place; a partitioned block cannot grow in place because each pool
has neighbours after it. Every handle, `Frame_Result` slice, and `diagnostics`
slice obtained before the call is therefore invalidated, and the published
frame result is dropped rather than migrated, because it describes a frame
solved under the previous capacities. The measurement cache is discarded, so
the next frame remeasures. The metrics generation, the frame counters, and the
per-pool high-water marks survive, because they describe the whole lifetime of
the context rather than one frame.
*/
@(require_results)
reserve :: proc(ctx: ^Context, capacities: Capacities) -> Context_Error {
	if !_capacities_are_nonnegative(capacities) {
		return .Invalid_Options
	}
	if ctx != nil && _context_state(ctx)._initialized && _context_state(ctx)._measuring {
		when ODIN_DEBUG {
			assert(false, "layout: reserve called from a measurement callback")
		}
		_append_diagnostic(_context_state(ctx), .Measure_Reentered, 0)
		return .Invalid_Options
	}
	if ctx == nil || !_context_state(ctx)._initialized {
		return .Invalid_Options
	}
	state := _context_state(ctx)
	if state._frame_open {
		return .Invalid_Options
	}
	if !state._owns_storage {
		// `init_from_buffer` storage is the caller's; only they can replace it.
		return .Invalid_Options
	}

	config := state._options
	config.capacities = _capacities_union(state._options.capacities, capacities)
	if config.capacities == state._options.capacities {
		return nil
	}
	if !_config_is_valid(config) {
		return .Invalid_Options
	}
	size := storage_size(config.capacities)
	if size == 0 {
		return .Invalid_Options
	}

	storage, alloc_err := mem.alloc_bytes(size, storage_alignment(), state._allocator)
	if alloc_err != nil || len(storage) != size {
		if len(storage) > 0 {
			_ = mem.free_bytes(storage, state._allocator)
		}
		return alloc_err if alloc_err != nil else runtime.Allocator_Error.Out_Of_Memory
	}

	// Build the replacement beside the live context so a failure here cannot
	// leave a half-partitioned state behind.
	grown: Context
	err := _init_with_storage(&grown, config, storage, state._allocator, true)
	if err != nil {
		_ = mem.free_bytes(storage, state._allocator)
		return err
	}

	grown_state := _context_state(&grown)
	grown_state._metrics_generation = state._metrics_generation
	grown_state._generation = state._generation
	grown_state._statistics = state._statistics

	_ = mem.free_bytes(state._storage, state._allocator)
	ctx^ = grown
	return nil
}

@(private)
_capacities_are_nonnegative :: proc "contextless" (capacities: Capacities) -> bool {
	return(
		capacities.nodes >= 0 &&
		capacities.children >= 0 &&
		capacities.clips >= 0 &&
		capacities.commands >= 0 &&
		capacities.text_lines >= 0 &&
		capacities.measured_words >= 0 &&
		capacities.overlays >= 0 &&
		capacities.measure_cache >= 0 &&
		capacities.id_table >= 0 &&
		capacities.depth >= 0 &&
		capacities.diagnostics >= 0 &&
		capacities.debug_labels >= 0 \
	)
}

@(private)
_capacities_union :: proc "contextless" (current, requested: Capacities) -> Capacities {
	return Capacities {
		nodes = max(current.nodes, requested.nodes),
		children = max(current.children, requested.children),
		clips = max(current.clips, requested.clips),
		commands = max(current.commands, requested.commands),
		text_lines = max(current.text_lines, requested.text_lines),
		measured_words = max(current.measured_words, requested.measured_words),
		overlays = max(current.overlays, requested.overlays),
		measure_cache = max(current.measure_cache, requested.measure_cache),
		id_table = max(current.id_table, requested.id_table),
		depth = max(current.depth, requested.depth),
		diagnostics = max(current.diagnostics, requested.diagnostics),
		debug_labels = max(current.debug_labels, requested.debug_labels),
	}
}

// destroy releases a context's storage and returns it to its zero value.
//
// Only an `init`-created context frees its allocation; an `init_from_buffer` context
// borrows caller storage and leaves it untouched. Calling destroy on an
// uninitialized context is a no-op.
destroy :: proc(ctx: ^Context) {
	if ctx == nil || !_context_state(ctx)._initialized {
		return
	}
	state := _context_state(ctx)
	if state._measuring {
		when ODIN_DEBUG {
			assert(false, "layout: destroy called from a measurement callback")
		}
		_append_diagnostic(state, .Measure_Reentered, 0)
		return
	}
	if state._frame_open {
		when ODIN_DEBUG {
			assert(false, "layout: destroy called while a frame is open")
		}
		return
	}
	if state._owns_storage {
		_ = mem.free_bytes(state._storage, state._allocator)
	}
	ctx^ = {}
}

// diagnostics returns a borrowed view of the current frame's diagnostics.
//
// The view aliases the context's storage and is valid only until the next
// `frame` on the same context; it must not be retained across frames. Returns
// nil when no frame has completed.
diagnostics :: proc(ctx: ^Context) -> []Diagnostic {
	if ctx == nil || !_context_state(ctx)._initialized {
		return nil
	}
	state := _context_state(ctx)
	if state._measuring {
		when ODIN_DEBUG {
			assert(false, "layout: diagnostics called from a measurement callback")
		}
		_append_diagnostic(state, .Measure_Reentered, 0)
		return nil
	}
	return state._diagnostics[:]
}

// statistics returns the context's lifetime counters and per-pool high-water
// marks. The value is owned by the caller and stays valid indefinitely.
statistics :: proc(ctx: ^Context) -> Statistics {
	if ctx == nil || !_context_state(ctx)._initialized {
		return {}
	}
	state := _context_state(ctx)
	if state._measuring {
		when ODIN_DEBUG {
			assert(false, "layout: statistics called from a measurement callback")
		}
		_append_diagnostic(state, .Measure_Reentered, 0)
		return {}
	}
	return state._statistics
}

@(private)
_update_high_water :: proc(state: ^_Context_State, pool: Pool_Id, length: int) {
	if length > state._statistics.pool_high_water[pool] {
		state._statistics.pool_high_water[pool] = length
	}
}

@(private)
_try_append :: proc(array: ^[dynamic]$T, value: T) -> bool {
	if len(array^) >= cap(array^) {
		return false
	}
	_, err := append(array, value)
	return err == nil
}

@(private)
_try_append_diagnostic :: proc(state: ^_Context_State, diagnostic: Diagnostic) -> bool {
	// Ordinary diagnostics cannot consume the terminal capacity-error slot.
	if len(state._diagnostics) >= cap(state._diagnostics) - 1 {
		return false
	}
	if !_try_append(&state._diagnostics, diagnostic) {
		return false
	}
	_update_high_water(state, .Diagnostics, len(state._diagnostics))
	return true
}

@(private)
_latch_capacity_error :: proc(state: ^_Context_State, pool: Pool_Id, loc := #caller_location) {
	if state._frame_error != .None {
		return
	}
	state._frame_error = .Capacity_Exhausted
	state._failed_pool = pool

	// One slot is reserved by contract for this terminal diagnostic.
	assert(len(state._diagnostics) < cap(state._diagnostics))
	ok := _try_append(&state._diagnostics, Diagnostic{kind = .Pool_Exhausted, pool = pool, loc = loc})
	assert(ok)
	_update_high_water(state, .Diagnostics, len(state._diagnostics))
}
