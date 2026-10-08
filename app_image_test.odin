#+build linux
package main

import "core:hash"
import "core:strings"
import "core:sync"
import "core:testing"

import "nabla:agent"
import "nabla:ai"
import "nabla:term"
import "nabla:tui/widgets"

// image_test_png is a black 8-bit RGB PNG file of the given size, written with stored
// deflate blocks because core:image has no encoder.
image_test_png :: proc(width, height: u32) -> []byte {
	STORED_BLOCK_MAX :: 65535
	file := make([dynamic]byte, context.temp_allocator)
	append_u32 :: proc(buffer: ^[dynamic]byte, value: u32) {
		for shift in 0 ..< 4 { append(buffer, byte(value >> uint(24 - 8 * shift))) }
	}
	append_chunk :: proc(file: ^[dynamic]byte, type: string, data: []byte) {
		append_u32(file, u32(len(data)))
		start := len(file)
		append(file, type)
		append(file, ..data)
		append_u32(file, hash.crc32(file[start:]))
	}
	append(&file, "\x89PNG\r\n\x1a\n")

	header := make([dynamic]byte, context.temp_allocator)
	append_u32(&header, width)
	append_u32(&header, height)
	append(&header, 8, 2, 0, 0, 0)
	append_chunk(&file, "IHDR", header[:])

	raw := make([]byte, (int(width) * 3 + 1) * int(height), context.temp_allocator)
	zlib := make([dynamic]byte, context.temp_allocator)
	append(&zlib, 0x78, 0x01)
	for offset := 0; offset < len(raw); offset += STORED_BLOCK_MAX {
		block := raw[offset:min(offset + STORED_BLOCK_MAX, len(raw))]
		length := u16(len(block))
		append(&zlib, 1 if offset + len(block) == len(raw) else 0, byte(length), byte(length >> 8), byte(~length), byte(~length >> 8))
		append(&zlib, ..block)
	}
	append_u32(&zlib, hash.adler32(raw))
	append_chunk(&file, "IDAT", zlib[:])
	append_chunk(&file, "IEND", nil)
	return file[:]
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
	image_test_app(app, true, 60, 40, 600, 400)
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
	image_test_app(app, true, 100, 30, 800, 600)
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

// A picture larger than IMAGE_MAX_EDGE is shrunk with its aspect ratio kept, so the
// entry holds and the terminal is sent no more than the shrunk pixels.
@(test)
test_large_picture_is_shrunk :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app.run.alloc = context.allocator
	app.run.snap.images_enabled = true
	attachments := []ai.Provider_Attachment{{Media = .PNG, Name = "a.png", Data = image_test_png(2400, 1200)}}
	prepared := image_prepare(app, attachments)
	defer delete(prepared.pixels)
	testing.expect_value(t, prepared.format, term.Image_Format.RGB)
	testing.expect_value(t, prepared.width, IMAGE_MAX_EDGE)
	testing.expect_value(t, prepared.height, IMAGE_MAX_EDGE / 2)
	testing.expect_value(t, len(prepared.pixels), prepared.width * prepared.height * 3)
}

// Each pixel of a shrunk picture is the mean of the pixels it covers.
@(test)
test_shrink_averages_covered_pixels :: proc(t: ^testing.T) {
	// Four 2 x 2 blocks of constant gray 0, 40, 80, and 120, except that the first
	// block holds 0, 4, 8, and 12.
	levels := [16]u8{0, 4, 40, 40, 8, 12, 40, 40, 80, 80, 120, 120, 80, 80, 120, 120}
	prepared := Entry_Image {
		format = .RGB,
		width  = 4,
		height = 4,
	}
	for level in levels { append(&prepared.pixels, level, level, level) }
	defer delete(prepared.pixels)
	if !testing.expect(t, image_shrink(&prepared, 2, 2, context.allocator)) { return }
	testing.expect_value(t, prepared.width, 2)
	testing.expect_value(t, prepared.height, 2)
	testing.expect_value(t, len(prepared.pixels), 12)
	for expected, index in ([4]u8{6, 40, 80, 120}) {
		for channel in 0 ..< 3 { testing.expect_value(t, prepared.pixels[index * 3 + channel], expected) }
	}
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

// A photo the read tool attached charges only the picture budget: the entries before it,
// its box, and the answer after it all stay.
@(test)
test_large_picture_keeps_the_transcript :: proc(t: ^testing.T) {
	app := new(App)
	defer {
		snapshot_destroy(app)
		free(app)
	}
	app.run.alloc = context.allocator
	snap_append(app, .User, "look at a.png")
	snap_append(app, .Assistant, "reading")
	image_test_app(app, true, 100, 40, 1024, 800)
	defer widgets.input_destroy(&app.input)
	snap_append(app, .Assistant, "it is black")

	if !testing.expect_value(t, len(app.run.snap.entries), 4) { return }
	testing.expect(t, app.run.snap.entries[2].image.id != 0, "the box keeps its picture")
	testing.expect_value(t, app.run.snap.image_bytes, app.run.snap.entries[2].image.bytes)
}

// A picture that does not fit the picture budget releases the oldest pictures, oldest
// first. Every entry stays, and the released box's picture is deleted from the terminal.
@(test)
test_picture_budget_releases_the_oldest_picture :: proc(t: ^testing.T) {
	PICTURE_BYTES :: 48
	app := new(App)
	defer {
		snapshot_destroy(app)
		free(app)
	}
	app.run.alloc = context.allocator
	app.run.snap.images_enabled = true
	storage := frame_storage_new(context.allocator)
	defer frame_storage_destroy(storage)

	for _ in 0 ..< 3 {
		image := Entry_Image {
			format = .RGB,
			width  = 4,
			height = 4,
		}
		resize(&image.pixels, PICTURE_BYTES)
		entry := snap_entry_make(app, .Tool, "ok")
		snap_entry_image_set_locked(app, &entry, &image, 2 * PICTURE_BYTES)
		snap_push_locked(app, entry)
	}
	entries := app.run.snap.entries
	if !testing.expect_value(t, len(entries), 3) { return }
	testing.expect_value(t, entries[0].image.id, term.Image_Id(0))
	testing.expect_value(t, len(entries[0].image.pixels), 0)
	testing.expect(t, entries[1].image.id != 0 && entries[2].image.id != 0, "the newer pictures stay")
	testing.expect_value(t, app.run.snap.image_bytes, 2 * PICTURE_BYTES)

	// A picture larger than the whole budget is not kept, and the caller frees it.
	oversized := Entry_Image {
		format = .RGB,
		width  = 4,
		height = 4,
	}
	resize(&oversized.pixels, 3 * PICTURE_BYTES)
	defer delete(oversized.pixels)
	entry := snap_entry_make(app, .Tool, "ok")
	snap_entry_image_set_locked(app, &entry, &oversized, 2 * PICTURE_BYTES)
	testing.expect_value(t, entry.image.id, term.Image_Id(0))
	testing.expect_value(t, len(oversized.pixels), 3 * PICTURE_BYTES)
	snap_push_locked(app, entry)
	testing.expect_value(t, app.run.snap.image_bytes, 2 * PICTURE_BYTES)
}

// Releasing a picture that is placed on the terminal or waiting in an upload deletes the
// terminal image on the next frame and frees the pending pixels.
@(test)
test_released_picture_is_deleted_from_the_terminal :: proc(t: ^testing.T) {
	app := new(App)
	defer {
		snapshot_destroy(app)
		free(app)
	}
	image_test_app(app, true, 60, 40, 80, 32)
	defer widgets.input_destroy(&app.input)
	storage := frame_storage_new(context.allocator)
	defer frame_storage_destroy(storage)
	if !testing.expect_value(t, image_test_frame(app, storage), Render_Status.None) { return }
	if !testing.expect_value(t, len(storage.uploads), 1) { return }
	id := app.run.snap.entries[0].image.id

	{
		sync.mutex_guard(&app.run.mu)
		snap_images_release_locked(app, 0)
		images_collect(app, storage)
	}
	testing.expect_value(t, len(storage.uploads), 0)
	testing.expect_value(t, app.run.snap.image_bytes, 0)

	append(&storage.placed, Image_Placement{id = id, columns = 1, rows = 1})
	{
		sync.mutex_guard(&app.run.mu)
		images_collect(app, storage)
	}
	testing.expect_value(t, len(storage.stale), 1)
}
