package tls

// Server_Hello is what a server answers a ClientHello with (RFC 8446
// section 4.1.3). Its slices borrow from the message it was decoded from.
//
// version is set only when the server named a version in supported_versions, and
// a server that leaves it out is not speaking TLS 1.3. group and keyshare are set
// only when the server chose one of the groups that was offered.
Server_Hello :: struct {
	random:         [32]u8,
	session_id:     []u8,
	cipher_suite:   Cipher_Suite,
	version:        u16,
	group:          Named_Group,
	keyshare:       []u8,
	alpn:           string,
	pre_shared_key: bool,
}

// server_hello_decode reads a ServerHello message body, the bytes after its
// handshake header. The trailing extensions must be exactly consumed.
server_hello_decode :: proc(message: []u8) -> (hello: Server_Hello, ok: bool) {
	r := Reader{data = message, ok = true}
	_ = read_u16(&r)  // legacy_version, fixed at LEGACY_VERSION
	copy(hello.random[:], read_bytes(&r, len(hello.random)))
	hello.session_id = read_bytes(&r, int(read_u8(&r)))
	hello.cipher_suite = Cipher_Suite(read_u16(&r))
	_ = read_u8(&r)  // legacy_compression_methods, a single null byte

	extensions := read_section_u16(&r)
	for extensions.ok && extensions.at < len(extensions.data) {
		extension_type := Extension_Type(read_u16(&extensions))
		extension := read_section_u16(&extensions)
		#partial switch extension_type {
		case .Supported_Versions:
			hello.version = read_u16(&extension)
		case .Key_Share:
			hello.group = Named_Group(read_u16(&extension))
			hello.keyshare = read_bytes(&extension, int(read_u16(&extension)))
		case .Application_Layer_Protocol_Negotiation:
			protocols := read_section_u16(&extension)
			hello.alpn = string(read_bytes(&protocols, int(read_u8(&protocols))))
		case .Pre_Shared_Key:
			// This client offers no pre-shared key, so a server that selects one
			// is answering a ClientHello that was never sent.
			hello.pre_shared_key = true
		case:
			// An extension the peer does not recognize is ignored rather than
			// refused (RFC 8446 section 4.2).
		}
		if !extension.ok { r.ok = false }
	}

	return hello, r.ok && extensions.ok && extensions.at == len(extensions.data)
}
