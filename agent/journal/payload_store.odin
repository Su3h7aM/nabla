package journal

import "base:intrinsics"
import "core:mem"
import "core:mem/virtual"

import "nabla:db"

// Payload_Row is one family-table insert buffered after the record it belongs to.
// arguments[0] is that record's seq, set at commit. Its text and bytes are owned
// by the batch arena.
@(private)
Payload_Row :: struct {
	sql:       string,
	arguments: []db.Value,
}

// payload_push buffers the family rows of a payload that has a table. A payload
// that is still JSON-only buffers nothing.
@(private)
payload_push :: proc(journal: ^Journal, data: $Payload) {
	when intrinsics.type_is_variant_of(Record_Payload, Payload) {
		payload_rows(journal, data)
	}
}

// payload_row buffers one insert whose first column is the record's seq and whose
// other columns are values. It copies text and bytes into the batch arena.
@(private)
payload_row :: proc(journal: ^Journal, sql: string, values: ..db.Value) {
	if journal.failure != nil { return }
	arguments, error := make([]db.Value, len(values) + 1, virtual.arena_allocator(&journal.batch))
	if error != nil {
		latch(journal, error)
		return
	}
	for value, index in values {
		arguments[index + 1] = value
		#partial switch member in value {
		case string:
			arguments[index + 1] = batch_text(journal, member)
		case []u8:
			arguments[index + 1] = batch_bytes(journal, member)
		}
	}
	push(journal, Payload_Row{sql = sql, arguments = arguments})
}

@(private)
int_value :: proc(value: $Integer) -> db.Value {
	return db.Value(i64(value))
}

@(private)
maybe_int :: proc(value: Maybe(i64)) -> db.Value {
	if number, present := value.?; present { return db.Value(number) }
	return nil
}

@(private)
maybe_real :: proc(value: Maybe(f64)) -> db.Value {
	if number, present := value.?; present { return db.Value(number) }
	return nil
}

// name_code is the stored code of a name in an enum's name table. An unknown name
// latches the journal as Corrupt: the writer built a payload no table can hold.
@(private)
name_code :: proc(journal: ^Journal, names: [$Enum]string, name: string) -> db.Value {
	code, found := enum_from_name(names, name)
	if !found && journal.failure == nil { latch(journal, Journal_Error.Corrupt) }
	return db.Value(i64(code))
}

// digest_value is the 32 bytes of a hexadecimal digest, NULL for "". The bytes are
// owned by the batch arena.
@(private)
digest_value :: proc(journal: ^Journal, hex: string) -> db.Value {
	if hex == "" { return nil }
	digest, ok := digest_from_hex(hex)
	if !ok {
		if journal.failure == nil { latch(journal, Journal_Error.Corrupt) }
		return nil
	}
	return db.Value(batch_bytes(journal, digest[:]))
}

// usage_values is the six Attempt_Usage columns of any payload that embeds it.
@(private)
usage_values :: proc(payload: $Payload) -> [6]db.Value {
	return {
		maybe_int(payload.input_tokens),
		maybe_int(payload.output_tokens),
		maybe_int(payload.reasoning_tokens),
		maybe_int(payload.cache_read_tokens),
		maybe_int(payload.cache_write_tokens),
		maybe_real(payload.cost),
	}
}

@(private)
attachment_rows :: proc(journal: ^Journal, attachments: []Attachment) {
	for attachment, index in attachments {
		payload_row(
			journal,
			"INSERT INTO record_attachment (seq, ordinal, media_type, name, digest) VALUES (?, ?, ?, ?, ?)",
			int_value(index),
			attachment.media_type,
			attachment.name,
			digest_value(journal, attachment.digest),
		)
	}
}

@(private)
payload_rows :: proc(journal: ^Journal, payload: Record_Payload) {
	switch value in payload {
	case Session_Titled:
	// record_session_titled has its own pending row.
	case Run_Started:
		payload_row(journal, "INSERT INTO record_run_started (seq, pid) VALUES (?, ?)", int_value(value.pid))
	case Session_Recovered:
		payload_row(
			journal,
			"INSERT INTO record_session_recovered (seq, turns, requests, calls, results) VALUES (?, ?, ?, ?, ?)",
			int_value(value.turns),
			int_value(value.requests),
			int_value(value.calls),
			int_value(value.results),
		)
	case Session_Claimed:
		payload_row(journal, "INSERT INTO record_session_claimed (seq, resumed) VALUES (?, ?)", value.resumed)
	case Session_Environment:
		payload_row(journal, "INSERT INTO record_environment (seq, instructions) VALUES (?, ?)", text_or_null(value.instructions))
		for server, index in value.servers {
			payload_row(
				journal,
				`INSERT INTO record_environment_server (seq, ordinal, id, executable, working_directory, discovery_timeout_ms, call_timeout_ms)
				VALUES (?, ?, ?, ?, ?, ?, ?)`,
				int_value(index),
				server.id,
				server.executable,
				text_or_null(server.working_directory),
				server.discovery_timeout_ms,
				server.call_timeout_ms,
			)
			for argument, argument_index in server.arguments {
				payload_row(
					journal,
					"INSERT INTO record_environment_argument (seq, server_ordinal, ordinal, argument) VALUES (?, ?, ?, ?)",
					int_value(index),
					int_value(argument_index),
					argument,
				)
			}
			for variable, variable_index in server.environment {
				payload_row(
					journal,
					"INSERT INTO record_environment_variable (seq, server_ordinal, ordinal, name, value) VALUES (?, ?, ?, ?, ?)",
					int_value(index),
					int_value(variable_index),
					variable.name,
					text_or_null(variable.value),
				)
			}
			for tool, tool_index in server.tools {
				payload_row(
					journal,
					"INSERT INTO record_environment_tool (seq, server_ordinal, ordinal, remote_name, name, enabled) VALUES (?, ?, ?, ?, ?, ?)",
					int_value(index),
					int_value(tool_index),
					tool.remote_name,
					text_or_null(tool.name),
					tool.enabled,
				)
			}
		}
	case User_Input:
		payload_row(journal, "INSERT INTO record_user_input (seq, origin) VALUES (?, ?)", name_code(journal, USER_ORIGIN_NAMES, value.origin))
		attachment_rows(journal, value.attachments)
	case User_Command:
		payload_row(
			journal,
			"INSERT INTO record_user_command (seq, kind, provider, model, level) VALUES (?, ?, ?, ?, ?)",
			name_code(journal, COMMAND_KIND_NAMES, value.kind),
			text_or_null(value.provider),
			text_or_null(value.model),
			text_or_null(value.level),
		)
	case Command_Applied:
		payload_row(
			journal,
			"INSERT INTO record_command_applied (seq, command, outcome, reason) VALUES (?, ?, ?, ?)",
			int_value(value.command),
			name_code(journal, COMMAND_OUTCOME_NAMES, value.outcome),
			text_or_null(value.reason),
		)
	case Turn_Started:
		payload_row(
			journal,
			"INSERT INTO record_turn_started (seq, instructions, manifest, effort) VALUES (?, ?, ?, ?)",
			digest_value(journal, value.instructions),
			digest_value(journal, value.manifest),
			text_or_null(value.effort),
		)
	case Turn_Completed:
		payload_row(
			journal,
			"INSERT INTO record_turn_completed (seq, outcome, detail, reason, cause) VALUES (?, ?, ?, ?, ?)",
			name_code(journal, TURN_OUTCOME_NAMES, value.outcome),
			text_or_null(value.detail),
			text_or_null(value.reason),
			text_or_null(value.cause),
		)
	case Request_Prepared:
		payload_row(
			journal,
			`INSERT INTO record_request_prepared (seq, purpose, api, transport, estimate, context_window, messages, tools, replay_refused)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			name_code(journal, REQUEST_PURPOSE_NAMES, value.purpose),
			text_or_null(value.api),
			text_or_null(value.transport),
			int_value(value.estimate),
			int_value(value.context_window),
			int_value(value.messages),
			int_value(value.tools),
			int_value(value.replay_refused),
		)
	case Request_Admitted:
		payload_row(
			journal,
			`INSERT INTO record_request_admitted
			(seq, decision, estimate, context_window, instructions_tokens, tools_tokens, conversation_tokens) VALUES (?, ?, ?, ?, ?, ?, ?)`,
			name_code(journal, ADMISSION_DECISION_NAMES, value.decision),
			int_value(value.estimate),
			int_value(value.context_window),
			int_value(value.instructions_tokens),
			int_value(value.tools_tokens),
			int_value(value.conversation_tokens),
		)
	case Request_Sent:
		payload_row(
			journal,
			"INSERT INTO record_request_sent (seq, purpose, api, recovery, body_digest, body_bytes) VALUES (?, ?, ?, ?, ?, ?)",
			name_code(journal, REQUEST_PURPOSE_NAMES, value.purpose),
			text_or_null(value.api),
			text_or_null(value.recovery),
			digest_value(journal, value.body_digest),
			int_value(value.body_bytes),
		)
	case Request_Interrupted:
		usage := usage_values(value)
		payload_row(
			journal,
			`INSERT INTO record_request_interrupted
			(seq, detail, input_tokens, output_tokens, reasoning_tokens, cache_read_tokens, cache_write_tokens, cost) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			text_or_null(value.detail),
			usage[0],
			usage[1],
			usage[2],
			usage[3],
			usage[4],
			usage[5],
		)
	case Response_Committed:
		usage := usage_values(value)
		payload_row(
			journal,
			`INSERT INTO record_response
			(seq, api, model_resolved, finish, input_tokens, output_tokens, reasoning_tokens, cache_read_tokens, cache_write_tokens, cost)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			text_or_null(value.api),
			text_or_null(value.model_resolved),
			name_code(journal, RESPONSE_FINISH_NAMES, value.finish),
			usage[0],
			usage[1],
			usage[2],
			usage[3],
			usage[4],
			usage[5],
		)
	case Response_Rejected:
		usage := usage_values(value)
		payload_row(
			journal,
			`INSERT INTO record_response_rejected
			(seq, kind, failure_class, status, provider_code, provider_request_id, retry_after_ms, retry_directive, transport_cause,
			text_exposed, completion_accepted, recovery, delay_ms, detail,
			input_tokens, output_tokens, reasoning_tokens, cache_read_tokens, cache_write_tokens, cost)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			text_or_null(value.kind),
			text_or_null(value.failure_class),
			int_value(value.status),
			text_or_null(value.provider_code),
			text_or_null(value.provider_request_id),
			maybe_int(value.retry_after_ms),
			text_or_null(value.retry_directive),
			text_or_null(value.transport_cause),
			value.text_exposed,
			value.completion_accepted,
			text_or_null(value.recovery),
			value.delay_ms,
			text_or_null(value.detail),
			usage[0],
			usage[1],
			usage[2],
			usage[3],
			usage[4],
			usage[5],
		)
	case Retry_Scheduled:
		payload_row(
			journal,
			"INSERT INTO record_retry_scheduled (seq, purpose, reason, next_attempt, delay_ms) VALUES (?, ?, ?, ?, ?)",
			name_code(journal, REQUEST_PURPOSE_NAMES, value.purpose),
			text_or_null(value.reason),
			int_value(value.next_attempt),
			value.delay_ms,
		)
	case Retry_Completed:
		payload_row(
			journal,
			"INSERT INTO record_retry_completed (seq, purpose, outcome) VALUES (?, ?, ?)",
			name_code(journal, REQUEST_PURPOSE_NAMES, value.purpose),
			name_code(journal, RETRY_OUTCOME_NAMES, value.outcome),
		)
	case Selection_Changed:
		payload_row(journal, "INSERT INTO record_selection_changed (seq, effort) VALUES (?, ?)", text_or_null(value.effort))
	case Selection_Fit:
		payload_row(
			journal,
			"INSERT INTO record_selection_fit (seq, api, recheck, decision, estimate, context_window, reason) VALUES (?, ?, ?, ?, ?, ?, ?)",
			text_or_null(value.api),
			value.recheck,
			name_code(journal, SELECTION_FIT_DECISION_NAMES, value.decision),
			int_value(value.estimate),
			int_value(value.context_window),
			text_or_null(value.reason),
		)
	case Selection_Applied:
		payload_row(journal, "INSERT INTO record_selection_applied (seq, api, effort) VALUES (?, ?, ?)", text_or_null(value.api), text_or_null(value.effort))
	}
}

// payload_as returns the payload of record when it is a Payload, false when the
// record has no typed payload or another kind. The result borrows record.
payload_as :: proc(record: Record, $Payload: typeid) -> (payload: Payload, ok: bool) {
	stored := record.payload.? or_return
	return stored.(Payload)
}

// load_record_payload fills record.payload from its family tables. A kind that has
// a table and no row is Corrupt. A kind with no table, or still JSON-only, is left
// nil. Strings and slices are owned by allocator. It runs after the header's result
// set has ended, because each family read needs the connection.
@(private, require_results)
load_record_payload :: proc(journal: ^Journal, record: ^Record, allocator: mem.Allocator) -> Error {
	if record.payload != nil { return nil }
	switch record.kind {
	case .Run_Started:
		return payload_load(journal, record, "SELECT pid FROM record_run_started WHERE seq = ?", allocator, scan_run_started)
	case .Session_Recovered:
		return payload_load(
			journal,
			record,
			"SELECT turns, requests, calls, results FROM record_session_recovered WHERE seq = ?",
			allocator,
			scan_session_recovered,
		)
	case .Session_Claimed:
		return payload_load(journal, record, "SELECT resumed FROM record_session_claimed WHERE seq = ?", allocator, scan_session_claimed)
	case .Session_Environment:
		environment, error := environment_load(journal, record, allocator)
		if error != nil {
			environment_destroy(environment, allocator)
			return error
		}
		record.payload = environment
	case .User_Input:
		payload_load(journal, record, "SELECT origin FROM record_user_input WHERE seq = ?", allocator, scan_user_input) or_return
		payload := record.payload.?
		input := payload.(User_Input)
		input.attachments = attachments_load(journal, record, allocator) or_return
		record.payload = input
	case .User_Command:
		return payload_load(journal, record, "SELECT kind, provider, model, level FROM record_user_command WHERE seq = ?", allocator, scan_user_command)
	case .Command_Applied:
		return payload_load(journal, record, "SELECT command, outcome, reason FROM record_command_applied WHERE seq = ?", allocator, scan_command_applied)
	case .Turn_Started:
		return payload_load(journal, record, "SELECT instructions, manifest, effort FROM record_turn_started WHERE seq = ?", allocator, scan_turn_started)
	case .Turn_Completed:
		return payload_load(journal, record, "SELECT outcome, detail, reason, cause FROM record_turn_completed WHERE seq = ?", allocator, scan_turn_completed)
	case .Request_Prepared:
		return payload_load(
			journal,
			record,
			"SELECT purpose, api, transport, estimate, context_window, messages, tools, replay_refused FROM record_request_prepared WHERE seq = ?",
			allocator,
			scan_request_prepared,
		)
	case .Request_Admitted:
		return payload_load(
			journal,
			record,
			"SELECT decision, estimate, context_window, instructions_tokens, tools_tokens, conversation_tokens FROM record_request_admitted WHERE seq = ?",
			allocator,
			scan_request_admitted,
		)
	case .Request_Sent:
		return payload_load(
			journal,
			record,
			"SELECT purpose, api, recovery, body_digest, body_bytes FROM record_request_sent WHERE seq = ?",
			allocator,
			scan_request_sent,
		)
	case .Request_Interrupted:
		return payload_load(
			journal,
			record,
			`SELECT detail, input_tokens, output_tokens, reasoning_tokens, cache_read_tokens, cache_write_tokens, cost
			FROM record_request_interrupted WHERE seq = ?`,
			allocator,
			scan_request_interrupted,
		)
	case .Retry_Scheduled:
		return payload_load(
			journal,
			record,
			"SELECT purpose, reason, next_attempt, delay_ms FROM record_retry_scheduled WHERE seq = ?",
			allocator,
			scan_retry_scheduled,
		)
	case .Retry_Completed:
		return payload_load(journal, record, "SELECT purpose, outcome FROM record_retry_completed WHERE seq = ?", allocator, scan_retry_completed)
	case .Selection_Changed:
		return payload_load(journal, record, "SELECT effort FROM record_selection_changed WHERE seq = ?", allocator, scan_selection_changed)
	case .Response_Committed, .Compaction_Completed:
		return payload_load(
			journal,
			record,
			`SELECT api, model_resolved, finish, input_tokens, output_tokens, reasoning_tokens, cache_read_tokens, cache_write_tokens, cost
			FROM record_response WHERE seq = ?`,
			allocator,
			scan_response_committed,
		)
	case .Response_Rejected:
		return payload_load(
			journal,
			record,
			`SELECT kind, failure_class, status, provider_code, provider_request_id, retry_after_ms, retry_directive, transport_cause,
			text_exposed, completion_accepted, recovery, delay_ms, detail,
			input_tokens, output_tokens, reasoning_tokens, cache_read_tokens, cache_write_tokens, cost
			FROM record_response_rejected WHERE seq = ?`,
			allocator,
			scan_response_rejected,
		)
	case .Selection_Fit:
		return payload_load(
			journal,
			record,
			"SELECT api, recheck, decision, estimate, context_window, reason FROM record_selection_fit WHERE seq = ?",
			allocator,
			scan_selection_fit,
		)
	case .Selection_Applied:
		return payload_load(journal, record, "SELECT api, effort FROM record_selection_applied WHERE seq = ?", allocator, scan_selection_applied)
	case .Run_Finished,
	     .Session_Created,
	     .Session_Titled,
	     .Session_Released,
	     .Branch_Created,
	     .Branch_Selected,
	     .Node_Committed,
	     .Tool_Proposed,
	     .Tool_Admitted,
	     .Tool_Started,
	     .Tool_Completed,
	     .Lua_Started,
	     .Lua_Completed,
	     .Task_Started,
	     .Task_Completed,
	     .Subagent_Started,
	     .Subagent_Completed,
	     .Compaction_Started,
	     .Checkpoint_Installed,
	     .Runtime_Message,
	     .Job_Abandoned,
	     .Job_Reclaimed,
	     .Subagent_Message,
	     .Background_Completed:
	}
	return nil
}

// payload_load reads the one family row of record with sql, which selects the
// columns scan reads in order. A missing row is Corrupt.
@(private, require_results)
payload_load :: proc(journal: ^Journal, record: ^Record, sql: string, allocator: mem.Allocator, scan: proc(row: ^Row) -> Record_Payload) -> Error {
	rows: db.Rows
	defer _ = db.rows_close(&rows)
	db.query(&journal.connection, &rows, sql, {db.Value(i64(record.seq))}) or_return
	values, has_row := db.rows_next(&rows) or_return
	if !has_row { return corrupt(journal, Journal_Error.Corrupt, record.session, record.seq) }
	row := Row {
		values    = values,
		allocator = allocator,
	}
	payload := scan(&row)
	if row.error != nil {
		payload_destroy(payload, allocator)
		return corrupt(journal, row.error, record.session, record.seq)
	}
	record.payload = payload
	return nil
}

@(private)
scan_run_started :: proc(row: ^Row) -> Record_Payload {
	return Run_Started{version = PAYLOAD_VERSION, pid = int(row_int(row))}
}

@(private)
scan_session_recovered :: proc(row: ^Row) -> Record_Payload {
	return Session_Recovered {
		version = PAYLOAD_VERSION,
		turns = int(row_int(row)),
		requests = int(row_int(row)),
		calls = int(row_int(row)),
		results = int(row_int(row)),
	}
}

@(private)
scan_session_claimed :: proc(row: ^Row) -> Record_Payload {
	resumed, ok := row_flag(row)
	if !ok && row.error == nil { row.error = Journal_Error.Corrupt }
	return Session_Claimed{version = PAYLOAD_VERSION, resumed = resumed}
}

@(private)
scan_user_input :: proc(row: ^Row) -> Record_Payload {
	return User_Input{version = PAYLOAD_VERSION, origin = row_enum_name(row, USER_ORIGIN_NAMES)}
}

@(private)
scan_user_command :: proc(row: ^Row) -> Record_Payload {
	return User_Command {
		version = PAYLOAD_VERSION,
		kind = row_enum_name(row, COMMAND_KIND_NAMES),
		provider = row_text(row),
		model = row_text(row),
		level = row_text(row),
	}
}

@(private)
scan_command_applied :: proc(row: ^Row) -> Record_Payload {
	return Command_Applied {
		version = PAYLOAD_VERSION,
		command = Journal_Seq(row_int(row)),
		outcome = row_enum_name(row, COMMAND_OUTCOME_NAMES),
		reason = row_text(row),
	}
}

@(private)
scan_turn_started :: proc(row: ^Row) -> Record_Payload {
	return Turn_Started{version = PAYLOAD_VERSION, instructions = row_digest(row), manifest = row_digest(row), effort = row_text(row)}
}

@(private)
scan_turn_completed :: proc(row: ^Row) -> Record_Payload {
	return Turn_Completed {
		version = PAYLOAD_VERSION,
		outcome = row_enum_name(row, TURN_OUTCOME_NAMES),
		detail = row_text(row),
		reason = row_text(row),
		cause = row_text(row),
	}
}

@(private)
scan_request_prepared :: proc(row: ^Row) -> Record_Payload {
	return Request_Prepared {
		version = PAYLOAD_VERSION,
		purpose = row_enum_name(row, REQUEST_PURPOSE_NAMES),
		api = row_text(row),
		transport = row_text(row),
		estimate = int(row_int(row)),
		context_window = int(row_int(row)),
		messages = int(row_int(row)),
		tools = int(row_int(row)),
		replay_refused = int(row_int(row)),
	}
}

@(private)
scan_request_admitted :: proc(row: ^Row) -> Record_Payload {
	return Request_Admitted {
		version = PAYLOAD_VERSION,
		decision = row_enum_name(row, ADMISSION_DECISION_NAMES),
		estimate = int(row_int(row)),
		context_window = int(row_int(row)),
		instructions_tokens = int(row_int(row)),
		tools_tokens = int(row_int(row)),
		conversation_tokens = int(row_int(row)),
	}
}

@(private)
scan_request_sent :: proc(row: ^Row) -> Record_Payload {
	return Request_Sent {
		version = PAYLOAD_VERSION,
		purpose = row_enum_name(row, REQUEST_PURPOSE_NAMES),
		api = row_text(row),
		recovery = row_text(row),
		body_digest = row_digest(row),
		body_bytes = int(row_int(row)),
	}
}

@(private)
scan_request_interrupted :: proc(row: ^Row) -> Record_Payload {
	interrupted := Request_Interrupted {
		version = PAYLOAD_VERSION,
		detail  = row_text(row),
	}
	row_usage(row, &interrupted)
	return interrupted
}

@(private)
scan_response_committed :: proc(row: ^Row) -> Record_Payload {
	committed := Response_Committed {
		version        = PAYLOAD_VERSION,
		api            = row_text(row),
		model_resolved = row_text(row),
		finish         = row_enum_name(row, RESPONSE_FINISH_NAMES),
	}
	row_usage(row, &committed)
	return committed
}

@(private)
scan_response_rejected :: proc(row: ^Row) -> Record_Payload {
	rejected := Response_Rejected {
		version             = PAYLOAD_VERSION,
		kind                = row_text(row),
		failure_class       = row_text(row),
		status              = int(row_int(row)),
		provider_code       = row_text(row),
		provider_request_id = row_text(row),
		retry_after_ms      = row_optional_int(row),
		retry_directive     = row_text(row),
		transport_cause     = row_text(row),
	}
	text_exposed, text_exposed_ok := row_flag(row)
	completion_accepted, completion_accepted_ok := row_flag(row)
	if (!text_exposed_ok || !completion_accepted_ok) && row.error == nil { row.error = Journal_Error.Corrupt }
	rejected.text_exposed = text_exposed
	rejected.completion_accepted = completion_accepted
	rejected.recovery = row_text(row)
	rejected.delay_ms = row_int(row)
	rejected.detail = row_text(row)
	row_usage(row, &rejected)
	return rejected
}

@(private)
scan_retry_scheduled :: proc(row: ^Row) -> Record_Payload {
	return Retry_Scheduled {
		version = PAYLOAD_VERSION,
		purpose = row_enum_name(row, REQUEST_PURPOSE_NAMES),
		reason = row_text(row),
		next_attempt = int(row_int(row)),
		delay_ms = row_int(row),
	}
}

@(private)
scan_retry_completed :: proc(row: ^Row) -> Record_Payload {
	return Retry_Completed{version = PAYLOAD_VERSION, purpose = row_enum_name(row, REQUEST_PURPOSE_NAMES), outcome = row_enum_name(row, RETRY_OUTCOME_NAMES)}
}

@(private)
scan_selection_changed :: proc(row: ^Row) -> Record_Payload {
	return Selection_Changed{version = PAYLOAD_VERSION, effort = row_text(row)}
}

@(private)
scan_selection_fit :: proc(row: ^Row) -> Record_Payload {
	fit := Selection_Fit {
		version = PAYLOAD_VERSION,
		api     = row_text(row),
	}
	recheck, recheck_ok := row_flag(row)
	if !recheck_ok && row.error == nil { row.error = Journal_Error.Corrupt }
	fit.recheck = recheck
	fit.decision = row_enum_name(row, SELECTION_FIT_DECISION_NAMES)
	fit.estimate = int(row_int(row))
	fit.context_window = int(row_int(row))
	fit.reason = row_text(row)
	return fit
}

@(private)
scan_selection_applied :: proc(row: ^Row) -> Record_Payload {
	return Selection_Applied{version = PAYLOAD_VERSION, api = row_text(row), effort = row_text(row)}
}

// row_usage reads the six Attempt_Usage columns into any payload that embeds
// them; NULL stays absent.
@(private)
row_usage :: proc(row: ^Row, payload: ^$Payload) {
	payload.input_tokens = row_optional_int(row)
	payload.output_tokens = row_optional_int(row)
	payload.reasoning_tokens = row_optional_int(row)
	payload.cache_read_tokens = row_optional_int(row)
	payload.cache_write_tokens = row_optional_int(row)
	value, ok := row_next(row)
	if !ok || value == nil { return }
	number, error := db.as_f64(value)
	if error != nil {
		row.error = Journal_Error.Corrupt
		return
	}
	payload.cost = number
}

@(private)
row_optional_int :: proc(row: ^Row) -> Maybe(i64) {
	number, present := row_maybe_int(row)
	if !present { return nil }
	return number
}

// payload_destroy releases the strings and slices load_record_payload allocated.
@(private)
payload_destroy :: proc(payload: Record_Payload, allocator: mem.Allocator) {
	switch value in payload {
	case Session_Titled:
		delete(value.title, allocator)
	case Run_Started, Session_Recovered, Session_Claimed:
	case Session_Environment:
		environment_destroy(value, allocator)
	case User_Input:
		delete(value.origin, allocator)
		attachments_destroy(value.attachments, allocator)
	case User_Command:
		delete(value.kind, allocator)
		delete(value.provider, allocator)
		delete(value.model, allocator)
		delete(value.level, allocator)
	case Command_Applied:
		delete(value.outcome, allocator)
		delete(value.reason, allocator)
	case Turn_Started:
		delete(value.instructions, allocator)
		delete(value.manifest, allocator)
		delete(value.effort, allocator)
	case Turn_Completed:
		delete(value.outcome, allocator)
		delete(value.detail, allocator)
		delete(value.reason, allocator)
		delete(value.cause, allocator)
	case Request_Prepared:
		delete(value.purpose, allocator)
		delete(value.api, allocator)
		delete(value.transport, allocator)
	case Request_Admitted:
		delete(value.decision, allocator)
	case Request_Sent:
		delete(value.purpose, allocator)
		delete(value.api, allocator)
		delete(value.recovery, allocator)
		delete(value.body_digest, allocator)
	case Request_Interrupted:
		delete(value.detail, allocator)
	case Response_Committed:
		delete(value.api, allocator)
		delete(value.model_resolved, allocator)
		delete(value.finish, allocator)
	case Response_Rejected:
		delete(value.kind, allocator)
		delete(value.failure_class, allocator)
		delete(value.provider_code, allocator)
		delete(value.provider_request_id, allocator)
		delete(value.retry_directive, allocator)
		delete(value.transport_cause, allocator)
		delete(value.recovery, allocator)
		delete(value.detail, allocator)
	case Retry_Scheduled:
		delete(value.purpose, allocator)
		delete(value.reason, allocator)
	case Retry_Completed:
		delete(value.purpose, allocator)
		delete(value.outcome, allocator)
	case Selection_Changed:
		delete(value.effort, allocator)
	case Selection_Fit:
		delete(value.api, allocator)
		delete(value.decision, allocator)
		delete(value.reason, allocator)
	case Selection_Applied:
		delete(value.api, allocator)
		delete(value.effort, allocator)
	}
}
