package tls

import "core:crypto/aead"

// record_nonce is the per-record nonce: the static nonce with the record
// sequence number XORed into its last eight bytes (RFC 8446 section 5.3).
record_nonce :: proc(key: ^Traffic_Key) -> [IV_SIZE]u8 {
	nonce := key.iv
	for i in 0 ..< 8 {
		nonce[IV_SIZE - 1 - i] ~= u8(key.sequence >> (8 * u64(i)))
	}
	return nonce
}

// record_protect writes one protected record into `dst`: the header, the
// encrypted inner plaintext, and the tag. The header is authenticated with the
// content, and its length field is only known once the inner plaintext is, so the
// inner plaintext is built inside `dst` and encrypted there.
//
// `dst` must hold RECORD_HEADER_SIZE + len(payload) + 1 + tag bytes.
record_protect :: proc(suite: Cipher_Suite, key: ^Traffic_Key, record_type: Record_Type, payload: []u8, dst: []u8) -> (n: int, ok: bool) {
	info := CIPHER_SUITES[suite]
	tag_size := aead.TAG_SIZES[info.aead]
	inner_length := len(payload) + 1
	length := inner_length + tag_size
	if len(payload) > MAX_PLAINTEXT_RECORD || length > MAX_CIPHERTEXT_RECORD { return 0, false }
	if len(dst) < RECORD_HEADER_SIZE + length { return 0, false }

	header := dst[:RECORD_HEADER_SIZE]
	inner := dst[RECORD_HEADER_SIZE:RECORD_HEADER_SIZE + inner_length]
	tag := dst[RECORD_HEADER_SIZE + inner_length:RECORD_HEADER_SIZE + length]
	copy(inner, payload)
	inner[len(payload)] = u8(record_type)

	nonce := record_nonce(key)
	record_encode_header(.Application_Data, length, header)
	aead.seal_oneshot(info.aead, inner, tag, key.key[:aead.KEY_SIZES[info.aead]], nonce[:], header, inner)
	key.sequence += 1
	return RECORD_HEADER_SIZE + length, true
}

// record_unprotect authenticates one complete protected record and decrypts it in
// place, returning the content and type it carried. A record that does not
// authenticate yields nothing. `record` must be the whole of that record.
record_unprotect :: proc(suite: Cipher_Suite, key: ^Traffic_Key, record: []u8) -> (content: []u8, record_type: Record_Type, ok: bool) {
	info := CIPHER_SUITES[suite]
	tag_size := aead.TAG_SIZES[info.aead]
	outer_type, length, decoded := record_decode_header(record)
	if !decoded || outer_type != .Application_Data { return nil, {}, false }
	if length > MAX_CIPHERTEXT_RECORD || len(record) != RECORD_HEADER_SIZE + length { return nil, {}, false }

	inner_length := length - tag_size
	if inner_length < 1 { return nil, {}, false }
	header := record[:RECORD_HEADER_SIZE]
	inner := record[RECORD_HEADER_SIZE:RECORD_HEADER_SIZE + inner_length]
	tag := record[RECORD_HEADER_SIZE + inner_length:]

	nonce := record_nonce(key)
	if !aead.open_oneshot(info.aead, inner, key.key[:aead.KEY_SIZES[info.aead]], nonce[:], header, inner, tag) {
		return nil, {}, false
	}
	key.sequence += 1
	return record_decode_inner(inner)
}
