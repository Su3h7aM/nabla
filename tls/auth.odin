package tls

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
