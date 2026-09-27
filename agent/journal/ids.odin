package journal

import "core:crypto"

// The identities of section 5 of the architecture. Zero means absent for every
// one of them and is stored as SQL NULL. Branch and node ids are allocated by
// the journal; turn, request, call, and job ids by the harness.
Run_Id :: distinct [16]u8
Session_Id :: distinct [16]u8
Branch_Id :: distinct u32
Node_Id :: distinct u64
Journal_Seq :: distinct i64
Turn_Id :: distinct u32
Request_Id :: distinct u32
Attempt_No :: distinct u8
Job_Id :: distinct u64
Call_Id :: distinct u64

// Digest is the SHA-256 an artifact is stored under.
Digest :: distinct [32]u8

SESSION_ID_HEX_LENGTH :: 2 * size_of(Session_Id)
DIGEST_HEX_LENGTH :: 2 * size_of(Digest)

// session_id_create returns a random id from the operating system's entropy
// source, so ids from concurrent processes never collide.
session_id_create :: proc() -> (id: Session_Id) {
	crypto.rand_bytes(id[:])
	return
}

run_id_create :: proc() -> (id: Run_Id) {
	crypto.rand_bytes(id[:])
	return
}

// session_id_to_hex writes id as lowercase hexadecimal into buffer, which holds
// at least SESSION_ID_HEX_LENGTH bytes. The result aliases buffer.
session_id_to_hex :: proc(id: Session_Id, buffer: []u8) -> string {
	bytes := id
	return hex_encode(bytes[:], buffer)
}

session_id_parse :: proc(text: string) -> (id: Session_Id, ok: bool) {
	if !hex_decode(text, id[:]) { return {}, false }
	return id, true
}

// digest_to_hex writes digest as lowercase hexadecimal into buffer, which holds
// at least DIGEST_HEX_LENGTH bytes. The result aliases buffer.
digest_to_hex :: proc(digest: Digest, buffer: []u8) -> string {
	bytes := digest
	return hex_encode(bytes[:], buffer)
}

digest_from_hex :: proc(text: string) -> (digest: Digest, ok: bool) {
	if !hex_decode(text, digest[:]) { return {}, false }
	return digest, true
}

@(private)
HEX_DIGITS := "0123456789abcdef"

@(private)
hex_encode :: proc(bytes: []u8, buffer: []u8) -> string {
	assert(len(buffer) >= 2 * len(bytes))
	for byte, i in bytes {
		buffer[2 * i] = HEX_DIGITS[byte >> 4]
		buffer[2 * i + 1] = HEX_DIGITS[byte & 0x0f]
	}
	return string(buffer[:2 * len(bytes)])
}

// hex_decode accepts exactly 2 * len(out) lowercase hexadecimal characters.
@(private)
hex_decode :: proc(text: string, out: []u8) -> bool {
	if len(text) != 2 * len(out) { return false }
	for i in 0 ..< len(out) {
		high := hex_value(text[2 * i]) or_return
		low := hex_value(text[2 * i + 1]) or_return
		out[i] = high << 4 | low
	}
	return true
}

@(private)
hex_value :: proc(character: u8) -> (u8, bool) {
	switch character {
	case '0' ..= '9':
		return character - '0', true
	case 'a' ..= 'f':
		return character - 'a' + 10, true
	}
	return 0, false
}
