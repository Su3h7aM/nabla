#+build linux
package agent

import "core:os"
import "core:sys/linux"

// log_lock_platform_acquire takes an exclusive flock on file. The kernel releases
// it when the last descriptor on that open file closes, including when the process
// dies, so a lock needs no cleanup after a crash.
@(private)
log_lock_platform_acquire :: proc(file: ^os.File, blocking: bool) -> bool {
	operation := linux.FLock_Op{.EX}
	if !blocking { operation += {.NB} }
	return linux.flock(linux.Fd(i64(os.fd(file))), operation) == .NONE
}

// log_lock_platform_probe takes the same lock without blocking. Success means
// nobody held it, which is what makes the descriptor a pin while the caller keeps
// it open. A would-block answer means another holder exists. Anything else is a
// question the kernel did not answer, which the caller must not read as Free.
@(private)
log_lock_platform_probe :: proc(file: ^os.File) -> Log_Lock_State {
	errno := linux.flock(linux.Fd(i64(os.fd(file))), linux.FLock_Op{.EX, .NB})
	if errno == .NONE { return .Free }
	if errno == .EWOULDBLOCK { return .Held }
	return .Unknown
}
