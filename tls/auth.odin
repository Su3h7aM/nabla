package tls

import "base:runtime"

import "core:bytes"
import "core:crypto"
import "core:crypto/ecdsa"
import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:crypto/rsa"
import "core:crypto/x509"
import "core:mem"
import "core:net"

// Certificate_Chain is a peer's certificates, in the order the peer sent them, and
// the DER they were decoded from.
Certificate_Chain :: struct {
	certificates: []x509.Certificate,
	der:          [][]u8,
	allocator:    mem.Allocator,
}

// certificate_chain_decode reads a Certificate message body, the bytes after its
// handshake header (RFC 8446 section 4.4.2).
//
// Every certificate owns the DER it was decoded from, so the message need not
// outlive it. A server sends no certificate request context.
@(require_results)
certificate_chain_decode :: proc(message: []u8, allocator: mem.Allocator) -> (chain: Certificate_Chain, ok: bool) {
	chain.allocator = allocator

	reader := Reader {
		data = message,
		ok   = true,
	}
	if read_u8(&reader) != 0 { return {}, false }

	entries := read_section_u24(&reader)
	if !reader.ok { return {}, false }

	certificates, certificate_err := make([dynamic]x509.Certificate, 0, 4, allocator)
	ders, der_err := make([dynamic][]u8, 0, 4, allocator)
	if certificate_err != nil || der_err != nil {
		delete(certificates)
		delete(ders)
		return {}, false
	}
	failed := false
	for entries.ok && entries.at < len(entries.data) {
		encoded := read_bytes(&entries, read_u24(&entries))
		_ = read_bytes(&entries, int(read_u16(&entries))) // the entry's extensions
		if !entries.ok || certificate_append(&certificates, &ders, encoded, allocator) != .Appended {
			failed = true
			break
		}
	}

	if failed || !reader.ok || reader.at != len(reader.data) || !entries.ok || entries.at != len(entries.data) || len(certificates) == 0 {
		chain.certificates = certificates[:]
		chain.der = ders[:]
		certificate_chain_destroy(&chain)
		return {}, false
	}

	chain.certificates = certificates[:]
	chain.der = ders[:]
	return chain, true
}

// certificate_chain_destroy releases a chain and the DER its certificates view.
certificate_chain_destroy :: proc(chain: ^Certificate_Chain) {
	if chain == nil { return }
	certificates_destroy(chain.certificates, chain.der, chain.allocator)
	chain^ = {}
}

// Append_Result is how one certificate's addition to a list ended.
@(private)
Append_Result :: enum {
	Appended,
	// Malformed is DER that is not a certificate. Nothing was added.
	Malformed,
	// No_Room is an allocation that failed. Nothing was added.
	No_Room,
}

// certificate_append copies encoded into storage of its own, parses it, and adds
// the certificate and that copy to the two lists, which stay parallel. The
// certificate views the copy, so the lists are released together by
// certificates_destroy.
@(private, require_results)
certificate_append :: proc(certificates: ^[dynamic]x509.Certificate, ders: ^[dynamic][]u8, encoded: []u8, allocator: mem.Allocator) -> Append_Result {
	der, make_err := make([]u8, len(encoded), allocator)
	if make_err != nil { return .No_Room }
	copy(der, encoded)
	certificate, parse_err := x509.parse(der, allocator)
	if parse_err != nil {
		delete(der, allocator)
		return .Malformed
	}
	if _, append_err := append(certificates, certificate); append_err != nil {
		x509.destroy(&certificate, allocator)
		delete(der, allocator)
		return .No_Room
	}
	if _, append_err := append(ders, der); append_err != nil {
		// The certificate is already in the list the caller's failure path destroys.
		delete(der, allocator)
		return .No_Room
	}
	return .Appended
}

// certificates_destroy releases parsed certificates, the DER they view, and the
// two lists.
@(private)
certificates_destroy :: proc(certificates: []x509.Certificate, ders: [][]u8, allocator: mem.Allocator) {
	for &certificate in certificates { x509.destroy(&certificate, allocator) }
	delete(certificates, allocator)
	for der in ders { delete(der, allocator) }
	delete(ders, allocator)
}

// certificate_pointers returns the certificates as the pointers core's verifier
// takes, which is the caller's to free. mem_err is set when that list could not be
// allocated, and the caller owns nothing.
@(require_results)
certificate_pointers :: proc(certificates: []x509.Certificate, allocator: mem.Allocator) -> (pointers: []^x509.Certificate, mem_err: runtime.Allocator_Error) {
	pointers, mem_err = make([]^x509.Certificate, len(certificates), allocator)
	if mem_err != nil { return nil, mem_err }
	for &certificate, at in certificates { pointers[at] = &certificate }
	return pointers, nil
}

// SERVER_CERTIFICATE_VERIFY_CONTEXT is the context a server signs its
// CertificateVerify under. The input it signs is 64 space bytes, this string, a
// zero byte, and the transcript hash (RFC 8446 section 4.4.3).
SERVER_CERTIFICATE_VERIFY_CONTEXT :: "TLS 1.3, server CertificateVerify"

CERTIFICATE_VERIFY_INPUT_MAX :: 64 + len(SERVER_CERTIFICATE_VERIFY_CONTEXT) + 1 + MAX_SECRET_SIZE

// identity_verify checks the peer's certificate against the reference identifier the
// caller reached it by, which is a name or an address literal.
@(require_results)
identity_verify :: proc(certificate: ^x509.Certificate, reference: string) -> bool {
	if ip4, is_ip4 := net.parse_ip4_address(reference); is_ip4 {
		address := ip4
		return san_matches(certificate, address[:])
	}
	if ip6, is_ip6 := net.parse_ip6_address(reference); is_ip6 {
		address := transmute([16]u8)ip6
		return san_matches(certificate, address[:])
	}
	return x509.verify_hostname(certificate, reference) == .None
}

// A name is matched against the certificate's subject alternative names, and an
// address literal against the addresses among them.
@(require_results)
san_matches :: proc(certificate: ^x509.Certificate, expected: []u8) -> bool {
	for san in certificate.ip_addresses {
		if bytes.equal(san, expected) { return true }
	}
	return false
}

// certificate_verify_verify checks a CertificateVerify message body against the
// peer's end-entity certificate and the transcript of everything up to and
// including its Certificate message. A scheme this client did not offer fails.
@(require_results)
certificate_verify_verify :: proc(message: []u8, certificate: ^x509.Certificate, transcript_hash: []u8) -> bool {
	reader := Reader {
		data = message,
		ok   = true,
	}
	scheme := Signature_Scheme(read_u16(&reader))
	signature := read_bytes(&reader, int(read_u16(&reader)))
	if !reader.ok || reader.at != len(message) || len(signature) == 0 { return false }
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
@(require_results)
rsa_pss_verify :: proc(certificate: ^x509.Certificate, hash_algorithm: hash.Algorithm, input, signature: []byte) -> bool {
	public_key: rsa.Public_Key
	if !rsa.public_key_set_bytes(&public_key, certificate.rsa_n, certificate.rsa_e) { return false }
	return rsa.verify_pss(&public_key, hash_algorithm, hash.DIGEST_SIZES[hash_algorithm], input, signature)
}

// A TLS 1.3 ECDSA signature is the DER-encoded ECDSA-Sig-Value (RFC 8446
// section 4.4.3).
@(require_results)
ecdsa_verify :: proc(certificate: ^x509.Certificate, curve: ecdsa.Curve, hash_algorithm: hash.Algorithm, input, signature: []byte) -> bool {
	public_key: ecdsa.Public_Key
	if !ecdsa.public_key_set_bytes(&public_key, curve, certificate.ec_point) { return false }
	return ecdsa.verify_asn1(&public_key, hash_algorithm, input, signature)
}

@(require_results)
ed25519_verify :: proc(certificate: ^x509.Certificate, input, signature: []byte) -> bool {
	public_key: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&public_key, certificate.ec_point) { return false }
	return ed25519.verify(&public_key, input, signature)
}

// finished_verify checks the verify_data of a Finished message body, which
// authenticates every handshake message before it under the traffic secret of the
// sender's direction (RFC 8446 section 4.4.4).
@(require_results)
finished_verify :: proc(suite: Cipher_Suite, secret: []u8, transcript_hash: []u8, verify_data: []u8) -> bool {
	size := secret_size(suite)
	finished_key: [MAX_SECRET_SIZE]u8
	defer crypto.zero_explicit(&finished_key, size_of(finished_key))
	if !hkdf_expand_label(suite, secret, "finished", {}, finished_key[:size]) { return false }

	mac: [hash.MAX_DIGEST_SIZE]u8
	hmac.sum(CIPHER_SUITES[suite].hash, mac[:size], transcript_hash, finished_key[:size])
	// compare_constant_time returns 1 for equal and 0 otherwise.
	return crypto.compare_constant_time(mac[:size], verify_data) == 1
}
