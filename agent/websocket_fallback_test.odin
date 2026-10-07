#+test
package agent

import "core:testing"

import "nabla:ai"

// Fallback is a decision about what the peer did, not about who the peer is.
@(test)
test_websocket_fallback_stops_at_trust_and_at_model_delivery :: proc(t: ^testing.T) {
	Cases :: struct {
		name:     string,
		err:      ai.Provider_Operation_Error,
		fallback: bool,
	}
	cases := []Cases {
		{"nothing reached the peer", {kind = .Transport, transport_cause = .Connection}, true},
		{"the endpoint has no such resource", {kind = .HTTP, status = 404}, true},
		{"the peer was never trusted", {kind = .Transport, transport_cause = .Trust}, false},
		{"the peer refused the credential", {kind = .HTTP, status = 401}, false},
		{"a model send may have reached the peer", {kind = .Transport, transport_cause = .Connection, delivery = .Model_Send_Started}, false},
	}
	for c in cases {
		testing.expectf(t, chat_websocket_fallback_safe(c.err) == c.fallback, "%s", c.name)
	}
}
