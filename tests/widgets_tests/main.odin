package main

// External harness for the widgets package's test suite, which is written
// against a package-local assertion harness rather than core:testing's
// `@(test)` declarations. scripts/test runs this harness with `odin run`
// instead of `odin test`. The helpers below mirror the core:testing call
// shapes the suite was written against.

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
		test_snapshot_is_known_and_complete,
		test_selection_is_the_only_styled_run,
		test_two_identical_renders_produce_identical_output,
		test_reused_storage_matches_fresh_storage,
		test_key_event_moves_the_selection_and_render_follows,
		test_selection_is_clamped_at_the_ends,
		test_resize_recomputes_geometry_without_stale_cache,
		test_content_wider_than_its_parent_overflows_and_is_clipped,
		test_insufficient_presentation_capacity_fails_the_frame,
		test_presenting_to_a_closed_session_reports_and_draws_nothing,
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
		fmt.eprintf("widgets: %d test(s) failed\n", failures)
		os.exit(1)
	}
}
