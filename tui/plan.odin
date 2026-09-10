package tui

import "nabla:term"

// Presentation planning (§3.5 of the frozen API target). plan_presentation
// compares the current logical buffer with the previous one and produces a
// borrowed []term.Presentation_Op stream that terminal validates,
// encodes, and transports. Changed-line spans with one buffered write are the
// first optimization; scroll-region and cost-minimized cursor movement come
// only after measurement (§6.8).
//
// Ownership: the returned slice borrows out, and Write_Grapheme_Op text
// borrows from the logical buffers' cells (the caller keeps the drawn text
// alive through presentation). Nothing is retained and nothing is allocated.
//
// A nil previous frame or a dimension change (resize) requires full_redraw:
// every cell is planned and a leading Set_Style_Op{} establishes the SGR
// baseline, mirroring the full-frame path's opening reset. A malformed
// previous frame is a caller error (.Invalid_Buffer), not a redraw trigger.
// The reserved bottom-right cell is never planned — it stays stale exactly
// as in the full-frame path (autowrap/scroll hazard, §6.4).
//
// profile and capabilities are accepted and unused in v1: color reduction is
// terminal-owned at encode time, and capability-aware planning arrives with
// the capability milestone (D26).

// Presentation_Error classifies a failed plan. .None is the zero value.
Presentation_Error :: enum u8 {
	None,
	Buffer_Too_Small,
	Invalid_Buffer,
	Unsupported,
}

@(require_results)
plan_presentation :: proc(
	current: Cell_Buffer,
	previous: Maybe(Cell_Buffer),
	profile: term.Target_Profile,
	capabilities: term.Capabilities,
	out: []term.Presentation_Op,
) -> (
	ops: []term.Presentation_Op,
	required: int,
	full_redraw: bool,
	err: Presentation_Error,
) {
	if v_err := _validate_buffer(current); v_err != nil {
		return nil, 0, false, v_err
	}
	has_previous := previous != nil
	prev: Cell_Buffer
	if has_previous {
		prev = previous.?
		if v_err := _validate_buffer(prev); v_err != nil {
			return nil, 0, false, v_err
		}
	}
	full_redraw = !has_previous || prev.width != current.width || prev.height != current.height

	// Count pass: the exact operation count, so a too-small out is reported
	// with no guess-and-retry.
	p := _Op_Plan {
		count_only = true,
	}
	_plan_operations(&p, current, prev, full_redraw, has_previous)
	required = p.pos
	if required > len(out) {
		return nil, required, full_redraw, .Buffer_Too_Small
	}

	w := _Op_Plan {
		out = out,
	}
	_plan_operations(&w, current, prev, full_redraw, has_previous)
	if w.overflowed {
		// Unreachable: the count pass just produced the exact count.
		return nil, required, full_redraw, .Buffer_Too_Small
	}
	return out[:w.pos], required, full_redraw, .None
}

// _Op_Plan writes planned operations into caller-owned storage. count_only
// mode counts the exact operation count without touching out, so the
// required-size contract and the emit pass share one walk.
_Op_Plan :: struct {
	out:        []term.Presentation_Op,
	pos:        int,
	count_only: bool,
	overflowed: bool,
}

_plan_op :: proc(p: ^_Op_Plan, op: term.Presentation_Op) {
	if p.count_only {
		p.pos += 1
		return
	}
	if p.pos >= len(p.out) {
		p.overflowed = true
		return
	}
	p.out[p.pos] = op
	p.pos += 1
}

// _validate_buffer rejects negative extents and cell storage too small for
// the logical grid (division form avoids a hostile width * height overflow).
// Zero-sized buffers are valid and plan nothing.
_validate_buffer :: proc(buffer: Cell_Buffer) -> Presentation_Error {
	if buffer.width < 0 || buffer.height < 0 {
		return .Invalid_Buffer
	}
	if buffer.width == 0 || buffer.height == 0 {
		return nil
	}
	if buffer.width > len(buffer.cells) / buffer.height {
		return .Invalid_Buffer
	}
	return nil
}

// _is_blank reports whether a logical grapheme is a blank cell: the empty
// grapheme (the terminal blank-cell contract) or the composition blank " ".
_is_blank :: proc "contextless" (grapheme: string) -> bool {
	return grapheme == "" || grapheme == " "
}

// _plan_operations walks the logical buffer once and plans the operation
// stream. Changed cells are coalesced into runs per row, grouped by
// blank-ness and style: a blank run emits one Move + one Set_Style (when the
// tracked style differs) + one Erase; a write run emits Move + Set_Style +
// one Write per cell, with the cursor advanced per cell. The tracked planner
// cursor starts unknown, so the first planned run always emits a move (there
// is no cross-frame state).
_plan_operations :: proc(p: ^_Op_Plan, current, prev: Cell_Buffer, full_redraw: bool, has_previous: bool) {
	if current.width == 0 || current.height == 0 {
		return
	}
	if full_redraw {
		// Establish the SGR baseline, mirroring the full-frame path's
		// opening reset: an external write may have left attributes set.
		_plan_op(p, term.Set_Style_Op{})
	}

	cursor_known := false
	cursor: term.Position
	style: Style

	last_row := current.height - 1
	last_col := current.width - 1
	for y in 0 ..< current.height {
		x := 0
		for x < current.width {
			if y == last_row && x == last_col {
				// The reserved bottom-right cell is never planned.
				break
			}
			index := y * current.width + x
			cell := current.cells[index]
			changed := full_redraw
			if !changed && has_previous {
				changed = cell != prev.cells[index]
			}
			if !changed {
				x += 1
				continue
			}

			// Extend the run: changed cells of the same blank-ness and style.
			run_start := x
			blank := _is_blank(cell.grapheme)
			run_style := cell.style
			x += 1
			for x < current.width {
				if y == last_row && x == last_col {
					break
				}
				next_index := y * current.width + x
				next_cell := current.cells[next_index]
				next_changed := full_redraw
				if !next_changed && has_previous {
					next_changed = next_cell != prev.cells[next_index]
				}
				if !next_changed || _is_blank(next_cell.grapheme) != blank || next_cell.style != run_style {
					break
				}
				x += 1
			}

			position := term.Position {
				x = run_start,
				y = y,
			}
			if !cursor_known || cursor != position {
				_plan_op(p, term.Move_Cursor_Op{position = position})
				cursor = position
				cursor_known = true
			}
			if style != run_style {
				_plan_op(p, term.Set_Style_Op{style = presentation_style(run_style)})
				style = run_style
			}
			if blank {
				_plan_op(p, term.Erase_Cells_Op{count = x - run_start})
				// ECH leaves the cursor at the run start.
			} else {
				for i in run_start ..< x {
					_plan_op(p, term.Write_Grapheme_Op{grapheme = current.cells[y * current.width + i].grapheme, width = 1})
					cursor.x += 1
				}
			}
		}
	}
}
