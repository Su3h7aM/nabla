package journal

import "core:mem"
import "core:strings"

import "nabla:db"

@(private)
row_flag :: proc(row: ^Row) -> (flag: bool, ok: bool) {
	number := row_int(row)
	if row.error != nil || (number != 0 && number != 1) { return false, false }
	return number == 1, true
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
	if !ok || value == nil { return "" }
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
