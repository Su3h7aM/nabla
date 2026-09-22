#+test
package agent

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

import "nabla:agent/session"
import "nabla:ai"

// Shutdown and race validation. These drive the production control path: the real
// turn runner, the real tool executor, real child processes, and real signals.

// --- repeated cancellation and completion races -------------------------------

@(test)
test_repeated_cancellation_is_idempotent :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, shell_test_workspace(context.temp_allocator))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(t, chat, "repeat")

	effect := _test_begin_request(t, chat)

	testing.expect(t, chat_session_request_cancel(chat))
	// The turn is already stopping, so a repeat is refused rather than accepted
	// again, and it must not queue a cancellation for anything later.
	testing.expect(t, !chat_session_request_cancel(chat))
	testing.expect(t, !chat_session_request_cancel(chat))
	testing.expect_value(t, chat.state, Chat_State.Cancelling)

	chat_session_retire_operation(chat)
	finish := _test_settle(t, chat)
	testing.expect_value(t, finish.status, Chat_Terminal_Status.Cancelled)

	// Exactly one terminal effect, and a repeat cannot resurrect the turn.
	again := chat_session_advance(chat)
	testing.expect_value(t, again.kind, Chat_Effect_Kind.None)
	testing.expect_value(t, chat.terminal_status, Chat_Terminal_Status.Cancelled)
	testing.expect(t, !chat_session_request_cancel(chat))
}

@(test)
test_cancel_racing_successful_completion_yields_one_status :: proc(t: ^testing.T) {
	// Completion first: a cancellation arriving after the response completed must
	// not relabel a successful turn.
	completed: Chat_Test
	chat_test_begin(t, &completed, shell_test_workspace(context.temp_allocator))
	defer chat_test_end(t, &completed)
	completed_chat := &completed.chat
	_test_accept(t, completed_chat, "win")
	effect := _test_begin_request(t, completed_chat)
	testing.expect(t, chat_session_feed_completion(completed_chat, chat_session_event_source(completed_chat)))
	testing.expect(t, !chat_session_request_cancel(completed_chat))
	finish := _test_settle(t, completed_chat)
	testing.expect_value(t, finish.status, Chat_Terminal_Status.Completed)

	// Cancellation first: a completion arriving afterwards must not upgrade a
	// cancelled turn, and partial text must not be committed as a response.
	cancelled: Chat_Test
	chat_test_begin(t, &cancelled, shell_test_workspace(context.temp_allocator))
	defer chat_test_end(t, &cancelled)
	cancelled_chat := &cancelled.chat
	_test_accept(t, cancelled_chat, "lose")
	effect = _test_begin_request(t, cancelled_chat)
	testing.expect(t, chat_session_feed_text(cancelled_chat, chat_session_event_source(cancelled_chat), "half"))
	testing.expect(t, chat_session_request_cancel(cancelled_chat))
	testing.expect(t, !chat_session_feed_completion(cancelled_chat, chat_session_event_source(cancelled_chat)))
	chat_session_retire_operation(cancelled_chat)
	finish = _test_settle(t, cancelled_chat)
	testing.expect_value(t, finish.status, Chat_Terminal_Status.Cancelled)

	// The text the cancelled turn produced is kept as partial evidence.
	entries := _test_entries(t, cancelled_chat)
	defer session.entries_destroy(entries, context.allocator)
	if !testing.expect_value(t, len(entries), 2) { return }
	text, is_text := entries[1].payload.(session.Assistant_Entry)
	if !testing.expect(t, is_text, "the second entry should be assistant text") { return }
	testing.expect_value(t, text.text, "half")
	testing.expect(t, text.partial, "text from a cancelled turn is partial")
}

@(test)
test_cancellation_is_not_inherited_by_next_turn :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, shell_test_workspace(context.temp_allocator))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true

	for round in 0 ..< 3 {
		_test_accept(t, chat, fmt.aprintf("round %d", round, allocator = context.temp_allocator))
		effect := _test_begin_request(t, chat)
		if round == 0 {
			testing.expect(t, chat_session_request_cancel(chat))
			chat_session_retire_operation(chat)
			finish := _test_settle(t, chat)
			testing.expect_value(t, finish.status, Chat_Terminal_Status.Cancelled)
			continue
		}
		// A stale cancellation would surface here: a later turn must reach a normal
		// completion even though an earlier turn was cancelled.
		testing.expect(t, !chat_session_cancelled(chat))
		testing.expect_value(t, chat.state, Chat_State.Requesting)
		testing.expect(t, chat_session_feed_completion(chat, chat_session_event_source(chat)))
		finish := _test_settle(t, chat)
		testing.expect_value(t, finish.status, Chat_Terminal_Status.Completed)
	}
}

// --- signal handler lifetime ---------------------------------------------------

// keeping a saved disposition at a stable address is required by chat_signal_arm.
sigaction_storage :: struct {
	saved: posix.sigaction_t,
}

// The handler references only static storage, so it remains valid while sessions
// are created and destroyed around it. Under a sanitizer this surfaces a stale
// access if the handler still dereferenced session memory.
@(test)
test_signal_handler_outlives_sessions :: proc(t: ^testing.T) {
	for round in 0 ..< 24 {
		chat_cancel_reset()
		// Installation and removal are exercised repeatedly, and the session is
		// destroyed while the handler may still be returning from this round's signal.
		// If the handler referenced session memory rather than static storage, that
		// removal would dereference freed memory.
		previous: sigaction_storage
		chat_signal_arm(&previous.saved)

		fixture: Chat_Test
		chat_test_begin(t, &fixture, shell_test_workspace(context.temp_allocator))
		chat := &fixture.chat
		_test_accept(t, chat, "signal")
		effect := _test_begin_request(t, chat)

		testing.expect(t, linux.kill(linux.Pid(os.get_pid()), .SIGINT) == .NONE)
		// Wait for the handler to actually run, so this covers handler execution
		// overlapping session teardown rather than only a pending signal.
		deadline := time.tick_add(time.tick_now(), SHELL_TEST_BOUND)
		for !chat_cancel_requested() && time.tick_since(deadline) < 0 { time.sleep(time.Millisecond) }
		testing.expectf(t, chat_cancel_requested(), "round %d never observed the signal", round)

		chat_session_note_cancel(chat)
		chat_session_retire_operation(chat)
		finish := _test_settle(t, chat)
		testing.expect_value(t, finish.status, Chat_Terminal_Status.Cancelled)
		chat_test_end(t, &fixture)

		chat_signal_disarm(&previous.saved)
	}
	chat_cancel_reset()
}

// --- stale handler requests ----------------------------------------------------

// A request is only honoured if the token still holds the generation the requester
// observed. This is the mechanism that makes the interleaving below impossible.
@(test)
test_interrupt_generation_rejects_stale_request :: proc(t: ^testing.T) {
	token: ai.Interrupt
	stale := ai.interrupt_capture(&token)
	ai.interrupt_reset(&token)
	// The stale requester resumes after the reset and must not take effect.
	ai.interrupt_request_captured(&token, stale)
	testing.expect(t, !ai.interrupt_requested(&token))

	// A request in the current generation still works, and resetting clears it.
	ai.interrupt_request(&token)
	testing.expect(t, ai.interrupt_requested(&token))
	ai.interrupt_reset(&token)
	testing.expect(t, !ai.interrupt_requested(&token))

	// Repeated requests within one generation stay idempotent.
	current := ai.interrupt_capture(&token)
	ai.interrupt_request_captured(&token, current)
	ai.interrupt_request(&token)
	testing.expect(t, ai.interrupt_requested(&token))
}

// The interleaving this guards against: a handler enters during one turn, is
// descheduled before its write, the turn advances and the next turn resets the
// token, and only then does the handler resume. Splitting the request into a capture
// and a conditional write reproduces that ordering deterministically, and a live
// stale request is written on resume, so the test would fail if the request were
// unconditional.
@(test)
test_stale_handler_cannot_cancel_next_turn :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, shell_test_workspace(context.temp_allocator))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true

	_test_accept(t, chat, "first")
	effect := _test_begin_request(t, chat)
	first_turn := effect.turn_id

	// The handler runs only as far as observing the token, then stops.
	captured := ai.interrupt_capture(&chat_cancel)
	chat_session_request_cancel(chat)
	chat_session_retire_operation(chat)
	finish := _test_settle(t, chat)

	_test_accept(t, chat, "second")
	testing.expect_value(t, chat.active_turn_id, first_turn + 1)
	effect = _test_begin_request(t, chat)

	// The stale handler resumes and completes its write against a reset token.
	ai.interrupt_request_captured(&chat_cancel, captured)

	testing.expectf(t, !chat_cancel_requested(), "a stale handler cancelled the current turn")
	testing.expect_value(t, chat.state, Chat_State.Requesting)
	testing.expect(t, chat_session_feed_completion(chat, chat_session_event_source(chat)))
	finish = _test_settle(t, chat)
	testing.expect_value(t, finish.kind, Chat_Effect_Kind.Turn_Finished)
	testing.expect_value(t, finish.status, Chat_Terminal_Status.Completed)

	// A signal observed in the current generation still cancels.
	_test_accept(t, chat, "third")
	effect = _test_begin_request(t, chat)
	fresh := ai.interrupt_capture(&chat_cancel)
	ai.interrupt_request_captured(&chat_cancel, fresh)
	testing.expect(t, chat_cancel_requested())
	chat_session_note_cancel(chat)
	chat_session_retire_operation(chat)
	finish = _test_settle(t, chat)
	testing.expect_value(t, finish.status, Chat_Terminal_Status.Cancelled)
}

// --- post-fork child path -----------------------------------------------------

Shell_Spin :: struct {
	stop:       ^bool, // accessed atomically by the owner
	allocator:  mem.Allocator,
	iterations: int,
}

// shell_spin_serve keeps the heap, the runtime, and stdio busy while other threads
// fork, which is the condition a post-fork child must tolerate.
shell_spin_serve :: proc(thread: ^thread.Thread) {
	spin := cast(^Shell_Spin)thread.data
	for !sync.atomic_load(spin.stop) {
		scratch := make([]u8, 4096, spin.allocator)
		text := fmt.aprintf("spin-%d", len(scratch), allocator = spin.allocator)
		_ = len(text)
		delete(text, spin.allocator)
		delete(scratch, spin.allocator)
		spin.iterations += 1
	}
}

// The child calls only contextless raw syscalls and leaves through exit_group. That
// claim rests on audit of the child block, not on this test: what follows is stress
// coverage that a child which touched the runtime would be very likely to expose.
// Starting shells while other threads hold runtime locks must still work.
@(test)
test_shell_spawn_is_safe_with_running_threads :: proc(t: ^testing.T) {
	stop := false
	spinners: [4]Shell_Spin
	threads: [4]^thread.Thread
	for i in 0 ..< len(spinners) {
		spinners[i] = Shell_Spin {
			stop      = &stop,
			// The spinner threads run beside the test thread, so they cannot use the
			// allocator the test runner installs: it is per-task and not safe to share.
			// The heap allocator is the one they would contend on in a real program.
			allocator = runtime.heap_allocator(),
		}
		threads[i] = test_thread_start(shell_spin_serve, &spinners[i], "nabla-spin")
		if threads[i] == nil {
			testing.expectf(t, false, "spin thread %d could not start", i)
			stop = true
			for j in 0 ..< i {
				thread.join(threads[j])
				thread.destroy(threads[j])
			}
			return
		}
	}

	workspace := shell_test_workspace(context.temp_allocator)
	for iteration in 0 ..< 16 {
		arguments := tool_arguments_prepare(`{"command":"printf child-ok","working_directory":null,"timeout_ms":5000}`)
		object, is_object := arguments.value.(json.Object)
		if !is_object {
			tool_arguments_destroy(&arguments)
			testing.expectf(t, false, "iteration %d could not read arguments", iteration)
			break
		}
		ctx := Tool_Context {
			call_id   = "call_spin",
			workspace = workspace,
			allocator = context.temp_allocator,
		}
		result := tool_shell_execute(&ctx, object)
		ok_iteration := result.outcome == .Success && strings.contains(result.content, "child-ok")
		if !ok_iteration {
			testing.expectf(t, false, "iteration %d produced %v %q", iteration, result.outcome, result.content)
		}
		tool_result_destroy(&result)
		tool_arguments_destroy(&arguments)
		if !ok_iteration { break }
	}

	sync.atomic_store(&stop, true)
	for i in 0 ..< len(threads) {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}
}

// --- production shutdown ordering ---------------------------------------------

Shell_Tool_Run :: struct {
	thread: ^thread.Thread,
	chat:   ^Chat_Session,
	count:  int,
}

// chat_run_tools drives the shared job table directly, which is the path a committed call
// takes when the control loop is not the one running it.
shell_tool_serve :: proc(thread: ^thread.Thread) {
	run := cast(^Shell_Tool_Run)thread.data
	run.count = chat_run_tools(run.chat, {})
}

@(test)
test_shutdown_during_tool_reaps_child_before_session_cleanup :: proc(t: ^testing.T) {
	allocator := context.temp_allocator
	workspace := shell_test_workspace(allocator)
	pid_file := fmt.aprintf("%s/shutdown.pid", workspace, allocator = allocator)
	defer os.remove(pid_file)

	fixture: Chat_Test
	chat_test_begin(t, &fixture, workspace)
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(t, chat, "run a child")

	effect := _test_begin_request(t, chat)

	// A call that starts a background child and then sleeps, so the descendant is
	// observable and the turn is still running when the signal lands.
	command := fmt.aprintf("sleep 30 & echo $! > %s; sleep 30", pid_file, allocator = allocator)
	arguments := fmt.aprintf(`{{"command":%q,"working_directory":null,"timeout_ms":60000}}`, command, allocator = allocator)
	_test_stage_call(t, chat, "call_shutdown", arguments)
	effect = chat_session_advance(chat)
	testing.expect_value(t, effect.kind, Chat_Effect_Kind.Run_Tools)

	run := Shell_Tool_Run {
		chat = chat,
	}
	run.thread = test_thread_start(shell_tool_serve, &run, "nabla-shutdown-tool")
	if run.thread == nil {
		testing.expectf(t, false, "shutdown thread could not start")
		return
	}

	descendant, found := shell_await_pid_file(pid_file)
	if !found {
		testing.expectf(t, false, "tool child never started")
		thread.join(run.thread)
		thread.destroy(run.thread)
		return
	}
	testing.expect(t, chat_session_request_cancel(chat))
	thread.join(run.thread)
	thread.destroy(run.thread)

	testing.expect(t, chat_session_tools_done(chat, chat.active_turn_id, run.count))
	chat_session_retire_operation(chat)
	finish := _test_settle(t, chat)
	testing.expect_value(t, finish.kind, Chat_Effect_Kind.Turn_Finished)
	testing.expect_value(t, finish.status, Chat_Terminal_Status.Cancelled)

	// Retirement and reaping must already have happened, so cleanup cannot race a
	// live child.
	testing.expect_value(t, chat.operation.state, Chat_Operation_State.Retired)
	testing.expectf(t, shell_process_gone(descendant), "descendant %d outlived the turn, so reaping did not precede cleanup", descendant)
}

// Shutdown while the model request is in flight, driven through the real turn
// runner and the real SIGINT handler, then destroyed.
@(test)
test_shutdown_during_request_retires_before_session_cleanup :: proc(t: ^testing.T) {
	server: Shell_Stall_Server
	if !shell_stall_start(t, &server) { return }
	defer shell_stall_stop(&server)

	fixture: Chat_Test
	chat_test_begin(t, &fixture, shell_test_workspace(context.temp_allocator))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, 500000)
	_test_accept(t, chat, "block")

	run := Shell_Turn_Run {
		chat = chat,
		connection = ai.Provider_Connection {
			API = .OpenAI_Chat_Completions,
			Endpoint = fmt.aprintf("http://127.0.0.1:%d", server.port, allocator = context.temp_allocator),
		},
	}
	run.thread = test_thread_start(shell_turn_serve, &run, "nabla-shutdown-request")
	if run.thread == nil {
		testing.expectf(t, false, "shutdown thread could not start")
		return
	}

	if !sync.sema_wait_with_timeout(&server.accepted, SHELL_TEST_BOUND) {
		testing.expectf(t, false, "request never reached the stall server")
		thread.join(run.thread)
		thread.destroy(run.thread)
		return
	}
	testing.expect(t, linux.kill(linux.Pid(os.get_pid()), .SIGINT) == .NONE)
	thread.join(run.thread)
	thread.destroy(run.thread)

	testing.expectf(t, chat_cancel_requested(), "the SIGINT handler never requested cancellation")
	testing.expect_value(t, chat.terminal_status, Chat_Terminal_Status.Cancelled)
	testing.expect_value(t, chat.state, Chat_State.Idle)
	testing.expect_value(t, chat.operation.state, Chat_Operation_State.Retired)
	testing.expect(t, !run.completed)

	// The token is static and outlives the session; clearing it here is what keeps a
	// later turn from inheriting this cancellation.
	chat_cancel_reset()
	testing.expect(t, !chat_cancel_requested())
}
