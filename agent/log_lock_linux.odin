#+build linux
package agent

import "core:os"
import "core:sys/linux"

// log_lock_platform_acquire takes an exclusive flock on file. The kernel releases
// it when the last descriptor on that open file closes, including when the process
// dies, so a lock needs no cleanup after a crash. A Darwin build implements this
// same procedure with the same BSD call.
@(private)
log_lock_platform_acquire :: proc(file: ^os.File, blocking: bool) -> bool {
	operation := linux.FLock_Op{.EX}
	if !blocking { operation += {.NB} }
	return linux.flock(linux.Fd(i64(os.fd(file))), operation) == .NONE
}
