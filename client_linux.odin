#+build linux
package main

import "core:os"
import "core:sys/linux"

// client_claim_held reports whether another process holds an exclusive lock on the
// session lock file at path. A missing file is not held. The probe locks only to
// learn that and drops the lock before it returns, so the caller does not become
// the holder.
@(require_results)
client_claim_held :: proc(path: string) -> (held: bool, error: os.Error) {
	if !os.exists(path) { return false, nil }
	file, open_error := os.open(path, {.Read, .Write})
	if open_error == .Not_Exist { return false, nil }
	if open_error != nil { return false, open_error }
	defer _ = os.close(file) // The probe is done; a close failure does not change the answer.

	flock_error := linux.flock(linux.Fd(os.fd(file)), {.EX, .NB})
	#partial switch flock_error {
	case .NONE:
		if unlock_error := linux.flock(linux.Fd(os.fd(file)), {.UN}); unlock_error != .NONE {
			return false, os.Platform_Error(unlock_error)
		}
		return false, nil
	case .EWOULDBLOCK, .EACCES:
		return true, nil
	}
	return false, os.Platform_Error(flock_error)
}
