#+test
package tls

import "core:crypto/hash"
import "core:testing"

// The trace's server flight is EncryptedExtensions, Certificate, CertificateVerify,
// and Finished, in one record, and these are their sizes in octets.
ENCRYPTED_EXTENSIONS_SIZE :: 40
CERTIFICATE_SIZE :: 445
CERTIFICATE_VERIFY_SIZE :: 136

@(test)
test_rfc_8448_certificate_list :: proc(t: ^testing.T) {
	message := vector(t, RFC8448_CERTIFICATE)
	certificates, ok := certificate_list_decode(message[HANDSHAKE_HEADER_SIZE:], context.temp_allocator)
	defer certificate_list_destroy(certificates, context.temp_allocator)
	if !testing.expect(t, ok) { return }
	if !testing.expect_value(t, len(certificates), 1) { return }

	// The entry's own length decides what x509 was handed: 432 bytes of DER.
	testing.expect_value(t, len(certificates[0].raw), 432)

	_, truncated_ok := certificate_list_decode(message[HANDSHAKE_HEADER_SIZE:len(message) - 1], context.temp_allocator)
	testing.expect(t, !truncated_ok, "a certificate list missing its last byte was accepted")
}

@(test)
test_rfc_8448_certificate_verify :: proc(t: ^testing.T) {
	certificates, decoded := certificate_list_decode(vector(t, RFC8448_CERTIFICATE)[HANDSHAKE_HEADER_SIZE:], context.temp_allocator)
	defer certificate_list_destroy(certificates, context.temp_allocator)
	if !testing.expect(t, decoded) { return }

	client_hello := vector(t, RFC8448_CLIENT_HELLO)
	server_hello := vector(t, RFC8448_SERVER_HELLO)
	flight := vector(t, RFC8448_SERVER_FLIGHT_PLAINTEXT)
	through_certificate := ENCRYPTED_EXTENSIONS_SIZE + CERTIFICATE_SIZE

	transcript := make([]u8, len(client_hello) + len(server_hello) + through_certificate, context.temp_allocator)
	at := copy(transcript, client_hello)
	at += copy(transcript[at:], server_hello)
	at += copy(transcript[at:], flight[:through_certificate])

	transcript_hash: [hash.MAX_DIGEST_SIZE]u8
	digest := hash.hash_bytes_to_buffer(.SHA256, transcript, transcript_hash[:])

	certificate_verify := flight[through_certificate:][:CERTIFICATE_VERIFY_SIZE]
	verified := certificate_verify_verify(certificate_verify[HANDSHAKE_HEADER_SIZE:], &certificates[0], digest)
	testing.expect(t, verified, "the trace's CertificateVerify did not verify")
}
