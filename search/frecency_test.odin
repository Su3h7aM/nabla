#+test
package search

import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

FRECENCY_TEST_NOW :: 1_800_000_000
FRECENCY_TEST_DAY :: 24 * 60 * 60

// frecency_test_record records path and fails the test when the call errors.
frecency_test_record :: proc(test: ^testing.T, frecency: ^Frecency, path: string, at: i64) {
	err := frecency_record(frecency, path, at)
	testing.expect_value(test, err, nil)
}

// More recent and more frequent accesses rank higher, an access past the
// window scores 0, and heavy use has diminishing returns.
@(test)
test_frecency_scores_recency_window_and_diminishing_returns :: proc(test: ^testing.T) {
	now: i64 = FRECENCY_TEST_NOW
	frecency: Frecency
	open_error := frecency_open(&frecency, "", now)
	defer frecency_destroy(&frecency)
	testing.expect_value(test, open_error, nil)

	frecency_test_record(test, &frecency, "/day", now - 3 * FRECENCY_TEST_DAY)
	frecency_test_record(test, &frecency, "/hour", now - 60 * 60)
	frecency_test_record(test, &frecency, "/now", now)
	frecency_test_record(test, &frecency, "/old", now - 8 * FRECENCY_TEST_DAY)
	day := frecency_access_score(&frecency, "/day", now)
	hour := frecency_access_score(&frecency, "/hour", now)
	current := frecency_access_score(&frecency, "/now", now)
	testing.expect(test, math.abs(day - 0.5) < 1e-9, "one access is worth half after one half-life")
	testing.expect(test, day < hour && hour < current, "newer accesses rank higher")
	testing.expect_value(test, frecency_access_score(&frecency, "/old", now), 0)
	testing.expect_value(test, frecency_access_score(&frecency, "/unknown", now), 0)

	for _ in 0 ..< 10 {
		frecency_test_record(test, &frecency, "/ten", now)
	}
	testing.expect_value(test, frecency_access_score(&frecency, "/ten", now), 10)
	for _ in 0 ..< 30 {
		frecency_test_record(test, &frecency, "/thirty", now)
	}
	thirty := frecency_access_score(&frecency, "/thirty", now)
	testing.expect(test, math.abs(thirty - (10 + math.sqrt(f64(20)))) < 1e-9, "the sum above the knee grows with its square root")
}

// Reopening replays the log into the same decayed scores, drops entries past
// the window, ignores garbage lines, and leaves a compacted log.
@(test)
test_frecency_persists_and_compacts :: proc(test: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "search-frecency-*", context.allocator)
	if !testing.expect_value(test, directory_error, nil) {
		return
	}
	defer delete(directory)
	defer os.remove_all(directory)
	log_path := strings.concatenate({directory, "/frecency.log"})
	defer delete(log_path)

	start: i64 = FRECENCY_TEST_NOW
	later := start + 2 * FRECENCY_TEST_DAY
	frecency: Frecency
	open_error := frecency_open(&frecency, log_path, start)
	testing.expect_value(test, open_error, nil)
	frecency_test_record(test, &frecency, "/a", start)
	frecency_test_record(test, &frecency, "/a", start + 10)
	frecency_test_record(test, &frecency, "/a", start + 20)
	frecency_test_record(test, &frecency, "/b c", start - FRECENCY_TEST_DAY)
	frecency_test_record(test, &frecency, "/stale", start - 6 * FRECENCY_TEST_DAY)
	frecency_test_record(test, &frecency, "/new\nline", start)
	want_a := frecency_access_score(&frecency, "/a", later)
	want_b := frecency_access_score(&frecency, "/b c", later)
	testing.expect(test, want_a > want_b && want_b > 0, "the fixture scores differ")
	frecency_destroy(&frecency)

	garbage, garbage_error := os.open(log_path, {.Write, .Append})
	if !testing.expect_value(test, garbage_error, nil) {
		return
	}
	_, write_error := os.write_string(garbage, "garbage\nx y z\n-5 1 /negative\n12 nan /nan\n")
	testing.expect_value(test, write_error, nil)
	testing.expect_value(test, os.close(garbage), nil)

	reopen_error := frecency_open(&frecency, log_path, later)
	defer frecency_destroy(&frecency)
	testing.expect_value(test, reopen_error, nil)
	testing.expect(test, math.abs(frecency_access_score(&frecency, "/a", later) - want_a) < 1e-9, "a replayed score equals the in-memory score")
	testing.expect(test, math.abs(frecency_access_score(&frecency, "/b c", later) - want_b) < 1e-9, "a path with a space survives the replay")
	testing.expect_value(test, frecency_access_score(&frecency, "/stale", later), 0)
	testing.expect_value(test, frecency_access_score(&frecency, "/new", later), 0)
	testing.expect_value(test, len(frecency.accesses), 2)

	frecency_test_record(test, &frecency, "/c", later)
	data, read_error := os.read_entire_file(log_path, context.allocator)
	testing.expect_value(test, read_error, nil)
	defer delete(data)
	lines := strings.split_lines(strings.trim_suffix(string(data), "\n"), context.temp_allocator)
	testing.expect_value(test, len(lines), 3)
	for line in lines {
		fields := strings.split_n(line, " ", 3, context.temp_allocator)
		testing.expect_value(test, len(fields), 3)
		testing.expect(test, !strings.contains(line, "garbage"), "garbage lines do not survive compaction")
	}
	testing.expect_value(test, strings.has_suffix(lines[2], " 1 /c"), true)
}

// The modification score is flat before 30 seconds, linear between the
// breakpoints, and 0 after four hours.
@(test)
test_modification_score_breakpoints :: proc(test: ^testing.T) {
	now: i64 = FRECENCY_TEST_NOW
	score :: proc(age, now: i64) -> f64 {
		return modification_score(time.unix(now - age, 0), now)
	}
	testing.expect_value(test, score(0, now), 16)
	testing.expect_value(test, score(30, now), 16)
	testing.expect_value(test, score(165, now), 12)
	testing.expect_value(test, score(5 * 60, now), 8)
	testing.expect_value(test, score(10 * 60, now), 6)
	testing.expect_value(test, score(15 * 60, now), 4)
	testing.expect_value(test, score(60 * 60, now), 2)
	testing.expect_value(test, score(4 * 60 * 60, now), 1)
	testing.expect_value(test, score(4 * 60 * 60 + 1, now), 0)
	testing.expect_value(test, score(-100, now), 16)
}
