#+test
#+private file
package http

import "core:mem"
import "core:testing"

@(test)
test_body_url_encoded_frees_decoded_key_when_value_fails :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	queries, ok := body_url_encoded("key%20with%20space=%", allocator)
	delete(queries)
	if !testing.expect(t, !ok, "an invalid percent escape was accepted") { return }
	for _, entry in track.allocation_map {
		testing.expectf(t, false, "the decoder leaked %d bytes allocated at %v", entry.size, entry.location)
	}
}
