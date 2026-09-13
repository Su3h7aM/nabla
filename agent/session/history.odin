package session

import "core:fmt"
import "core:mem"
import "core:strings"

import "nabla:db"

// Usage is what a provider reported for one request. A nil field means the
// provider did not report that number; it does not mean zero.
Usage :: struct {
	input:       Maybe(i64),
	output:      Maybe(i64),
	cache_read:  Maybe(i64),
	cache_write: Maybe(i64),
}

// New_Request is a model request about to begin. The input description is
// written before the request is sent, so a request that never finishes still
// says what context it was given.
New_Request :: struct {
	turn_no:         Maybe(Turn_No),
	purpose:         Request_Purpose,
	provider:        string,
	model_requested: string,
	api:             string,
	config_json:     string,
	input_json:      string,
}

// Request_Finish is the terminal record of a request.
Request_Finish :: struct {
	outcome:        Outcome,
	model_resolved: string,
	response_json:  string,
	error_json:     string,
	usage:          Usage,
	at_ms:          i64,
}

// turn_begin admits user input: it opens a turn, records the prompt as the
// turn's first entry, and marks the session active. All three land in one
// transaction, so a turn never exists without the input that opened it.
turn_begin :: proc(store: ^Store, id: Session_Id, user_text: string, origin: User_Origin, at_ms: i64) -> (turn_no: Turn_No, err: Error) {
	require_claim(store, id) or_return
	if user_text == "" { return 0, error_make(.Invalid_Argument, "a turn needs user text") }
	if at_ms <= 0 { return 0, error_make(.Invalid_Argument, "a turn needs a timestamp") }

	if err := db.exec(&store.conn, "BEGIN IMMEDIATE"); err != nil {
		return 0, storage_error("begin turn", err)
	}
	committed := false
	defer if !committed { db.rollback(&store.conn) }

	turn, turn_err := scalar_i64(store, TURN_NEXT_NO, string(id))
	if turn_err != nil { return 0, turn_err }
	turn_no = Turn_No(turn)

	turn_args := [?]db.Value{db.Value(string(id)), db.Value(turn), db.Value(at_ms), db.Value(nil), db.Value(outcome_name(.Running)), db.Value(nil)}
	if err := db.exec(&store.conn, TURN_INSERT, turn_args[:]); err != nil {
		return 0, storage_error("begin turn", err)
	}

	seq, seq_err := scalar_i64(store, ENTRY_NEXT_SEQ, string(id))
	if seq_err != nil { return 0, seq_err }
	entry := New_Entry {
		turn_no = turn_no,
		created_at_ms = at_ms,
		payload = User_Entry{text = user_text, origin = origin},
	}
	if insert_err := insert_entry(store, id, Seq(seq), entry); insert_err != nil { return 0, insert_err }

	if touch_err := touch_session(store, id, at_ms); touch_err != nil { return 0, touch_err }

	if commit_err := db.commit(&store.conn); commit_err != nil {
		return 0, storage_error("commit turn", commit_err)
	}
	committed = true
	return turn_no, nil
}

// turn_finish records how a turn ended. A turn that is already finished is
// refused, so a completion cannot overwrite an interruption.
turn_finish :: proc(store: ^Store, id: Session_Id, turn_no: Turn_No, outcome: Outcome, error_json: string, at_ms: i64) -> Error {
	require_claim(store, id) or_return
	if outcome == .Running { return error_make(.Invalid_Argument, "a finished turn cannot still be running") }
	if at_ms <= 0 { return error_make(.Invalid_Argument, "a turn needs a timestamp") }

	if err := db.exec(&store.conn, "BEGIN IMMEDIATE"); err != nil {
		return storage_error("begin turn finish", err)
	}
	committed := false
	defer if !committed { db.rollback(&store.conn) }

	args := [?]db.Value{db.Value(outcome_name(outcome)), db.Value(at_ms), optional_text_value(error_json), db.Value(string(id)), db.Value(i64(turn_no))}
	affected, affected_err := exec_affected(store, TURN_FINISH, args[:])
	if affected_err != nil { return affected_err }
	if affected == 0 { return error_make(.Not_Found, "no running turn has that number") }

	if err := touch_session(store, id, at_ms); err != nil { return err }
	if err := db.commit(&store.conn); err != nil {
		return storage_error("commit turn finish", err)
	}
	committed = true
	return nil
}

// request_begin records a model request before it is sent, together with the
// context it was built from.
request_begin :: proc(store: ^Store, id: Session_Id, request: New_Request, at_ms: i64) -> (request_no: Request_No, err: Error) {
	require_claim(store, id) or_return
	if request.provider == "" { return 0, error_make(.Invalid_Argument, "a request needs a provider") }
	if request.model_requested == "" { return 0, error_make(.Invalid_Argument, "a request needs a model") }
	if request.api == "" { return 0, error_make(.Invalid_Argument, "a request needs an api") }
	if request.input_json == "" { return 0, error_make(.Invalid_Argument, "a request needs its input description") }
	if request.config_json == "" { return 0, error_make(.Invalid_Argument, "a request needs its settings") }
	if at_ms <= 0 { return 0, error_make(.Invalid_Argument, "a request needs a timestamp") }
	if request.purpose == .Response {
		if _, present := request.turn_no.?; !present {
			return 0, error_make(.Invalid_Argument, "a response request belongs to a turn")
		}
	}

	if err := db.exec(&store.conn, "BEGIN IMMEDIATE"); err != nil {
		return 0, storage_error("begin request", err)
	}
	committed := false
	defer if !committed { db.rollback(&store.conn) }

	number, number_err := scalar_i64(store, REQUEST_NEXT_NO, string(id))
	if number_err != nil { return 0, number_err }
	request_no = Request_No(number)

	args := [?]db.Value {
		db.Value(string(id)),
		db.Value(number),
		optional_int_value(request.turn_no),
		db.Value(request_purpose_name(request.purpose)),
		db.Value(at_ms),
		db.Value(nil),
		db.Value(outcome_name(.Running)),
		db.Value(request.provider),
		db.Value(request.model_requested),
		db.Value(nil),
		db.Value(request.api),
		db.Value(request.config_json),
		db.Value(request.input_json),
		db.Value(nil),
		db.Value(nil),
		db.Value(nil),
		db.Value(nil),
		db.Value(nil),
		db.Value(nil),
	}
	if err := db.exec(&store.conn, REQUEST_INSERT, args[:]); err != nil {
		return 0, storage_error("begin request", err)
	}
	if err := db.commit(&store.conn); err != nil {
		return 0, storage_error("commit request", err)
	}
	committed = true
	return request_no, nil
}

// request_finish records how a request ended together with what it cost. The
// request's own record is the only place usage lives, so a total is a query
// over requests rather than a second counter that can drift.
request_finish :: proc(store: ^Store, id: Session_Id, request_no: Request_No, finish: Request_Finish) -> Error {
	require_claim(store, id) or_return
	if finish.outcome == .Running { return error_make(.Invalid_Argument, "a finished request cannot still be running") }
	if finish.at_ms <= 0 { return error_make(.Invalid_Argument, "a request needs a timestamp") }

	if err := db.exec(&store.conn, "BEGIN IMMEDIATE"); err != nil {
		return storage_error("begin request finish", err)
	}
	committed := false
	defer if !committed { db.rollback(&store.conn) }

	args := [?]db.Value {
		db.Value(outcome_name(finish.outcome)),
		db.Value(finish.at_ms),
		optional_text_value(finish.model_resolved),
		optional_text_value(finish.response_json),
		optional_text_value(finish.error_json),
		optional_int_value(finish.usage.input),
		optional_int_value(finish.usage.output),
		optional_int_value(finish.usage.cache_read),
		optional_int_value(finish.usage.cache_write),
		db.Value(string(id)),
		db.Value(i64(request_no)),
	}
	affected, affected_err := exec_affected(store, REQUEST_FINISH, args[:])
	if affected_err != nil { return affected_err }
	if affected == 0 { return error_make(.Not_Found, "no running request has that number") }

	if err := db.commit(&store.conn); err != nil {
		return storage_error("commit request finish", err)
	}
	committed = true
	return nil
}

// entries_append stores a run of entries and returns the sequence numbers they
// were given. The whole run is one transaction, so a request's output and the
// calls it proposed are either all recorded or none of it is.
//
// The returned slice is owned by allocator.
entries_append :: proc(store: ^Store, id: Session_Id, entries: []New_Entry, allocator := context.allocator) -> (seqs: []Seq, err: Error) {
	require_claim(store, id) or_return
	if len(entries) == 0 { return nil, nil }

	if err := db.exec(&store.conn, "BEGIN IMMEDIATE"); err != nil {
		return nil, storage_error("begin entry write", err)
	}
	committed := false
	defer if !committed { db.rollback(&store.conn) }

	base, base_err := scalar_i64(store, ENTRY_NEXT_SEQ, string(id))
	if base_err != nil { return nil, base_err }

	seqs = make([]Seq, len(entries), allocator)
	defer if !committed { delete(seqs, allocator) }

	for entry, i in entries {
		seq := Seq(base + i64(i))
		if validate_err := validate_new_entry(store, id, seq, entry); validate_err != nil { return nil, validate_err }
		if insert_err := insert_entry(store, id, seq, entry); insert_err != nil { return nil, insert_err }
		seqs[i] = seq
	}

	if err := db.commit(&store.conn); err != nil {
		return nil, storage_error("commit entry write", err)
	}
	committed = true
	return seqs, nil
}

// entry_append stores one entry and returns its sequence number.
entry_append :: proc(store: ^Store, id: Session_Id, entry: New_Entry) -> (Seq, Error) {
	batch := [1]New_Entry{entry}
	seqs, append_err := entries_append(store, id, batch[:], context.temp_allocator)
	if append_err != nil { return 0, append_err }
	return seqs[0], nil
}

// entries_load reads a contiguous run of a session's history in sequence order.
// Reading does not need the writer claim.
entries_load :: proc(store: ^Store, id: Session_Id, options: Entry_Load_Options, allocator := context.allocator) -> ([]Entry, Error) {
	if !store.open { return nil, error_make(.Invalid_State, "the store is closed") }
	limit := options.limit
	if limit <= 0 { limit = ENTRIES_DEFAULT_LIMIT }
	if limit > ENTRIES_MAX_LIMIT { limit = ENTRIES_MAX_LIMIT }

	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, ENTRY_SELECT_RANGE)
	args := make([dynamic]db.Value, 0, 4, context.temp_allocator)
	append(&args, db.Value(string(id)))
	if after, present := options.after.?; present {
		strings.write_string(&builder, " AND seq > ?")
		append(&args, db.Value(i64(after)))
	}
	if through, present := options.through.?; present {
		strings.write_string(&builder, " AND seq <= ?")
		append(&args, db.Value(i64(through)))
	}
	strings.write_string(&builder, " ORDER BY seq LIMIT ?")
	append(&args, db.Value(i64(limit)))

	rows: db.Rows
	if err := db.query(&store.conn, &rows, strings.to_string(builder), args[:]); err != nil {
		return nil, storage_error("load history", err)
	}
	defer db.rows_close(&rows)

	entries := make([dynamic]Entry, 0, 16, allocator)
	complete := false
	defer if !complete { entries_destroy(entries[:], allocator) }

	for {
		values, has_row, next_err := db.rows_next(&rows)
		if next_err != nil { return nil, storage_error("load history", next_err) }
		if !has_row { break }
		entry, scan_err := entry_scan(values, allocator)
		if scan_err != nil { return nil, scan_err }
		append(&entries, entry)
	}
	complete = true
	return entries[:], nil
}

// --- statements -------------------------------------------------------------

@(private)
TURN_INSERT :: `INSERT INTO turns (session_id, turn_no, started_at_ms, finished_at_ms, status, error_json) VALUES (?, ?, ?, ?, ?, ?)`

@(private)
TURN_FINISH :: `UPDATE turns SET status = ?, finished_at_ms = ?, error_json = ? WHERE session_id = ? AND turn_no = ? AND status = 'running'`

@(private)
TURN_NEXT_NO :: `SELECT COALESCE(MAX(turn_no), 0) + 1 FROM turns WHERE session_id = ?`

@(private)
REQUEST_INSERT :: `INSERT INTO requests (session_id, request_no, turn_no, purpose, started_at_ms, finished_at_ms, status, provider, model_requested, model_resolved, api, config_json, input_json, response_json, error_json, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`

@(private)
REQUEST_FINISH :: `UPDATE requests SET status = ?, finished_at_ms = ?, model_resolved = ?, response_json = ?, error_json = ?, input_tokens = ?, output_tokens = ?, cache_read_tokens = ?, cache_write_tokens = ? WHERE session_id = ? AND request_no = ? AND status = 'running'`

@(private)
REQUEST_NEXT_NO :: `SELECT COALESCE(MAX(request_no), 0) + 1 FROM requests WHERE session_id = ?`

@(private)
ENTRY_INSERT :: `INSERT INTO entries (session_id, seq, turn_no, request_no, created_at_ms, kind, related_seq, payload_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`

@(private)
ENTRY_NEXT_SEQ :: `SELECT COALESCE(MAX(seq), 0) + 1 FROM entries WHERE session_id = ?`

@(private)
ENTRY_SELECT_RANGE :: `SELECT seq, turn_no, request_no, created_at_ms, kind, related_seq, payload_json FROM entries WHERE session_id = ?`

@(private)
ENTRY_SELECT_KIND :: `SELECT kind FROM entries WHERE session_id = ? AND seq = ?`

// --- entry writing ----------------------------------------------------------

@(private)
insert_entry :: proc(store: ^Store, id: Session_Id, seq: Seq, entry: New_Entry) -> Error {
	payload_json, encode_err := entry_payload_encode(entry.payload, context.temp_allocator)
	if encode_err != nil { return encode_err }

	args := [?]db.Value {
		db.Value(string(id)),
		db.Value(i64(seq)),
		optional_int_value(entry.turn_no),
		optional_int_value(entry.request_no),
		db.Value(entry.created_at_ms),
		db.Value(entry_kind_name(entry_kind_of(entry.payload))),
		optional_int_value(entry.related_seq),
		db.Value(string(payload_json)),
	}
	if err := db.exec(&store.conn, ENTRY_INSERT, args[:]); err != nil {
		return storage_error("append entry", err)
	}
	return nil
}

// validate_new_entry checks the relationships a foreign key cannot express: a
// dispatch or result must name an existing tool call from the same session, and
// only those kinds may name a related entry at all.
@(private)
validate_new_entry :: proc(store: ^Store, id: Session_Id, seq: Seq, entry: New_Entry) -> Error {
	if entry.created_at_ms <= 0 { return error_make(.Invalid_Argument, "an entry needs a timestamp") }
	kind := entry_kind_of(entry.payload)

	if kind == .Tool_Dispatch || kind == .Tool_Result {
		related, present := entry.related_seq.?
		if !present {
			return error_make(.Invalid_Argument, "a tool dispatch or result must name the call it belongs to")
		}
		if related <= 0 || related >= seq {
			return error_make(.Invalid_Argument, "the related call must come before the entry")
		}
		if err := require_tool_call(store, id, related); err != nil { return err }
	} else if _, present := entry.related_seq.?; present {
		return error_make(.Invalid_Argument, "only a tool dispatch or result may name a related entry")
	}

	if !entry_payload_complete(kind, entry.payload) {
		return error_make(.Invalid_Argument, "the entry payload is missing a required field")
	}
	return nil
}

@(private)
require_tool_call :: proc(store: ^Store, id: Session_Id, seq: Seq) -> Error {
	rows: db.Rows
	args := [?]db.Value{db.Value(string(id)), db.Value(i64(seq))}
	if err := db.query(&store.conn, &rows, ENTRY_SELECT_KIND, args[:]); err != nil {
		return storage_error("read the related entry", err)
	}
	defer db.rows_close(&rows)

	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return storage_error("read the related entry", next_err) }
	if !has_row { return error_make(.Invalid_Argument, "the related entry does not exist") }
	kind, convert_err := db.as_string(values[0])
	if convert_err != nil { return corrupt_error("read the related entry", convert_err) }
	if kind != entry_kind_name(.Tool_Call) {
		return error_make(.Invalid_Argument, "the related entry is not a tool call")
	}
	return nil
}

// --- entry reading ----------------------------------------------------------

@(private)
entry_scan :: proc(values: []db.Value, allocator: mem.Allocator) -> (entry: Entry, err: Error) {
	complete := false
	defer if !complete { entry_destroy(&entry, allocator) }

	seq, seq_err := db.as_i64(values[0])
	if seq_err != nil { return {}, corrupt_error("read entry sequence", seq_err) }
	turn_no, turn_err := read_optional_i64(values[1])
	if turn_err != nil { return {}, corrupt_error("read entry turn", turn_err) }
	request_no, request_err := read_optional_i64(values[2])
	if request_err != nil { return {}, corrupt_error("read entry request", request_err) }
	created_at_ms, created_err := db.as_i64(values[3])
	if created_err != nil { return {}, corrupt_error("read entry time", created_err) }
	kind_name, kind_err := db.as_string(values[4])
	if kind_err != nil { return {}, corrupt_error("read entry kind", kind_err) }
	related_seq, related_err := read_optional_i64(values[5])
	if related_err != nil { return {}, corrupt_error("read related sequence", related_err) }
	payload_json, payload_err := db.as_string(values[6])
	if payload_err != nil { return {}, corrupt_error("read entry payload", payload_err) }

	kind, known := entry_kind_from_name(kind_name)
	if !known { return {}, error_make(.Corrupt, fmt.tprintf("a stored entry has an unknown kind: %s", kind_name)) }

	payload, decode_err := entry_payload_decode(kind, payload_json, allocator)
	if decode_err != nil { return {}, decode_err }

	entry = Entry {
		seq           = Seq(seq),
		kind          = kind,
		created_at_ms = created_at_ms,
		payload       = payload,
	}
	if value, present := turn_no.?; present { entry.turn_no = Turn_No(value) }
	if value, present := request_no.?; present { entry.request_no = Request_No(value) }
	if value, present := related_seq.?; present { entry.related_seq = Seq(value) }
	complete = true
	return entry, nil
}

// --- supporting -------------------------------------------------------------

@(private)
touch_session :: proc(store: ^Store, id: Session_Id, at_ms: i64) -> Error {
	args := [?]db.Value{db.Value(at_ms), db.Value(string(id))}
	if err := db.exec(&store.conn, "UPDATE sessions SET updated_at_ms = ? WHERE id = ?", args[:]); err != nil {
		return storage_error("record session activity", err)
	}
	return nil
}

// scalar_i64 runs a query whose single parameter is a session id and returns
// its single integer result. It is used for the per-session counters, which are
// read inside the transaction that appends the row they number.
@(private)
scalar_i64 :: proc(store: ^Store, sql: string, argument: string) -> (i64, Error) {
	rows: db.Rows
	if err := db.query(&store.conn, &rows, sql, {db.Value(argument)}); err != nil {
		return 0, storage_error("read counter", err)
	}
	defer db.rows_close(&rows)
	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return 0, storage_error("read counter", next_err) }
	if !has_row { return 0, error_make(.Corrupt, "a counter query returned no row") }
	number, convert_err := db.as_i64(values[0])
	if convert_err != nil { return 0, corrupt_error("read counter", convert_err) }
	return number, nil
}

// exec_affected runs one write and reports how many rows it changed, so a write
// that matched nothing is an error rather than a silent no-op.
@(private)
exec_affected :: proc(store: ^Store, sql: string, args: []db.Value) -> (i64, Error) {
	if err := db.exec(&store.conn, sql, args); err != nil {
		return 0, storage_error("write", err)
	}
	rows: db.Rows
	if err := db.query(&store.conn, &rows, "SELECT changes()"); err != nil {
		return 0, storage_error("read change count", err)
	}
	defer db.rows_close(&rows)
	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return 0, storage_error("read change count", next_err) }
	if !has_row { return 0, error_make(.Corrupt, "SELECT changes() returned no row") }
	count, convert_err := db.as_i64(values[0])
	if convert_err != nil { return 0, corrupt_error("read change count", convert_err) }
	return count, nil
}

@(private)
optional_int_value :: proc(value: Maybe($T)) -> db.Value {
	if number, present := value.?; present { return db.Value(i64(number)) }
	return db.Value(nil)
}

@(private)
optional_text_value :: proc(value: string) -> db.Value {
	if value == "" { return db.Value(nil) }
	return db.Value(value)
}
