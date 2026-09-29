#+test
package ai

import "core:testing"

@(test)
test_chat_stream_error_uses_error_type_fallback :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Chat_Completions, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)

	err := Provider_Consume_SSE_Data(`{"error":{"code":"unknown_code","type":"server_error","message":"provider failed"}}`, &state)
	if !testing.expect_value(t, err, Provider_Stream_Error.None) { return }
	event, drained := Provider_Stream_Drain(&state)
	if !testing.expect(t, drained) { return }
	defer Provider_Event_Destroy(&event, context.temp_allocator)
	failure, is_failure := event.(Provider_Error_Event)
	if !testing.expect(t, is_failure) { return }
	class := provider_classify_failure(
		Provider_Evidence {
			api = .OpenAI_Chat_Completions,
			kind = .Stream,
			event = failure.Kind,
			rejection = {code = failure.Provider_Code, message = failure.Message},
		},
	)
	testing.expect_value(t, class, Provider_Failure_Class.Provider_Unavailable)
}
