package journal

import "core:mem"

import "nabla:db"

// Recovery is what recover had to record, and also the payload of the
// `session.recovered` record it writes.
Recovery :: Session_Recovered

// The details of the outcomes recovery records. Each one says what was found,
// so a reader of the journal can tell an interrupted turn from a refused one
// without guessing.
@(private)
INTERRUPTED_TURN_DETAIL :: "the process ended before the turn finished"
@(private)
INTERRUPTED_REQUEST_DETAIL :: "the request was sent and its outcome was never recorded"
@(private)
NOT_ADMITTED_DETAIL :: "the call was proposed and never admitted, so it did not run"
@(private)
ADMITTED_DETAIL :: "execution may have happened"
@(private)
STARTED_DETAIL :: "the execution started and its outcome was never recorded; it may have happened"

// recover closes the work the claimed session left open when the process died,
// in one transaction, and returns what it recorded.
//
// It reconstructs history, not stacks: a turn that has no completion ends as
// Interrupted, a request that was sent is never resent, a call that was
// admitted and has no result is Unknown, and a delegated execution that started
// and has no completion is Unknown. An Assistant node whose calls have no
// Results node gets one, naming the calls in the order they were proposed.
// Nothing is replayed.
//
// When there was nothing to recover, recover records nothing at all, so a
// second call after a clean shutdown leaves the journal exactly as it was.
@(require_results)
recover :: proc(j: ^Journal) -> (Recovery, Error) {
	if !j.open { return {}, Journal_Error.Invalid_State }
	if j.failure != nil { return {}, j.failure }
	if session_id_is_absent(j.claimed) { return {}, Journal_Error.Not_Claimed }
	session := j.claimed

	// Recovery reads what is durable, so anything still buffered is written
	// first.
	if _, commit_err := commit(j); commit_err != nil { return {}, commit_err }

	recovery: Recovery
	turns, turns_err := recover_turns(j, session)
	if turns_err != nil { return {}, turns_err }
	recovery.turns = turns

	requests, requests_err := recover_requests(j, session)
	if requests_err != nil { return {}, requests_err }
	recovery.requests = requests

	tools, tools_err := recover_tools(j, session)
	if tools_err != nil { return {}, tools_err }
	recovery.tools = tools

	effects, effects_err := recover_effects(j, session)
	if effects_err != nil { return {}, effects_err }
	recovery.effects = effects

	results, results_err := recover_results(j, session)
	if results_err != nil { return {}, results_err }
	recovery.results = results

	if recovery.turns == 0 && recovery.requests == 0 && recovery.tools == 0 && recovery.effects == 0 && recovery.results == 0 {
		// A session that was closed cleanly has nothing to say, and a record of
		// having recovered nothing would be noise in every later reading.
		return recovery, nil
	}

	append_record(j, Record{session = session, kind = .Session_Recovered}, recovery)
	if j.failure != nil { return {}, j.failure }
	if _, commit_err := commit(j); commit_err != nil { return {}, commit_err }
	return recovery, nil
}

// recover_turns closes every turn that started and never ended.
@(private)
recover_turns :: proc(j: ^Journal, session: Session_Id) -> (int, Error) {
	owner := session
	rows: db.Rows
	if err := db.query(&j.conn, &rows, TURN_RECOVERY_QUERY, {db.Value(owner[:])}); err != nil { return 0, err }
	defer db.rows_close(&rows)

	count := 0
	for {
		values, has_row, next_err := db.rows_next(&rows)
		if next_err != nil { return count, next_err }
		if !has_row { break }
		turn, turn_ok := optional_id(values[0])
		if !turn_ok { return count, corrupt_row(j, session, 0) }
		append_record(
			j,
			Record{session = session, turn = Turn_Id(turn), kind = .Turn_Completed},
			Turn_Completed{outcome = TURN_OUTCOME_NAMES[.Interrupted], detail = INTERRUPTED_TURN_DETAIL},
		)
		if j.failure != nil { return count, j.failure }
		count += 1
	}
	return count, nil
}

// recover_requests closes every request that was sent and never settled. A
// request that may have reached the provider is never sent again.
@(private)
recover_requests :: proc(j: ^Journal, session: Session_Id) -> (int, Error) {
	owner := session
	rows: db.Rows
	if err := db.query(&j.conn, &rows, REQUEST_RECOVERY_QUERY, {db.Value(owner[:])}); err != nil { return 0, err }
	defer db.rows_close(&rows)

	count := 0
	for {
		values, has_row, next_err := db.rows_next(&rows)
		if next_err != nil { return count, next_err }
		if !has_row { break }
		turn, turn_ok := optional_id(values[0])
		if !turn_ok { return count, corrupt_row(j, session, 0) }
		request, request_ok := optional_id(values[1])
		if !request_ok { return count, corrupt_row(j, session, 0) }
		append_record(
			j,
			Record{session = session, turn = Turn_Id(turn), request = Request_Id(request), kind = .Request_Interrupted},
			Request_Interrupted{detail = INTERRUPTED_REQUEST_DETAIL},
		)
		if j.failure != nil { return count, j.failure }
		count += 1
	}
	return count, nil
}

// recover_tools closes every call that was proposed and never admitted, and
// every call that was admitted and never completed. A call that already has a
// completion is left alone, so recovery records each call once.
@(private)
recover_tools :: proc(j: ^Journal, session: Session_Id) -> (int, Error) {
	proposed, proposed_err := recover_tool_rule(j, session, PROPOSED_RECOVERY_QUERY, .Not_Executed, NOT_ADMITTED_DETAIL)
	if proposed_err != nil { return proposed, proposed_err }
	admitted, admitted_err := recover_tool_rule(j, session, ADMITTED_RECOVERY_QUERY, .Unknown, ADMITTED_DETAIL)
	return proposed + admitted, admitted_err
}

@(private)
recover_tool_rule :: proc(j: ^Journal, session: Session_Id, query: string, outcome: Tool_Outcome, detail: string) -> (int, Error) {
	owner := session
	rows: db.Rows
	if err := db.query(&j.conn, &rows, query, {db.Value(owner[:])}); err != nil { return 0, err }
	defer db.rows_close(&rows)

	count := 0
	for {
		values, has_row, next_err := db.rows_next(&rows)
		if next_err != nil { return count, next_err }
		if !has_row { break }
		source, source_ok := scan_recovery_source(values)
		if !source_ok { return count, corrupt_row(j, session, 0) }
		append_record(j, recovery_header(session, source, .Tool_Completed), Tool_Completed{outcome = TOOL_OUTCOME_NAMES[outcome], detail = detail})
		if j.failure != nil { return count, j.failure }
		count += 1
	}
	return count, nil
}

// recover_effects closes every Lua execution, Task, and subagent that started
// and never completed. A script is never resumed, and an execution that may
// have run is never replayed.
@(private)
recover_effects :: proc(j: ^Journal, session: Session_Id) -> (int, Error) {
	owner := session
	rows: db.Rows
	if err := db.query(&j.conn, &rows, EFFECT_RECOVERY_QUERY, {db.Value(owner[:])}); err != nil { return 0, err }
	defer db.rows_close(&rows)

	count := 0
	for {
		values, has_row, next_err := db.rows_next(&rows)
		if next_err != nil { return count, next_err }
		if !has_row { break }
		started_name, started_err := db.as_string(values[0])
		if started_err != nil { return count, corrupt_row(j, session, 0) }
		started, started_ok := record_kind_from_name(started_name)
		if !started_ok { return count, corrupt_row(j, session, 0) }
		kind, kind_ok := completed_kind(started)
		if !kind_ok { return count, corrupt_row(j, session, 0) }
		source, source_ok := scan_recovery_source(values[1:])
		if !source_ok { return count, corrupt_row(j, session, 0) }

		append_record(j, recovery_header(session, source, kind), Call_Completed{outcome = TOOL_OUTCOME_NAMES[.Unknown], detail = STARTED_DETAIL})
		if j.failure != nil { return count, j.failure }
		count += 1
	}
	return count, nil
}

// recover_results gives every Assistant node whose calls were proposed a
// Results node, unless it already has one. The calls are listed in the order
// the node proposed them.
@(private)
recover_results :: proc(j: ^Journal, session: Session_Id) -> (int, Error) {
	// A connection runs one result set at a time, so the nodes are collected
	// before the calls of any one of them are read.
	nodes := make([dynamic]Results_Node, 0, 8, context.temp_allocator)
	if node_err := collect_results_nodes(j, session, &nodes); node_err != nil { return 0, node_err }

	calls := make([dynamic]Call_Id, 0, 8, context.temp_allocator)
	count := 0
	for node in nodes {
		clear(&calls)
		if call_err := read_proposed_calls(j, session, node.node, &calls); call_err != nil { return count, call_err }

		_ = append_node(j, Node{session = session, parent = node.node, branch = node.branch, kind = .Results, turn = node.turn}, Results{calls = calls[:]})
		if j.failure != nil { return count, j.failure }
		count += 1
	}
	return count, nil
}

// Results_Node is one Assistant node that still needs a Results node.
@(private)
Results_Node :: struct {
	node:   Node_Id,
	branch: Branch_Id,
	turn:   Turn_Id,
}

// collect_results_nodes reads the Assistant nodes of a session whose calls were
// proposed and that have no Results node of their own.
@(private)
collect_results_nodes :: proc(j: ^Journal, session: Session_Id, nodes: ^[dynamic]Results_Node) -> Error {
	owner := session
	rows: db.Rows
	if err := db.query(&j.conn, &rows, RESULTS_RECOVERY_QUERY, {db.Value(owner[:])}); err != nil { return err }
	defer db.rows_close(&rows)

	for {
		values, has_row, next_err := db.rows_next(&rows)
		if next_err != nil { return next_err }
		if !has_row { break }
		node, node_ok := optional_id(values[0])
		if !node_ok { return corrupt_row(j, session, 0) }
		branch, branch_ok := optional_id(values[1])
		if !branch_ok { return corrupt_row(j, session, 0) }
		turn, turn_ok := optional_id(values[2])
		if !turn_ok { return corrupt_row(j, session, 0) }

		appended, append_err := append(nodes, Results_Node{node = Node_Id(node), branch = Branch_Id(branch), turn = Turn_Id(turn)})
		if append_err != nil { return append_err }
		if appended != 1 { return mem.Allocator_Error.Out_Of_Memory }
	}
	return nil
}

// read_proposed_calls collects the calls one node proposed, in the order it
// proposed them.
@(private)
read_proposed_calls :: proc(j: ^Journal, session: Session_Id, node: Node_Id, calls: ^[dynamic]Call_Id) -> Error {
	owner := session
	rows: db.Rows
	if err := db.query(&j.conn, &rows, PROPOSED_CALLS_QUERY, {db.Value(owner[:]), db.Value(i64(node))}); err != nil {
		return err
	}
	defer db.rows_close(&rows)

	for {
		values, has_row, next_err := db.rows_next(&rows)
		if next_err != nil { return next_err }
		if !has_row { break }
		call, call_err := db.as_i64(values[0])
		if call_err != nil { return corrupt_row(j, session, 0) }
		appended, append_err := append(calls, Call_Id(call))
		if append_err != nil { return append_err }
		if appended != 1 { return mem.Allocator_Error.Out_Of_Memory }
	}
	return nil
}

// Recovery_Source is the correlation a recovery rule copies from the record
// that did not finish into the record that closes it. The task string is
// borrowed from the row being read, so it is only valid until the next step.
@(private)
Recovery_Source :: struct {
	branch:      Branch_Id,
	node:        Node_Id,
	turn:        Turn_Id,
	request:     Request_Id,
	attempt:     Attempt_No,
	job:         Job_Id,
	call:        Call_Id,
	parent_call: Call_Id,
	task:        string,
	subagent:    Session_Id,
}

@(private)
scan_recovery_source :: proc(values: []db.Value) -> (source: Recovery_Source, ok: bool) {
	branch, branch_ok := optional_id(values[0])
	if !branch_ok { return {}, false }
	node, node_ok := optional_id(values[1])
	if !node_ok { return {}, false }
	turn, turn_ok := optional_id(values[2])
	if !turn_ok { return {}, false }
	request, request_ok := optional_id(values[3])
	if !request_ok { return {}, false }
	attempt, attempt_ok := optional_id(values[4])
	if !attempt_ok { return {}, false }
	job, job_ok := optional_id(values[5])
	if !job_ok { return {}, false }
	call, call_ok := optional_id(values[6])
	if !call_ok { return {}, false }
	parent_call, parent_ok := optional_id(values[7])
	if !parent_ok { return {}, false }
	task := ""
	if values[8] != nil {
		text, text_err := db.as_string(values[8])
		if text_err != nil { return {}, false }
		task = text
	}
	subagent, subagent_ok := read_session_id(values[9])
	if !subagent_ok { return {}, false }

	return Recovery_Source {
			branch = Branch_Id(branch),
			node = Node_Id(node),
			turn = Turn_Id(turn),
			request = Request_Id(request),
			attempt = Attempt_No(attempt),
			job = Job_Id(job),
			call = Call_Id(call),
			parent_call = Call_Id(parent_call),
			task = task,
			subagent = subagent,
		},
		true
}

// recovery_header is the correlation of a record that closes work: the session,
// and every column the record it closes carried.
@(private)
recovery_header :: proc(session: Session_Id, source: Recovery_Source, kind: Record_Kind) -> Record {
	return Record {
		session = session,
		kind = kind,
		branch = source.branch,
		node = source.node,
		turn = source.turn,
		request = source.request,
		attempt = source.attempt,
		job = source.job,
		call = source.call,
		parent_call = source.parent_call,
		task = source.task,
		subagent = source.subagent,
	}
}

// completed_kind is the record kind that ends a delegated execution.
@(private)
completed_kind :: proc(started: Record_Kind) -> (Record_Kind, bool) {
	// The query lists only the three kinds an execution starts with, so every
	// other record kind is refused rather than named here.
	#partial switch started {
	case .Lua_Started:
		return .Lua_Completed, true
	case .Task_Started:
		return .Task_Completed, true
	case .Subagent_Started:
		return .Subagent_Completed, true
	case:
	}
	return {}, false
}

// Every rule looks for the work that has no record closing it. A settled record
// of the matching kind is what makes a second recovery find nothing.
@(private)
TURN_RECOVERY_QUERY :: `SELECT DISTINCT turn FROM records
WHERE session = ? AND kind = 'turn.started' AND turn IS NOT NULL
	AND NOT EXISTS (SELECT 1 FROM records AS settled WHERE settled.session = records.session AND settled.kind = 'turn.completed' AND settled.turn = records.turn)`

@(private)
REQUEST_RECOVERY_QUERY :: `SELECT turn, request FROM records
WHERE session = ? AND kind = 'request.sent' AND request IS NOT NULL
	AND NOT EXISTS (SELECT 1 FROM records AS settled WHERE settled.session = records.session AND settled.request = records.request AND settled.kind IN ('response.committed', 'response.rejected', 'request.interrupted'))`

@(private)
PROPOSED_RECOVERY_QUERY :: `SELECT branch, node, turn, request, attempt, job, call, parent_call, task, subagent FROM records
WHERE session = ? AND kind = 'tool.proposed' AND call IS NOT NULL
	AND NOT EXISTS (SELECT 1 FROM records AS settled WHERE settled.session = records.session AND settled.call = records.call AND settled.kind IN ('tool.admitted', 'tool.completed'))`

@(private)
ADMITTED_RECOVERY_QUERY :: `SELECT branch, node, turn, request, attempt, job, call, parent_call, task, subagent FROM records
WHERE session = ? AND kind = 'tool.admitted' AND call IS NOT NULL
	AND NOT EXISTS (SELECT 1 FROM records AS settled WHERE settled.session = records.session AND settled.call = records.call AND settled.kind = 'tool.completed')`

@(private)
EFFECT_RECOVERY_QUERY :: `SELECT kind, branch, node, turn, request, attempt, job, call, parent_call, task, subagent FROM records
WHERE session = ? AND kind IN ('lua.started', 'task.started', 'subagent.started') AND call IS NOT NULL
	AND NOT EXISTS (SELECT 1 FROM records AS settled WHERE settled.session = records.session AND settled.call = records.call AND settled.kind IN ('lua.completed', 'task.completed', 'subagent.completed'))`

@(private)
RESULTS_RECOVERY_QUERY :: `SELECT assistant.node, assistant.branch, assistant.turn FROM nodes AS assistant
WHERE assistant.session = ? AND assistant.kind = 'assistant'
	AND EXISTS (SELECT 1 FROM records WHERE records.session = assistant.session AND records.node = assistant.node AND records.kind = 'tool.proposed')
	AND NOT EXISTS (SELECT 1 FROM nodes AS done WHERE done.session = assistant.session AND done.parent = assistant.node AND done.kind = 'results')`

@(private)
PROPOSED_CALLS_QUERY :: `SELECT call FROM records
WHERE session = ? AND node = ? AND kind = 'tool.proposed' AND call IS NOT NULL
ORDER BY seq ASC`
