#+build linux
package journal

import "core:os"
import "core:sys/linux"

// claim_lock_take takes an exclusive advisory lock on file without waiting. The
// lock belongs to the open file, so a second claim conflicts whether it is in
// this process or another, and the kernel drops it when the process dies.
// held_elsewhere reports that another holder has it.
@(private, require_results)
claim_lock_take :: proc(file: ^os.File) -> (held_elsewhere: bool, error: os.Error) {
	flock_error := linux.flock(linux.Fd(os.fd(file)), {.EX, .NB})
	#partial switch flock_error {
	case .NONE:
		return false, nil
	case .EWOULDBLOCK, .EACCES:
		return true, nil
	}
	return false, os.Platform_Error(flock_error)
}

// claim_lock_drop releases the lock claim_lock_take took on file.
@(private, require_results)
claim_lock_drop :: proc(file: ^os.File) -> os.Error {
	if flock_error := linux.flock(linux.Fd(os.fd(file)), {.UN}); flock_error != .NONE { return os.Platform_Error(flock_error) }
	return nil
}
