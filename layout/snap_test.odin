#+test
#+private file
package layout

import "core:testing"

_whole :: proc(value: Scalar) -> bool {
	return value == Scalar(int(value))
}

_rect_is_whole :: proc(rect: Rect) -> bool {
	return _whole(rect.position.x) && _whole(rect.position.y) && _whole(rect.size.x) && _whole(rect.size.y)
}

@(test)
test_snap_splits_grow_children_into_adjacent_whole_units :: proc(t: ^testing.T) {
	config := _test_options()
	config.snap = 1
	ctx: Context
	testing.expect_value(t, init(&ctx, config), nil)
	defer destroy(&ctx)

	if frame(&ctx, {100, 10}) {
		if element(&ctx, {layout = {flow = .Row, sizing = {width = grow(), height = grow()}, padding = {left = 0.5, right = 1.25}}}) {
			for _ in 0 ..< 3 {
				content(&ctx, {layout = {sizing = {width = grow(), height = grow()}}, paint = {background = 1}})
			}
		}
	}
	frame_result, err := result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)

	for node in frame_result.nodes[1:] {
		testing.expect(t, _rect_is_whole(node.outer), "outer is whole")
		testing.expect(t, _rect_is_whole(node.inner), "inner is whole")
	}
	for command in frame_result.commands {
		testing.expect(t, _rect_is_whole(command.bounds), "command bounds are whole")
	}
	parent := frame_result.nodes[1]
	total: Scalar
	for index in 2 ..= 4 {
		child := frame_result.nodes[index]
		if index > 2 {
			previous := frame_result.nodes[index - 1].outer
			testing.expect_value(t, child.outer.position.x, previous.position.x + previous.size.x)
		}
		total += child.outer.size.x
	}
	testing.expect_value(t, total, parent.inner.size.x)
	testing.expect_value(t, frame_result.nodes[2].outer.position.x, parent.inner.position.x)
}

@(test)
test_snap_keeps_nested_padding_whole :: proc(t: ^testing.T) {
	config := _test_options()
	config.snap = 1
	ctx: Context
	testing.expect_value(t, init(&ctx, config), nil)
	defer destroy(&ctx)

	if frame(&ctx, {33.5, 20.25}) {
		if element(&ctx, {layout = {sizing = {width = grow(), height = grow()}, padding = pad_all(1.5)}, clip = {axes = {.Y}, offset = {0, 0.4}}}) {
			if element(&ctx, {layout = {sizing = {width = percent(0.5), height = grow()}, padding = pad_all(0.75)}}) {
				content(&ctx, {layout = {sizing = {width = grow(), height = fixed(30.3)}}})
			}
		}
	}
	frame_result, err := result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	for node in frame_result.nodes[1:] {
		testing.expect(t, _rect_is_whole(node.outer), "outer is whole")
		testing.expect(t, _rect_is_whole(node.inner), "inner is whole")
		testing.expect(t, _whole(node.content_size.x) && _whole(node.content_size.y), "content size is whole")
		testing.expect(t, _whole(node.scroll_range.x) && _whole(node.scroll_range.y), "scroll range is whole")
		testing.expect(t, _whole(node.scroll_offset.y), "scroll offset is whole")
	}
	for index in 1 ..< len(frame_result.clips) {
		testing.expect(t, _rect_is_whole(frame_result.clips[index].rect), "clip is whole")
	}
}

@(test)
test_snap_zero_leaves_geometry_fractional :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	if frame(&ctx, {100, 10}) {
		if element(&ctx, {layout = {flow = .Row, sizing = {width = grow(), height = grow()}}}) {
			for _ in 0 ..< 3 {
				content(&ctx, {layout = {sizing = {width = grow(), height = grow()}}})
			}
		}
	}
	frame_result, err := result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect(t, !_whole(frame_result.nodes[2].outer.size.x), "unsnapped share stays fractional")
	testing.expect(t, !_whole(frame_result.nodes[3].outer.position.x), "unsnapped edge stays fractional")
}

@(test)
test_snap_rejects_invalid_pitch :: proc(t: ^testing.T) {
	config := _test_options()
	config.snap = -1
	ctx: Context
	testing.expect_value(t, init(&ctx, config), Context_Error(Context_Data_Error.Invalid_Options))
}
