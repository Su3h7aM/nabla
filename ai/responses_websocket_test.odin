#+test
package ai

import "core:encoding/json"
import "core:testing"

@(test)
test_responses_websocket_endpoint_preserves_authority_and_resource :: proc(t: ^testing.T) {
	cases := []struct {
		base: string,
		want: string,
		ok:   bool,
	} {
		{"https://api.openai.com/v1", "wss://api.openai.com/v1/responses", true},
		{"http://127.0.0.1:8080/v1/responses", "ws://127.0.0.1:8080/v1/responses", true},
		{"wss://example.test/api", "wss://example.test/api/responses", true},
		{"ftp://example.test", "", false},
	}
	for entry in cases {
		endpoint, ok := provider_websocket_endpoint(entry.base, context.temp_allocator)
		testing.expect_value(t, ok, entry.ok)
		testing.expect_value(t, endpoint, entry.want)
	}
}

@(test)
test_responses_websocket_freeze_builds_a_response_create_event :: proc(t: ^testing.T) {
	request := request_fixture()
	encoded, failure := Provider_Request_Freeze_WebSocket(request, context.temp_allocator)
	if !testing.expect_value(t, failure.kind, Provider_Operation_Error_Kind.None) { return }
	value, parse_err := json.parse(encoded.Body, .JSON, true, context.temp_allocator)
	if !testing.expect_value(t, parse_err, nil) { return }
	defer json.destroy_value(value, context.temp_allocator)
	object, ok := value.(json.Object)
	if !testing.expect(t, ok, "the frozen request is not an object") { return }
	event_type, present, valid := openai_value_string(object, "type")
	testing.expect(t, valid && present && event_type == "response.create")
	_, stream_present := object["stream"]
	testing.expect(t, !stream_present, "the frozen WebSocket request carried stream")
}
