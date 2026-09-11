#+test
#+private file
package layout

import "core:testing"

_handle_of :: proc(frame_result: Frame_Result, identifier: Id) -> Node_Handle {
	for entry in frame_result.id_index {
		if entry.id == identifier {
			return entry.node
		}
	}
	return 0
}

_panel :: proc(width, height: Scalar) -> Element_Desc {
	return Element_Desc{layout = {sizing = {fixed(width), fixed(height)}}}
}

_hit_position :: proc(frame_result: Frame_Result, handle: Node_Handle) -> int {
	for entry, index in frame_result.hit_order {
		if entry == handle {
			return index
		}
	}
	return -1
}

@(test)
test_hit_ancestor_and_child_queries :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	if frame(&ctx, {200, 200}) {
		background := _panel(200, 200)
		background.id = id("background")
		if element(&ctx, background) {
			content(&ctx, {id = id("child"), layout = {sizing = {fixed(100), fixed(100)}}})
			floating := _panel(50, 50)
			floating.id = id("floating")
			floating.hit = .Opaque
			floating.overlay = {
				attach = .Root,
				layer  = 1,
			}
			content(&ctx, floating)
		}
	}
	frame_result, err := result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)

	// hit_test returns the front-most eligible node, and an opaque overlay
	// stops the overlap stack beneath it.
	front, hit := hit_test(frame_result, {10, 10})
	testing.expect(t, hit)
	testing.expect_value(t, front.id, id("floating"))

	inner, inner_hit := hit_test(frame_result, {80, 80})
	testing.expect(t, inner_hit)
	testing.expect_value(t, inner.id, id("child"))

	outer, outer_hit := hit_test(frame_result, {150, 150})
	testing.expect(t, outer_hit)
	testing.expect_value(t, outer.id, id("background"))

	_, missed := hit_test(frame_result, {400, 400})
	testing.expect(t, !missed)

	storage: [8]Node_Handle
	stack, complete := hit_stack(frame_result, {80, 80}, storage[:])
	testing.expect(t, complete)
	testing.expect_value(t, len(stack), 2)
	testing.expect_value(t, frame_result.nodes[stack[0]].id, id("child"))
	testing.expect_value(t, frame_result.nodes[stack[1]].id, id("background"))

	opaque_stack, opaque_complete := hit_stack(frame_result, {10, 10}, storage[:])
	testing.expect(t, opaque_complete)
	testing.expect_value(t, len(opaque_stack), 1)

	short: [1]Node_Handle
	short_stack, short_complete := hit_stack(frame_result, {80, 80}, short[:])
	testing.expect(t, !short_complete)
	testing.expect_value(t, len(short_stack), 1)

	// ancestor_path is the structural chain, not the overlap stack: it crosses
	// the overlay boundary and never consults hit eligibility.
	path_storage: [8]Node_Handle
	path, path_complete, path_found := ancestor_path(frame_result, _handle_of(frame_result, id("floating")), path_storage[:])
	testing.expect(t, path_complete && path_found)
	testing.expect_value(t, len(path), 2)
	testing.expect_value(t, frame_result.nodes[path[0]].id, id("floating"))
	testing.expect_value(t, frame_result.nodes[path[1]].id, id("background"))

	// Children iterate in declaration order, overlays included.
	iterator := children(frame_result, _handle_of(frame_result, id("background")))
	expected := [2]Id{id("child"), id("floating")}
	seen := 0
	for child in next_child(&iterator) {
		testing.expect_value(t, child.id, expected[seen])
		seen += 1
	}
	testing.expect_value(t, seen, 2)

	// An out-of-range clip handle resolves to the viewport.
	testing.expect_value(t, clip_of(frame_result, Clip_Handle(99)), clip_of(frame_result, Clip_Handle(0)))

	// A passthrough container stays in the hit order but is never eligible, and
	// a child scrolled out of its clip is rejected by the clip test.
	if frame(&ctx, {200, 200}) {
		clipper := _panel(100, 40)
		clipper.id = id("clipper")
		clipper.hit = .Passthrough
		clipper.clip = {
			axes   = {.Y},
			offset = {0, 40},
		}
		if element(&ctx, clipper) {
			if element(&ctx, {layout = {flow = .Column, sizing = {fixed(100), fit()}}}) {
				content(&ctx, {id = id("first"), layout = {sizing = {fixed(100), fixed(40)}}})
				content(&ctx, {id = id("second"), layout = {sizing = {fixed(100), fixed(40)}}})
			}
		}
	}
	frame_result, err = result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	clipper := _handle_of(frame_result, id("clipper"))
	testing.expect(t, _hit_position(frame_result, clipper) >= 0)
	testing.expect(t, !frame_result.nodes[clipper].flags.hit_testable)
	second, second_hit := hit_test(frame_result, {50, 20})
	testing.expect(t, second_hit)
	testing.expect_value(t, second.id, id("second"))

	// A handle wider than the table is rejected without signed wrap.
	nodes := make([]Resolved_Node, 2)
	clips := make([]Resolved_Clip, 1)
	defer delete(nodes)
	defer delete(clips)
	manual := Frame_Result {
		nodes = nodes,
		clips = clips,
	}
	_, valid := node(manual, Node_Handle(max(u32)))
	testing.expect(t, !valid)
	_, found := lookup(manual, Id(1))
	testing.expect(t, !found)
}

@(test)
test_result_lifecycle_and_visible_commands :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	// No frame yet, and a failed frame, both publish nothing.
	before, before_error := result(&ctx)
	testing.expect_value(t, before_error, Frame_Error.No_Completed_Frame)
	testing.expect_value(t, len(before.nodes), 0)

	services := Services{}
	services.measure_text = nil
	set_services(&ctx, services)
	if frame(&ctx, {100, 100}) {
		text(&ctx, {text = "hello"})
	}
	failed, failed_error := result(&ctx)
	testing.expect_value(t, failed_error, Frame_Error.Missing_Text_Measurer)
	testing.expect_value(t, len(failed.nodes), 0)

	// visible_commands is a bounds-only view of the stream: it filters without
	// touching the node table and yields a subsequence in paint order.
	set_services(&ctx, Services{})
	if frame(&ctx, {400, 400}) {
		if element(&ctx, {layout = {flow = .Column, sizing = {fixed(100), fit()}}}) {
			for index in 0 ..< 4 {
				row := _panel(100, 100)
				row.paint.background = {255, 255, 255, 255}
				content(&ctx, row)
			}
		}
	}
	frame_result, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	testing.expect_value(t, len(frame_result.commands), 4)

	iterator := visible_commands(frame_result, Rect{size = {100, 150}})
	seen := 0
	last_index := -1
	for command, index in next_command(&iterator) {
		testing.expect(t, index > last_index)
		last_index = index
		testing.expect_value(t, command.bounds.position.y, Scalar(100 * seen))
		seen += 1
	}
	testing.expect_value(t, seen, 2)
	testing.expect_value(t, len(frame_result.commands), 4)

	empty := visible_commands(frame_result, Rect{size = {0, 150}})
	empty_count := 0
	for _ in next_command(&empty) {
		empty_count += 1
	}
	testing.expect_value(t, empty_count, 0)
}
