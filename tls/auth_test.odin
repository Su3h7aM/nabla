#+test
package tls

import "core:testing"

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
