#+test
package agent

import "core:testing"

import "nabla:ai"

// Fallback is a decision about what the peer did, not about who the peer is. A transport
// the operator requires is never substituted, and neither is one whose failure happened
// after model bytes may have been accepted.
@(test)
test_websocket_fallback_stops_at_trust_and_at_model_delivery :: proc(t: ^testing.T) {
	Cases :: struct {
		name:     string,
		err:      ai.Provider_Operation_Error,
		fallback: bool,
	}
	cases := []Cases {
		// Nothing reached the peer, or the peer said it has no WebSocket transport.
		{"nothing reached the peer", {kind = .Transport, transport_cause = .Connection}, true},
		{"the endpoint has no such resource", {kind = .HTTP, status = 404}, true},
		// A peer that was never trusted is not sent the same request over a transport it
		// would trust less, and a refusal is the peer's answer, not a missing capability.
		{"the peer was never trusted", {kind = .Transport, transport_cause = .Trust}, false},
		{"the peer refused the credential", {kind = .HTTP, status = 401}, false},
		// A write may have delivered the request, so a second send could be a second answer.
		{"a model send may have reached the peer", {kind = .Transport, transport_cause = .Connection, delivery = .Model_Send_Started}, false},
	}
	for c in cases {
		testing.expectf(t, chat_websocket_fallback_safe(c.err) == c.fallback, "%s", c.name)
	}
}
