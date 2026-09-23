package mcp

import "base:runtime"
import "core:encoding/json"
import "core:mem"
import "core:testing"

@(test)
test_protocol_builders_report_allocation_failure :: proc(t: ^testing.T) {
	allocator := mem.Allocator {
		procedure = mcp_failing_allocate,
	}
	params, err := request_params_make(.V2026_07_28, allocator = allocator)
	testing.expect_value(t, err.kind, Error_Kind.Out_Of_Memory)
	testing.expect(t, params == nil, "a failed builder must not publish an empty object")
	defer error_destroy(&err, allocator)

	params, err = initialize_params_make(allocator)
	testing.expect_value(t, err.kind, Error_Kind.Out_Of_Memory)
	testing.expect(t, params == nil, "a failed handshake must not publish an empty object")
	error_destroy(&err, allocator)

	empty, empty_error := make(json.Object, 0, context.allocator)
	if empty_error != nil { testing.fail_now(t, "the empty test object could not be allocated") }
	line, encode_err := request_encode(METHOD_DISCOVER, empty, 1, allocator)
	testing.expect_value(t, encode_err.kind, Error_Kind.Out_Of_Memory)
	testing.expect_value(t, line, "")
	error_destroy(&encode_err, allocator)
}

mcp_failing_allocate :: proc(
	_: rawptr,
	_: mem.Allocator_Mode,
	_, _: int,
	_: rawptr,
	_: int,
	_: runtime.Source_Code_Location = #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	return nil, .Out_Of_Memory
}
