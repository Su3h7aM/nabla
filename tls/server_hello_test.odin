#+test
package tls

import "core:testing"

// What openssl s_server sent in answer to a ClientHello that offered a key share for
// x25519 when it accepts secp256r1 alone: a HelloRetryRequest, then the ServerHello of
// the handshake the client repeated. A real peer's bytes are what the decoder is held to.
OPENSSL_HELLO_RETRY_REQUEST ::
	"020000540303cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2" +// 92 octets
	"c8a8339c20e509ccdd82392aadbfa6447506b734cd768cfd8fec09f4624a71d534f" +
	"f996a42130200000c002b00020304003300020017"

OPENSSL_RETRIED_SERVER_HELLO ::
	"020000970303a2b8550f7b8710d95f32ee763323fbba48de098aa22d36c0b068369" +// 155 octets
	"34c614fa420e509ccdd82392aadbfa6447506b734cd768cfd8fec09f4624a71d534" +
	"ff996a42130200004f002b000203040033004500170041045ba06def966d3a29d8de" +
	"4c82e710e63c8ee5ec71c6cc2a8c86b7470f37d27cbd7627a8c3c03c6742bec002c" +
	"b54fec7f2efcfdd876d1cd152be6bab93d07304d0"

@(test)
test_a_hello_retry_request_names_a_group_and_sends_no_share :: proc(t: ^testing.T) {
	hello, ok := server_hello_read(vector(t, OPENSSL_HELLO_RETRY_REQUEST))
	if !testing.expect(t, ok, "the answer to the ClientHello could not be read") { return }

	testing.expect(t, hello.retry, "the answer is not a HelloRetryRequest")
	testing.expect_value(t, hello.version, VERSION_1_3)
	expect_bytes(t, "the echoed session id", hello.session_id, vector(t, "e509ccdd82392aadbfa6447506b734cd768cfd8fec09f4624a71d534ff996a42"))
	testing.expect_value(t, hello.cipher_suite, Cipher_Suite.AES_256_GCM_SHA384)
	// The group to use in the second ClientHello, and no share: the retry names what it
	// wants rather than answering with a key.
	testing.expect_value(t, hello.group, Named_Group.SECP256R1)
	testing.expect_value(t, len(hello.keyshare), 0)
}

@(test)
test_the_retried_server_hello_answers_with_a_share_of_the_group_it_named :: proc(t: ^testing.T) {
	hello, ok := server_hello_read(vector(t, OPENSSL_RETRIED_SERVER_HELLO))
	if !testing.expect(t, ok, "the answer to the second ClientHello could not be read") { return }

	testing.expect(t, !hello.retry, "the second answer is a HelloRetryRequest")
	testing.expect_value(t, hello.group, Named_Group.SECP256R1)
	testing.expect_value(t, hello.keyshare[0], u8(4)) // an uncompressed point
	testing.expect_value(t, len(hello.keyshare), 65)
}
