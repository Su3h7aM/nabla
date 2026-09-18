#+test
package agent

import "core:testing"

import "nabla:agent/session"
import "nabla:ai"

compact_call_entry :: proc(seq: session.Seq, id: string) -> session.Entry {
	return session.Entry{seq = seq, kind = .Tool_Call, payload = session.Tool_Call_Entry{call_id = id, name = TOOL_SHELL_NAME, arguments = "{}"}}
}

compact_result_entry :: proc(seq: session.Seq) -> session.Entry {
	return session.Entry{seq = seq, kind = .Tool_Result, payload = session.Tool_Result_Entry{outcome = .Success, content = "{}", origin = .Observed}}
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

// On the Responses API the endpoint's own output is replayed verbatim, so a
// request's calls live inside its `.Response` entry. A seam between that record
// and the entries committed with the same request would send the calls without
// their results even though no adjacent pair looks like a call and its result.
@(test)
test_compact_seam_keeps_one_responses_request_together :: proc(t: ^testing.T) {
	request := session.Request_No(1)
	record := []session.Entry {
		compact_user_entry(1, "ask"),
		{
			seq = 2,
			request_no = request,
			kind = .Response,
			payload = session.Response_Entry{output = `[{"type":"function_call","call_id":"call_1","name":"shell","arguments":"{}"}]`},
		},
		{seq = 3, request_no = request, kind = .Tool_Call, payload = session.Tool_Call_Entry{call_id = "call_1", name = TOOL_SHELL_NAME, arguments = "{}"}},
		{
			seq = 4,
			request_no = request,
			kind = .Tool_Result,
			related_seq = 3,
			payload = session.Tool_Result_Entry{outcome = .Success, content = "{}", origin = .Observed},
		},
		compact_user_entry(5, "next"),
	}
	// The seam starts on the result and must back over the call and the verbatim
	// record that carries it, stopping at the user prompt before the request.
	testing.expect_value(t, chat_compact_seam(record, 2), 1)

	// Assistant text between the record and its calls does not break the run.
	with_text := []session.Entry {
		compact_user_entry(1, "ask"),
		{seq = 2, request_no = request, kind = .Response, payload = session.Response_Entry{output = `[]`}},
		{seq = 3, request_no = request, kind = .Assistant, payload = session.Assistant_Entry{text = "working"}},
		{seq = 4, request_no = request, kind = .Tool_Call, payload = session.Tool_Call_Entry{call_id = "call_1", name = TOOL_SHELL_NAME, arguments = "{}"}},
		{
			seq = 5,
			request_no = request,
			kind = .Tool_Result,
			related_seq = 4,
			payload = session.Tool_Result_Entry{outcome = .Success, content = "{}", origin = .Observed},
		},
	}
	testing.expect_value(t, chat_compact_seam(with_text, 2), 1)
}

// A checkpoint is the whole post-compaction context: the checkpoint message in
// front of the entries after the boundary. This is what the model sees, so it is
// pinned directly rather than through a summarization request.
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
	chat_build_request_into(chat, &prep, ctx.entries, ctx.dispatches, ctx.summary, tool_loop_connection, "")
	defer chat_request_prep_destroy(&prep, chat.allocator)

	testing.expect_value(t, len(prep.request.Messages), 3)
	testing.expect_value(t, prep.request.Messages[0].Role, ai.Provider_Role.User)
	testing.expect_value(t, prep.request.Messages[0].Content, "earlier work")
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
	chat_build_request_into(chat, &prep, ctx.entries, ctx.dispatches, ctx.summary, tool_loop_connection, "")
	defer chat_request_prep_destroy(&prep, chat.allocator)
	testing.expect_value(t, len(prep.request.Messages), 1)
	testing.expect_value(t, prep.request.Messages[0].Content, "question")
}

// A compaction request reads the conversation's own prefix, so the summarizer's
// input is a cache read rather than a cache write and the summary is written by
// the same model that will read it back. Only the directive at the end is new.
@(test)
test_a_compaction_request_shares_the_conversation_prefix :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW)

	ctx := session.Context {
		entries = []session.Entry{compact_user_entry(1, "first")},
	}
	prep: Chat_Request_Prep
	chat_build_request_into(chat, &prep, ctx.entries, ctx.dispatches, ctx.summary, tool_loop_connection, CHAT_COMPACT_DIRECTIVE)
	defer chat_request_prep_destroy(&prep, chat.allocator)

	testing.expect(t, prep.request.Instructions_Present)
	testing.expect_value(t, prep.request.Instructions, AGENT_SYSTEM_PROMPT)
	testing.expect(t, len(prep.request.Tools) > 0, "a compaction request keeps the conversation's tools")
	testing.expect_value(t, prep.request.Prompt_Cache_Key, string(chat.id))
	testing.expect(t, prep.request.Max_Output_Tokens_Present)
	// A summarization request follows the same rule as any other: it asks for the room the
	// window has left. Its input is the prefix, so the bound is what the prefix leaves.
	expected, _ := chat_request_output_bound(chat.capacity, prep.estimate)
	testing.expect_value(t, prep.request.Max_Output_Tokens, expected)
	// The directive is the last message, after the prefix it asks about.
	if !testing.expect_value(t, len(prep.request.Messages), 2) { return }
	testing.expect_value(t, prep.request.Messages[0].Content, "first")
	testing.expect_value(t, prep.request.Messages[1].Content, CHAT_COMPACT_DIRECTIVE)
}

// A provider that rejected the context is the strongest reason to compact: it promotes a
// summary that is already running to install at the first safe boundary, and it schedules
// one when nothing is running. Neither bypasses what a caller asked for.
@(test)
test_a_provider_overflow_promotes_a_running_summary :: proc(t: ^testing.T) {
	testing.expect(t, compact_trigger_explicit(.Provider_Overflow), "a refused payload installs as soon as it can")

	running := Compact_Control {
		state   = .Running,
		trigger = .Pressure,
	}
	testing.expect_value(t, compact_request_intent(&running, .Provider_Overflow, nil), Compact_Request_Result.Already_Scheduled)
	testing.expect_value(t, running.trigger, Compact_Trigger.Provider_Overflow)

	idle: Compact_Control
	testing.expect_value(t, compact_request_intent(&idle, .Provider_Overflow, nil), Compact_Request_Result.Scheduled)
	testing.expect_value(t, idle.pending, Compact_Trigger.Provider_Overflow)
}
