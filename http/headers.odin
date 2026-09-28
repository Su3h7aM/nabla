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
headers_init :: proc(headers: ^Headers, allocator := context.temp_allocator) {
	headers._kv.allocator = allocator
}

// headers_destroy releases a section filled by header_parse: its names, its
// values, and the map.
headers_destroy :: proc(headers: ^Headers) {
	allocator := headers._kv.allocator
	for key, value in headers._kv {
		delete(value, allocator)
		delete(key, allocator)
	}
	delete(headers._kv)
	headers^ = {}
}

headers_count :: #force_inline proc(headers: Headers) -> int {
	return len(headers._kv)
}

// headers_set stores a value under a name it lowercases first, and returns that
// name. The section borrows the value.
headers_set :: proc(headers: ^Headers, key: string, value: string, loc := #caller_location) -> string {
	assert(!headers.readonly, "these headers are readonly, did you accidentally try to set a header on the request?", loc)
	name := sanitize_key(headers^, key)
	headers._kv[name] = value
	return name
}

headers_set_unsafe :: #force_inline proc(headers: ^Headers, key: string, value: string, loc := #caller_location) {
	assert(!headers.readonly, "these headers are readonly, did you accidentally try to set a header on the request?", loc)
	headers._kv[key] = value
}

headers_get :: proc(headers: Headers, key: string) -> (string, bool) #optional_ok {
	return headers._kv[sanitize_key(headers, key)]
}

headers_get_unsafe :: #force_inline proc(headers: Headers, key: string) -> (string, bool) #optional_ok {
	return headers._kv[key]
}

headers_entry :: proc(headers: ^Headers, key: string, loc := #caller_location) -> (key_ptr: ^string, value_ptr: ^string, just_inserted: bool) {
	assert(!headers.readonly, "these headers are readonly, did you accidentally try to set a header on the request?", loc)
	key_ptr, value_ptr, just_inserted, _ = map_entry(&headers._kv, sanitize_key(headers^, key))
	return
}

headers_entry_unsafe :: #force_inline proc(
	headers: ^Headers,
	key: string,
	loc := #caller_location,
) -> (
	key_ptr: ^string,
	value_ptr: ^string,
	just_inserted: bool,
) {
	assert(!headers.readonly, "these headers are readonly, did you accidentally try to set a header on the request?", loc)
	key_ptr, value_ptr, just_inserted, _ = map_entry(&headers._kv, key)
	return
}

headers_has :: proc(headers: Headers, key: string) -> bool {
	return sanitize_key(headers, key) in headers._kv
}

headers_has_unsafe :: #force_inline proc(headers: Headers, key: string) -> bool {
	return key in headers._kv
}

headers_delete :: proc(headers: ^Headers, key: string) -> (deleted_key: string, deleted_value: string) {
	return delete_key(&headers._kv, sanitize_key(headers^, key))
}

headers_delete_unsafe :: #force_inline proc(headers: ^Headers, key: string) {
	delete_key(&headers._kv, key)
}

headers_set_content_type :: proc {
	headers_set_content_type_mime,
	headers_set_content_type_string,
}

headers_set_content_type_string :: #force_inline proc(headers: ^Headers, content_type: string) {
	headers_set_unsafe(headers, "content-type", content_type)
}

headers_set_content_type_mime :: #force_inline proc(headers: ^Headers, content_type: Mime_Type) {
	headers_set_unsafe(headers, "content-type", mime_to_content_type(content_type))
}

headers_set_close :: #force_inline proc(headers: ^Headers) {
	headers_set_unsafe(headers, "connection", "close")
}

// sanitize_key lowercases ASCII and escapes newlines, so a name can neither
// miss a lookup by case nor split a field line when written. The result is owned
// by the section's allocator.
@(private = "package")
sanitize_key :: proc(headers: Headers, key: string) -> string {
	allocator := headers._kv.allocator if headers._kv.allocator.procedure != nil else context.temp_allocator
	builder := strings.builder_make(0, len(key), allocator)
	for character in key {
		switch character {
		case 'A' ..= 'Z':
			strings.write_rune(&builder, character + 32)
		case '\n':
			strings.write_string(&builder, "\\n")
		case:
			strings.write_rune(&builder, character)
		}
	}
	return strings.to_string(builder)
}
