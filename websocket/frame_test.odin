#+test
package websocket

import "core:testing"

// RFC 6455 section 5.7 works through the frames an endpoint sends. Holding the codec
// to those octets is what makes a failure here a failure against the protocol rather
// than against this package's own idea of it.
MASK :: [MASK_KEY_SIZE]u8{0x37, 0xfa, 0x21, 0x3d}

@(test)
test_rfc_6455_frame_examples :: proc(t: ^testing.T) {
	// A single-frame masked text message: 0x81 0x85 0x37 0xfa 0x21 0x3d 0x7f 0x9f
	// 0x4d 0x51 0x58, which is "Hello".
	dst: [MASK_KEY_SIZE + HEADER_MAX_SIZE + 8]u8
	payload := transmute([]u8)string("Hello")
	count, encoded := frame_encode(.Text, true, MASK, payload, dst[:])
	if !testing.expect(t, encoded, "a text frame could not be encoded") { return }
	expect_octets(t, "the masked text frame", dst[:count], {
		0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58,
	})

	header, decoded := frame_header_decode(dst[:count])
	if !testing.expect(t, decoded, "the header could not be decoded") { return }
	testing.expect_value(t, header.opcode, Opcode.Text)
	testing.expect(t, header.final, "the frame is not final")
	testing.expect(t, header.masked, "a client frame is masked")
	testing.expect_value(t, header.length, len(payload))
	testing.expect_value(t, header.header_length, 6)

	frame_mask(dst[header.header_length:count], header.mask)
	testing.expect_value(t, string(dst[header.header_length:count]), "Hello")

	// A fragmented unmasked text message: 0x01 0x03 "Hel" and 0x80 0x02 "lo".
	first := []u8{0x01, 0x03, 0x48, 0x65, 0x6c}
	second := []u8{0x80, 0x02, 0x6c, 0x6f}
	first_header, first_decoded := frame_header_decode(first)
	second_header, second_decoded := frame_header_decode(second)
	if !testing.expect(t, first_decoded && second_decoded, "a fragment header could not be decoded") { return }
	testing.expect_value(t, first_header.opcode, Opcode.Text)
	testing.expect(t, !first_header.final && !first_header.masked, "the first fragment is final or masked")
	testing.expect_value(t, first_header.length, 3)
	testing.expect_value(t, second_header.opcode, Opcode.Continuation)
	testing.expect(t, second_header.final, "the last fragment is not final")
	testing.expect_value(t, second_header.length, 2)

	// An unmasked ping: 0x89 0x05 "Hello".
	ping, ping_decoded := frame_header_decode([]u8{0x89, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f})
	if !testing.expect(t, ping_decoded, "a ping header could not be decoded") { return }
	testing.expect_value(t, ping.opcode, Opcode.Ping)
	testing.expect_value(t, ping.length, 5)
	testing.expect_value(t, ping.header_length, 2)

	// The two length ladders: 256 octets under a 16-bit length, and 65536 under a
	// 64-bit one.
	short, short_decoded := frame_header_decode([]u8{0x82, 0x7e, 0x01, 0x00, 0, 0, 0, 0})
	if !testing.expect(t, short_decoded, "a 16-bit length could not be decoded") { return }
	testing.expect_value(t, short.length, 256)
	testing.expect_value(t, short.header_length, 4)

	long, long_decoded := frame_header_decode([]u8{0x82, 0x7f, 0, 0, 0, 0, 0, 0x01, 0x00, 0x00, 0, 0, 0, 0})
	if !testing.expect(t, long_decoded, "a 64-bit length could not be decoded") { return }
	testing.expect_value(t, long.length, 65536)
	testing.expect_value(t, long.header_length, 10)

	// The same two lengths, written.
	encoded_short: [HEADER_MAX_SIZE]u8
	short_count, short_ok := frame_header_encode({final = true, opcode = .Binary, length = 256}, MASK, encoded_short[:])
	if !testing.expect(t, short_ok, "a 16-bit length could not be encoded") { return }
	expect_octets(t, "the 16-bit length", encoded_short[:short_count], {
		0x82, 0xfe, 0x01, 0x00, 0x37, 0xfa, 0x21, 0x3d,
	})

	encoded_long: [HEADER_MAX_SIZE]u8
	long_count, long_ok := frame_header_encode({final = true, opcode = .Binary, length = 65536}, MASK, encoded_long[:])
	if !testing.expect(t, long_ok, "a 64-bit length could not be encoded") { return }
	expect_octets(t, "the 64-bit length", encoded_long[:long_count], {
		0x82, 0xff, 0, 0, 0, 0, 0, 0x01, 0x00, 0x00, 0x37, 0xfa, 0x21, 0x3d,
	})

	// A reserved bit is a frame this client has no extension to read.
	_, reserved_ok := frame_header_decode([]u8{0x91, 0x00})
	testing.expect(t, !reserved_ok, "a frame with a reserved bit was accepted")
}

@(private)
expect_octets :: proc(t: ^testing.T, what: string, actual: []u8, expected: []u8) {
	testing.expectf(
		t,
		len(actual) == len(expected) && string(actual) == string(expected),
		"%s is not the frame RFC 6455 records",
		what,
	)
}
