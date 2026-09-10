package main

// Compile-only example of the exact target call shapes of the layout package.
// It exercises allocator-backed and caller-owned fixed contexts, per-frame
// Services, deferred lexical composition, result publication, pure queries,
// and borrowed result lifetime. The example is verified by an explicit
// `odin build`; it is not part of the runtime test suite.

import "nabla:layout"

_measure_text :: proc(
	user_data: rawptr,
	value: string,
	style: layout.Text_Style,
	request: layout.Measure_Request,
) -> (
	layout.Measure_Result,
	layout.Measure_Error,
) {
	_ = user_data
	_ = style
	_ = request
	size := layout.Vec2{layout.Scalar(len(value)), 1}
	return layout.Measure_Result{size = size, min_size = size, baseline = 1}, .None
}

_break_text :: proc(
	user_data: rawptr,
	value: string,
	offset: int,
) -> (
	piece_end: int,
	next_offset: int,
	kind: layout.Text_Break_Kind,
	err: layout.Text_Break_Error,
) {
	_ = user_data
	if offset >= len(value) {
		return len(value), len(value), .None, .None
	}
	for index := offset; index < len(value); index += 1 {
		if value[index] == ' ' {
			return index, index + 1, .Optional, .None
		}
	}
	return len(value), len(value), .None, .None
}

_options :: proc() -> layout.Options {
	return layout.Options {
		capacities = layout.Capacities {
			nodes = 32,
			children = 32,
			clips = 8,
			commands = 64,
			text_lines = 32,
			measured_words = 64,
			overlays = 4,
			measure_cache = 32,
			id_table = 32,
			depth = 8,
			diagnostics = 16,
		},
		cull = .Visible,
	}
}

_compose :: proc(ctx: ^layout.Context) {
	if layout.element(
		ctx,
		layout.Element_Desc {
			id = layout.id("root"),
			layout = layout.Layout_Style {
				flow = .Column,
				sizing = layout.Sizing{width = layout.grow(), height = layout.grow()},
				padding = layout.pad_all(2),
				gap = 1,
				justify = .Center,
				align = .Center,
			},
		},
	) {
		layout.text(
			ctx,
			layout.Text_Desc {
				id = layout.id("title"),
				text = "Nabla",
				style = layout.Text_Style{size = 1, wrap = .None},
				sizing = layout.Sizing{width = layout.fit(), height = layout.fit()},
			},
		)
		layout.content(
			ctx,
			layout.Element_Desc {
				id = layout.id("empty"),
				content = layout.Content{},
				layout = layout.Layout_Style{sizing = layout.Sizing{width = layout.fixed(4), height = layout.fixed(1)}},
			},
		)
	}
}

_consume_result :: proc(frame_result: layout.Frame_Result) {
	root, root_found := layout.lookup(frame_result, layout.id("root"))
	if root_found {
		_ = layout.clip_of(frame_result, root.clip)
		child_iterator := layout.children(frame_result, layout.Node_Handle(1))
		for {
			child, handle, ok := layout.next_child(&child_iterator)
			if !ok {
				break
			}
			_ = child
			_ = handle
		}
	}

	_, hit_ok := layout.hit_test(frame_result, {0, 0})
	_ = hit_ok
	hit_buffer: [8]layout.Node_Handle
	hits, hits_complete := layout.hit_stack(frame_result, {0, 0}, hit_buffer[:])
	_ = hits
	_ = hits_complete
	path_buffer: [8]layout.Node_Handle
	path, path_complete, path_found := layout.ancestor_path(frame_result, layout.Node_Handle(1), path_buffer[:])
	_ = path
	_ = path_complete
	_ = path_found

	commands := layout.visible_commands(frame_result, layout.Rect{size = frame_result.viewport})
	for {
		command, index, ok := layout.next_command(&commands)
		if !ok {
			break
		}
		_ = command
		_ = index
	}
}

main :: proc() {
	options := _options()
	services := layout.Services {
		measure_text           = _measure_text,
		measure_text_user_data = nil,
		break_text             = _break_text,
		break_text_user_data   = nil,
	}

	allocator_context: layout.Context
	if layout.init(&allocator_context, options) == nil {
		defer layout.destroy(&allocator_context)
		layout.set_services(&allocator_context, services)
		if layout.frame(&allocator_context, {80, 24}) {
			_compose(&allocator_context)
		}
		frame_result, frame_error := layout.result(&allocator_context)
		if frame_error == .None {
			_consume_result(frame_result)
		}
		layout.invalidate_metrics(&allocator_context, 1)
		_ = layout.reserve(&allocator_context, options.capacities)
	}

	storage := make([]byte, layout.storage_size(options.capacities))
	defer delete(storage)
	fixed_context: layout.Context
	if layout.init_from_buffer(&fixed_context, options, storage) == nil {
		defer layout.destroy(&fixed_context)
		layout.set_services(&fixed_context, services)
		if layout.frame(&fixed_context, {80, 24}) {
			_compose(&fixed_context)
		}
		frame_result, frame_error := layout.result(&fixed_context)
		if frame_error == .None {
			_consume_result(frame_result)
		}
	}
}
