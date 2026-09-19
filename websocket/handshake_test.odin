#+test
package websocket

import "core:encoding/base64"
import "core:fmt"
import "core:testing"

import "nabla:http"
import "nabla:http/client"

// The key and the answer to it are the ones RFC 6455 1.3 and 4.2.2 state.
@(test)
test_accept_key_is_the_hash_of_the_key_and_the_guid :: proc(t: ^testing.T) {
	accept := accept_key("dGhlIHNhbXBsZSBub25jZQ==")
	testing.expect_value(t, string(accept[:]), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
}

// A nonce is a fresh key every time, and the encoding decodes back to the octets the
// peer hashes.
@(test)
test_nonce_is_random_and_well_formed :: proc(t: ^testing.T) {
	first: [NONCE_ENCODED_SIZE]u8
	second: [NONCE_ENCODED_SIZE]u8
	key := nonce_generate(first[:])
	testing.expect_value(t, len(key), NONCE_ENCODED_SIZE)
	testing.expect(t, key != nonce_generate(second[:]), "two nonces are the same key")

	octets: [NONCE_SIZE]u8
	decoded, err := base64.decode_into_buf(octets[:], key)
	if !testing.expect(t, err == nil, "the nonce is not base64") { return }
	testing.expect_value(t, len(decoded), NONCE_SIZE)
}

@(test)
test_handshake_fields_owned_by_the_protocol_are_refused_from_callers :: proc(t: ^testing.T) {
	for name in ([]string{"upgrade", "Connection", "Sec-WebSocket-Key", "sec-websocket-version", "sec-websocket-extensions"}) {
		detail := handshake_headers_invalid([]client.Header{{name = name, value = "x"}})
		testing.expectf(t, detail != "", "%s was accepted from the caller", name)
	}
	testing.expect_value(t, handshake_headers_invalid([]client.Header{{name = "authorization", value = "Bearer x"}}), "")
}

@(test)
test_upgrade_response_selects_only_an_offered_protocol_and_no_extension :: proc(t: ^testing.T) {
	key := "dGhlIHNhbXBsZSBub25jZQ=="
	accept := accept_key(key)
	request_headers := []client.Header{{name = "sec-websocket-protocol", value = "chat.v1, chat.v2"}}

	accepted_headers: http.Headers
	http.headers_init(&accepted_headers, context.temp_allocator)
	accept_field := fmt.aprintf("sec-websocket-accept: %s", string(accept[:]), allocator = context.temp_allocator)
	for field in ([]string{"upgrade: websocket", "connection: Upgrade", accept_field, "sec-websocket-protocol: chat.v2"}) {
		_, ok := http.header_parse(&accepted_headers, field, context.temp_allocator)
		if !testing.expectf(t, ok, "%q was not a response field", field) { return }
	}
	accepted := client.Upgraded {
		headers = accepted_headers,
	}
	failure := response_accepts(&accepted, key, request_headers, context.temp_allocator)
	testing.expect_value(t, failure.kind, Dial_Error.None)

	unoffered_headers := accepted_headers
	http.headers_set_unsafe(&unoffered_headers, "sec-websocket-protocol", "chat.v3")
	unoffered := client.Upgraded {
		headers = unoffered_headers,
	}
	failure = response_accepts(&unoffered, key, request_headers, context.temp_allocator)
	testing.expect_value(t, failure.kind, Dial_Error.Response)

	extension_headers := accepted_headers
	http.headers_set_unsafe(&extension_headers, "sec-websocket-protocol", "chat.v2")
	http.headers_set_unsafe(&extension_headers, "sec-websocket-extensions", "permessage-deflate")
	extension := client.Upgraded {
		headers = extension_headers,
	}
	failure = response_accepts(&extension, key, request_headers, context.temp_allocator)
	testing.expect_value(t, failure.kind, Dial_Error.Response)
}
