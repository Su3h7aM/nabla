package http

import "core:strings"

// Headers is a field section keyed by lowercase field name. Field names are
// case-insensitive (RFC 9110 5.1). The _unsafe procedures take a name that is
// already lowercase; the others lowercase it first.
Headers :: struct {
	_kv:      map[string]string,
	readonly: bool,
}

// headers_init sets the allocator the section's map, and every name and value
// header_parse copies into it, is owned by.
headers_init :: proc(h: ^Headers, allocator := context.temp_allocator) {
	h._kv.allocator = allocator
}

// headers_destroy releases a section filled by header_parse: its names, its
// values, and the map.
headers_destroy :: proc(h: ^Headers) {
	allocator := h._kv.allocator
	for key, value in h._kv {
		delete(value, allocator)
		delete(key, allocator)
	}
	delete(h._kv)
	h^ = {}
}

headers_count :: #force_inline proc(h: Headers) -> int {
	return len(h._kv)
}

// headers_set stores a value under a name it lowercases first, and returns that
// name. The section borrows the value.
headers_set :: proc(h: ^Headers, k: string, v: string, loc := #caller_location) -> string {
	assert(!h.readonly, "these headers are readonly, did you accidentally try to set a header on the request?", loc)
	l := sanitize_key(h^, k)
	h._kv[l] = v
	return l
}

headers_set_unsafe :: #force_inline proc(h: ^Headers, k: string, v: string, loc := #caller_location) {
	assert(!h.readonly, "these headers are readonly, did you accidentally try to set a header on the request?", loc)
	h._kv[k] = v
}

headers_get :: proc(h: Headers, k: string) -> (string, bool) #optional_ok {
	return h._kv[sanitize_key(h, k)]
}

headers_get_unsafe :: #force_inline proc(h: Headers, k: string) -> (string, bool) #optional_ok {
	return h._kv[k]
}

headers_entry :: proc(h: ^Headers, k: string, loc := #caller_location) -> (key_ptr: ^string, value_ptr: ^string, just_inserted: bool) {
	assert(!h.readonly, "these headers are readonly, did you accidentally try to set a header on the request?", loc)
	key_ptr, value_ptr, just_inserted, _ = map_entry(&h._kv, sanitize_key(h^, k))
	return
}

headers_entry_unsafe :: #force_inline proc(h: ^Headers, k: string, loc := #caller_location) -> (key_ptr: ^string, value_ptr: ^string, just_inserted: bool) {
	assert(!h.readonly, "these headers are readonly, did you accidentally try to set a header on the request?", loc)
	key_ptr, value_ptr, just_inserted, _ = map_entry(&h._kv, k)
	return
}

headers_has :: proc(h: Headers, k: string) -> bool {
	return sanitize_key(h, k) in h._kv
}

headers_has_unsafe :: #force_inline proc(h: Headers, k: string) -> bool {
	return k in h._kv
}

headers_delete :: proc(h: ^Headers, k: string) -> (deleted_key: string, deleted_value: string) {
	return delete_key(&h._kv, sanitize_key(h^, k))
}

headers_delete_unsafe :: #force_inline proc(h: ^Headers, k: string) {
	delete_key(&h._kv, k)
}

headers_set_content_type :: proc {
	headers_set_content_type_mime,
	headers_set_content_type_string,
}

headers_set_content_type_string :: #force_inline proc(h: ^Headers, ct: string) {
	headers_set_unsafe(h, "content-type", ct)
}

headers_set_content_type_mime :: #force_inline proc(h: ^Headers, ct: Mime_Type) {
	headers_set_unsafe(h, "content-type", mime_to_content_type(ct))
}

headers_set_close :: #force_inline proc(h: ^Headers) {
	headers_set_unsafe(h, "connection", "close")
}

// sanitize_key lowercases ASCII and escapes newlines, so a name can neither
// miss a lookup by case nor split a field line when written.
@(private = "package")
sanitize_key :: proc(h: Headers, k: string) -> string {
	allocator := h._kv.allocator if h._kv.allocator.procedure != nil else context.temp_allocator
	b := strings.builder_make(0, len(k), allocator)
	for c in k {
		switch c {
		case 'A' ..= 'Z':
			strings.write_rune(&b, c + 32)
		case '\n':
			strings.write_string(&b, "\\n")
		case:
			strings.write_rune(&b, c)
		}
	}
	return strings.to_string(b)
}
