#+build linux
#+test
// Full-frame encode benchmark: measures the cost of serializing a complete
// Frame_Buffer into caller-owned reusable output, the contract that replaced
// the old per-call builder allocation. The hot path must allocate nothing per
// frame, so every iteration reuses one scratch.
//
// Gated behind `-define:BENCH=true`; with BENCH unset the file compiles to an
// empty translation unit, so the regular matrix is unaffected.
//
// Run (from the repo root, release semantics):
//
//	odin test ./term -collection:nabla=$PWD -define:BENCH=true -o:speed -thread-count:1
package term

import "core:fmt"
import "core:testing"
import "core:time"

// Anchors keep the imports referenced when the benchmark block is compiled
// out (BENCH unset).
_ :: fmt
_ :: testing
_ :: time

when #config(BENCH, false) {

	_bench_encode :: proc(label: string, buffer: Frame_Buffer, profile: Target_Profile, frames: int) {
		scratch := make([]byte, 4 << 20)
		defer delete(scratch)

		required: int
		for _ in 0 ..< 24 {
			_, req, err := encode(buffer, profile, {}, scratch)
			if err != nil {
				fmt.eprintln("bench: encode failed:", err)
				return
			}
			required = req
		}

		start := time.tick_now()
		for _ in 0 ..< frames {
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

	@(test)
	bench_full_frame_encode :: proc(t: ^testing.T) {
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
