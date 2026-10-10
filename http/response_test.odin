#+test
#+private file
package http

import "core:io"
import "core:mem"
import "core:testing"

@(test)
test_response_body_reports_allocation_failure :: proc(t: ^testing.T) {
	state := Test_Failing_Allocator {
		backing = context.allocator,
		fail_at = 1,
	}
	allocator := mem.Allocator {
		procedure = test_failing_allocator,
		data      = &state,
	}
	response: Response
	response_init(&response, allocator)
	defer delete(response._buf)
	defer headers_destroy(&response.headers)
	testing.expect(t, body_set_bytes(&response, []byte{'x'}) == .Out_Of_Memory)
	testing.expect(t, len(response._buf) == 0)
}

@(test)
test_response_writer_reports_buffer_growth_failure :: proc(t: ^testing.T) {
	state := Test_Failing_Allocator {
		backing = context.allocator,
	}
	allocator := mem.Allocator {
		procedure = test_failing_allocator,
		data      = &state,
	}
	server_thread: Server_Thread
	previous_thread := current_thread
	current_thread = &server_thread
	defer current_thread = previous_thread
	connection: Connection
	response: Response
	response_init(&response, allocator)
	response._conn = &connection
	defer delete(response._buf)
	defer headers_destroy(&response.headers)
	writer: Response_Writer
	output, init_err := response_writer_init(&writer, &response, nil)
	if !testing.expect(t, init_err == nil) { return }
	state.fail_at = state.allocations + 1
	content: [1024]byte
	_, write_err := io.write(output, content[:])
	testing.expect_value(t, write_err, io.Error.Short_Write)
}
