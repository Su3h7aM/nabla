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
client_hello_encode :: proc(dst: []u8, fields: Client_Hello_Fields) -> (n: int, ok: bool) {
	w := Writer{dst = dst, ok = true}
	random := fields.random
	write_u16(&w, LEGACY_VERSION)
	write_bytes(&w, random[:])
	write_u8(&w, len(fields.session_id))
	write_bytes(&w, fields.session_id)

	suites := write_section_start(&w)
	for suite in OFFERED_SUITES { write_u16(&w, int(suite)) }
	write_section_end(&w, suites)

	// legacy_compression_methods: the null compression, and nothing else
	// (RFC 8446 section 4.1.2).
	write_u8(&w, 1)
	write_u8(&w, 0)

	extensions := write_section_start(&w)
	if fields.server_name != "" { write_server_name(&w, fields.server_name) }
	write_supported_versions(&w)
	write_supported_groups(&w)
	write_signature_algorithms(&w)
	write_key_share(&w, fields)
	if len(fields.alpn) > 0 { write_alpn(&w, fields.alpn) }
	if len(fields.cookie) > 0 { write_cookie(&w, fields.cookie) }
	write_section_end(&w, extensions)

	return w.at, w.ok
}

write_server_name :: proc(w: ^Writer, server_name: string) {
	write_u16(w, int(Extension_Type.Server_Name))
	extension := write_section_start(w)
	list := write_section_start(w)
	write_u8(w, 0)  // NameType.host_name
	write_u16(w, len(server_name))
	write_bytes(w, transmute([]u8)server_name)
	write_section_end(w, list)
	write_section_end(w, extension)
}

write_supported_versions :: proc(w: ^Writer) {
	write_u16(w, int(Extension_Type.Supported_Versions))
	extension := write_section_start(w)
	// A ClientHello carries the list of versions under a one-byte length, where a
	// ServerHello answers with a single version (RFC 8446 section 4.2.1).
	write_u8(w, 2)
	write_u16(w, VERSION_1_3)
	write_section_end(w, extension)
}

// write_supported_groups offers every group this client can exchange a key with, which
// is what a server picks the key share it wants from (RFC 8446 section 4.2.7).
write_supported_groups :: proc(w: ^Writer) {
	write_u16(w, int(Extension_Type.Supported_Groups))
	extension := write_section_start(w)
	groups := write_section_start(w)
	for group in OFFERED_GROUPS { write_u16(w, int(group)) }
	write_section_end(w, groups)
	write_section_end(w, extension)
}

// write_cookie repeats the cookie a HelloRetryRequest carried (RFC 8446 section 4.2.2).
write_cookie :: proc(w: ^Writer, cookie: []u8) {
	write_u16(w, int(Extension_Type.Cookie))
	extension := write_section_start(w)
	write_u16(w, len(cookie))
	write_bytes(w, cookie)
	write_section_end(w, extension)
}

write_signature_algorithms :: proc(w: ^Writer) {
	write_u16(w, int(Extension_Type.Signature_Algorithms))
	extension := write_section_start(w)
	schemes := write_section_start(w)
	for scheme in OFFERED_SIGNATURE_SCHEMES { write_u16(w, int(scheme)) }
	write_section_end(w, schemes)
	write_section_end(w, extension)
}

write_key_share :: proc(w: ^Writer, fields: Client_Hello_Fields) {
	write_u16(w, int(Extension_Type.Key_Share))
	extension := write_section_start(w)
	shares := write_section_start(w)
	write_u16(w, int(fields.group))
	write_u16(w, len(fields.keyshare))
	write_bytes(w, fields.keyshare)
	write_section_end(w, shares)
	write_section_end(w, extension)
}

write_alpn :: proc(w: ^Writer, protocols: []string) {
	write_u16(w, int(Extension_Type.Application_Layer_Protocol_Negotiation))
	extension := write_section_start(w)
	list := write_section_start(w)
	for protocol in protocols {
		write_u8(w, len(protocol))
		write_bytes(w, transmute([]u8)protocol)
	}
	write_section_end(w, list)
	write_section_end(w, extension)
}
