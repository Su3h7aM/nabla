#+test
package tls

import "core:crypto/hash"
import "core:testing"

// The trace's server flight is EncryptedExtensions, Certificate, CertificateVerify,
// and Finished, in one record, and these are their sizes in octets.
ENCRYPTED_EXTENSIONS_SIZE :: 40
CERTIFICATE_SIZE :: 445
CERTIFICATE_VERIFY_SIZE :: 136
FINISHED_SIZE :: 36

@(test)
test_rfc_8448_certificate_list :: proc(t: ^testing.T) {
	message := vector(t, RFC8448_CERTIFICATE)
	chain, ok := certificate_chain_decode(message[HANDSHAKE_HEADER_SIZE:], context.temp_allocator)
	defer certificate_chain_destroy(&chain)
	if !testing.expect(t, ok) { return }
	if !testing.expect_value(t, len(chain.certificates), 1) { return }

	// The entry's own length decides what x509 was handed: 432 bytes of DER.
	testing.expect_value(t, len(chain.certificates[0].raw), 432)

	truncated, truncated_ok := certificate_chain_decode(message[HANDSHAKE_HEADER_SIZE:len(message) - 1], context.temp_allocator)
	defer certificate_chain_destroy(&truncated)
	testing.expect(t, !truncated_ok, "a certificate list missing its last byte was accepted")
}

// The two messages that authenticate the peer: the CertificateVerify signature, and
// the Finished that covers every handshake message before it.
@(test)
test_rfc_8448_server_flight_authenticates :: proc(t: ^testing.T) {
	chain, decoded := certificate_chain_decode(vector(t, RFC8448_CERTIFICATE)[HANDSHAKE_HEADER_SIZE:], context.temp_allocator)
	defer certificate_chain_destroy(&chain)
	if !testing.expect(t, decoded) { return }

	client_hello := vector(t, RFC8448_CLIENT_HELLO)
	server_hello := vector(t, RFC8448_SERVER_HELLO)
	flight := vector(t, RFC8448_SERVER_FLIGHT_PLAINTEXT)
	through_certificate := ENCRYPTED_EXTENSIONS_SIZE + CERTIFICATE_SIZE
	through_certificate_verify := through_certificate + CERTIFICATE_VERIFY_SIZE

	transcript := make([]u8, len(client_hello) + len(server_hello) + through_certificate_verify, context.temp_allocator)
	at := copy(transcript, client_hello)
	at += copy(transcript[at:], server_hello)
	at += copy(transcript[at:], flight[:through_certificate_verify])
	through_certificate_at := len(client_hello) + len(server_hello) + through_certificate

	// A CertificateVerify covers everything up to its own Certificate message, and
	// the Finished covers that signature too.
	certificate_hash: [hash.MAX_DIGEST_SIZE]u8
	digest := hash.hash_bytes_to_buffer(.SHA256, transcript[:through_certificate_at], certificate_hash[:])

	certificate_verify := flight[through_certificate:][:CERTIFICATE_VERIFY_SIZE]
	verified := certificate_verify_verify(certificate_verify[HANDSHAKE_HEADER_SIZE:], &chain.certificates[0], digest)
	testing.expect(t, verified, "the trace's CertificateVerify did not verify")

	finished_hash: [hash.MAX_DIGEST_SIZE]u8
	finished_digest := hash.hash_bytes_to_buffer(.SHA256, transcript, finished_hash[:])

	finished := flight[through_certificate_verify:][:FINISHED_SIZE]
	secret := vector(t, RFC8448_SERVER_HANDSHAKE_TRAFFIC_SECRET)
	finished_ok := finished_verify(.AES_128_GCM_SHA256, secret, finished_digest, finished[HANDSHAKE_HEADER_SIZE:])
	testing.expect(t, finished_ok, "the trace's Finished did not verify")
}
