package tls

// Handshake framing and the field codecs the handshake structures are built from.
// TLS fields are big-endian and its structures are length-prefixed, so writing one
// is writing nested sections and reading one is reading them.

// Handshake_Type is the TLS HandshakeType (RFC 8446 section B.3). Message_Hash is not a
// handshake message a peer sends: it stands in the transcript for a ClientHello that a
// HelloRetryRequest replaced (section 4.4.1).
Handshake_Type :: enum u8 {
	Client_Hello         = 1,
	Server_Hello         = 2,
	New_Session_Ticket   = 4,
	Encrypted_Extensions = 8,
	Certificate          = 11,
	Certificate_Request  = 13,
	Certificate_Verify   = 15,
	Finished             = 20,
	Key_Update           = 24,
	Message_Hash         = 254,
}

// Extension_Type is a TLS extension type (RFC 8446 section B.3.2).
Extension_Type :: enum u16 {
	Server_Name                            = 0x0000,
	Supported_Groups                       = 0x000a,
	Signature_Algorithms                   = 0x000d,
	Application_Layer_Protocol_Negotiation = 0x0010,
	Pre_Shared_Key                         = 0x0029,
	Supported_Versions                     = 0x002b,
	Cookie                                 = 0x002c,
	Key_Share                              = 0x0033,
}

// Named_Group is a group a key share can be made for (RFC 8446 section B.3.1.4).
Named_Group :: enum u16 {
	SECP256R1 = 0x0017,
	X25519    = 0x001d,
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

// HELLO_RETRY_REQUEST_RANDOM is what tells a HelloRetryRequest apart from a ServerHello,
// since they are the same message (RFC 8446 section 4.1.4).
HELLO_RETRY_REQUEST_RANDOM: [32]u8 = {
	0xcf,
	0x21,
	0xad,
	0x74,
	0xe5,
	0x9a,
	0x61,
	0x11,
	0xbe,
	0x1d,
	0x8c,
	0x02,
	0x1e,
	0x65,
	0xb8,
	0x91,
	0xc2,
	0xa2,
	0x11,
	0x16,
	0x7a,
	0xbb,
	0x8c,
	0x5e,
	0x07,
	0x9e,
	0x09,
	0xe2,
	0xc8,
	0xa8,
	0x33,
	0x9c,
}

HANDSHAKE_HEADER_SIZE :: 4

handshake_encode_header :: proc(handshake_type: Handshake_Type, length: int, dst: []u8) {
	dst[0] = u8(handshake_type)
	dst[1] = u8(length >> 16)
	dst[2] = u8(length >> 8)
	dst[3] = u8(length & 0xff)
}

// handshake_decode_header reads the header at the front of `data` and reports the
// length of the handshake message that follows it.
@(require_results)
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

write_u8 :: proc(writer: ^Writer, value: int) {
	if value < 0 || value > 0xff || writer.at + 1 > len(writer.dst) {
		writer.ok = false
		return
	}
	writer.dst[writer.at] = u8(value)
	writer.at += 1
}

write_u16 :: proc(writer: ^Writer, value: int) {
	if value < 0 || value > 0xffff || writer.at + 2 > len(writer.dst) {
		writer.ok = false
		return
	}
	writer.dst[writer.at] = u8(value >> 8)
	writer.dst[writer.at + 1] = u8(value & 0xff)
	writer.at += 2
}

write_bytes :: proc(writer: ^Writer, data: []u8) {
	if writer.at + len(data) > len(writer.dst) {
		writer.ok = false
		return
	}
	copy(writer.dst[writer.at:], data)
	writer.at += len(data)
}

// write_section_start reserves the length field of a section and returns where it
// is, for write_section_end to fill in once the section's length is known.
write_section_start :: proc(writer: ^Writer) -> int {
	at := writer.at
	write_u16(writer, 0)
	return at
}

write_section_end :: proc(writer: ^Writer, start: int) {
	if !writer.ok { return }
	length := writer.at - start - 2
	writer.dst[start] = u8(length >> 8)
	writer.dst[start + 1] = u8(length & 0xff)
}

// Reader walks a length-prefixed structure. A read that does not fit leaves `ok`
// false and keeps it false, so a caller reads a whole structure and checks once;
// a section read from it is bounds checked against the section, not the whole.
Reader :: struct {
	data: []u8,
	at:   int,
	ok:   bool,
}

read_u8 :: proc(reader: ^Reader) -> u8 {
	if !reader.ok || reader.at + 1 > len(reader.data) {
		reader.ok = false
		return 0
	}
	value := reader.data[reader.at]
	reader.at += 1
	return value
}

read_u16 :: proc(reader: ^Reader) -> u16 {
	if !reader.ok || reader.at + 2 > len(reader.data) {
		reader.ok = false
		return 0
	}
	value := u16(reader.data[reader.at]) << 8 | u16(reader.data[reader.at + 1])
	reader.at += 2
	return value
}

read_bytes :: proc(reader: ^Reader, count: int) -> []u8 {
	if count < 0 || !reader.ok || reader.at + count > len(reader.data) {
		reader.ok = false
		return nil
	}
	value := reader.data[reader.at:reader.at + count]
	reader.at += count
	return value
}

read_section :: proc(reader: ^Reader, length: int) -> Reader {
	return {data = read_bytes(reader, length), ok = reader.ok}
}

read_section_u8 :: proc(reader: ^Reader) -> Reader {
	return read_section(reader, int(read_u8(reader)))
}

read_section_u16 :: proc(reader: ^Reader) -> Reader {
	return read_section(reader, int(read_u16(reader)))
}

read_u24 :: proc(reader: ^Reader) -> int {
	if !reader.ok || reader.at + 3 > len(reader.data) {
		reader.ok = false
		return 0
	}
	value := int(reader.data[reader.at]) << 16 | int(reader.data[reader.at + 1]) << 8 | int(reader.data[reader.at + 2])
	reader.at += 3
	return value
}

read_section_u24 :: proc(reader: ^Reader) -> Reader {
	return read_section(reader, read_u24(reader))
}
