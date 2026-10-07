package tls

import "core:crypto/x509"
import "core:encoding/pem"
import "core:mem"

// Roots is a set of certificates a chain is allowed to end at. A trust store is
// distributed as PEM text, and every certificate views the decode of one of its
// blocks, which roots_destroy releases along with the certificates.
Roots :: struct {
	certificates: []x509.Certificate,
	der:          [][]u8,
	allocator:    mem.Allocator,
}

// roots_parse reads every certificate of a PEM trust store, in the order the blocks
// appear. A block that is not a certificate is left alone, and one that does not
// parse is skipped: a store may carry other labels, and dropping an anchor can only
// refuse a chain, never admit one. Empty text, or text with no readable certificate,
// is not a trust store.
@(require_results)
roots_parse :: proc(text: []u8, allocator: mem.Allocator) -> (roots: Roots, ok: bool) {
	roots.allocator = allocator

	certificates, certificate_err := make([dynamic]x509.Certificate, 0, 16, allocator)
	ders, der_err := make([dynamic][]u8, 0, 16, allocator)
	if certificate_err != nil || der_err != nil {
		delete(certificates)
		delete(ders)
		return {}, false
	}

	failed := false
	remaining := text
	for {
		block, rest, err := pem.decode(remaining, allocator)
		if block != nil {
			// A block that does not parse is skipped; only a failed allocation ends the store.
			if block.label == pem.LABEL_CERTIFICATE && certificate_append(&certificates, &ders, block.data[:], allocator) == .No_Room {
				failed = true
			}
			pem.block_delete(block)
		}
		if failed || err != nil || block == nil { break }
		remaining = rest
	}

	if failed {
		roots.certificates = certificates[:]
		roots.der = ders[:]
		roots_destroy(&roots)
		return {}, false
	}

	if len(certificates) == 0 {
		delete(certificates)
		delete(ders)
		return {}, false
	}

	roots.certificates = certificates[:]
	roots.der = ders[:]
	return roots, true
}

roots_destroy :: proc(roots: ^Roots) {
	if roots == nil { return }
	certificates_destroy(roots.certificates, roots.der, roots.allocator)
	roots^ = {}
}
