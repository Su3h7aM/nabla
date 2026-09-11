#+test
#+private file
package layout

import "core:testing"

@(test)
test_identifiers_are_stable_and_scoped :: proc(t: ^testing.T) {
	// `id` and `id_index` are deterministic, so an identifier never changes
	// meaning between frames, call sites, or releases.
	testing.expect_value(t, id(""), Id(0xcbf29ce484222325))
	testing.expect_value(t, id("foobar"), Id(0x85944171f73967e8))
	testing.expect(t, id("a") != id("b"))
	testing.expect_value(t, id_index("row", 0), Id(0x50c22210c12b2efb))
	testing.expect(t, id_index("row", 0) != id_index("row", 1))

	// `id_local` folds in the declaration parent, so the same label under
	// different parents stays distinct and repeats frame to frame.
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	first, second: Id
	if frame(&ctx, {100, 100}) {
		if element(&ctx, {}) {
			first = id_local(&ctx, "button")
			content(&ctx, {id = first})
		}
		if element(&ctx, {}) {
			second = id_local(&ctx, "button")
			content(&ctx, {id = second})
		}
	}
	testing.expect(t, first != 0 && second != 0 && first != second)
	frame_result, err := result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	_, first_found := lookup(frame_result, first)
	_, second_found := lookup(frame_result, second)
	testing.expect(t, first_found && second_found)

	repeated: Id
	if frame(&ctx, {100, 100}) {
		if element(&ctx, {}) {
			repeated = id_local(&ctx, "button")
		}
	}
	testing.expect_value(t, repeated, first)
}
