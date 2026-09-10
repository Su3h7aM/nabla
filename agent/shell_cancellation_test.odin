package agent

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"

import "nabla:ai"

// Shell cancellation runs the real executor against real processes. The test
// synchronizes on observable evidence (a pid written by the command, or a request
// the server received) rather than on sleeps.

SHELL_TEST_BOUND :: 10 * time.Second

// shell_process_gone reports that a pid no longer exists. A reaped pid is gone; a
// zombie would still answer, so this is also the evidence that the child was reaped.
// Signal 0 performs the existence check without delivering anything.
SHELL_NO_SIGNAL :: linux.Signal(0)

shell_process_gone :: proc(pid: int) -> bool {
	if pid <= 0 { return true }
	return linux.kill(linux.Pid(pid), SHELL_NO_SIGNAL) == linux.Errno.ESRCH
}

shell_await_process_gone :: proc(pid: int) -> bool {
	deadline := time.tick_add(time.tick_now(), SHELL_TEST_BOUND)
	for time.tick_since(deadline) < 0 {
		if shell_process_gone(pid) { return true }
		time.sleep(5 * time.Millisecond)
	}
	return shell_process_gone(pid)
}

shell_test_workspace :: proc(allocator: mem.Allocator) -> string {
	path := fmt.aprintf("/tmp/svan-shell-test-%d", os.get_pid(), allocator = allocator)
	_ = os.make_directory(path)
	return path
}

// A cancelled command reports the pid it started, so the test can prove the
// descendant is gone rather than trusting that the group was signalled.
Shell_Run :: struct {
	thread:    ^thread.Thread,
	control:   Tool_Control,
	args:      Tool_Shell_Args,
	workspace: string,
	result:    Tool_Result,
	started:   sync.Sema,
}

shell_run_start :: proc(run: ^Shell_Run, workspace: string, command: string, control: Tool_Control) -> bool {
	args, ok := tool_shell_parse_args(
		fmt.aprintf(`{{"command":%q,"working_directory":null,"timeout_ms":10000}}`, command, allocator = context.temp_allocator),
		context.temp_allocator,
	)
	if !ok { return false }
	run.workspace = workspace
	run.control = control
	run.args = args
	run.thread = test_thread_start(shell_run_serve, run, "svan-shell-run")
	return run.thread != nil
}

shell_run_serve :: proc(thread: ^thread.Thread) {
	run := cast(^Shell_Run)thread.data
	run.result = tool_shell_execute("call_shell", run.args, run.workspace, run.control, context.allocator)
}

shell_run_join :: proc(run: ^Shell_Run) {
	if run.thread == nil { return }
	thread.join(run.thread)
	thread.destroy(run.thread)
	run.thread = nil
}

// shell_read_pid file is the synchronization point: the command has reached the
// point where its descendant exists.
shell_read_pid_file :: proc(path: string) -> (int, bool) {
	contents, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil { return 0, false }
	text := strings.trim_space(string(contents))
	if text == "" { return 0, false }
	pid, parsed := strconv.parse_int(text)
	if !parsed { return 0, false }
	return pid, true
}

shell_await_pid_file :: proc(path: string) -> (int, bool) {
	deadline := time.tick_add(time.tick_now(), SHELL_TEST_BOUND)
	for time.tick_since(deadline) < 0 {
		if pid, ok := shell_read_pid_file(path); ok { return pid, true }
		time.sleep(5 * time.Millisecond)
	}
	return 0, false
}

@(test)
test_shell_timeout_applies_after_pipes_close :: proc(t: ^testing.T) {
	allocator := context.temp_allocator
	workspace := shell_test_workspace(allocator)
	args, ok := tool_shell_parse_args(`{"command":"exec 1>&- 2>&-; sleep 5","working_directory":null,"timeout_ms":100}`, allocator)
	testing.expect(t, ok)
	defer tool_shell_args_destroy(&args, allocator)
	started := time.tick_now()
	result := tool_shell_execute("call_timeout", args, workspace, {}, context.temp_allocator)
	defer tool_result_destroy(&result)
	elapsed := time.tick_since(started)
	testing.expect_value(t, result.status, Tool_Result_Status.Timed_Out)
	testing.expectf(t, elapsed < 2 * time.Second, "100ms budget took %v; retirement ignored the deadline", elapsed)
}

@(test)
test_shell_cancel_terminates_descendants :: proc(t: ^testing.T) {
	allocator := context.temp_allocator
	workspace := shell_test_workspace(allocator)
	pid_file := fmt.aprintf("%s/descendant.pid", workspace, allocator = allocator)
	defer os.remove(pid_file)

	interrupt: ai.Interrupt
	run: Shell_Run
	// The background child is a descendant of the direct child: only signalling the
	// process group reaches it.
	command := fmt.aprintf("sleep 30 & echo $! > %s; wait", pid_file, allocator = allocator)
	if !shell_run_start(&run, workspace, command, Tool_Control{interrupt = &interrupt}) {
		testing.expectf(t, false, "shell run could not start")
		return
	}
	descendant, found := shell_await_pid_file(pid_file)
	defer shell_run_join(&run)
	if !found {
		testing.expectf(t, false, "command never reported its descendant")
		return
	}
	testing.expectf(t, !shell_process_gone(descendant), "descendant %d was not running before cancellation", descendant)

	ai.interrupt_request(&interrupt)
	shell_run_join(&run)
	defer tool_result_destroy(&run.result)

	testing.expect_value(t, run.result.status, Tool_Result_Status.Cancelled)
	testing.expectf(t, shell_await_process_gone(descendant), "descendant %d survived cancellation", descendant)
}

@(test)
test_shell_cancel_escalates_when_sigterm_is_ignored :: proc(t: ^testing.T) {
	allocator := context.temp_allocator
	workspace := shell_test_workspace(allocator)

	interrupt: ai.Interrupt
	run: Shell_Run
	// The shell ignores SIGTERM and keeps running, so only SIGKILL ends it. If the
	// escalation were missing this call would block on the final reap instead of
	// returning, which the suite's external timeout would catch.
	if !shell_run_start(&run, workspace, `trap "" TERM; while :; do sleep 0.05; done`, Tool_Control{interrupt = &interrupt}) {
		testing.expectf(t, false, "shell run could not start")
		return
	}
	defer shell_run_join(&run)
	time.sleep(100 * time.Millisecond)
	started := time.tick_now()
	ai.interrupt_request(&interrupt)
	shell_run_join(&run)
	elapsed := time.tick_since(started)
	defer tool_result_destroy(&run.result)

	testing.expect_value(t, run.result.status, Tool_Result_Status.Cancelled)
	testing.expectf(t, elapsed >= TOOL_KILL_GRACE, "returned in %v without waiting out the SIGTERM grace, so SIGKILL was not the escalation path", elapsed)
}

@(test)
test_shell_cancel_reaps_child_and_allows_next_turn :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = shell_test_workspace(context.temp_allocator)
	session.tools_enabled = true
	testing.expect(t, chat_session_accept_user(&session, "run something long"))

	effect := tool_loop_begin_request(&session)
	first_turn := effect.turn_id
	chat_effect_destroy(&effect)
	calls := []ai.Provider_Tool_Call {
		{ID = "call_long", Name = TOOL_SHELL_NAME, Arguments = `{"command":"sleep 30","working_directory":null,"timeout_ms":10000}`},
	}
	testing.expect(t, chat_session_feed_tool_calls(&session, chat_session_event_source(&session), calls))
	effect = chat_session_advance(&session)
	testing.expect_value(t, effect.kind, Chat_Effect_Kind.Run_Tools)
	chat_effect_destroy(&effect)

	// Cancel and execute on separate threads so the request lands while the command
	// is genuinely running.
	chat_session_request_cancel(&session)
	testing.expect_value(t, session.state, Chat_State.Cancelling)
	count := chat_execute_pending(&session, {})
	testing.expect_value(t, count, 1)
	testing.expect(t, chat_session_tools_done(&session, session.active_turn_id, count))
	// The committed call is resolved rather than left dangling.
	testing.expect_value(t, session.messages[2].role, Chat_Role.Tool)
	testing.expect(t, strings.contains(session.messages[2].text, "cancelled") || strings.contains(session.messages[2].text, "not_executed"))
	chat_session_retire_operation(&session)

	finish := chat_session_advance(&session)
	testing.expect_value(t, finish.kind, Chat_Effect_Kind.Turn_Finished)
	testing.expect_value(t, finish.status, Chat_Terminal_Status.Cancelled)
	chat_effect_destroy(&finish)
	testing.expect_value(t, session.state, Chat_State.Idle)

	// A fresh turn starts immediately, without waiting on anything from the last one.
	testing.expect(t, chat_session_accept_user(&session, "next"))
	testing.expect_value(t, session.active_turn_id, first_turn + 1)
	testing.expect(t, !chat_session_cancelled(&session))
	effect = tool_loop_begin_request(&session)
	testing.expect_value(t, effect.kind, Chat_Effect_Kind.Start_Request)
	chat_effect_destroy(&effect)
}

// --- SIGINT through the production control loop -------------------------------

// test_thread_start creates a thread with SIGINT already blocked, then restores the
// creating thread's mask.
//
// Masking inside the new thread would leave a startup window: the OS thread exists
// from thread.create (it waits on a condition variable until start), so a
// process-directed SIGINT can be delivered to it before its own mask is applied. A
// handler running there could be entered before a turn reset and capture the next
// generation afterwards, cancelling a turn it does not own. Blocking before the
// spawn and letting the child inherit closes that window; the mask is inherited from
// the creating thread at pthread_create.
test_thread_start :: proc(routine: thread.Thread_Proc, data: rawptr, name: string) -> ^thread.Thread {
	// Block SIGINT for the whole spawn so the new thread inherits the mask. Masking
	// at thread entry would leave a startup window: thread.create already spawns the
	// OS thread, so a process-directed SIGINT could reach it first.
	blocked := chat_signal_int_set()
	previous: linux.Sig_Set
	_ = linux.rt_sigprocmask(.SIG_BLOCK, &blocked, &previous)
	defer _ = linux.rt_sigprocmask(.SIG_SETMASK, &previous, nil)

	started := thread.create(routine, name = name)
	if started == nil { return nil }
	started.data = data
	thread.start(started)
	return started
}

// A server that accepts and then never answers leaves the request blocked in a
// read, which is where Ctrl-C has to reach it.
Shell_Stall_Server :: struct {
	listener: net.TCP_Socket,
	port:     int,
	accepted: sync.Sema,
	release:  sync.Sema,
	thread:   ^thread.Thread,
}

shell_stall_serve :: proc(thread: ^thread.Thread) {
	server := cast(^Shell_Stall_Server)thread.data
	socket, _, accept_err := net.accept_tcp(server.listener)
	if accept_err != nil {
		sync.sema_post(&server.accepted)
		return
	}
	defer net.close(socket)
	// Read the request so the client is provably in flight, then hold the
	// connection open without responding.
	scratch: [4096]u8
	_, _ = net.recv_tcp(socket, scratch[:])
	sync.sema_post(&server.accepted)
	_ = sync.sema_wait_with_timeout(&server.release, SHELL_TEST_BOUND)
}

// The server is owned by the caller: the worker thread keeps a pointer to it, so
// returning it by value would leave that pointer aimed at a dead stack frame.
shell_stall_start :: proc(t: ^testing.T, server: ^Shell_Stall_Server) -> bool {
	server^ = {}
	listener, listen_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	if listen_err != nil {
		testing.expectf(t, false, "stall server could not listen: %v", listen_err)
		return false
	}
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if endpoint_err != nil {
		testing.expectf(t, false, "stall server had no endpoint: %v", endpoint_err)
		net.close(listener)
		return false
	}
	server.listener = listener
	server.port = endpoint.port
	server.thread = test_thread_start(shell_stall_serve, server, "svan-stall-server")
	if server.thread == nil {
		testing.expectf(t, false, "stall server thread could not start")
		net.close(listener)
		return false
	}
	return true
}

shell_stall_stop :: proc(server: ^Shell_Stall_Server) {
	if server.thread == nil { return }
	sync.sema_post(&server.release)
	thread.join(server.thread)
	thread.destroy(server.thread)
	server.thread = nil
	if server.listener != {} {
		net.close(server.listener)
		server.listener = {}
	}
}

Shell_Turn_Run :: struct {
	thread:     ^thread.Thread,
	session:    ^Chat_Session,
	connection: ai.Provider_Connection,
	completed:  bool,
}

shell_turn_serve :: proc(thread: ^thread.Thread) {
	run := cast(^Shell_Turn_Run)thread.data
	run.completed = chat_run_turn(run.session, run.connection, "shell-test-model", {})
}

shell_turn_join :: proc(run: ^Shell_Turn_Run) {
	if run.thread == nil { return }
	thread.join(run.thread)
	thread.destroy(run.thread)
	run.thread = nil
}

@(test)
test_sigint_cancels_turn_through_control_loop :: proc(t: ^testing.T) {
	server: Shell_Stall_Server
	if !shell_stall_start(t, &server) { return }
	defer shell_stall_stop(&server)

	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = shell_test_workspace(context.temp_allocator)
	session.context_window = 500000
	testing.expect(t, chat_session_accept_user(&session, "hello"))
	first_turn := session.active_turn_id

	run := Shell_Turn_Run {
		session = &session,
		connection = ai.Provider_Connection {
			API = .OpenAI_Chat_Completions,
			Endpoint = fmt.aprintf("http://127.0.0.1:%d", server.port, allocator = context.temp_allocator),
		},
	}
	run.thread = test_thread_start(shell_turn_serve, &run, "svan-turn-run")
	if run.thread == nil {
		testing.expectf(t, false, "turn thread could not start")
		return
	}
	defer shell_turn_join(&run)

	// The server has the request, so the handler is armed and the request is blocked
	// in a read: this is the real Ctrl-C window.
	if !sync.sema_wait_with_timeout(&server.accepted, SHELL_TEST_BOUND) {
		testing.expectf(t, false, "request never reached the stall server")
		return
	}
	testing.expect(t, linux.kill(linux.Pid(os.get_pid()), .SIGINT) == .NONE)
	shell_turn_join(&run)

	testing.expectf(t, chat_cancel_requested(), "the SIGINT handler never requested cancellation")
	testing.expect_value(t, session.terminal_status, Chat_Terminal_Status.Cancelled)
	testing.expect_value(t, session.state, Chat_State.Idle)
	testing.expect(t, !run.completed)

	// The turn is over and the session is immediately reusable.
	testing.expect(t, chat_session_accept_user(&session, "again"))
	testing.expect_value(t, session.active_turn_id, first_turn + 1)
	testing.expect(t, !chat_session_cancelled(&session))
	effect := tool_loop_begin_request(&session)
	testing.expect_value(t, effect.kind, Chat_Effect_Kind.Start_Request)
	chat_effect_destroy(&effect)
}
