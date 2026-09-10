#+build linux
package term

import "base:intrinsics"
import "core:fmt"

// Test-only assertion helpers and the single public test entry for the
// in-package suites (present_tests.odin, operations_tests.odin,
// bench_tests.odin).
//
// The suites use these helpers rather than core:testing's `@(test)`
// declarations, so scripts/test runs the external harness
// `odin run ./tests/tty_tests`, which calls run_tests. The helpers mirror the
// core:testing call shapes so the suite bodies stay readable.

// T is the per-test context: a running failure count.
T :: struct {
	failures: int,
}

// expect records a failure when ok is false.
expect :: proc(t: ^T, ok: bool, msg := "", loc := #caller_location) -> bool {
	if !ok {
		fmt.eprintf("%s:%d: %s\n", loc.file_path, loc.line, msg)
		t.failures += 1
	}
	return ok
}

// expect_value records a failure when value != expected.
expect_value :: proc(t: ^T, value, expected: $T, loc := #caller_location) -> bool where intrinsics.type_is_comparable(T) {
	if value != expected {
		fmt.eprintf("%s:%d: expected %v, got %v\n", loc.file_path, loc.line, expected, value)
		t.failures += 1
		return false
	}
	return true
}

// expectf records a failure with a formatted message when ok is false.
expectf :: proc(t: ^T, ok: bool, format: string, args: ..any, loc := #caller_location) -> bool {
	if !ok {
		fmt.eprintf("%s:%d: %s\n", loc.file_path, loc.line, fmt.tprintf(format, ..args))
		t.failures += 1
		return false
	}
	return true
}

// run_tests runs the in-package suites and reports whether every test
// passed. The full-frame encode benchmark joins the run only under
// -define:BENCH=true, mirroring the old odin test gating.
run_tests :: proc() -> bool {
	tests := make([dynamic]proc(_: ^T), 0, 32)
	defer delete(tests)
	append(
		&tests,
		test_present_requires_an_open_session,
		test_encode_matches_the_reference_bytes,
		test_encode_emits_the_cursor_intent,
		test_encoded_bytes_use_real_escape_characters,
		test_control_sequences_start_with_esc,
		test_color_reduction_helpers,
		test_encode_reduces_colors_by_depth,
		test_encode_emits_style_once_per_run,
		test_encode_ignores_unused_trailing_cells,
		test_encode_reduces_indexed_colors_by_depth,
		test_encode_rejects_cells_wider_than_one_column,
		test_encode_rejects_unsafe_graphemes,
		test_encode_rejects_out_of_bounds_cursor,
		test_encode_rejects_invalid_frame_data,
		test_encode_zero_size_is_a_noop,
		test_encode_reports_exact_required_when_scratch_is_too_small,
		test_modifiers_empty_set_is_the_neutral_value,
		test_session_write_bytes_preserves_the_cause_after_a_committed_prefix,
		test_session_write_bytes_recovers_from_backpressure,
		test_profile_default_follows_the_package_color_state,
		test_operations_encode_reference_bytes,
		test_operations_suppress_redundant_moves,
		test_operations_empty_grapheme_does_not_advance_cursor,
		test_operations_max_int_domain_does_not_overflow,
		test_operations_style_baseline_and_restore,
		test_operations_validate_moves_and_erases,
		test_operations_validate_widths_and_graphemes,
		test_operations_reports_exact_required_when_scratch_is_too_small,
		test_operations_present_requires_an_open_session,
		test_operations_reduce_colors_by_depth,
	)
	when #config(BENCH, false) {
		append(&tests, bench_full_frame_encode)
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
		fmt.eprintf("terminal: %d test(s) failed\n", failures)
		return false
	}
	return true
}
