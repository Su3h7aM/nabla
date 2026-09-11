#+test
#+private file
package layout

import "core:testing"

_run_early_return :: proc(ctx: ^Context) {
	if frame(ctx, {320, 200}) {
		if element(ctx, {}) {
			return
		}
	}
}

_run_break :: proc(ctx: ^Context) {
	if frame(ctx, {320, 200}) {
		for _ in 0 ..< 3 {
			if element(ctx, {}) {
				break
			}
		}
	}
}

_run_continue :: proc(ctx: ^Context) {
	if frame(ctx, {320, 200}) {
		for _ in 0 ..< 3 {
			if element(ctx, {}) {
				continue
			}
		}
	}
}

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
test_scopes_balance_and_failures_are_atomic :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)
	state := _context_state(&ctx)

	if frame(&ctx, {320, 200}) {
		if element(&ctx, {}) {
			if element(&ctx, {}) {
			}
		}
	}
	// Leaving the block through any control-flow edge closes every scope.
	_run_early_return(&ctx)
	_run_break(&ctx)
	_run_continue(&ctx)
	_run_labelled_continue(&ctx)
	testing.expect(t, !state._frame_open && len(state._scopes) == 0)
	testing.expect_value(t, state._statistics.frames_failed, u64(0))

	// A pool that runs out mid-declaration fails the frame, publishes nothing,
	// and leaves the context balanced.
	config := _test_options()
	config.capacities.nodes = 1
	failed_ctx: Context
	testing.expect_value(t, init(&failed_ctx, config), nil)
	defer destroy(&failed_ctx)

	entered := false
	if frame(&failed_ctx, {100, 100}) {
		if element(&failed_ctx, {}) {
			entered = true
		}
		testing.expect_value(t, len(_context_state(&failed_ctx)._nodes), 1)
	}
	testing.expect(t, !entered)
	testing.expect(t, !_context_state(&failed_ctx)._frame_open)
	failed_result, failed_error := result(&failed_ctx)
	testing.expect_value(t, failed_error, Frame_Error.Capacity_Exhausted)
	testing.expect_value(t, len(failed_result.nodes), 0)
	testing.expect_value(t, diagnostics(&failed_ctx)[0].pool, Pool_Id.Nodes)
}
