package journal

import "core:crypto"

// The identities of section 5. They are declared here, in the innermost package
// that stores them, so the harness and the journal agree on one definition.
//
// Zero means absent for every one of them, and an absent id is stored as SQL
// NULL. A session, a run, and a subagent are 16 bytes; the rest are counters,
// allocated by the journal (branch, node) or by the harness (turn, request,
// call, job).
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

// SESSION_ID_HEX_LENGTH is how many characters a session or run id takes in
// lowercase hexadecimal.
SESSION_ID_HEX_LENGTH :: 32

// session_id_create returns a fresh session id from the operating system's
// entropy source. Randomness is what makes the id unique without a lookup and
// unguessable enough to name a lock file, and two processes started at the same
// moment must not produce the same one. A failed read returns the absent id,
// which create_session refuses.
session_id_create :: proc() -> Session_Id {
	bytes: [16]u8
	crypto.rand_bytes(bytes[:])
	return Session_Id(bytes)
}

// run_id_create returns a fresh run id, one per process run.
run_id_create :: proc() -> Run_Id {
	bytes: [16]u8
	crypto.rand_bytes(bytes[:])
	return Run_Id(bytes)
}

// session_id_to_hex writes the 32 lowercase hexadecimal characters of id into
// buffer, which must hold at least SESSION_ID_HEX_LENGTH bytes, and returns
// them. The result aliases buffer.
session_id_to_hex :: proc(id: Session_Id, buffer: []u8) -> string {
	assert(len(buffer) >= SESSION_ID_HEX_LENGTH, "the id buffer is too small")
	for byte, i in id {
		buffer[i * 2] = hex_character(byte >> 4)
		buffer[i * 2 + 1] = hex_character(byte & 0x0f)
	}
	return string(buffer[:SESSION_ID_HEX_LENGTH])
}

// session_id_parse reads a session id from its hexadecimal form. Anything but
// exactly 32 lowercase hexadecimal characters is refused.
session_id_parse :: proc(text: string) -> (Session_Id, bool) {
	if len(text) != SESSION_ID_HEX_LENGTH { return Session_Id{}, false }
	bytes: [16]u8
	for i in 0 ..< 16 {
		high, high_ok := hex_digit(text[i * 2])
		low, low_ok := hex_digit(text[i * 2 + 1])
		if !high_ok || !low_ok { return Session_Id{}, false }
		bytes[i] = high << 4 | low
	}
	return Session_Id(bytes), true
}

// session_id_is_absent reports whether no session is named.
session_id_is_absent :: proc(id: Session_Id) -> bool {
	return id == Session_Id{}
}

// run_id_is_absent reports whether no run is named.
run_id_is_absent :: proc(id: Run_Id) -> bool {
	return id == Run_Id{}
}

// hex_character is the lowercase hexadecimal character of a nibble.
@(private)
hex_character :: proc(nibble: u8) -> u8 {
	return nibble < 10 ? '0' + nibble : 'a' + (nibble - 10)
}

@(private)
hex_digit :: proc(character: u8) -> (u8, bool) {
	switch character {
	case '0' ..= '9':
		return character - '0', true
	case 'a' ..= 'f':
		return character - 'a' + 10, true
	}
	return 0, false
}
