package session

import "base:runtime"
import "core:mem"

import "nabla:db"

// --- recovery ---------------------------------------------------------------

// Recovery reports what an interrupted session had to settle. The two call
// counts are separate because they say different things: a dispatched call may
// have taken effect, while a call that was never dispatched cannot have.
Recovery :: struct {
	interrupted_turns:    int,
	interrupted_requests: int,
	recovered_calls:      int, // dispatched with no result; the outcome is unknown
	unexecuted_calls:     int, // never dispatched; the call did not run
}

// Recover_Options carries what recovery needs besides the session itself. Both
// results are model-visible text the harness supplies, because it owns the shape
// of a tool result: recovered_content answers a call that was dispatched and
// never came back, and unexecuted_content answers a call that was never
// dispatched.
Recover_Options :: struct {
	at_ms:              i64,
	recovered_content:  string,
	unexecuted_content: string,
}

// session_recover settles a session that was interrupted. Every tool call with
// no result is closed: one that was dispatched may have run, so its result says
// the outcome is unknown, and one that was never dispatched cannot have run, so
// its result says it did not execute. Then any request and turn still marked
// running is closed as interrupted.
//
// A result is what makes the record coherent again: a call left without one is
// a call a later request would send to the model unanswered.
//
// Recovery records what the harness knows. It never reruns a tool and never
// resumes a request, because a dispatch may have taken effect before the
// process died and that effect is the user's to inspect.
session_recover :: proc(store: ^Store, id: Session_Id, options: Recover_Options, allocator := context.allocator) -> (recovery: Recovery, err: Error) {
	require_claim(store, id) or_return
	if options.at_ms <= 0 { return {}, error_make(.Invalid_Argument, "recovery needs a timestamp") }
	if options.recovered_content == "" { return {}, error_make(.Invalid_Argument, "recovery needs the result text to record") }
	if options.unexecuted_content == "" { return {}, error_make(.Invalid_Argument, "recovery needs the unexecuted result text to record") }

	if err := db.exec(&store.conn, "BEGIN IMMEDIATE"); err != nil {
		return {}, storage_error("begin recovery", err)
	}
	committed := false
	defer if !committed { abandon_transaction(store) }

	unsettled, unsettled_err := unsettled_calls(store, id, allocator)
	if unsettled_err != nil { return {}, unsettled_err }
	defer delete(unsettled)

	if len(unsettled) > 0 {
		base, base_err := scalar_i64(store, ENTRY_NEXT_SEQ, {db.Value(string(id))})
		if base_err != nil { return {}, base_err }
		for call, i in unsettled {
			// A recovered result is the harness saying what it knows, so there is
			// no error text: an error would claim a cause it does not have.
			payload := Tool_Result_Entry {
				outcome = .Unknown if call.dispatched else .Not_Executed,
				content = options.recovered_content if call.dispatched else options.unexecuted_content,
				origin  = .Recovered,
			}
			entry := New_Entry {
				turn_no       = call.turn_no,
				request_no    = call.request_no,
				created_at_ms = options.at_ms,
				related_seq   = call.call_seq,
				payload       = payload,
			}
			seq := Seq(base + i64(i))
			if validate_err := validate_new_entry(store, id, seq, entry); validate_err != nil { return {}, validate_err }
			if insert_err := insert_entry(store, id, seq, entry); insert_err != nil { return {}, insert_err }
			if call.dispatched { recovery.recovered_calls += 1 } else { recovery.unexecuted_calls += 1 }
		}
	}

	finish_args := [?]db.Value{db.Value(options.at_ms), db.Value(string(id))}
	requests, requests_err := exec_affected(store, REQUESTS_INTERRUPT, finish_args[:])
	if requests_err != nil { return {}, requests_err }
	turns, turns_err := exec_affected(store, TURNS_INTERRUPT, finish_args[:])
	if turns_err != nil { return {}, turns_err }
	recovery.interrupted_requests = int(requests)
	recovery.interrupted_turns = int(turns)

	if touch_err := touch_session(store, id, options.at_ms); touch_err != nil { return {}, touch_err }
	if err := db.commit(&store.conn); err != nil {
		return {}, storage_error("commit recovery", err)
	}
	committed = true
	return recovery, nil
}

@(private)
Unsettled_Call :: struct {
	call_seq:   Seq,
	turn_no:    Maybe(Turn_No),
	request_no: Maybe(Request_No),
	dispatched: bool,
}

// unsettled_calls finds every tool call that never produced a result, whether or
// not the harness got as far as committing a dispatch for it. It runs inside the
// recovery transaction, so the set cannot change under it.
@(private)
unsettled_calls :: proc(store: ^Store, id: Session_Id, allocator: mem.Allocator) -> ([]Unsettled_Call, Error) {
	rows: db.Rows
	if err := db.query(&store.conn, &rows, UNSETTLED_CALLS, {db.Value(string(id))}); err != nil {
		return nil, storage_error("find unsettled tool calls", err)
	}
	defer db.rows_close(&rows)

	calls := make([dynamic]Unsettled_Call, 0, 4, allocator)
	complete := false
	defer if !complete { delete(calls) }

	for {
		values, has_row, next_err := db.rows_next(&rows)
		if next_err != nil { return nil, storage_error("find unsettled tool calls", next_err) }
		if !has_row { break }
		call_seq, seq_err := db.as_i64(values[0])
		if seq_err != nil { return nil, corrupt_error("read an unsettled call", seq_err) }
		turn_no, turn_err := read_optional_i64(values[1])
		if turn_err != nil { return nil, corrupt_error("read an unsettled call", turn_err) }
		request_no, request_err := read_optional_i64(values[2])
		if request_err != nil { return nil, corrupt_error("read an unsettled call", request_err) }
		dispatched, dispatched_err := db.as_i64(values[3])
		if dispatched_err != nil { return nil, corrupt_error("read an unsettled call", dispatched_err) }

		call := Unsettled_Call {
			call_seq   = Seq(call_seq),
			dispatched = dispatched != 0,
		}
		if value, present := turn_no.?; present { call.turn_no = Turn_No(value) }
		if value, present := request_no.?; present { call.request_no = Request_No(value) }
		append(&calls, call)
	}
	complete = true
	return calls[:], nil
}

// --- checkpoints ------------------------------------------------------------

// New_Checkpoint is a compaction summary about to be stored. summary is the text
// that re-enters the conversation, wrapper included, so the bytes a resumed
// session projects are the bytes that were stored. covered_seq is the last entry
// the summary stands in for; it must already exist.
New_Checkpoint :: struct {
	turn_no:     Maybe(Turn_No),
	at_ms:       i64,
	summary:     string,
	covered_seq: Seq,
}

// checkpoint_install records a compaction summary at an exact context boundary.
// History is never rewritten: the summary is one more entry, and everything
// before covered_seq stays where it is but leaves the active context.
//
// expected_base names the checkpoint this one replaces, nil when the session had
// none, and compaction_request names the request that produced the summary. The
// checks and the append are one transaction, so a summary computed against a
// superseded base, or from a request that never completed, cannot move the
// context. That is what makes an asynchronous compaction safe to install late.
checkpoint_install :: proc(
	store: ^Store,
	id: Session_Id,
	checkpoint: New_Checkpoint,
	expected_base: Maybe(Seq),
	compaction_request: Request_No,
) -> (
	seq: Seq,
	err: Error,
) {
	require_claim(store, id) or_return
	if checkpoint.summary == "" { return 0, error_make(.Invalid_Argument, "a checkpoint needs a summary") }
	if checkpoint.covered_seq <= 0 { return 0, error_make(.Invalid_Argument, "a checkpoint must cover some history") }
	if compaction_request <= 0 { return 0, error_make(.Invalid_Argument, "a checkpoint needs the request that produced it") }

	covered, covered_err := entry_exists(store, id, checkpoint.covered_seq)
	if covered_err != nil { return 0, covered_err }
	if !covered { return 0, error_make(.Invalid_Argument, "a checkpoint must cover an entry that exists") }

	if begin_err := db.exec(&store.conn, "BEGIN IMMEDIATE"); begin_err != nil {
		return 0, storage_error("begin checkpoint install", begin_err)
	}
	committed := false
	defer if !committed { abandon_transaction(store) }

	base, base_err := checkpoint_latest_seq(store, id)
	if base_err != nil { return 0, base_err }
	if !maybe_seq_equal(base, expected_base) {
		return 0, error_make(.Invalid_State, "the checkpoint's base has changed")
	}
	origin, origin_err := checkpoint_origin_state(store, id, compaction_request)
	if origin_err != nil { return 0, origin_err }
	if !origin.completed {
		return 0, error_make(.Invalid_Argument, "a checkpoint must come from a completed compaction request")
	}
	if origin.installed {
		return 0, error_make(.Invalid_State, "that compaction request already installed a checkpoint")
	}

	payload := Checkpoint_Entry {
		summary     = checkpoint.summary,
		covered_seq = checkpoint.covered_seq,
	}
	if value, present := base.?; present { payload.previous_seq = Seq(value) }

	next, next_err := scalar_i64(store, ENTRY_NEXT_SEQ, {db.Value(string(id))})
	if next_err != nil { return 0, next_err }
	seq = Seq(next)
	entry := New_Entry {
		turn_no       = checkpoint.turn_no,
		request_no    = compaction_request,
		created_at_ms = checkpoint.at_ms,
		payload       = payload,
	}
	if validate_err := validate_new_entry(store, id, seq, entry); validate_err != nil { return 0, validate_err }
	if insert_err := insert_entry(store, id, seq, entry); insert_err != nil { return 0, insert_err }

	if err := db.commit(&store.conn); err != nil {
		return 0, storage_error("commit checkpoint install", err)
	}
	committed = true
	return seq, nil
}

@(private)
CHECKPOINT_ORIGIN_STATE :: `SELECT r.purpose, r.status, EXISTS (SELECT 1 FROM entries AS c WHERE c.session_id = r.session_id AND c.kind = 'checkpoint' AND c.request_no = r.request_no) FROM requests AS r WHERE r.session_id = ? AND r.request_no = ?`

@(private)
Checkpoint_Origin :: struct {
	compaction: bool,
	completed:  bool,
	installed:  bool,
}

@(private)
checkpoint_origin_state :: proc(store: ^Store, id: Session_Id, request_no: Request_No) -> (origin: Checkpoint_Origin, err: Error) {
	rows: db.Rows
	args := [?]db.Value{db.Value(string(id)), db.Value(i64(request_no))}
	if query_err := db.query(&store.conn, &rows, CHECKPOINT_ORIGIN_STATE, args[:]); query_err != nil {
		return {}, storage_error("read the compaction request", query_err)
	}
	defer db.rows_close(&rows)

	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return {}, storage_error("read the compaction request", next_err) }
	if !has_row { return {}, error_make(.Not_Found, "no compaction request has that number") }
	purpose, purpose_err := db.as_string(values[0])
	if purpose_err != nil { return {}, corrupt_error("read the compaction request", purpose_err) }
	status, status_err := db.as_string(values[1])
	if status_err != nil { return {}, corrupt_error("read the compaction request", status_err) }
	installed, installed_err := db.as_i64(values[2])
	if installed_err != nil { return {}, corrupt_error("read the compaction request", installed_err) }

	origin.compaction = purpose == request_purpose_name(.Compaction)
	origin.completed = status == outcome_name(.Completed)
	origin.installed = installed != 0
	return origin, nil
}

@(private)
checkpoint_latest_seq :: proc(store: ^Store, id: Session_Id) -> (Maybe(Seq), Error) {
	rows: db.Rows
	if err := db.query(&store.conn, &rows, CHECKPOINT_LATEST_SEQ, {db.Value(string(id))}); err != nil {
		return nil, storage_error("find the latest checkpoint", err)
	}
	defer db.rows_close(&rows)

	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return nil, storage_error("find the latest checkpoint", next_err) }
	if !has_row { return nil, nil }
	seq, convert_err := db.as_i64(values[0])
	if convert_err != nil { return nil, corrupt_error("find the latest checkpoint", convert_err) }
	return Seq(seq), nil
}

// maybe_seq_equal compares two optional sequences by presence and value, which is
// how a compaction candidate names the checkpoint it was computed against.
maybe_seq_equal :: proc(a, b: Maybe(Seq)) -> bool {
	a_value, a_present := a.?
	b_value, b_present := b.?
	if a_present != b_present { return false }
	return !a_present || a_value == b_value
}

// entry_latest_checkpoint returns the newest checkpoint entry, or false when
// the session has none. The result owns its strings under allocator.
entry_latest_checkpoint :: proc(store: ^Store, id: Session_Id, allocator := context.allocator) -> (Entry, bool, Error) {
	if !store.open { return {}, false, error_make(.Invalid_State, "the store is closed") }
	entries, read_err := entries_read(store, ENTRY_SELECT_LATEST_CHECKPOINT, {db.Value(string(id))}, false, allocator)
	if read_err != nil { return {}, false, read_err }
	// The buffer is released either way; the entry that is returned was copied
	// out of it and keeps its own strings.
	defer delete(entries, allocator)
	if len(entries) == 0 { return {}, false, nil }
	return entries[0], true, nil
}

// --- context ----------------------------------------------------------------

// Context is the conversation a later request is built from: the newest
// checkpoint's summary, when there is one, followed by the entries the summary
// does not cover.
//
// It is not the session's history. History keeps every entry, including the
// ones a summary replaced and the bookkeeping a model is never shown.
Context :: struct {
	summary:     string, // owned; "" when the session has no checkpoint
	summary_seq: Maybe(Seq), // the checkpoint entry itself
	covered_seq: Maybe(Seq), // the last entry the checkpoint covers
	entries:     []Entry, // owned; what a model is shown
	// dispatches is what the harness committed to run, one per call it answered.
	// It is not conversation, but a request needs it: a proposal is not always
	// what ran, and the projection has to say what ran rather than replay
	// arguments an endpoint would refuse.
	dispatches:  []Entry, // owned
}

context_destroy :: proc(ctx: ^Context, allocator := context.allocator) {
	if ctx == nil { return }
	delete(ctx.summary, allocator)
	entries_destroy(ctx.entries, allocator)
	entries_destroy(ctx.dispatches, allocator)
	ctx^ = {}
}

Replay_History :: struct {
	entries: []Entry, // owned
}

history_destroy :: proc(history: ^Replay_History, allocator := context.allocator) {
	if history == nil { return }
	entries_destroy(history.entries, allocator)
	history^ = {}
}

// history_load reads the retained conversation rather than the compacted model
// context. ACP replay needs every user, assistant, and tool record, including
// entries before the latest checkpoint.
history_load :: proc(store: ^Store, id: Session_Id, allocator := context.allocator) -> (history: Replay_History, err: Error) {
	if !store.open { return {}, error_make(.Invalid_State, "the store is closed") }
	entries, read_err := entries_read(
		store,
		`SELECT ` +
		ENTRY_COLUMNS +
		` FROM entries WHERE session_id = ? AND parent_call_seq IS NULL AND kind NOT IN ('tool_dispatch', 'checkpoint', 'instruction_snapshot') ORDER BY seq`,
		{db.Value(string(id))},
		false,
		allocator,
	)
	if read_err != nil { return {}, read_err }
	return Replay_History{entries = entries}, nil
}

// context_load reads what a request would be built from right now. Entries a
// model is never shown are left out: a tool dispatch is bookkeeping, and a
// partial assistant entry is text from a turn that never finished.
context_load :: proc(store: ^Store, id: Session_Id, allocator := context.allocator) -> (ctx: Context, err: Error) {
	if !store.open { return {}, error_make(.Invalid_State, "the store is closed") }

	checkpoint, has_checkpoint, checkpoint_err := entry_latest_checkpoint(store, id, allocator)
	if checkpoint_err != nil { return {}, checkpoint_err }

	boundary: Maybe(Seq)
	if has_checkpoint {
		payload, is_checkpoint := checkpoint.payload.(Checkpoint_Entry)
		if !is_checkpoint {
			entry_destroy(&checkpoint, allocator)
			return {}, error_make(.Corrupt, "the newest checkpoint does not hold a checkpoint payload")
		}
		ctx.summary = payload.summary
		ctx.summary_seq = checkpoint.seq
		ctx.covered_seq = payload.covered_seq
		boundary = payload.covered_seq
		// The summary was moved out of the entry, so only the entry's other
		// fields are released here.
		payload.summary = ""
		checkpoint.payload = payload
		entry_destroy(&checkpoint, allocator)
	}

	// The query's arguments are this read's own, so the temp arena is released with them
	// rather than keeping the request's copy of them for the session's life.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	args := make([dynamic]db.Value, 0, 2, context.temp_allocator)
	append(&args, db.Value(string(id)))
	if value, present := boundary.?; present {
		append(&args, db.Value(i64(value)))
	} else {
		append(&args, db.Value(nil))
	}

	entries, read_err := entries_read(store, ENTRY_SELECT_CONTEXT, args[:], true, allocator)
	if read_err != nil {
		delete(ctx.summary, allocator)
		return {}, read_err
	}
	ctx.entries = entries

	dispatches, dispatch_err := entries_read(store, ENTRY_SELECT_DISPATCHES, args[:], true, allocator)
	if dispatch_err != nil {
		context_destroy(&ctx, allocator)
		return {}, dispatch_err
	}
	ctx.dispatches = dispatches
	return ctx, nil
}

// --- statements -------------------------------------------------------------

@(private)
UNSETTLED_CALLS :: `SELECT c.seq, c.turn_no, c.request_no, EXISTS (SELECT 1 FROM entries AS d WHERE d.session_id = c.session_id AND d.kind = 'tool_dispatch' AND d.related_seq = c.seq) FROM entries AS c WHERE c.session_id = ? AND c.kind = 'tool_call' AND NOT EXISTS (SELECT 1 FROM entries AS r WHERE r.session_id = c.session_id AND r.kind = 'tool_result' AND r.related_seq = c.seq) ORDER BY c.seq`

@(private)
REQUESTS_INTERRUPT :: `UPDATE requests SET status = 'interrupted', finished_at_ms = ? WHERE session_id = ? AND status = 'running'`

@(private)
TURNS_INTERRUPT :: `UPDATE turns SET status = 'interrupted', finished_at_ms = ? WHERE session_id = ? AND status = 'running'`

@(private)
CHECKPOINT_LATEST_SEQ :: `SELECT seq FROM entries WHERE session_id = ? AND kind = 'checkpoint' ORDER BY seq DESC LIMIT 1`

@(private)
ENTRY_SELECT_LATEST_CHECKPOINT :: `SELECT ` + ENTRY_COLUMNS + ` FROM entries WHERE session_id = ? AND kind = 'checkpoint' ORDER BY seq DESC LIMIT 1`

@(private)
ENTRY_SELECT_CONTEXT ::
	`SELECT ` +
	ENTRY_COLUMNS +
	` FROM entries AS e WHERE e.session_id = ? AND e.seq > COALESCE(?, 0) AND e.parent_call_seq IS NULL AND NOT (e.kind = 'tool_result' AND EXISTS (SELECT 1 FROM entries AS c WHERE c.session_id = e.session_id AND c.seq = e.related_seq AND c.parent_call_seq IS NOT NULL)) AND e.kind NOT IN ('tool_dispatch', 'checkpoint', 'instruction_snapshot') ORDER BY e.seq`

@(private)
ENTRY_SELECT_DISPATCHES ::
	`SELECT ` +
	ENTRY_COLUMNS +
	` FROM entries AS e WHERE e.session_id = ? AND e.seq > COALESCE(?, 0) AND e.parent_call_seq IS NULL AND NOT EXISTS (SELECT 1 FROM entries AS c WHERE c.session_id = e.session_id AND c.seq = e.related_seq AND c.parent_call_seq IS NOT NULL) AND e.kind = 'tool_dispatch' ORDER BY e.seq`

@(private)
entry_exists :: proc(store: ^Store, id: Session_Id, seq: Seq) -> (bool, Error) {
	args := [?]db.Value{db.Value(string(id)), db.Value(i64(seq))}
	count, count_err := scalar_i64(store, "SELECT COUNT(*) FROM entries WHERE session_id = ? AND seq = ?", args[:])
	if count_err != nil { return false, count_err }
	return count > 0, nil
}
