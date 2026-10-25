#+test
package ai

// Error diagnostics for one Responses WebSocket request: what the transport
// observed must reach the caller in the failure's cause and detail, through the
// real fixture rather than the request's own encoder.

import "core:strings"
import "core:testing"
import "core:time"

// A connection that ends before answering is a broken connection, not an unknown
// one: the transport cause says the exchange failed, and the detail names the
// WebSocket outcome that ended it.
@(test)
test_responses_websocket_error_silence_reports_broken_connection :: proc(t: ^testing.T) {
	fixture: Responses_WebSocket_Fixture
	if !responses_websocket_fixture_start(t, &fixture, .Silence) { return }
	defer responses_websocket_fixture_stop(t, &fixture)

	test_case, opened := responses_websocket_case_open(t, fixture.port)
	defer responses_websocket_case_destroy(&test_case)
	if !opened { return }

	observed: Transport_Observation
	outcome: Responses_WebSocket_Outcome
	responses_websocket_request_run(&test_case, &observed, &outcome)
	defer Provider_Operation_Error_Destroy(&outcome.error, context.allocator)

	testing.expect_value(t, outcome.error.kind, Provider_Operation_Error_Kind.Transport)
	testing.expect_value(t, outcome.error.transport_cause, Provider_Transport_Cause.IO)
	testing.expect_value(t, outcome.error.failure_class, Provider_Failure_Class.Provider_Unavailable)
	testing.expect(t, strings.contains(outcome.error.detail, "Closed"), outcome.error.detail)
	testing.expect_value(t, outcome.completions, 0)
}

// A peer that goes quiet is cut by the idle timeout it was given. The attempt fails
// as an incomplete stream, and the detail keeps both the configured bound and the
// WebSocket outcome that reported it.
@(test)
test_responses_websocket_error_idle_timeout_names_bound_and_cause :: proc(t: ^testing.T) {
	fixture: Responses_WebSocket_Fixture
	if !responses_websocket_fixture_start(t, &fixture, .Hold) { return }
	defer responses_websocket_fixture_stop(t, &fixture)

	test_case, opened := responses_websocket_case_open(t, fixture.port)
	defer responses_websocket_case_destroy(&test_case)
	if !opened { return }
	test_case.idle_timeout = 200 * time.Millisecond

	observed: Transport_Observation
	outcome: Responses_WebSocket_Outcome
	responses_websocket_request_run(&test_case, &observed, &outcome)
	defer Provider_Operation_Error_Destroy(&outcome.error, context.allocator)

	testing.expect_value(t, outcome.error.kind, Provider_Operation_Error_Kind.Stream)
	testing.expect_value(t, outcome.error.transport_cause, Provider_Transport_Cause.IO)
	testing.expect_value(t, outcome.error.failure_class, Provider_Failure_Class.Incomplete_Stream)
	testing.expect(t, strings.contains(outcome.error.detail, "no bytes were received"), outcome.error.detail)
	testing.expect(t, strings.contains(outcome.error.detail, "Idle_Timeout"), outcome.error.detail)
	testing.expect_value(t, outcome.completions, 0)
}
