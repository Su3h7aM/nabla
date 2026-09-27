package journal

import "base:runtime"
import "nabla:db"

Recovery :: Session_Recovered

// recover records an outcome for all work the claimed session left open when
// its process died, in one transaction, and replays nothing. It records nothing
// when nothing was open, so recovering twice changes nothing.
@(require_results)
recover :: proc(j: ^Journal) -> (recovery: Recovery, err: Error) {
	assert(j.claimed != {}, "recover needs a claimed session")
	_ = commit(j) or_return
	recover_open_work(j, &recovery) or_return
	recover_results(j, &recovery) or_return
	if recovery == {} { return }
	append_record(j, Record{kind = .Session_Recovered, session = j.claimed}, recovery)
	_ = commit(j) or_return
	return
}

// Recovery_Rule is the first column of RECOVERY_QUERY, in this order.
@(private)
Recovery_Rule :: enum {
	Turn,
	Request,
	Proposed_Call,
	Admitted_Call,
	Lua,
	Task,
	Subagent,
}

@(private)
recover_open_work :: proc(j: ^Journal, recovery: ^Recovery) -> (err: Error) {
	rows: db.Rows
	defer db.rows_close(&rows)
	db.query(&j.conn, &rows, RECOVERY_QUERY, {db.Value(j.claimed[:])}) or_return
	for {
		values, has_row := db.rows_next(&rows) or_return
		if !has_row { break }
		row := Row {
			values = values,
		}
		rule := Recovery_Rule(row_int(&row))
		header := Record {
			session = j.claimed,
		}
		header.branch = Branch_Id(row_int(&row))
		header.node = Node_Id(row_int(&row))
		header.turn = Turn_Id(row_int(&row))
		header.request = Request_Id(row_int(&row))
		header.attempt = Attempt_No(row_int(&row))
		header.job = Job_Id(row_int(&row))
		header.call = Call_Id(row_int(&row))
		header.parent_call = Call_Id(row_int(&row))
		if row.err != nil || rule > max(Recovery_Rule) { return corrupt(j, Journal_Error.Corrupt, j.claimed, 0) }

		unknown := Call_Completed {
			outcome = TOOL_OUTCOME_NAMES[.Unknown],
			detail  = "execution may have happened",
		}
		switch rule {
		case .Turn:
			header.kind = .Turn_Completed
			append_record(j, header, Turn_Completed{outcome = TURN_OUTCOME_NAMES[.Interrupted], detail = "the process ended during the turn"})
			recovery.turns += 1
		case .Request:
			header.kind = .Request_Interrupted
			append_record(j, header, Request_Interrupted{detail = "the request was sent and its outcome is unknown"})
			recovery.requests += 1
		case .Proposed_Call:
			header.kind = .Tool_Completed
			append_record(j, header, Tool_Completed{outcome = TOOL_OUTCOME_NAMES[.Not_Executed], detail = "the call was never admitted"})
			recovery.calls += 1
		case .Admitted_Call:
			header.kind = .Tool_Completed
			append_record(j, header, unknown)
			recovery.calls += 1
		case .Lua:
			header.kind = .Lua_Completed
			append_record(j, header, unknown)
			recovery.calls += 1
		case .Task:
			header.kind = .Task_Completed
			append_record(j, header, unknown)
			recovery.calls += 1
		case .Subagent:
			header.kind = .Subagent_Completed
			append_record(j, header, unknown)
			recovery.calls += 1
		}
	}
	return j.failure
}

// recover_results gives each Assistant node whose proposed calls have no
// Results node one, listing the calls in proposal order.
@(private)
recover_results :: proc(j: ^Journal, recovery: ^Recovery) -> (err: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	rows: db.Rows
	defer db.rows_close(&rows)
	db.query(&j.conn, &rows, UNANSWERED_CALLS_QUERY, {db.Value(j.claimed[:])}) or_return

	calls := make([dynamic]Call_Id, context.temp_allocator) or_return
	assistant: Node
	for {
		values, has_row := db.rows_next(&rows) or_return
		row := Row {
			values = values,
		}
		node := Node_Id(0)
		if has_row { node = Node_Id(row_int(&row)) }
		if node != assistant.id && len(calls) > 0 {
			results := Node {
				session = j.claimed,
				parent  = assistant.id,
				branch  = assistant.branch,
				kind    = .Results,
				turn    = assistant.turn,
			}
			_ = append_node(j, results, Results{calls = calls[:]})
			recovery.results += 1
			clear(&calls)
		}
		if !has_row { break }
		assistant.id = node
		assistant.branch = Branch_Id(row_int(&row))
		assistant.turn = Turn_Id(row_int(&row))
		call := Call_Id(row_int(&row))
		if row.err != nil { return corrupt(j, row.err, j.claimed, 0) }
		_, append_err := append(&calls, call)
		if append_err != nil { return append_err }
	}
	return j.failure
}

// Each rule finds work whose closing record is missing, so a second recovery
// finds nothing.
@(private)
RECOVERY_QUERY :: `SELECT rule, branch, node, turn, request, attempt, job, call, parent_call FROM (
	SELECT 0 AS rule, * FROM records AS open WHERE session = ?1 AND kind = 'turn.started'
		AND NOT EXISTS (SELECT 1 FROM records WHERE session = ?1 AND turn = open.turn AND kind = 'turn.completed')
	UNION ALL
	SELECT 1, * FROM records AS open WHERE session = ?1 AND kind = 'request.sent'
		AND NOT EXISTS (SELECT 1 FROM records WHERE session = ?1 AND request = open.request AND attempt IS open.attempt
			AND kind IN ('response.committed', 'response.rejected', 'request.interrupted'))
	UNION ALL
	SELECT 2, * FROM records AS open WHERE session = ?1 AND kind = 'tool.proposed'
		AND NOT EXISTS (SELECT 1 FROM records WHERE session = ?1 AND call = open.call AND kind IN ('tool.admitted', 'tool.completed'))
	UNION ALL
	SELECT 3, * FROM records AS open WHERE session = ?1 AND kind = 'tool.admitted'
		AND NOT EXISTS (SELECT 1 FROM records WHERE session = ?1 AND call = open.call AND kind = 'tool.completed')
	UNION ALL
	SELECT CASE kind WHEN 'lua.started' THEN 4 WHEN 'task.started' THEN 5 ELSE 6 END, *
		FROM records AS open WHERE session = ?1 AND kind IN ('lua.started', 'task.started', 'subagent.started')
		AND NOT EXISTS (SELECT 1 FROM records WHERE session = ?1 AND call = open.call
			AND kind IN ('lua.completed', 'task.completed', 'subagent.completed'))
) ORDER BY seq`

@(private)
UNANSWERED_CALLS_QUERY :: `SELECT assistant.node, assistant.branch, assistant.turn, proposed.call
FROM nodes AS assistant
JOIN records AS proposed ON proposed.session = ?1 AND proposed.node = assistant.node AND proposed.kind = 'tool.proposed'
WHERE assistant.session = ?1 AND assistant.kind = 'assistant'
	AND NOT EXISTS (SELECT 1 FROM nodes WHERE session = ?1 AND parent = assistant.node AND kind = 'results')
ORDER BY assistant.node, proposed.seq`
