#+test
package mcp

import "core:mem"
import "core:testing"

@(test)
test_stdio_write_line_rejects_short_allocation_before_io :: proc(t: ^testing.T) {
	stdio: Stdio
	stdio.started = true
	stdio.allocator = mem.nil_allocator()
	stdio.out.allocator = mem.nil_allocator()

	err := stdio_write_line(&stdio, "request", {})
	defer error_destroy(&err, context.allocator)
	testing.expect_value(t, err.kind, Error_Kind.Out_Of_Memory)
	testing.expect_value(t, err.delivery, Delivery_State.Not_Delivered)
}
