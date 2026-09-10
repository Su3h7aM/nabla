#+test
#+private file
package layout

import "base:runtime"
import "core:mem"
import "core:testing"

@(private)
_all_pools_aligned :: proc(ctx: ^Context) -> bool {
	state := _context_state(ctx)
	return(
		uintptr(raw_data(state._node_inputs)) % uintptr(align_of(_Node_Input)) == 0 &&
		uintptr(raw_data(state._nodes)) % uintptr(align_of(Resolved_Node)) == 0 &&
		uintptr(raw_data(state._children)) % uintptr(align_of(Node_Handle)) == 0 &&
		uintptr(raw_data(state._clips)) % uintptr(align_of(Resolved_Clip)) == 0 &&
		uintptr(raw_data(state._commands)) % uintptr(align_of(Render_Command)) == 0 &&
		uintptr(raw_data(state._text_lines)) % uintptr(align_of(_Text_Line_Record)) == 0 &&
		uintptr(raw_data(state._roots)) % uintptr(align_of(_Paint_Root)) == 0 &&
		uintptr(raw_data(state._root_order)) % uintptr(align_of(i32)) == 0 &&
		uintptr(raw_data(state._root_paint)) % uintptr(align_of(u64)) == 0 &&
		uintptr(raw_data(state._root_nodes)) % uintptr(align_of(Node_Handle)) == 0 &&
		uintptr(raw_data(state._measure_cache)) % uintptr(align_of(_Measure_Cache_Entry)) == 0 &&
		uintptr(raw_data(state._id_table)) % uintptr(align_of(_Id_Table_Entry)) == 0 &&
		uintptr(raw_data(state._scopes)) % uintptr(align_of(_Scope_Record)) == 0 &&
		uintptr(raw_data(state._solver_scratch)) % uintptr(align_of(Node_Handle)) == 0 &&
		uintptr(raw_data(state._hit_order)) % uintptr(align_of(Node_Handle)) == 0 &&
		uintptr(raw_data(state._id_index)) % uintptr(align_of(Id_Index_Entry)) == 0 &&
		uintptr(raw_data(state._diagnostics)) % uintptr(align_of(Diagnostic)) == 0 &&
		uintptr(raw_data(state._debug_labels)) % uintptr(align_of(byte)) == 0 &&
		uintptr(raw_data(state._debug_label_entries)) % uintptr(align_of(_Debug_Label_Entry)) == 0 \
	)
}

@(private)
_test_destroy_cleanup :: proc(data: rawptr) {
	destroy((^Context)(data))
}

@(private)
_test_aborted_frame_destroy_cleanup :: proc(data: rawptr) {
	ctx := (^Context)(data)
	state := _context_state(ctx)
	// An expected assertion terminates the worker without running the frame's
	// deferred exit, while registered cleanup runs later on the runner thread.
	state._frame_open = false
	destroy(ctx)
}

@(private)
_test_services :: proc() -> Services {
	return {}
}

_test_config :: proc() -> Options {
	return Options {
		capacities = {
			nodes = 32,
			children = 32,
			clips = 8,
			commands = 32,
			text_lines = 32,
			measured_words = 512,
			overlays = 8,
			measure_cache = 16,
			id_table = 32,
			depth = 16,
			diagnostics = 8,
			debug_labels = 128,
		},
	}
}

@(test)
test_color_constructors_and_mix :: proc(t: ^testing.T) {
	testing.expect_value(t, rgb(10, 20, 30), Color{10, 20, 30, 255})
	testing.expect_value(t, rgba(10, 20, 30, 40), Color{10, 20, 30, 40})
	testing.expect_value(t, gray(128), Color{128, 128, 128, 255})
	testing.expect_value(t, with_alpha(rgb(10, 20, 30), 40), Color{10, 20, 30, 40})
	testing.expect_value(t, opaque(rgba(10, 20, 30, 40)), Color{10, 20, 30, 255})

	testing.expect_value(t, mix(rgb(0, 0, 0), rgb(255, 255, 255), 0), rgb(0, 0, 0))
	testing.expect_value(t, mix(rgb(0, 0, 0), rgb(255, 255, 255), 1), rgb(255, 255, 255))
	testing.expect_value(t, mix(rgb(0, 0, 0), rgb(100, 200, 40), 0.5), Color{50, 100, 20, 255})
}

@(test)
test_public_type_contracts :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Element_Desc), 256)
	testing.expect(t, storage_alignment() >= align_of(Element_Desc))
	testing.expect(t, storage_alignment() & (storage_alignment() - 1) == 0)

	first := Vec2{1, 2}
	second := Vec2{3, 4}
	sum := first + second
	testing.expect_value(t, sum.x, Scalar(4))
	testing.expect_value(t, sum.y, Scalar(6))
	testing.expect_value(t, sum[int(Axis.X)], Scalar(4))
}

@(test)
test_dynamic_initialization_and_destroy :: proc(t: ^testing.T) {
	ctx: Context
	config := _test_config()
	err := init(&ctx, config)
	state := _context_state(&ctx)
	testing.expect_value(t, err, nil)
	testing.expect(t, state._initialized)
	testing.expect(t, state._owns_storage)
	testing.expect_value(t, len(state._storage), storage_size(config.capacities))
	testing.expect_value(t, state._payload_size, storage_size(config.capacities) - storage_alignment() + 1)
	destroy(&ctx)
	testing.expect(t, !state._initialized)
}

@(test)
test_initialization_is_transactional :: proc(t: ^testing.T) {
	ctx: Context
	state := _context_state(&ctx)
	config := _test_config()
	config.capacities.diagnostics = 0
	err := init(&ctx, config)
	testing.expect_value(t, err, Context_Data_Error.Invalid_Options)
	testing.expect(t, !state._initialized)
	testing.expect_value(t, len(state._storage), 0)

	valid := _test_config()
	size := storage_size(valid.capacities)
	too_small := make([]byte, size - 1)
	defer delete(too_small)
	err = init_from_buffer(&ctx, valid, too_small)
	testing.expect_value(t, err, Context_Data_Error.Storage_Too_Small)
	testing.expect(t, !state._initialized)

	err = init(&ctx, valid, mem.nil_allocator())
	testing.expect_value(t, err, runtime.Allocator_Error.Out_Of_Memory)
	testing.expect(t, !state._initialized)
}

@(test)
test_fixed_storage_accepts_every_base_misalignment :: proc(t: ^testing.T) {
	config := _test_config()
	size := storage_size(config.capacities)
	alignment := storage_alignment()
	backing := make([]byte, size + alignment)
	defer delete(backing)

	for offset in 0 ..< alignment {
		ctx: Context
		err := init_from_buffer(&ctx, config, backing[offset:offset + size])
		testing.expect_value(t, err, nil)
		if err != nil {
			continue
		}
		testing.expect(t, _all_pools_aligned(&ctx))
		testing.expect_value(t, _context_state(&ctx)._payload_size, size - alignment + 1)
		destroy(&ctx)
	}
}

@(test)
test_fixed_frame_path_does_not_allocate :: proc(t: ^testing.T) {
	config := _test_config()
	size := storage_size(config.capacities)
	backing := make([]byte, size)
	defer delete(backing)

	ctx: Context
	init_err: Context_Error
	frame_closed := false
	{
		context.allocator = mem.panic_allocator()
		init_err = init_from_buffer(&ctx, config, backing)
		if init_err == nil {
			if frame(&ctx, {640, 480}) {
				if element(&ctx, {}) {
					if element(&ctx, {}) {
					}
				}
			}
			state := _context_state(&ctx)
			frame_closed = !state._frame_open && len(state._scopes) == 0
			destroy(&ctx)
		}
	}
	testing.expect_value(t, init_err, nil)
	testing.expect(t, frame_closed)
}

@(private)
_run_early_return :: proc(ctx: ^Context) {
	if frame(ctx, {320, 200}) {
		if element(ctx, {}) {
			return
		}
	}
}

@(private)
_run_break :: proc(ctx: ^Context) {
	if frame(ctx, {320, 200}) {
		for _ in 0 ..< 3 {
			if element(ctx, {}) {
				break
			}
		}
	}
}

@(private)
_run_continue :: proc(ctx: ^Context) {
	if frame(ctx, {320, 200}) {
		for _ in 0 ..< 3 {
			if element(ctx, {}) {
				continue
			}
		}
	}
}

@(private)
_run_labelled_continue :: proc(ctx: ^Context) {
	outer: for _ in 0 ..< 2 {
		if frame(ctx, {320, 200}) {
			if element(ctx, {}) {
				continue outer
			}
		}
	}
}

@(test)
test_scopes_balance_on_all_control_flow_exits :: proc(t: ^testing.T) {
	ctx: Context
	err := init(&ctx, _test_config())
	state := _context_state(&ctx)
	testing.expect_value(t, err, nil)
	defer destroy(&ctx)

	if frame(&ctx, {320, 200}) {
		if element(&ctx, {}) {
			if element(&ctx, {}) {
			}
		}
	}
	testing.expect(t, !state._frame_open && len(state._scopes) == 0)

	_run_early_return(&ctx)
	testing.expect(t, !state._frame_open && len(state._scopes) == 0)

	_run_break(&ctx)
	testing.expect(t, !state._frame_open && len(state._scopes) == 0)

	_run_continue(&ctx)
	testing.expect(t, !state._frame_open && len(state._scopes) == 0)

	_run_labelled_continue(&ctx)
	testing.expect(t, !state._frame_open && len(state._scopes) == 0)
	testing.expect_value(t, state._statistics.frames_failed, u64(0))
	testing.expect_value(t, state._statistics.frames_completed, u64(6))
}

@(test)
test_failed_element_entry_does_not_run_leave :: proc(t: ^testing.T) {
	config := _test_config()
	config.capacities.overlays = 0
	ctx: Context
	err := init(&ctx, config)
	state := _context_state(&ctx)
	testing.expect_value(t, err, nil)
	defer destroy(&ctx)

	entered := false
	if frame(&ctx, {320, 200}) {
		desc := Element_Desc {
			id = 99,
			overlay = {attach = .Root},
		}
		if element(&ctx, desc) {
			entered = true
		}
		testing.expect(t, !entered)
		testing.expect_value(t, len(state._nodes), 1)
		testing.expect_value(t, state._id_table_count, 0)
		testing.expect_value(t, len(state._roots), 1)
		testing.expect_value(t, len(state._scopes), 1)
	}

	testing.expect(t, !state._frame_open && len(state._scopes) == 0)
	testing.expect_value(t, state._frame_error, Frame_Error.Capacity_Exhausted)
	testing.expect_value(t, len(diagnostics(&ctx)), 1)
	testing.expect_value(t, diagnostics(&ctx)[0].pool, Pool_Id.Overlays)
	testing.expect_value(t, state._statistics.frames_failed, u64(1))
}

@(test)
test_dynamic_frame_path_does_not_allocate :: proc(t: ^testing.T) {
	ctx: Context
	err := init(&ctx, _test_config())
	testing.expect_value(t, err, nil)
	if err != nil {
		return
	}

	frame_closed := false
	{
		context.allocator = mem.panic_allocator()
		if frame(&ctx, {640, 480}) {
			if element(&ctx, {}) {
			}
		}
		state := _context_state(&ctx)
		frame_closed = !state._frame_open && len(state._scopes) == 0
	}
	destroy(&ctx)
	testing.expect(t, frame_closed)
}

@(test)
test_each_declaration_pool_failure_is_atomic :: proc(t: ^testing.T) {
	{
		config := _test_config()
		config.capacities.nodes = 1
		ctx: Context
		defer destroy(&ctx)
		testing.expect_value(t, init(&ctx, config), nil)
		if frame(&ctx, {100, 100}) {
			if element(&ctx, {}) {
				testing.expect(t, false, "node-exhausted element unexpectedly entered")
			}
			testing.expect_value(t, len(_context_state(&ctx)._nodes), 1)
		}
		testing.expect_value(t, diagnostics(&ctx)[0].pool, Pool_Id.Nodes)
	}
	{
		config := _test_config()
		config.capacities.depth = 1
		ctx: Context
		defer destroy(&ctx)
		testing.expect_value(t, init(&ctx, config), nil)
		if frame(&ctx, {100, 100}) {
			if element(&ctx, {}) {
				testing.expect(t, false, "depth-exhausted element unexpectedly entered")
			}
			testing.expect_value(t, len(_context_state(&ctx)._nodes), 1)
		}
		testing.expect_value(t, diagnostics(&ctx)[0].pool, Pool_Id.Depth)
	}
	{
		config := _test_config()
		config.capacities.children = 0
		ctx: Context
		defer destroy(&ctx)
		testing.expect_value(t, init(&ctx, config), nil)
		if frame(&ctx, {100, 100}) {
			if element(&ctx, {}) {
				if element(&ctx, {}) {
					testing.expect(t, false, "child-link-exhausted element unexpectedly entered")
				}
				testing.expect_value(t, len(_context_state(&ctx)._nodes), 2)
			}
		}
		testing.expect_value(t, diagnostics(&ctx)[0].pool, Pool_Id.Children)
	}
	{
		config := _test_config()
		config.capacities.id_table = 0
		ctx: Context
		defer destroy(&ctx)
		testing.expect_value(t, init(&ctx, config), nil)
		if frame(&ctx, {100, 100}) {
			if element(&ctx, {id = 1}) {
				testing.expect(t, false, "id-table-exhausted element unexpectedly entered")
			}
			testing.expect_value(t, len(_context_state(&ctx)._nodes), 1)
			testing.expect_value(t, _context_state(&ctx)._id_table_count, 0)
		}
		testing.expect_value(t, diagnostics(&ctx)[0].pool, Pool_Id.Id_Table)
	}
}

@(test)
test_terminal_diagnostic_slot_and_caller_location :: proc(t: ^testing.T) {
	config := _test_config()
	config.capacities.nodes = 1
	config.capacities.diagnostics = 3
	ctx: Context
	err := init(&ctx, config)
	testing.expect_value(t, err, nil)
	defer destroy(&ctx)

	expected_loc := runtime.Source_Code_Location {
		file_path = "phase0-capacity-test",
		line      = 321,
		column    = 7,
		procedure = "test_terminal_diagnostic_slot_and_caller_location",
	}
	if frame(&ctx, {100, 100}) {
		state := _context_state(&ctx)
		for _ in 0 ..< cap(state._diagnostics) - 1 {
			testing.expect(t, _try_append_diagnostic(state, Diagnostic{kind = .Overflow}))
		}
		testing.expect(t, !_try_append_diagnostic(state, Diagnostic{kind = .Overflow}))
		if element(&ctx, {}, expected_loc) {
			testing.expect(t, false, "capacity-exhausted element unexpectedly entered")
		}
	}

	diagnostic_list := diagnostics(&ctx)
	testing.expect_value(t, len(diagnostic_list), 3)
	terminal := diagnostic_list[len(diagnostic_list) - 1]
	testing.expect_value(t, terminal.kind, Diagnostic_Kind.Pool_Exhausted)
	testing.expect_value(t, terminal.pool, Pool_Id.Nodes)
	testing.expect_value(t, terminal.loc.file_path, expected_loc.file_path)
	testing.expect_value(t, terminal.loc.line, expected_loc.line)
}

@(test)
test_storage_size_overflow_is_consistently_invalid :: proc(t: ^testing.T) {
	config := _test_config()
	config.capacities.debug_labels = 0
	base_payload, ok := _storage_payload_size(config.capacities)
	testing.expect(t, ok)
	testing.expect(t, storage_alignment() > 1)

	// The aligned payload fits in int, but adding worst-case leading slack does not.
	target_payload := max(int) - (storage_alignment() - 2)
	config.capacities.debug_labels = target_payload - base_payload
	payload, payload_ok := _storage_payload_size(config.capacities)
	testing.expect(t, payload_ok)
	testing.expect_value(t, payload, target_payload)
	testing.expect_value(t, storage_size(config.capacities), 0)

	dynamic_ctx: Context
	fixed_ctx: Context
	testing.expect_value(t, init(&dynamic_ctx, config), Context_Data_Error.Invalid_Options)
	testing.expect_value(t, init_from_buffer(&fixed_ctx, config, nil), Context_Data_Error.Invalid_Options)
	testing.expect(t, !_context_state(&dynamic_ctx)._initialized)
	testing.expect(t, !_context_state(&fixed_ctx)._initialized)
}

@(test)
test_overlay_capacity_at_int_limit_is_invalid :: proc(t: ^testing.T) {
	// The paint-root pools hold `overlays + 1` entries. `storage_size` is public
	// and runs no config validation, and the `u32` bound in `_config_is_valid`
	// cannot reject `max(int)` on a 32-bit target, so the add itself must fail
	// closed rather than wrap to `min(int)`.
	config := _test_config()
	config.capacities.overlays = max(int)

	_, payload_ok := _storage_payload_size(config.capacities)
	testing.expect(t, !payload_ok)
	testing.expect_value(t, storage_size(config.capacities), 0)

	dynamic_ctx: Context
	fixed_ctx: Context
	testing.expect_value(t, init(&dynamic_ctx, config), Context_Data_Error.Invalid_Options)
	testing.expect_value(t, init_from_buffer(&fixed_ctx, config, nil), Context_Data_Error.Invalid_Options)
	testing.expect(t, !_context_state(&dynamic_ctx)._initialized)
	testing.expect(t, !_context_state(&fixed_ctx)._initialized)
}

when ODIN_DEBUG {
	@(test)
	test_uninitialized_frame_asserts_in_debug :: proc(t: ^testing.T) {
		ctx: Context
		testing.expect_assert_message(t, "layout: frame called with an uninitialized context")
		if frame(&ctx, {100, 100}) {
		}
	}

	@(test)
	test_nested_frame_asserts_in_debug :: proc(t: ^testing.T) {
		ctx: Context
		testing.expect_value(t, init(&ctx, _test_config()), nil)
		testing.cleanup(t, _test_aborted_frame_destroy_cleanup, &ctx)
		testing.expect_assert_message(t, "layout: frame called while another frame is open")
		if frame(&ctx, {100, 100}) {
			if frame(&ctx, {100, 100}) {
			}
		}
	}
} else {
	@(test)
	test_frame_contract_errors_in_release :: proc(t: ^testing.T) {
		uninitialized: Context
		if frame(&uninitialized, {100, 100}) {
			testing.expect(t, false, "uninitialized frame unexpectedly entered")
		}
		testing.expect_value(t, _context_state(&uninitialized)._frame_error, Frame_Error.Not_Initialized)

		config := _test_config()
		config.capacities.overlays = 0
		ctx: Context
		testing.expect_value(t, init(&ctx, config), nil)
		defer destroy(&ctx)
		if frame(&ctx, {100, 100}) {
			if element(&ctx, {overlay = {attach = .Root}}) {
			}
			if frame(&ctx, {100, 100}) {
				testing.expect(t, false, "nested frame unexpectedly entered")
			}
			testing.expect_value(t, _context_state(&ctx)._frame_error, Frame_Error.Capacity_Exhausted)
			testing.expect_value(t, _context_state(&ctx)._failed_pool, Pool_Id.Overlays)
		}
	}
}

@(test)
test_reserve_grows_capacity_and_recovers_from_exhaustion :: proc(t: ^testing.T) {
	config := _test_config()
	config.capacities.nodes = 4
	ctx: Context
	testing.expect_value(t, init(&ctx, config), nil)
	defer destroy(&ctx)

	declare := proc(ctx: ^Context) {
		if frame(ctx, {100, 100}) {
			if element(ctx, {id = id("root"), layout = {sizing = {width = fixed(100), height = fixed(100)}}}) {
				for index in 0 ..< 8 {
					content(ctx, {id = id_index("child", u64(index)), layout = {sizing = {width = fixed(10), height = fixed(10)}}})
				}
			}
		}
	}

	declare(&ctx)
	_, exhausted := result(&ctx)
	testing.expect_value(t, exhausted, Frame_Error.Capacity_Exhausted)

	// Growth is the documented recovery from Capacity_Exhausted; without it the
	// only route back is destroy followed by init.
	grow_request := Capacities {
		nodes = 32,
	}
	testing.expect_value(t, reserve(&ctx, grow_request), nil)
	testing.expect_value(t, _context_state(&ctx)._options.capacities.nodes, 32)

	declare(&ctx)
	grown_result, grown_error := result(&ctx)
	testing.expect_value(t, grown_error, Frame_Error.None)
	testing.expect_value(t, len(grown_result.nodes), 10)
}

@(test)
test_reserve_never_lowers_capacity :: proc(t: ^testing.T) {
	config := _test_config()
	ctx: Context
	testing.expect_value(t, init(&ctx, config), nil)
	defer destroy(&ctx)

	before := _context_state(&ctx)._storage
	// Raising one pool must not shrink the others, and a request that asks for
	// nothing new must not reallocate.
	testing.expect_value(t, reserve(&ctx, Capacities{clips = 64}), nil)
	grown := _context_state(&ctx)._options.capacities
	testing.expect_value(t, grown.clips, 64)
	testing.expect_value(t, grown.nodes, config.capacities.nodes)
	testing.expect_value(t, grown.debug_labels, config.capacities.debug_labels)
	testing.expect(t, raw_data(_context_state(&ctx)._storage) != raw_data(before))

	unchanged := _context_state(&ctx)._storage
	testing.expect_value(t, reserve(&ctx, Capacities{clips = 8}), nil)
	testing.expect_value(t, _context_state(&ctx)._options.capacities.clips, 64)
	testing.expect(t, raw_data(_context_state(&ctx)._storage) == raw_data(unchanged))
}

@(test)
test_reserve_preserves_lifetime_state_and_drops_frame_results :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_config()), nil)
	defer destroy(&ctx)

	if frame(&ctx, {100, 100}) {
		content(&ctx, {id = id("root"), layout = {sizing = {width = fixed(50), height = fixed(50)}}})
	}
	published, err := result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, published.generation, u32(1))

	before := statistics(&ctx)
	testing.expect_value(t, reserve(&ctx, Capacities{nodes = 64}), nil)

	// Counters and high-water marks describe the whole lifetime of the context,
	// so they survive; the published result described the previous capacities,
	// so it does not.
	after := statistics(&ctx)
	testing.expect_value(t, after.frames_completed, before.frames_completed)
	testing.expect_value(t, after.declarations, before.declarations)
	testing.expect_value(t, after.pool_high_water[.Nodes], before.pool_high_water[.Nodes])

	dropped, dropped_error := result(&ctx)
	testing.expect_value(t, dropped_error, Frame_Error.No_Completed_Frame)
	testing.expect_value(t, len(dropped.nodes), 0)

	// Generation continues rather than restarting, so a consumer comparing
	// frames cannot mistake a post-reserve frame for an earlier one.
	if frame(&ctx, {100, 100}) {
		content(&ctx, {id = id("root"), layout = {sizing = {width = fixed(50), height = fixed(50)}}})
	}
	next, next_error := result(&ctx)
	testing.expect_value(t, next_error, Frame_Error.None)
	testing.expect_value(t, next.generation, u32(2))
}

@(test)
test_reserve_is_rejected_for_fixed_and_open_contexts :: proc(t: ^testing.T) {
	config := _test_config()
	storage := make([]byte, storage_size(config.capacities))
	defer delete(storage)
	fixed_ctx: Context
	testing.expect_value(t, init_from_buffer(&fixed_ctx, config, storage), nil)
	defer destroy(&fixed_ctx)

	// Fixed storage belongs to the caller, so the library must not replace it.
	testing.expect_value(t, reserve(&fixed_ctx, Capacities{nodes = 64}), Context_Data_Error.Invalid_Options)
	testing.expect_value(t, _context_state(&fixed_ctx)._options.capacities.nodes, config.capacities.nodes)
	testing.expect(t, raw_data(_context_state(&fixed_ctx)._storage) == raw_data(storage))

	uninitialized: Context
	testing.expect_value(t, reserve(&uninitialized, Capacities{nodes = 64}), Context_Data_Error.Invalid_Options)
	testing.expect_value(t, reserve(nil, Capacities{nodes = 64}), Context_Data_Error.Invalid_Options)

	dynamic_ctx: Context
	testing.expect_value(t, init(&dynamic_ctx, config), nil)
	defer destroy(&dynamic_ctx)
	if frame(&dynamic_ctx, {100, 100}) {
		// Reserve moves the storage every pool is carved from, so it cannot run
		// while a frame holds handles into it.
		testing.expect_value(t, reserve(&dynamic_ctx, Capacities{nodes = 64}), Context_Data_Error.Invalid_Options)
		testing.expect_value(t, _context_state(&dynamic_ctx)._options.capacities.nodes, config.capacities.nodes)
	}
}

@(test)
test_reserve_rejects_negative_requests_without_unioning_them :: proc(t: ^testing.T) {
	config := _test_config()
	ctx: Context
	testing.expect_value(t, init(&ctx, config), nil)
	defer destroy(&ctx)

	before_storage := _context_state(&ctx)._storage
	before_capacities := _context_state(&ctx)._options.capacities

	testing.expect_value(t, reserve(&ctx, Capacities{nodes = -1}), Context_Data_Error.Invalid_Options)
	testing.expect_value(t, _context_state(&ctx)._options.capacities, before_capacities)
	testing.expect(t, raw_data(_context_state(&ctx)._storage) == raw_data(before_storage))

	testing.expect_value(t, reserve(&ctx, Capacities{nodes = -1, clips = 64}), Context_Data_Error.Invalid_Options)
	testing.expect_value(t, _context_state(&ctx)._options.capacities, before_capacities)
	testing.expect(t, raw_data(_context_state(&ctx)._storage) == raw_data(before_storage))

	invalidate_metrics(&ctx, 7)
	testing.expect_value(t, reserve(&ctx, Capacities{nodes = 64}), nil)
	testing.expect_value(t, _context_state(&ctx)._metrics_generation, u32(7))

	if frame(&ctx, {100, 100}) {
		content(&ctx, {id = id("root"), layout = {sizing = {width = fixed(50), height = fixed(50)}}})
	}
	_, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
}

@(test)
test_high_bit_handles_are_rejected_without_signed_wrap :: proc(t: ^testing.T) {
	nodes := make([]Resolved_Node, 2)
	clips := make([]Resolved_Clip, 1)
	defer delete(nodes)
	defer delete(clips)
	frame_result := Frame_Result {
		nodes = nodes,
		clips = clips,
	}

	node_index, node_index_valid := _node_index(frame_result, Node_Handle(max(u32)))
	testing.expect(t, !node_index_valid)
	testing.expect_value(t, node_index, 0)
	_, node_valid := node(frame_result, Node_Handle(max(u32)))
	testing.expect(t, !node_valid)

	frame_result.id_index = []Id_Index_Entry{{id = 1, node = Node_Handle(max(u32))}}
	_, lookup_valid := lookup(frame_result, Id(1))
	testing.expect(t, !lookup_valid)

	frame_result.hit_order = []Node_Handle{Node_Handle(max(u32))}
	_, hit_valid := hit_test(frame_result, {})
	testing.expect(t, !hit_valid)

	hits, hit_stack_complete := hit_stack(frame_result, {}, nil)
	testing.expect_value(t, len(hits), 0)
	testing.expect(t, hit_stack_complete)

	_, child_handle, child_ok := next_child(&Child_Iterator{_result = frame_result, _next = Node_Handle(max(u32))})
	testing.expect_value(t, child_handle, Node_Handle(0))
	testing.expect(t, !child_ok)

	path, path_complete, path_found := ancestor_path(frame_result, Node_Handle(max(u32)), nil)
	testing.expect_value(t, len(path), 0)
	testing.expect(t, path_complete)
	testing.expect(t, !path_found)

	viewport := clip_of(frame_result, Clip_Handle(max(u32)))
	testing.expect_value(t, viewport, clips[0])
	clip_index, clip_index_valid := _clip_index(frame_result, Clip_Handle(max(u32)))
	testing.expect(t, !clip_index_valid)
	testing.expect_value(t, clip_index, 0)
}

@(test)
test_reserve_failure_leaves_the_context_usable :: proc(t: ^testing.T) {
	config := _test_config()
	ctx: Context
	testing.expect_value(t, init(&ctx, config), nil)
	defer destroy(&ctx)

	before_storage := _context_state(&ctx)._storage
	// depth is bounded at 4096 by _config_is_valid, so this request is rejected
	// after the union is computed but before anything is allocated.
	testing.expect_value(t, reserve(&ctx, Capacities{depth = 8192}), Context_Data_Error.Invalid_Options)
	testing.expect_value(t, _context_state(&ctx)._options.capacities.depth, config.capacities.depth)
	testing.expect(t, raw_data(_context_state(&ctx)._storage) == raw_data(before_storage))

	// A failed reserve must leave a context that still solves frames.
	if frame(&ctx, {100, 100}) {
		content(&ctx, {id = id("root"), layout = {sizing = {width = fixed(50), height = fixed(50)}}})
	}
	survived, survived_error := result(&ctx)
	testing.expect_value(t, survived_error, Frame_Error.None)
	testing.expect_value(t, len(survived.nodes), 2)
}
