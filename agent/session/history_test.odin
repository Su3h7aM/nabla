#+test
#+private file
package session

import "core:fmt"
import "core:strings"
import "core:testing"

import "nabla:db"

_scalar_or_nil :: proc(t: ^testing.T, store: ^Store, column: string, id: Session_Id) -> Maybe(i64) {
	sql := fmt.tprintf("SELECT %s FROM requests WHERE session_id = '%s'", column, string(id))
	rows: db.Rows
	_expect_db_ok(t, db.query(&store.conn, &rows, sql))
	defer db.rows_close(&rows)
	values, has_row, next_err := db.rows_next(&rows)
	_expect_db_ok(t, next_err)
	if !has_row { testing.fail_now(t, "expected a row") }
	if values[0] == nil { return nil }
	number, convert_err := db.as_i64(values[0])
	_expect_db_ok(t, convert_err)
	return number
}

@(test)
test_turn_opens_with_its_prompt_and_closes_once :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session := _open_claimed_session(t, &store)
	defer session_destroy(&session)

	turn, turn_err := turn_begin(&store, session.id, "list the files", .Prompt, 2_000)
	_expect_ok(t, turn_err)
	testing.expect_value(t, turn, Turn_No(1))

	entries, load_err := entries_load(&store, session.id, {})
	_expect_ok(t, load_err)
	defer entries_destroy(entries)
	if !testing.expect_value(t, len(entries), 1) { return }
	testing.expect_value(t, entries[0].seq, Seq(1))
	testing.expect_value(t, entries[0].kind, Entry_Kind.User)
	if entry_turn, present := entries[0].turn_no.?; present {
		testing.expect_value(t, entry_turn, turn)
	} else {
		testing.fail_now(t, "the prompt should belong to its turn")
	}
	user, is_user := entries[0].payload.(User_Entry)
	if !testing.expect(t, is_user, "the first entry should be user text") { return }
	testing.expect_value(t, user.text, "list the files")
	testing.expect_value(t, user.origin, User_Origin.Prompt)

	_expect_ok(t, turn_finish(&store, session.id, turn, .Completed, "", 3_000))
	_expect_error(t, turn_finish(&store, session.id, turn, .Completed, "", 4_000), .Not_Found)
	_expect_error(t, turn_finish(&store, session.id, Turn_No(7), .Completed, "", 4_000), .Not_Found)
}

@(test)
test_entries_are_sequenced_and_page :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session := _open_claimed_session(t, &store)
	defer session_destroy(&session)

	turn, turn_err := turn_begin(&store, session.id, "first", .Prompt, 2_000)
	_expect_ok(t, turn_err)

	request, request_err := request_begin(
		&store,
		session.id,
		{turn_no = turn, purpose = .Response, provider = "p", model_requested = "m", api = "a", config_json = "{}", input_json = "{}"},
		2_100,
	)
	_expect_ok(t, request_err)

	seqs, append_err := entries_append(
		&store,
		session.id,
		{
			{turn_no = turn, request_no = request, created_at_ms = 2_200, payload = Assistant_Entry{text = "working"}},
			{turn_no = turn, request_no = request, created_at_ms = 2_200, payload = Assistant_Entry{text = "done"}},
			{turn_no = turn, request_no = request, created_at_ms = 2_200, payload = Assistant_Entry{text = "and done"}},
		},
	)
	_expect_ok(t, append_err)
	defer delete(seqs)
	if !testing.expect_value(t, len(seqs), 3) { return }
	testing.expect_value(t, seqs[0], Seq(2))
	testing.expect_value(t, seqs[2], Seq(4))

	// The bounds are exclusive below and inclusive above.
	middle, middle_err := entries_load(&store, session.id, {after = Seq(1), through = Seq(3)})
	_expect_ok(t, middle_err)
	defer entries_destroy(middle)
	if !testing.expect_value(t, len(middle), 2) { return }
	testing.expect_value(t, middle[0].seq, Seq(2))
	testing.expect_value(t, middle[1].seq, Seq(3))

	first_two, first_err := entries_load(&store, session.id, {limit = 2})
	_expect_ok(t, first_err)
	defer entries_destroy(first_two)
	testing.expect_value(t, len(first_two), 2)

	// Reading does not need the claim.
	_expect_ok(t, session_release(&store))
	unclaimed, unclaimed_err := entries_load(&store, session.id, {})
	_expect_ok(t, unclaimed_err)
	testing.expect_value(t, len(unclaimed), 4)
	entries_destroy(unclaimed)
	_expect_ok(t, session_claim(&store, session.id))
}

@(test)
test_tool_call_dispatch_and_result_are_linked :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session := _open_claimed_session(t, &store)
	defer session_destroy(&session)

	turn, turn_err := turn_begin(&store, session.id, "list the files", .Prompt, 2_000)
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
		{
			turn_no = turn,
			request_no = request,
			created_at_ms = 2_200,
			payload = Tool_Call_Entry{call_id = "call_1", name = "shell", arguments = `{"command":"ls"}`},
		},
	)
	_expect_ok(t, call_err)
	testing.expect_value(t, call_seq, Seq(2))

	dispatch_seq, dispatch_err := entry_append(
		&store,
		session.id,
		{
			turn_no = turn,
			request_no = request,
			created_at_ms = 2_300,
			related_seq = call_seq,
			payload = Tool_Dispatch_Entry{tool = "shell", arguments = `{"command":"ls","timeout_ms":30000}`},
		},
	)
	_expect_ok(t, dispatch_err)
	testing.expect_value(t, dispatch_seq, Seq(3))

	result_seq, result_err := entry_append(
		&store,
		session.id,
		{
			turn_no = turn,
			request_no = request,
			created_at_ms = 2_400,
			related_seq = call_seq,
			payload = Tool_Result_Entry{outcome = .Exited, exit_code = 0, content = `{"status":"exited","exit_code":0}`, origin = .Observed},
		},
	)
	_expect_ok(t, result_err)
	testing.expect_value(t, result_seq, Seq(4))

	entries, load_err := entries_load(&store, session.id, {after = Seq(1)})
	_expect_ok(t, load_err)
	defer entries_destroy(entries)
	if !testing.expect_value(t, len(entries), 3) { return }
	testing.expect_value(t, entries[0].kind, Entry_Kind.Tool_Call)
	testing.expect_value(t, entries[1].kind, Entry_Kind.Tool_Dispatch)
	testing.expect_value(t, entries[2].kind, Entry_Kind.Tool_Result)
	for entry in entries {
		related, present := entry.related_seq.?
		if entry.kind == .Tool_Call {
			if present { testing.fail_now(t, "a call names no related entry") }
			continue
		}
		if !present { testing.fail_now(t, "a dispatch or result must name its call") }
		testing.expect_value(t, related, call_seq)
	}
	result, is_result := entries[2].payload.(Tool_Result_Entry)
	if !testing.expect(t, is_result, "the last entry should be a result") { return }
	testing.expect_value(t, result.outcome, Tool_Outcome.Exited)
	if code, present := result.exit_code.?; present {
		testing.expect_value(t, code, i32(0))
	} else {
		testing.fail_now(t, "an exit code of zero is still a reported code")
	}
}

@(test)
test_a_tool_link_must_name_an_existing_call :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session := _open_claimed_session(t, &store)
	defer session_destroy(&session)
	turn, turn_err := turn_begin(&store, session.id, "go", .Prompt, 2_000)
	_expect_ok(t, turn_err)
	request, request_err := request_begin(
		&store,
		session.id,
		{turn_no = turn, purpose = .Response, provider = "p", model_requested = "m", api = "a", config_json = "{}", input_json = "{}"},
		2_100,
	)
	_expect_ok(t, request_err)

	// Nothing to link to.
	_, missing_err := entry_append(
		&store,
		session.id,
		{turn_no = turn, request_no = request, created_at_ms = 2_200, payload = Tool_Dispatch_Entry{tool = "shell"}},
	)
	_expect_error(t, missing_err, .Invalid_Argument)

	// Linked to an entry that is not a call.
	_, not_a_call_err := entry_append(
		&store,
		session.id,
		{turn_no = turn, request_no = request, created_at_ms = 2_200, related_seq = Seq(1), payload = Tool_Dispatch_Entry{tool = "shell"}},
	)
	_expect_error(t, not_a_call_err, .Invalid_Argument)

	// Linked to an entry that does not exist.
	_, no_such_err := entry_append(
		&store,
		session.id,
		{
			turn_no = turn,
			request_no = request,
			created_at_ms = 2_200,
			related_seq = Seq(99),
			payload = Tool_Result_Entry{outcome = .Exited, content = "x", origin = .Observed},
		},
	)
	_expect_error(t, no_such_err, .Invalid_Argument)

	// An entry that is not a dispatch or result may not name one at all.
	_, stray_err := entry_append(
		&store,
		session.id,
		{turn_no = turn, request_no = request, created_at_ms = 2_200, related_seq = Seq(1), payload = Assistant_Entry{text = "hello"}},
	)
	_expect_error(t, stray_err, .Invalid_Argument)
}

@(test)
test_a_call_has_at_most_one_dispatch_and_one_result :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session := _open_claimed_session(t, &store)
	defer session_destroy(&session)
	turn, turn_err := turn_begin(&store, session.id, "go", .Prompt, 2_000)
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

	dispatch := New_Entry {
		turn_no = turn,
		request_no = request,
		created_at_ms = 2_300,
		related_seq = call_seq,
		payload = Tool_Dispatch_Entry{tool = "shell"},
	}
	_, first_dispatch_err := entry_append(&store, session.id, dispatch)
	_expect_ok(t, first_dispatch_err)
	_, second_dispatch_err := entry_append(&store, session.id, dispatch)
	_expect_error(t, second_dispatch_err, .Constraint)

	result := New_Entry {
		turn_no = turn,
		request_no = request,
		created_at_ms = 2_400,
		related_seq = call_seq,
		payload = Tool_Result_Entry{outcome = .Exited, content = "{}", origin = .Observed},
	}
	_, first_result_err := entry_append(&store, session.id, result)
	_expect_ok(t, first_result_err)
	_, second_result_err := entry_append(&store, session.id, result)
	_expect_error(t, second_result_err, .Constraint)
}

@(test)
test_request_records_usage_and_finishes_once :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session := _open_claimed_session(t, &store)
	defer session_destroy(&session)
	turn, turn_err := turn_begin(&store, session.id, "go", .Prompt, 2_000)
	_expect_ok(t, turn_err)

	request, request_err := request_begin(
		&store,
		session.id,
		{
			turn_no = turn,
			purpose = .Response,
			provider = "openai",
			model_requested = "gpt-4",
			api = "openai_chat_completions",
			config_json = `{"max_output_tokens":100}`,
			input_json = `{"messages":[]}`,
		},
		2_100,
	)
	_expect_ok(t, request_err)

	// One reported number, one reported zero, and two the provider never sent.
	finish := Request_Finish {
		outcome = .Completed,
		model_resolved = "gpt-4-0613",
		response_json = `{"reason":"stop"}`,
		usage = Usage{input = 10, output = 0},
		at_ms = 2_900,
	}
	_expect_ok(t, request_finish(&store, session.id, request, finish))
	_expect_error(t, request_finish(&store, session.id, request, finish), .Not_Found)

	id := string(session.id)
	input_tokens := _scalar_or_nil(t, &store, "input_tokens", session.id)
	output_tokens := _scalar_or_nil(t, &store, "output_tokens", session.id)
	cache_tokens := _scalar_or_nil(t, &store, "cache_read_tokens", session.id)
	if value, present := input_tokens.?; present {
		testing.expect_value(t, value, i64(10))
	} else {
		testing.fail_now(t, "reported input tokens should be stored")
	}
	if value, present := output_tokens.?; present {
		testing.expect_value(t, value, i64(0))
	} else {
		testing.fail_now(t, "a reported zero is a value, not an absence")
	}
	if _, present := cache_tokens.?; present {
		testing.fail_now(t, "unreported cache tokens should stay unknown")
	}
}

@(test)
test_cache_totals_sum_finished_requests_and_skip_running :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session := _open_claimed_session(t, &store)
	defer session_destroy(&session)
	turn, turn_err := turn_begin(&store, session.id, "go", .Prompt, 2_000)
	_expect_ok(t, turn_err)

	first, first_err := request_begin(
		&store,
		session.id,
		{turn_no = turn, purpose = .Response, provider = "p", model_requested = "m", api = "a", config_json = "{}", input_json = "{}"},
		2_100,
	)
	_expect_ok(t, first_err)
	_expect_ok(
		t,
		request_finish(&store, session.id, first, {outcome = .Completed, usage = Usage{input = 100, output = 10, cache_read = 90}, at_ms = 2_200}),
	)

	second, second_err := request_begin(
		&store,
		session.id,
		{turn_no = turn, purpose = .Compaction, provider = "p", model_requested = "m", api = "a", config_json = "{}", input_json = "{}"},
		2_300,
	)
	_expect_ok(t, second_err)
	_expect_ok(
		t,
		request_finish(&store, session.id, second, {outcome = .Failed, usage = Usage{input = 50, output = 5, cache_write = 50}, at_ms = 2_400}),
	)

	// A running request must not move a reported total.
	_, running_err := request_begin(
		&store,
		session.id,
		{turn_no = turn, purpose = .Response, provider = "p", model_requested = "m", api = "a", config_json = "{}", input_json = "{}"},
		2_500,
	)
	_expect_ok(t, running_err)

	totals, totals_err := cache_totals(&store, session.id)
	_expect_ok(t, totals_err)
	testing.expect_value(t, totals.input, i64(150))
	testing.expect_value(t, totals.cache_read, i64(90))
	testing.expect_value(t, totals.cache_write, i64(50))
	testing.expect_value(t, totals.output, i64(15))
	testing.expect_value(t, totals.input_requests, 2)
	testing.expect_value(t, totals.cache_read_requests, 1)
	testing.expect_value(t, totals.cache_write_requests, 1)
	testing.expect_value(t, totals.output_requests, 2)

	rate, measured := cache_hit_rate(totals)
	testing.expect(t, measured, "two finished requests with input and one cache read are measurable")
	testing.expect(t, rate > 0.59 && rate < 0.61, "90 of 150 input tokens is a 60% hit rate")

	// Nothing reported: no input denominator, no hit rate to show.
	empty := Cache_Totals{}
	_, empty_measured := cache_hit_rate(empty)
	testing.expect(t, !empty_measured, "unknown usage must stay unknown, not zero")
}

@(test)
test_history_survives_a_reopen :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)

	session, create_err := session_create(&store, {workspace = "/tmp/project"}, 1_000)
	_expect_ok(t, create_err)
	id := Session_Id(strings.clone(string(session.id), context.allocator))
	session_destroy(&session)
	_expect_ok(t, session_claim(&store, id))

	turn, turn_err := turn_begin(&store, id, "remember this", .Prompt, 2_000)
	_expect_ok(t, turn_err)
	_, assist_err := entry_append(&store, id, {turn_no = turn, created_at_ms = 2_500, payload = Assistant_Entry{text = "remembered"}})
	_expect_ok(t, assist_err)
	_expect_ok(t, turn_finish(&store, id, turn, .Completed, "", 2_600))
	store_close(&store)

	reopened: Store
	_expect_ok(t, store_open(&reopened, directory))
	defer _close_store(&reopened, directory)

	entries, load_err := entries_load(&reopened, id, {})
	_expect_ok(t, load_err)
	defer entries_destroy(entries)
	if !testing.expect_value(t, len(entries), 2) { return }
	testing.expect_value(t, entries[0].kind, Entry_Kind.User)
	testing.expect_value(t, entries[1].kind, Entry_Kind.Assistant)
	assistant, is_assistant := entries[1].payload.(Assistant_Entry)
	if !testing.expect(t, is_assistant, "the second entry should be assistant text") { return }
	testing.expect_value(t, assistant.text, "remembered")
	testing.expect(t, !assistant.partial, "a completed turn is not partial")

	delete(string(id), context.allocator)
}

@(test)
test_entry_payloads_round_trip :: proc(t: ^testing.T) {
	payloads := [?]Entry_Payload {
		User_Entry{text = "hello", origin = .Steering},
		Assistant_Entry{text = "hi", partial = true},
		Reasoning_Entry{id = "reason_1", encrypted = "opaque"},
		Tool_Call_Entry{call_id = "call_1", item_id = "item_1", name = "shell", arguments = `{"command":"ls"}`},
		Tool_Dispatch_Entry{tool = "shell", arguments = `{"command":"ls","timeout_ms":30000}`},
		Tool_Result_Entry{outcome = .Exited, exit_code = 2, error = "", content = `{"status":"exited"}`, origin = .Observed},
		Tool_Result_Entry{outcome = .Unknown, content = `{"status":"unknown"}`, origin = .Recovered},
		Checkpoint_Entry{summary = "so far", covered_seq = Seq(4), previous_seq = Seq(2)},
	}

	for payload in payloads {
		kind := entry_kind_of(payload)
		encoded, encode_err := entry_payload_encode(payload, context.temp_allocator)
		_expect_ok(t, encode_err)
		decoded, decode_err := entry_payload_decode(kind, string(encoded), context.allocator)
		_expect_ok(t, decode_err)
		testing.expect_value(t, entry_kind_of(decoded), kind)
		again, again_err := entry_payload_encode(decoded, context.temp_allocator)
		_expect_ok(t, again_err)
		testing.expect_value(t, string(again), string(encoded))
		entry_payload_destroy(&decoded, context.allocator)
	}
}

@(test)
test_an_incomplete_payload_is_refused :: proc(t: ^testing.T) {
	incomplete := [?]struct {
		kind: Entry_Kind,
		json: string,
	} {
		{.User, `{"text":"","origin":"prompt"}`},
		{.User, `{"text":"hello","origin":"telepathy"}`},
		{.Assistant, `not json at all`},
		{.Reasoning, `{"id":""}`},
		{.Tool_Call, `{"call_id":"","name":"shell"}`},
		{.Tool_Result, `{"outcome":"exploded","content":"x","origin":"executed"}`},
		{.Checkpoint, `{"summary":""}`},
	}
	for item in incomplete {
		_, err := entry_payload_decode(item.kind, item.json, context.temp_allocator)
		_expect_error(t, err, .Corrupt)
	}
}

@(test)
test_writing_history_requires_the_claim :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session, create_err := session_create(&store, {workspace = "/tmp/project"}, 1_000)
	_expect_ok(t, create_err)
	defer session_destroy(&session)

	_, turn_err := turn_begin(&store, session.id, "go", .Prompt, 2_000)
	_expect_error(t, turn_err, .Invalid_State)
	_, append_err := entry_append(&store, session.id, {created_at_ms = 2_000, payload = Assistant_Entry{text = "nope"}})
	_expect_error(t, append_err, .Invalid_State)
	_, request_err := request_begin(
		&store,
		session.id,
		{purpose = .Response, provider = "p", model_requested = "m", api = "a", config_json = "{}", input_json = "{}"},
		2_000,
	)
	_expect_error(t, request_err, .Invalid_State)
}

@(test)
test_an_entry_must_name_a_real_turn_and_request :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session := _open_claimed_session(t, &store)
	defer session_destroy(&session)
	turn, turn_err := turn_begin(&store, session.id, "go", .Prompt, 2_000)
	_expect_ok(t, turn_err)

	// The foreign key refuses an entry whose turn does not exist.
	_, turn_err_missing := entry_append(&store, session.id, {turn_no = Turn_No(99), created_at_ms = 2_000, payload = Assistant_Entry{text = "x"}})
	_expect_error(t, turn_err_missing, .Constraint)

	// And one whose request does not exist.
	_, request_err_missing := entry_append(
		&store,
		session.id,
		{turn_no = turn, request_no = Request_No(99), created_at_ms = 2_000, payload = Assistant_Entry{text = "x"}},
	)
	_expect_error(t, request_err_missing, .Constraint)
}
