package session

import "core:mem"

import "nabla:db"

// --- recovery ---------------------------------------------------------------

// Recovery reports what an interrupted session had to settle.
Recovery :: struct {
	interrupted_turns:    int,
	interrupted_requests: int,
	recovered_calls:      int,
}

// Recover_Options carries what recovery needs besides the session itself.
// recovered_content is the model-visible result written for a call whose
// outcome the harness never observed; the harness supplies it because it owns
// the shape of a tool result.
Recover_Options :: struct {
	at_ms:             i64,
	recovered_content: string,
}

// session_recover settles a session that was interrupted. A dispatch with no
// result gets an honest result saying the outcome is unknown, then any request
// and turn still marked running is closed as interrupted.
//
// Recovery records what the harness knows. It never reruns a tool and never
// resumes a request, because a dispatch may have taken effect before the
// process died and that effect is the user's to inspect.
session_recover :: proc(store: ^Store, id: Session_Id, options: Recover_Options, allocator := context.allocator) -> (recovery: Recovery, err: Error) {
	require_claim(store, id) or_return
	if options.at_ms <= 0 { return {}, error_make(.Invalid_Argument, "recovery needs a timestamp") }
	if options.recovered_content == "" { return {}, error_make(.Invalid_Argument, "recovery needs the result text to record") }

	if err := db.exec(&store.conn, "BEGIN IMMEDIATE"); err != nil {
		return {}, storage_error("begin recovery", err)
	}
	committed := false
	defer if !committed { db.rollback(&store.conn) }

	unresolved, unresolved_err := unresolved_calls(store, id, allocator)
	if unresolved_err != nil { return {}, unresolved_err }
	defer delete(unresolved)

	if len(unresolved) > 0 {
		base, base_err := scalar_i64(store, ENTRY_NEXT_SEQ, {db.Value(string(id))})
		if base_err != nil { return {}, base_err }
		for call, i in unresolved {
			payload := Tool_Result_Entry {
				outcome = .Unknown,
				// A recovered result is the harness admitting it does not know,
				// so there is no error text: an error would claim a cause.
				content = options.recovered_content,
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
			recovery.recovered_calls += 1
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
Unresolved_Call :: struct {
	call_seq:   Seq,
	turn_no:    Maybe(Turn_No),
	request_no: Maybe(Request_No),
}

// unresolved_calls finds every dispatch that never produced a result. It runs
// inside the recovery transaction, so the set cannot change under it.
@(private)
unresolved_calls :: proc(store: ^Store, id: Session_Id, allocator: mem.Allocator) -> ([]Unresolved_Call, Error) {
	rows: db.Rows
	if err := db.query(&store.conn, &rows, UNRESOLVED_CALLS, {db.Value(string(id))}); err != nil {
		return nil, storage_error("find unresolved tool calls", err)
	}
	defer db.rows_close(&rows)

	calls := make([dynamic]Unresolved_Call, 0, 4, allocator)
	complete := false
	defer if !complete { delete(calls) }

	for {
		values, has_row, next_err := db.rows_next(&rows)
		if next_err != nil { return nil, storage_error("find unresolved tool calls", next_err) }
		if !has_row { break }
		call_seq, seq_err := db.as_i64(values[0])
		if seq_err != nil { return nil, corrupt_error("read an unresolved call", seq_err) }
		turn_no, turn_err := read_optional_i64(values[1])
		if turn_err != nil { return nil, corrupt_error("read an unresolved call", turn_err) }
		request_no, request_err := read_optional_i64(values[2])
		if request_err != nil { return nil, corrupt_error("read an unresolved call", request_err) }

		call := Unresolved_Call {
			call_seq = Seq(call_seq),
		}
		if value, present := turn_no.?; present { call.turn_no = Turn_No(value) }
		if value, present := request_no.?; present { call.request_no = Request_No(value) }
		append(&calls, call)
	}
	complete = true
	return calls[:], nil
}

// --- checkpoints ------------------------------------------------------------

// New_Checkpoint is a compaction summary about to be stored. covered_seq is the
// last entry the summary stands in for; it must already exist.
New_Checkpoint :: struct {
	turn_no:     Maybe(Turn_No),
	request_no:  Maybe(Request_No),
	at_ms:       i64,
	summary:     string,
	covered_seq: Seq,
}

// checkpoint_append records a compaction summary. History is never rewritten:
// the summary is one more entry, and everything before covered_seq stays where
// it is, readable and analysable, but no longer part of the active context.
checkpoint_append :: proc(store: ^Store, id: Session_Id, checkpoint: New_Checkpoint) -> (seq: Seq, err: Error) {
	require_claim(store, id) or_return
	if checkpoint.summary == "" { return 0, error_make(.Invalid_Argument, "a checkpoint needs a summary") }
	if checkpoint.covered_seq <= 0 { return 0, error_make(.Invalid_Argument, "a checkpoint must cover some history") }

	covered, covered_err := entry_exists(store, id, checkpoint.covered_seq)
	if covered_err != nil { return 0, covered_err }
	if !covered { return 0, error_make(.Invalid_Argument, "a checkpoint must cover an entry that exists") }

	previous, previous_err := checkpoint_previous_seq(store, id)
	if previous_err != nil { return 0, previous_err }

	payload := Checkpoint_Entry {
		summary     = checkpoint.summary,
		covered_seq = checkpoint.covered_seq,
	}
	if value, present := previous.?; present { payload.previous_seq = Seq(value) }

	entry := New_Entry {
		turn_no       = checkpoint.turn_no,
		request_no    = checkpoint.request_no,
		created_at_ms = checkpoint.at_ms,
		payload       = payload,
	}
	return entry_append(store, id, entry)
}

@(private)
checkpoint_previous_seq :: proc(store: ^Store, id: Session_Id) -> (Maybe(Seq), Error) {
	rows: db.Rows
	if err := db.query(&store.conn, &rows, CHECKPOINT_LATEST_SEQ, {db.Value(string(id))}); err != nil {
		return nil, storage_error("find the previous checkpoint", err)
	}
	defer db.rows_close(&rows)

	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return nil, storage_error("find the previous checkpoint", next_err) }
	if !has_row { return nil, nil }
	seq, convert_err := db.as_i64(values[0])
	if convert_err != nil { return nil, corrupt_error("find the previous checkpoint", convert_err) }
	return Seq(seq), nil
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
	summary_seq: Maybe(Seq),
	entries:     []Entry, // owned
}

context_destroy :: proc(ctx: ^Context, allocator := context.allocator) {
	if ctx == nil { return }
	delete(ctx.summary, allocator)
	entries_destroy(ctx.entries, allocator)
	ctx^ = {}
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
		boundary = payload.covered_seq
		// The summary was moved out of the entry, so only the entry's other
		// fields are released here.
		payload.summary = ""
		checkpoint.payload = payload
		entry_destroy(&checkpoint, allocator)
	}

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
	return ctx, nil
}

// --- statements -------------------------------------------------------------

@(private)
UNRESOLVED_CALLS :: `SELECT d.related_seq, d.turn_no, d.request_no FROM entries AS d WHERE d.session_id = ? AND d.kind = 'tool_dispatch' AND NOT EXISTS (SELECT 1 FROM entries AS r WHERE r.session_id = d.session_id AND r.kind = 'tool_result' AND r.related_seq = d.related_seq) ORDER BY d.seq`

@(private)
REQUESTS_INTERRUPT :: `UPDATE requests SET status = 'interrupted', finished_at_ms = ? WHERE session_id = ? AND status = 'running'`

@(private)
TURNS_INTERRUPT :: `UPDATE turns SET status = 'interrupted', finished_at_ms = ? WHERE session_id = ? AND status = 'running'`

@(private)
CHECKPOINT_LATEST_SEQ :: `SELECT seq FROM entries WHERE session_id = ? AND kind = 'checkpoint' ORDER BY seq DESC LIMIT 1`

@(private)
ENTRY_SELECT_LATEST_CHECKPOINT :: `SELECT seq, turn_no, request_no, created_at_ms, kind, related_seq, payload_json FROM entries WHERE session_id = ? AND kind = 'checkpoint' ORDER BY seq DESC LIMIT 1`

@(private)
ENTRY_SELECT_CONTEXT :: `SELECT seq, turn_no, request_no, created_at_ms, kind, related_seq, payload_json FROM entries WHERE session_id = ? AND seq > COALESCE(?, 0) AND kind NOT IN ('tool_dispatch', 'checkpoint') ORDER BY seq`

@(private)
entry_exists :: proc(store: ^Store, id: Session_Id, seq: Seq) -> (bool, Error) {
	args := [?]db.Value{db.Value(string(id)), db.Value(i64(seq))}
	count, count_err := scalar_i64(store, "SELECT COUNT(*) FROM entries WHERE session_id = ? AND seq = ?", args[:])
	if count_err != nil { return false, count_err }
	return count > 0, nil
}
