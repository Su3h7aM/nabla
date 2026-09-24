package session

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"

import "nabla:db"

// Usage is what a provider reported for one request. A nil field means the
// provider did not report that number; it does not mean zero.
//
// input is total input tokens, the number a cache-read share is measured
// against, so it includes every token that was read from or written to the
// cache. OpenAI reports it that way already. A provider that reports uncached
// input on its own, as Anthropic does, must add its read and write counts before
// the value is stored, or the hit rate would be measured against too small a
// denominator.
Usage :: struct {
	input:       Maybe(i64),
	output:      Maybe(i64),
	cache_read:  Maybe(i64),
	cache_write: Maybe(i64),
}

// Cache_Totals is one session's reported token accounting across finished
// requests. A request contributes only when it reported that bucket; an
// unmeasured bucket is smaller than the row count suggests, so the counts say
// how many finished requests each sum rests on. Compaction and failed work are
// included by default: hiding them would flatter the hit rate rather than
// measure the session. A caller that wants the warm-period numbers filters by
// purpose or outcome in the same query and says so.
//
// paired_input and paired_read are the sums over the requests that reported both
// numbers, which is the only population a hit rate may be measured from: a
// request whose cache usage is unknown says nothing about the ones that reported.
Cache_Totals :: struct {
	input:                i64,
	cache_read:           i64,
	cache_write:          i64,
	output:               i64,
	paired_input:         i64,
	paired_read:          i64,
	// Requests each summed bucket rests on. A bucket the provider never
	// reported has no denominator of its own; its count stays zero.
	input_requests:       int,
	cache_read_requests:  int,
	cache_write_requests: int,
	output_requests:      int,
	// requests counts every finished request, paired_requests those the hit rate
	// rests on, missing_requests those that reported tokens but no cache bucket,
	// and invalid_requests those whose stored numbers cannot be used.
	requests:             int,
	paired_requests:      int,
	missing_requests:     int,
	invalid_requests:     int,
}

cache_totals_add :: proc(totals: ^Cache_Totals, usage: Usage) {
	totals.requests += 1
	if usage_invalid(usage) {
		totals.invalid_requests += 1
		return
	}
	if value, present := usage.input.?; present {
		totals.input += value
		totals.input_requests += 1
	}
	if value, present := usage.cache_read.?; present {
		totals.cache_read += value
		totals.cache_read_requests += 1
	}
	input, input_present := usage.input.?
	read, read_present := usage.cache_read.?
	if input_present && read_present {
		totals.paired_input += input
		totals.paired_read += read
		totals.paired_requests += 1
	}
	if _, write_present := usage.cache_write.?; !read_present && !write_present {
		totals.missing_requests += 1
	}
	if value, present := usage.cache_write.?; present {
		totals.cache_write += value
		totals.cache_write_requests += 1
	}
	if value, present := usage.output.?; present {
		totals.output += value
		totals.output_requests += 1
	}
}

// usage_invalid reports a stored measurement no accounting may use: a token count
// is never negative, and a session that reads one cannot trust the row it came from.
usage_invalid :: proc(usage: Usage) -> bool {
	for bucket in ([]Maybe(i64){usage.input, usage.output, usage.cache_read, usage.cache_write}) {
		if value, present := bucket.?; present && value < 0 { return true }
	}
	return false
}

// cache_hit_rate is the token-weighted share of reported input read from the
// provider's cache: cache-read tokens over all reported input tokens. It counts
// a session, not a request, because one request's ratio says more about where it
// sits in the conversation than about how much the prefix was reused. A
// workload whose turns are mostly new input cannot reach a high rate no matter
// how stable its prefixes are, so callers pair this with the suffix size before
// treating it as a regression signal.
//
// Only the requests that reported both an input total and a cache-read count are
// measured. Treating an unreported cache count as a miss would report a lower rate
// than the session actually achieved, which is what cache_coverage exists to make
// visible.
cache_hit_rate :: proc(totals: Cache_Totals) -> (rate: f64, measured: bool) {
	if totals.paired_requests == 0 || totals.paired_input <= 0 { return 0, false }
	if totals.paired_read > totals.paired_input { return 0, false }
	return f64(totals.paired_read) / f64(totals.paired_input), true
}

// cache_coverage is the share of reported input tokens the hit rate rests on. A
// rate from part of a session is a rate for that part, and a reader that cannot see
// the coverage cannot tell the difference.
cache_coverage :: proc(totals: Cache_Totals) -> (share: f64, measured: bool) {
	if totals.input_requests == 0 || totals.input <= 0 { return 0, false }
	return f64(totals.paired_input) / f64(totals.input), true
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

// Request is one stored model request, exactly as it was recorded. Every string
// is owned by the allocator it was read with and released by request_destroy.
Request :: struct {
	request_no:      Request_No,
	turn_no:         Maybe(Turn_No),
	purpose:         Request_Purpose,
	started_at_ms:   i64,
	finished_at_ms:  Maybe(i64),
	outcome:         Outcome,
	provider:        string, // owned
	model_requested: string, // owned
	model_resolved:  string, // owned
	api:             string, // owned
	config_json:     string, // owned
	input_json:      string, // owned
	response_json:   string, // owned
	error_json:      string, // owned
	usage:           Usage,
}

request_destroy :: proc(request: ^Request, allocator := context.allocator) {
	if request == nil { return }
	delete(request.provider, allocator)
	delete(request.model_requested, allocator)
	delete(request.model_resolved, allocator)
	delete(request.api, allocator)
	delete(request.config_json, allocator)
	delete(request.input_json, allocator)
	delete(request.response_json, allocator)
	delete(request.error_json, allocator)
	request^ = {}
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
	defer if !committed { abandon_transaction(store) }

	turn, turn_err := scalar_i64(store, TURN_NEXT_NO, {db.Value(string(id))})
	if turn_err != nil { return 0, turn_err }
	turn_no = Turn_No(turn)

	turn_args := [?]db.Value{db.Value(string(id)), db.Value(turn), db.Value(at_ms), db.Value(nil), db.Value(outcome_name(.Running)), db.Value(nil)}
	if err := db.exec(&store.conn, TURN_INSERT, turn_args[:]); err != nil {
		return 0, storage_error("begin turn", err)
	}

	seq, seq_err := scalar_i64(store, ENTRY_NEXT_SEQ, {db.Value(string(id))})
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
	defer if !committed { abandon_transaction(store) }

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
	defer if !committed { abandon_transaction(store) }

	number, number_err := scalar_i64(store, REQUEST_NEXT_NO, {db.Value(string(id))})
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
//
// A finished request must either keep all four usage numbers unknown or keep
// every number the provider reported. Cumulative stream measurements reach
// here through one normalized `ai` value, so repeated reports of one request
// are an update of that request, not another request's worth of tokens to add.
request_finish :: proc(store: ^Store, id: Session_Id, request_no: Request_No, finish: Request_Finish) -> Error {
	require_claim(store, id) or_return
	if finish.outcome == .Running { return error_make(.Invalid_Argument, "a finished request cannot still be running") }
	if finish.at_ms <= 0 { return error_make(.Invalid_Argument, "a request needs a timestamp") }

	if err := db.exec(&store.conn, "BEGIN IMMEDIATE"); err != nil {
		return storage_error("begin request finish", err)
	}
	committed := false
	defer if !committed { abandon_transaction(store) }

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

// cache_totals sums the usage of every finished request in the session.
// Rows still running and rows that never reported a bucket contribute
// nothing to that bucket; returning their counts alongside the sums is what
// keeps an unmeasured bucket from reading as zero use.
cache_totals :: proc(store: ^Store, id: Session_Id) -> (Cache_Totals, Error) {
	if !store.open { return {}, error_make(.Invalid_State, "the store is closed") }

	rows: db.Rows
	if err := db.query(&store.conn, &rows, REQUEST_SELECT_FINISHED_USAGE, {db.Value(string(id))}); err != nil {
		return {}, storage_error("sum request usage", err)
	}
	defer db.rows_close(&rows)

	totals: Cache_Totals
	for {
		values, has_row, next_err := db.rows_next(&rows)
		if next_err != nil { return {}, storage_error("sum request usage", next_err) }
		if !has_row { break }
		usage, usage_err := request_usage_scan(values)
		if usage_err != nil { return {}, usage_err }
		cache_totals_add(&totals, usage)
	}
	return totals, nil
}

// request_load reads one request. Reading does not need the writer claim.
request_load :: proc(store: ^Store, id: Session_Id, request_no: Request_No, allocator := context.allocator) -> (Request, Error) {
	if !store.open { return {}, error_make(.Invalid_State, "the store is closed") }

	rows: db.Rows
	args := [?]db.Value{db.Value(string(id)), db.Value(i64(request_no))}
	if err := db.query(&store.conn, &rows, REQUEST_SELECT_ONE, args[:]); err != nil {
		return {}, storage_error("load request", err)
	}
	defer db.rows_close(&rows)

	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return {}, storage_error("load request", next_err) }
	if !has_row { return {}, error_make(.Not_Found, fmt.tprintf("no request %d exists for that session", i64(request_no))) }
	return request_scan(values, allocator)
}

@(private)
request_scan :: proc(values: []db.Value, allocator: mem.Allocator) -> (request: Request, err: Error) {
	complete := false
	defer if !complete { request_destroy(&request, allocator) }

	request_no, number_err := db.as_i64(values[0])
	if number_err != nil { return {}, corrupt_error("read request number", number_err) }
	purpose_name, purpose_err := db.as_string(values[2])
	if purpose_err != nil { return {}, corrupt_error("read request purpose", purpose_err) }
	outcome_name, outcome_err := db.as_string(values[5])
	if outcome_err != nil { return {}, corrupt_error("read request outcome", outcome_err) }
	started_at_ms, started_err := db.as_i64(values[3])
	if started_err != nil { return {}, corrupt_error("read request start", started_err) }
	finished_at_ms, finished_err := read_optional_i64(values[4])
	if finished_err != nil { return {}, corrupt_error("read request finish", finished_err) }
	turn_no, turn_err := read_optional_i64(values[1])
	if turn_err != nil { return {}, corrupt_error("read request turn", turn_err) }

	purpose, known_purpose := request_purpose_from_name(purpose_name)
	if !known_purpose {
		return {}, error_make(.Corrupt, fmt.tprintf("a stored request has an unknown purpose: %s", purpose_name))
	}
	outcome, known_outcome := outcome_from_name(outcome_name)
	if !known_outcome {
		return {}, error_make(.Corrupt, fmt.tprintf("a stored request has an unknown outcome: %s", outcome_name))
	}

	request.request_no = Request_No(request_no)
	request.purpose = purpose
	request.outcome = outcome
	request.started_at_ms = started_at_ms
	if value, present := finished_at_ms.?; present { request.finished_at_ms = value }
	if value, present := turn_no.?; present { request.turn_no = Turn_No(value) }

	text_fields := [8]struct {
		value:    db.Value,
		optional: bool,
	} {
		{values[6], false}, // provider
		{values[7], false}, // model_requested
		{values[8], true}, // model_resolved
		{values[9], false}, // api
		{values[10], false}, // config_json
		{values[11], false}, // input_json
		{values[12], true}, // response_json
		{values[13], true}, // error_json
	}
	targets := [8]^string {
		&request.provider,
		&request.model_requested,
		&request.model_resolved,
		&request.api,
		&request.config_json,
		&request.input_json,
		&request.response_json,
		&request.error_json,
	}
	for field, i in text_fields {
		if field.value == nil {
			if !field.optional { return {}, error_make(.Corrupt, "a stored request is missing its provider or settings") }
			continue
		}
		text, text_err := db.as_string(field.value)
		if text_err != nil { return {}, corrupt_error("read request text", text_err) }
		targets[i]^ = strings.clone(text, allocator)
	}

	usage_targets := [4]^Maybe(i64){&request.usage.input, &request.usage.output, &request.usage.cache_read, &request.usage.cache_write}
	for value, i in values[14:18] {
		number, usage_err := request_usage_value(value)
		if usage_err != nil { return {}, usage_err }
		usage_targets[i]^ = number
	}
	complete = true
	return request, nil
}

// request_usage_value reads one nullable usage column. A NULL column is a
// measurement the provider never sent; it stays unknown rather than zero.
@(private)
request_usage_value :: proc(value: db.Value) -> (Maybe(i64), Error) {
	number, usage_err := read_optional_i64(value)
	if usage_err != nil { return nil, corrupt_error("read request usage", usage_err) }
	return number, nil
}

// request_usage_scan reads the four usage columns `cache_totals` selects.
// The order is fixed by REQUEST_FINISHED_USAGE_COLUMNS, not by the caller.
@(private)
request_usage_scan :: proc(values: []db.Value) -> (Usage, Error) {
	if len(values) < len(REQUEST_FINISHED_USAGE_COLUMNS) {
		return {}, error_make(.Corrupt, "a stored request is missing its usage")
	}
	usage: Usage
	targets := [4]^Maybe(i64){&usage.input, &usage.output, &usage.cache_read, &usage.cache_write}
	for value, i in values[:len(REQUEST_FINISHED_USAGE_COLUMNS)] {
		number, usage_err := request_usage_value(value)
		if usage_err != nil { return {}, usage_err }
		targets[i]^ = number
	}
	return usage, nil
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
	defer if !committed { abandon_transaction(store) }

	base, base_err := scalar_i64(store, ENTRY_NEXT_SEQ, {db.Value(string(id))})
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
	// The batch and the sequence numbers it is given are this call's own. Releasing them
	// keeps the thread's temp arena to one block across a turn's entries.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
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

	return entries_scan(&rows, false, allocator)
}

// entries_read runs one history query and decodes every row it returns.
@(private)
entries_read :: proc(store: ^Store, sql: string, args: []db.Value, skip_partial_assistant: bool, allocator: mem.Allocator) -> ([]Entry, Error) {
	rows: db.Rows
	if err := db.query(&store.conn, &rows, sql, args); err != nil {
		return nil, storage_error("load history", err)
	}
	defer db.rows_close(&rows)
	return entries_scan(&rows, skip_partial_assistant, allocator)
}

// tool_result_read returns the result stored for one tool call. A result the model
// was shown only a handle for is still in the record in full, so this is what reads
// it back. found is false when the call has no result, which is a different fact
// from a read that failed. The entry is owned by allocator.
tool_result_read :: proc(store: ^Store, id: Session_Id, call_seq: Seq, allocator := context.allocator) -> (entry: Entry, found: bool, err: Error) {
	if call_seq <= 0 { return {}, false, error_make(.Invalid_Argument, "a result read needs the call sequence") }
	rows, read_err := entries_read(store, TOOL_RESULT_SELECT, {db.Value(string(id)), db.Value(i64(call_seq))}, false, allocator)
	if read_err != nil { return {}, false, read_err }
	if len(rows) == 0 {
		delete(rows)
		return {}, false, nil
	}
	// One call has at most one result, so the rest of the slice is released here and
	// the single row is handed to the caller.
	entry = rows[0]
	for row, i in rows {
		if i == 0 { continue }
		remaining := row
		entry_destroy(&remaining, allocator)
	}
	delete(rows)
	return entry, true, nil
}

@(private)
entries_scan :: proc(rows: ^db.Rows, skip_partial_assistant: bool, allocator: mem.Allocator) -> ([]Entry, Error) {
	entries := make([dynamic]Entry, 0, allocator)
	complete := false
	defer if !complete { entries_destroy(entries[:], allocator) }

	for {
		values, has_row, next_err := db.rows_next(rows)
		if next_err != nil { return nil, storage_error("load history", next_err) }
		if !has_row { break }
		entry, scan_err := entry_scan(values, allocator)
		if scan_err != nil { return nil, scan_err }
		if skip_partial_assistant {
			if assistant, is_assistant := entry.payload.(Assistant_Entry); is_assistant && assistant.partial {
				entry_destroy(&entry, allocator)
				continue
			}
		}
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
REQUEST_COLUMNS :: `request_no, turn_no, purpose, started_at_ms, finished_at_ms, status, provider, model_requested, model_resolved, api, config_json, input_json, response_json, error_json, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens`

@(private)
REQUEST_SELECT_ONE :: `SELECT ` + REQUEST_COLUMNS + ` FROM requests WHERE session_id = ? AND request_no = ?`

@(private)
REQUEST_FINISHED_USAGE_COLUMNS :: [?]string{"input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"}

// REQUEST_SELECT_FINISHED_USAGE is the only usage total. It reads finished
// rows, never running ones, so an in-flight request cannot move a reported
// total; finished usage is immutable by construction.
@(private)
REQUEST_SELECT_FINISHED_USAGE :: `SELECT input_tokens, output_tokens, cache_read_tokens, cache_write_tokens FROM requests WHERE session_id = ? AND status <> 'running' ORDER BY request_no`

@(private)
ENTRY_INSERT :: `INSERT INTO entries (session_id, seq, turn_no, request_no, created_at_ms, kind, related_seq, parent_call_seq, payload_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`

@(private)
ENTRY_NEXT_SEQ :: `SELECT COALESCE(MAX(seq), 0) + 1 FROM entries WHERE session_id = ?`

@(private)
ENTRY_COLUMNS :: `seq, turn_no, request_no, created_at_ms, kind, related_seq, parent_call_seq, payload_json`

@(private)
ENTRY_SELECT_RANGE :: `SELECT ` + ENTRY_COLUMNS + ` FROM entries WHERE session_id = ?`

// TOOL_RESULT_SELECT reads the result of one call. The kind is named so a dispatch
// entry, which shares the related sequence, can never be mistaken for a result.
@(private)
TOOL_RESULT_SELECT :: `SELECT ` + ENTRY_COLUMNS + ` FROM entries WHERE session_id = ? AND related_seq = ? AND kind = 'tool_result'`

@(private)
ENTRY_SELECT_KIND :: `SELECT kind, turn_no FROM entries WHERE session_id = ? AND seq = ?`

// --- entry writing ----------------------------------------------------------

@(private)
insert_entry :: proc(store: ^Store, id: Session_Id, seq: Seq, entry: New_Entry) -> Error {
	// The payload's JSON is this write's own: encoded, handed to sqlite, and released here.
	// Releasing it keeps the thread's temp arena to one block for a session's writes instead
	// of a block per entry.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
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
		optional_int_value(entry.parent_call_seq),
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

	if parent, present := entry.parent_call_seq.?; present {
		if kind != .Tool_Call {
			return error_make(.Invalid_Argument, "only a tool call may name a parent call")
		}
		if parent <= 0 || parent >= seq {
			return error_make(.Invalid_Argument, "the parent call must come before the child call")
		}
		turn, has_turn := entry.turn_no.?
		if !has_turn {
			return error_make(.Invalid_Argument, "a child tool call must belong to a turn")
		}
		if err := require_parent_tool_call(store, id, parent, turn); err != nil { return err }
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

@(private)
require_parent_tool_call :: proc(store: ^Store, id: Session_Id, seq: Seq, turn_no: Turn_No) -> Error {
	rows: db.Rows
	args := [?]db.Value{db.Value(string(id)), db.Value(i64(seq))}
	if err := db.query(&store.conn, &rows, ENTRY_SELECT_KIND, args[:]); err != nil {
		return storage_error("read the parent call", err)
	}
	defer db.rows_close(&rows)

	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return storage_error("read the parent call", next_err) }
	if !has_row { return error_make(.Invalid_Argument, "the parent call does not exist") }
	kind, kind_err := db.as_string(values[0])
	if kind_err != nil { return corrupt_error("read the parent call", kind_err) }
	if kind != entry_kind_name(.Tool_Call) {
		return error_make(.Invalid_Argument, "the parent entry is not a tool call")
	}
	parent_turn, turn_err := read_optional_i64(values[1])
	if turn_err != nil { return corrupt_error("read the parent call turn", turn_err) }
	stored_turn, present := parent_turn.?
	if !present || Turn_No(stored_turn) != turn_no {
		return error_make(.Invalid_Argument, "the parent call belongs to another turn")
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
	parent_call_seq, parent_err := read_optional_i64(values[6])
	if parent_err != nil { return {}, corrupt_error("read parent call sequence", parent_err) }
	payload_json, payload_err := db.as_string(values[7])
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
	if value, present := parent_call_seq.?; present { entry.parent_call_seq = Seq(value) }
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

// scalar_i64 runs a query and returns its single integer result.
@(private)
scalar_i64 :: proc(store: ^Store, sql: string, args: []db.Value) -> (i64, Error) {
	rows: db.Rows
	if err := db.query(&store.conn, &rows, sql, args); err != nil {
		return 0, storage_error("read a value", err)
	}
	defer db.rows_close(&rows)
	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return 0, storage_error("read a value", next_err) }
	if !has_row { return 0, error_make(.Corrupt, "a counter query returned no row") }
	number, convert_err := db.as_i64(values[0])
	if convert_err != nil { return 0, corrupt_error("read a value", convert_err) }
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
