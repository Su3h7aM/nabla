package journal

import "core:mem"
import "core:mem/virtual"
import "core:strings"

import "nabla:db"

// Payload_Pending is the typed family row of the record buffered just before it.
// Its strings and slices are owned by the batch arena.
@(private)
Payload_Pending :: struct {
	payload: Record_Payload,
}

// payload_push buffers the family row for a payload that has a table. Kinds that
// are still JSON-only push nothing. Strings are copied into the batch arena.
@(private)
payload_push :: proc(journal: ^Journal, data: $Payload) {
	when Payload == Run_Started || Payload == Session_Recovered || Payload == Session_Claimed {
		push(journal, Payload_Pending{payload = data})
	} else when Payload == Session_Environment {
		copied := environment_batch(journal, data)
		if journal.failure == nil { push(journal, Payload_Pending{payload = copied}) }
	} else when Payload == User_Input {
		copied := data
		copied.origin = batch_text(journal, data.origin)
		copied.attachments = batch_attachments(journal, data.attachments)
		if journal.failure == nil { push(journal, Payload_Pending{payload = copied}) }
	} else when Payload == User_Command {
		copied := data
		copied.kind = batch_text(journal, data.kind)
		copied.provider = batch_text(journal, data.provider)
		copied.model = batch_text(journal, data.model)
		copied.level = batch_text(journal, data.level)
		if journal.failure == nil { push(journal, Payload_Pending{payload = copied}) }
	} else when Payload == Command_Applied {
		copied := data
		copied.outcome = batch_text(journal, data.outcome)
		copied.reason = batch_text(journal, data.reason)
		if journal.failure == nil { push(journal, Payload_Pending{payload = copied}) }
	}
}

// payload_insert writes the family row of seq. The header row is already inserted.
@(private, require_results)
payload_insert :: proc(journal: ^Journal, seq: Journal_Seq, payload: Record_Payload) -> Error {
	switch value in payload {
	case Session_Titled:
		return Journal_Error.Corrupt
	case Run_Started:
		return db.exec(&journal.connection, "INSERT INTO record_run_started (seq, pid) VALUES (?, ?)", {db.Value(i64(seq)), db.Value(i64(value.pid))})
	case Session_Recovered:
		return db.exec(
			&journal.connection,
			"INSERT INTO record_session_recovered (seq, turns, requests, calls, results) VALUES (?, ?, ?, ?, ?)",
			{db.Value(i64(seq)), db.Value(i64(value.turns)), db.Value(i64(value.requests)), db.Value(i64(value.calls)), db.Value(i64(value.results))},
		)
	case Session_Claimed:
		return db.exec(&journal.connection, "INSERT INTO record_session_claimed (seq, resumed) VALUES (?, ?)", {db.Value(i64(seq)), db.Value(value.resumed)})
	case Session_Environment:
		return environment_insert(journal, seq, value)
	case User_Input:
		return user_input_insert(journal, seq, value)
	case User_Command:
		return user_command_insert(journal, seq, value)
	case Command_Applied:
		return command_applied_insert(journal, seq, value)
	case:
		return Journal_Error.Corrupt
	}
}

// load_record_payload fills record.payload from its family table. A kind that has
// a table and no row is Corrupt. A kind that is still JSON-only is left nil.
// Strings and slices are owned by allocator.
@(private, require_results)
load_record_payload :: proc(journal: ^Journal, record: ^Record, allocator: mem.Allocator) -> Error {
	if record.payload != nil { return nil }
	switch record.kind {
	case .Run_Started:
		return load_run_started(journal, record, allocator)
	case .Session_Recovered:
		return load_session_recovered(journal, record, allocator)
	case .Session_Claimed:
		return load_session_claimed(journal, record, allocator)
	case .Session_Environment:
		return load_session_environment(journal, record, allocator)
	case .User_Input:
		return load_user_input(journal, record, allocator)
	case .User_Command:
		return load_user_command(journal, record, allocator)
	case .Command_Applied:
		return load_command_applied(journal, record, allocator)
	case .Run_Finished,
	     .Session_Created,
	     .Session_Titled,
	     .Session_Released,
	     .Branch_Created,
	     .Branch_Selected,
	     .Node_Committed,
	     .Turn_Started,
	     .Turn_Completed,
	     .Request_Prepared,
	     .Request_Admitted,
	     .Request_Sent,
	     .Response_Committed,
	     .Response_Rejected,
	     .Request_Interrupted,
	     .Retry_Scheduled,
	     .Retry_Completed,
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
	     .Compaction_Completed,
	     .Checkpoint_Installed,
	     .Runtime_Message,
	     .Job_Abandoned,
	     .Job_Reclaimed,
	     .Selection_Changed,
	     .Subagent_Message,
	     .Selection_Fit,
	     .Selection_Applied,
	     .Background_Completed:
		return nil
	}
	return nil
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
	}
}

@(private, require_results)
load_run_started :: proc(journal: ^Journal, record: ^Record, allocator: mem.Allocator) -> Error {
	rows: db.Rows
	defer _ = db.rows_close(&rows)
	db.query(&journal.connection, &rows, "SELECT pid FROM record_run_started WHERE seq = ?", {db.Value(i64(record.seq))}) or_return
	values, has_row := db.rows_next(&rows) or_return
	if !has_row { return corrupt(journal, Journal_Error.Corrupt, record.session, record.seq) }
	row := Row {
		values    = values,
		allocator = allocator,
	}
	pid := row_int(&row)
	if row.error != nil { return corrupt(journal, row.error, record.session, record.seq) }
	record.payload = Run_Started {
		version = PAYLOAD_VERSION,
		pid     = int(pid),
	}
	return nil
}

@(private, require_results)
load_session_recovered :: proc(journal: ^Journal, record: ^Record, allocator: mem.Allocator) -> Error {
	rows: db.Rows
	defer _ = db.rows_close(&rows)
	db.query(
		&journal.connection,
		&rows,
		"SELECT turns, requests, calls, results FROM record_session_recovered WHERE seq = ?",
		{db.Value(i64(record.seq))},
	) or_return
	values, has_row := db.rows_next(&rows) or_return
	if !has_row { return corrupt(journal, Journal_Error.Corrupt, record.session, record.seq) }
	row := Row {
		values    = values,
		allocator = allocator,
	}
	recovered := Session_Recovered {
		version  = PAYLOAD_VERSION,
		turns    = int(row_int(&row)),
		requests = int(row_int(&row)),
		calls    = int(row_int(&row)),
		results  = int(row_int(&row)),
	}
	if row.error != nil { return corrupt(journal, row.error, record.session, record.seq) }
	record.payload = recovered
	return nil
}

@(private, require_results)
load_session_claimed :: proc(journal: ^Journal, record: ^Record, allocator: mem.Allocator) -> Error {
	rows: db.Rows
	defer _ = db.rows_close(&rows)
	db.query(&journal.connection, &rows, "SELECT resumed FROM record_session_claimed WHERE seq = ?", {db.Value(i64(record.seq))}) or_return
	values, has_row := db.rows_next(&rows) or_return
	if !has_row { return corrupt(journal, Journal_Error.Corrupt, record.session, record.seq) }
	row := Row {
		values    = values,
		allocator = allocator,
	}
	resumed, ok := row_flag(&row)
	if row.error != nil { return corrupt(journal, row.error, record.session, record.seq) }
	if !ok { return corrupt(journal, Journal_Error.Corrupt, record.session, record.seq) }
	record.payload = Session_Claimed {
		version = PAYLOAD_VERSION,
		resumed = resumed,
	}
	return nil
}

@(private, require_results)
load_session_environment :: proc(journal: ^Journal, record: ^Record, allocator: mem.Allocator) -> Error {
	environment, error := environment_load(journal, record, allocator)
	if error != nil {
		environment_destroy(environment, allocator)
		return error
	}
	record.payload = environment
	return nil
}

// row_flag reads a 0 or 1. Any other integer is not a flag, and ok is false.
@(private)
row_flag :: proc(row: ^Row) -> (flag: bool, ok: bool) {
	number := row_int(row)
	if row.error != nil || (number != 0 && number != 1) { return false, false }
	return number == 1, true
}

@(private)
environment_batch :: proc(journal: ^Journal, source: Session_Environment) -> (copied: Session_Environment) {
	allocator := virtual.arena_allocator(&journal.batch)
	copied.version = source.version
	copied.instructions = batch_text(journal, source.instructions)
	if len(source.servers) == 0 || journal.failure != nil { return }
	servers, error := make([]Session_Environment_Server, len(source.servers), allocator)
	if error != nil {
		latch(journal, error)
		return {}
	}
	for server, index in source.servers {
		servers[index] = {
			id                   = batch_text(journal, server.id),
			executable           = batch_text(journal, server.executable),
			arguments            = batch_string_list(journal, server.arguments),
			working_directory    = batch_text(journal, server.working_directory),
			environment          = batch_variables(journal, server.environment),
			tools                = batch_environment_tools(journal, server.tools),
			discovery_timeout_ms = server.discovery_timeout_ms,
			call_timeout_ms      = server.call_timeout_ms,
		}
	}
	copied.servers = servers
	return
}

@(private)
batch_string_list :: proc(journal: ^Journal, source: []string) -> []string {
	if len(source) == 0 || journal.failure != nil { return nil }
	copied, error := make([]string, len(source), virtual.arena_allocator(&journal.batch))
	if error != nil {
		latch(journal, error)
		return nil
	}
	for text, index in source { copied[index] = batch_text(journal, text) }
	return copied
}

@(private)
batch_variables :: proc(journal: ^Journal, source: []Session_Environment_Variable) -> []Session_Environment_Variable {
	if len(source) == 0 || journal.failure != nil { return nil }
	copied, error := make([]Session_Environment_Variable, len(source), virtual.arena_allocator(&journal.batch))
	if error != nil {
		latch(journal, error)
		return nil
	}
	for variable, index in source {
		copied[index] = {
			name  = batch_text(journal, variable.name),
			value = batch_text(journal, variable.value),
		}
	}
	return copied
}

@(private)
batch_environment_tools :: proc(journal: ^Journal, source: []Session_Environment_Tool) -> []Session_Environment_Tool {
	if len(source) == 0 || journal.failure != nil { return nil }
	copied, error := make([]Session_Environment_Tool, len(source), virtual.arena_allocator(&journal.batch))
	if error != nil {
		latch(journal, error)
		return nil
	}
	for tool, index in source {
		copied[index] = {
			remote_name = batch_text(journal, tool.remote_name),
			name        = batch_text(journal, tool.name),
			enabled     = tool.enabled,
		}
	}
	return copied
}

@(private, require_results)
environment_insert :: proc(journal: ^Journal, seq: Journal_Seq, environment: Session_Environment) -> Error {
	db.exec(
		&journal.connection,
		"INSERT INTO record_environment (seq, instructions) VALUES (?, ?)",
		{db.Value(i64(seq)), text_or_null(environment.instructions)},
	) or_return
	for server, index in environment.servers {
		db.exec(
			&journal.connection,
			`INSERT INTO record_environment_server
				(seq, ordinal, id, executable, working_directory, discovery_timeout_ms, call_timeout_ms)
				VALUES (?, ?, ?, ?, ?, ?, ?)`,
			{
				db.Value(i64(seq)),
				db.Value(i64(index)),
				db.Value(server.id),
				db.Value(server.executable),
				text_or_null(server.working_directory),
				db.Value(server.discovery_timeout_ms),
				db.Value(server.call_timeout_ms),
			},
		) or_return
		for argument, argument_index in server.arguments {
			db.exec(
				&journal.connection,
				"INSERT INTO record_environment_argument (seq, server_ordinal, ordinal, argument) VALUES (?, ?, ?, ?)",
				{db.Value(i64(seq)), db.Value(i64(index)), db.Value(i64(argument_index)), db.Value(argument)},
			) or_return
		}
		for variable, variable_index in server.environment {
			db.exec(
				&journal.connection,
				"INSERT INTO record_environment_variable (seq, server_ordinal, ordinal, name, value) VALUES (?, ?, ?, ?, ?)",
				{db.Value(i64(seq)), db.Value(i64(index)), db.Value(i64(variable_index)), db.Value(variable.name), text_or_null(variable.value)},
			) or_return
		}
		for tool, tool_index in server.tools {
			db.exec(
				&journal.connection,
				`INSERT INTO record_environment_tool
					(seq, server_ordinal, ordinal, remote_name, name, enabled) VALUES (?, ?, ?, ?, ?, ?)`,
				{
					db.Value(i64(seq)),
					db.Value(i64(index)),
					db.Value(i64(tool_index)),
					db.Value(tool.remote_name),
					text_or_null(tool.name),
					db.Value(tool.enabled),
				},
			) or_return
		}
	}
	return nil
}

@(private, require_results)
environment_load :: proc(journal: ^Journal, record: ^Record, allocator: mem.Allocator) -> (environment: Session_Environment, error: Error) {
	{
		rows: db.Rows
		defer _ = db.rows_close(&rows)
		db.query(&journal.connection, &rows, "SELECT instructions FROM record_environment WHERE seq = ?", {db.Value(i64(record.seq))}) or_return
		values, has_row := db.rows_next(&rows) or_return
		if !has_row { return {}, corrupt(journal, Journal_Error.Corrupt, record.session, record.seq) }
		row := Row {
			values    = values,
			allocator = allocator,
		}
		environment.version = PAYLOAD_VERSION
		environment.instructions = row_text(&row)
		if row.error != nil { return environment, corrupt(journal, row.error, record.session, record.seq) }
	}
	environment.servers = environment_servers_load(journal, record, allocator) or_return
	return environment, nil
}

@(private, require_results)
environment_servers_load :: proc(journal: ^Journal, record: ^Record, allocator: mem.Allocator) -> (servers: []Session_Environment_Server, error: Error) {
	rows: db.Rows
	defer _ = db.rows_close(&rows)
	db.query(
		&journal.connection,
		&rows,
		`SELECT ordinal, id, executable, working_directory, discovery_timeout_ms, call_timeout_ms
			FROM record_environment_server WHERE seq = ? ORDER BY ordinal`,
		{db.Value(i64(record.seq))},
	) or_return
	listed := make([dynamic]Session_Environment_Server, allocator) or_return
	defer if error != nil {
		for &server in listed { environment_server_destroy(server, allocator) }
		delete(listed[:], allocator)
	}
	for {
		values, has_row := db.rows_next(&rows) or_return
		if !has_row { break }
		row := Row {
			values    = values,
			allocator = allocator,
		}
		ordinal := row_int(&row)
		server := Session_Environment_Server {
			id                   = row_text(&row),
			executable           = row_text(&row),
			working_directory    = row_text(&row),
			discovery_timeout_ms = row_int(&row),
			call_timeout_ms      = row_int(&row),
		}
		if row.error != nil { return nil, corrupt(journal, row.error, record.session, record.seq) }
		if _, append_error := append(&listed, server); append_error != nil {
			environment_server_destroy(server, allocator)
			return nil, append_error
		}
		if ordinal != i64(len(listed) - 1) { return nil, corrupt(journal, Journal_Error.Corrupt, record.session, record.seq) }
	}
	_ = db.rows_close(&rows)
	for &server, index in listed {
		server.arguments = environment_arguments_load(journal, record, index, allocator) or_return
		server.environment = environment_variables_load(journal, record, index, allocator) or_return
		server.tools = environment_tools_load(journal, record, index, allocator) or_return
	}
	return listed[:], nil
}

@(private, require_results)
environment_arguments_load :: proc(journal: ^Journal, record: ^Record, server: int, allocator: mem.Allocator) -> (arguments: []string, error: Error) {
	return environment_text_list_load(
		journal,
		record,
		server,
		allocator,
		"SELECT ordinal, argument FROM record_environment_argument WHERE seq = ? AND server_ordinal = ? ORDER BY ordinal",
	)
}

@(private, require_results)
environment_text_list_load :: proc(journal: ^Journal, record: ^Record, server: int, allocator: mem.Allocator, sql: string) -> (texts: []string, error: Error) {
	rows: db.Rows
	defer _ = db.rows_close(&rows)
	db.query(&journal.connection, &rows, sql, {db.Value(i64(record.seq)), db.Value(i64(server))}) or_return
	listed := make([dynamic]string, allocator) or_return
	defer if error != nil {
		for text in listed { delete(text, allocator) }
		delete(listed[:], allocator)
	}
	for {
		values, has_row := db.rows_next(&rows) or_return
		if !has_row { break }
		row := Row {
			values    = values,
			allocator = allocator,
		}
		ordinal := row_int(&row)
		text := row_text(&row)
		if row.error != nil { return nil, corrupt(journal, row.error, record.session, record.seq) }
		if _, append_error := append(&listed, text); append_error != nil {
			delete(text, allocator)
			return nil, append_error
		}
		if ordinal != i64(len(listed) - 1) { return nil, corrupt(journal, Journal_Error.Corrupt, record.session, record.seq) }
	}
	return listed[:], nil
}

@(private, require_results)
environment_variables_load :: proc(
	journal: ^Journal,
	record: ^Record,
	server: int,
	allocator: mem.Allocator,
) -> (
	variables: []Session_Environment_Variable,
	error: Error,
) {
	rows: db.Rows
	defer _ = db.rows_close(&rows)
	db.query(
		&journal.connection,
		&rows,
		"SELECT ordinal, name, value FROM record_environment_variable WHERE seq = ? AND server_ordinal = ? ORDER BY ordinal",
		{db.Value(i64(record.seq)), db.Value(i64(server))},
	) or_return
	listed := make([dynamic]Session_Environment_Variable, allocator) or_return
	defer if error != nil {
		for variable in listed {
			delete(variable.name, allocator)
			delete(variable.value, allocator)
		}
		delete(listed[:], allocator)
	}
	for {
		values, has_row := db.rows_next(&rows) or_return
		if !has_row { break }
		row := Row {
			values    = values,
			allocator = allocator,
		}
		ordinal := row_int(&row)
		variable := Session_Environment_Variable {
			name  = row_text(&row),
			value = row_text(&row),
		}
		if row.error != nil { return nil, corrupt(journal, row.error, record.session, record.seq) }
		if _, append_error := append(&listed, variable); append_error != nil {
			delete(variable.name, allocator)
			delete(variable.value, allocator)
			return nil, append_error
		}
		if ordinal != i64(len(listed) - 1) { return nil, corrupt(journal, Journal_Error.Corrupt, record.session, record.seq) }
	}
	return listed[:], nil
}

@(private, require_results)
environment_tools_load :: proc(
	journal: ^Journal,
	record: ^Record,
	server: int,
	allocator: mem.Allocator,
) -> (
	tools: []Session_Environment_Tool,
	error: Error,
) {
	rows: db.Rows
	defer _ = db.rows_close(&rows)
	db.query(
		&journal.connection,
		&rows,
		"SELECT ordinal, remote_name, name, enabled FROM record_environment_tool WHERE seq = ? AND server_ordinal = ? ORDER BY ordinal",
		{db.Value(i64(record.seq)), db.Value(i64(server))},
	) or_return
	listed := make([dynamic]Session_Environment_Tool, allocator) or_return
	defer if error != nil {
		for tool in listed {
			delete(tool.remote_name, allocator)
			delete(tool.name, allocator)
		}
		delete(listed[:], allocator)
	}
	for {
		values, has_row := db.rows_next(&rows) or_return
		if !has_row { break }
		row := Row {
			values    = values,
			allocator = allocator,
		}
		ordinal := row_int(&row)
		tool := Session_Environment_Tool {
			remote_name = row_text(&row),
			name        = row_text(&row),
			enabled     = false,
		}
		enabled, ok := row_flag(&row)
		tool.enabled = enabled
		if row.error != nil || !ok { return nil, corrupt(journal, Journal_Error.Corrupt, record.session, record.seq) }
		if _, append_error := append(&listed, tool); append_error != nil {
			delete(tool.remote_name, allocator)
			delete(tool.name, allocator)
			return nil, append_error
		}
		if ordinal != i64(len(listed) - 1) { return nil, corrupt(journal, Journal_Error.Corrupt, record.session, record.seq) }
	}
	return listed[:], nil
}

@(private)
environment_destroy :: proc(environment: Session_Environment, allocator: mem.Allocator) {
	delete(environment.instructions, allocator)
	for server in environment.servers { environment_server_destroy(server, allocator) }
	delete(environment.servers, allocator)
}

@(private)
environment_server_destroy :: proc(server: Session_Environment_Server, allocator: mem.Allocator) {
	delete(server.id, allocator)
	delete(server.executable, allocator)
	delete(server.working_directory, allocator)
	for argument in server.arguments { delete(argument, allocator) }
	delete(server.arguments, allocator)
	for variable in server.environment {
		delete(variable.name, allocator)
		delete(variable.value, allocator)
	}
	delete(server.environment, allocator)
	for tool in server.tools {
		delete(tool.remote_name, allocator)
		delete(tool.name, allocator)
	}
	delete(server.tools, allocator)
}

@(private)
batch_attachments :: proc(journal: ^Journal, source: []Attachment) -> []Attachment {
	if len(source) == 0 || journal.failure != nil { return nil }
	copied, error := make([]Attachment, len(source), virtual.arena_allocator(&journal.batch))
	if error != nil {
		latch(journal, error)
		return nil
	}
	for attachment, index in source {
		copied[index] = {
			media_type = batch_text(journal, attachment.media_type),
			name       = batch_text(journal, attachment.name),
			digest     = batch_text(journal, attachment.digest),
		}
	}
	return copied
}

@(private, require_results)
enum_code :: proc(names: [$Enum]string, name: string) -> (code: i64, error: Error) {
	value, found := enum_from_name(names, name)
	if !found { return 0, Journal_Error.Corrupt }
	return i64(value), nil
}

@(private, require_results)
user_input_insert :: proc(journal: ^Journal, seq: Journal_Seq, input: User_Input) -> Error {
	origin := enum_code(USER_ORIGIN_NAMES, input.origin) or_return
	db.exec(&journal.connection, "INSERT INTO record_user_input (seq, origin) VALUES (?, ?)", {db.Value(i64(seq)), db.Value(origin)}) or_return
	return attachments_insert(journal, seq, input.attachments)
}

@(private, require_results)
user_command_insert :: proc(journal: ^Journal, seq: Journal_Seq, command: User_Command) -> Error {
	kind := enum_code(COMMAND_KIND_NAMES, command.kind) or_return
	return db.exec(
		&journal.connection,
		"INSERT INTO record_user_command (seq, kind, provider, model, level) VALUES (?, ?, ?, ?, ?)",
		{db.Value(i64(seq)), db.Value(kind), text_or_null(command.provider), text_or_null(command.model), text_or_null(command.level)},
	)
}

@(private, require_results)
command_applied_insert :: proc(journal: ^Journal, seq: Journal_Seq, applied: Command_Applied) -> Error {
	outcome := enum_code(COMMAND_OUTCOME_NAMES, applied.outcome) or_return
	return db.exec(
		&journal.connection,
		"INSERT INTO record_command_applied (seq, command, outcome, reason) VALUES (?, ?, ?, ?)",
		{db.Value(i64(seq)), db.Value(i64(applied.command)), db.Value(outcome), text_or_null(applied.reason)},
	)
}

@(private, require_results)
attachments_insert :: proc(journal: ^Journal, seq: Journal_Seq, attachments: []Attachment) -> Error {
	for attachment, index in attachments {
		digest, ok := digest_from_hex(attachment.digest)
		if !ok { return Journal_Error.Corrupt }
		db.exec(
			&journal.connection,
			"INSERT INTO record_attachment (seq, ordinal, media_type, name, digest) VALUES (?, ?, ?, ?, ?)",
			{db.Value(i64(seq)), db.Value(i64(index)), db.Value(attachment.media_type), db.Value(attachment.name), db.Value(digest[:])},
		) or_return
	}
	return nil
}

@(private, require_results)
load_user_input :: proc(journal: ^Journal, record: ^Record, allocator: mem.Allocator) -> Error {
	rows: db.Rows
	defer _ = db.rows_close(&rows)
	db.query(&journal.connection, &rows, "SELECT origin FROM record_user_input WHERE seq = ?", {db.Value(i64(record.seq))}) or_return
	values, has_row := db.rows_next(&rows) or_return
	if !has_row { return corrupt(journal, Journal_Error.Corrupt, record.session, record.seq) }
	row := Row {
		values    = values,
		allocator = allocator,
	}
	input := User_Input {
		version = PAYLOAD_VERSION,
		origin  = row_enum_name(&row, USER_ORIGIN_NAMES),
	}
	if row.error != nil {
		delete(input.origin, allocator)
		return corrupt(journal, row.error, record.session, record.seq)
	}
	_ = db.rows_close(&rows)
	attachments, error := attachments_load(journal, record, allocator)
	if error != nil {
		delete(input.origin, allocator)
		return error
	}
	input.attachments = attachments
	record.payload = input
	return nil
}

@(private, require_results)
load_user_command :: proc(journal: ^Journal, record: ^Record, allocator: mem.Allocator) -> Error {
	rows: db.Rows
	defer _ = db.rows_close(&rows)
	db.query(&journal.connection, &rows, "SELECT kind, provider, model, level FROM record_user_command WHERE seq = ?", {db.Value(i64(record.seq))}) or_return
	values, has_row := db.rows_next(&rows) or_return
	if !has_row { return corrupt(journal, Journal_Error.Corrupt, record.session, record.seq) }
	row := Row {
		values    = values,
		allocator = allocator,
	}
	command := User_Command {
		version  = PAYLOAD_VERSION,
		kind     = row_enum_name(&row, COMMAND_KIND_NAMES),
		provider = row_text(&row),
		model    = row_text(&row),
		level    = row_text(&row),
	}
	if row.error != nil {
		delete(command.kind, allocator)
		delete(command.provider, allocator)
		delete(command.model, allocator)
		delete(command.level, allocator)
		return corrupt(journal, row.error, record.session, record.seq)
	}
	record.payload = command
	return nil
}

@(private, require_results)
load_command_applied :: proc(journal: ^Journal, record: ^Record, allocator: mem.Allocator) -> Error {
	rows: db.Rows
	defer _ = db.rows_close(&rows)
	db.query(&journal.connection, &rows, "SELECT command, outcome, reason FROM record_command_applied WHERE seq = ?", {db.Value(i64(record.seq))}) or_return
	values, has_row := db.rows_next(&rows) or_return
	if !has_row { return corrupt(journal, Journal_Error.Corrupt, record.session, record.seq) }
	row := Row {
		values    = values,
		allocator = allocator,
	}
	applied := Command_Applied {
		version = PAYLOAD_VERSION,
		command = Journal_Seq(row_int(&row)),
		outcome = row_enum_name(&row, COMMAND_OUTCOME_NAMES),
		reason  = row_text(&row),
	}
	if row.error != nil {
		delete(applied.outcome, allocator)
		delete(applied.reason, allocator)
		return corrupt(journal, row.error, record.session, record.seq)
	}
	record.payload = applied
	return nil
}

@(private)
row_enum_name :: proc(row: ^Row, names: [$Enum]string) -> string {
	code := row_code(row, Enum)
	if row.error != nil { return "" }
	copied, error := strings.clone(names[code], row.allocator)
	if error != nil {
		row.error = error
		return ""
	}
	return copied
}

@(private)
row_digest :: proc(row: ^Row) -> string {
	value, ok := row_next(row)
	if !ok { return "" }
	if value == nil {
		row.error = Journal_Error.Corrupt
		return ""
	}
	bytes, error := db.as_bytes(value)
	if error != nil || len(bytes) != size_of(Digest) {
		row.error = Journal_Error.Corrupt
		return ""
	}
	digest: Digest
	copy(digest[:], bytes)
	hex: [DIGEST_HEX_LENGTH]u8
	copied, clone_error := strings.clone(digest_to_hex(digest, hex[:]), row.allocator)
	if clone_error != nil {
		row.error = clone_error
		return ""
	}
	return copied
}

@(private, require_results)
attachments_load :: proc(journal: ^Journal, record: ^Record, allocator: mem.Allocator) -> (attachments: []Attachment, error: Error) {
	rows: db.Rows
	defer _ = db.rows_close(&rows)
	db.query(
		&journal.connection,
		&rows,
		"SELECT ordinal, media_type, name, digest FROM record_attachment WHERE seq = ? ORDER BY ordinal",
		{db.Value(i64(record.seq))},
	) or_return
	listed := make([dynamic]Attachment, allocator) or_return
	defer if error != nil { attachments_destroy(listed[:], allocator) }
	for {
		values, has_row := db.rows_next(&rows) or_return
		if !has_row { break }
		row := Row {
			values    = values,
			allocator = allocator,
		}
		ordinal := row_int(&row)
		attachment := Attachment {
			media_type = row_text(&row),
			name       = row_text(&row),
			digest     = row_digest(&row),
		}
		if row.error != nil {
			attachments_destroy([]Attachment{attachment}, allocator)
			return nil, corrupt(journal, row.error, record.session, record.seq)
		}
		if _, append_error := append(&listed, attachment); append_error != nil {
			attachments_destroy([]Attachment{attachment}, allocator)
			return nil, append_error
		}
		if ordinal != i64(len(listed) - 1) { return nil, corrupt(journal, Journal_Error.Corrupt, record.session, record.seq) }
	}
	return listed[:], nil
}

@(private)
attachments_destroy :: proc(attachments: []Attachment, allocator: mem.Allocator) {
	for attachment in attachments {
		delete(attachment.media_type, allocator)
		delete(attachment.name, allocator)
		delete(attachment.digest, allocator)
	}
	delete(attachments, allocator)
}
