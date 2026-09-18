// Package tls is a TLS 1.3 client: the record layer, the key schedule, and the
// handshake that reach a peer over a byte stream. It performs no I/O of its own
// and holds no clock, so a caller decides how bytes move and how long a wait may
// take.
package tls

// Record_Type is the TLS ContentType (RFC 8446 section B.1).
Record_Type :: enum u8 {
	Change_Cipher_Spec = 20,
	Alert              = 21,
	Handshake          = 22,
	Application_Data   = 23,
}

RECORD_HEADER_SIZE :: 5

// RECORD_VERSION is 0x0303, TLS 1.2's version, which TLS 1.3 pins in every
// record so that what reads it sees a record it recognizes (RFC 8446
// section 5.1).
RECORD_VERSION :: 0x0303

// MAX_PLAINTEXT_RECORD is the largest TLSPlaintext.fragment (RFC 8446
// section 5.1) and the largest content an inner plaintext may carry
// (section 5.4).
MAX_PLAINTEXT_RECORD :: 1 << 14

// MAX_CIPHERTEXT_RECORD is the largest TLSCiphertext.length, which leaves room
// for the tag and for padding (RFC 8446 section 5.2).
MAX_CIPHERTEXT_RECORD :: (1 << 14) + 256

record_encode_header :: proc(record_type: Record_Type, length: int, dst: []u8) {
	dst[0] = u8(record_type)
	dst[1] = u8(RECORD_VERSION >> 8)
	dst[2] = u8(RECORD_VERSION & 0xff)
	dst[3] = u8(length >> 8)
	dst[4] = u8(length)
}

// record_decode_header reads the header at the front of `data` and reports the
// length of the record body that follows it. The version is not checked: the
// protocol fixes it rather than negotiating it, and a record that carries
// another value is not this record layer's to reject.
record_decode_header :: proc(data: []u8) -> (record_type: Record_Type, length: int, ok: bool) {
	if len(data) < RECORD_HEADER_SIZE { return {}, 0, false }
	return Record_Type(data[0]), int(data[3]) << 8 | int(data[4]), true
}

// record_encode writes one unprotected record and returns how many bytes of
// `dst` it used.
record_encode :: proc(record_type: Record_Type, payload: []u8, dst: []u8) -> (n: int, ok: bool) {
	if len(payload) > MAX_PLAINTEXT_RECORD || len(dst) < RECORD_HEADER_SIZE + len(payload) { return 0, false }
	record_encode_header(record_type, len(payload), dst)
	copy(dst[RECORD_HEADER_SIZE:], payload)
	return RECORD_HEADER_SIZE + len(payload), true
}

// record_decode returns the payload of one unprotected record, which must be the
// whole of that record.
record_decode :: proc(record: []u8) -> (payload: []u8, record_type: Record_Type, ok: bool) {
	header_type, length, decoded := record_decode_header(record)
	if !decoded || length > MAX_PLAINTEXT_RECORD || len(record) != RECORD_HEADER_SIZE + length {
		return nil, {}, false
	}
	return record[RECORD_HEADER_SIZE:], header_type, true
}

// record_decode_inner returns the content of a decrypted inner plaintext and
// drops its padding: the last non-zero byte is the record's own type, and every
// byte after it is padding (RFC 8446 section 5.4).
record_decode_inner :: proc(inner: []u8) -> (content: []u8, record_type: Record_Type, ok: bool) {
	for i := len(inner) - 1; i >= 0; i -= 1 {
		if inner[i] == 0 { continue }
		return inner[:i], Record_Type(inner[i]), true
	}
	return nil, {}, false
}
