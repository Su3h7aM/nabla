#+build linux
#+test
#+private file
package tui

import "core:testing"

@(test)
test_init_validates_and_initializes :: proc(t: ^testing.T) {
	storage: [12]Cell
	buffer: Cell_Buffer
	base := Style {
		foreground = Indexed_Color(3),
	}
	testing.expect(t, init(&buffer, 4, 3, storage[:], base), "init must accept sufficient storage")
	testing.expect_value(t, len(buffer.cells), 12)
	for cell in buffer.cells {
		testing.expect_value(t, cell, Cell{grapheme = " ", style = base})
	}

	// Insufficient storage and negative extents are refused.
	small_storage: [4]Cell
	small_buffer: Cell_Buffer
	testing.expect(t, !init(&small_buffer, 3, 3, small_storage[:]), "undersized storage must be refused")
	testing.expect(t, !init(&small_buffer, -1, 2, small_storage[:]), "negative extents must be refused")

	// Hostile dimensions are refused without mutating the buffer or storage.
	hostile_storage := [?]Cell{{grapheme = "a"}, {grapheme = "b"}}
	original := hostile_storage
	hostile_buffer := Cell_Buffer {
		width  = 1,
		height = 1,
		cells  = hostile_storage[:1],
	}
	testing.expect(t, !init(&hostile_buffer, max(int), 2, hostile_storage[:]), "overflowing dimensions must be refused")
	testing.expect_value(t, hostile_buffer.width, 1)
	testing.expect_value(t, hostile_buffer.height, 1)
	testing.expect_value(t, len(hostile_buffer.cells), 1)
	testing.expect_value(t, hostile_storage, original)
	testing.expect(t, !init(nil, 1, 1, hostile_storage[:]), "a nil buffer must be refused")

	// A zero-width grid is legal and leaves the storage untouched.
	zero_storage := [?]Cell{{grapheme = "kept"}}
	zero_buffer: Cell_Buffer
	testing.expect(t, init(&zero_buffer, 0, max(int), zero_storage[:]), "a zero-width grid is legal")
	testing.expect_value(t, zero_buffer.width, 0)
	testing.expect_value(t, zero_buffer.height, max(int))
	testing.expect_value(t, len(zero_buffer.cells), 0)
	testing.expect_value(t, zero_storage[0].grapheme, "kept")
}

@(test)
test_put_is_bounds_checked :: proc(t: ^testing.T) {
	storage: [6]Cell
	buffer: Cell_Buffer
	_ = init(&buffer, 3, 2, storage[:])
	testing.expect(t, put(&buffer, 2, 1, {grapheme = "z"}))
	testing.expect_value(t, buffer.cells[5].grapheme, "z")
	testing.expect(t, !put(&buffer, 3, 0, {grapheme = "z"}))
	testing.expect(t, !put(&buffer, 0, 2, {grapheme = "z"}))
	testing.expect(t, !put(&buffer, -1, 0, {grapheme = "z"}))
}
