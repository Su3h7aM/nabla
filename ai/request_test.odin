#+test
package ai

import "core:strings"
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

// A cache decides how much of a request is written again, never what is written: a
// request that repeats a conversation, one that extends it, and one whose middle changed
// all encode to the bytes the same request encodes to with no cache.
// expect_encode_agrees checks that the body encoded through a cache is the body encoded
// without one, for the request as it stands now. Reuse is an accelerator: it may never
// change what is sent, and a slot that answered for another text could only be caught by a
// reader that compares the two bodies byte for byte.
@(private)
expect_encode_agrees :: proc(t: ^testing.T, request: Provider_Request, cache: ^Provider_Encode_Cache) {
	reused, reused_err := Provider_Encode_Request_Reusing(request, cache, context.temp_allocator)
	fresh, fresh_err := Provider_Encode_Request(request, context.temp_allocator)
	if !testing.expect_value(t, reused_err, Provider_Request_Error.None) { return }
	if !testing.expect_value(t, fresh_err, Provider_Request_Error.None) { return }
	testing.expect_value(t, reused, fresh)
}

@(test)
test_encode_cache_writes_what_the_request_says :: proc(t: ^testing.T) {
	tools := []Provider_Tool_Def {
		{
			Name = "shell",
			Description = "Run a command.",
			Parameters_JSON = `{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}`,
		},
	}
	// An endpoint record, which carries a field the input schema has no place for.
	record := `[{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"one"}]}]`
	messages := []Provider_Message {
		{Role = .User, Content = "first", Cache_Breakpoint = true},
		{Role = .Assistant, Tool_Calls = []Provider_Tool_Call{{ID = "call_a", Item_ID = "fc_1", Name = "shell", Arguments = `{"command":"pwd"}`}}},
		{Role = .Tool, Content = "workspace", Tool_Call_ID = "call_a"},
		{Verbatim_Items = record},
	}
	request := Provider_Request {
		API                       = .OpenAI_Responses,
		Model_Present             = true,
		Model                     = "cache-model",
		Instructions_Present      = true,
		Instructions              = "Be brief.",
		Messages_Present          = true,
		Messages                  = messages,
		Tools                     = tools,
		Max_Output_Tokens_Present = true,
		Max_Output_Tokens         = 128,
	}

	cache: Provider_Encode_Cache
	defer Provider_Encode_Cache_Destroy(&cache)
	expect_encode_agrees(t, request, &cache)
	expect_encode_agrees(t, request, &cache)

	grown_messages := make([]Provider_Message, len(messages) + 1, context.temp_allocator)
	copy(grown_messages, messages)
	grown_messages[len(messages)] = Provider_Message {
		Role    = .Assistant,
		Content = "an answer",
	}
	grown := request
	grown.Messages = grown_messages
	expect_encode_agrees(t, grown, &cache)

	// A call the harness repaired is replayed with its repair, which changes one message
	// and leaves every message after it as it was.
	changed_messages := make([]Provider_Message, len(messages), context.temp_allocator)
	copy(changed_messages, messages)
	changed_messages[1].Tool_Calls = []Provider_Tool_Call{{ID = "call_a", Item_ID = "fc_1", Name = "shell", Arguments = `{"command":"ls"}`}}
	changed := request
	changed.Messages = changed_messages
	expect_encode_agrees(t, changed, &cache)

	// Bytes answer for the text they were written for, not for the storage they were read
	// from: a record whose bytes changed in place, at the same address and the same
	// length, is read again.
	record_buffer := make([]u8, len(record), context.temp_allocator)
	copy(record_buffer, record)
	in_place_messages := make([]Provider_Message, len(messages), context.temp_allocator)
	copy(in_place_messages, messages)
	in_place_messages[3].Verbatim_Items = string(record_buffer)
	in_place := request
	in_place.Messages = in_place_messages
	expect_encode_agrees(t, in_place, &cache)
	replaced, _ := strings.replace_all(record, "one", "two", context.temp_allocator)
	copy(record_buffer, replaced)
	expect_encode_agrees(t, in_place, &cache)
}

// The Messages API carries the same conversation in a different shape: the instruction lane
// is its own field, tool calls are content blocks whose arguments are an object, and a call
// whose arguments are not one is replayed with an empty object. Its cache is walked the
// same way, so the same scenarios hold for it.
@(test)
test_anthropic_encode_cache_writes_what_the_request_says :: proc(t: ^testing.T) {
	tools := []Provider_Tool_Def {
		{
			Name = "shell",
			Description = "Run a command.",
			Parameters_JSON = `{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}`,
		},
	}
	messages := []Provider_Message {
		{Role = .User, Content = "first"},
		{Role = .Assistant, Content = "an answer"},
		{
			Role = .Assistant,
			Tool_Calls = []Provider_Tool_Call {
				{ID = "call_a", Name = "shell", Arguments = `{"command":"pwd"}`},
				{ID = "call_b", Name = "shell", Arguments = `not an object`},
			},
		},
		{Role = .Tool, Content = "workspace", Tool_Call_ID = "call_a"},
		{Role = .Tool, Content = "the call was refused", Tool_Call_ID = "call_b", Tool_Is_Error = true},
	}
	request := Provider_Request {
		API                       = .Anthropic_Messages,
		Model_Present             = true,
		Model                     = "cache-model",
		Instructions_Present      = true,
		Instructions              = "Be brief.",
		Messages_Present          = true,
		Messages                  = messages,
		Tools                     = tools,
		Max_Output_Tokens_Present = true,
		Max_Output_Tokens         = 128,
		Cache_Request_Present     = true,
		Cache_Request             = true,
	}

	cache: Provider_Encode_Cache
	defer Provider_Encode_Cache_Destroy(&cache)
	// The call whose arguments are not an object is answered from the slot that read it, so
	// the same request twice must still write the same empty object.
	expect_encode_agrees(t, request, &cache)
	expect_encode_agrees(t, request, &cache)

	grown_messages := make([]Provider_Message, len(messages) + 1, context.temp_allocator)
	copy(grown_messages, messages)
	grown_messages[len(messages)] = Provider_Message {
		Role    = .Assistant,
		Content = "another answer",
	}
	grown := request
	grown.Messages = grown_messages
	expect_encode_agrees(t, grown, &cache)

	// A call the harness repaired is replayed with its repair, which changes the object one
	// block carries and leaves the turns after it as they were.
	changed_messages := make([]Provider_Message, len(messages), context.temp_allocator)
	copy(changed_messages, messages)
	changed_messages[2].Tool_Calls = []Provider_Tool_Call {
		{ID = "call_a", Name = "shell", Arguments = `{"command":"ls"}`},
		{ID = "call_b", Name = "shell", Arguments = `not an object`},
	}
	changed := request
	changed.Messages = changed_messages
	expect_encode_agrees(t, changed, &cache)

	// Bytes answer for the text they were written for, not for the storage they were read
	// from: arguments whose bytes changed in place, at the same address and the same length,
	// are read again.
	arguments := `{"n":"aaa"}`
	arguments_buffer := make([]u8, len(arguments), context.temp_allocator)
	copy(arguments_buffer, arguments)
	in_place_messages := make([]Provider_Message, len(messages), context.temp_allocator)
	copy(in_place_messages, messages)
	in_place_calls := make([]Provider_Tool_Call, len(messages[2].Tool_Calls), context.temp_allocator)
	copy(in_place_calls, messages[2].Tool_Calls)
	in_place_calls[0].Arguments = string(arguments_buffer)
	in_place_messages[2].Tool_Calls = in_place_calls
	in_place := request
	in_place.Messages = in_place_messages
	expect_encode_agrees(t, in_place, &cache)
	copy(arguments_buffer, `{"n":"bbb"}`)
	expect_encode_agrees(t, in_place, &cache)
}
