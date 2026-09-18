#+test
package tls

import "core:testing"

// The trace's certificate, as a trust store would carry it.
RFC8448_CERTIFICATE_PEM : string : `-----BEGIN CERTIFICATE-----
MIIBrDCCARWgAwIBAgIBAjANBgkqhkiG9w0BAQsFADAOMQwwCgYDVQQDEwNyc2Ew
HhcNMTYwNzMwMDEyMzU5WhcNMjYwNzMwMDEyMzU5WjAOMQwwCgYDVQQDEwNyc2Ew
gZ8wDQYJKoZIhvcNAQEBBQADgY0AMIGJAoGBALS7SY+CeTA9mAg2OZs2xpiMDGje
VeG9uCbTkBokYer9LeSakdAVq7yalRN6zmwa8Z6qavmMfO1DEgmY4YeoDuDMsFJL
GwGMPgtjJk1Emm044ipf2kMIRnSAMFMO8EYcjKnZ77+ujqbR0D4r0ZPv8KuagALE
dCim01qNiNeffx4/AgMBAAGjGjAYMAkGA1UdEwQCMAAwCwYDVR0PBAQDAgWgMA0G
CSqGSIb3DQEBCwUAA4GBAIWq0qDluSdrkIxl9zpyZxcGGKVMX4p7M30t96WUNlQX
8uro+KWMj4Fy+TGc82t/1sVbgPIaAwFRVnJglv0zXl5n8tvxAnAuYIzK5r7B/GOk
Kpm+XD63EHw8VOm56yvVIDscO4TgqLL3WUCbo+rJ2R1ALcwMyPiWEimskYe0K03h
-----END CERTIFICATE-----
`

// A Certificate message carries its DER after the handshake header, the context
// byte, and the two lengths, and here that DER is 432 octets.
CERTIFICATE_DER_OFFSET :: HANDSHAKE_HEADER_SIZE + 1 + 3 + 3
CERTIFICATE_DER_SIZE :: 432

@(test)
test_roots_parse_reads_the_certificate_a_store_carries :: proc(t: ^testing.T) {
	roots, ok := roots_parse(transmute([]u8)RFC8448_CERTIFICATE_PEM, context.temp_allocator)
	defer roots_destroy(&roots)
	if !testing.expect(t, ok) { return }
	if !testing.expect_value(t, len(roots.certificates), 1) { return }

	message := vector(t, RFC8448_CERTIFICATE)
	der := message[CERTIFICATE_DER_OFFSET:][:CERTIFICATE_DER_SIZE]
	expect_bytes(t, "certificate", roots.certificates[0].raw, der)

	empty, empty_ok := roots_parse({}, context.temp_allocator)
	defer roots_destroy(&empty)
	testing.expect(t, !empty_ok, "empty text was accepted as a trust store")
}
