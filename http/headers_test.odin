#+test
#+private file
package http

import "core:mem"
import "core:testing"

@(test)
test_header_setters_own_and_replace_storage :: proc(t: ^testing.T) {
	headers: Headers
	headers_init(&headers, context.allocator)
	defer headers_destroy(&headers)
	value := [3]byte{'o', 'n', 'e'}
	canonical, err := headers_set(&headers, "X-Name", string(value[:]))
	if !testing.expect(t, err == nil) { return }
	value[0] = 'x'
	testing.expect_value(t, headers_get_unsafe(headers, "x-name"), "one")

	replacement, replacement_err := headers_set_unsafe(&headers, "x-name", "two")
	if !testing.expect(t, replacement_err == nil) { return }
	testing.expect(t, raw_data(canonical) == raw_data(replacement))
	testing.expect_value(t, headers_get_unsafe(headers, "x-name"), "two")
	testing.expect(t, headers_delete(&headers, "X-Name") == nil)
	testing.expect(t, !headers_has_unsafe(headers, "x-name"))

	_, first_ok := header_parse(&headers, "Set-Cookie: a=one")
	_, second_ok := header_parse(&headers, "Set-Cookie: b=two")
	testing.expect(t, first_ok && second_ok)
	_, cookie_err := headers_set(&headers, "Set-Cookie", "c=three")
	if !testing.expect(t, cookie_err == nil) { return }
	values, found, values_err := headers_get_all(headers, "set-cookie", context.allocator)
	defer delete(values, context.allocator)
	if testing.expect(t, values_err == nil && found && len(values) == 1) { testing.expect_value(t, values[0], "c=three") }
	headers_delete_unsafe(&headers, "set-cookie")
}

@(test)
test_header_setter_allocation_failures_leave_no_entry :: proc(t: ^testing.T) {
	for fail_at in 1 ..= 6 {
		state := Test_Failing_Allocator {
			backing = context.allocator,
			fail_at = fail_at,
		}
		allocator := mem.Allocator {
			procedure = test_failing_allocator,
			data      = &state,
		}
		headers: Headers
		headers_init(&headers, allocator)
		_, err := headers_set(&headers, "Name", "value")
		if err != nil { testing.expect(t, !headers_has_unsafe(headers, "name")) }
		headers_destroy(&headers)
	}

	state := Test_Failing_Allocator {
		backing = context.allocator,
	}
	allocator := mem.Allocator {
		procedure = test_failing_allocator,
		data      = &state,
	}
	headers: Headers
	headers_init(&headers, allocator)
	defer headers_destroy(&headers)
	_, err := headers_set(&headers, "Name", "first")
	if !testing.expect(t, err == nil) { return }
	state.fail_at = state.allocations + 2
	_, replacement_err := headers_set(&headers, "Name", "second")
	testing.expect(t, replacement_err == .Out_Of_Memory)
	testing.expect_value(t, headers_get_unsafe(headers, "name"), "first")
}
