package agent

import "core:os"

// A Log_Lock is an exclusive lock on a file, held for as long as the descriptor
// stays open. The kernel drops it when the process dies, which is what lets a later
// cleanup tell a live run from a crashed one without trusting a timestamp or a
// process id.
//
// Locking a file is the one thing the log needs that no core package abstracts, so
// the operation itself lives in a platform file: log_lock_linux.odin today, and a
// Darwin sibling if this project is built there. Everything here is written against
// os.File.
@(private)
Log_Lock :: struct {
	file: ^os.File,
	held: bool,
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

// log_lock_release drops a lock. Closing the descriptor releases it in the kernel,
// so a release that cannot run leaves behind only what process death would have
// left anyway.
@(private)
log_lock_release :: proc(lock: ^Log_Lock) {
	if lock == nil || !lock.held { return }
	os.close(lock.file)
	lock^ = {}
}
