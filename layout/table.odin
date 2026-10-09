package layout

import "base:runtime"
import "core:math"

// table declares a column of table_row elements whose cells share the widths of
// `columns`, and, when it returns true, opens a scope the rows are declared into.
//
// The table is a Column flow that stretches its rows; give it a fit, fixed,
// percent or grow width as for any element. `columns` is borrowed until the
// frame result is released. A table of fit columns is as wide as its widest
// cells and shrinks with its parent. Declare only table_row elements in it.
@(deferred_in_out = _table_leave, require_results)
table :: proc(ctx: ^Context, #by_ptr desc: Element_Desc, columns: []Column_Desc, loc := #caller_location) -> bool {
	styled := desc
	styled.layout.flow = .Column
	styled.layout.align = .Stretch
	_, entered := _declare_node(ctx, styled, true, loc)
	if !entered {
		return false
	}
	state := _context_state(ctx)
	if len(columns) > cap(state._tracks) - len(state._tracks) {
		_latch_capacity_error(state, .Tracks, loc)
		element_end(ctx)
		return false
	}
	input := &state._node_inputs[state._scopes[len(state._scopes) - 1].node]
	input.table_kind = .Table
	input.columns = columns
	input.track_start = len(state._tracks)
	input.track_count = len(columns)
	for _ in columns {
		ok := _try_append(&state._tracks, _Track{})
		assert(ok)
	}
	_update_high_water(state, .Tracks, len(state._tracks))
	return true
}

@(private)
_table_leave :: proc(ctx: ^Context, #by_ptr desc: Element_Desc, columns: []Column_Desc, loc: runtime.Source_Code_Location, entered: bool) {
	if entered {
		element_end(ctx)
	}
}

// table_row declares a Row flow directly inside a table and, when it returns
// true, opens a scope for its children. Children with `Layout_Style.cell` set
// are the row's cells, in column order; other children, such as fixed-size
// separators, keep their own sizing and are subtracted from the table width.
// A row with a different cell count than the table has columns is diagnosed as
// `Table_Cell_Count`.
@(deferred_in_out = _table_row_leave, require_results)
table_row :: proc(ctx: ^Context, #by_ptr desc: Element_Desc, loc := #caller_location) -> bool {
	styled := desc
	styled.layout.flow = .Row
	_, entered := _declare_node(ctx, styled, true, loc)
	if !entered {
		return false
	}
	state := _context_state(ctx)
	row := state._scopes[len(state._scopes) - 1].node
	parent := state._scopes[len(state._scopes) - 2].node
	if state._node_inputs[parent].table_kind == .Table {
		state._node_inputs[row].table_kind = .Row
	}
	return true
}

@(private)
_table_row_leave :: proc(ctx: ^Context, #by_ptr desc: Element_Desc, loc: runtime.Source_Code_Location, entered: bool) {
	if entered {
		element_end(ctx)
	}
}

@(private, require_results)
_is_table_row :: proc(state: ^_Context_State, node: Node_Handle) -> bool {
	input := &state._node_inputs[node]
	return input.in_flow && input.table_kind == .Row
}

// _cell_track returns the column a node occupies in its row, or -1 when the
// node is not a cell or lies beyond the table's columns.
@(private, require_results)
_cell_track :: proc "contextless" (table, cell: ^_Node_Input) -> int {
	if cell.track_slot < 1 || cell.track_slot > table.track_count {
		return -1
	}
	return cell.track_slot - 1
}

@(private, require_results)
_nonnegative :: proc "contextless" (value: Scalar) -> Scalar {
	return value if value >= 0 else 0
}

// _column_style normalizes a caller's column the way an element's sizing is.
@(private, require_results)
_column_style :: proc "contextless" (column: Column_Desc) -> Axis_Size {
	style := column.width
	style.value = _nonnegative(style.value)
	style.min = _nonnegative(style.min)
	style.max = _nonnegative(style.max)
	style.weight = _nonnegative(style.weight)
	if style.mode == .Percent {
		style.value = math.min(style.value, 1)
	}
	if style.mode == .Grow && style.weight == 0 {
		style.weight = 1
	}
	if style.max == 0 {
		style.max = math.inf_f32(1)
	}
	style.max = math.max(style.max, style.min)
	return style
}

// _bound_track applies a column's sizing to the widths its cells asked for. A
// percent column resolves only against a definite table width; otherwise it
// sizes from its cells like a fit column.
@(private, require_results)
_bound_track :: proc "contextless" (style: Axis_Size, track: _Track, available: f64, definite: bool) -> (base, floor: Scalar) {
	switch style.mode {
	case .Fixed:
		base = math.clamp(style.value, style.min, style.max)
		return base, base
	case .Percent:
		if definite {
			base = math.clamp(Scalar(available * f64(style.value)), style.min, style.max)
			return base, base
		}
		fallthrough
	case .Fit, .Grow:
		base = math.clamp(track.preferred, style.min, style.max)
		floor = math.min(math.max(track.floor, style.min), base)
	}
	return
}

// _fit_table gathers each column's preferred width and shrink floor from all of
// its cells, then sets every row's intrinsic width from those columns so the
// table sizes as a whole.
@(private)
_fit_table :: proc(state: ^_Context_State, table: Node_Handle) {
	table_input := &state._node_inputs[table]
	tracks := state._tracks[table_input.track_start:][:table_input.track_count]
	for &track in tracks {
		track = {}
	}
	for row in _direct_children(state, table) {
		if !_is_table_row(state, row) {
			continue
		}
		for cell in _direct_children(state, row) {
			cell_input := &state._node_inputs[cell]
			index := _cell_track(table_input, cell_input)
			if !cell_input.in_flow || index < 0 {
				continue
			}
			floor := cell_input.minimum_size.x
			if .X in cell_input.desc.clip.axes {
				floor = 0
			}
			tracks[index].preferred = math.max(tracks[index].preferred, cell_input.intrinsic_size.x)
			tracks[index].floor = math.max(tracks[index].floor, floor)
		}
	}
	for &track, index in tracks {
		track.preferred, track.floor = _bound_track(_column_style(table_input.columns[index]), track, 0, false)
	}

	overhead: f64
	for row in _direct_children(state, table) {
		if !_is_table_row(state, row) {
			continue
		}
		row_input := &state._node_inputs[row]
		preferred_tracks, floor_tracks, preferred_other, floor_other: f64
		flow_count := 0
		for cell in _direct_children(state, row) {
			cell_input := &state._node_inputs[cell]
			if !cell_input.in_flow {
				continue
			}
			flow_count += 1
			if index := _cell_track(table_input, cell_input); index >= 0 {
				preferred_tracks += f64(tracks[index].preferred)
				floor_tracks += f64(tracks[index].floor)
			} else {
				preferred_other += f64(_preferred_axis_size(state, cell, .X))
				floor_other += f64(_minimum_axis_size(state, cell, .X))
			}
		}
		spacing := f64(math.max(flow_count - 1, 0)) * f64(row_input.desc.layout.gap) + f64(_padding_total(row_input.desc.layout.padding, .X))
		overhead = math.max(overhead, preferred_other + spacing)
		row_input.intrinsic_size.x = _finite_scalar(state, row, .X, preferred_tracks + preferred_other + spacing, false)
		row_input.minimum_size.x = _finite_scalar(state, row, .X, floor_tracks + floor_other + spacing, false)
	}
	table_input.track_overhead = _finite_scalar(state, table, .X, overhead, false)
}

// _solve_tracks distributes the table's resolved inner width over its columns
// and fixes each cell's width to its column.
//
// Columns start at their bounded preferred width. Spare width goes to grow
// columns by weight up to their max. A deficit is taken from fit, grow and
// indefinite percent columns in proportion to how far each is above its floor,
// so the column with the most to give wraps most and none goes below its floor.
@(private)
_solve_tracks :: proc(state: ^_Context_State, table: Node_Handle) {
	input := &state._node_inputs[table]
	tracks := state._tracks[input.track_start:][:input.track_count]
	available := math.max(f64(state._nodes[table].inner.size.x) - f64(input.track_overhead), 0)
	definite := input.definite[.X]
	tolerance := f64(SCALAR_TOLERANCE)

	total: f64
	for &track, index in tracks {
		track.preferred, track.floor = _bound_track(_column_style(input.columns[index]), track, available, definite)
		track.width = track.preferred
		total += f64(track.width)
	}

	free := available - total
	if free > tolerance && definite {
		remaining := free
		for remaining > tolerance {
			total_weight: f64
			for track, index in tracks {
				style := _column_style(input.columns[index])
				if style.mode == .Grow && track.width < style.max {
					total_weight += f64(style.weight)
				}
			}
			if total_weight == 0 {
				break
			}
			saturated := false
			share := remaining
			for &track, index in tracks {
				style := _column_style(input.columns[index])
				if style.mode != .Grow || track.width >= style.max {
					continue
				}
				if f64(track.width) + share * f64(style.weight) / total_weight > f64(style.max) {
					remaining -= f64(style.max - track.width)
					track.width = style.max
					saturated = true
				}
			}
			if !saturated {
				for &track, index in tracks {
					style := _column_style(input.columns[index])
					if style.mode == .Grow && track.width < style.max {
						track.width += Scalar(remaining * f64(style.weight) / total_weight)
					}
				}
				break
			}
		}
	} else if free < -tolerance {
		slack: f64
		for track in tracks {
			slack += f64(track.width - track.floor)
		}
		if slack > 0 {
			ratio := math.min(-free / slack, 1)
			for &track in tracks {
				track.width -= Scalar(f64(track.width - track.floor) * ratio)
			}
		}
	}

	// Text wraps at the width solved here, before snapping rounds the edges, so
	// the boundaries are rounded to the grid now. Rounding the running total
	// keeps the columns' sum exact.
	if pitch := f64(state._options.snap); pitch > 0 {
		running, snapped_previous: f64
		for &track in tracks {
			running += f64(track.width)
			snapped := math.round(running / pitch) * pitch
			track.width = _finite_scalar(state, table, .X, snapped - snapped_previous, false)
			snapped_previous = snapped
		}
	}

	for row in _direct_children(state, table) {
		if !_is_table_row(state, row) {
			continue
		}
		for cell in _direct_children(state, row) {
			cell_input := &state._node_inputs[cell]
			index := _cell_track(input, cell_input)
			if cell_input.in_flow && index >= 0 {
				cell_input.desc.layout.sizing.width = Axis_Size {
					mode  = .Fixed,
					value = tracks[index].width,
					max   = math.inf_f32(1),
				}
			}
		}
	}
}

@(private)
_diagnose_table_rows :: proc(state: ^_Context_State) {
	for node_index in 1 ..< len(state._node_inputs) {
		node := Node_Handle(node_index)
		if !_is_table_row(state, node) {
			continue
		}
		input := &state._node_inputs[node]
		columns := state._node_inputs[state._nodes[node].parent].track_count
		if input.cell_count != columns {
			_append_diagnostic(state, .Table_Cell_Count, node, amount = Scalar(input.cell_count), loc = input.loc)
		}
	}
}
