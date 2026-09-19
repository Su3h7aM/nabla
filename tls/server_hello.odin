package tls

import "core:bytes"

// Server_Hello is what a server answers a ClientHello with (RFC 9846
// section 4.1.3). Its slices borrow from the message it was decoded from.
//
// version is set only when the server named a version in supported_versions, and
// a server that leaves it out is not speaking TLS 1.3. group and keyshare are set
// only when the server chose one of the groups that was offered.
//
// A HelloRetryRequest is the same message, told apart by its random: it names the
// group the client is to use in a second ClientHello rather than carrying a share
// (RFC 9846 section 4.1.4).
Server_Hello :: struct {
	random:         [32]u8,
	session_id:     []u8,
	cipher_suite:   Cipher_Suite,
	version:        u16,
	group:          Named_Group,
	keyshare:       []u8,
	cookie:         []u8,
	pre_shared_key: bool,
	retry:          bool,
}

// server_hello_decode reads a ServerHello message body, the bytes after its
// handshake header. The message and every recognized extension must be exactly
// consumed, and an extension may appear only once.
server_hello_decode :: proc(message: []u8) -> (hello: Server_Hello, ok: bool) {
	r := Reader {
		data = message,
		ok   = true,
	}
	if read_u16(&r) != LEGACY_VERSION { return {}, false }
	copy(hello.random[:], read_bytes(&r, len(hello.random)))
	hello.retry = bytes.equal(hello.random[:], HELLO_RETRY_REQUEST_RANDOM[:])
	hello.session_id = read_bytes(&r, int(read_u8(&r)))
	hello.cipher_suite = Cipher_Suite(read_u16(&r))
	if read_u8(&r) != 0 { return {}, false }

	extensions := read_section_u16(&r)
	for extensions.ok && extensions.at < len(extensions.data) {
		start := extensions.at
		extension_type := Extension_Type(read_u16(&extensions))
		if extension_seen(extensions.data[:start], extension_type) { return {}, false }
		extension := read_section_u16(&extensions)
		#partial switch extension_type {
		case .Supported_Versions:
			hello.version = read_u16(&extension)
		case .Key_Share:
			hello.group = Named_Group(read_u16(&extension))
			if !hello.retry {
				hello.keyshare = read_bytes(&extension, int(read_u16(&extension)))
			}
		case .Cookie:
			if !hello.retry { return {}, false }
			hello.cookie = read_bytes(&extension, int(read_u16(&extension)))
		case .Pre_Shared_Key:
			if hello.retry { return {}, false }
			_ = read_u16(&extension)
			hello.pre_shared_key = true
		case:
			return {}, false
		}
		if !extension.ok || extension.at != len(extension.data) { return {}, false }
	}

	return hello, r.ok && r.at == len(r.data) && extensions.ok && extensions.at == len(extensions.data)
}

extension_seen :: proc(encoded: []u8, wanted: Extension_Type) -> bool {
	r := Reader {
		data = encoded,
		ok   = true,
	}
	for r.ok && r.at < len(r.data) {
		extension_type := Extension_Type(read_u16(&r))
		_ = read_section_u16(&r)
		if extension_type == wanted { return true }
	}
	return false
}
