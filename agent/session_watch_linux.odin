#+build linux
package agent

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"

// SESSION_WATCH_MASK is what wakes an owner: the journal touches a session's lock file after
// each commit (IN_ATTRIB), and a claim drops or a follower leaves when a descriptor on it
// closes.
SESSION_WATCH_MASK :: linux.Inotify_Event_Mask{.ATTRIB, .CLOSE_WRITE, .CLOSE_NOWRITE}

// Session_Watch_Id names one watched lock file until session_watch_remove.
Session_Watch_Id :: distinct i32

// Session_Watch turns changes of the lock files of shared sessions into owner wakes
// (section 8.6 of the architecture). One thread per process waits in ppoll on an inotify
// descriptor and a stop eventfd with no timeout, and signals owner_wake_signal for every
// batch of events it reads. The zero value is inert: the first session_watch_add starts the
// thread, and session_watch_stop ends it. A queue overflow is an event like another, so it
// wakes too. A Session_Watch must not move while its thread runs.
Session_Watch :: struct {
	mutex:   sync.Mutex, // guards the fields below, never held across a wait
	inotify: linux.Fd,
	stop:    linux.Fd,
	worker:  ^thread.Thread,
}

// session_watch_add watches the lock file at lock_path and returns its id. The watch is
// armed when this returns, so a caller adds before its first read of the session: a commit
// after the read then raises an event, and none falls between the read and the watch.
// The file must exist. Adding a path that is already watched returns the same id, so the
// caller adds each path once and removes it once. The first call starts the thread and can
// fail with the cause of the descriptor, inotify, or thread that could not be created.
session_watch_add :: proc(watch: ^Session_Watch, lock_path: string) -> (id: Session_Watch_Id, error: os.Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	path := strings.clone_to_cstring(lock_path, context.temp_allocator) or_return
	inotify := session_watch_start(watch) or_return
	wd, add_error := linux.inotify_add_watch(inotify, path, SESSION_WATCH_MASK)
	if add_error != .NONE { return 0, os.Platform_Error(add_error) }
	return Session_Watch_Id(wd), nil
}

// session_watch_remove stops watching the file id names. An id the kernel no longer knows,
// because the file was removed or the watch never started, is ignored: removal is teardown
// and has nothing left to undo.
session_watch_remove :: proc(watch: ^Session_Watch, id: Session_Watch_Id) {
	sync.guard(&watch.mutex)
	if watch.worker == nil { return }
	_ = linux.inotify_rm_watch(watch.inotify, linux.Wd(id))
}

// session_watch_stop ends the thread and closes its descriptors, which drops every watch.
// It returns after the thread has exited, and later calls with nothing started do nothing.
// No other thread adds or removes while it runs, and a stopped watch may be started again.
session_watch_stop :: proc(watch: ^Session_Watch) {
	sync.lock(&watch.mutex)
	worker := watch.worker
	inotify, stop := watch.inotify, watch.stop
	watch.worker = nil
	watch.inotify, watch.stop = 0, 0
	sync.unlock(&watch.mutex)
	if worker == nil { return }

	// A full counter is already readable, so a failed write cannot keep the thread waiting.
	signal_wake_write(int(stop))
	thread.join(worker)
	thread.destroy(worker)
	// The descriptors are teardown: a close that fails leaves nothing to retry.
	_ = linux.close(inotify)
	_ = linux.close(stop)
}

// session_watch_start creates the descriptors and the thread on first use and returns the
// inotify descriptor. The thread is created with the watched signals blocked, so the
// process handler never runs on it.
@(private = "file")
session_watch_start :: proc(watch: ^Session_Watch) -> (inotify: linux.Fd, error: os.Error) {
	sync.guard(&watch.mutex)
	if watch.worker != nil { return watch.inotify, nil }

	inotify_fd, inotify_error := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if inotify_error != .NONE { return 0, os.Platform_Error(inotify_error) }
	stop_fd, stop_error := linux.eventfd(0, {.NONBLOCK, .CLOEXEC})
	if stop_error != .NONE {
		_ = linux.close(inotify_fd) // Abandoned; the eventfd failure is what the caller needs.
		return 0, os.Platform_Error(stop_error)
	}

	previous := chat_signal_block_watched()
	worker := thread.create(session_watch_thread, name = "nabla-session-watch")
	chat_signal_restore(previous)
	if worker == nil {
		// Abandoned; the failure to start is what the caller needs.
		_ = linux.close(inotify_fd)
		_ = linux.close(stop_fd)
		return 0, runtime.Allocator_Error.Out_Of_Memory
	}
	watch.inotify = inotify_fd
	watch.stop = stop_fd
	watch.worker = worker
	worker.data = watch
	thread.start(worker)
	return inotify_fd, nil
}

@(private = "file")
session_watch_thread :: proc(worker: ^thread.Thread) {
	watch := (^Session_Watch)(worker.data)
	// The descriptors are fixed from before the thread starts until stop joins it.
	inotify, stop := watch.inotify, watch.stop
	// inotify_event is 16 bytes plus a name; a lock file watch carries no name, and the
	// buffer is only drained, never parsed.
	events: [4096]u8
	fds := [2]linux.Poll_Fd{{fd = inotify, events = {.IN}}, {fd = stop, events = {.IN}}}
	for {
		_, poll_error := linux.ppoll(fds[:], nil, nil)
		if poll_error == .EINTR { continue }
		// No other error is expected. The thread ends, and a wake first tells owners to
		// recheck, since none will follow.
		if poll_error != .NONE {
			owner_wake_signal()
			return
		}
		if fds[1].revents != {} { return }
		if fds[0].revents == {} { continue }
		// One read takes the events queued so far, and the signal follows it, so an event
		// raised after the read is still queued for the next pass.
		if _, read_error := linux.read(inotify, events[:]); read_error != .NONE && read_error != .EAGAIN && read_error != .EINTR {
			owner_wake_signal()
			return
		}
		owner_wake_signal()
	}
}
