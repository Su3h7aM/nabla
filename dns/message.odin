// DNS wire-message facts: what a reply says about the query it answers.
//
// The message codec itself lives in core:net and is reused, not repeated
// here. What this file adds is the small set of predicates a stub resolver
// needs before it may act on a reply: the truncation bit, and whether the
// reply answers the query that was sent. Both are pure functions over the
// received bytes, with no allocation and no network.
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

// message_flags reads the header flags of a message with at least a header.
message_flags :: proc(message: []u8) -> (flags: Flags, ok: bool) {
	if len(message) < HEADER_SIZE { return {}, false }
	bits := u16(message[2]) << 8 | u16(message[3])
	return transmute(Flags)bits, true
}

// message_truncated reports the TC bit: the reply answers the query but its
// answers did not fit the datagram. RFC 1035 4.2.1, RFC 7766 4.
message_truncated :: proc(response: []u8) -> bool {
	flags, ok := message_flags(response)
	return ok && flags.tc
}

// response_matches reports whether a reply answers the query that was sent:
// the same ID, the QR bit set, and the same question. RFC 5452 9.1 requires
// matching on ID, name, class, and type before a reply may be trusted; an
// off-path packet that matches none of those is passed over, never acted on.
response_matches :: proc(query, response: []u8) -> bool {
	if len(query) < HEADER_SIZE || len(response) < HEADER_SIZE { return false }
	if response[0] != query[0] || response[1] != query[1] { return false }
	flags, ok := message_flags(response)
	if !ok || !flags.qr { return false }
	return question_matches(query, response)
}

// question_matches compares the single question of two messages: type, class,
// and name. Names compare label by label in ASCII case-insensitive form;
// compression pointers are followed with a loop guard, so a hostile pointer
// cycle mismatches rather than looping.
question_matches :: proc(query, response: []u8) -> bool {
	if question_count(query) != 1 || question_count(response) != 1 { return false }
	qname, qtype, qclass, qok := question_at(query)
	if !qok { return false }
	rname, rtype, rclass, rok := question_at(response)
	if !rok { return false }
	if qtype != rtype || qclass != rclass { return false }
	return name_equal_fold(query, qname, response, rname)
}

// question_count reads QDCOUNT without parsing anything else.
question_count :: proc(message: []u8) -> int {
	if len(message) < HEADER_SIZE { return -1 }
	return int(message[4]) << 8 | int(message[5])
}

// question_at locates the question of a single-question message: the name
// span, and the type and class that follow it.
question_at :: proc(message: []u8) -> (name: Span, qtype, qclass: u16, ok: bool) {
	end, found := name_end(message, HEADER_SIZE, 0)
	if !found { return {}, 0, 0, false }
	if end + 4 > len(message) { return {}, 0, 0, false }
	qtype = u16(message[end]) << 8 | u16(message[end + 1])
	qclass = u16(message[end + 2]) << 8 | u16(message[end + 3])
	return Span{HEADER_SIZE, end}, qtype, qclass, true
}

// Span is a byte range inside a message: offset of its first byte and one
// past its last.
Span :: struct {
	start, end: int,
}

// name_end finds the end of the possibly compressed name at offset: the first
// byte past it, following at most a few pointers. A name that runs off the
// message or chains pointers too deep is not a name this resolver reads.
name_end :: proc(message: []u8, offset, depth: int) -> (end: int, ok: bool) {
	if depth > 8 { return 0, false }
	pos := offset
	for {
		if pos >= len(message) { return 0, false }
		length := message[pos]
		if length & 0xC0 == 0xC0 {
			if pos + 1 >= len(message) { return 0, false }
			target := int(length & 0x3F) << 8 | int(message[pos + 1])
			if target >= len(message) { return 0, false }
			_, valid := name_end(message, target, depth + 1)
			if !valid { return 0, false }
			return pos + 2, true
		}
		if length & 0xC0 != 0 { return 0, false }
		if length == 0 { return pos + 1, true }
		pos += 1 + int(length)
	}
}

// name_equal_fold compares two possibly compressed names label by label,
// ASCII case-insensitive. Only ASCII folds: DNS names are LDH, and a
// Unicode-aware fold would give a non-name comparison.
name_equal_fold :: proc(a: []u8, a_span: Span, b: []u8, b_span: Span) -> bool {
	a_labels := labels(a, a_span)
	b_labels := labels(b, b_span)
	defer delete(a_labels)
	defer delete(b_labels)
	if len(a_labels) != len(b_labels) { return false }
	for i in 0 ..< len(a_labels) {
		a_label := a[a_labels[i].start:a_labels[i].end]
		b_label := b[b_labels[i].start:b_labels[i].end]
		if !label_equal_fold(a_label, b_label) { return false }
	}
	return true
}

// labels splits the name at span into its label spans, following compression
// pointers. The array carries its allocator for release; a malformed name
// yields no labels, which never equals a well-formed one. The root name
// yields no labels either, and equals only itself.
labels :: proc(message: []u8, span: Span, allocator := context.temp_allocator) -> [dynamic]Span {
	found: [dynamic]Span
	found.allocator = allocator
	pos := span.start
	depth := 0
	for pos < span.end {
		if pos >= len(message) { break }
		length := message[pos]
		if length & 0xC0 == 0xC0 {
			if pos + 1 >= len(message) { break }
			target := int(length & 0x3F) << 8 | int(message[pos + 1])
			if target >= len(message) { break }
			depth += 1
			if depth > 8 { break }
			pos = target
			continue
		}
		if length & 0xC0 != 0 || length == 0 { break }
		if pos + 1 + int(length) > len(message) { break }
		append(&found, Span{pos + 1, pos + 1 + int(length)})
		pos += 1 + int(length)
	}
	return found
}

// label_equal_fold compares two label spans byte by byte, folding ASCII
// uppercase to lowercase on the fly.
label_equal_fold :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) {
		if fold_ascii(a[i]) != fold_ascii(b[i]) { return false }
	}
	return true
}

// fold_ascii folds an ASCII uppercase byte to lowercase and leaves every
// other byte alone.
fold_ascii :: proc(c: byte) -> byte {
	if c >= 'A' && c <= 'Z' { return c + ('a' - 'A') }
	return c
}
