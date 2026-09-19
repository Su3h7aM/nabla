package tls

import "core:crypto/aead"
import "core:crypto/hash"
import "core:crypto/hkdf"

// Cipher_Suite is a TLS 1.3 cipher suite (RFC 8446 section B.4): the mandatory
// one, and the two the protocol recommends.
Cipher_Suite :: enum u16 {
	AES_128_GCM_SHA256       = 0x1301,
	AES_256_GCM_SHA384       = 0x1302,
	CHACHA20_POLY1305_SHA256 = 0x1303,
}

// Cipher_Suite_Info is what a suite fixes for the rest of the protocol: the hash
// the key schedule runs on, and the AEAD that protects its records.
Cipher_Suite_Info :: struct {
	hash: hash.Algorithm,
	aead: aead.Algorithm,
}

CIPHER_SUITES := [Cipher_Suite]Cipher_Suite_Info {
	.AES_128_GCM_SHA256 = {hash = .SHA256, aead = .AES_GCM_128},
	.AES_256_GCM_SHA384 = {hash = .SHA384, aead = .AES_GCM_256},
	.CHACHA20_POLY1305_SHA256 = {hash = .SHA256, aead = .CHACHA20POLY1305},
}

// MAX_SECRET_SIZE and MAX_KEY_SIZE are the most the supported suites need: the
// digest of SHA-384, and the key of AES-256.
MAX_SECRET_SIZE :: 48
MAX_KEY_SIZE :: 32

// IV_SIZE is the nonce size of every TLS 1.3 suite (RFC 8446 section 5.3).
IV_SIZE :: 12

// Secret is storage for one key-schedule secret. A secret is `secret_size` bytes
// long; the rest of the array carries nothing.
Secret :: [MAX_SECRET_SIZE]u8

secret_size :: proc(suite: Cipher_Suite) -> int {
	return hash.DIGEST_SIZES[CIPHER_SUITES[suite].hash]
}

// LABEL_PREFIX begins every HKDF label of the protocol (RFC 8446 section 7.1).
LABEL_PREFIX :: "tls13 "

// The HkdfLabel structure carries the label and the context as uint8-prefixed
// vectors and the output length as a uint16 (RFC 8446 section 7.1).
MAX_LABEL_BYTES :: 255
MAX_HKDF_OUTPUT_BYTES :: 65535

// hkdf_expand_label is HKDF-Expand-Label: keying material of `len(dst)` bytes
// derived from `secret`, with the label and the context carried in the HkdfLabel
// structure (RFC 8446 section 7.1).
hkdf_expand_label :: proc(suite: Cipher_Suite, secret: []u8, label: string, label_context: []u8, dst: []u8) -> bool {
	label_length := len(LABEL_PREFIX) + len(label)
	if label_length > MAX_LABEL_BYTES || len(label_context) > MAX_LABEL_BYTES { return false }
	if len(dst) > MAX_HKDF_OUTPUT_BYTES { return false }

	info: [2 + 1 + MAX_LABEL_BYTES + 1 + MAX_LABEL_BYTES]u8
	info[0] = u8(len(dst) >> 8)
	info[1] = u8(len(dst))
	info[2] = u8(label_length)
	offset := 3 + copy(info[3:], LABEL_PREFIX)
	offset += copy(info[offset:], label)
	info[offset] = u8(len(label_context))
	offset += 1 + copy(info[offset + 1:], label_context)

	hkdf.expand(CIPHER_SUITES[suite].hash, secret, info[:offset], dst)
	return true
}

// Stage is where a key schedule has reached. The labels its secrets are derived
// under follow from it.
Stage :: enum {
	Early,
	Handshake,
	Application,
}

// Key_Schedule is one connection's secret tree (RFC 8446 section 7.1). It holds
// the stage it has reached and that stage's secret, never a transcript: a caller
// passes the hash of the messages a secret covers, so the caller keeps owning the
// transcript.
Key_Schedule :: struct {
	suite:  Cipher_Suite,
	stage:  Stage,
	secret: Secret,
}

// key_schedule_init starts a schedule with no pre-shared key, which extracts the
// early secret from a zero secret (RFC 8446 section 7.1).
key_schedule_init :: proc(suite: Cipher_Suite) -> (schedule: Key_Schedule) {
	schedule.suite = suite
	schedule.stage = .Early
	zeros: Secret
	size := secret_size(suite)
	hkdf.extract(CIPHER_SUITES[suite].hash, zeros[:size], zeros[:size], schedule.secret[:size])
	return
}

// key_schedule_advance moves to the next stage, extracting `ikm` against a secret
// derived from the current stage. `ikm` is the ECDHE shared secret for the
// handshake stage and a zero secret for the master stage, which is the end of the
// tree (RFC 8446 section 7.1).
key_schedule_advance :: proc(schedule: ^Key_Schedule, ikm: []u8) -> bool {
	next: Stage
	switch schedule.stage {
	case .Early:
		next = .Handshake
	case .Handshake:
		next = .Application
	case .Application:
		return false
	}

	suite := schedule.suite
	size := secret_size(suite)

	// Derive-Secret over an empty transcript is the hash of no messages, not an
	// empty context (RFC 8446 section 7.1).
	empty: Secret
	hash.hash_bytes_to_buffer(CIPHER_SUITES[suite].hash, {}, empty[:size])

	salt: Secret
	if !hkdf_expand_label(suite, schedule.secret[:size], "derived", empty[:size], salt[:size]) { return false }

	hkdf.extract(CIPHER_SUITES[suite].hash, salt[:size], ikm, schedule.secret[:size])
	schedule.stage = next
	return true
}

// key_schedule_traffic_secrets derives both directions' traffic secrets of the
// current stage: what this endpoint writes under, and what the peer writes under.
// The transcript hash covers the messages the secrets are bound to (RFC 8446
// section 7.1). The early stage binds 0-RTT data, which is not implemented.
key_schedule_traffic_secrets :: proc(schedule: ^Key_Schedule, transcript_hash: []u8, client, server: ^Secret) -> bool {
	client_label, server_label: string
	switch schedule.stage {
	case .Early:
		return false
	case .Handshake:
		client_label, server_label = "c hs traffic", "s hs traffic"
	case .Application:
		client_label, server_label = "c ap traffic", "s ap traffic"
	}

	size := secret_size(schedule.suite)
	if !hkdf_expand_label(schedule.suite, schedule.secret[:size], client_label, transcript_hash, client[:size]) {
		return false
	}
	return hkdf_expand_label(schedule.suite, schedule.secret[:size], server_label, transcript_hash, server[:size])
}

// Traffic_Key is one direction's protection state for one stage: the AEAD key,
// the static nonce, and the record sequence number.
//
// Nothing here replaces a nonce. RFC 8446 section 5.5 requires a key update
// before the sequence number repeats, so a caller that never updates a key must
// not write more records than the sequence space holds.
Traffic_Key :: struct {
	key:      [MAX_KEY_SIZE]u8,
	iv:       [IV_SIZE]u8,
	sequence: u64,
}

// traffic_key_derive fills `dst` from one traffic secret and starts its sequence
// number at zero (RFC 8446 section 7.3).
traffic_key_derive :: proc(suite: Cipher_Suite, secret: []u8, dst: ^Traffic_Key) -> bool {
	key_length := aead.KEY_SIZES[CIPHER_SUITES[suite].aead]
	if !hkdf_expand_label(suite, secret, "key", {}, dst.key[:key_length]) { return false }
	if !hkdf_expand_label(suite, secret, "iv", {}, dst.iv[:]) { return false }
	dst.sequence = 0
	return true
}

// key_schedule_update derives the next traffic secret of one direction from the one
// in use, which is the whole of a key update (RFC 8446 section 7.2).
key_schedule_update :: proc(suite: Cipher_Suite, secret: []u8, dst: []u8) -> bool {
	size := secret_size(suite)
	empty: Secret
	hash.hash_bytes_to_buffer(CIPHER_SUITES[suite].hash, {}, empty[:size])
	return hkdf_expand_label(suite, secret, "traffic upd", empty[:size], dst)
}
