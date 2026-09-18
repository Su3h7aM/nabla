#+test
package websocket

import "core:encoding/base64"
import "core:testing"

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
