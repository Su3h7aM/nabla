package websocket

import "core:crypto"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"

// KEY_GUID is the value a server appends to the key it was sent before hashing it
// (RFC 6455 1.3).
KEY_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

// NONCE_SIZE is the number of random octets a client sends as its key, and
// NONCE_ENCODED_SIZE is the length of that key once base64-encoded.
NONCE_SIZE :: 16
NONCE_ENCODED_SIZE :: (NONCE_SIZE + 2) / 3 * 4

// ACCEPT_SIZE is the length of the base64-encoded SHA-1 digest that answers the
// key, which is 20 octets encoded with padding.
ACCEPT_SIZE :: (sha1.DIGEST_SIZE + 2) / 3 * 4

// nonce_generate writes a fresh key into dst, which must hold
// NONCE_ENCODED_SIZE octets, and returns it. Entropy comes from the system source,
// whose failure core:crypto treats as fatal, so there is nothing to report.
nonce_generate :: proc(dst: []u8) -> (nonce: string) {
	assert(len(dst) >= NONCE_ENCODED_SIZE)
	random: [NONCE_SIZE]u8
	crypto.rand_bytes(random[:])
	encoded, err := base64.encode_into_buf(dst, random[:])
	assert(err == nil, "the destination holds an encoded key")
	return string(encoded)
}

// accept_key is the value a server must answer a key with: the SHA-1 of the key
// followed by KEY_GUID, base64-encoded (RFC 6455 4.2.2). A client that does not see
// this exact value has not been accepted.
accept_key :: proc(key: string) -> (accept: [ACCEPT_SIZE]u8) {
	// The GUID is bound to a local so that it has a memory representation to hash;
	// a constant expression has none.
	guid := KEY_GUID
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]u8)key)
	sha1.update(&ctx, transmute([]u8)guid)
	digest: [sha1.DIGEST_SIZE]u8
	sha1.final(&ctx, digest[:])
	encoded, err := base64.encode_into_buf(accept[:], digest[:])
	assert(err == nil, "the destination holds an encoded digest")
	assert(len(encoded) == ACCEPT_SIZE, "the encoded digest is not the expected length")
	return accept
}
