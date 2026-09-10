#+build linux
package main

// PTY lifecycle tests for the term package.
//
// This is a single-threaded executable (run by scripts/test with
// -define:NABLA_TERM_TEST_HOOKS=true), not an in-package @(test) suite:
// it forks a child, and fork() into a multi-threaded test runner would risk
// deadlocking on allocator locks held by other threads. The child acquires a
// real controlling terminal from a PTY (setsid + TIOCSCTTY) and exercises
// the session contract against it; the parent drives resize and output
// draining and asserts the child's exit status.
//
// Scenarios:
//   A ownership: open allocates the Session with the caller's allocator;
//     close frees it; close(nil) is a no-op.
//   B close-retry: an injected teardown failure leaves the session
//     allocated; a later close completes and frees.
//   C resize: TIOCSWINSZ on the master is observed by viewport polling.
//   D zero-progress write: present reports General_Error.Partial_Write with
//     zero committed bytes.
//   E EINTR: a signal interrupting the blocked write/poll is retried and the
//     full frame still lands.
//   F descriptor-close failure: the one-shot close reports its cause, the
//     session stays allocated, and the retry close settles and frees.
//   G SIGWINCH disposition: close restores the caller's previous handler.
//   H present_operations: the operation stream commits its exact size over
//     the real controlling terminal.

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:sys/linux"
import "core:sys/posix"
import "nabla:term"

// Linux ioctl requests not exposed by core:sys/linux.
TIOCSCTTY :: 0x540E
TIOCSWINSZ :: 0x5414

// Win_Size matches the kernel winsize structure for TIOCSWINSZ.
Win_Size :: struct {
	rows, columns, x_pixels, y_pixels: u16,
}

failures: int

check :: proc(cond: bool, message: string, args: ..any) {
	if !cond {
		fmt.eprintln("FAIL:", fmt.tprintf(message, ..args))
		failures += 1
	}
}

// --- pty plumbing ---

pty_open :: proc() -> (master: posix.FD, slave_path: string, ok: bool) {
	master = posix.posix_openpt({.RDWR})
	if master < 0 {
		return
	}
	if posix.grantpt(master) != .OK || posix.unlockpt(master) != .OK {
		posix.close(master)
		master = -1
		return
	}
	name := posix.ptsname(master)
	if name == nil {
		posix.close(master)
		master = -1
		return
	}
	return master, string(name), true
}

// wait_for_byte blocks until the pipe yields the expected byte.
wait_for_byte :: proc(fd: posix.FD, expected: byte) -> bool {
	got: byte
	for {
		n := posix.read(fd, &got, 1)
		if n == 1 {
			return got == expected
		}
		if n < 0 && posix.get_errno() == .EINTR {
			continue
		}
		return false
	}
}

// drain_slave reads from master until the child signals done on sync_fd,
// reading at most 64 bytes per 5ms tick so the pty output buffer stays full
// and the child's writes genuinely block (what makes the EINTR path real).
drain_slave :: proc(sync_fd: posix.FD, master: posix.FD) {
	done := false
	for !done {
		pfds := [2]posix.pollfd{{fd = sync_fd, events = {.IN}}, {fd = master, events = {.IN}}}
		n := posix.poll(raw_data(pfds[:]), 2, 5)
		if n < 0 {
			continue
		}
		if .IN in pfds[0].revents {
			got: byte
			if posix.read(sync_fd, &got, 1) == 1 && got == 'D' {
				done = true
			}
		}
		if .IN in pfds[1].revents {
			buf: [64]byte
			posix.read(master, raw_data(buf[:]), c.size_t(len(buf)))
		}
		if !done {
			// Throttle: without this the master is constantly readable and
			// the whole buffer drains in microseconds, which would let the
			// child's write complete before the SIGALRM lands.
			ts := posix.timespec {
				tv_sec  = 0,
				tv_nsec = 5_000_000,
			}
			posix.nanosleep(&ts, nil)
		}
	}
}

// --- child scenarios ---

alarm_fired: int

alarm_handler :: proc "c" (sig: posix.Signal) {
	// The handler must exist so the signal interrupts poll/write with EINTR
	// instead of terminating the child. The counter proves the timer fired
	// during the blocked write (single-threaded child; the increment is
	// atomic in practice).
	alarm_fired += 1
}

run_child :: proc(slave_path: string, sync_out_w: posix.FD, sync_in_r: posix.FD) -> int {
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, context.allocator)
	context.allocator = mem.tracking_allocator(&tracking)

	// Acquire a controlling terminal from the PTY.
	if posix.setsid() < 0 {
		fmt.eprintln("child: setsid failed")
		return 1
	}
	path_buf: [256]byte
	if len(slave_path) >= len(path_buf) {
		fmt.eprintln("child: slave path too long")
		return 1
	}
	copy(path_buf[:], slave_path)
	slave_path_c := cstring(raw_data(path_buf[:]))
	slave := posix.open(slave_path_c, {.RDWR, .NOCTTY})
	if slave < 0 {
		fmt.eprintln("child: slave open failed, errno", posix.get_errno())
		return 1
	}
	if slave < 0 {
		fmt.eprintln("child: slave open failed")
		return 1
	}
	defer posix.close(slave)
	if linux.ioctl(linux.Fd(slave), u32(TIOCSCTTY), 0) != 0 {
		fmt.eprintln("child: TIOCSCTTY failed, errno", posix.get_errno())
		return 1
	}

	// A: ownership — open allocates with the caller's allocator; a
	// successful close frees the Session and its file.
	live_before := len(tracking.allocation_map)
	session, open_err := term.open({alternate_screen = true, hide_cursor = true, input_mode = .Raw})
	check(open_err == nil, "open must succeed on a controlling tty")
	check(session != nil, "open must return a session")
	check(len(tracking.allocation_map) > live_before, "open must allocate with the caller's allocator")
	check(term.close(nil) == nil, "close(nil) is a documented no-op")
	check(term.close(session) == nil, "close must succeed")
	check(len(tracking.allocation_map) == 0, "a successful close must free the session and its file")

	// B: close-retry — a teardown failure leaves the session allocated; a
	// later close completes and frees.
	session, open_err = term.open({input_mode = .Raw})
	check(open_err == nil, "open must succeed")
	live := len(tracking.allocation_map)
	term.Terminal_Test_Fail_Next_Teardown()
	first_err := term.close(session)
	check(first_err != nil, "an injected teardown failure must be reported")
	check(len(tracking.allocation_map) == live, "a failed close must leave the session allocated")
	retry_err := term.close(session)
	check(retry_err == nil, "close must be retryable until it succeeds")
	check(len(tracking.allocation_map) == 0, "the retry close must free the session")

	// C: resize — viewport polling reflects TIOCSWINSZ on the master.
	session, open_err = term.open({})
	check(open_err == nil, "open must succeed")
	ready_byte := byte('R')
	if posix.write(sync_out_w, &ready_byte, 1) != 1 {
		fmt.eprintln("child: resize-ready write failed")
		return 1
	}
	if !wait_for_byte(sync_in_r, 'G') {
		fmt.eprintln("child: resize-go signal missing")
		return 1
	}
	vp, vp_err := term.viewport(session)
	check(vp_err == nil, "viewport must succeed after a resize")
	check(vp.columns == 100 && vp.rows == 40, "viewport must report the resized 100x40, got %dx%d", vp.columns, vp.rows)
	check(term.close(session) == nil, "close must succeed")

	// D: zero-progress write — present reports Partial_Write with zero
	// committed bytes and keeps the exact required count.
	session, open_err = term.open({})
	check(open_err == nil, "open must succeed")
	frame := term.Frame_Buffer {
		columns = 2,
		rows    = 1,
		cells   = []term.Cell{{grapheme = "a", width = 1}, {grapheme = "b", width = 1}},
	}
	scratch: [1024]byte
	term.Terminal_Test_Zero_Write_Next()
	committed, required, present_err := term.present(session, frame, term.profile_default(), {}, scratch[:])
	check(present_err == term.General_Error.Partial_Write, "a zero-progress write must report Partial_Write")
	check(committed == 0, "zero progress must commit zero bytes")
	check(required > 0, "the frame must still report an exact required size")

	// Recovery: a later successful full frame restores the observable
	// presentation after the failed write (the hook is one-shot).
	recovery_committed, recovery_required, recovery_err := term.present(session, frame, term.profile_default(), {}, scratch[:])
	check(recovery_err == nil, "a later full frame must recover after a failed write")
	check(recovery_committed == recovery_required && recovery_committed == required, "the recovery frame must commit its full size")
	check(term.close(session) == nil, "close must succeed")

	// E: EINTR — a signal interrupting the blocked write/poll is retried
	// and the whole frame still lands.
	session, open_err = term.open({input_mode = .Raw})
	check(open_err == nil, "open must succeed")
	file, file_err := term.session_file(session)
	check(file_err == nil, "session_file must succeed")
	fd := posix.FD(os.fd(file))

	// Fill the pty output buffer so present's write genuinely blocks.
	junk: [4096]byte
	for i in 0 ..< len(junk) {
		junk[i] = 'j'
	}
	for {
		n := posix.write(fd, raw_data(junk[:]), c.size_t(len(junk)))
		if n < 0 {
			break
		}
	}
	fill_byte := byte('F')
	posix.write(sync_out_w, &fill_byte, 1)

	action := posix.sigaction_t {
		sa_handler = alarm_handler,
	}
	posix.sigaction(posix.Signal(posix.SIGALRM), &action, nil)
	timer := posix.itimerval {
		it_value = {tv_sec = 0, tv_usec = 20000},
	}
	posix.setitimer(.REAL, &timer, nil)

	big := make([]term.Cell, 200 * 50)
	defer delete(big)
	for &cell in big {
		cell = {
			grapheme = "x",
			width    = 1,
		}
	}
	big_frame := term.Frame_Buffer {
		columns = 200,
		rows    = 50,
		cells   = big,
	}
	big_scratch := make([]byte, 1 << 20)
	defer delete(big_scratch)
	_, _, eintr_err := term.present(session, big_frame, term.profile_default(), {}, big_scratch)
	check(eintr_err == nil, "present must retry EINTR and complete the full frame")
	check(alarm_fired > 0, "the SIGALRM timer must have fired during the blocked write")

	timer = {}
	posix.setitimer(.REAL, &timer, nil)
	done_byte := byte('D')
	posix.write(sync_out_w, &done_byte, 1)
	check(term.close(session) == nil, "close must succeed")

	// F: descriptor-close failure — the cause is reported (not suppressed),
	// the session stays allocated, and the retry close settles and frees.
	// (Scenario E's frame/scratch allocations are still live here — their
	// defers run at child exit — so the assertions are relative to them.)
	live = len(tracking.allocation_map)
	session, open_err = term.open({})
	check(open_err == nil, "open must succeed")
	check(len(tracking.allocation_map) == live + 1, "open must allocate exactly the session")
	term.Terminal_Test_Fail_Close_Next()
	first_err = term.close(session)
	check(first_err != nil, "a descriptor-close failure must be reported")
	check(len(tracking.allocation_map) == live + 1, "a failed descriptor close must leave the session allocated")
	retry_err = term.close(session)
	check(retry_err == nil, "the retry close must settle and free")
	check(len(tracking.allocation_map) == live, "the retry close must free the session")

	// H: present_operations over the real terminal — the operation stream
	// preflights, encodes into the caller-owned scratch, and commits its
	// exact size through the same write loop as present.
	session, open_err = term.open({})
	check(open_err == nil, "open must succeed")
	operations := []term.Presentation_Op {
		term.Move_Cursor_Op{{x = 0, y = 0}},
		term.Set_Style_Op{{foreground = term.Color(term.RGB_Color{0, 255, 0})}},
		term.Write_Grapheme_Op{grapheme = "ok", width = 1},
	}
	op_scratch: [4096]byte
	op_committed, op_required, op_err := term.present_operations(session, operations, term.profile_default(), op_scratch[:])
	check(op_err == nil, "present_operations must succeed on a real session")
	check(op_required > 0, "the op stream must report an exact required size")
	check(op_committed == op_required, "present_operations must commit its exact size, committed %d required %d", op_committed, op_required)

	// H2: max-boundary ops — a max(int) coordinate and erase count must
	// encode and commit exactly over the real terminal, never overflow or
	// panic (the CUP +1 runs in u64 and the digit buffer covers the whole
	// nonnegative int domain).
	max_ops := []term.Presentation_Op {
		term.Move_Cursor_Op{{x = max(int), y = max(int)}},
		term.Write_Grapheme_Op{grapheme = "x", width = 1},
		term.Erase_Cells_Op{count = max(int)},
	}
	max_scratch: [4096]byte
	max_committed, max_required, max_err := term.present_operations(session, max_ops, term.profile_default(), max_scratch[:])
	check(max_err == nil, "max-boundary ops must present on a real session")
	check(max_required > 0, "max-boundary ops must report an exact required size")
	check(max_committed == max_required, "max-boundary ops must commit their exact size, committed %d required %d", max_committed, max_required)
	check(term.close(session) == nil, "close must succeed")

	// G: SIGWINCH disposition — close restores the caller's previous
	// handler, so a closed session never leaves the package handler armed.
	sigwinch_action := posix.sigaction_t {
		sa_handler = alarm_handler,
	}
	posix.sigaction(posix.Signal(posix.SIGWINCH), &sigwinch_action, nil)
	session, open_err = term.open({})
	check(open_err == nil, "open must succeed")
	check(term.close(session) == nil, "close must succeed")
	restored: posix.sigaction_t
	posix.sigaction(posix.Signal(posix.SIGWINCH), nil, &restored)
	check(restored.sa_handler == alarm_handler, "close must restore the caller's SIGWINCH handler")

	return failures == 0 ? 0 : 1
}

// --- parent ---

main :: proc() {
	os.exit(run_parent())
}

run_parent :: proc() -> int {
	master, slave_path, ok := pty_open()
	check(ok, "pty must open")
	defer posix.close(master)
	defer delete(slave_path)

	child_out: [2]posix.FD
	parent_out: [2]posix.FD
	if posix.pipe(&child_out) != .OK || posix.pipe(&parent_out) != .OK {
		fmt.eprintln("sync pipes must open")
		return 1
	}

	pid := posix.fork()
	if pid < 0 {
		fmt.eprintln("fork must succeed")
		return 1
	}
	if pid == 0 {
		posix.close(master)
		posix.close(child_out[0])
		posix.close(parent_out[1])
		os.exit(run_child(slave_path, child_out[1], parent_out[0]))
	}

	posix.close(child_out[1])
	posix.close(parent_out[0])

	// Scenario C: resize the master once the child's session is open.
	if !wait_for_byte(child_out[0], 'R') {
		probe: c.int
		waited := posix.waitpid(pid, &probe, {.NOHANG})
		if waited == pid {
			fmt.eprintln("parent: child died before 'R'; status", probe)
		} else {
			fmt.eprintln("parent: resize-ready signal missing; child still alive")
		}
		return 1
	}
	size := Win_Size {
		rows    = 40,
		columns = 100,
	}
	linux.ioctl(linux.Fd(master), u32(TIOCSWINSZ), uintptr(rawptr(&size)))
	go_byte := byte('G')
	posix.write(parent_out[1], &go_byte, 1)

	// Scenario E: drain the slave slowly until the child finishes.
	drain_slave(child_out[0], master)

	status: c.int
	waited := posix.waitpid(pid, &status, {})
	check(waited == pid, "waitpid must return the child pid")
	exited := (status & 0x7f) == 0
	code := (status >> 8) & 0xff
	check(exited && code == 0, "child must exit 0, status %d", status)

	return failures == 0 ? 0 : 1
}
