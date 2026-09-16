package agent

import "core:os"

// A Log_Lock is an exclusive lock on a file, held for as long as the descriptor
// stays open. The kernel drops it when the process dies, which is what lets a later
// cleanup tell a live run from a crashed one without trusting a timestamp or a
// process id.
//
// Locking a file is the one thing the log needs that no core package abstracts, so
// the operation itself lives in a platform file: log_lock_linux.odin. Linux is the
// only target this project builds, so there is no second sibling.
@(private)
Log_Lock :: struct {
	file: ^os.File,
	held: bool,
}

// Log_Lock_State answers whether a lock is held. Unknown is not Free: a caller
// that cannot prove a lock is released must keep what that lock guards.
Log_Lock_State :: enum {
	Free,
	Held,
	Unknown,
}

// log_lock_acquire opens path, creating it when missing, and takes an exclusive
// lock on it. blocking decides whether a lock another process holds is waited for
// or declined. A lock file is never deleted: replacing a locked inode would let two
// processes hold what each believes is the same lock.
@(private)
log_lock_acquire :: proc(path: string, blocking: bool) -> (lock: Log_Lock, err: Log_Error) {
	file, open_err := os.open(path, {.Read, .Write, .Create}, LOG_FILE_PERMISSIONS)
	if open_err != nil { return {}, log_error(.Create, "a lock file could not be opened") }
	if !log_lock_platform_acquire(file, blocking) {
		os.close(file)
		return {}, log_error(.Create, "a lock could not be taken")
	}
	lock = Log_Lock {
		file = file,
		held = true,
	}
	return lock, nil
}

// log_lock_pin asks whether the lock file at path is held, and, when it is not,
// returns the descriptor that proves it. The caller closes the pin, which releases
// the lock; keeping the pin open until the guarded work is finished is what stops
// another process from taking the lock in between.
//
// A path with no lock file cannot be held by anyone, so it answers Free. Any other
// failure to answer is Unknown, never Free.
@(private)
log_lock_pin :: proc(path: string) -> (pin: ^os.File, state: Log_Lock_State) {
	file, open_err := os.open(path, {.Read, .Write})
	if open_err != nil {
		if open_err == os.General_Error.Not_Exist { return nil, .Free }
		return nil, .Unknown
	}
	probed := log_lock_platform_probe(file)
	if probed != .Free {
		os.close(file)
		return nil, probed
	}
	return file, .Free
}

// log_lock_release drops a lock. Closing the descriptor releases it in the kernel,
// so a release that cannot run leaves behind only what process death would have
// left anyway.
@(private)
log_lock_release :: proc(lock: ^Log_Lock) {
	if lock == nil || !lock.held { return }
	os.close(lock.file)
	lock^ = {}
}
