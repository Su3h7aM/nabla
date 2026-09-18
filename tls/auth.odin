package tls

import "core:crypto/ecdsa"
import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:crypto/rsa"
import "core:crypto/x509"
import "core:mem"

// certificate_list_decode reads a Certificate message body, the bytes after its
// handshake header (RFC 8446 section 4.4.2).
//
// A server sends no certificate request context, and every certificate holds views
// into `message`, so it must outlive them. certificate_list_destroy releases what
// each parsed certificate allocated, and the list itself.
certificate_list_decode :: proc(message: []u8, allocator: mem.Allocator) -> (certificates: []x509.Certificate, ok: bool) {
	r := Reader{data = message, ok = true}
	if read_u8(&r) != 0 { return nil, false }

	entries := read_section_u24(&r)
	if !r.ok { return nil, false }

	list := make([dynamic]x509.Certificate, 0, 4, allocator)
	for entries.ok && entries.at < len(entries.data) {
		der := read_bytes(&entries, read_u24(&entries))
		_ = read_bytes(&entries, int(read_u16(&entries)))  // the entry's extensions
		certificate, parse_err := x509.parse(der, allocator)
		if parse_err != nil || !entries.ok { break }
		append(&list, certificate)
	}
	if entries.ok && entries.at == len(entries.data) && len(list) > 0 { return list[:], true }

	for &certificate in list { x509.destroy(&certificate, allocator) }
	delete(list)
	return nil, false
}

// certificate_list_destroy releases a list from certificate_list_decode. The
// certificates still borrow from the message they were decoded from, which the
// caller owns and may have released already.
certificate_list_destroy :: proc(certificates: []x509.Certificate, allocator: mem.Allocator) {
	for &certificate in certificates { x509.destroy(&certificate, allocator) }
	delete(certificates, allocator)
}

// SERVER_CERTIFICATE_VERIFY_CONTEXT is the context a server signs its
// CertificateVerify under. The input it signs is 64 space bytes, this string, a
// zero byte, and the transcript hash (RFC 8446 section 4.4.3).
SERVER_CERTIFICATE_VERIFY_CONTEXT :: "TLS 1.3, server CertificateVerify"

CERTIFICATE_VERIFY_INPUT_MAX :: 64 + len(SERVER_CERTIFICATE_VERIFY_CONTEXT) + 1 + MAX_SECRET_SIZE

// certificate_verify_verify checks a CertificateVerify message body against the
// peer's end-entity certificate and the transcript of everything up to and
// including its Certificate message. A scheme this client did not offer fails.
certificate_verify_verify :: proc(message: []u8, certificate: ^x509.Certificate, transcript_hash: []u8) -> bool {
	r := Reader{data = message, ok = true}
	scheme := Signature_Scheme(read_u16(&r))
	signature := read_bytes(&r, int(read_u16(&r)))
	if !r.ok || r.at != len(message) || len(signature) == 0 { return false }
	if len(transcript_hash) > MAX_SECRET_SIZE { return false }

	input: [CERTIFICATE_VERIFY_INPUT_MAX]u8
	at := 0
	for _ in 0 ..< 64 {
		input[at] = 0x20
		at += 1
	}
	at += copy(input[at:], SERVER_CERTIFICATE_VERIFY_CONTEXT)
	input[at] = 0
	at += 1
	at += copy(input[at:], transcript_hash)

	switch scheme {
	case .RSA_PSS_RSAE_SHA256:
		return rsa_pss_verify(certificate, .SHA256, input[:at], signature)
	case .RSA_PSS_RSAE_SHA384:
		return rsa_pss_verify(certificate, .SHA384, input[:at], signature)
	case .RSA_PSS_RSAE_SHA512:
		return rsa_pss_verify(certificate, .SHA512, input[:at], signature)
	case .ECDSA_SECP256R1_SHA256:
		return ecdsa_verify(certificate, .SECP256R1, .SHA256, input[:at], signature)
	case .ECDSA_SECP384R1_SHA384:
		return ecdsa_verify(certificate, .SECP384R1, .SHA384, input[:at], signature)
	case .ED25519:
		return ed25519_verify(certificate, input[:at], signature)
	}
	return false
}

// TLS 1.3 fixes the PSS parameters: MGF1 with the same hash, and a salt as long as
// the digest (RFC 8446 section 4.2.3).
rsa_pss_verify :: proc(certificate: ^x509.Certificate, hash_algorithm: hash.Algorithm, input, signature: []byte) -> bool {
	public_key: rsa.Public_Key
	if !rsa.public_key_set_bytes(&public_key, certificate.rsa_n, certificate.rsa_e) { return false }
	return rsa.verify_pss(&public_key, hash_algorithm, hash.DIGEST_SIZES[hash_algorithm], input, signature)
}

// A TLS 1.3 ECDSA signature is the DER-encoded ECDSA-Sig-Value (RFC 8446
// section 4.4.3).
ecdsa_verify :: proc(certificate: ^x509.Certificate, curve: ecdsa.Curve, hash_algorithm: hash.Algorithm, input, signature: []byte) -> bool {
	public_key: ecdsa.Public_Key
	if !ecdsa.public_key_set_bytes(&public_key, curve, certificate.ec_point) { return false }
	return ecdsa.verify_asn1(&public_key, hash_algorithm, input, signature)
}

ed25519_verify :: proc(certificate: ^x509.Certificate, input, signature: []byte) -> bool {
	public_key: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&public_key, certificate.ec_point) { return false }
	return ed25519.verify(&public_key, input, signature)
}
