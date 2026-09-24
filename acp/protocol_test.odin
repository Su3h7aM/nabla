#+test
#+private file
package acp

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
	for c in invalid_cases {
		_, err := parse_envelope(c.wire)
		testing.expectf(t, err == c.err, "envelope %q: expected %v, got %v", c.wire, c.err, err)
	}
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
test_batch_parser_rejects_too_many_entries :: proc(t: ^testing.T) {
	builder, builder_error := strings.builder_make(context.allocator)
	if builder_error != nil { testing.fail_now(t, "the batch could not be built") }
	defer strings.builder_destroy(&builder)
	strings.write_byte(&builder, '[')
	for i := 0; i <= MAX_BATCH_ENTRIES; i += 1 {
		if i > 0 { strings.write_byte(&builder, ',') }
		strings.write_string(&builder, `{"jsonrpc":"2.0","method":"session/cancel"}`)
	}
	strings.write_byte(&builder, ']')
	_, is_batch, batch_err := parse_batch(strings.to_string(builder), context.allocator)
	testing.expect(t, is_batch)
	testing.expect_value(t, batch_err, Envelope_Error.Invalid_Envelope)
}
