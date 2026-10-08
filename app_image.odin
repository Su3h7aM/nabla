#+build linux
package main

// The pictures a tool result carries, drawn inside the call's box on a terminal
// that supports Kitty graphics placeholders. The entry owns the picture and the
// main thread owns what the terminal holds: the frame draws placeholder cells,
// and present_frame sends, resizes, and frees terminal images to match them.

import "base:runtime"
import "core:fmt"
import "core:image"
import _ "core:image/jpeg"
import _ "core:image/png"
import "core:math"
import "core:sync"

import "nabla:ai"
import "nabla:term"

// IMAGE_MAX_ROWS is the tallest a picture is drawn, and half the conversation's
// rows is the tallest on a short terminal. A screenshot stays readable at 24 rows,
// and the text around the picture stays on screen.
IMAGE_MAX_ROWS :: 24
#assert(IMAGE_MAX_ROWS <= term.GRAPHICS_MAX_ROWS)

// IMAGE_MIN_ROWS is the height a smaller picture is enlarged to, because an icon
// at its natural size is a few cells and cannot be read. The maximums win when
// they are smaller.
IMAGE_MIN_ROWS :: 8
#assert(IMAGE_MIN_ROWS <= IMAGE_MAX_ROWS)

// IMAGE_MAX_COLUMNS is the widest a picture is drawn. A wide terminal would
// otherwise stretch a picture across the whole screen, far past a readable size.
IMAGE_MAX_COLUMNS :: 80
#assert(IMAGE_MAX_COLUMNS <= term.GRAPHICS_MAX_COLUMNS)

// IMAGE_CELL_WIDTH and IMAGE_CELL_HEIGHT are the pixels assumed for one cell when
// the terminal reports no pixel size.
IMAGE_CELL_WIDTH :: 8
IMAGE_CELL_HEIGHT :: 16

// IMAGE_MAX_EDGE is the longest side, in pixels, a prepared picture keeps. A
// picture of IMAGE_MAX_COLUMNS cells at a large HiDPI cell width is about this
// wide, so a larger picture only costs transfer time and memory.
IMAGE_MAX_EDGE :: 1024

// Entry_Image is the picture of one tool box. The terminal names it by id, which
// is zero when the entry has none. pixels is what the terminal is sent, the RGB or RGBA
// pixels the picture decoded to, at most IMAGE_MAX_EDGE on a side, owned by the
// run's allocator. bytes is what the picture charged to Snapshot.image_bytes. It stays
// after images_collect moves the pixels to an upload, which holds bytes already counted.
Entry_Image :: struct {
	id:     term.Image_Id,
	pixels: [dynamic]u8, // owned,
	bytes:  int,
	format: term.Image_Format,
	width:  int,
	height: int,
}

// Image_Placement is an image at a size in cells.
Image_Placement :: struct {
	id:      term.Image_Id,
	columns: int,
	rows:    int,
}

// Image_Upload is an image the terminal does not have yet. It owns the pixels
// that images_collect moved out of the entry under the lock, so the lock never
// copies them and the entry can be dropped while they are sent. The frame storage
// frees them when the terminal takes the image, when the entry is gone, or when
// the storage is destroyed.
Image_Upload :: struct {
	pixels:    [dynamic]u8, // owned,
	format:    term.Image_Format,
	width:     int,
	height:    int,
	placement: Image_Placement,
}

// entry_destroy releases everything an entry owns.
entry_destroy :: proc(entry: ^Entry) {
	delete(entry.text)
	delete(entry.stream)
	delete(entry.image.pixels)
}

// image_prepare makes the picture of the first PNG or JPEG among attachments,
// decoded to 8-bit RGB or RGBA pixels and shrunk to IMAGE_MAX_EDGE. GIF, WebP,
// and PDF keep the text preview only, and so does a file that cannot be read.
// It runs on the calling thread before the runtime mutex is taken. The result
// owns its pixels with the run's allocator and has no id yet; its pixels are
// empty when there is no picture. images_enabled is set before any thread that
// calls this starts, so it is read without the lock.
image_prepare :: proc(app: ^App, attachments: []ai.Provider_Attachment) -> (image: Entry_Image) {
	if !app.run.snap.images_enabled { return }
	for attachment in attachments {
		switch attachment.Media {
		case .PNG, .JPEG:
			image_decode(app, attachment.Data, &image)
			return
		case .GIF, .WebP, .PDF:
		}
	}
	return
}

// snap_entry_image_set_locked moves a prepared picture into an entry and numbers
// it, leaving image empty. A picture it cannot take stays with the caller, who
// frees it: one larger than budget, one for an entry that has a picture, or one
// with no id left. Otherwise the oldest pictures are released until this one fits
// in budget. The picture is charged to Snapshot.image_bytes here, and the charge
// ends when the picture is released or its entry leaves the transcript; pixels
// moved into Frame_Storage.uploads stay charged until then. The caller holds the
// runtime mutex.
snap_entry_image_set_locked :: proc(app: ^App, entry: ^Entry, image: ^Entry_Image, budget := TRANSCRIPT_IMAGE_MAX_BYTES) {
	if image == nil || len(image.pixels) == 0 || entry.image.id != 0 || app.run.snap.next_image_id + 1 >= u32(term.IMAGE_ID_LIMIT) {
		return
	}
	image.bytes = cap(image.pixels)
	if image.bytes > budget { return }
	snap_images_release_locked(app, budget - image.bytes)
	app.run.snap.next_image_id += 1
	image.id = term.Image_Id(app.run.snap.next_image_id)
	entry.image = image^
	image^ = {}
	app.run.snap.image_bytes += entry.image.bytes
}

// snap_images_release_locked releases the pictures of the oldest entries, oldest
// first, until the snapshot holds at most limit bytes of pictures. The boxes keep
// their text. The next frame deletes the terminal image of each: images_collect
// finds its id gone from the entries, deletes the placed image, and frees pixels
// still waiting in an upload. The caller holds the runtime mutex.
snap_images_release_locked :: proc(app: ^App, limit: int) {
	for &entry in app.run.snap.entries {
		if app.run.snap.image_bytes <= limit { return }
		if entry.image.id == 0 { continue }
		app.run.snap.image_bytes -= entry.image.bytes
		delete(entry.image.pixels)
		entry.image = {}
		entry.revision += 1
		snap_publish_locked(app)
	}
}

// image_decode decodes a PNG or JPEG file into prepared, whose pixels the decoder
// allocates with the run's allocator, and shrinks it to IMAGE_MAX_EDGE. prepared
// stays empty when it cannot.
image_decode :: proc(app: ^App, data: []byte, prepared: ^Entry_Image) {
	// image.destroy frees the metadata with the context's allocator.
	context.allocator = app.run.alloc
	decoded, decode_error := image.load_from_bytes(data, {}, app.run.alloc)
	defer image.destroy(decoded)
	if decode_error != nil || decoded.depth != 8 || decoded.width <= 0 || decoded.height <= 0 { return }
	switch decoded.channels {
	case 3:
		prepared.format = .RGB
	case 4:
		prepared.format = .RGBA
	case:
		return
	}
	prepared.pixels = decoded.pixels.buf
	decoded.pixels.buf = nil
	prepared.width, prepared.height = decoded.width, decoded.height
	longer := max(prepared.width, prepared.height)
	if longer <= IMAGE_MAX_EDGE { return }
	new_width := max(1, prepared.width * IMAGE_MAX_EDGE / longer)
	new_height := max(1, prepared.height * IMAGE_MAX_EDGE / longer)
	if !image_shrink(prepared, new_width, new_height, app.run.alloc) {
		delete(prepared.pixels)
		prepared^ = {}
	}
}

// image_shrink scales image down to new_width by new_height, which are no larger
// than its size, and replaces its pixels with a buffer allocated with allocator.
// Each new pixel is the mean of the old pixels it covers. False means the
// allocation failed and image is unchanged.
image_shrink :: proc(image: ^Entry_Image, new_width, new_height: int, allocator: runtime.Allocator) -> bool {
	channels := 3 if image.format == .RGB else 4
	pixels, allocation_error := make([dynamic]u8, new_width * new_height * channels, allocator)
	if allocation_error != nil { return false }
	for y in 0 ..< new_height {
		top := y * image.height / new_height
		bottom := max((y + 1) * image.height / new_height, top + 1)
		for x in 0 ..< new_width {
			left := x * image.width / new_width
			right := max((x + 1) * image.width / new_width, left + 1)
			covered := (right - left) * (bottom - top)
			for channel in 0 ..< channels {
				sum := 0
				for source_y in top ..< bottom {
					for source_x in left ..< right {
						sum += int(image.pixels[(source_y * image.width + source_x) * channels + channel])
					}
				}
				pixels[(y * new_width + x) * channels + channel] = u8((sum + covered / 2) / covered)
			}
		}
	}
	delete(image.pixels)
	image.pixels = pixels
	image.width, image.height = new_width, new_height
	return true
}

// image_cells sizes a picture in cells: its natural size at the given pixels per
// cell (a zero size assumes the default), enlarged with its aspect ratio kept
// until it is IMAGE_MIN_ROWS tall when it is smaller, and shrunk to fit
// available_columns, IMAGE_MAX_COLUMNS, IMAGE_MAX_ROWS, and half of
// conversation_rows. The maximums win over the minimum. The result is at least
// one cell. image must be prepared.
image_cells :: proc(image: Entry_Image, available_columns, conversation_rows: int, cell_pixels: [2]int) -> (columns, rows: int) {
	cell_width := cell_pixels.x if cell_pixels.x > 0 else IMAGE_CELL_WIDTH
	cell_height := cell_pixels.y if cell_pixels.y > 0 else IMAGE_CELL_HEIGHT
	natural_columns := f64(image.width) / f64(cell_width)
	natural_rows := f64(image.height) / f64(cell_height)
	limit_columns := clamp(available_columns, 1, IMAGE_MAX_COLUMNS)
	limit_rows := clamp(conversation_rows / 2, 1, IMAGE_MAX_ROWS)
	wanted := max(1, IMAGE_MIN_ROWS / natural_rows)
	scale := min(wanted, f64(limit_columns) / natural_columns, f64(limit_rows) / natural_rows)
	columns = clamp(int(math.round(natural_columns * scale)), 1, limit_columns)
	rows = clamp(int(math.round(natural_rows * scale)), 1, limit_rows)
	return
}

// image_attach numbers a prepared picture and moves it into a window entry, leaving image
// empty. A picture it cannot number stays with the caller, who frees it. The window's
// pictures are not charged to the live budget.
image_attach :: proc(app: ^App, entry: ^Entry, image: ^Entry_Image) {
	if len(image.pixels) == 0 { return }
	sync.mutex_guard(&app.run.mu)
	if app.run.snap.next_image_id + 1 >= u32(term.IMAGE_ID_LIMIT) { return }
	app.run.snap.next_image_id += 1
	image.id = term.Image_Id(app.run.snap.next_image_id)
	image.bytes = cap(image.pixels)
	entry.image = image^
	image^ = {}
}

// snap_image_entry_locked finds the window or live entry that holds image id, or nil.
snap_image_entry_locked :: proc(app: ^App, id: term.Image_Id) -> ^Entry {
	for &entry in app.transcript.entries {
		if entry.image.id == id { return &entry }
	}
	for &entry in app.run.snap.entries {
		if entry.image.id == id { return &entry }
	}
	return nil
}

// images_collect works out, from the frame just composed, what the terminal must
// be told: the shown images it does not hold yet, whose pixels move from their
// entries to storage.uploads, and the images it holds whose entries left the
// transcript. Moving is a slice header, so the lock covers no copy of the pixels.
// A pending upload whose entry left is freed. A failed allocation skips the item,
// and the next frame finds it again. The caller holds the runtime mutex.
images_collect :: proc(app: ^App, storage: ^Frame_Storage) {
	clear(&storage.stale)
	for placed in storage.placed {
		if snap_image_entry_locked(app, placed.id) == nil { _, _ = append(&storage.stale, placed.id) }
	}
	for index := len(storage.uploads) - 1; index >= 0; index -= 1 {
		if snap_image_entry_locked(app, storage.uploads[index].placement.id) == nil {
			delete(storage.uploads[index].pixels)
			unordered_remove(&storage.uploads, index)
		}
	}
	for shown in storage.shown {
		if image_placement_find(storage.placed[:], shown.id) >= 0 { continue }
		if index := image_upload_find(storage.uploads[:], shown.id); index >= 0 {
			storage.uploads[index].placement = shown
			continue
		}
		entry := snap_image_entry_locked(app, shown.id)
		if entry == nil || len(entry.image.pixels) == 0 { continue }
		upload := Image_Upload {
			pixels    = entry.image.pixels,
			format    = entry.image.format,
			width     = entry.image.width,
			height    = entry.image.height,
			placement = shown,
		}
		if _, append_error := append(&storage.uploads, upload); append_error != nil { continue }
		entry.image.pixels = nil
	}
}

// image_placement_find returns the index of id in placements, or -1.
image_placement_find :: proc(placements: []Image_Placement, id: term.Image_Id) -> int {
	for placement, index in placements {
		if placement.id == id { return index }
	}
	return -1
}

// image_upload_find returns the index of the upload of id in uploads, or -1.
image_upload_find :: proc(uploads: []Image_Upload, id: term.Image_Id) -> int {
	for upload, index in uploads {
		if upload.placement.id == id { return index }
	}
	return -1
}

// images_sync brings the terminal to what images_collect found: it frees stale
// images, sends new ones, and re-places a shown image whose size changed. It runs
// on the main thread before the frame is presented and holds no lock. A failed
// write is reported once and never stops the frame; the image stays pending or
// keeps its old size, so the next frame tries it again while its entry exists.
images_sync :: proc(app: ^App, storage: ^Frame_Storage) {
	for id in storage.stale {
		_, delete_error := term.graphics_delete(app.terminal, id, context.temp_allocator)
		images_report(app, storage, delete_error)
		if index := image_placement_find(storage.placed[:], id); index >= 0 { unordered_remove(&storage.placed, index) }
	}
	for shown in storage.shown {
		index := image_upload_find(storage.uploads[:], shown.id)
		if index < 0 { continue }
		upload := storage.uploads[index]
		image := term.Image {
			data   = upload.pixels[:],
			format = upload.format,
			width  = upload.width,
			height = upload.height,
		}
		_, transmit_error := term.graphics_transmit(app.terminal, shown.id, image, shown.columns, shown.rows, context.temp_allocator)
		images_report(app, storage, transmit_error)
		if transmit_error != nil { continue }
		if _, append_error := append(&storage.placed, shown); append_error != nil { continue }
		delete(upload.pixels)
		unordered_remove(&storage.uploads, index)
	}
	for shown in storage.shown {
		index := image_placement_find(storage.placed[:], shown.id)
		if index < 0 || storage.placed[index] == shown { continue }
		_, place_error := term.graphics_place(app.terminal, shown.id, shown.columns, shown.rows, context.temp_allocator)
		images_report(app, storage, place_error)
		if place_error == nil { storage.placed[index] = shown }
	}
}

// images_report says once that a terminal image write failed. The text of the
// result stays in the box, so nothing is lost.
images_report :: proc(app: ^App, storage: ^Frame_Storage, err: term.Error) {
	if err == nil || storage.graphics_failed { return }
	storage.graphics_failed = true
	snap_append(app, .Warning, fmt.tprintf("an image could not be sent to the terminal: %v", err))
}
