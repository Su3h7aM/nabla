#+test
package tls

import "core:bytes"
import "core:crypto/x25519"
import "core:encoding/hex"
import "core:testing"

// RFC 8448 section 3, "Simple 1-RTT Handshake", records every intermediate value
// of a TLS 1.3 handshake and the records the peers exchanged. Holding this
// package against the protocol's own trace is what makes a failure here a
// failure against the RFC rather than against this package's assumptions.
RFC8448_TRANSCRIPT_HASH :: "860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8" // 32 octets

RFC8448_EARLY_SECRET :: "33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a" // 32 octets

RFC8448_ECDHE_SHARED_SECRET :: "8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d" // 32 octets

RFC8448_HANDSHAKE_SECRET :: "1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac" // 32 octets

RFC8448_CLIENT_HANDSHAKE_TRAFFIC_SECRET :: "b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21" // 32 octets

RFC8448_SERVER_HANDSHAKE_TRAFFIC_SECRET :: "b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38" // 32 octets

RFC8448_MASTER_SECRET :: "18df06843d13a08bf2a449844c5f8a478001bc4d4c627984d5a41da8d0402919" // 32 octets

RFC8448_SERVER_HANDSHAKE_KEY :: "3fce516009c21727d0f2e4e86ee403bc" // 16 octets

RFC8448_SERVER_HANDSHAKE_IV :: "5d313eb2671276ee13000b30" // 12 octets

// 679 octets.
RFC8448_SERVER_FLIGHT_RECORD ::
	"17030302a2d1ff334a56f5bff6594a07cc87b580233f500f45e489e7f33af35e" +
	"df7869fcf40aa40aa2b8ea73f848a7ca07612ef9f945cb960b4068905123ea78" +
	"b111b429ba9191cd05d2a389280f526134aadc7fc78c4b729df828b5ecf7b13b" +
	"d9aefb0e57f271585b8ea9bb355c7c79020716cfb9b1183ef3ab20e37d57a6b9" +
	"d7477609aee6e122a4cf51427325250c7d0e509289444c9b3a648f1d71035d2e" +
	"d65b0e3cdd0cbae8bf2d0b227812cbb360987255cc744110c453baa4fcd61092" +
	"8d809810e4b7ed1a8fd991f06aa6248204797e36a6a73b70a2559c09ead68694" +
	"5ba246ab66e5edd8044b4c6de3fcf2a89441ac66272fd8fb330ef8190579b368" +
	"4596c960bd596eea520a56a8d650f563aad27409960dca63d3e688611ea5e22f" +
	"4415cf9538d51a200c27034272968a264ed6540c84838d89f72c24461aad6d26" +
	"f59ecaba9acbbb317b66d902f4f292a36ac1b639c637ce343117b65962224531" +
	"7b49eeda0c6258f100d7d961ffb138647e92ea330faeea6dfa31c7a84dc3bd7e" +
	"1b7a6c7178af36879018e3f252107f243d243dc7339d5684c8b0378bf30244da" +
	"8c87c843f5e56eb4c5e8280a2b48052cf93b16499a66db7cca71e4599426f7d4" +
	"61e66f99882bd89fc50800becca62d6c74116dbd2972fda1fa80f85df881edbe" +
	"5a37668936b335583b599186dc5c6918a396fa48a181d6b6fa4f9d62d513afbb" +
	"992f2b992f67f8afe67f76913fa388cb5630c8ca01e0c65d11c66a1e2ac4c859" +
	"77b7c7a6999bbf10dc35ae69f5515614636c0b9b68c19ed2e31c0b3b66763038" +
	"ebba42f3b38edc0399f3a9f23faa63978c317fc9fa66a73f60f0504de93b5b84" +
	"5e275592c12335ee340bbc4fddd502784016e4b3be7ef04dda49f4b440a30cb5" +
	"d2af939828fd4ae3794e44f94df5a631ede42c1719bfdabf0253fe5175be898e" +
	"750edc53370d2b"

// 657 octets.
RFC8448_SERVER_FLIGHT_PLAINTEXT ::
	"080000240022000a00140012001d00170018001901000101010201030104001c" +
	"00024001000000000b0001b9000001b50001b0308201ac30820115a003020102" +
	"020102300d06092a864886f70d01010b0500300e310c300a0603550403130372" +
	"7361301e170d3136303733303031323335395a170d3236303733303031323335" +
	"395a300e310c300a0603550403130372736130819f300d06092a864886f70d01" +
	"0101050003818d0030818902818100b4bb498f8279303d980836399b36c6988c" +
	"0c68de55e1bdb826d3901a2461eafd2de49a91d015abbc9a95137ace6c1af19e" +
	"aa6af98c7ced43120998e187a80ee0ccb0524b1b018c3e0b63264d449a6d38e2" +
	"2a5fda430846748030530ef0461c8ca9d9efbfae8ea6d1d03e2bd193eff0ab9a" +
	"8002c47428a6d35a8d88d79f7f1e3f0203010001a31a301830090603551d1304" +
	"023000300b0603551d0f0404030205a0300d06092a864886f70d01010b050003" +
	"81810085aad2a0e5b9276b908c65f73a7267170618a54c5f8a7b337d2df7a594" +
	"365417f2eae8f8a58c8f8172f9319cf36b7fd6c55b80f21a03015156726096fd" +
	"335e5e67f2dbf102702e608ccae6bec1fc63a42a99be5c3eb7107c3c54e9b9eb" +
	"2bd5203b1c3b84e0a8b2f759409ba3eac9d91d402dcc0cc8f8961229ac9187b4" +
	"2b4de100000f000084080400805a747c5d88fa9bd2e55ab085a61015b7211f82" +
	"4cd484145ab3ff52f1fda8477b0b7abc90db78e2d33a5c141a078653fa6bef78" +
	"0c5ea248eeaaa785c4f394cab6d30bbe8d4859ee511f602957b15411ac027671" +
	"459e46445c9ea58c181e818e95b8c3fb0bf3278409d3be152a3da5043e063dda" +
	"65cdf5aea20d53dfacd42f74f3140000209b9b141d906337fbd2cbdce71df4de" +
	"da4ab42c309572cb7fffee5454b78f0718"

// 90 octets.
RFC8448_SERVER_HELLO ::
	"020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155" +
	"772ed3e2692800130100002e00330024001d0020c9828876112095fe66762bdb" +
	"f7c672e156d6cc253b833df1dd69b1b04e751f0f002b00020304"

// 196 octets.
RFC8448_CLIENT_HELLO ::
	"010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef" +
	"6283024dece7000006130113031302010000910000000b000900000673657276" +
	"6572ff01000100000a00140012001d0017001800190100010101020103010400" +
	"230000003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c06e" +
	"51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603" +
	"020308040805080604010501060102010402050206020202002d00020101001c" +
	"00024001"

RFC8448_CLIENT_PRIVATE_KEY :: "49af42ba7f7994852d713ef2784bcbcaa7911de26adc5642cb634540e7ea5005" // 32 octets

// 445 octets.
RFC8448_CERTIFICATE ::
	"0b0001b9000001b50001b0308201ac30820115a003020102020102300d06092a" +
	"864886f70d01010b0500300e310c300a06035504031303727361301e170d3136" +
	"303733303031323335395a170d3236303733303031323335395a300e310c300a" +
	"0603550403130372736130819f300d06092a864886f70d010101050003818d00" +
	"30818902818100b4bb498f8279303d980836399b36c6988c0c68de55e1bdb826" +
	"d3901a2461eafd2de49a91d015abbc9a95137ace6c1af19eaa6af98c7ced4312" +
	"0998e187a80ee0ccb0524b1b018c3e0b63264d449a6d38e22a5fda4308467480" +
	"30530ef0461c8ca9d9efbfae8ea6d1d03e2bd193eff0ab9a8002c47428a6d35a" +
	"8d88d79f7f1e3f0203010001a31a301830090603551d1304023000300b060355" +
	"1d0f0404030205a0300d06092a864886f70d01010b05000381810085aad2a0e5" +
	"b9276b908c65f73a7267170618a54c5f8a7b337d2df7a594365417f2eae8f8a5" +
	"8c8f8172f9319cf36b7fd6c55b80f21a03015156726096fd335e5e67f2dbf102" +
	"702e608ccae6bec1fc63a42a99be5c3eb7107c3c54e9b9eb2bd5203b1c3b84e0" +
	"a8b2f759409ba3eac9d91d402dcc0cc8f8961229ac9187b42b4de10000"

@(test)
test_rfc_8448_simple_handshake :: proc(t: ^testing.T) {
	schedule := key_schedule_init(.AES_128_GCM_SHA256)
	expect_bytes(t, "early secret", schedule.secret[:32], vector(t, RFC8448_EARLY_SECRET))

	if !testing.expect(t, key_schedule_advance(&schedule, vector(t, RFC8448_ECDHE_SHARED_SECRET))) { return }
	expect_bytes(t, "handshake secret", schedule.secret[:32], vector(t, RFC8448_HANDSHAKE_SECRET))

	client_secret, server_secret: Secret
	transcript_hash := vector(t, RFC8448_TRANSCRIPT_HASH)
	if !testing.expect(t, key_schedule_traffic_secrets(&schedule, transcript_hash, &client_secret, &server_secret)) { return }
	expect_bytes(t, "client handshake traffic secret", client_secret[:32], vector(t, RFC8448_CLIENT_HANDSHAKE_TRAFFIC_SECRET))
	expect_bytes(t, "server handshake traffic secret", server_secret[:32], vector(t, RFC8448_SERVER_HANDSHAKE_TRAFFIC_SECRET))

	server_key: Traffic_Key
	if !testing.expect(t, traffic_key_derive(schedule.suite, server_secret[:32], &server_key)) { return }
	expect_bytes(t, "server handshake key", server_key.key[:16], vector(t, RFC8448_SERVER_HANDSHAKE_KEY))
	expect_bytes(t, "server handshake nonce", server_key.iv[:], vector(t, RFC8448_SERVER_HANDSHAKE_IV))

	record := vector(t, RFC8448_SERVER_FLIGHT_RECORD)
	flight := vector(t, RFC8448_SERVER_FLIGHT_PLAINTEXT)

	// Protecting the flight with that key has to reproduce the RFC's record,
	// which is the only check on the write path that does not come from this
	// package reading its own output.
	protected := make([]u8, len(record), context.temp_allocator)
	count, protected_ok := record_protect(schedule.suite, &server_key, .Handshake, flight, protected)
	if !testing.expect(t, protected_ok) { return }
	expect_bytes(t, "protected record", protected[:count], record)

	// Unprotecting runs last, as it decrypts the record in place.
	server_key.sequence = 0
	content, content_type, opened := record_unprotect(schedule.suite, &server_key, record)
	if !testing.expect(t, opened) { return }
	testing.expect_value(t, content_type, Record_Type.Handshake)
	expect_bytes(t, "server flight", content, flight)

	zeros: [32]u8
	if !testing.expect(t, key_schedule_advance(&schedule, zeros[:])) { return }
	expect_bytes(t, "master secret", schedule.secret[:32], vector(t, RFC8448_MASTER_SECRET))
}

@(test)
test_traffic_update_uses_an_empty_context :: proc(t: ^testing.T) {
	secret: [32]u8
	for &octet, index in secret { octet = u8(index) }

	updated: Secret
	if !testing.expect(t, key_schedule_update(.AES_128_GCM_SHA256, secret[:], updated[:32])) { return }
	expect_bytes(t, "updated traffic secret", updated[:32], vector(t, "2cecd0a17506ef5fa73edc062d6e7b5397cf074ec1b4d8f99a120772932f0b45"))
}

@(test)
test_rfc_8448_server_hello :: proc(t: ^testing.T) {
	message := vector(t, RFC8448_SERVER_HELLO)
	handshake_type, message_length, decoded := handshake_decode_header(message)
	if !testing.expect(t, decoded) { return }
	testing.expect_value(t, handshake_type, Handshake_Type.Server_Hello)
	testing.expect_value(t, message_length, len(message) - HANDSHAKE_HEADER_SIZE)

	hello, ok := server_hello_decode(message[HANDSHAKE_HEADER_SIZE:])
	if !testing.expect(t, ok) { return }
	testing.expect_value(t, hello.cipher_suite, Cipher_Suite.AES_128_GCM_SHA256)
	testing.expect_value(t, hello.version, VERSION_1_3)
	testing.expect_value(t, hello.group, Named_Group.X25519)

	// The other half of the trace's key exchange: the RFC's server key share and
	// the RFC's client private key have to produce the RFC's shared secret, which
	// is what the handshake secret was extracted from.
	shared_secret: [x25519.POINT_SIZE]u8
	x25519.scalarmult(shared_secret[:], vector(t, RFC8448_CLIENT_PRIVATE_KEY), hello.keyshare)
	expect_bytes(t, "shared secret", shared_secret[:], vector(t, RFC8448_ECDHE_SHARED_SECRET))
}

// vector decodes a test vector the tests of this package share.
@(private = "package")
vector :: proc(t: ^testing.T, hex_text: string) -> []u8 {
	decoded, ok := hex.decode(transmute([]u8)hex_text, context.temp_allocator)
	if !ok { testing.fail_now(t, "a test vector is not hexadecimal") }
	return decoded
}

// expect_bytes compares a decoded field against the bytes a vector fixes.
@(private = "package")
expect_bytes :: proc(t: ^testing.T, what: string, actual, expected: []u8) {
	testing.expectf(t, bytes.equal(actual, expected), "%s is not the bytes the vector fixes", what)
}
