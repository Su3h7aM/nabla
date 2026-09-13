#+test
package agent

import "core:strings"
import "core:testing"

import "nabla:agent/session"
import "nabla:ai"

compact_call_entry :: proc(seq: session.Seq, id: string) -> session.Entry {
	return session.Entry{seq = seq, kind = .Tool_Call, payload = session.Tool_Call_Entry{call_id = id, name = TOOL_SHELL_NAME, arguments = "{}"}}
}

compact_result_entry :: proc(seq: session.Seq) -> session.Entry {
	return session.Entry{seq = seq, kind = .Tool_Result, payload = session.Tool_Result_Entry{outcome = .Exited, content = "{}", origin = .Observed}}
}

compact_user_entry :: proc(seq: session.Seq, text: string) -> session.Entry {
	return session.Entry{seq = seq, kind = .User, payload = session.User_Entry{text = text, origin = .Prompt}}
}

@(test)
test_compact_seam_keeps_call_runs_together :: proc(t: ^testing.T) {
	entries := []session.Entry {
		compact_user_entry(1, "a"),
		compact_call_entry(2, "call_1"),
		compact_result_entry(3),
		compact_user_entry(4, "b"),
		session.Entry{seq = 5, kind = .Assistant, payload = session.Assistant_Entry{text = "done"}},
	}
	// The tail would split the call from its result, so the seam backs up over
	// the result and stops on the call: the pair stays together in the tail
	// instead of the whole window collapsing into the summary.
	testing.expect_value(t, chat_compact_seam(entries, 3), 1)
	testing.expect_value(t, chat_compact_seam(entries, 1), 4)
	plain := []session.Entry {
		compact_user_entry(1, "a"),
		session.Entry{seq = 2, kind = .Assistant, payload = session.Assistant_Entry{text = "b"}},
		compact_user_entry(3, "c"),
	}
	testing.expect_value(t, chat_compact_seam(plain, 1), 2)
}

@(test)
test_compact_seam_never_lands_inside_a_later_run :: proc(t: ^testing.T) {
	// Two runs in one window: backing only over results stops on call_2, which
	// keeps both runs whole. Backing over the call as well would strand result_1
	// in the tail without call_1.
	runs := []session.Entry{compact_call_entry(1, "call_1"), compact_result_entry(2), compact_call_entry(3, "call_2"), compact_result_entry(4)}
	testing.expect_value(t, chat_compact_seam(runs, 1), 2)
	testing.expect_value(t, chat_compact_seam(runs, 3), 0)

	// A seam whose predecessor is a call backs up too, so a multi-call run is
	// never cut between its calls.
	grouped := []session.Entry {
		compact_user_entry(1, "ask"),
		compact_call_entry(2, "call_1"),
		compact_call_entry(3, "call_2"),
		compact_result_entry(4),
		compact_result_entry(5),
	}
	testing.expect_value(t, chat_compact_seam(grouped, 3), 1)
}

// A checkpoint is the whole post-compaction context: the summary in front of the
// entries after the boundary. This is what the model sees, so it is pinned
// directly rather than through a summarization request.
@(test)
test_a_summary_opens_the_request_before_the_kept_tail :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat

	ctx := session.Context {
		summary = "earlier work",
		entries = []session.Entry {
			compact_user_entry(1, "kept question"),
			session.Entry{seq = 2, kind = .Assistant, payload = session.Assistant_Entry{text = "kept answer"}},
		},
	}
	prep: Chat_Request_Prep
	chat_build_request_into(chat, &prep, ctx.entries, ctx.summary, tool_loop_connection, false)
	defer chat_request_prep_destroy(&prep, chat.allocator)

	testing.expect_value(t, len(prep.request.Messages), 3)
	testing.expect(t, strings.has_prefix(prep.request.Messages[0].Content, "Summary of the conversation so far:"))
	testing.expect_value(t, prep.request.Messages[1].Content, "kept question")
	testing.expect_value(t, prep.request.Messages[2].Content, "kept answer")
}

@(test)
test_a_partial_answer_is_never_sent :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat

	// The builder refuses a partial answer even when one reaches it: a turn that
	// never finished must not be replayed as if it had.
	ctx := session.Context {
		entries = []session.Entry {
			compact_user_entry(1, "question"),
			session.Entry{seq = 2, kind = .Assistant, payload = session.Assistant_Entry{text = "half an ans", partial = true}},
		},
	}
	prep: Chat_Request_Prep
	chat_build_request_into(chat, &prep, ctx.entries, ctx.summary, tool_loop_connection, false)
	defer chat_request_prep_destroy(&prep, chat.allocator)
	testing.expect_value(t, len(prep.request.Messages), 1)
	testing.expect_value(t, prep.request.Messages[0].Content, "question")
}

@(test)
test_build_compact_request_has_no_tools :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true

	ctx := session.Context {
		entries = []session.Entry{compact_user_entry(1, "first")},
	}
	prep: Chat_Request_Prep
	chat_build_request_into(chat, &prep, ctx.entries, ctx.summary, tool_loop_connection, true)
	defer chat_request_prep_destroy(&prep, chat.allocator)
	testing.expect_value(t, len(prep.request.Tools), 0)
	testing.expect(t, prep.request.Max_Output_Tokens_Present)
	testing.expect_value(t, prep.request.Max_Output_Tokens, CHAT_COMPACT_MAX_OUTPUT)
	testing.expect(t, !prep.request.Reasoning_Effort_Present)
	// Instructions and the span being summarized: a compaction request carries no
	// agent prompt and no tools, because a summary must be text.
	if !testing.expect_value(t, len(prep.request.Messages), 2) { return }
	testing.expect_value(t, prep.request.Messages[0].Role, ai.Provider_Role.System)
	testing.expect_value(t, prep.request.Messages[0].Content, CHAT_COMPACT_INSTRUCTIONS)
	testing.expect_value(t, prep.request.Messages[1].Content, "first")
}

@(test)
test_compaction_failure_records_nothing_and_keeps_history :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.context_window = 500000
	// Enough history that compaction has something to summarize.
	_test_accept(t, chat, "first")
	for text in ([]string{"early", "middle", "late", "more", "most"}) {
		_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_000, payload = session.Assistant_Entry{text = text}})
	}
	chat.state = .Idle

	dead := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = "http://127.0.0.1:9/",
	}
	testing.expect(t, !chat_command_compact(chat, {}, dead, nil))

	// No checkpoint was written and every entry is still there.
	_, has_checkpoint, checkpoint_err := session.entry_latest_checkpoint(chat.store, chat.id)
	if checkpoint_err != nil { testing.fail_now(t, "entry_latest_checkpoint failed") }
	testing.expect(t, !has_checkpoint, "a failed compaction must not write a checkpoint")

	entries := _test_entries(t, chat)
	defer session.entries_destroy(entries, context.allocator)
	testing.expect_value(t, len(entries), 6)
	for entry in entries {
		testing.expect(t, entry.kind != .Checkpoint, "a failed compaction must not write a checkpoint entry")
	}
}

@(test)
test_a_compaction_request_is_recorded_and_closed :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.context_window = 500000
	_test_accept(t, chat, "first")
	// More entries than the kept tail, so compaction has a span to summarize.
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_000, payload = session.Assistant_Entry{text = text}})
	}
	chat.state = .Idle

	dead := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = "http://127.0.0.1:9/",
	}
	testing.expect(t, !chat_command_compact(chat, {}, dead, nil))

	// The attempt itself is a request, and it ends as failed rather than staying
	// open. That is what makes a session that died mid-compaction legible.
	request, request_err := session.request_load(chat.store, chat.id, 1)
	if request_err != nil { testing.fail_now(t, "the compaction request should exist") }
	defer session.request_destroy(&request)
	testing.expect_value(t, request.purpose, session.Request_Purpose.Compaction)
	testing.expect_value(t, request.outcome, session.Outcome.Failed)
	_, still_running := request.finished_at_ms.?
	testing.expect(t, still_running, "a finished request records when it finished")
}
