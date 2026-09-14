#+test
#+private file
package session

import "core:testing"

RECOVERED_RESULT :: `{"status":"unknown","error":"interrupted"}`
UNEXECUTED_RESULT :: `{"status":"not_executed","error":"never started"}`

@(test)
test_recovery_settles_an_interrupted_session :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session := _open_claimed_session(t, &store)
	defer session_destroy(&session)

	turn, turn_err := turn_begin(&store, session.id, "run it", .Prompt, 2_000)
	_expect_ok(t, turn_err)
	request, request_err := request_begin(
		&store,
		session.id,
		{turn_no = turn, purpose = .Response, provider = "p", model_requested = "m", api = "a", config_json = "{}", input_json = "{}"},
		2_100,
	)
	_expect_ok(t, request_err)
	call_seq, call_err := entry_append(
		&store,
		session.id,
		{turn_no = turn, request_no = request, created_at_ms = 2_200, payload = Tool_Call_Entry{call_id = "call_1", name = "shell", arguments = "{}"}},
	)
	_expect_ok(t, call_err)
	_, dispatch_err := entry_append(
		&store,
		session.id,
		{turn_no = turn, request_no = request, created_at_ms = 2_300, related_seq = call_seq, payload = Tool_Dispatch_Entry{tool = "shell"}},
	)
	_expect_ok(t, dispatch_err)

	recovery, recover_err := session_recover(&store, session.id, {at_ms = 2_400, recovered_content = RECOVERED_RESULT, unexecuted_content = UNEXECUTED_RESULT})
	_expect_ok(t, recover_err)
	testing.expect_value(t, recovery.recovered_calls, 1)
	testing.expect_value(t, recovery.interrupted_requests, 1)
	testing.expect_value(t, recovery.interrupted_turns, 1)

	entries, load_err := entries_load(&store, session.id, {})
	_expect_ok(t, load_err)
	defer entries_destroy(entries)
	if !testing.expect_value(t, len(entries), 4) { return }
	result, is_result := entries[3].payload.(Tool_Result_Entry)
	if !testing.expect(t, is_result, "the dispatch should have a recovered result") { return }
	testing.expect_value(t, result.outcome, Tool_Outcome.Unknown)
	testing.expect_value(t, result.origin, Tool_Result_Origin.Recovered)
	testing.expect_value(t, result.content, RECOVERED_RESULT)
	related, present := entries[3].related_seq.?
	if !testing.expect(t, present, "the recovered result should name its call") { return }
	testing.expect_value(t, related, call_seq)

	// Recovery is idempotent: the second pass has nothing left to settle.
	second, second_err := session_recover(&store, session.id, {at_ms = 2_500, recovered_content = RECOVERED_RESULT, unexecuted_content = UNEXECUTED_RESULT})
	_expect_ok(t, second_err)
	testing.expect_value(t, second.recovered_calls, 0)
	testing.expect_value(t, second.interrupted_requests, 0)
	testing.expect_value(t, second.interrupted_turns, 0)
}

// A call committed by a response and killed before its dispatch is the other
// half of an interruption: it never ran, and its result has to say so, or a
// later request would send the call to the model unanswered.
@(test)
test_recovery_closes_a_call_that_never_ran :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session := _open_claimed_session(t, &store)
	defer session_destroy(&session)

	turn, turn_err := turn_begin(&store, session.id, "run it", .Prompt, 2_000)
	_expect_ok(t, turn_err)
	request, request_err := request_begin(
		&store,
		session.id,
		{turn_no = turn, purpose = .Response, provider = "p", model_requested = "m", api = "a", config_json = "{}", input_json = "{}"},
		2_100,
	)
	_expect_ok(t, request_err)
	call_seq, call_err := entry_append(
		&store,
		session.id,
		{turn_no = turn, request_no = request, created_at_ms = 2_200, payload = Tool_Call_Entry{call_id = "call_1", name = "shell", arguments = "{}"}},
	)
	_expect_ok(t, call_err)

	recovery, recover_err := session_recover(&store, session.id, {at_ms = 2_400, recovered_content = RECOVERED_RESULT, unexecuted_content = UNEXECUTED_RESULT})
	_expect_ok(t, recover_err)
	testing.expect_value(t, recovery.recovered_calls, 0)
	testing.expect_value(t, recovery.unexecuted_calls, 1)
	testing.expect_value(t, recovery.interrupted_turns, 1)
	testing.expect_value(t, recovery.interrupted_requests, 1)

	entries, load_err := entries_load(&store, session.id, {})
	_expect_ok(t, load_err)
	defer entries_destroy(entries)
	if !testing.expect_value(t, len(entries), 3) { return }
	result, is_result := entries[2].payload.(Tool_Result_Entry)
	if !testing.expect(t, is_result, "the call should have a recovered result") { return }
	// The call never ran, so the outcome is known rather than unknown.
	testing.expect_value(t, result.outcome, Tool_Outcome.Not_Executed)
	testing.expect_value(t, result.origin, Tool_Result_Origin.Recovered)
	testing.expect_value(t, result.content, UNEXECUTED_RESULT)
	related, present := entries[2].related_seq.?
	if !testing.expect(t, present, "the recovered result should name its call") { return }
	testing.expect_value(t, related, call_seq)

	// A call that now has a result is settled, so a second pass leaves it alone.
	second, second_err := session_recover(&store, session.id, {at_ms = 2_500, recovered_content = RECOVERED_RESULT, unexecuted_content = UNEXECUTED_RESULT})
	_expect_ok(t, second_err)
	testing.expect_value(t, second.recovered_calls, 0)
	testing.expect_value(t, second.unexecuted_calls, 0)
}

// A recovered call and a recovered dispatch are told apart in one pass.
@(test)
test_recovery_separates_running_from_never_run :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session := _open_claimed_session(t, &store)
	defer session_destroy(&session)

	turn, turn_err := turn_begin(&store, session.id, "run both", .Prompt, 2_000)
	_expect_ok(t, turn_err)
	request, request_err := request_begin(
		&store,
		session.id,
		{turn_no = turn, purpose = .Response, provider = "p", model_requested = "m", api = "a", config_json = "{}", input_json = "{}"},
		2_100,
	)
	_expect_ok(t, request_err)
	started, started_err := entry_append(
		&store,
		session.id,
		{turn_no = turn, request_no = request, created_at_ms = 2_200, payload = Tool_Call_Entry{call_id = "call_1", name = "shell", arguments = "{}"}},
	)
	_expect_ok(t, started_err)
	never_ran, never_ran_err := entry_append(
		&store,
		session.id,
		{turn_no = turn, request_no = request, created_at_ms = 2_250, payload = Tool_Call_Entry{call_id = "call_2", name = "shell", arguments = "{}"}},
	)
	_expect_ok(t, never_ran_err)
	_, dispatch_err := entry_append(
		&store,
		session.id,
		{turn_no = turn, request_no = request, created_at_ms = 2_300, related_seq = started, payload = Tool_Dispatch_Entry{tool = "shell"}},
	)
	_expect_ok(t, dispatch_err)

	recovery, recover_err := session_recover(&store, session.id, {at_ms = 2_400, recovered_content = RECOVERED_RESULT, unexecuted_content = UNEXECUTED_RESULT})
	_expect_ok(t, recover_err)
	testing.expect_value(t, recovery.recovered_calls, 1)
	testing.expect_value(t, recovery.unexecuted_calls, 1)

	entries, load_err := entries_load(&store, session.id, {})
	_expect_ok(t, load_err)
	defer entries_destroy(entries)
	// Prompt, two calls, one dispatch, and a recovered result for each call.
	if !testing.expect_value(t, len(entries), 6) { return }

	outcomes := map[Seq]Tool_Outcome{}
	defer delete(outcomes)
	for entry in entries {
		result, is_result := entry.payload.(Tool_Result_Entry)
		if !is_result { continue }
		related, present := entry.related_seq.?
		if !present { continue }
		outcomes[related] = result.outcome
	}
	testing.expect_value(t, outcomes[started], Tool_Outcome.Unknown)
	testing.expect_value(t, outcomes[never_ran], Tool_Outcome.Not_Executed)
}

@(test)
test_recovery_leaves_resolved_calls_alone :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session := _open_claimed_session(t, &store)
	defer session_destroy(&session)
	turn, turn_err := turn_begin(&store, session.id, "run it", .Prompt, 2_000)
	_expect_ok(t, turn_err)
	request, request_err := request_begin(
		&store,
		session.id,
		{turn_no = turn, purpose = .Response, provider = "p", model_requested = "m", api = "a", config_json = "{}", input_json = "{}"},
		2_100,
	)
	_expect_ok(t, request_err)
	call_seq, call_err := entry_append(
		&store,
		session.id,
		{turn_no = turn, request_no = request, created_at_ms = 2_200, payload = Tool_Call_Entry{call_id = "call_1", name = "shell", arguments = "{}"}},
	)
	_expect_ok(t, call_err)
	_, dispatch_err := entry_append(
		&store,
		session.id,
		{turn_no = turn, request_no = request, created_at_ms = 2_300, related_seq = call_seq, payload = Tool_Dispatch_Entry{tool = "shell"}},
	)
	_expect_ok(t, dispatch_err)
	_, result_err := entry_append(
		&store,
		session.id,
		{
			turn_no = turn,
			request_no = request,
			created_at_ms = 2_350,
			related_seq = call_seq,
			payload = Tool_Result_Entry{outcome = .Success, content = "{}", origin = .Observed},
		},
	)
	_expect_ok(t, result_err)
	_expect_ok(t, request_finish(&store, session.id, request, {outcome = .Completed, at_ms = 2_400}))
	_expect_ok(t, turn_finish(&store, session.id, turn, .Completed, "", 2_450))

	recovery, recover_err := session_recover(&store, session.id, {at_ms = 2_500, recovered_content = RECOVERED_RESULT, unexecuted_content = UNEXECUTED_RESULT})
	_expect_ok(t, recover_err)
	testing.expect_value(t, recovery.recovered_calls, 0)
	testing.expect_value(t, recovery.unexecuted_calls, 0)
	testing.expect_value(t, recovery.interrupted_turns, 0)

	entries, load_err := entries_load(&store, session.id, {})
	_expect_ok(t, load_err)
	defer entries_destroy(entries)
	testing.expect_value(t, len(entries), 4)
}

@(test)
test_checkpoints_chain_and_move_the_context :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session := _open_claimed_session(t, &store)
	defer session_destroy(&session)

	// A first turn: prompt, answer, and a tool exchange.
	turn, turn_err := turn_begin(&store, session.id, "first task", .Prompt, 2_000)
	_expect_ok(t, turn_err)
	request, request_err := request_begin(
		&store,
		session.id,
		{turn_no = turn, purpose = .Response, provider = "p", model_requested = "m", api = "a", config_json = "{}", input_json = "{}"},
		2_100,
	)
	_expect_ok(t, request_err)
	_, answer_err := entry_append(
		&store,
		session.id,
		{turn_no = turn, request_no = request, created_at_ms = 2_200, payload = Assistant_Entry{text = "the answer"}},
	)
	_expect_ok(t, answer_err)
	call_seq, call_err := entry_append(
		&store,
		session.id,
		{turn_no = turn, request_no = request, created_at_ms = 2_250, payload = Tool_Call_Entry{call_id = "call_1", name = "shell", arguments = "{}"}},
	)
	_expect_ok(t, call_err)
	_, dispatch_err := entry_append(
		&store,
		session.id,
		{turn_no = turn, request_no = request, created_at_ms = 2_260, related_seq = call_seq, payload = Tool_Dispatch_Entry{tool = "shell"}},
	)
	_expect_ok(t, dispatch_err)
	_, result_err := entry_append(
		&store,
		session.id,
		{
			turn_no = turn,
			request_no = request,
			created_at_ms = 2_270,
			related_seq = call_seq,
			payload = Tool_Result_Entry{outcome = .Success, content = `{"status":"exited"}`, origin = .Observed},
		},
	)
	_expect_ok(t, result_err)
	last_seq, _ := entries_load(&store, session.id, {limit = ENTRIES_MAX_LIMIT})
	covered := last_seq[len(last_seq) - 1].seq
	entries_destroy(last_seq)
	_expect_ok(t, request_finish(&store, session.id, request, {outcome = .Completed, at_ms = 2_300}))
	_expect_ok(t, turn_finish(&store, session.id, turn, .Completed, "", 2_350))

	// A compaction request produced a summary standing in for everything so far.
	compaction, compaction_err := request_begin(
		&store,
		session.id,
		{purpose = .Compaction, provider = "p", model_requested = "m", api = "a", config_json = "{}", input_json = "{}"},
		2_400,
	)
	_expect_ok(t, compaction_err)
	checkpoint_seq, checkpoint_err := checkpoint_append(
		&store,
		session.id,
		{request_no = compaction, at_ms = 2_450, summary = "the first task is done", covered_seq = covered},
	)
	_expect_ok(t, checkpoint_err)
	_expect_ok(t, request_finish(&store, session.id, compaction, {outcome = .Completed, at_ms = 2_460}))

	// A second turn continues after the checkpoint.
	turn_two, turn_two_err := turn_begin(&store, session.id, "second task", .Prompt, 2_500)
	_expect_ok(t, turn_two_err)
	second_request, second_request_err := request_begin(
		&store,
		session.id,
		{turn_no = turn_two, purpose = .Response, provider = "p", model_requested = "m", api = "a", config_json = "{}", input_json = "{}"},
		2_550,
	)
	_expect_ok(t, second_request_err)
	_, second_answer_err := entry_append(
		&store,
		session.id,
		{turn_no = turn_two, request_no = second_request, created_at_ms = 2_600, payload = Assistant_Entry{text = "second answer"}},
	)
	_expect_ok(t, second_answer_err)
	_, partial_err := entry_append(
		&store,
		session.id,
		{turn_no = turn_two, request_no = second_request, created_at_ms = 2_610, payload = Assistant_Entry{text = "cut off", partial = true}},
	)
	_expect_ok(t, partial_err)

	latest, has_latest, latest_err := entry_latest_checkpoint(&store, session.id)
	_expect_ok(t, latest_err)
	if !testing.expect(t, has_latest, "the checkpoint should be found") { return }
	testing.expect_value(t, latest.seq, checkpoint_seq)
	payload, is_checkpoint := latest.payload.(Checkpoint_Entry)
	if !testing.expect(t, is_checkpoint, "the newest checkpoint should hold a summary") { return }
	testing.expect_value(t, payload.summary, "the first task is done")
	if _, present := payload.previous_seq.?; present {
		testing.fail_now(t, "the first checkpoint has no predecessor")
	}
	entry_destroy(&latest)

	ctx, ctx_err := context_load(&store, session.id)
	_expect_ok(t, ctx_err)
	defer context_destroy(&ctx)
	testing.expect_value(t, ctx.summary, "the first task is done")
	if summary_seq, present := ctx.summary_seq.?; present {
		testing.expect_value(t, summary_seq, checkpoint_seq)
	} else {
		testing.fail_now(t, "the context should name its summary entry")
	}
	// Only the second turn remains: the compaction bookkeeping, the dispatch,
	// and the partial answer are not part of a request.
	if !testing.expect_value(t, len(ctx.entries), 2) { return }
	testing.expect_value(t, ctx.entries[0].seq, Seq(7))
	testing.expect_value(t, ctx.entries[1].seq, Seq(8))

	// The summary replaced nothing: history still holds every entry.
	history, history_err := entries_load(&store, session.id, {})
	_expect_ok(t, history_err)
	defer entries_destroy(history)
	testing.expect_value(t, len(history), 9)
}

@(test)
test_a_checkpoint_must_cover_real_history :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session := _open_claimed_session(t, &store)
	defer session_destroy(&session)
	turn, turn_err := turn_begin(&store, session.id, "go", .Prompt, 2_000)
	_expect_ok(t, turn_err)
	_ = turn

	_, missing_err := checkpoint_append(&store, session.id, {at_ms = 2_100, summary = "so far", covered_seq = Seq(99)})
	_expect_error(t, missing_err, .Invalid_Argument)

	_, empty_err := checkpoint_append(&store, session.id, {at_ms = 2_100, summary = "", covered_seq = Seq(1)})
	_expect_error(t, empty_err, .Invalid_Argument)

	first, first_err := checkpoint_append(&store, session.id, {at_ms = 2_100, summary = "so far", covered_seq = Seq(1)})
	_expect_ok(t, first_err)
	second, second_err := checkpoint_append(&store, session.id, {at_ms = 2_200, summary = "still going", covered_seq = Seq(1)})
	_expect_ok(t, second_err)

	latest, has_latest, latest_err := entry_latest_checkpoint(&store, session.id)
	_expect_ok(t, latest_err)
	if !testing.expect(t, has_latest, "the second checkpoint should be found") { return }
	testing.expect_value(t, latest.seq, second)
	payload, is_checkpoint := latest.payload.(Checkpoint_Entry)
	if !testing.expect(t, is_checkpoint, "the newest checkpoint should hold a summary") { return }
	if previous, present := payload.previous_seq.?; present {
		testing.expect_value(t, previous, first)
	} else {
		testing.fail_now(t, "the second checkpoint should name the first")
	}
	entry_destroy(&latest)
}

@(test)
test_context_without_a_checkpoint_is_the_whole_conversation :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session := _open_claimed_session(t, &store)
	defer session_destroy(&session)
	turn, turn_err := turn_begin(&store, session.id, "hello", .Prompt, 2_000)
	_expect_ok(t, turn_err)
	_, assistant_err := entry_append(&store, session.id, {turn_no = turn, created_at_ms = 2_100, payload = Assistant_Entry{text = "hi"}})
	_expect_ok(t, assistant_err)

	ctx, ctx_err := context_load(&store, session.id)
	_expect_ok(t, ctx_err)
	defer context_destroy(&ctx)
	testing.expect_value(t, ctx.summary, "")
	if _, present := ctx.summary_seq.?; present {
		testing.fail_now(t, "a context without a checkpoint names no summary")
	}
	testing.expect_value(t, len(ctx.entries), 2)
}
