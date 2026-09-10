#+build linux

// Full-frame encode benchmark (implementation-plan step D24): measures the
// cost of serializing a complete Frame_Buffer into caller-owned reusable
// output — the contract that replaced the old per-call builder allocation.
// The point is that the hot path allocates nothing per frame; this harness
// runs encode against one reusable scratch for the whole measurement.
//
// Gated behind `-define:BENCH=true`; with BENCH unset the file compiles to
// an empty translation unit, so the regular matrix (scripts/check,
// scripts/test) is unaffected and the terminal test counts do not change.
//
// Run (from the repo root, release semantics):
//
//	odin run ./tests/tty_tests -collection:nabla=$PWD -define:BENCH=true -o:speed -thread-count:1
//
// Results are printed as a table by the `bench_full_frame_encode` test,
// which run_tests (test_support.odin) includes under the same BENCH gate.

package term

import "core:fmt"
import "core:time"

// Anchor: keeps the imports referenced when the benchmark block below is
// compiled out (BENCH unset) so CI's unused-import check stays green.
@(private)
_bench_import_anchor :: proc() {
	_ = fmt.println
	_ = time.tick_now
}

when #config(BENCH, false) {

	// _bench_encode measures full-frame encode into one reusable scratch.
	_bench_encode :: proc(label: string, buffer: Frame_Buffer, profile: Target_Profile, frames: int) {
		scratch := make([]byte, 4 << 20)
		defer delete(scratch)

		required: int
		for i in 0 ..< 24 {
			_, req, err := encode(buffer, profile, {}, scratch)
			if err != nil {
				fmt.eprintln("bench: encode failed:", err)
				return
			}
			required = req
		}

		start := time.tick_now()
		for i in 0 ..< frames {
			_, _, err := encode(buffer, profile, {}, scratch)
			if err != nil {
				fmt.eprintln("bench: encode failed:", err)
				return
			}
		}
		elapsed_us := time.duration_microseconds(time.tick_diff(start, time.tick_now()))
		us_per_frame := f64(elapsed_us) / f64(frames)
		fmt.printf("%-16s %6d cells  %9.2f us/frame  %7d bytes/frame\n", label, len(buffer.cells), us_per_frame, required)
	}

	// _bench_frame builds a frame of the given size; styled frames force a
	// style diff on every cell (the expensive SGR emission path).
	_bench_frame :: proc(columns, rows: int, styled: bool) -> Frame_Buffer {
		cells := make([]Cell, columns * rows)
		for i in 0 ..< len(cells) {
			cell := Cell {
				grapheme = "x",
				width    = 1,
			}
			if styled {
				cell.style = {
					foreground = Color(RGB_Color{u8(i % 256), u8((i / 256) % 256), 128}),
					background = Color(RGB_Color{u8(255 - i % 256), 64, 128}),
				}
			}
			cells[i] = cell
		}
		return Frame_Buffer{columns = columns, rows = rows, cells = cells}
	}

	@(private)
	bench_full_frame_encode :: proc(t: ^T) {
		_ = t
		fmt.println("== terminal full-frame encode (BENCH=true, -o:speed) ==")
		profile := Target_Profile {
			color_depth = .True_Color,
		}
		workloads := []struct {
			label:         string,
			columns, rows: int,
			frames:        int,
			styled:        bool,
		} {
			{label = "plain-80x24", columns = 80, rows = 24, frames = 20000},
			{label = "styled-80x24", columns = 80, rows = 24, frames = 20000, styled = true},
			{label = "styled-200x50", columns = 200, rows = 50, frames = 5000, styled = true},
			{label = "styled-400x100", columns = 400, rows = 100, frames = 1000, styled = true},
			{label = "plain-400x100", columns = 400, rows = 100, frames = 1000},
		}
		for w in workloads {
			buffer := _bench_frame(w.columns, w.rows, w.styled)
			defer delete(buffer.cells)
			_bench_encode(w.label, buffer, profile, w.frames)
		}
		fmt.println("\n== done ==")
	}

} // when #config(BENCH, false)
