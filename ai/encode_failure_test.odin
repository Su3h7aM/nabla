package ai

import "base:runtime"
import "core:mem"
import "core:testing"

@(test)
test_request_encoder_reports_allocation_failure :: proc(t: ^testing.T) {
	messages := make([]Provider_Message, 1, context.temp_allocator)
	messages[0] = Provider_Message {
		Role    = .User,
		Content = "hello",
	}
	request := Provider_Request {
		API              = .OpenAI_Chat_Completions,
		Model_Present    = true,
		Model            = "test-model",
		Messages_Present = true,
		Messages         = messages,
	}

	body, err := Provider_Encode_Request(request, mem.Allocator{procedure = encode_failing_allocate})
	testing.expect_value(t, err, Provider_Request_Error.Allocation)
	testing.expect_value(t, body, "")

	cache := Provider_Encode_Cache {
		allocator = mem.Allocator{procedure = encode_failing_allocate},
	}
	defer Provider_Encode_Cache_Destroy(&cache)
	body, err = Provider_Encode_Request_Reusing(request, &cache, context.temp_allocator)
	testing.expect_value(t, err, Provider_Request_Error.Allocation)
	testing.expect_value(t, body, "")
}

encode_failing_allocate :: proc(
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
