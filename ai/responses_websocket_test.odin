#+test
package ai

import "core:testing"

@(test)
test_responses_websocket_endpoint_preserves_authority_and_resource :: proc(t: ^testing.T) {
	cases := []struct {
		base: string,
		want: string,
		ok:   bool,
	} {
		{"https://api.openai.com/v1", "wss://api.openai.com/v1/responses", true},
		{"https://api.openai.com/v1/responses", "wss://api.openai.com/v1/responses", true},
		{"http://127.0.0.1:8080/v1/", "ws://127.0.0.1:8080/v1/responses", true},
		{"wss://example.test/api", "wss://example.test/api/responses", true},
		// A query belongs after the resource path, not inside it.
		{"https://example.test/v1?api-version=1", "wss://example.test/v1/responses?api-version=1", true},
		{"ftp://example.test", "", false},
		{"not a url", "", false},
	}
	for entry in cases {
		endpoint, ok := provider_websocket_endpoint(entry.base, context.temp_allocator)
		testing.expect_value(t, ok, entry.ok)
		testing.expect_value(t, endpoint, entry.want)
	}
}
