package journal

import "base:runtime"
import "nabla:db"

Recovery :: Session_Recovered

// recover records an outcome for all work the claimed session left open when
// its process died, in one transaction, and replays nothing. It records nothing
// when nothing was open, so recovering twice changes nothing. A failure after
// outcomes are staged latches the journal, so none of them is written.
@(require_results)
recover :: proc(journal: ^Journal) -> (recovery: Recovery, error: Error) {
	assert(journal.claimed != {}, "recover needs a claimed session")
	_ = commit(journal) or_return
	defer if error != nil && journal.failure == nil && !error_is_busy(error) { journal.failure = error }
	recover_open_work(journal, &recovery) or_return
	recover_results(journal, &recovery) or_return
	if recovery == {} { return }
	append_record(journal, Record{kind = .Session_Recovered, session = journal.claimed}, recovery)
	_ = commit(journal) or_return
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

@(private, require_results)
recover_open_work :: proc(journal: ^Journal, recovery: ^Recovery) -> (error: Error) {
	rows: db.Rows
	defer _ = db.rows_close(&rows) // The walk to the end released the set; an early return carries its own error.
	db.query(&journal.connection, &rows, RECOVERY_QUERY, {db.Value(journal.claimed[:])}) or_return
	for {
		values, has_row := db.rows_next(&rows) or_return
		if !has_row { break }
		row := Row {
			values = values,
		}
		rule := Recovery_Rule(row_int(&row))
		header := Record {
			session = journal.claimed,
		}
		header.branch = Branch_Id(row_int(&row))
		header.node = Node_Id(row_int(&row))
		header.turn = Turn_Id(row_int(&row))
		header.request = Request_Id(row_int(&row))
		header.attempt = Attempt_No(row_int(&row))
		header.job = Job_Id(row_int(&row))
		header.call = Call_Id(row_int(&row))
		header.parent_call = Call_Id(row_int(&row))
		header.subagent = Session_Id(row_id(&row))
		if row.error != nil || rule > max(Recovery_Rule) { return corrupt(journal, Journal_Error.Corrupt, journal.claimed, 0) }

		unknown := Call_Completed {
			outcome = TOOL_OUTCOME_NAMES[.Unknown],
			detail  = "the session ended before this call reported a result; it may have taken effect",
		}
		switch rule {
		case .Turn:
			header.kind = .Turn_Completed
			append_record(journal, header, Turn_Completed{outcome = TURN_OUTCOME_NAMES[.Interrupted], detail = "the process ended during the turn"})
			recovery.turns += 1
		case .Request:
			header.kind = .Request_Interrupted
			append_record(journal, header, Request_Interrupted{detail = "the request was sent and its outcome is unknown"})
			recovery.requests += 1
		case .Proposed_Call:
			header.kind = .Tool_Completed
			append_record(
				journal,
				header,
				Tool_Completed{outcome = TOOL_OUTCOME_NAMES[.Not_Executed], detail = "the session ended before this call ran; it did not run"},
			)
			recovery.calls += 1
		case .Admitted_Call:
			header.kind = .Tool_Completed
			append_record(journal, header, unknown)
			recovery.calls += 1
		case .Lua:
			header.kind = .Lua_Completed
			append_record(journal, header, unknown)
			recovery.calls += 1
		case .Task:
			header.kind = .Task_Completed
			append_record(journal, header, unknown)
			recovery.calls += 1
		case .Subagent:
			header.kind = .Subagent_Completed
			append_record(journal, header, unknown)
			recovery.calls += 1
		}
	}
	return journal.failure
}

// recover_results gives each Assistant node whose proposed calls have no
// Results node one, listing the calls in proposal order.
@(private, require_results)
recover_results :: proc(journal: ^Journal, recovery: ^Recovery) -> (error: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	rows: db.Rows
	defer _ = db.rows_close(&rows) // The walk to the end released the set; an early return carries its own error.
	db.query(&journal.connection, &rows, UNANSWERED_CALLS_QUERY, {db.Value(journal.claimed[:])}) or_return

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
				session = journal.claimed,
				parent  = assistant.id,
				branch  = assistant.branch,
				kind    = .Results,
				turn    = assistant.turn,
			}
			// The node id is not needed here; a failure latches and is returned below.
			_ = append_node(journal, results, Results{calls = calls[:]})
			recovery.results += 1
			clear(&calls)
		}
		if !has_row { break }
		assistant.id = node
		assistant.branch = Branch_Id(row_int(&row))
		assistant.turn = Turn_Id(row_int(&row))
		call := Call_Id(row_int(&row))
		if row.error != nil { return corrupt(journal, row.error, journal.claimed, 0) }
		_, append_error := append(&calls, call)
		if append_error != nil { return append_error }
	}
	return journal.failure
}

// Each rule finds work whose closing record is missing, so a second recovery
// finds nothing.
@(private)
RECOVERY_QUERY :: `SELECT rule, branch, node, turn, request, attempt, job, call, parent_call, subagent FROM (
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
