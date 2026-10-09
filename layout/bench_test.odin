#+test
#+private file
// C6b baseline benchmark harness.
//
// Gated behind `-define:BENCH=true`; with BENCH unset the file compiles to an
// empty translation unit, so the regular matrix (scripts/check, scripts/test)
// is unaffected and the layout test counts do not change.
//
// Run (from the repo root, release semantics):
//
//	odin test ./layout -collection:nabla=$PWD -define:BENCH=true -o:speed -thread-count:1
//
// What it measures: whole-frame cost (declaration + solve + publish) for four
// workloads, each scaled over several sizes:
//
//  1. ordinary  — a representative tree: root column, fixed header/footer, a
//     body row with a fixed-width sidebar and a grow main column of rows.
//     Exercises fixed/grow distribution in the common, non-saturating shape.
//  2. grow-linear — a single row of `node_count` Grow children whose max is effectively
//     unbounded: `_grow_children` completes in one pass. Linear control.
//  3. grow-saturating — the same row, but each child's max comes from the
//     constant-gap recurrence, which forces `_grow_children` into repeated
//     saturation passes.
//  4. grow-adversarial — the same row with the cap arrangement from Orpheus's
//     C6b review: the first cap is 3.5, then each remaining cap is the current
//     equal-share proposal minus 1e-5, with the proposal recomputed after each
//     cap. This is the family the review asked to be measured.
//
// For workloads 3 and 4 the harness also prints `sim_passes` — the number of
// saturation passes a faithful simulation of `_grow_children` (equal weights,
// same maxes) predicts; it was cross-checked against the real loop in a
// temporary instrumented copy.
//
// Results are logged as a table by the `bench_c6b_baseline` test.

package layout

import "core:log"
import "core:math"
import "core:testing"
import "core:time"

// Anchor: keeps the imports referenced when the benchmark block below is
// compiled out (BENCH unset) so the unused-import check stays green.
_ :: log
_ :: math
_ :: testing
_ :: time

when #config(BENCH, false) {

	Bench_Point :: struct {
		label:      string,
		node_count: int,
		frames:     int,
		sim_passes: int, // simulation-predicted _grow_children passes (saturating/adversarial only)
		mean_us:    f64, // mean per-frame microseconds across repeats
		min_us:     f64, // best per-frame repeat mean
		max_us:     f64, // worst per-frame repeat mean
		stddev_us:  f64, // stddev of the per-frame repeat means
	}

	// Bench run parameters — set by the driver before each measurement. Package
	// procs (no closures in Odin) read these.
	@(private)
	_bench_nodes: int
	@(private)
	_bench_height: Scalar
	@(private)
	_bench_rows: int
	@(private)
	_bench_maxes: []Scalar
	@(private)
	_bench_sim_passes: int

	@(private)
	_bench_config :: proc(node_count: int) -> Options {
		return Options {
			capacities = {
				nodes = node_count + 8,
				children = node_count + 8,
				clips = 16,
				commands = node_count + 8,
				text_lines = 16,
				measured_words = 64,
				overlays = 8,
				measure_cache = 16,
				id_table = node_count + 8,
				depth = 64,
				diagnostics = node_count + 8,
				debug_labels = 256,
			},
		}
	}

	// Faithful simulation of `_grow_children` (equal weights, current = 0), used
	// to report the saturation pass count each max arrangement produces. Matches
	// the real loop's behaviour: an instrumented scratch copy of solve.odin
	// reported the same pass counts at every measured size.
	@(private)
	_sim_grow_passes :: proc(free_space: f64, maxes: []Scalar) -> int {
		node_count := len(maxes)
		current := make([]f64, node_count)
		defer delete(current)
		remaining := free_space
		passes := 0
		for remaining > 0 {
			passes += 1
			total_weight := 0.0
			candidate_count := 0
			for i in 0 ..< node_count {
				if current[i] < f64(maxes[i]) {
					total_weight += 1
					candidate_count += 1
				}
			}
			if candidate_count == 0 || total_weight == 0 {
				return passes
			}
			iteration_remaining := remaining
			saturated := 0
			for i in 0 ..< node_count {
				if current[i] >= f64(maxes[i]) {
					continue
				}
				proposed := current[i] + iteration_remaining / total_weight
				if proposed > f64(maxes[i]) {
					remaining -= f64(maxes[i]) - current[i]
					current[i] = f64(maxes[i])
					saturated += 1
				}
			}
			if saturated == 0 {
				return passes
			}
		}
		return passes
	}

	// Times `frames` consecutive frames of `build` in a fresh context, repeated
	// `repeats` times, and aggregates per-frame microseconds.
	@(private)
	_measure :: proc(t: ^testing.T, label: string, node_count: int, viewport: Vec2, frames: int, repeats: int, build: proc(ctx: ^Context)) -> Bench_Point {
		ctx: Context
		init_err := init(&ctx, _bench_config(node_count))
		defer destroy(&ctx)
		assert(init_err == nil, "bench: init failed")

		// Warmup: reach steady pool sizes and verify the tree solves cleanly.
		for _ in 0 ..< 24 {
			if frame(&ctx, viewport) {
				build(&ctx)
			}
		}
		_, frame_error := result(&ctx)
		if frame_error != .None {
			testing.expectf(t, false, "%s (node_count=%d): frame error %v", label, node_count, frame_error)
		}

		run_means := make([]f64, repeats)
		defer delete(run_means)
		for repeat in 0 ..< repeats {
			start := time.tick_now()
			for _ in 0 ..< frames {
				if frame(&ctx, viewport) {
					build(&ctx)
				}
			}
			elapsed_us := time.duration_microseconds(time.tick_diff(start, time.tick_now()))
			run_means[repeat] = elapsed_us / f64(frames)
		}

		total := 0.0
		min_us := run_means[0]
		max_us := run_means[0]
		for sample in run_means {
			total += sample
			min_us = math.min(min_us, sample)
			max_us = math.max(max_us, sample)
		}
		mean := total / f64(repeats)
		variance := 0.0
		for sample in run_means {
			variance += (sample - mean) * (sample - mean)
		}
		return Bench_Point {
			label = label,
			node_count = node_count,
			frames = frames,
			sim_passes = _bench_sim_passes,
			mean_us = mean,
			min_us = min_us,
			max_us = max_us,
			stddev_us = math.sqrt(variance / f64(repeats)),
		}
	}

	// Ordinary workload: a root column with a fixed header, a body row
	// (fixed-width sidebar column + grow main column of `rows` rows), and a fixed
	// footer. The viewport height scales with `rows` so the tree fits without
	// triggering the shrink path.
	@(private)
	_build_ordinary :: proc(ctx: ^Context) {
		rows := _bench_rows
		if element(ctx, {layout = {sizing = {width = grow(), height = grow()}, padding = pad_all(8), gap = 4}}) {
			if element(ctx, {layout = {sizing = {width = grow(), height = fixed(24)}}}) {
				content(ctx, {})
			}
			if element(ctx, {layout = {flow = .Row, sizing = {width = grow(), height = grow()}, gap = 4}}) {
				if element(ctx, {layout = {sizing = {width = fixed(180), height = grow()}}}) {
					for _ in 0 ..< 24 {
						content(ctx, {layout = {sizing = {width = grow(), height = fixed(16)}, padding = pad_all(2)}})
					}
				}
				if element(ctx, {layout = {sizing = {width = grow(), height = grow()}}}) {
					for _ in 0 ..< rows {
						content(ctx, {layout = {sizing = {width = grow(), height = fixed(28)}, padding = pad_all(4)}})
					}
				}
			}
			if element(ctx, {layout = {sizing = {width = grow(), height = fixed(20)}}}) {
				content(ctx, {})
			}
		}
	}

	// Grow workloads: a single row of `node_count` Grow children. When `_bench_maxes` is
	// set, each child's max comes from the chosen generator; otherwise max is
	// effectively unbounded and the distribution completes in a single pass.
	@(private)
	_build_grow_row :: proc(ctx: ^Context) {
		node_count := _bench_nodes
		row_width := Scalar(4 * node_count)
		if element(ctx, {layout = {flow = .Row, sizing = {width = fixed(row_width), height = fixed(_bench_height)}}}) {
			for i in 0 ..< node_count {
				maximum: Scalar = 1e6
				if _bench_maxes != nil {
					maximum = _bench_maxes[i]
				}
				content(ctx, {layout = {sizing = {width = grow(1, 0, maximum), height = fixed(_bench_height)}}})
			}
		}
	}

	// Constant-gap max recurrence: the equal-weight max arrangement that keeps the
	// gap at 1/(2n) below the running per-pass proposal.
	@(private)
	_saturating_maxes :: proc(node_count: int) -> []Scalar {
		total_width := f64(4 * node_count)
		proposal := total_width / f64(node_count)
		remaining := total_width
		candidates := f64(node_count)
		gap := 1.0 / (2.0 * f64(node_count))
		maxes := make([]Scalar, node_count)
		for index in 0 ..< node_count {
			maxes[index] = Scalar(math.max(proposal - gap, 0.5))
			remaining -= proposal - gap
			candidates -= 1
			if candidates > 0 {
				proposal = remaining / candidates
			}
		}
		return maxes
	}

	// Adversarial max arrangement from the C6b review: the first cap is 3.5, then
	// each remaining cap is the current equal-share proposal minus 1e-5, with the
	// proposal recomputed after each cap.
	@(private)
	_adversarial_maxes :: proc(node_count: int) -> []Scalar {
		total_width := f64(4 * node_count)
		maxes := make([]Scalar, node_count)
		maxes[0] = 3.5
		accumulated := 3.5
		for index in 1 ..< node_count {
			proposal := (total_width - accumulated) / f64(node_count - index)
			maxes[index] = Scalar(proposal - 1e-5)
			accumulated += f64(maxes[index])
		}
		return maxes
	}

	@(private)
	_print_header :: proc() {
		log.info("workload\tn\tframes\tsim_passes\tmean_us/frame\tmin_us\tmax_us\tstddev_us")
	}

	@(private)
	_print_point :: proc(point: Bench_Point) {
		log.infof(
			"%s\t%d\t%d\t%d\t%.2f\t%.2f\t%.2f\t%.2f",
			point.label,
			point.node_count,
			point.frames,
			point.sim_passes,
			point.mean_us,
			point.min_us,
			point.max_us,
			point.stddev_us,
		)
	}

	@(private)
	_bench_ordinary :: proc(t: ^testing.T) {
		log.info("\n== ordinary (representative tree) ==")
		_print_header()
		rows := []int{128, 256, 512, 1024, 2048}
		frames := []int{5000, 3000, 1500, 800, 400}
		for i in 0 ..< len(rows) {
			_bench_rows = rows[i]
			_bench_sim_passes = 0
			viewport := Vec2{1200, Scalar(f64(rows[i]) * 28.0 + 64.0)}
			point := _measure(t, "ordinary", rows[i] + 30, viewport, frames[i], 5, _build_ordinary)
			_print_point(point)
		}
	}

	@(private)
	_bench_grow :: proc(t: ^testing.T, saturating: bool) {
		name := "grow-linear"
		if saturating {
			name = "grow-saturating"
		}
		log.infof("\n== %s ==", name)
		_print_header()
		sizes := []int{125, 250, 500, 1000, 2000, 4000, 8000}
		frames := []int{3000, 1500, 800, 400, 400, 300, 200}
		height := Scalar(64)
		for i in 0 ..< len(sizes) {
			node_count := sizes[i]
			_bench_nodes = node_count
			_bench_height = height
			_bench_maxes = nil
			_bench_sim_passes = 0
			if saturating {
				_bench_maxes = _saturating_maxes(node_count)
				defer delete(_bench_maxes)
				_bench_sim_passes = _sim_grow_passes(f64(4 * node_count), _bench_maxes)
			}
			viewport := Vec2{Scalar(4 * node_count), 64}
			point := _measure(t, name, node_count, viewport, frames[i], 7, _build_grow_row)
			_print_point(point)
		}
	}

	@(private)
	_bench_adversarial :: proc(t: ^testing.T) {
		log.info("\n== grow-adversarial (review construction: cap 3.5, then proposal - 1e-5) ==")
		_print_header()
		sizes := []int{125, 250, 500, 1000, 2000, 4000, 8000}
		frames := []int{3000, 1500, 800, 400, 400, 300, 200}
		height := Scalar(64)
		for i in 0 ..< len(sizes) {
			node_count := sizes[i]
			_bench_nodes = node_count
			_bench_height = height
			_bench_maxes = _adversarial_maxes(node_count)
			defer delete(_bench_maxes)
			_bench_sim_passes = _sim_grow_passes(f64(4 * node_count), _bench_maxes)
			viewport := Vec2{Scalar(4 * node_count), 64}
			point := _measure(t, "grow-adversarial", node_count, viewport, frames[i], 7, _build_grow_row)
			_print_point(point)
		}
	}

	@(test)
	bench_c6b_baseline :: proc(t: ^testing.T) {
		log.info("== C6b layout baseline (BENCH=true, -o:speed) ==")
		_bench_ordinary(t)
		_bench_grow(t, false)
		_bench_grow(t, true)
		_bench_adversarial(t)
		log.info("\n== done ==")
	}

} // when #config(BENCH, false)
