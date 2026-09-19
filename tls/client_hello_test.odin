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
	r := Reader {
		data = dst[:count],
		ok   = true,
	}
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

// A second ClientHello repeats the first with the cookie the retry carried, and it still
// offers every group this client can exchange a key with (RFC 8446 sections 4.1.4, 4.2.2,
// and 4.2.7).
@(test)
test_the_second_client_hello_repeats_the_cookie :: proc(t: ^testing.T) {
	cookie := []u8{0xde, 0xad, 0xbe, 0xef}
	share: [65]u8
	share[0] = 4 // an uncompressed secp256r1 point
	fields := Client_Hello_Fields {
		session_id = make([]u8, 32, context.temp_allocator),
		group      = .SECP256R1,
		keyshare   = share[:],
		cookie     = cookie,
	}
	dst := make([]u8, 1024, context.temp_allocator)
	count, encoded := client_hello_encode(dst, fields)
	if !testing.expect(t, encoded) { return }

	r := Reader {
		data = dst[:count],
		ok   = true,
	}
	_ = read_u16(&r)
	_ = read_bytes(&r, len(fields.random))
	_ = read_bytes(&r, int(read_u8(&r)))
	_ = read_section_u16(&r)
	_ = read_u8(&r)
	_ = read_u8(&r)

	repeated: []u8
	offered: int
	extensions := read_section_u16(&r)
	for extensions.ok && extensions.at < len(extensions.data) {
		extension_type := Extension_Type(read_u16(&extensions))
		extension := read_section_u16(&extensions)
		#partial switch extension_type {
		case .Cookie:
			repeated = read_bytes(&extension, int(read_u16(&extension)))
		case .Supported_Groups:
			list := read_section_u16(&extension)
			for list.ok && list.at < len(list.data) {
				group := Named_Group(read_u16(&list))
				if offered < len(OFFERED_GROUPS) {
					testing.expect_value(t, group, OFFERED_GROUPS[offered])
				} else {
					testing.expect(t, false, "the second ClientHello offers more groups than this client has")
				}
				offered += 1
			}
		case:
		}
	}

	testing.expect_value(t, offered, len(OFFERED_GROUPS))
	testing.expect_value(t, len(repeated), len(cookie))
	for octet, at in cookie {
		testing.expect_value(t, repeated[at], octet)
	}
}
