#+test
package agent

import "core:encoding/json"
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

import "nabla:agent/journal"
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

shell_test_workspace_sequence: i64

shell_test_workspace :: proc(allocator: mem.Allocator) -> string {
	// One directory per call, not per process: parallel tests share nothing, and
	// a retry of one test never inherits another attempt's files.
	sequence := sync.atomic_add(&shell_test_workspace_sequence, 1)
	path := fmt.aprintf("/tmp/nabla-shell-test-%d-%d", os.get_pid(), sequence, allocator = allocator)
	_ = os.make_directory(path)
	return path
}

// A cancelled command reports the pid it started, so the test can prove the
// descendant is gone rather than trusting that the group was signalled.
Shell_Run :: struct {
	thread:    ^thread.Thread,
	interrupt: ai.Interrupt,
	wake:      Tool_Wake,
	command:   string,
	workspace: string,
	result:    Tool_Result,
	started:   sync.Sema,
}

shell_run_start :: proc(run: ^Shell_Run, workspace: string, command: string) -> bool {
	wake, wake_error := tool_wake_open()
	if wake_error != nil { return false }
	run.wake = wake
	run.workspace = workspace
	run.command = command
	run.thread = test_thread_start(shell_run_serve, run, "nabla-shell-run")
	if run.thread == nil { tool_wake_close(&run.wake) }
	return run.thread != nil
}

shell_run_serve :: proc(thread: ^thread.Thread) {
	run := cast(^Shell_Run)thread.data
	raw := fmt.aprintf(`{{"command":%q,"working_directory":null,"timeout_ms":10000}}`, run.command)
	defer delete(raw)
	arguments := tool_arguments_prepare(raw)
	defer tool_arguments_destroy(&arguments)

	tool_context := Tool_Context {
		call_id = "call_shell",
		workspace = run.workspace,
		control = {interrupt = &run.interrupt, wake = run.wake.read},
		allocator = context.allocator,
	}
	object, is_object := arguments.value.(json.Object)
	if !is_object {
		run.result = tool_result_failure(&tool_context, .Invalid_Arguments, "the test arguments did not parse")
		return
	}
	run.result = tool_test_execute(&tool_context, Tool_Definition{kind = .Shell, execute = tool_shell_execute}, object)
}

shell_run_join :: proc(run: ^Shell_Run) {
	if run.thread == nil { return }
	thread.join(run.thread)
	thread.destroy(run.thread)
	run.thread = nil
	tool_wake_close(&run.wake)
}

// shell_run_stop stops the command the way the owner stops a job.
shell_run_stop :: proc(run: ^Shell_Run) {
	ai.interrupt_request(&run.interrupt)
	tool_wake_signal(&run.wake)
}

// shell_read_pid file is the synchronization point: the command has reached the
// point where its descendant exists.
shell_read_pid_file :: proc(path: string) -> (int, bool) {
	contents, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil { return 0, false }
	text := strings.trim_space(string(contents))
	if text == "" { return 0, false }
	pid, parsed := strconv.parse_int(text)
	if !parsed { return 0, false }
	return pid, true
}

shell_await_pid_file :: proc(path: string) -> (int, bool) {
	deadline := time.tick_add(time.tick_now(), SHELL_TEST_BOUND)
	for time.tick_since(deadline) < 0 {
		if pid, found := shell_read_pid_file(path); found { return pid, true }
		time.sleep(5 * time.Millisecond)
	}
	return 0, false
}

@(test)
test_shell_timeout_applies_after_pipes_close :: proc(test: ^testing.T) {
	allocator := context.temp_allocator
	workspace := shell_test_workspace(allocator)
	arguments := tool_arguments_prepare(`{"command":"exec 1>&- 2>&-; sleep 5","working_directory":null,"timeout_ms":100}`)
	defer tool_arguments_destroy(&arguments)
	object, is_object := arguments.value.(json.Object)
	if !testing.expect(test, is_object, "the arguments should parse") { return }
	tool_context := Tool_Context {
		call_id   = "call_timeout",
		workspace = workspace,
		allocator = allocator,
	}
	started := time.tick_now()
	result := tool_test_execute(&tool_context, Tool_Definition{kind = .Shell, execute = tool_shell_execute}, object)
	defer tool_result_destroy(&result)
	elapsed := time.tick_since(started)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Timed_Out)
	testing.expectf(test, elapsed < 2 * time.Second, "100ms budget took %v; retirement ignored the deadline", elapsed)
}

@(test)
test_shell_cancel_terminates_descendants :: proc(test: ^testing.T) {allocator := context.temp_allocator
	workspace := shell_test_workspace(allocator)
	pid_file := fmt.aprintf("%s/descendant.pid", workspace, allocator = allocator)
	defer os.remove(pid_file)

	run: Shell_Run
	// The background child is a descendant of the direct child: only signalling the
	// process group reaches it.
	// The command is POSIX shell source, so it names the shell that runs it rather than
	// inheriting whatever shell started the suite.
	command := fmt.aprintf("exec sh -c 'sleep 30 & echo $! > %s; wait'", pid_file, allocator = allocator)
	if !shell_run_start(&run, workspace, command) {
		testing.expectf(test, false, "shell run could not start")
		return
	}
	descendant, found := shell_await_pid_file(pid_file)
	defer shell_run_join(&run)
	if !found {
		testing.expectf(test, false, "command never reported its descendant")
		return
	}
	testing.expectf(test, !shell_process_gone(descendant), "descendant %d was not running before cancellation", descendant)

	shell_run_stop(&run)
	shell_run_join(&run)
	defer tool_result_destroy(&run.result)

	testing.expect_value(test, run.result.outcome, journal.Tool_Outcome.Cancelled)
	testing.expectf(test, shell_await_process_gone(descendant), "descendant %d survived cancellation", descendant)
}

@(test)
test_shell_cancel_escalates_when_sigterm_is_ignored :: proc(test: ^testing.T) {
	allocator := context.temp_allocator
	workspace := shell_test_workspace(allocator)

	run: Shell_Run
	// The shell ignores SIGTERM and keeps running, so only SIGKILL ends it. If the
	// escalation were missing this call would block on the final reap instead of
	// returning, which the suite's external timeout would catch.
	// The command is POSIX shell source, so it names the shell that runs it rather than
	// inheriting whatever shell started the suite. exec leaves that shell as the direct
	// child, so the SIGTERM the group receives is the one it ignores.
	if !shell_run_start(&run, workspace, `exec sh -c 'trap "" TERM; while :; do sleep 0.05; done'`) {
		testing.expectf(test, false, "shell run could not start")
		return
	}
	defer shell_run_join(&run)
	time.sleep(100 * time.Millisecond)
	started := time.tick_now()
	shell_run_stop(&run)
	shell_run_join(&run)
	elapsed := time.tick_since(started)
	defer tool_result_destroy(&run.result)

	testing.expect_value(test, run.result.outcome, journal.Tool_Outcome.Cancelled)
	testing.expectf(test, elapsed >= TOOL_KILL_GRACE, "returned in %v without waiting out the SIGTERM grace, so SIGKILL was not the escalation path", elapsed)
}

@(test)
test_shell_cancel_reaps_child_and_allows_next_turn :: proc(test: ^testing.T) {
	if !test_isolate_process(test, #procedure) { return }
	fixture: Chat_Test
	chat_test_begin(test, &fixture, shell_test_workspace(context.temp_allocator))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(test, chat, "run something long")

	effect := _test_begin_request(test, chat)
	first_turn := effect.turn_id

	// The call is recorded first, exactly as a completed response would, and then
	// the turn is cancelled before the tool would have finished.
	_test_stage_call(test, chat, "call_long", `{"command":"sleep 30","working_directory":null,"timeout_ms":10000}`)
	effect = chat_session_advance(chat)
	testing.expect_value(test, effect.kind, Chat_Effect_Kind.Run_Tools)

	chat_session_request_cancel(chat)
	testing.expect_value(test, chat.state, Chat_State.Cancelling)
	count := chat_run_tools(chat, {})
	testing.expect_value(test, count, 1)
	testing.expect(test, chat_session_tools_done(chat, chat.active_turn_id, count))

	// The committed call is resolved rather than left dangling: its result reached the
	// journal with an outcome the harness named.
	completions := _test_records(test, chat, {.Tool_Completed})
	if !testing.expect_value(test, len(completions), 1) { return }
	completion: journal.Tool_Completed
	if !testing.expect_value(test, journal.payload_decode(completions[0].data, &completion, context.temp_allocator), nil) { return }
	outcome, known := journal.enum_from_name(journal.TOOL_OUTCOME_NAMES, completion.outcome)
	if !testing.expect(test, known, "the recorded outcome is one the harness names") { return }
	testing.expect(test, outcome == .Cancelled || outcome == .Not_Executed, "a cancelled call is resolved, not left dangling")
	chat_session_retire_operation(chat)

	finish := _test_settle(test, chat)
	testing.expect_value(test, finish.kind, Chat_Effect_Kind.Turn_Finished)
	testing.expect_value(test, finish.status, Chat_Terminal_Status.Cancelled)
	testing.expect_value(test, chat.state, Chat_State.Idle)

	// A fresh turn starts immediately, without waiting on anything from the last one.
	_test_accept(test, chat, "next")
	testing.expect_value(test, chat.active_turn_id, first_turn + 1)
	testing.expect(test, !chat_session_cancelled(chat))
	effect = _test_begin_request(test, chat)
	testing.expect_value(test, effect.kind, Chat_Effect_Kind.Start_Request)
}

// --- SIGINT through the production control loop -------------------------------

// test_thread_start creates a thread that inherits a mask blocking the watched signals,
// so a signal a test raises is handled by the thread under test, never by a helper.
test_thread_start :: proc(routine: thread.Thread_Proc, data: rawptr, name: string) -> ^thread.Thread {
	previous := chat_signal_block_watched()
	defer chat_signal_restore(previous)

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
	socket, _, accept_error := net.accept_tcp(server.listener)
	if accept_error != nil {
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
shell_stall_start :: proc(test: ^testing.T, server: ^Shell_Stall_Server) -> bool {
	server^ = {}
	listener, listen_error := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	if listen_error != nil {
		testing.expectf(test, false, "stall server could not listen: %v", listen_error)
		return false
	}
	endpoint, endpoint_error := net.bound_endpoint(listener)
	if endpoint_error != nil {
		testing.expectf(test, false, "stall server had no endpoint: %v", endpoint_error)
		net.close(listener)
		return false
	}
	server.listener = listener
	server.port = endpoint.port
	server.thread = test_thread_start(shell_stall_serve, server, "nabla-stall-server")
	if server.thread == nil {
		testing.expectf(test, false, "stall server thread could not start")
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
	chat:       ^Chat_Session,
	connection: ai.Provider_Connection,
	completed:  bool,
}

shell_turn_serve :: proc(thread: ^thread.Thread) {
	run := cast(^Shell_Turn_Run)thread.data
	run.completed = chat_run_turn(run.chat, run.connection, test_retry_policy(), {})
}

shell_turn_join :: proc(run: ^Shell_Turn_Run) {
	if run.thread == nil { return }
	thread.join(run.thread)
	thread.destroy(run.thread)
	run.thread = nil
}

@(test)
test_sigint_cancels_turn_through_control_loop :: proc(test: ^testing.T) {
	if !test_isolate_process(test, #procedure) { return }
	server: Shell_Stall_Server
	if !shell_stall_start(test, &server) { return }
	defer shell_stall_stop(&server)

	fixture: Chat_Test
	chat_test_begin(test, &fixture, shell_test_workspace(context.temp_allocator))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, 500000)
	_test_accept(test, chat, "hello")
	first_turn := chat.active_turn_id

	run := Shell_Turn_Run {
		chat = chat,
		connection = ai.Provider_Connection {
			API = .OpenAI_Chat_Completions,
			Endpoint = fmt.aprintf("http://127.0.0.1:%d", server.port, allocator = context.temp_allocator),
		},
	}
	run.thread = test_thread_start(shell_turn_serve, &run, "nabla-turn-run")
	if run.thread == nil {
		testing.expectf(test, false, "turn thread could not start")
		return
	}
	defer shell_turn_join(&run)

	// The server has the request, so the handler is armed and the request is blocked
	// in a read: this is the real Ctrl-C window.
	if !sync.sema_wait_with_timeout(&server.accepted, SHELL_TEST_BOUND) {
		testing.expectf(test, false, "request never reached the stall server")
		return
	}
	testing.expect(test, linux.kill(linux.Pid(os.get_pid()), .SIGINT) == .NONE)
	shell_turn_join(&run)

	testing.expectf(test, process_interrupted(), "the SIGINT handler never latched the interrupt")
	testing.expect_value(test, chat.terminal_status, Chat_Terminal_Status.Cancelled)
	testing.expect_value(test, chat.state, Chat_State.Idle)
	testing.expect(test, !run.completed)

	// The attempt that was in flight is awaited, so the send that was running records its
	// own end: the turn's status is the cancellation, and the interrupted send names the
	// request it was.
	interruptions := _test_records(test, chat, {.Request_Interrupted})
	if !testing.expect_value(test, len(interruptions), 1) { return }
	testing.expect(test, interruptions[0].request != 0, "the interrupted send names its request")
	interruption: journal.Request_Interrupted
	if !testing.expect_value(test, journal.payload_decode(interruptions[0].data, &interruption, context.temp_allocator), nil) { return }
	testing.expect(test, interruption.detail != "", "the cancelled send's own account must be recorded")

	// The turn is over and the session is immediately reusable. The process would exit on
	// the signal, so the latch is cleared to show the session itself holds no stop.
	sync.atomic_store(&process_interrupt.requested, false)
	_test_accept(test, chat, "again")
	testing.expect_value(test, chat.active_turn_id, first_turn + 1)
	testing.expect(test, !chat_session_cancelled(chat))
	effect := _test_begin_request(test, chat)
	testing.expect_value(test, effect.kind, Chat_Effect_Kind.Start_Request)
}

// Backoff_Wait is signalled when a chain schedules a retry, which is the moment before it waits
// out the delay.
Backoff_Wait :: struct {
	scheduled: sync.Sema,
}

backoff_note_scheduled :: proc(user_data: rawptr, event: Chat_Retry_Event) {
	wait := cast(^Backoff_Wait)user_data
	sync.sema_post(&wait.scheduled)
}

// backoff_send_signal delivers the stop once the retry is scheduled. The thread blocks SIGINT
// and so can never run the process handler itself, which is the point: the signal reaches the
// owner through the handler and the handler's wake, not through this thread.
backoff_send_signal :: proc(thread: ^thread.Thread) {
	wait := cast(^Backoff_Wait)thread.data
	if !sync.sema_wait_with_timeout(&wait.scheduled, SHELL_TEST_BOUND) { return }
	_ = linux.kill(linux.Pid(os.get_pid()), .SIGINT)
}

// A stop that no provider or tool event follows still has to reach the owner. During a retry
// backoff the owner is the only thread left, so the signal handler itself has to wake the wait:
// nothing else can, and a wait that no longer polls would otherwise run the whole delay.
@(test)
test_sigint_cuts_a_retry_backoff_short :: proc(test: ^testing.T) {
	if !test_isolate_process(test, #procedure) { return }
	// A backoff far longer than the bound below, so a turn that returns inside it can only have
	// been woken rather than waited out.
	BACKOFF_DELAY :: 3 * time.Second

	responses := []string{agent_provider_refusal("429 Too Many Requests", `{"error":{"message":"Rate limit reached"}}`, "retry-after: 0\r\n")}
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)

	fixture: Chat_Test
	chat_test_begin(test, &fixture, shell_test_workspace(context.temp_allocator))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, 500_000)
	_test_accept(test, chat, "hello")

	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	policy := test_retry_policy()
	policy.base_delay = BACKOFF_DELAY
	policy.max_delay = BACKOFF_DELAY

	// The handler stays armed for the whole test, so a signal that arrives after the turn
	// restored the default disposition cannot terminate this process.
	previous: sigaction_storage
	chat_signal_arm(&previous.saved)
	defer chat_signal_disarm(&previous.saved)

	wait: Backoff_Wait
	observer := Chat_Observer {
		user_data       = &wait,
		retry_scheduled = backoff_note_scheduled,
	}
	sender := test_thread_start(backoff_send_signal, &wait, "nabla-backoff-signal")
	if sender == nil {
		testing.expectf(test, false, "the signal sender could not start")
		return
	}
	defer {
		thread.join(sender)
		thread.destroy(sender)
	}

	started := time.tick_now()
	completed := chat_run_turn(chat, connection, policy, observer)
	elapsed := time.tick_since(started)

	testing.expect(test, !completed)
	testing.expect_value(test, chat.terminal_status, Chat_Terminal_Status.Cancelled)
	testing.expectf(test, elapsed < BACKOFF_DELAY / 2, "the retry backoff was not cut short: %v", elapsed)
	// The second attempt never went out: the stop arrived while the chain was waiting.
	testing.expect_value(test, agent_provider_request_count(&provider), 1)
}
