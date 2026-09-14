#+test
package agent

// Support shared by the agent package's test files. The chat suites run against
// a real store, because a session's history is the store now and a fake would
// test the fake instead of the harness.

import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent/session"

// Chat_Test binds a running session to a temporary store. The store lives in the
// fixture so its address is stable while the session points at it.
Chat_Test :: struct {
	store: session.Store,
	dir:   string,
	chat:  Chat_Session,
}

chat_test_begin :: proc(t: ^testing.T, fixture: ^Chat_Test, workspace: string) {
	directory, directory_err := os.make_directory_temp("", "nabla-agent-test-*", context.allocator)
	if directory_err != nil { testing.fail_now(t, "could not create a temporary directory") }
	fixture.dir = directory

	if err := session.store_open(&fixture.store, directory); err != nil {
		local := err
		testing.fail_now(t, strings.concatenate({"store_open failed: ", session.error_detail(&local)}, context.temp_allocator))
	}
	created, create_err := session.session_create(&fixture.store, {workspace = workspace}, 1_000)
	if create_err != nil { testing.fail_now(t, "session_create failed") }
	id := session.Session_Id(strings.clone(string(created.id), context.allocator))
	session.session_destroy(&created)

	if claim_err := session.session_claim(&fixture.store, id); claim_err != nil {
		testing.fail_now(t, "session_claim failed")
	}
	delete(string(id), context.allocator)

	// The running session borrows the id the claim owns, so the two cannot drift.
	claimed, held := session.session_claimed(&fixture.store)
	if !held { testing.fail_now(t, "the claim went missing") }
	fixture.chat = chat_session_init(&fixture.store, claimed, workspace, context.allocator)
	fixture.chat.provider_id = chat_clone_string("test-provider", context.allocator)
	fixture.chat.model_id = chat_clone_string("test-model", context.allocator)
	fixture.chat.skill_instructions = strings.clone(AGENT_SYSTEM_PROMPT, fixture.chat.allocator)
}

chat_test_end :: proc(t: ^testing.T, fixture: ^Chat_Test) {
	chat_session_destroy(&fixture.chat)
	session.session_release(&fixture.store)
	session.store_close(&fixture.store)
	os.remove_all(fixture.dir)
	delete(fixture.dir, context.allocator)
	fixture^ = {}
}

_test_accept :: proc(t: ^testing.T, chat: ^Chat_Session, text: string) {
	if chat_session_accept_user(chat, text, session.now_ms()) != .Accepted {
		testing.fail_now(t, "the prompt was not admitted")
	}
}

_test_begin_request :: proc(t: ^testing.T, chat: ^Chat_Session) -> Chat_Effect {
	effect := chat_session_advance(chat)
	if effect.kind != .Start_Request { testing.fail_now(t, "expected a request to start") }
	chat_session_begin_operation(chat)
	return effect
}

_test_append :: proc(t: ^testing.T, chat: ^Chat_Session, entry: session.New_Entry) -> session.Seq {
	seq, err := session.entry_append(chat.store, chat.id, entry)
	if err != nil { testing.fail_now(t, "entry_append failed") }
	return seq
}

_test_entries :: proc(t: ^testing.T, chat: ^Chat_Session, allocator := context.allocator) -> []session.Entry {
	entries, err := session.entries_load(chat.store, chat.id, {}, allocator)
	if err != nil { testing.fail_now(t, "entries_load failed") }
	return entries
}

_test_context :: proc(t: ^testing.T, chat: ^Chat_Session, allocator := context.allocator) -> session.Context {
	ctx, err := session.context_load(chat.store, chat.id, allocator)
	if err != nil { testing.fail_now(t, "context_load failed") }
	return ctx
}

// _test_settle drives the turn to its terminal effect and records it, which is
// what the driver does when it sees a finished turn.
_test_settle :: proc(t: ^testing.T, chat: ^Chat_Session) -> Chat_Effect {
	finish := chat_session_advance(chat)
	if finish.kind != .Turn_Finished { testing.fail_now(t, "expected the turn to finish") }
	chat_persist_turn_end(chat, finish)
	return finish
}

// _test_stage_call stages a provider call for execution exactly as a completed
// response does: the call entry is recorded first, and the staged call points at
// it, so the dispatch and the result can name the same call.
_test_stage_call :: proc(t: ^testing.T, chat: ^Chat_Session, id, arguments: string) {
	seq := _test_append(
		t,
		chat,
		{
			turn_no = chat.turn_no,
			request_no = chat.active_request,
			created_at_ms = session.now_ms(),
			payload = session.Tool_Call_Entry{call_id = id, name = TOOL_SHELL_NAME, arguments = arguments},
		},
	)
	append(
		&chat.pending_calls,
		Chat_Tool_Call {
			id = chat_clone_string(id, chat.allocator),
			name = chat_clone_string(TOOL_SHELL_NAME, chat.allocator),
			arguments = chat_clone_string(arguments, chat.allocator),
			seq = seq,
		},
	)
	chat.state = .Executing_Tools
}
