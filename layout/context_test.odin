#+test
// The context suite owns the shared default capacities: a focused test starts
// from `_test_options` and lowers the pool it means to starve.
package layout

import "base:runtime"
import "core:mem"
import "core:testing"

_test_options :: proc() -> Options {
	return Options {
		capacities = {
			nodes = 32,
			children = 32,
			clips = 8,
			commands = 64,
			text_lines = 32,
			measured_words = 256,
			overlays = 8,
			measure_cache = 32,
			id_table = 32,
			depth = 16,
			diagnostics = 16,
			debug_labels = 128,
		},
	}
}

// Every pool is a slice carved out of one byte block, so each must be aligned
// for its element type.
_pools_aligned :: proc(ctx: ^Context) -> bool {
	state := _context_state(ctx)
	return(
		uintptr(raw_data(state._node_inputs)) % uintptr(align_of(_Node_Input)) == 0 &&
		uintptr(raw_data(state._nodes)) % uintptr(align_of(Resolved_Node)) == 0 &&
		uintptr(raw_data(state._commands)) % uintptr(align_of(Render_Command)) == 0 &&
		uintptr(raw_data(state._measure_cache)) % uintptr(align_of(_Measure_Cache_Entry)) == 0 &&
		uintptr(raw_data(state._id_table)) % uintptr(align_of(_Id_Table_Entry)) == 0 &&
		uintptr(raw_data(state._diagnostics)) % uintptr(align_of(Diagnostic)) == 0 \
	)
}

@(test)
test_initialization_is_transactional_and_aligned :: proc(t: ^testing.T) {
	ctx: Context
	state := _context_state(&ctx)
	config := _test_options()

	testing.expect_value(t, init(&ctx, config), nil)
	testing.expect(t, state._initialized && state._owns_storage)
	testing.expect_value(t, len(state._storage), storage_size(config.capacities))
	destroy(&ctx)
	testing.expect(t, !state._initialized)

	// Every failure mode leaves the context zeroed and unchanged.
	invalid := _test_options()
	invalid.capacities.diagnostics = 0
	testing.expect_value(t, init(&ctx, invalid), Context_Data_Error.Invalid_Options)

	fixed := _test_options()
	size := storage_size(fixed.capacities)
	too_small := make([]byte, size - 1)
	defer delete(too_small)
	testing.expect_value(t, init_from_buffer(&ctx, fixed, too_small), Context_Data_Error.Storage_Too_Small)
	testing.expect_value(t, init(&ctx, fixed, mem.nil_allocator()), runtime.Allocator_Error.Out_Of_Memory)
	testing.expect(t, !state._initialized)

	// A caller-owned block may start at any byte address: the partition aligns
	// itself by consuming leading slack.
	alignment := storage_alignment()
	backing := make([]byte, size + alignment)
	defer delete(backing)
	for offset in 0 ..< alignment {
		fixed_ctx: Context
		testing.expect_value(t, init_from_buffer(&fixed_ctx, fixed, backing[offset:offset + size]), nil)
		testing.expect(t, _pools_aligned(&fixed_ctx))
		destroy(&fixed_ctx)
	}
}

@(test)
test_reserve_grows_and_preserves_state :: proc(t: ^testing.T) {
	config := _test_options()
	config.capacities.nodes = 4
	ctx: Context
	testing.expect_value(t, init(&ctx, config), nil)
	defer destroy(&ctx)

	declare :: proc(ctx: ^Context, count: int) {
		if frame(ctx, {100, 100}) {
			if element(ctx, {id = id("root"), layout = {sizing = {width = fixed(100), height = fixed(100)}}}) {
				for index in 0 ..< count {
					content(ctx, {layout = {sizing = {width = fixed(10), height = fixed(10)}}})
				}
			}
		}
	}

	// Growth is the documented recovery from exhaustion.
	declare(&ctx, 8)
	_, exhausted := result(&ctx)
	testing.expect_value(t, exhausted, Frame_Error.Capacity_Exhausted)

	testing.expect_value(t, reserve(&ctx, Capacities{nodes = 32}), nil)
	declare(&ctx, 8)
	grown, grown_error := result(&ctx)
	testing.expect_value(t, grown_error, Frame_Error.None)
	testing.expect_value(t, len(grown.nodes), 10)

	// A request never lowers a capacity, and a rejected request leaves the
	// context usable.
	before := statistics(&ctx)
	testing.expect_value(t, reserve(&ctx, Capacities{nodes = 8}), nil)
	testing.expect_value(t, _context_state(&ctx)._options.capacities.nodes, 32)
	testing.expect_value(t, statistics(&ctx).frames_completed, before.frames_completed)
	testing.expect_value(t, reserve(&ctx, Capacities{nodes = -1}), Context_Data_Error.Invalid_Options)

	// A fixed block belongs to the caller and can never be replaced.
	storage := make([]byte, storage_size(_test_options().capacities))
	defer delete(storage)
	fixed_ctx: Context
	testing.expect_value(t, init_from_buffer(&fixed_ctx, _test_options(), storage), nil)
	defer destroy(&fixed_ctx)
	testing.expect_value(t, reserve(&fixed_ctx, Capacities{nodes = 64}), Context_Data_Error.Invalid_Options)
	testing.expect_value(t, reserve(nil, Capacities{nodes = 64}), Context_Data_Error.Invalid_Options)
}
