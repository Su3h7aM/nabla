package tls

// OFFERED_SUITES is what this client offers, in preference order: the mandatory
// suite first (RFC 8446 section 9.1).
OFFERED_SUITES := [3]Cipher_Suite{.AES_128_GCM_SHA256, .CHACHA20_POLY1305_SHA256, .AES_256_GCM_SHA384}

// OFFERED_SIGNATURE_SCHEMES is what this client can verify, and offering one it
// cannot is what a server would then sign with.
OFFERED_SIGNATURE_SCHEMES := [6]Signature_Scheme {
	.ECDSA_SECP256R1_SHA256,
	.ECDSA_SECP384R1_SHA384,
	.RSA_PSS_RSAE_SHA256,
	.RSA_PSS_RSAE_SHA384,
	.RSA_PSS_RSAE_SHA512,
	.ED25519,
}

// Client_Hello_Fields is what a caller decides about the ClientHello it sends: the
// name it is reaching, the protocols it speaks over TLS, and the ephemeral key
// share whose private half stays with the caller.
//
// A server_name that is an address literal is not a name, and SNI carries no
// address literals (RFC 6066 section 3), so a caller reaching a peer by address
// leaves it empty.
//
// A cookie is what a HelloRetryRequest gave, and a second ClientHello repeats it
// (RFC 8446 section 4.2.2).
Client_Hello_Fields :: struct {
	random:      [32]u8,
	session_id:  []u8,
	server_name: string,
	alpn:        []string,
	group:       Named_Group,
	keyshare:    []u8,
	cookie:      []u8,
}

// client_hello_encode writes a ClientHello (RFC 8446 section 4.1.2) and returns
// how many bytes of `dst` it used.
@(require_results)
client_hello_encode :: proc(dst: []u8, fields: Client_Hello_Fields) -> (count: int, ok: bool) {
	writer := Writer {
		dst = dst,
		ok  = true,
	}
	random := fields.random
	write_u16(&writer, LEGACY_VERSION)
	write_bytes(&writer, random[:])
	write_u8(&writer, len(fields.session_id))
	write_bytes(&writer, fields.session_id)

	suites := write_section_start(&writer)
	for suite in OFFERED_SUITES { write_u16(&writer, int(suite)) }
	write_section_end(&writer, suites)

	// legacy_compression_methods: the null compression, and nothing else
	// (RFC 8446 section 4.1.2).
	write_u8(&writer, 1)
	write_u8(&writer, 0)

	extensions := write_section_start(&writer)
	if fields.server_name != "" { write_server_name(&writer, fields.server_name) }
	write_supported_versions(&writer)
	write_supported_groups(&writer)
	write_signature_algorithms(&writer)
	write_key_share(&writer, fields)
	if len(fields.alpn) > 0 { write_alpn(&writer, fields.alpn) }
	if len(fields.cookie) > 0 { write_cookie(&writer, fields.cookie) }
	write_section_end(&writer, extensions)

	return writer.at, writer.ok
}

write_server_name :: proc(writer: ^Writer, server_name: string) {
	write_u16(writer, int(Extension_Type.Server_Name))
	extension := write_section_start(writer)
	list := write_section_start(writer)
	write_u8(writer, 0) // NameType.host_name
	write_u16(writer, len(server_name))
	write_bytes(writer, transmute([]u8)server_name)
	write_section_end(writer, list)
	write_section_end(writer, extension)
}

write_supported_versions :: proc(writer: ^Writer) {
	write_u16(writer, int(Extension_Type.Supported_Versions))
	extension := write_section_start(writer)
	// A ClientHello carries the list of versions under a one-byte length, where a
	// ServerHello answers with a single version (RFC 8446 section 4.2.1).
	write_u8(writer, 2)
	write_u16(writer, VERSION_1_3)
	write_section_end(writer, extension)
}

// write_supported_groups offers every group this client can exchange a key with, which
// is what a server picks the key share it wants from (RFC 8446 section 4.2.7).
write_supported_groups :: proc(writer: ^Writer) {
	write_u16(writer, int(Extension_Type.Supported_Groups))
	extension := write_section_start(writer)
	groups := write_section_start(writer)
	for group in OFFERED_GROUPS { write_u16(writer, int(group)) }
	write_section_end(writer, groups)
	write_section_end(writer, extension)
}

// write_cookie repeats the cookie a HelloRetryRequest carried (RFC 8446 section 4.2.2).
write_cookie :: proc(writer: ^Writer, cookie: []u8) {
	write_u16(writer, int(Extension_Type.Cookie))
	extension := write_section_start(writer)
	write_u16(writer, len(cookie))
	write_bytes(writer, cookie)
	write_section_end(writer, extension)
}

write_signature_algorithms :: proc(writer: ^Writer) {
	write_u16(writer, int(Extension_Type.Signature_Algorithms))
	extension := write_section_start(writer)
	schemes := write_section_start(writer)
	for scheme in OFFERED_SIGNATURE_SCHEMES { write_u16(writer, int(scheme)) }
	write_section_end(writer, schemes)
	write_section_end(writer, extension)
}

write_key_share :: proc(writer: ^Writer, fields: Client_Hello_Fields) {
	write_u16(writer, int(Extension_Type.Key_Share))
	extension := write_section_start(writer)
	shares := write_section_start(writer)
	write_u16(writer, int(fields.group))
	write_u16(writer, len(fields.keyshare))
	write_bytes(writer, fields.keyshare)
	write_section_end(writer, shares)
	write_section_end(writer, extension)
}

write_alpn :: proc(writer: ^Writer, protocols: []string) {
	write_u16(writer, int(Extension_Type.Application_Layer_Protocol_Negotiation))
	extension := write_section_start(writer)
	list := write_section_start(writer)
	for protocol in protocols {
		write_u8(writer, len(protocol))
		write_bytes(writer, transmute([]u8)protocol)
	}
	write_section_end(writer, list)
	write_section_end(writer, extension)
}
