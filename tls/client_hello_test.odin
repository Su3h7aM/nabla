#+test
package tls

import "core:testing"

@(test)
test_client_hello_carries_what_the_caller_asked_for :: proc(t: ^testing.T) {
	fields := Client_Hello_Fields {
		session_id  = make([]u8, 32, context.temp_allocator),
		server_name = "example.test",
		alpn        = []string{"http/1.1"},
		group       = .X25519,
		keyshare    = make([]u8, 32, context.temp_allocator),
	}
	dst := make([]u8, 1024, context.temp_allocator)
	count, encoded := client_hello_encode(dst, fields)
	if !testing.expect(t, encoded) { return }

	// Walk the message back: a length that does not add up desynchronizes the
	// reader, which the extension set and the final position both report.
	r := Reader{data = dst[:count], ok = true}
	testing.expect_value(t, read_u16(&r), u16(LEGACY_VERSION))
	_ = read_bytes(&r, len(fields.random))
	testing.expect_value(t, len(read_bytes(&r, int(read_u8(&r)))), len(fields.session_id))
	testing.expect_value(t, len(read_section_u16(&r).data), 2 * len(OFFERED_SUITES))
	testing.expect_value(t, read_u8(&r), u8(1))
	testing.expect_value(t, read_u8(&r), u8(0))

	seen: bit_set[Extension_Type]
	extensions := read_section_u16(&r)
	for extensions.ok && extensions.at < len(extensions.data) {
		seen += {Extension_Type(read_u16(&extensions))}
		_ = read_section_u16(&extensions)
	}
	wanted := bit_set[Extension_Type] {
		.Server_Name,
		.Supported_Versions,
		.Supported_Groups,
		.Signature_Algorithms,
		.Key_Share,
		.Application_Layer_Protocol_Negotiation,
	}
	testing.expect(t, seen == wanted, "the ClientHello does not carry the extensions it should")
	testing.expect_value(t, r.at, count)
}
