package journal

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strings"

import "nabla:db"

// Filter selects records. A zero field matches anything; empty kinds or nodes
// match every kind or node.
Filter :: struct {
	session: Session_Id,
	kinds:   bit_set[Record_Kind;u128],
	turn:    Turn_Id,
	request: Request_Id,
	call:    Call_Id,
	nodes:   []Node_Id,
}

// Session_Filter selects sessions. The zero value lists all of them, newest
// activity first.
Session_Filter :: struct {
	workspace: string,
	role:      Maybe(Session_Role),
	limit:     int, // 0 lists every match
	before:    Journal_Seq, // continues a listing below this last_seq
}

Session_Summary :: struct {
	id:             Session_Id,
	created_ms:     i64,
	workspace:      string,
	role:           Session_Role,
	parent_session: Session_Id,
	parent_call:    Call_Id,
	title:          string, // "" until a session.titled record names it
	last_seq:       Journal_Seq,
}

Branch_Summary :: struct {
	id:             Branch_Id,
	base_node:      Node_Id,
	head:           Node_Id, // 0 while the branch holds no node
	last_user_text: string,
	seq:            Journal_Seq,
}

// Usage_Totals sums what the session's committed responses reported. The
// paired fields cover only the responses that reported every token count, the
// one population a cache hit rate may be measured over.
Usage_Totals :: struct {
	requests:        int,
	paired_requests: int,
	input:           i64,
	output:          i64,
	cache_read:      i64,
	cache_write:     i64,
	paired_input:    i64,
	paired_read:     i64,
}

// read_records returns the matching records with seq above after, oldest first,
// at most page of them (page <= 0 reads all), and the last seq read (after when
// none). The result is owned by allocator; release it with records_destroy.
@(require_results)
read_records :: proc(j: ^Journal, f: Filter, after: Journal_Seq, page: int, allocator: mem.Allocator) -> (records: []Record, last: Journal_Seq, err: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	assert(j.open)
	filter := f
	query := Query{}
	query_start(&query, "SELECT " + RECORD_COLUMNS + " FROM records WHERE seq > ?", i64(after)) or_return
	query_filter(&query, &filter) or_return
	query_add(&query, " ORDER BY seq ASC") or_return
	if page > 0 { query_add(&query, " LIMIT ?", i64(page)) or_return }

	rows: db.Rows
	defer db.rows_close(&rows)
	db.query(&j.conn, &rows, strings.to_string(query.sql), query.args[:]) or_return

	list := make([dynamic]Record, allocator) or_return
	defer if err != nil { records_destroy(list[:], allocator) }
	for {
		values, has_row := db.rows_next(&rows) or_return
		if !has_row { break }
		row := Row {
			values    = values,
			allocator = allocator,
		}
		record := scan_record(&row)
		if row.err != nil {
			record_destroy(&record, allocator)
			return nil, after, corrupt(j, row.err, record.session, record.seq)
		}
		if _, append_err := append(&list, record); append_err != nil {
			record_destroy(&record, allocator)
			return nil, after, append_err
		}
	}
	last = after
	if len(list) > 0 { last = list[len(list) - 1].seq }
	return list[:], last, nil
}

// read_latest returns the matching record with the highest seq, false when none
// matches. Release it with record_destroy.
@(require_results)
read_latest :: proc(j: ^Journal, f: Filter, allocator: mem.Allocator) -> (record: Record, found: bool, err: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	assert(j.open)
	filter := f
	query := Query{}
	query_start(&query, "SELECT " + RECORD_COLUMNS + " FROM records WHERE 1 = 1") or_return
	query_filter(&query, &filter) or_return
	query_add(&query, " ORDER BY seq DESC LIMIT 1") or_return

	rows: db.Rows
	defer db.rows_close(&rows)
	db.query(&j.conn, &rows, strings.to_string(query.sql), query.args[:]) or_return
	values, has_row := db.rows_next(&rows) or_return
	if !has_row { return {}, false, nil }
	row := Row {
		values    = values,
		allocator = allocator,
	}
	record = scan_record(&row)
	if row.err != nil {
		record_destroy(&record, allocator)
		return {}, false, corrupt(j, row.err, record.session, record.seq)
	}
	return record, true, nil
}

// read_ancestry returns the nodes a projection walks to head, oldest first. At
// the first Checkpoint K on the way, covering F, it returns K, then the nodes
// after F through K's parent, then the nodes after K; nodes up to F are not
// read. Release the result with nodes_destroy.
@(require_results)
read_ancestry :: proc(j: ^Journal, s: Session_Id, head: Node_Id, allocator: mem.Allocator) -> (nodes: []Node, err: Error) {
	assert(j.open)
	list := make([dynamic]Node, allocator) or_return
	defer if err != nil { nodes_destroy(list[:], allocator) }

	// K is appended after the nodes before it, so one reverse gives the order.
	checkpoint: Maybe(Node)
	defer if err != nil {
		if node, has := checkpoint.?; has { node_destroy(&node, allocator) }
	}
	stop := Node_Id(0)
	for walk := head; walk != 0 && walk != stop; {
		node := read_node(j, s, walk, allocator) or_return
		// Ids grow in commit order, so a parent at or above its child is damage
		// that would otherwise loop.
		if node.parent >= walk {
			node_destroy(&node, allocator)
			return nil, corrupt(j, Journal_Error.Corrupt, s, node.seq)
		}
		walk = node.parent
		if node.kind == .Checkpoint && checkpoint == nil {
			checkpoint = node
			stop = node.covers
			continue
		}
		if _, append_err := append(&list, node); append_err != nil {
			node_destroy(&node, allocator)
			return nil, append_err
		}
	}
	if node, has := checkpoint.?; has {
		append(&list, node) or_return
		checkpoint = nil
	}
	slice.reverse(list[:])
	return list[:], nil
}

// session_head returns the active branch (the latest `branch.selected`, else
// the initial one) and its head (its highest node, else its base node).
@(require_results)
session_head :: proc(j: ^Journal, s: Session_Id) -> (branch: Branch_Id, head: Node_Id, err: Error) {
	assert(j.open)
	session := s
	rows: db.Rows
	defer db.rows_close(&rows)
	row := query_first(j, &rows, SESSION_HEAD_QUERY, {db.Value(session[:]), db.Value(i64(INITIAL_BRANCH))}) or_return
	branch = Branch_Id(row_int(&row))
	head = Node_Id(row_int(&row))
	if row.err != nil { return 0, 0, corrupt(j, row.err, s, 0) }
	return
}

// read_artifact returns the bytes stored under digest, owned by allocator.
@(require_results)
read_artifact :: proc(j: ^Journal, digest: Digest, allocator: mem.Allocator) -> (bytes: []u8, found: bool, err: Error) {
	assert(j.open)
	key := digest
	rows: db.Rows
	defer db.rows_close(&rows)
	db.query(&j.conn, &rows, "SELECT bytes FROM artifacts WHERE digest = ?", {db.Value(key[:])}) or_return
	values, has_row := db.rows_next(&rows) or_return
	if !has_row { return nil, false, nil }
	row := Row {
		values    = values,
		allocator = allocator,
	}
	bytes = row_bytes(&row)
	if row.err != nil { return nil, false, corrupt(j, row.err, {}, 0) }
	return bytes, true, nil
}

@(require_results)
usage_totals :: proc(j: ^Journal, s: Session_Id) -> (totals: Usage_Totals, err: Error) {
	assert(j.open)
	session := s
	rows: db.Rows
	defer db.rows_close(&rows)
	row := query_first(j, &rows, USAGE_TOTALS_QUERY, {db.Value(session[:])}) or_return
	totals.requests = int(row_int(&row))
	totals.paired_requests = int(row_int(&row))
	totals.input = row_int(&row)
	totals.output = row_int(&row)
	totals.cache_read = row_int(&row)
	totals.cache_write = row_int(&row)
	totals.paired_input = row_int(&row)
	totals.paired_read = row_int(&row)
	if row.err != nil { return {}, corrupt(j, row.err, s, 0) }
	return totals, nil
}

// cache_hit_rate is the share of paired input the provider read from its cache.
cache_hit_rate :: proc(totals: Usage_Totals) -> (rate: f64, measured: bool) {
	if totals.paired_input <= 0 || totals.paired_read > totals.paired_input { return 0, false }
	return f64(totals.paired_read) / f64(totals.paired_input), true
}

// cache_coverage is the share of all reported input the hit rate rests on.
cache_coverage :: proc(totals: Usage_Totals) -> (share: f64, measured: bool) {
	if totals.input <= 0 { return 0, false }
	return f64(totals.paired_input) / f64(totals.input), true
}

// list_sessions returns sessions by latest activity. Release the result with
// session_summaries_destroy.
@(require_results)
list_sessions :: proc(j: ^Journal, f: Session_Filter, allocator: mem.Allocator) -> (sessions: []Session_Summary, err: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	assert(j.open)
	query := Query{}
	query_start(&query, SESSION_LIST_QUERY) or_return
	if f.workspace != "" { query_add(&query, " AND workspace = ?", f.workspace) or_return }
	if role, has_role := f.role.?; has_role { query_add(&query, " AND role = ?", SESSION_ROLE_NAMES[role]) or_return }
	if f.before != 0 { query_add(&query, " AND last_seq < ?", i64(f.before)) or_return }
	query_add(&query, " ORDER BY last_seq DESC, session DESC") or_return
	if f.limit > 0 { query_add(&query, " LIMIT ?", i64(f.limit)) or_return }

	rows: db.Rows
	defer db.rows_close(&rows)
	db.query(&j.conn, &rows, strings.to_string(query.sql), query.args[:]) or_return

	list := make([dynamic]Session_Summary, allocator) or_return
	defer if err != nil { session_summaries_destroy(list[:], allocator) }
	for {
		values, has_row := db.rows_next(&rows) or_return
		if !has_row { break }
		row := Row {
			values    = values,
			allocator = allocator,
		}
		summary: Session_Summary
		summary.id = Session_Id(row_id(&row))
		summary.created_ms = row_int(&row)
		summary.workspace = row_text(&row)
		summary.role = row_enum(&row, SESSION_ROLE_NAMES)
		summary.parent_session = Session_Id(row_id(&row))
		summary.parent_call = Call_Id(row_int(&row))
		summary.title = row_text(&row)
		summary.last_seq = Journal_Seq(row_int(&row))
		if row.err != nil {
			session_summary_destroy(&summary, allocator)
			return nil, corrupt(j, row.err, summary.id, 0)
		}
		if _, append_err := append(&list, summary); append_err != nil {
			session_summary_destroy(&summary, allocator)
			return nil, append_err
		}
	}
	return list[:], nil
}

// list_branches returns a session's branches in creation order. Release the
// result with branch_summaries_destroy.
@(require_results)
list_branches :: proc(j: ^Journal, s: Session_Id, allocator: mem.Allocator) -> (branches: []Branch_Summary, err: Error) {
	assert(j.open)
	session := s
	rows: db.Rows
	defer db.rows_close(&rows)
	db.query(&j.conn, &rows, BRANCH_LIST_QUERY, {db.Value(session[:])}) or_return

	list := make([dynamic]Branch_Summary, allocator) or_return
	defer if err != nil { branch_summaries_destroy(list[:], allocator) }
	for {
		values, has_row := db.rows_next(&rows) or_return
		if !has_row { break }
		row := Row {
			values    = values,
			allocator = allocator,
		}
		branch: Branch_Summary
		branch.id = Branch_Id(row_int(&row))
		branch.base_node = Node_Id(row_int(&row))
		branch.seq = Journal_Seq(row_int(&row))
		branch.head = Node_Id(row_int(&row))
		branch.last_user_text = row_text(&row)
		if row.err != nil {
			branch_summary_destroy(&branch, allocator)
			return nil, corrupt(j, row.err, s, branch.seq)
		}
		if _, append_err := append(&list, branch); append_err != nil {
			branch_summary_destroy(&branch, allocator)
			return nil, append_err
		}
	}
	return list[:], nil
}

record_destroy :: proc(record: ^Record, allocator := context.allocator) {
	delete(record.task, allocator)
	delete(record.hook, allocator)
	delete(record.provider, allocator)
	delete(record.model, allocator)
	delete(record.data, allocator)
	delete(record.body, allocator)
	record^ = {}
}

records_destroy :: proc(records: []Record, allocator := context.allocator) {
	for &record in records { record_destroy(&record, allocator) }
	delete(records, allocator)
}

node_destroy :: proc(node: ^Node, allocator := context.allocator) {
	delete(node.data, allocator)
	delete(node.body, allocator)
	node^ = {}
}

nodes_destroy :: proc(nodes: []Node, allocator := context.allocator) {
	for &node in nodes { node_destroy(&node, allocator) }
	delete(nodes, allocator)
}

session_summary_destroy :: proc(summary: ^Session_Summary, allocator := context.allocator) {
	delete(summary.workspace, allocator)
	delete(summary.title, allocator)
	summary^ = {}
}

session_summaries_destroy :: proc(summaries: []Session_Summary, allocator := context.allocator) {
	for &summary in summaries { session_summary_destroy(&summary, allocator) }
	delete(summaries, allocator)
}

branch_summary_destroy :: proc(summary: ^Branch_Summary, allocator := context.allocator) {
	delete(summary.last_user_text, allocator)
	summary^ = {}
}

branch_summaries_destroy :: proc(summaries: []Branch_Summary, allocator := context.allocator) {
	for &summary in summaries { branch_summary_destroy(&summary, allocator) }
	delete(summaries, allocator)
}

@(private)
RECORD_COLUMNS :: "seq, time_ms, mono_ns, run, kind, session, branch, node, turn, request, attempt, job, call, parent_call, task, subagent, hook, provider, model, data, body"

@(private)
NODE_QUERY :: "SELECT session, node, parent, branch, kind, turn, covers, seq, data, body FROM nodes WHERE session = ? AND node = ?"

@(private)
SESSION_LIST_QUERY :: `SELECT * FROM (
	SELECT session, created_ms, workspace, role, parent_session, parent_call,
		COALESCE((SELECT json_extract(data, '$.title') FROM records AS titled
			WHERE titled.session = sessions.session AND titled.kind = 'session.titled' ORDER BY titled.seq DESC LIMIT 1), '') AS title,
		COALESCE((SELECT MAX(seq) FROM records WHERE records.session = sessions.session), 0) AS last_seq
	FROM sessions)
WHERE 1 = 1`

@(private)
BRANCH_LIST_QUERY :: `SELECT branch, base_node, seq,
	COALESCE((SELECT MAX(node) FROM nodes WHERE nodes.session = branches.session AND nodes.branch = branches.branch), 0),
	COALESCE((SELECT CAST(body AS TEXT) FROM nodes WHERE nodes.session = branches.session AND nodes.branch = branches.branch AND nodes.kind = 'user' ORDER BY node DESC LIMIT 1), '')
FROM branches WHERE session = ? ORDER BY branch`

@(private)
SESSION_HEAD_QUERY :: `WITH active AS (SELECT COALESCE(
	(SELECT branch FROM records WHERE session = ?1 AND kind = 'branch.selected' AND branch IS NOT NULL ORDER BY seq DESC LIMIT 1),
	?2) AS branch)
SELECT active.branch, COALESCE(
	(SELECT MAX(node) FROM nodes WHERE session = ?1 AND nodes.branch = active.branch),
	(SELECT base_node FROM branches WHERE session = ?1 AND branches.branch = active.branch),
	0)
FROM active`

// A count the provider did not report is JSON null, which SUM and the paired
// test both skip, so it never enters a total as zero.
@(private)
USAGE_TOTALS_QUERY :: `WITH reported AS (SELECT
	json_extract(data, '$.input_tokens') AS input,
	json_extract(data, '$.output_tokens') AS output,
	json_extract(data, '$.cache_read_tokens') AS cache_read,
	json_extract(data, '$.cache_write_tokens') AS cache_write
	FROM records WHERE session = ? AND kind = 'response.committed'),
paired AS (SELECT *, (input IS NOT NULL AND output IS NOT NULL AND cache_read IS NOT NULL AND cache_write IS NOT NULL) AS both FROM reported)
SELECT COUNT(*), COALESCE(SUM(both), 0),
	COALESCE(SUM(input), 0), COALESCE(SUM(output), 0), COALESCE(SUM(cache_read), 0), COALESCE(SUM(cache_write), 0),
	COALESCE(SUM(CASE WHEN both THEN input END), 0), COALESCE(SUM(CASE WHEN both THEN cache_read END), 0)
FROM paired`

@(private)
read_node :: proc(j: ^Journal, s: Session_Id, id: Node_Id, allocator: mem.Allocator) -> (node: Node, err: Error) {
	session := s
	rows: db.Rows
	defer db.rows_close(&rows)
	db.query(&j.conn, &rows, NODE_QUERY, {db.Value(session[:]), db.Value(i64(id))}) or_return
	values, has_row := db.rows_next(&rows) or_return
	// A missing node is a parent the tree promised.
	if !has_row { return {}, corrupt(j, Journal_Error.Corrupt, s, 0) }
	row := Row {
		values    = values,
		allocator = allocator,
	}
	node.session = Session_Id(row_id(&row))
	node.id = Node_Id(row_int(&row))
	node.parent = Node_Id(row_int(&row))
	node.branch = Branch_Id(row_int(&row))
	node.kind = row_enum(&row, NODE_KIND_NAMES)
	node.turn = Turn_Id(row_int(&row))
	node.covers = Node_Id(row_int(&row))
	node.seq = Journal_Seq(row_int(&row))
	node.data = row_text(&row)
	node.body = row_bytes(&row)
	if row.err != nil {
		node_destroy(&node, allocator)
		return {}, corrupt(j, row.err, s, node.seq)
	}
	return node, nil
}

@(private)
scan_record :: proc(row: ^Row) -> (record: Record) {
	record.seq = Journal_Seq(row_int(row))
	record.time_ms = row_int(row)
	record.mono_ns = row_int(row)
	record.run = Run_Id(row_id(row))
	record.kind = row_enum(row, RECORD_KIND_NAMES)
	record.session = Session_Id(row_id(row))
	record.branch = Branch_Id(row_int(row))
	record.node = Node_Id(row_int(row))
	record.turn = Turn_Id(row_int(row))
	record.request = Request_Id(row_int(row))
	record.attempt = Attempt_No(row_int(row))
	record.job = Job_Id(row_int(row))
	record.call = Call_Id(row_int(row))
	record.parent_call = Call_Id(row_int(row))
	record.task = row_text(row)
	record.subagent = Session_Id(row_id(row))
	record.hook = row_text(row)
	record.provider = row_text(row)
	record.model = row_text(row)
	record.data = row_text(row)
	record.body = row_bytes(row)
	return
}

// corrupt names the damaged row when a read fails on stored data. A lower
// failure such as allocation passes through unchanged.
@(private)
corrupt :: proc(j: ^Journal, err: Error, session: Session_Id, seq: Journal_Seq) -> Error {
	if error_is(err, .Corrupt) { j.corrupt = {session, seq} }
	return err
}

// Query builds SQL and its bound arguments in temp memory.
@(private)
Query :: struct {
	sql:  strings.Builder,
	args: [dynamic]db.Value,
}

@(private)
query_start :: proc(query: ^Query, sql: string, args: ..db.Value) -> mem.Allocator_Error {
	query.sql = strings.builder_make(context.temp_allocator) or_return
	query.args = make([dynamic]db.Value, context.temp_allocator) or_return
	return query_add(query, sql, ..args)
}

@(private)
query_add :: proc(query: ^Query, sql: string, args: ..db.Value) -> mem.Allocator_Error {
	strings.write_string(&query.sql, sql)
	_, err := append(&query.args, ..args)
	return err
}

// query_filter binds the session id by reference, so filter must outlive the query.
@(private)
query_filter :: proc(query: ^Query, filter: ^Filter) -> mem.Allocator_Error {
	if filter.session != {} { query_add(query, " AND session = ?", db.Value(filter.session[:])) or_return }
	if filter.turn != 0 { query_add(query, " AND turn = ?", i64(filter.turn)) or_return }
	if filter.request != 0 { query_add(query, " AND request = ?", i64(filter.request)) or_return }
	if filter.call != 0 { query_add(query, " AND call = ?", i64(filter.call)) or_return }
	if filter.kinds != {} {
		query_add(query, " AND kind IN (") or_return
		separator := ""
		for kind in filter.kinds {
			query_add(query, separator) or_return
			query_add(query, "?", RECORD_KIND_NAMES[kind]) or_return
			separator = ", "
		}
		query_add(query, ")") or_return
	}
	if len(filter.nodes) > 0 {
		query_add(query, " AND node IN (") or_return
		for node, i in filter.nodes {
			query_add(query, ", ?" if i > 0 else "?", i64(node)) or_return
		}
		query_add(query, ")") or_return
	}
	return nil
}

// query_first runs a query that yields one row and returns it. The caller
// closes rows.
@(private)
query_first :: proc(j: ^Journal, rows: ^db.Rows, sql: string, args: []db.Value) -> (row: Row, err: Error) {
	db.query(&j.conn, rows, sql, args) or_return
	values, has_row := db.rows_next(rows) or_return
	if !has_row { return {}, Journal_Error.Corrupt }
	return Row{values = values}, nil
}

@(private)
query_int :: proc(j: ^Journal, sql: string, args: []db.Value) -> (value: i64, err: Error) {
	rows: db.Rows
	defer db.rows_close(&rows)
	row := query_first(j, &rows, sql, args) or_return
	value = row_int(&row)
	return value, row.err
}

// Row reads the columns of one result row in order. The first failure is kept
// in err and later reads return zero values, so a scan checks err once.
@(private)
Row :: struct {
	values:    []db.Value,
	column:    int,
	allocator: mem.Allocator,
	err:       Error,
}

@(private)
row_next :: proc(row: ^Row) -> (db.Value, bool) {
	if row.err != nil { return nil, false }
	if row.column >= len(row.values) {
		row.err = Journal_Error.Corrupt
		return nil, false
	}
	value := row.values[row.column]
	row.column += 1
	return value, true
}

// row_int reads an integer; NULL is 0, the absent id.
@(private)
row_int :: proc(row: ^Row) -> i64 {
	value, ok := row_next(row)
	if !ok { return {} }
	if value == nil { return 0 }
	number, err := db.as_i64(value)
	if err != nil { row.err = Journal_Error.Corrupt }
	return number
}

// row_id reads a 16-byte id; NULL is the absent id.
@(private)
row_id :: proc(row: ^Row) -> (id: [16]u8) {
	value, ok := row_next(row)
	if !ok { return {} }
	if value == nil { return }
	bytes, err := db.as_bytes(value)
	if err != nil || len(bytes) != len(id) {
		row.err = Journal_Error.Corrupt
		return
	}
	copy(id[:], bytes)
	return
}

// row_view reads text without copying; it lives as long as the row.
@(private)
row_view :: proc(row: ^Row) -> string {
	value, ok := row_next(row)
	if !ok { return {} }
	if value == nil { return "" }
	text, err := db.as_string(value)
	if err != nil { row.err = Journal_Error.Corrupt }
	return text
}

@(private)
row_text :: proc(row: ^Row) -> string {
	text := row_view(row)
	if row.err != nil || text == "" { return "" }
	copied, err := strings.clone(text, row.allocator)
	if err != nil { row.err = err }
	return copied
}

// row_bytes copies a blob; NULL and empty are both nil.
@(private)
row_bytes :: proc(row: ^Row) -> []u8 {
	value, ok := row_next(row)
	if !ok { return {} }
	if value == nil { return nil }
	bytes, err := db.as_bytes(value)
	if err != nil {
		row.err = Journal_Error.Corrupt
		return nil
	}
	if len(bytes) == 0 { return nil }
	copied, clone_err := slice.clone(bytes, row.allocator)
	if clone_err != nil { row.err = clone_err }
	return copied
}

@(private)
row_enum :: proc(row: ^Row, names: [$E]string) -> E {
	name := row_view(row)
	if row.err != nil { return {} }
	value, known := enum_from_name(names, name)
	if !known { row.err = Journal_Error.Corrupt }
	return value
}
