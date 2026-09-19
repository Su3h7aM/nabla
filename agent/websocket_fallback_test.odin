#+test
package agent

import "core:testing"

import "nabla:ai"

// Fallback is a decision about facts, not about who the provider is: an endpoint whose
// WebSocket Upgrade is missing, refused, or unsupported may be served over HTTP instead,
// while a peer that was never trusted, a local misconfiguration, or anything that
// happened after model bytes may have been accepted may not.
@(test)
test_websocket_fallback_reads_facts_rather_than_identity :: proc(t: ^testing.T) {
	Cases :: struct {
		name:     string,
		err:      ai.Provider_Operation_Error,
		fallback: bool,
	}
	cases := []Cases {
		{"nothing reached the peer", {kind = .Transport, transport_cause = .Connection}, true},
		{"the peer closed before answering", {kind = .Transport, transport_cause = .IO}, true},
		{"the upgrade is unsupported", {kind = .HTTP, status = 426}, true},
		{"the endpoint has no such resource", {kind = .HTTP, status = 404}, true},
		{"the method is not allowed", {kind = .HTTP, status = 405}, true},
		{"the peer does not implement it", {kind = .HTTP, status = 501}, true},
		{"the peer was never trusted", {kind = .Transport, transport_cause = .Trust}, false},
		{"the local TLS setup is unusable", {kind = .Transport, transport_cause = .Configuration}, false},
		{"the peer refused the credential", {kind = .HTTP, status = 401}, false},
		{"the peer refused the request", {kind = .HTTP, status = 400}, false},
		{"the peer is rate limiting", {kind = .HTTP, status = 429}, false},
		{"the stream broke in the middle", {kind = .Stream}, false},
		{"a model send may have reached the peer", {kind = .Transport, transport_cause = .Connection, delivery = .Model_Send_Started}, false},
		{"a response was observed", {kind = .Transport, transport_cause = .IO, delivery = .Response_Observed}, false},
		{"the turn was cancelled", {kind = .Cancelled}, false},
	}
	for c in cases {
		testing.expectf(t, chat_websocket_fallback_safe(c.err) == c.fallback, "%s", c.name)
	}
}
