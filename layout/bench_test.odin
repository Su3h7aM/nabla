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
//  2. grow-linear — a single row of `n` Grow children whose max is effectively
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
// same maxes) predicts, cross-checked against the real loop in an instrumented
// scratch copy (see docs/C6B_BENCHMARK_BASELINE.md).
//
// Results are printed as a table by the `bench_c6b_baseline` test.

package layout

import "core:fmt"
import "core:math"
import "core:testing"
import "core:time"

// Anchor: keeps the imports referenced when the benchmark block below is
// compiled out (BENCH unset) so the unused-import check stays green.
_ :: fmt
_ :: math
_ :: testing
_ :: time

when #config(BENCH, false) {

	Bench_Point :: struct {
		label:      string,
		n:          int,
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
	_bench_n: int
	@(private)
	_bench_height: Scalar
	@(private)
	_bench_rows: int
	@(private)
	_bench_maxes: []Scalar
	@(private)
	_bench_sim_passes: int

	@(private)
	_bench_config :: proc(n: int) -> Options {
		return Options {
			capacities = {
				nodes = n + 8,
				children = n + 8,
				clips = 16,
				commands = n + 8,
				text_lines = 16,
				measured_words = 64,
				overlays = 8,
				measure_cache = 16,
				id_table = n + 8,
				depth = 64,
				diagnostics = n + 8,
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
		n := len(maxes)
		current := make([]f64, n)
		defer delete(current)
		remaining := free_space
		passes := 0
		for remaining > 0 {
			passes += 1
			total_weight := 0.0
			candidate_count := 0
			for i in 0 ..< n {
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
			for i in 0 ..< n {
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
	_measure :: proc(label: string, n: int, viewport: Vec2, frames: int, repeats: int, build: proc(ctx: ^Context)) -> Bench_Point {
		ctx: Context
		init_err := init(&ctx, _bench_config(n))
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
			fmt.printfln("  WARN %s (n=%d): frame error %v", label, n, frame_error)
		}

		run_means := make([]f64, repeats)
		defer delete(run_means)
		for r in 0 ..< repeats {
			start := time.tick_now()
			for _ in 0 ..< frames {
				if frame(&ctx, viewport) {
					build(&ctx)
				}
			}
			elapsed_us := time.duration_microseconds(time.tick_diff(start, time.tick_now()))
			run_means[r] = elapsed_us / f64(frames)
		}

		total := 0.0
		min_us := run_means[0]
		max_us := run_means[0]
		for v in run_means {
			total += v
			min_us = math.min(min_us, v)
			max_us = math.max(max_us, v)
		}
		mean := total / f64(repeats)
		variance := 0.0
		for v in run_means {
			variance += (v - mean) * (v - mean)
		}
		return Bench_Point {
			label = label,
			n = n,
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

	// Grow workloads: a single row of `n` Grow children. When `_bench_maxes` is
	// set, each child's max comes from the chosen generator; otherwise max is
	// effectively unbounded and the distribution completes in a single pass.
	@(private)
	_build_grow_row :: proc(ctx: ^Context) {
		n := _bench_n
		row_width := Scalar(4 * n)
		if element(ctx, {layout = {flow = .Row, sizing = {width = fixed(row_width), height = fixed(_bench_height)}}}) {
			for i in 0 ..< n {
				mx: Scalar = 1e6
				if _bench_maxes != nil {
					mx = _bench_maxes[i]
				}
				content(ctx, {layout = {sizing = {width = grow(1, 0, mx), height = fixed(_bench_height)}}})
			}
		}
	}

	// Constant-gap max recurrence: the equal-weight max arrangement that keeps the
	// gap at 1/(2n) below the running per-pass proposal.
	@(private)
	_saturating_maxes :: proc(n: int) -> []Scalar {
		R := f64(4 * n)
		proposal := R / f64(n)
		remaining := R
		candidates := f64(n)
		gap := 1.0 / (2.0 * f64(n))
		maxes := make([]Scalar, n)
		for k in 0 ..< n {
			maxes[k] = Scalar(math.max(proposal - gap, 0.5))
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
	_adversarial_maxes :: proc(n: int) -> []Scalar {
		R := f64(4 * n)
		maxes := make([]Scalar, n)
		maxes[0] = 3.5
		acc := 3.5
		for k in 1 ..< n {
			proposal := (R - acc) / f64(n - k)
			maxes[k] = Scalar(proposal - 1e-5)
			acc += f64(maxes[k])
		}
		return maxes
	}

	@(private)
	_print_header :: proc() {
		fmt.println("workload\tn\tframes\tsim_passes\tmean_us/frame\tmin_us\tmax_us\tstddev_us")
	}

	@(private)
	_print_point :: proc(p: Bench_Point) {
		fmt.printfln("%s\t%d\t%d\t%d\t%.2f\t%.2f\t%.2f\t%.2f", p.label, p.n, p.frames, p.sim_passes, p.mean_us, p.min_us, p.max_us, p.stddev_us)
	}

	@(private)
	_bench_ordinary :: proc() {
		fmt.println("\n== ordinary (representative tree) ==")
		_print_header()
		rows := []int{128, 256, 512, 1024, 2048}
		frames := []int{5000, 3000, 1500, 800, 400}
		for i in 0 ..< len(rows) {
			_bench_rows = rows[i]
			_bench_sim_passes = 0
			viewport := Vec2{1200, Scalar(f64(rows[i]) * 28.0 + 64.0)}
			p := _measure("ordinary", rows[i] + 30, viewport, frames[i], 5, _build_ordinary)
			_print_point(p)
		}
	}

	@(private)
	_bench_grow :: proc(saturating: bool) {
		name := "grow-linear"
		if saturating {
			name = "grow-saturating"
		}
		fmt.printfln("\n== %s ==", name)
		_print_header()
		sizes := []int{125, 250, 500, 1000, 2000, 4000, 8000}
		frames := []int{3000, 1500, 800, 400, 400, 300, 200}
		height := Scalar(64)
		for i in 0 ..< len(sizes) {
			n := sizes[i]
			_bench_n = n
			_bench_height = height
			_bench_maxes = nil
			_bench_sim_passes = 0
			if saturating {
				_bench_maxes = _saturating_maxes(n)
				defer delete(_bench_maxes)
				_bench_sim_passes = _sim_grow_passes(f64(4 * n), _bench_maxes)
			}
			viewport := Vec2{Scalar(4 * n), 64}
			p := _measure(name, n, viewport, frames[i], 7, _build_grow_row)
			_print_point(p)
		}
	}

	@(private)
	_bench_adversarial :: proc() {
		fmt.println("\n== grow-adversarial (review construction: cap 3.5, then proposal - 1e-5) ==")
		_print_header()
		sizes := []int{125, 250, 500, 1000, 2000, 4000, 8000}
		frames := []int{3000, 1500, 800, 400, 400, 300, 200}
		height := Scalar(64)
		for i in 0 ..< len(sizes) {
			n := sizes[i]
			_bench_n = n
			_bench_height = height
			_bench_maxes = _adversarial_maxes(n)
			defer delete(_bench_maxes)
			_bench_sim_passes = _sim_grow_passes(f64(4 * n), _bench_maxes)
			viewport := Vec2{Scalar(4 * n), 64}
			p := _measure("grow-adversarial", n, viewport, frames[i], 7, _build_grow_row)
			_print_point(p)
		}
	}

	@(test)
	bench_c6b_baseline :: proc(t: ^testing.T) {
		fmt.println("== C6b layout baseline (BENCH=true, -o:speed) ==")
		_bench_ordinary()
		_bench_grow(false)
		_bench_grow(true)
		_bench_adversarial()
		fmt.println("\n== done ==")
	}

} // when #config(BENCH, false)
