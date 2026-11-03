#+test
#+build linux
package main

import "core:strings"
import "core:sys/linux"
import "core:testing"

@(test)
test_process_name_set :: proc(test: ^testing.T) {
	if !test_isolate_process(test, #procedure) { return }
	process_name_set(PROCESS_NAME_ACP)
	name: [PROCESS_NAME_BYTES]u8
	PR_GET_NAME :: 16
	err := linux.prctl(PR_GET_NAME, uint(uintptr(&name[0])), 0, 0, 0)
	testing.expect_value(test, err, linux.Errno.NONE)
	testing.expect_value(test, strings.trim_right(string(name[:]), "\x00"), PROCESS_NAME_ACP)
}
