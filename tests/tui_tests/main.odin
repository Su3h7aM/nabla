package main

// External harness for the tui package's test suite, which is written
// against a package-local assertion harness rather than core:testing's
// `@(test)` declarations. scripts/test runs this harness with `odin run`
// instead of `odin test`. The helpers mirror the core:testing call shapes the
// suite was written against.

import "base:intrinsics"
import "core:fmt"
import "core:os"

// T is the per-test context: a running failure count.
T :: struct {
	failures: int,
}

expect :: proc(t: ^T, ok: bool, msg := "", loc := #caller_location) -> bool {
	if !ok {
		fmt.eprintf("%s:%d: %s\n", loc.file_path, loc.line, msg)
		t.failures += 1
	}
	return ok
}

expect_value :: proc(t: ^T, value, expected: $T, loc := #caller_location) -> bool where intrinsics.type_is_comparable(T) {
	if value != expected {
		fmt.eprintf("%s:%d: expected %v, got %v\n", loc.file_path, loc.line, expected, value)
		t.failures += 1
		return false
	}
	return true
}

expectf :: proc(t: ^T, ok: bool, format: string, args: ..any, loc := #caller_location) -> bool {
	if !ok {
		fmt.eprintf("%s:%d: %s\n", loc.file_path, loc.line, fmt.tprintf(format, ..args))
		t.failures += 1
		return false
	}
	return true
}

main :: proc() {
	tests := []proc(_: ^T) {
		test_init_fills_with_blanks,
		test_init_rejects_insufficient_storage,
		test_init_rejects_negative_extent,
		test_init_rejects_hostile_dimensions_without_mutation,
		test_init_accepts_zero_sized_grids,
		test_put_is_bounds_checked,
		test_integral_projection_is_exact,
		test_fractional_geometry_is_rejected_not_rounded,
		test_negative_size_is_rejected,
		test_fill_writes_only_inside_the_rect,
		test_fill_clips_to_the_buffer,
		test_draw_ascii_writes_at_the_rect_origin,
		test_draw_ascii_truncates_to_the_rect,
		test_draw_ascii_clips_at_the_left_edge_without_shifting_text,
		test_draw_ascii_outside_the_buffer_writes_nothing,
		test_draw_ascii_rejects_unrepresentable_text_without_writing,
		test_ascii_measurer_reports_cells_to_layout,
		test_ascii_measurer_clamps_to_available_width,
		test_ascii_measurer_treats_negative_width_as_unbounded,
		test_ascii_measurer_without_context_is_unavailable,
		test_ascii_measurer_surfaces_rejected_text,
		test_style_maps_to_the_terminal_vocabulary,
		test_every_modifier_maps_to_a_distinct_counterpart,
		test_unset_and_default_colors_are_distinguished,
		test_build_frame_is_a_full_redraw,
		test_build_frame_refuses_undersized_storage,
		test_build_frame_rejects_malformed_buffers_without_writing,
		test_ascii_break_proc_reproduces_fixture_wrapping_geometry,
		test_plan_presentation_nil_previous_forces_full_redraw,
		test_plan_presentation_identical_frames_plan_nothing,
		test_plan_presentation_changed_cell_plans_a_write,
		test_plan_presentation_blank_change_plans_an_erase,
		test_plan_presentation_resize_forces_full_redraw,
		test_plan_presentation_reports_exact_required,
		test_plan_presentation_rejects_invalid_buffers,
		test_plan_presentation_reserves_the_corner,
		test_plan_presentation_coalesces_style_runs,
		test_plan_presentation_erase_carries_the_cell_style,
	}
	failures := 0
	for test in tests {
		t := T{}
		test(&t)
		if t.failures > 0 {
			failures += 1
		}
	}
	if failures > 0 {
		fmt.eprintf("tui: %d test(s) failed\n", failures)
		os.exit(1)
	}
}
