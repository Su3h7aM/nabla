#+test
#+private file
package http

import "core:slice"
import "core:testing"

@(test)
test_dynamic_unwritten :: proc(t: ^testing.T) {
	{
		d := make([dynamic]int, 4, 8)
		defer delete(d)
		unwritten := _dynamic_unwritten(d)
		testing.expect(t, len(unwritten) == 4)
	}
	{
		d := slice.into_dynamic([]int{1, 2, 3, 4, 5})
		defer delete(d)
		_dynamic_add_len(&d, 3)
		unwritten := _dynamic_unwritten(d)
		testing.expect(t, len(d) == 3)
		testing.expect(t, len(unwritten) == 2)
		testing.expect(t, unwritten[0] == 4)
		testing.expect(t, unwritten[1] == 5)
	}
	{
		d := slice.into_dynamic([]int{})
		defer delete(d)
		unwritten := _dynamic_unwritten(d)
		testing.expect(t, len(unwritten) == 0)
	}
}
