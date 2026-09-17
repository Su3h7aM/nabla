#+test
package ai

import "core:testing"

// A frozen request holds the bytes a one-shot send would have produced, so a retry
// chain sends exactly them instead of a fresh encoding that has to be assumed
// equal.
@(test)
test_freeze_holds_the_bytes_a_send_would_produce :: proc(t: ^testing.T) {
	messages := make([]Provider_Message, 1, context.temp_allocator)
	messages[0] = Provider_Message {
		Role    = .User,
		Content = "hello",
	}
	request := Provider_Request {
		API              = .OpenAI_Chat_Completions,
		Model_Present    = true,
		Model            = "freeze-model",
		Messages_Present = true,
		Messages         = messages,
	}

	frozen, freeze_err := Provider_Request_Freeze(request, context.allocator)
	defer Provider_Operation_Error_Destroy(&freeze_err, context.allocator)
	defer delete(frozen.Body, context.allocator)
	if !testing.expect_value(t, freeze_err.kind, Provider_Operation_Error_Kind.None) { return }

	encoded, encode_err := Provider_Encode_Request(request, context.allocator)
	defer delete(encoded, context.allocator)
	if !testing.expect_value(t, encode_err, Provider_Request_Error.None) { return }
	testing.expect_value(t, string(frozen.Body), encoded)

	// What a frozen request carries beside its bytes is what an observer cannot read
	// back out of them.
	testing.expect_value(t, frozen.API, API_Kind.OpenAI_Chat_Completions)
	testing.expect_value(t, frozen.Model, "freeze-model")
	testing.expect_value(t, frozen.Tools, 0)
}

// A request that cannot be encoded yields the failure a one-shot send reports for
// it, and no body to release.
@(test)
test_freeze_refuses_an_invalid_request :: proc(t: ^testing.T) {
	frozen, freeze_err := Provider_Request_Freeze({API = .OpenAI_Chat_Completions}, context.allocator)
	defer Provider_Operation_Error_Destroy(&freeze_err, context.allocator)
	testing.expect_value(t, freeze_err.kind, Provider_Operation_Error_Kind.Invalid_Request)
	testing.expect(t, freeze_err.detail != "", "a refused request says why")
	testing.expect_value(t, len(frozen.Body), 0)
}
