package http

import "base:runtime"

import "core:strings"
import "core:unicode/utf8"

// Headers owns field names and values with its allocator. Names are lowercase
// and case-insensitive (RFC 9110 5.1). The _unsafe procedures require an already
// lowercase name; only the lookup and deletion variants avoid allocation.
Headers :: struct {
	_kv:                map[string]string,
	_set_cookie_values: [dynamic]string,
	readonly:           bool,
}

// headers_init sets the allocator that owns the section's map, extra Set-Cookie
// values, and every cloned name and value.
headers_init :: proc(headers: ^Headers, allocator := context.temp_allocator) {
	headers._kv.allocator = allocator
	headers._set_cookie_values.allocator = allocator
}

// headers_destroy releases the section's owned names, values,
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

// headers_set clones the name and value into the section and returns its canonical
// lowercase name. Allocation failure leaves the section unchanged.
@(require_results)
headers_set :: proc(headers: ^Headers, key: string, value: string, loc := #caller_location) -> (name: string, err: runtime.Allocator_Error) {
	headers_assert_writable(headers, loc)
	name = sanitize_key(headers^, key) or_return
	return headers_store(headers, name, value)
}

// headers_set_unsafe clones an already lowercase name and its value into the
// section. It returns the canonical name, or an allocation error without changes.
@(require_results)
headers_set_unsafe :: proc(headers: ^Headers, key: string, value: string, loc := #caller_location) -> (name: string, err: runtime.Allocator_Error) {
	headers_assert_writable(headers, loc)
	name = strings.clone(key, headers_allocator(headers^)) or_return
	return headers_store(headers, name, value)
}

@(private, require_results)
headers_store :: proc(headers: ^Headers, name, value: string) -> (key: string, err: runtime.Allocator_Error) {
	allocator := headers_allocator(headers^)
	transferred := false
	defer if !transferred { delete(name, allocator) }
	cloned := strings.clone(value, allocator) or_return
	defer if !transferred { delete(cloned, allocator) }
	if headers._kv.allocator.procedure == nil { headers_init(headers, allocator) }
	key_ptr, value_ptr, inserted := map_entry(&headers._kv, name) or_return
	if !inserted {
		delete(name, allocator)
		delete(value_ptr^, allocator)
	}
	value_ptr^ = cloned
	transferred = true
	if key_ptr^ == "set-cookie" { headers_clear_set_cookie_values(headers) }
	return key_ptr^, nil
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

headers_assert_writable :: proc(headers: ^Headers, loc := #caller_location) {
	assert(!headers.readonly, "these headers are readonly, did you accidentally try to set a header on the request?", loc)
}

// headers_entry returns the canonical name and mutable value for key, inserting
// an empty value when absent. Names and values belong to the section allocator;
// callers replacing a non-empty value must free it and allocate its replacement
// with that allocator. Returned pointers expire when the map grows or removes them.
@(require_results)
headers_entry :: proc(
	headers: ^Headers,
	key: string,
	loc := #caller_location,
) -> (
	key_ptr: ^string,
	value_ptr: ^string,
	just_inserted: bool,
	err: runtime.Allocator_Error,
) {
	headers_assert_writable(headers, loc)
	name := sanitize_key(headers^, key) or_return
	return headers_insert_entry(headers, name)
}

// headers_entry_unsafe is headers_entry for an already lowercase key.
@(require_results)
headers_entry_unsafe :: proc(
	headers: ^Headers,
	key: string,
	loc := #caller_location,
) -> (
	key_ptr: ^string,
	value_ptr: ^string,
	just_inserted: bool,
	err: runtime.Allocator_Error,
) {
	headers_assert_writable(headers, loc)
	name := strings.clone(key, headers_allocator(headers^)) or_return
	return headers_insert_entry(headers, name)
}

@(private, require_results)
headers_insert_entry :: proc(headers: ^Headers, name: string) -> (key_ptr: ^string, value_ptr: ^string, inserted: bool, err: runtime.Allocator_Error) {
	allocator := headers_allocator(headers^)
	if headers._kv.allocator.procedure == nil { headers_init(headers, allocator) }
	key_ptr, value_ptr, inserted, err = map_entry(&headers._kv, name)
	if err != nil || !inserted { delete(name, allocator) }
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

// headers_delete frees the field with a name it lowercases first. An allocation
// error leaves the section unchanged.
@(require_results)
headers_delete :: proc(headers: ^Headers, key: string, loc := #caller_location) -> runtime.Allocator_Error {
	headers_assert_writable(headers, loc)
	name := sanitize_key(headers^, key) or_return
	defer delete(name, headers_allocator(headers^))
	headers_delete_unsafe(headers, name, loc)
	return nil
}

// headers_delete_unsafe frees the field under an already lowercase name.
headers_delete_unsafe :: proc(headers: ^Headers, key: string, loc := #caller_location) {
	headers_assert_writable(headers, loc)
	removed_key, removed_value := delete_key(&headers._kv, key)
	if removed_key == "set-cookie" { headers_clear_set_cookie_values(headers) }
	allocator := headers_allocator(headers^)
	delete(removed_key, allocator)
	delete(removed_value, allocator)
}

headers_set_content_type :: proc {
	headers_set_content_type_mime,
	headers_set_content_type_string,
}

@(require_results)
headers_set_content_type_string :: proc(headers: ^Headers, content_type: string) -> runtime.Allocator_Error {
	_, err := headers_set_unsafe(headers, "content-type", content_type)
	return err
}

@(require_results)
headers_set_content_type_mime :: proc(headers: ^Headers, content_type: MIME_Type) -> runtime.Allocator_Error {
	return headers_set_content_type_string(headers, mime_to_content_type(content_type))
}

@(require_results)
headers_set_close :: proc(headers: ^Headers) -> runtime.Allocator_Error {
	_, err := headers_set_unsafe(headers, "connection", "close")
	return err
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
	encoded, width := utf8.encode_rune(character)
	return strings.write_bytes(builder, encoded[:width]) == width
}

// headers_allocator returns the allocator a section's names and values live in.
@(private)
headers_allocator :: #force_inline proc(headers: Headers) -> runtime.Allocator {
	return headers._kv.allocator if headers._kv.allocator.procedure != nil else context.temp_allocator
}
