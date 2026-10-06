#+build linux
package journal

import "core:os"
import "core:sys/linux"

// claim_file_pin sets the sticky bit on a lock file, which the XDG runtime directory
// rules name as the mark that keeps periodic clean-up from removing it. A lock file
// removed while held would let a second process claim the session on a new one.
@(private, require_results)
claim_file_pin :: proc(file: ^os.File) -> os.Error {
	mode := linux.Mode{.IRUSR, .IWUSR, .ISVTX}
	if chmod_error := linux.fchmod(linux.Fd(os.fd(file)), mode); chmod_error != .NONE { return os.Platform_Error(chmod_error) }
	return nil
}

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

// claim_file_touch sets the access and modification times of file to now, which
// raises IN_ATTRIB for every inotify watch on it. A null path makes utimensat act
// on the descriptor, as futimens does.
@(private, require_results)
claim_file_touch :: proc(file: ^os.File) -> os.Error {
	times := [2]linux.Time_Spec{{time_nsec = linux.UTIME_NOW}, {time_nsec = linux.UTIME_NOW}}
	if touch_error := linux.utimensat(linux.Fd(os.fd(file)), nil, raw_data(times[:]), {}); touch_error != .NONE {
		return os.Platform_Error(touch_error)
	}
	return nil
}
