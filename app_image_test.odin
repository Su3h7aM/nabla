#+build linux
package main

import "core:strings"
import "core:sync"
import "core:testing"

import "nabla:agent"
import "nabla:ai"
import "nabla:term"
import "nabla:tui/widgets"

// image_test_png is the start of a PNG file of the given size: the signature and the
// IHDR chunk, which is all the size is read from.
image_test_png :: proc(width, height: u32) -> []byte {
	header := make([]byte, PNG_HEADER_END + 5, context.temp_allocator)
	copy(header, PNG_SIGNATURE)
	header[11] = 13
	copy(header[12:], "IHDR")
	for value, index in ([2]u32{width, height}) {
		for shift in 0 ..< 4 { header[16 + index * 4 + shift] = byte(value >> uint(24 - 8 * shift)) }
	}
	return header
}

// image_test_frame renders one frame under the runtime mutex, as render_frame requires.
image_test_frame :: proc(app: ^App, storage: ^Frame_Storage) -> Render_Status {
	sync.mutex_guard(&app.run.mu)
	_, status := render_frame(app, storage)
	return status
}

image_test_count_placeholders :: proc(storage: ^Frame_Storage) -> (count: int) {
	for cell in storage.buffer.cells {
		if strings.has_prefix(cell.grapheme, term.GRAPHICS_PLACEHOLDER) { count += 1 }
	}
	return
}

// image_test_app shows one read result carrying a PNG of the given pixel size.
image_test_app :: proc(app: ^App, enabled: bool, columns, rows: int, width, height: u32) {
	app.run.alloc = context.allocator
	app.run.snap.images_enabled = enabled
	app.columns = columns
	app.rows = rows
	widgets.input_init(&app.input, context.allocator)
	result := agent.Tool_Result {
		content     = "ok\n\nread a.png",
		outcome     = .Success,
		attachments = []ai.Provider_Attachment{{Media = .PNG, Name = "a.png", Data = image_test_png(width, height)}},
	}
	observer_tool_result(app, 5, 0, "read", `{"path":"a.png"}`, &result)
}

// A picture the read tool attached is drawn inside its box, scaled down to the box's
// width and half the conversation's rows at the terminal's cell size, and clipped by
// the transcript like the text around it.
@(test)
test_tool_image_is_drawn_inside_the_box :: proc(t: ^testing.T) {
	app := new(App)
	defer {
		snapshot_destroy(app)
		free(app)
	}
	image_test_app(app, true, 60, 40, 5400, 3600)
	defer widgets.input_destroy(&app.input)
	storage := frame_storage_new(context.allocator)
	defer frame_storage_destroy(storage)
	storage.cell_pixels = {10, 20}

	if !testing.expect_value(t, image_test_frame(app, storage), Render_Status.None) { return }
	if !testing.expect_value(t, len(storage.shown), 1) { return }
	placement := storage.shown[0]
	testing.expect_value(t, placement.id, app.run.snap.entries[0].image.id)
	testing.expect_value(t, placement.rows, storage.conversation_rows / 2)
	testing.expect(t, placement.columns <= 54, "the box's text is 54 columns wide")
	testing.expect_value(t, image_test_count_placeholders(storage), placement.columns * placement.rows)
	testing.expect_value(t, len(storage.uploads), 1)

	// A terminal too short for the picture shows the rows that fit, and the prompt below
	// is not drawn over.
	app.rows = 14
	if !testing.expect_value(t, image_test_frame(app, storage), Render_Status.None) { return }
	shown := image_test_count_placeholders(storage)
	testing.expect(t, shown > 0 && shown < placement.columns * placement.rows, "only the rows inside the transcript are drawn")
	prompt_top := (app.rows - 5) * storage.buffer.columns
	testing.expect_value(t, storage.buffer.cells[prompt_top + 1].grapheme, "╭")
}

// A large picture stays within the maximums and leaves the prompt alone, and a tiny
// one is enlarged to the minimum height with its aspect ratio kept.
@(test)
test_tool_image_size_is_bounded :: proc(t: ^testing.T) {
	app := new(App)
	defer {
		snapshot_destroy(app)
		free(app)
	}
	image_test_app(app, true, 100, 30, 4000, 3000)
	defer widgets.input_destroy(&app.input)
	storage := frame_storage_new(context.allocator)
	defer frame_storage_destroy(storage)
	storage.cell_pixels = {8, 16}

	if !testing.expect_value(t, image_test_frame(app, storage), Render_Status.None) { return }
	if !testing.expect_value(t, len(storage.shown), 1) { return }
	placement := storage.shown[0]
	testing.expect(t, placement.columns <= IMAGE_MAX_COLUMNS, "no wider than the maximum")
	testing.expect(t, placement.rows <= storage.conversation_rows / 2, "no taller than half the conversation")
	testing.expect_value(t, image_test_count_placeholders(storage), placement.columns * placement.rows)
	for cell in storage.buffer.cells[(app.conversation_rect.y + app.conversation_rect.height) * storage.buffer.columns:] {
		if strings.has_prefix(cell.grapheme, term.GRAPHICS_PLACEHOLDER) {
			testing.fail_now(t, "the prompt and footer rows hold no picture")
		}
	}

	small := new(App)
	defer {
		snapshot_destroy(small)
		free(small)
	}
	image_test_app(small, true, 100, 40, 16, 16)
	defer widgets.input_destroy(&small.input)
	small_storage := frame_storage_new(context.allocator)
	defer frame_storage_destroy(small_storage)
	if !testing.expect_value(t, image_test_frame(small, small_storage), Render_Status.None) { return }
	if !testing.expect_value(t, len(small_storage.shown), 1) { return }
	// 16 x 16 pixels at the default 8 x 16 cell is 2 x 1 cells, enlarged eight times.
	testing.expect_value(t, small_storage.shown[0].columns, 16)
	testing.expect_value(t, small_storage.shown[0].rows, IMAGE_MIN_ROWS)
}

// A picture the terminal did not take stays pending and is sent again by the next frame,
// and the failure is reported once.
@(test)
test_failed_transmit_is_retried :: proc(t: ^testing.T) {
	app := new(App)
	defer {
		snapshot_destroy(app)
		free(app)
	}
	image_test_app(app, true, 60, 40, 80, 32)
	defer widgets.input_destroy(&app.input)
	storage := frame_storage_new(context.allocator)
	defer frame_storage_destroy(storage)

	// The app has no open terminal, so every write fails.
	for _ in 0 ..< 2 {
		if !testing.expect_value(t, image_test_frame(app, storage), Render_Status.None) { return }
		images_sync(app, storage)
		testing.expect_value(t, len(storage.placed), 0)
		testing.expect_value(t, len(storage.uploads), 1)
	}
	warnings := 0
	for entry in app.run.snap.entries {
		if entry.kind == .Warning { warnings += 1 }
	}
	testing.expect_value(t, warnings, 1)
}

// A terminal without graphics keeps the text preview only: the entry holds no picture
// and the frame has no placeholder.
@(test)
test_tool_image_is_not_kept_without_graphics :: proc(t: ^testing.T) {
	app := new(App)
	defer {
		snapshot_destroy(app)
		free(app)
	}
	image_test_app(app, false, 60, 40, 80, 32)
	defer widgets.input_destroy(&app.input)
	storage := frame_storage_new(context.allocator)
	defer frame_storage_destroy(storage)

	if !testing.expect_value(t, image_test_frame(app, storage), Render_Status.None) { return }
	testing.expect_value(t, app.run.snap.entries[0].image.id, term.Image_Id(0))
	testing.expect_value(t, image_test_count_placeholders(storage), 0)
}

@(test)
test_png_size_reads_the_header :: proc(t: ^testing.T) {
	width, height, ok := png_size(image_test_png(80, 32))
	testing.expect(t, ok)
	testing.expect_value(t, width, 80)
	testing.expect_value(t, height, 32)
	_, _, ok = png_size(image_test_png(0, 32))
	testing.expect(t, !ok, "an empty image has no size")
	_, _, ok = png_size(transmute([]byte)string("GIF89a..................."))
	testing.expect(t, !ok, "another format is not a PNG")
}

// A picture the decoder cannot read leaves the box with its text.
@(test)
test_unreadable_jpeg_leaves_the_text_preview :: proc(t: ^testing.T) {
	app := new(App)
	defer {
		snapshot_destroy(app)
		free(app)
	}
	app.run.alloc = context.allocator
	app.run.snap.images_enabled = true
	app.columns = 60
	app.rows = 20
	widgets.input_init(&app.input, context.allocator)
	defer widgets.input_destroy(&app.input)
	result := agent.Tool_Result {
		content     = "ok\n\nread a.jpg",
		outcome     = .Success,
		attachments = []ai.Provider_Attachment{{Media = ai.Provider_Media.JPEG, Name = "a.jpg", Data = transmute([]byte)string("\xff\xd8 not a jpeg")}},
	}
	observer_tool_result(app, 5, 0, "read", `{"path":"a.jpg"}`, &result)
	storage := frame_storage_new(context.allocator)
	defer frame_storage_destroy(storage)
	if !testing.expect_value(t, image_test_frame(app, storage), Render_Status.None) { return }
	testing.expect_value(t, app.run.snap.entries[0].image.id, term.Image_Id(0))
	testing.expect_value(t, image_test_count_placeholders(storage), 0)
}
