#+test
#+private file
package acp

import "base:runtime"
import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"

@(test)
test_envelope_kinds_and_validation :: proc(t: ^testing.T) {
	request, request_err := parse_envelope("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"prompt\",\"params\":{}}")
	testing.expect_value(t, request_err, Envelope_Error.None)
	testing.expect_value(t, request.kind, Envelope_Kind.Request)
	testing.expect(t, request.id_present)
	destroy_envelope(&request)

	notification, notification_err := parse_envelope("{\"jsonrpc\":\"2.0\",\"method\":\"cancel\"}")
	testing.expect_value(t, notification_err, Envelope_Error.None)
	testing.expect_value(t, notification.kind, Envelope_Kind.Notification)
	destroy_envelope(&notification)

	response, response_err := parse_envelope("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":null}")
	testing.expect_value(t, response_err, Envelope_Error.None)
	testing.expect_value(t, response.kind, Envelope_Kind.Response)
	testing.expect(t, response.result_present)
	destroy_envelope(&response)

	null_request, null_request_err := parse_envelope("{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"ping\"}")
	testing.expect_value(t, null_request_err, Envelope_Error.None)
	testing.expect(t, null_request.id_present)
	destroy_envelope(&null_request)

	// Malformed envelopes are classified rather than accepted.
	invalid_cases := []struct {
		wire: string,
		err:  Envelope_Error,
	} {
		{"not-json", .Invalid_JSON},
		{"{\"jsonrpc\":\"1.0\",\"method\":\"x\"}", .Invalid_Version},
		{"{\"jsonrpc\":\"2.0\",\"id\":\"abc\"}", .Invalid_Result},
		{"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":1,\"error\":{}}", .Invalid_Result},
	}
	for invalid_case in invalid_cases {
		_, err := parse_envelope(invalid_case.wire)
		testing.expectf(t, err == invalid_case.err, "envelope %q: expected %v, got %v", invalid_case.wire, invalid_case.err, err)
	}
}

@(test)
test_prompt_params_decode_reads_blob_metadata_without_copying_payload :: proc(t: ^testing.T) {
	envelope, envelope_err := parse_envelope(
		`{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"sessionId":"s","prompt":[{"type":"resource","resource":{"uri":"file:///a.bin","mimeType":"application/octet-stream","blob":"YWJj"}}]}}`,
		context.allocator,
	)
	if envelope_err != .None { testing.fail_now(t, "the prompt envelope could not be parsed") }
	defer destroy_envelope(&envelope, context.allocator)

	params: Session_Prompt_Params
	failed_params: Session_Prompt_Params
	testing.expect_value(
		t,
		session_prompt_params_decode(envelope.params, &failed_params, mem.Allocator{procedure = acp_protocol_test_fail_allocate}),
		Params_Error.Allocation,
	)
	testing.expect_value(t, session_prompt_params_decode(envelope.params, &params, context.allocator), Params_Error.None)
	defer delete(params.prompt, context.allocator)
	testing.expect_value(t, params.session_id, "s")
	if !testing.expect_value(t, len(params.prompt), 1) { return }
	testing.expect(t, params.prompt[0].resource.blob_present)
	testing.expect_value(t, params.prompt[0].resource.uri, "file:///a.bin")
	testing.expect_value(t, params.prompt[0].resource.mime_type, "application/octet-stream")
}

@(test)
test_json_allocation_failures_are_not_invalid_json_or_params :: proc(t: ^testing.T) {
	allocator := mem.Allocator {
		procedure = acp_protocol_test_fail_allocate,
	}
	_, envelope_err := parse_envelope(`{"jsonrpc":"2.0","method":"cancel"}`, allocator)
	testing.expect_value(t, envelope_err, Envelope_Error.Allocation)

	_, is_batch, batch_err := parse_batch(`[{"jsonrpc":"2.0","method":"cancel"}]`, allocator)
	testing.expect(t, is_batch)
	testing.expect_value(t, batch_err, Envelope_Error.Allocation)

	value, parse_err := json.parse_string(`{"sessionId":"s"}`, .JSON, true, context.allocator)
	if parse_err != nil { testing.fail_now(t, "the params JSON could not be parsed") }
	defer json.destroy_value(value, context.allocator)
	params: Session_Load_Params
	testing.expect_value(t, params_decode(value, &params, allocator), Params_Error.Allocation)
}

acp_protocol_test_fail_allocate :: proc(
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

@(test)
test_batch_parser_preserves_entries_and_rejects_empty_batches :: proc(t: ^testing.T) {
	frames, is_batch, batch_err := parse_batch(
		`[{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}},{"jsonrpc":"2.0","method":"session/cancel"}]`,
		context.allocator,
	)
	testing.expect(t, is_batch)
	testing.expect_value(t, batch_err, Envelope_Error.None)
	defer {
		for frame in frames { delete(frame, context.allocator) }
		delete(frames)
	}
	testing.expect_value(t, len(frames), 2)

	_, empty_batch, empty_err := parse_batch(`[]`, context.allocator)
	testing.expect(t, empty_batch)
	testing.expect_value(t, empty_err, Envelope_Error.Invalid_Envelope)
}

@(test)
test_batch_parser_accepts_many_entries :: proc(t: ^testing.T) {
	MANY_ENTRIES :: 4096
	builder, builder_error := strings.builder_make(context.allocator)
	if builder_error != nil { testing.fail_now(t, "the batch could not be built") }
	defer strings.builder_destroy(&builder)
	strings.write_byte(&builder, '[')
	for i in 0 ..< MANY_ENTRIES {
		if i > 0 { strings.write_byte(&builder, ',') }
		strings.write_string(&builder, `{"jsonrpc":"2.0","method":"session/cancel"}`)
	}
	strings.write_byte(&builder, ']')
	frames, is_batch, batch_err := parse_batch(strings.to_string(builder), context.allocator)
	defer {
		for frame in frames { delete(frame, context.allocator) }
		delete(frames)
	}
	testing.expect(t, is_batch)
	testing.expect_value(t, batch_err, Envelope_Error.None)
	testing.expect_value(t, len(frames), MANY_ENTRIES)
}
