// DNS wire-message facts: what a reply says about the query it answers.
//
// The message codec itself lives in core:net and is reused, not repeated
// here. What this file adds is the small set of predicates a stub resolver
// needs before it may act on a reply: the truncation bit, the response code,
// and whether the reply answers the query that was sent. All of them are pure
// functions over the received bytes, with no allocation and no network.
package dns

// HEADER_SIZE is the DNS header: ID, flags, and four section counts.
// RFC 1035 4.1.1.
HEADER_SIZE :: 12

// Flags decodes the header's second u16. Odin bit_fields pack from the least
// significant bit, so the declaration order is the reverse of how RFC 1035
// 4.1.1 draws the field:
//
//	|QR|   Opcode  |AA|TC|RD|RA|   Z    |   RCODE   |
Flags :: bit_field u16 {
	rcode:  u8   | 4,
	z:      u8   | 3,
	ra:     bool | 1,
	rd:     bool | 1,
	tc:     bool | 1,
	aa:     bool | 1,
	opcode: u8   | 4,
	qr:     bool | 1,
}

// Rcode_Name_Error is the response code for a name that does not exist.
// RFC 1035 4.1.1. No OPT record leaves this endpoint, so the plain four-bit
// code is authoritative.
Rcode_Name_Error :: 3

// message_flags reads the header flags of a message with at least a header.
message_flags :: proc(message: []u8) -> (flags: Flags, ok: bool) {
	if len(message) < HEADER_SIZE { return {}, false }
	return transmute(Flags)read_u16(message, 2), true
}

// message_truncated reports the TC bit: the reply answers the query but its
// answers did not fit the datagram. RFC 1035 4.2.1, RFC 7766 4.
message_truncated :: proc(response: []u8) -> bool {
	flags, ok := message_flags(response)
	return ok && flags.tc
}

// response_nxdomain reports a definitive Name Error.
response_nxdomain :: proc(response: []u8) -> bool {
	flags, ok := message_flags(response)
	return ok && flags.rcode == Rcode_Name_Error
}

// response_matches reports whether a reply answers the query that was sent:
// the same ID, the QR bit set, and the same question. RFC 5452 9.1 requires
// matching on ID, name, class, and type before a reply may be trusted; an
// off-path packet that matches none of those is passed over, never acted on.
response_matches :: proc(query, response: []u8) -> bool {
	if len(query) < HEADER_SIZE || len(response) < HEADER_SIZE { return false }
	if read_u16(query, 0) != read_u16(response, 0) { return false }
	flags, _ := message_flags(response)
	if !flags.qr { return false }
	if read_u16(query, 4) != 1 || read_u16(response, 4) != 1 { return false }

	query_end, query_ok := name_end(query, HEADER_SIZE)
	response_end, response_ok := name_end(response, HEADER_SIZE)
	if !query_ok || !response_ok { return false }
	// The question's type and class follow its name.
	if query_end + 4 > len(query) || response_end + 4 > len(response) { return false }
	if string(query[query_end:][:4]) != string(response[response_end:][:4]) { return false }
	return names_equal_fold(query, HEADER_SIZE, response, HEADER_SIZE)
}

// read_u16 reads a big-endian u16 at offset of a message known to hold it.
read_u16 :: proc(message: []u8, offset: int) -> u16 {
	return u16(message[offset]) << 8 | u16(message[offset + 1])
}

// Name_Walk steps through the labels of a possibly compressed name.
//
// RFC 1035 4.1.4 lets a pointer name only a prior occurrence of a name, which
// begins before the one that points to it. Each pointer must therefore land
// before the start of the labels being read, so the walk moves strictly
// backward on every jump and ends on any message, a hostile one included.
Name_Walk :: struct {
	message: []u8,
	at:      int,
	// start is where the labels being read began: the name itself, or the
	// target of the last pointer.
	start:   int,
	// end is the first byte past the name where it is written, known once the
	// walk reaches the root label or its first pointer.
	end:     int,
}

name_walk :: proc(message: []u8, offset: int) -> Name_Walk {
	return {message = message, at = offset, start = offset}
}

// name_next returns the next label of the name. done reports the root label,
// which ends the name; ok is false for anything that is not a name.
name_next :: proc(walk: ^Name_Walk) -> (label: []u8, done: bool, ok: bool) {
	for {
		if walk.at >= len(walk.message) { return nil, false, false }
		length := walk.message[walk.at]
		switch length & 0xC0 {
		case 0x00:
			if length == 0 {
				if walk.end == 0 { walk.end = walk.at + 1 }
				return nil, true, true
			}
			first := walk.at + 1
			past := first + int(length)
			if past > len(walk.message) { return nil, false, false }
			walk.at = past
			return walk.message[first:past], false, true
		case 0xC0:
			if walk.at + 1 >= len(walk.message) { return nil, false, false }
			target := int(read_u16(walk.message, walk.at) & 0x3FFF)
			if target >= walk.start { return nil, false, false }
			if walk.end == 0 { walk.end = walk.at + 2 }
			walk.at = target
			walk.start = target
		case:
			// 0x40 and 0x80 are reserved label types (RFC 1035 4.1.4).
			return nil, false, false
		}
	}
}

// name_end finds the first byte past the name written at offset.
name_end :: proc(message: []u8, offset: int) -> (end: int, ok: bool) {
	walk := name_walk(message, offset)
	for {
		_, done := name_next(&walk) or_return
		if done { return walk.end, true }
	}
}

// names_equal_fold compares two possibly compressed names label by label,
// ASCII case-insensitive (RFC 4343). Only ASCII folds: a Unicode-aware fold
// would equate labels DNS treats as different.
names_equal_fold :: proc(a: []u8, a_offset: int, b: []u8, b_offset: int) -> bool {
	a_walk := name_walk(a, a_offset)
	b_walk := name_walk(b, b_offset)
	for {
		a_label, a_done := name_next(&a_walk) or_return
		b_label, b_done := name_next(&b_walk) or_return
		if a_done || b_done { return a_done == b_done }
		if !label_equal_fold(a_label, b_label) { return false }
	}
}

label_equal_fold :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) {
		if fold_ascii(a[i]) != fold_ascii(b[i]) { return false }
	}
	return true
}

fold_ascii :: proc(c: byte) -> byte {
	return c + ('a' - 'A') if c >= 'A' && c <= 'Z' else c
}
