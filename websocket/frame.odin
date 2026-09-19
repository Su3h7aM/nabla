// Package websocket is the WebSocket protocol (RFC 6455): the frame codec, and a
// connection that moves messages over whatever carries its bytes.
//
// It is a client. It masks every frame it sends, refuses a frame a server may not
// send masked, and never carries the bytes itself: a caller supplies the transport
// and so keeps its own deadline and cancellation.
package websocket

// Opcode is what a frame carries (RFC 6455 section 5.2).
Opcode :: enum u8 {
	Continuation = 0x0,
	Text         = 0x1,
	Binary       = 0x2,
	Close        = 0x8,
	Ping         = 0x9,
	Pong         = 0xa,
}

// MASK_KEY_SIZE is the masking key every frame a client sends carries (RFC 6455
// section 5.3).
MASK_KEY_SIZE :: 4

// HEADER_MAX_SIZE is the largest frame header: the two fixed octets, the 64-bit
// length, and the masking key.
HEADER_MAX_SIZE :: 2 + 8 + MASK_KEY_SIZE

// MAX_CONTROL_PAYLOAD is the most a control frame may carry. A control frame has to
// be acted on while the connection is in the middle of something else, so it must
// fit in one frame and must not be fragmented (RFC 6455 section 5.5).
MAX_CONTROL_PAYLOAD :: 125

// Header is what a frame states about the payload that follows it.
Header :: struct {
	final:         bool,
	opcode:        Opcode,
	// masked says the payload is masked, and mask holds the key that unmasks it.
	masked:        bool,
	mask:          [MASK_KEY_SIZE]u8,
	length:        int,
	// header_length is how many octets the header took, the masking key included.
	header_length: int,
}

// frame_header_encode writes the header of a masked frame, the masking key included,
// and returns how many octets of `dst` it used. A client masks every frame it sends,
// so the key is always written (RFC 6455 section 5.3).
frame_header_encode :: proc(header: Header, mask: [MASK_KEY_SIZE]u8, dst: []u8) -> (n: int, ok: bool) {
	length := header.length
	extended := 0
	switch {
	case length <= 125:
	case length <= 0xffff:
		extended = 2
	case:
		extended = 8
	}
	if len(dst) < 2 + extended + MASK_KEY_SIZE { return 0, false }

	dst[0] = u8(header.opcode) & 0x0f
	if header.final { dst[0] |= 0x80 }

	length_field: int
	switch extended {
	case 0:
		length_field = length
	case 2:
		length_field = 126
	case 8:
		length_field = 127
	}
	dst[1] = u8(length_field) | 0x80

	at := 2
	switch extended {
	case 2:
		dst[at] = u8(length >> 8)
		dst[at + 1] = u8(length & 0xff)
		at += 2
	case 8:
		for i in 0 ..< 8 { dst[at + i] = u8(length >> (8 * u64(7 - i))) }
		at += 8
	}
	key := mask
	copy(dst[at:], key[:])
	return at + MASK_KEY_SIZE, true
}

// frame_header_decode reads the header at the front of `data`, which must hold all of
// it. A reserved bit that is set makes the frame one this client cannot read, since
// it has negotiated no extension that would define one (RFC 6455 section 5.2).
frame_header_decode :: proc(data: []u8) -> (header: Header, ok: bool) {
	if len(data) < 2 { return {}, false }
	if data[0] & 0x70 != 0 { return {}, false }

	header.final = data[0] & 0x80 != 0
	header.opcode = Opcode(data[0] & 0x0f)
	header.masked = data[1] & 0x80 != 0

	length := int(data[1] & 0x7f)
	at := 2
	switch length {
	case 126:
		if len(data) < 4 { return {}, false }
		length = int(data[2]) << 8 | int(data[3])
		at = 4
	case 127:
		if len(data) < 10 { return {}, false }
		// The length is 63 bits: the top bit of the 64 is zero by definition.
		if data[2] & 0x80 != 0 { return {}, false }
		length = 0
		for i in 2 ..< 10 { length = length << 8 | int(data[i]) }
		at = 10
	}
	if header.masked {
		if len(data) < at + MASK_KEY_SIZE { return {}, false }
		copy(header.mask[:], data[at:])
		at += MASK_KEY_SIZE
	}
	header.length = length
	header.header_length = at
	return header, true
}

// frame_mask applies a masking key to a payload in place. Masking and unmasking are
// the same operation (RFC 6455 section 5.3).
frame_mask :: proc(payload: []u8, mask: [MASK_KEY_SIZE]u8) {
	for byte, at in payload { payload[at] = byte ~ mask[at % MASK_KEY_SIZE] }
}

// frame_encode writes one whole masked frame and returns how many octets of `dst` it
// used. The payload is copied, so it may not overlap `dst`.
frame_encode :: proc(opcode: Opcode, final: bool, mask: [MASK_KEY_SIZE]u8, payload: []u8, dst: []u8) -> (n: int, ok: bool) {
	header_length, encoded := frame_header_encode({final = final, opcode = opcode, length = len(payload)}, mask, dst)
	if !encoded || len(dst) < header_length + len(payload) { return 0, false }
	copy(dst[header_length:], payload)
	frame_mask(dst[header_length:header_length + len(payload)], mask)
	return header_length + len(payload), true
}
