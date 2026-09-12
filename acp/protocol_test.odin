#+test
#+private file
package acp

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

	// Malformed envelopes are classified rather than accepted.
	invalid_cases := []struct {
		wire: string,
		err:  Envelope_Error,
	} {
		{"not-json", .Invalid_JSON},
		{"{\"jsonrpc\":\"1.0\",\"method\":\"x\"}", .Invalid_Version},
		{"{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"x\"}", .Invalid_ID},
		{"{\"jsonrpc\":\"2.0\",\"id\":\"abc\"}", .Invalid_Result},
		{"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":1,\"error\":{}}", .Invalid_Result},
	}
	for c in invalid_cases {
		_, err := parse_envelope(c.wire)
		testing.expectf(t, err == c.err, "envelope %q: expected %v, got %v", c.wire, c.err, err)
	}
}
