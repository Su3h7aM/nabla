#+test
#+private
package http

import "core:mem"

Test_Failing_Allocator :: struct {
	backing:     mem.Allocator,
	allocations: int,
	fail_at:     int,
}

test_failing_allocator :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	state := cast(^Test_Failing_Allocator)data
	if mode == .Alloc || mode == .Alloc_Non_Zeroed || ((mode == .Resize || mode == .Resize_Non_Zeroed) && size > old_size) {
		state.allocations += 1
		if state.fail_at > 0 && state.allocations >= state.fail_at { return nil, .Out_Of_Memory }
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, location)
}
