#+build linux
package main

import "core:sys/linux"

// PROCESS_NAME_BYTES is what the kernel keeps of a process name, including its
// terminating null, so a longer name is cut short.
PROCESS_NAME_BYTES :: 16
PR_SET_NAME :: 15

// The main process, the TUI, and the ACP interface run the same binary, so the
// name is what tells them apart in a process monitor.
PROCESS_NAME_MAIN :: "nabla"
PROCESS_NAME_TUI :: "nabla-tui"
PROCESS_NAME_ACP :: "nabla-acp"

// process_name_set renames the process of the calling thread, which is what `ps`
// and a process monitor show. It runs on the process's first thread, the one whose
// name is the process's; a worker thread that calls it names only itself. A
// refusal leaves the previous name, which costs only the label, so there is
// nothing for a caller to correct.
process_name_set :: proc(name: string) {
	raw: [PROCESS_NAME_BYTES]u8
	copy(raw[:PROCESS_NAME_BYTES - 1], name)
	_ = linux.prctl(PR_SET_NAME, uint(uintptr(&raw[0])), 0, 0, 0)
}
