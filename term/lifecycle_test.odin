#+build linux
#+test
package term

// PTY lifecycle coverage: ownership, close-retry, resize, zero-progress
// write, EINTR, descriptor-close failure, and SIGWINCH disposition. A real
// controlling terminal from a PTY is what makes these real: session setup,
// viewport polling, and signal delivery against a terminal no byte fixture
// can provide.
//
// The whole scenario runs isolated in a child of the test binary (see
// isolate_test.odin): it forks, and fork() into a multi-threaded test runner
// would risk deadlocking on allocator locks held by other threads. The forked
// child acquires its controlling terminal (setsid + TIOCSCTTY) and exercises
// the session contract against it; the parent drives resize and output
// draining and asserts the child's exit status. All process-global effects
// (session leadership, controlling terminal, signal dispositions) stay inside
// the child process, which exits when the scenario ends.
//
// The fault-injection hooks only exist with -define:NABLA_TERM_TEST_HOOKS=true
// (passed for this package by scripts/test), so without the define this file
// contributes no tests.

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:sys/linux"
import "core:testing"

when #config(NABLA_TERM_TEST_HOOKS, false) {

	// Linux ioctl requests not exposed by core:sys/linux (asm-generic/ioctls.h).
	LIFECYCLE_TIOCSCTTY :: 0x540E
	LIFECYCLE_TIOCSWINSZ :: 0x5414
	LIFECYCLE_TIOCGPTN :: 0x80045430
	LIFECYCLE_TIOCSPTLCK :: 0x40045431

	// Lifecycle_Win_Size matches the kernel winsize structure for TIOCSWINSZ.
	Lifecycle_Win_Size :: struct {
		rows, columns, x_pixels, y_pixels: u16,
	}

	@(test)
	test_pty_lifecycle_session_contract :: proc(t: ^testing.T) {
		if !test_isolate_process(t, #procedure) { return }
		lifecycle_run_parent(t)
	}

	// --- pty plumbing ---------------------------------------------------------

	// lifecycle_pty_open opens /dev/ptmx, unlocks the slave (TIOCSPTLCK) and
	// names it from its number (TIOCGPTN), the raw form of posix_openpt,
	// unlockpt and ptsname. The path is temp-allocated.
	lifecycle_pty_open :: proc(t: ^testing.T) -> (master: linux.Fd, slave_path: string, ok: bool) {
		master_fd, open_errno := linux.open("/dev/ptmx", {.RDWR, .NOCTTY})
		if open_errno != .NONE { return }
		unlock: i32
		number: u32
		if _ioctl(master_fd, LIFECYCLE_TIOCSPTLCK, &unlock) != .NONE || _ioctl(master_fd, LIFECYCLE_TIOCGPTN, &number) != .NONE {
			_ = linux.close(master_fd)
			return
		}
		return master_fd, fmt.tprintf("/dev/pts/%d", number), true
	}

	// lifecycle_wait_for_byte blocks until the pipe yields the expected byte.
	lifecycle_wait_for_byte :: proc(fd: linux.Fd, expected: byte) -> bool {
		got: [1]byte
		for {
			read_count, errno := linux.read(fd, got[:])
			if read_count == 1 {
				return got[0] == expected
			}
			if errno == .EINTR {
				continue
			}
			return false
		}
	}

	// lifecycle_drain_slave reads from master until the child signals done on
	// sync_fd, reading at most 64 bytes per 5ms tick so the pty output buffer
	// stays full and the child's writes genuinely block (what makes the EINTR
	// path real). It also checks the close restoration bytes across read chunks.
	lifecycle_drain_slave :: proc(sync_fd: linux.Fd, master: linux.Fd) -> bool {
		done := false
		restore_sequence := "\x1b[?25h\x1b[0m"
		restore_matched := 0
		restore_seen := false
		for !done {
			poll_descriptors := [2]linux.Poll_Fd{{fd = sync_fd, events = {.IN}}, {fd = master, events = {.IN}}}
			_, poll_errno := linux.poll(poll_descriptors[:], 5)
			if poll_errno != .NONE {
				continue
			}
			if .IN in poll_descriptors[0].revents {
				got: [1]byte
				if count, _ := linux.read(sync_fd, got[:]); count == 1 && got[0] == 'D' {
					done = true
				}
			}
			if .IN in poll_descriptors[1].revents {
				buffer: [64]byte
				read_count, _ := linux.read(master, buffer[:])
				if read_count > 0 {
					for output_byte in buffer[:int(read_count)] {
						if output_byte == restore_sequence[restore_matched] {
							restore_matched += 1
						} else if output_byte == restore_sequence[0] {
							restore_matched = 1
						} else {
							restore_matched = 0
						}
						if restore_matched == len(restore_sequence) {
							restore_seen = true
							restore_matched = 0
						}
					}
				}
			}
			if !done {
				// Throttle: without this the master is constantly readable and
				// the whole buffer drains in microseconds, which would let the
				// child's write complete before the SIGALRM lands.
				throttle := linux.Time_Spec {
					time_sec  = 0,
					time_nsec = 5_000_000,
				}
				_ = linux.nanosleep(&throttle, nil)
			}
		}
		return restore_seen
	}

	// --- child scenarios ------------------------------------------------------

	lifecycle_alarm_fired: int

	lifecycle_alarm_handler :: proc "c" (sig: linux.Signal) {
		// The handler must exist so the signal interrupts poll/write with EINTR
		// instead of terminating the child. The counter proves the timer fired
		// during the blocked write (single-threaded child; the increment is
		// atomic in practice).
		lifecycle_alarm_fired += 1
	}

	// lifecycle_setitimer arms ITIMER_REAL. core:sys/linux.setitimer issues
	// SYS_getitimer, so the syscall is made directly.
	lifecycle_setitimer :: proc(timer: ^linux.ITimer_Val) -> linux.Errno {
		ret := intrinsics.syscall(linux.SYS_setitimer, uintptr(linux.ITimer_Which.REAL), uintptr(timer), 0)
		return linux.Errno(-ret)
	}

	// Lifecycle_Exit is the exit status of the forked child. Checks_Failed
	// means the child wrote the failed checks to the report pipe.
	Lifecycle_Exit :: enum u8 {
		Passed,
		Checks_Failed,
		Setsid_Failed,
		Slave_Path_Too_Long,
		Slave_Open_Failed,
		Controlling_Terminal_Failed,
		Resize_Ready_Write_Failed,
		Resize_Go_Missing,
	}

	lifecycle_failures: int
	lifecycle_report_fd: linux.Fd

	lifecycle_check :: proc(cond: bool, message: string, args: ..any) {
		if !cond {
			line := fmt.tprintfln(message, ..args)
			_, _ = linux.write(lifecycle_report_fd, transmute([]byte)line)
			lifecycle_failures += 1
		}
	}

	lifecycle_run_child :: proc(slave_path: string, sync_out_w: linux.Fd, sync_in_r: linux.Fd) -> Lifecycle_Exit {
		tracking: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracking, context.allocator)
		context.allocator = mem.tracking_allocator(&tracking)

		// Acquire a controlling terminal from the PTY.
		if _, setsid_errno := linux.setsid(); setsid_errno != .NONE {
			return .Setsid_Failed
		}
		path_buf: [256]byte
		if len(slave_path) >= len(path_buf) {
			return .Slave_Path_Too_Long
		}
		copy(path_buf[:], slave_path)
		slave_path_c := cstring(raw_data(path_buf[:]))
		slave, slave_errno := linux.open(slave_path_c, {.RDWR, .NOCTTY})
		if slave_errno != .NONE {
			return .Slave_Open_Failed
		}
		defer linux.close(slave)
		if errno := _ioctl(slave, LIFECYCLE_TIOCSCTTY, nil); errno != .NONE {
			return .Controlling_Terminal_Failed
		}

		// A: ownership — open allocates with the caller's allocator; a
		// successful close frees the Session and its file.
		live_before := len(tracking.allocation_map)
		session, open_err := open({alternate_screen = true, hide_cursor = true, input_mode = .Raw})
		lifecycle_check(open_err == nil, "open must succeed on a controlling tty")
		lifecycle_check(session != nil, "open must return a session")
		lifecycle_check(len(tracking.allocation_map) > live_before, "open must allocate with the caller's allocator")
		lifecycle_check(close(nil) == nil, "close(nil) is a documented no-op")
		lifecycle_check(close(session) == nil, "close must succeed")
		lifecycle_check(len(tracking.allocation_map) == 0, "a successful close must free the session and its file")

		// B: close-retry — a teardown failure leaves the session allocated; a
		// later close completes and frees.
		session, open_err = open({input_mode = .Raw})
		lifecycle_check(open_err == nil, "open must succeed")
		live := len(tracking.allocation_map)
		Terminal_Test_Fail_Next_Teardown()
		first_err := close(session)
		lifecycle_check(first_err != nil, "an injected teardown failure must be reported")
		lifecycle_check(len(tracking.allocation_map) == live, "a failed close must leave the session allocated")
		retry_err := close(session)
		lifecycle_check(retry_err == nil, "close must be retryable until it succeeds")
		lifecycle_check(len(tracking.allocation_map) == 0, "the retry close must free the session")

		// C: resize — viewport polling reflects TIOCSWINSZ on the master.
		session, open_err = open({})
		lifecycle_check(open_err == nil, "open must succeed")
		ready_byte := [1]byte{'R'}
		if written, _ := linux.write(sync_out_w, ready_byte[:]); written != 1 {
			return .Resize_Ready_Write_Failed
		}
		if !lifecycle_wait_for_byte(sync_in_r, 'G') {
			return .Resize_Go_Missing
		}
		vp, vp_err := viewport(session)
		lifecycle_check(vp_err == nil, "viewport must succeed after a resize")
		lifecycle_check(vp.columns == 100 && vp.rows == 40, "viewport must report the resized 100x40, got %dx%d", vp.columns, vp.rows)
		lifecycle_check(close(session) == nil, "close must succeed")

		// D: zero-progress write — present reports Partial_Write with zero
		// committed bytes and keeps the exact required count.
		session, open_err = open({})
		lifecycle_check(open_err == nil, "open must succeed")
		frame := Frame_Buffer {
			columns = 2,
			rows    = 1,
			cells   = []Cell{{grapheme = "a", width = 1}, {grapheme = "b", width = 1}},
		}
		scratch: [1024]byte
		Terminal_Test_Zero_Write_Next()
		committed, required, present_err := present(session, frame, profile_default(), {}, scratch[:])
		lifecycle_check(present_err == General_Error.Partial_Write, "a zero-progress write must report Partial_Write")
		lifecycle_check(committed == 0, "zero progress must commit zero bytes")
		lifecycle_check(required > 0, "the frame must still report an exact required size")

		// Recovery: a later successful full frame restores the observable
		// presentation after the failed write (the hook is one-shot).
		recovery_committed, recovery_required, recovery_err := present(session, frame, profile_default(), {}, scratch[:])
		lifecycle_check(recovery_err == nil, "a later full frame must recover after a failed write")
		lifecycle_check(recovery_committed == recovery_required && recovery_committed == required, "the recovery frame must commit its full size")
		lifecycle_check(close(session) == nil, "close must succeed")

		// E: EINTR — a signal interrupting the blocked write/poll is retried
		// and the whole frame still lands.
		session, open_err = open({input_mode = .Raw})
		lifecycle_check(open_err == nil, "open must succeed")
		file, file_err := session_file(session)
		lifecycle_check(file_err == nil, "session_file must succeed")
		fd := linux.Fd(os.fd(file))

		// Fill the pty output buffer so present's write genuinely blocks.
		junk: [4096]byte
		for i in 0 ..< len(junk) {
			junk[i] = 'j'
		}
		for {
			_, errno := linux.write(fd, junk[:])
			if errno != .NONE {
				break
			}
		}
		fill_byte := [1]byte{'F'}
		_, _ = linux.write(sync_out_w, fill_byte[:])

		action := linux.Sig_Action {
			handler = lifecycle_alarm_handler,
		}
		lifecycle_check(linux.rt_sigaction(.SIGALRM, &action, nil) == .NONE, "SIGALRM handler must install")
		timer := linux.ITimer_Val {
			value = {seconds = 0, microseconds = 20000},
		}
		lifecycle_check(lifecycle_setitimer(&timer) == .NONE, "timer must arm")

		big := make([]Cell, 200 * 50)
		defer delete(big)
		for &cell in big {
			cell = {
				grapheme = "x",
				width    = 1,
			}
		}
		big_frame := Frame_Buffer {
			columns = 200,
			rows    = 50,
			cells   = big,
		}
		big_scratch := make([]byte, 1 << 20)
		defer delete(big_scratch)
		_, _, eintr_err := present(session, big_frame, profile_default(), {}, big_scratch)
		lifecycle_check(eintr_err == nil, "present must retry EINTR and complete the full frame")
		lifecycle_check(lifecycle_alarm_fired > 0, "the SIGALRM timer must have fired during the blocked write")

		timer = {}
		_ = lifecycle_setitimer(&timer)
		done_byte := [1]byte{'D'}
		_, _ = linux.write(sync_out_w, done_byte[:])
		lifecycle_check(close(session) == nil, "close must succeed")

		// F: descriptor-close failure — the cause is reported (not suppressed),
		// the session stays allocated, and the retry close settles and frees.
		// (Scenario E's frame/scratch allocations are still live here — their
		// defers run at child exit — so the assertions are relative to them.)
		live = len(tracking.allocation_map)
		session, open_err = open({})
		lifecycle_check(open_err == nil, "open must succeed")
		lifecycle_check(len(tracking.allocation_map) == live + 1, "open must allocate exactly the session")
		Terminal_Test_Fail_Close_Next()
		first_err = close(session)
		lifecycle_check(first_err != nil, "a descriptor-close failure must be reported")
		lifecycle_check(len(tracking.allocation_map) == live + 1, "a failed descriptor close must leave the session allocated")
		retry_err = close(session)
		lifecycle_check(retry_err == nil, "the retry close must settle and free")
		lifecycle_check(len(tracking.allocation_map) == live, "the retry close must free the session")

		// G: SIGWINCH disposition — close restores the caller's previous
		// handler, so a closed session never leaves the package handler armed.
		sigwinch_action := linux.Sig_Action {
			handler = lifecycle_alarm_handler,
		}
		lifecycle_check(linux.rt_sigaction(.SIGWINCH, &sigwinch_action, nil) == .NONE, "SIGWINCH handler must install")
		session, open_err = open({})
		lifecycle_check(open_err == nil, "open must succeed")
		lifecycle_check(close(session) == nil, "close must succeed")
		restored: linux.Sig_Action
		// rt_sigaction dereferences its action even for a pure query, so probe
		// with the handler already installed.
		probe := linux.Sig_Action {
			handler = lifecycle_alarm_handler,
		}
		lifecycle_check(linux.rt_sigaction(.SIGWINCH, &probe, &restored) == .NONE, "SIGWINCH query must succeed")
		lifecycle_check(restored.handler == lifecycle_alarm_handler, "close must restore the caller's SIGWINCH handler")

		// H: a terminal write may fail with EIO after SIGHUP; close still
		// releases the descriptor and session after attempting every restore.
		session, open_err = open({alternate_screen = true, hide_cursor = true, bracketed_paste = true, mouse = true})
		lifecycle_check(open_err == nil, "open must succeed")
		Terminal_Test_Fail_Next_Write()
		close_err := close(session)
		lifecycle_check(close_err == nil, "close must tolerate a terminal write that fails with EIO")

		return lifecycle_failures == 0 ? .Passed : .Checks_Failed
	}

	// --- parent ---------------------------------------------------------------

	lifecycle_run_parent :: proc(t: ^testing.T) {
		master, slave_path, ok := lifecycle_pty_open(t)
		if !testing.expect(t, ok, "pty must open") { return }
		defer linux.close(master)
		// slave_path borrows ptsname's static storage and is never freed.

		child_out: [2]linux.Fd
		parent_out: [2]linux.Fd
		if linux.pipe2(&child_out, {}) != .NONE || linux.pipe2(&parent_out, {}) != .NONE {
			testing.fail_now(t, "sync pipes must open")
		}

		report: [2]linux.Fd
		if linux.pipe2(&report, {}) != .NONE {
			testing.fail_now(t, "report pipe must open")
		}
		defer linux.close(report[0])

		pid, fork_errno := linux.fork()
		if fork_errno != .NONE {
			testing.fail_now(t, "fork must succeed")
		}
		if pid == 0 {
			_ = linux.close(master)
			_ = linux.close(child_out[0])
			_ = linux.close(parent_out[1])
			_ = linux.close(report[0])
			lifecycle_report_fd = report[1]
			os.exit(int(lifecycle_run_child(slave_path, child_out[1], parent_out[0])))
		}

		_ = linux.close(child_out[1])
		_ = linux.close(parent_out[0])
		_ = linux.close(report[1])

		// Scenario C: resize the master once the child's session is open.
		if !lifecycle_wait_for_byte(child_out[0], 'R') {
			probe: u32
			waited, _ := linux.wait4(pid, &probe, {.WNOHANG}, nil)
			if waited == pid {
				testing.fail_now(t, "child died before 'R'")
			} else {
				testing.fail_now(t, "resize-ready signal missing; child still alive")
			}
		}
		size := Lifecycle_Win_Size {
			rows    = 40,
			columns = 100,
		}
		testing.expect_value(t, _ioctl(master, LIFECYCLE_TIOCSWINSZ, &size), linux.Errno.NONE)
		go_byte := [1]byte{'G'}
		_, _ = linux.write(parent_out[1], go_byte[:])

		// Scenario E: drain the slave slowly until the child finishes.
		restore_seen := lifecycle_drain_slave(child_out[0], master)
		testing.expect(t, restore_seen, "close must emit an SGR reset with its cursor restoration")

		status: u32
		waited, _ := linux.wait4(pid, &status, {}, nil)
		testing.expect(t, waited == pid, "waitpid must return the child pid")
		exited := (status & 0x7f) == 0
		exit := Lifecycle_Exit((status >> 8) & 0xff)
		testing.expectf(t, exited && exit == .Passed, "child must exit Passed, got status %#x (%v)", status, exit)

		failures: [4096]byte
		count, _ := linux.read(report[0], failures[:])
		if count > 0 {
			testing.expectf(t, false, "child checks failed:\n%s", string(failures[:count]))
		}
	}

} // when #config(NABLA_TERM_TEST_HOOKS, false)
