package http

import "base:runtime"

import "core:strings"

// Headers is a field section keyed by lowercase field name. Field names are
// case-insensitive (RFC 9110 5.1). The _unsafe procedures take a name that is
// already lowercase and never allocate; the others lowercase it first, which
// needs the section's own allocator.
Headers :: struct {
	_kv:                map[string]string,
	_set_cookie_values: [dynamic]string,
	readonly:           bool,
}

// headers_init sets the allocator that owns the section's map, extra Set-Cookie
// values, and each name and value header_parse copies into it.
headers_init :: proc(headers: ^Headers, allocator := context.temp_allocator) {
	headers._kv.allocator = allocator
	headers._set_cookie_values.allocator = allocator
}

// headers_destroy releases a section filled by header_parse: its names, values,
// extra Set-Cookie values, and the map.
headers_destroy :: proc(headers: ^Headers) {
	allocator := headers._kv.allocator
	for key, value in headers._kv {
		delete(value, allocator)
		delete(key, allocator)
	}
	headers_clear_set_cookie_values(headers)
	delete(headers._set_cookie_values)
	delete(headers._kv)
	headers^ = {}
}

headers_count :: #force_inline proc(headers: Headers) -> int {
	return len(headers._kv)
}

// headers_set stores a value under a name it lowercases first, and returns that
// name. The section borrows the value. mem_err is set, and nothing is stored,
// when the name could not be built.
@(require_results)
headers_set :: proc(headers: ^Headers, key: string, value: string, loc := #caller_location) -> (name: string, mem_err: runtime.Allocator_Error) {
	assert(!headers.readonly, "these headers are readonly, did you accidentally try to set a header on the request?", loc)
	name, mem_err = sanitize_key(headers^, key)
	if mem_err != nil { return }
	headers._kv[name] = value
	if name == "set-cookie" { headers_clear_set_cookie_values(headers) }
	return
}

headers_set_unsafe :: #force_inline proc(headers: ^Headers, key: string, value: string, loc := #caller_location) {
	assert(!headers.readonly, "these headers are readonly, did you accidentally try to set a header on the request?", loc)
	headers._kv[key] = value
	if key == "set-cookie" { headers_clear_set_cookie_values(headers) }
}

// headers_get returns the value stored under a name it lowercases first, and
// whether a field has that name. mem_err is set, and nothing is looked up, when
// the name could not be built.
@(require_results)
headers_get :: proc(headers: Headers, key: string) -> (value: string, found: bool, mem_err: runtime.Allocator_Error) {
	name, name_err := sanitize_key(headers, key)
	if name_err != nil { return "", false, name_err }
	defer delete(name, headers_allocator(headers))
	value, found = headers._kv[name]
	return
}

headers_get_unsafe :: #force_inline proc(headers: Headers, key: string) -> (string, bool) #optional_ok {
	return headers._kv[key]
}

// headers_get_all returns an allocated list of a field's values in received
// order. The list uses allocator. Its strings borrow from headers and remain
// valid while their source values remain valid and headers is unchanged. Other
// than Set-Cookie, a repeated field is returned as its single combined value.
// err is set if the field name or list could not be allocated.
@(require_results)
headers_get_all :: proc(headers: Headers, key: string, allocator: runtime.Allocator) -> (values: []string, found: bool, err: runtime.Allocator_Error) {
	name, name_err := sanitize_key(headers, key)
	if name_err != nil { return nil, false, name_err }
	defer delete(name, headers_allocator(headers))

	first, present := headers._kv[name]
	if !present { return nil, false, nil }

	count := 1
	if name == "set-cookie" { count += len(headers._set_cookie_values) }
	values, err = make([]string, count, allocator)
	if err != nil { return nil, false, err }
	values[0] = first
	if name == "set-cookie" {
		for value, index in headers._set_cookie_values {
			values[index + 1] = value
		}
	}
	return values, true, nil
}

// headers_entry returns the entry for a name it lowercases first, inserted with a
// zero value when the section had none. mem_err is set when the name could not be
// built, or when the entry's allocation failed.
@(require_results)
headers_entry :: proc(
	headers: ^Headers,
	key: string,
	loc := #caller_location,
) -> (
	key_ptr: ^string,
	value_ptr: ^string,
	just_inserted: bool,
	mem_err: runtime.Allocator_Error,
) {
	assert(!headers.readonly, "these headers are readonly, did you accidentally try to set a header on the request?", loc)
	name, name_err := sanitize_key(headers^, key)
	if name_err != nil { return nil, nil, false, name_err }
	key_ptr, value_ptr, just_inserted, mem_err = map_entry(&headers._kv, name)
	// The map keeps the name only when it inserted it.
	if mem_err != nil || !just_inserted { delete(name, headers_allocator(headers^)) }
	return
}

@(require_results)
headers_entry_unsafe :: #force_inline proc(
	headers: ^Headers,
	key: string,
	loc := #caller_location,
) -> (
	key_ptr: ^string,
	value_ptr: ^string,
	just_inserted: bool,
	mem_err: runtime.Allocator_Error,
) {
	assert(!headers.readonly, "these headers are readonly, did you accidentally try to set a header on the request?", loc)
	key_ptr, value_ptr, just_inserted, mem_err = map_entry(&headers._kv, key)
	return
}

// headers_has reports whether a field has a name it lowercases first. mem_err is
// set, and has is false, when the name could not be built.
@(require_results)
headers_has :: proc(headers: Headers, key: string) -> (has: bool, mem_err: runtime.Allocator_Error) {
	name, name_err := sanitize_key(headers, key)
	if name_err != nil { return false, name_err }
	defer delete(name, headers_allocator(headers))
	return name in headers._kv, nil
}

@(require_results)
headers_has_unsafe :: #force_inline proc(headers: Headers, key: string) -> bool {
	return key in headers._kv
}

// headers_delete removes the field with a name it lowercases first, returning what
// it removed. mem_err is set, and nothing is removed, when the name could not be
// built.
@(require_results)
headers_delete :: proc(headers: ^Headers, key: string) -> (deleted_key: string, deleted_value: string, mem_err: runtime.Allocator_Error) {
	name, name_err := sanitize_key(headers^, key)
	if name_err != nil { return "", "", name_err }
	defer delete(name, headers_allocator(headers^))
	deleted_key, deleted_value = delete_key(&headers._kv, name)
	if name == "set-cookie" { headers_clear_set_cookie_values(headers) }
	return
}

headers_delete_unsafe :: #force_inline proc(headers: ^Headers, key: string) {
	delete_key(&headers._kv, key)
	if key == "set-cookie" { headers_clear_set_cookie_values(headers) }
}

headers_set_content_type :: proc {
	headers_set_content_type_mime,
	headers_set_content_type_string,
}

headers_set_content_type_string :: #force_inline proc(headers: ^Headers, content_type: string) {
	headers_set_unsafe(headers, "content-type", content_type)
}

headers_set_content_type_mime :: #force_inline proc(headers: ^Headers, content_type: MIME_Type) {
	headers_set_unsafe(headers, "content-type", mime_to_content_type(content_type))
}

headers_set_close :: #force_inline proc(headers: ^Headers) {
	headers_set_unsafe(headers, "connection", "close")
}

@(private)
headers_clear_set_cookie_values :: proc(headers: ^Headers) {
	allocator := headers_allocator(headers^)
	for value in headers._set_cookie_values {
		delete(value, allocator)
	}
	clear(&headers._set_cookie_values)
}

// sanitize_key lowercases ASCII and escapes newlines, so a name can neither
// miss a lookup by case nor split a field line when written. The result is owned
// by the section's allocator, and mem_err is set when it could not be built.
@(private = "package", require_results)
sanitize_key :: proc(headers: Headers, key: string) -> (name: string, mem_err: runtime.Allocator_Error) {
	builder: strings.Builder
	strings.builder_init(&builder, 0, len(key), headers_allocator(headers)) or_return
	for character in key {
		lowered := character + 32 if character >= 'A' && character <= 'Z' else character
		if !write_escaped_character(&builder, lowered) {
			// A builder reports the growth it could not make as a short write.
			strings.builder_destroy(&builder)
			return "", .Out_Of_Memory
		}
	}
	return strings.to_string(builder), nil
}

// write_escaped_character appends one character of a field name, writing a newline
// as its two-byte escape so a name can never split a field line. It reports false
// when the builder could not grow to hold it.
@(private, require_results)
write_escaped_character :: proc(builder: ^strings.Builder, character: rune) -> bool {
	if character == '\n' { return strings.write_string(builder, "\\n") == 2 }
	written, write_err := strings.write_rune(builder, character)
	return write_err == nil && written > 0
}

// headers_allocator returns the allocator a section's names and values live in.
@(private)
headers_allocator :: #force_inline proc(headers: Headers) -> runtime.Allocator {
	return headers._kv.allocator if headers._kv.allocator.procedure != nil else context.temp_allocator
}
