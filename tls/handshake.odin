package tls

// Handshake framing and the field codecs the handshake structures are built from.
// TLS fields are big-endian and its structures are length-prefixed, so writing one
// is writing nested sections and reading one is reading them.

// Handshake_Type is the TLS HandshakeType (RFC 8446 section B.3).
Handshake_Type :: enum u8 {
	Client_Hello = 1,
	Server_Hello = 2,
}

// Extension_Type is a TLS extension type (RFC 8446 section B.3.2).
Extension_Type :: enum u16 {
	Server_Name                            = 0x0000,
	Supported_Groups                       = 0x000a,
	Signature_Algorithms                   = 0x000d,
	Application_Layer_Protocol_Negotiation = 0x0010,
	Pre_Shared_Key                         = 0x0029,
	Supported_Versions                     = 0x002b,
	Key_Share                              = 0x0033,
}

// Named_Group is a group a key share can be made for (RFC 8446 section B.3.1.4).
Named_Group :: enum u16 {
	X25519 = 0x001d,
}

// Signature_Scheme is a signature algorithm a peer may sign with (RFC 8446
// section B.3.1.3).
Signature_Scheme :: enum u16 {
	ECDSA_SECP256R1_SHA256 = 0x0403,
	ECDSA_SECP384R1_SHA384 = 0x0503,
	RSA_PSS_RSAE_SHA256    = 0x0804,
	RSA_PSS_RSAE_SHA384    = 0x0805,
	RSA_PSS_RSAE_SHA512    = 0x0806,
	ED25519                = 0x0807,
}

// VERSION_1_3 is the version a peer names in supported_versions (RFC 8446
// section 4.2.1).
VERSION_1_3 :: 0x0304

HANDSHAKE_HEADER_SIZE :: 4

handshake_encode_header :: proc(handshake_type: Handshake_Type, length: int, dst: []u8) {
	dst[0] = u8(handshake_type)
	dst[1] = u8(length >> 16)
	dst[2] = u8(length >> 8)
	dst[3] = u8(length & 0xff)
}

// handshake_decode_header reads the header at the front of `data` and reports the
// length of the handshake message that follows it.
handshake_decode_header :: proc(data: []u8) -> (handshake_type: Handshake_Type, length: int, ok: bool) {
	if len(data) < HANDSHAKE_HEADER_SIZE { return {}, 0, false }
	length = int(data[1]) << 16 | int(data[2]) << 8 | int(data[3])
	return Handshake_Type(data[0]), length, true
}

// Writer appends protocol fields to `dst`. A field that does not fit, or a length
// too wide for its field, leaves `ok` false and keeps it false, so a caller writes
// a whole structure and checks once.
Writer :: struct {
	dst: []u8,
	at:  int,
	ok:  bool,
}

write_u8 :: proc(w: ^Writer, value: int) {
	if value < 0 || value > 0xff || w.at + 1 > len(w.dst) {
		w.ok = false
		return
	}
	w.dst[w.at] = u8(value)
	w.at += 1
}

write_u16 :: proc(w: ^Writer, value: int) {
	if value < 0 || value > 0xffff || w.at + 2 > len(w.dst) {
		w.ok = false
		return
	}
	w.dst[w.at] = u8(value >> 8)
	w.dst[w.at + 1] = u8(value & 0xff)
	w.at += 2
}

write_bytes :: proc(w: ^Writer, data: []u8) {
	if w.at + len(data) > len(w.dst) {
		w.ok = false
		return
	}
	copy(w.dst[w.at:], data)
	w.at += len(data)
}

// write_section_start reserves the length field of a section and returns where it
// is, for write_section_end to fill in once the section's length is known.
write_section_start :: proc(w: ^Writer) -> int {
	at := w.at
	write_u16(w, 0)
	return at
}

write_section_end :: proc(w: ^Writer, start: int) {
	if !w.ok { return }
	length := w.at - start - 2
	w.dst[start] = u8(length >> 8)
	w.dst[start + 1] = u8(length & 0xff)
}

// Reader walks a length-prefixed structure. A read that does not fit leaves `ok`
// false and keeps it false, so a caller reads a whole structure and checks once;
// a section read from it is bounds checked against the section, not the whole.
Reader :: struct {
	data: []u8,
	at:   int,
	ok:   bool,
}

read_u8 :: proc(r: ^Reader) -> u8 {
	if !r.ok || r.at + 1 > len(r.data) {
		r.ok = false
		return 0
	}
	value := r.data[r.at]
	r.at += 1
	return value
}

read_u16 :: proc(r: ^Reader) -> u16 {
	if !r.ok || r.at + 2 > len(r.data) {
		r.ok = false
		return 0
	}
	value := u16(r.data[r.at]) << 8 | u16(r.data[r.at + 1])
	r.at += 2
	return value
}

read_bytes :: proc(r: ^Reader, count: int) -> []u8 {
	if count < 0 || !r.ok || r.at + count > len(r.data) {
		r.ok = false
		return nil
	}
	value := r.data[r.at:r.at + count]
	r.at += count
	return value
}

read_section :: proc(r: ^Reader, length: int) -> Reader {
	return {data = read_bytes(r, length), ok = r.ok}
}

read_section_u8 :: proc(r: ^Reader) -> Reader {
	return read_section(r, int(read_u8(r)))
}

read_section_u16 :: proc(r: ^Reader) -> Reader {
	return read_section(r, int(read_u16(r)))
}

read_u24 :: proc(r: ^Reader) -> int {
	if !r.ok || r.at + 3 > len(r.data) {
		r.ok = false
		return 0
	}
	value := int(r.data[r.at]) << 16 | int(r.data[r.at + 1]) << 8 | int(r.data[r.at + 2])
	r.at += 3
	return value
}

read_section_u24 :: proc(r: ^Reader) -> Reader {
	return read_section(r, read_u24(r))
}
