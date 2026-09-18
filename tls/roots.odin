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

/*
roots_parse reads every certificate of a PEM trust store, in the order the blocks
appear.

A block that is not a certificate is left alone, and one that does not parse is
skipped: a store may carry other labels, and dropping an anchor can only refuse a
chain, never admit one. Empty text, or text with no readable certificate, is not a
trust store.
*/
roots_parse :: proc(text: []u8, allocator: mem.Allocator) -> (roots: Roots, ok: bool) {
	roots.allocator = allocator

	certificates := make([dynamic]x509.Certificate, 0, 16, allocator)
	ders := make([dynamic][]u8, 0, 16, allocator)

	remaining := text
	for {
		block, rest, err := pem.decode(remaining, allocator)
		if block != nil {
			if block.label == pem.LABEL_CERTIFICATE {
				der := make([]u8, len(block.data), allocator)
				copy(der, block.data[:])
				certificate, parse_err := x509.parse(der, allocator)
				if parse_err == nil {
					append(&certificates, certificate)
					append(&ders, der)
				} else {
					delete(der, allocator)
				}
			}
			delete(block.data)
			free(block, allocator)
		}
		if err != nil || block == nil { break }
		remaining = rest
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
	allocator := roots.allocator
	for &certificate in roots.certificates { x509.destroy(&certificate, allocator) }
	delete(roots.certificates, allocator)
	for der in roots.der { delete(der, allocator) }
	delete(roots.der, allocator)
	roots^ = {}
}
