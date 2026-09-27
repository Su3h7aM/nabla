package journal

import "core:mem"
import "core:slice"
import "core:strings"

import "nabla:db"

// Filter selects records to read. A zero field means "any"; an empty kinds set
// means every kind.
Filter :: struct {
	session: Session_Id,
	kinds:   bit_set[Record_Kind;u128],
	turn:    Turn_Id,
	call:    Call_Id,
}

// Session_Filter selects sessions to list. The zero value lists every session
// in the journal, newest activity first, with no limit.
Session_Filter :: struct {
	// workspace, when not empty, lists only sessions that ran in that
	// directory.
	workspace: string,
	// role, when set, lists only sessions of that role.
	role:      Maybe(Session_Role),
	// limit bounds one page. Zero means no limit.
	limit:     int,
	// before continues a previous listing: only sessions whose last seq is
	// below it are listed.
	before:    Journal_Seq,
}

// Session_Summary is one session as a frontend lists it.
Session_Summary :: struct {
	id:             Session_Id,
	created_ms:     i64,
	workspace:      string, // owned
	role:           Session_Role,
	parent_session: Session_Id,
	parent_call:    Call_Id,
	title:          string, // owned; "" until a session.titled record names it
	last_seq:       Journal_Seq,
}

// Branch_Summary is one branch of a session as a frontend lists it. head is the
// node the branch is at, or 0 when it holds no node.
Branch_Summary :: struct {
	id:             Branch_Id,
	base_node:      Node_Id,
	head:           Node_Id,
	last_user_text: string, // owned; the body of the latest User node
	seq:            Journal_Seq,
}

// READ_RECORDS_MAX_ARGS is the most arguments read_records builds: the cursor,
// the session, one per kind, the turn, the call, and the page.
@(private)
READ_RECORDS_MAX_ARGS :: 2 + len(Record_Kind) + 3

// read_records returns the records of one session in commit order: those with a
// seq above `after`, at most `page` of them, and the seq of the last row read.
// With nothing to return that seq is `after`, so a caller continues from the
// same position. A page of zero or less reads every matching record.
//
// Every string and every body of the result is owned by allocator. Release the
// result with records_destroy.
@(require_results)
read_records :: proc(j: ^Journal, f: Filter, after: Journal_Seq, page: int, allocator: mem.Allocator) -> ([]Record, Journal_Seq, Error) {
	if !j.open { return nil, after, Journal_Error.Invalid_State }

	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "SELECT ")
	strings.write_string(&builder, RECORD_COLUMNS)
	strings.write_string(&builder, " FROM records WHERE seq > ?")
	args: [READ_RECORDS_MAX_ARGS]db.Value
	count := 0
	args[count] = db.Value(i64(after))
	count += 1

	session := f.session
	if !session_id_is_absent(session) {
		strings.write_string(&builder, " AND session = ?")
		args[count] = db.Value(session[:])
		count += 1
	}
	if card(f.kinds) > 0 {
		strings.write_string(&builder, " AND kind IN (")
		first := true
		for kind in Record_Kind {
			if kind not_in f.kinds { continue }
			if !first { strings.write_string(&builder, ", ") }
			first = false
			strings.write_string(&builder, "?")
			args[count] = db.Value(RECORD_KIND_NAMES[kind])
			count += 1
		}
		strings.write_string(&builder, ")")
	}
	if f.turn != 0 {
		strings.write_string(&builder, " AND turn = ?")
		args[count] = db.Value(i64(f.turn))
		count += 1
	}
	if f.call != 0 {
		strings.write_string(&builder, " AND call = ?")
		args[count] = db.Value(i64(f.call))
		count += 1
	}
	strings.write_string(&builder, " ORDER BY seq ASC")
	if page > 0 {
		strings.write_string(&builder, " LIMIT ?")
		args[count] = db.Value(i64(page))
		count += 1
	}

	rows: db.Rows
	if err := db.query(&j.conn, &rows, strings.to_string(builder), args[:count]); err != nil { return nil, after, err }
	defer db.rows_close(&rows)

	records := make([dynamic]Record, 0, read_capacity(page), allocator)
	transferred := false
	defer if !transferred {
		for &record in records { record_destroy(&record, allocator) }
		delete(records)
	}

	last := after
	for {
		values, has_row, next_err := db.rows_next(&rows)
		if next_err != nil { return nil, after, next_err }
		if !has_row { break }
		record, record_err := scan_record(j, values, allocator)
		if record_err != nil { return nil, after, record_err }
		appended, append_err := append(&records, record)
		if append_err != nil { return nil, after, append_err }
		if appended != 1 { return nil, after, mem.Allocator_Error.Out_Of_Memory }
		last = record.seq
	}

	transferred = true
	return records[:], last, nil
}

// read_ancestry returns the nodes a projection walks from head, oldest first.
//
// Walking parents from head stops at the first Checkpoint node K, which covers
// node F: the result is K, then the nodes after F up to and including K.parent,
// then the nodes after K up to head. Nodes at or before F are not loaded, which
// is what makes a checkpoint a replacement for the history it summarises.
// Without a checkpoint the result is the root up to head.
//
// A node whose parent is not in the session is a broken tree and reports
// .Corrupt. Every string and body of the result is owned by allocator; release
// it with nodes_destroy.
@(require_results)
read_ancestry :: proc(j: ^Journal, s: Session_Id, head: Node_Id, allocator: mem.Allocator) -> ([]Node, Error) {
	if !j.open { return nil, Journal_Error.Invalid_State }
	if head == 0 { return nil, nil }

	nodes := make([dynamic]Node, 0, ANCESTRY_HEADROOM, allocator)
	transferred := false
	defer if !transferred {
		for &node in nodes { node_destroy(&node, allocator) }
		delete(nodes)
	}

	checkpoint: Node
	have_checkpoint := false
	covered := Node_Id(0) // the node the checkpoint covers; not loaded itself
	walk := head
	for walk != 0 {
		if have_checkpoint && walk == covered { break }
		loaded, load_err := load_node(j, s, walk, allocator)
		if load_err != nil {
			node_destroy(&checkpoint, allocator)
			return nil, load_err
		}
		// A parent is always an earlier node: it was committed before its child
		// existed. A parent that is not is a broken tree, and following it would
		// walk for as long as the damage allows.
		if loaded.parent != 0 && loaded.parent >= walk {
			node_destroy(&loaded, allocator)
			node_destroy(&checkpoint, allocator)
			return nil, corrupt_row(j, s, loaded.seq)
		}
		if !have_checkpoint && loaded.kind == .Checkpoint {
			checkpoint = loaded
			have_checkpoint = true
			covered = loaded.covers
			walk = loaded.parent
			continue
		}
		appended, append_err := append(&nodes, loaded)
		if append_err != nil {
			node_destroy(&checkpoint, allocator)
			return nil, append_err
		}
		if appended != 1 {
			node_destroy(&loaded, allocator)
			node_destroy(&checkpoint, allocator)
			return nil, mem.Allocator_Error.Out_Of_Memory
		}
		walk = loaded.parent
	}
	// The walk collected the nodes after K, then the nodes above K, and appends
	// K last, so reversing the whole list is the order the projection reads.
	if have_checkpoint {
		appended, append_err := append(&nodes, checkpoint)
		if append_err != nil { return nil, append_err }
		if appended != 1 { return nil, mem.Allocator_Error.Out_Of_Memory }
	}
	slice.reverse(nodes[:])

	transferred = true
	return nodes[:], nil
}

// SESSION_LIST_MAX_ARGS is the most arguments list_sessions builds: the
// workspace, the role, the cursor, and the page.
@(private)
SESSION_LIST_MAX_ARGS :: 4

// list_sessions returns the sessions of the journal, newest activity first. A
// session's activity is the highest seq any of its records has, so the listing
// is one query over what was committed. Release the result with
// session_summaries_destroy.
@(require_results)
list_sessions :: proc(j: ^Journal, f: Session_Filter, allocator: mem.Allocator) -> ([]Session_Summary, Error) {
	if !j.open { return nil, Journal_Error.Invalid_State }

	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, SESSION_LIST_QUERY)
	args: [SESSION_LIST_MAX_ARGS]db.Value
	count := 0
	if f.workspace != "" {
		strings.write_string(&builder, " AND workspace = ?")
		args[count] = db.Value(f.workspace)
		count += 1
	}
	if role, has_role := f.role.?; has_role {
		strings.write_string(&builder, " AND role = ?")
		args[count] = db.Value(SESSION_ROLE_NAMES[role])
		count += 1
	}
	if f.before != 0 {
		strings.write_string(&builder, " AND last_seq < ?")
		args[count] = db.Value(i64(f.before))
		count += 1
	}
	strings.write_string(&builder, " ORDER BY last_seq DESC, session DESC")
	if f.limit > 0 {
		strings.write_string(&builder, " LIMIT ?")
		args[count] = db.Value(i64(f.limit))
		count += 1
	}

	rows: db.Rows
	if err := db.query(&j.conn, &rows, strings.to_string(builder), args[:count]); err != nil { return nil, err }
	defer db.rows_close(&rows)

	summaries := make([dynamic]Session_Summary, 0, read_capacity(f.limit), allocator)
	transferred := false
	defer if !transferred {
		for &summary in summaries { session_summary_destroy(&summary, allocator) }
		delete(summaries)
	}

	for {
		values, has_row, next_err := db.rows_next(&rows)
		if next_err != nil { return nil, next_err }
		if !has_row { break }
		summary, summary_err := scan_session_summary(j, values, allocator)
		if summary_err != nil { return nil, summary_err }
		appended, append_err := append(&summaries, summary)
		if append_err != nil { return nil, append_err }
		if appended != 1 { return nil, mem.Allocator_Error.Out_Of_Memory }
	}

	transferred = true
	return summaries[:], nil
}

// list_branches returns the branches of one session in the order they were
// created. Release the result with branch_summaries_destroy.
@(require_results)
list_branches :: proc(j: ^Journal, s: Session_Id, allocator: mem.Allocator) -> ([]Branch_Summary, Error) {
	if !j.open { return nil, Journal_Error.Invalid_State }

	session := s
	rows: db.Rows
	if err := db.query(&j.conn, &rows, BRANCH_LIST_QUERY, {db.Value(session[:])}); err != nil { return nil, err }
	defer db.rows_close(&rows)

	branches := make([dynamic]Branch_Summary, 0, BRANCH_HEADROOM, allocator)
	transferred := false
	defer if !transferred {
		for &branch in branches { branch_summary_destroy(&branch, allocator) }
		delete(branches)
	}

	for {
		values, has_row, next_err := db.rows_next(&rows)
		if next_err != nil { return nil, next_err }
		if !has_row { break }
		branch, branch_err := scan_branch_summary(j, values, allocator)
		if branch_err != nil { return nil, branch_err }
		appended, append_err := append(&branches, branch)
		if append_err != nil { return nil, append_err }
		if appended != 1 { return nil, mem.Allocator_Error.Out_Of_Memory }
	}

	transferred = true
	return branches[:], nil
}

// --- releasing --------------------------------------------------------------

// record_destroy releases everything one record owns.
record_destroy :: proc(record: ^Record, allocator := context.allocator) {
	if record == nil { return }
	delete(record.task, allocator)
	delete(record.hook, allocator)
	delete(record.provider, allocator)
	delete(record.model, allocator)
	delete(record.data, allocator)
	delete(record.body, allocator)
	record^ = {}
}

// records_destroy releases a result of read_records.
records_destroy :: proc(records: []Record, allocator := context.allocator) {
	for &record in records { record_destroy(&record, allocator) }
	delete(records, allocator)
}

// node_destroy releases everything one node owns.
node_destroy :: proc(node: ^Node, allocator := context.allocator) {
	if node == nil { return }
	delete(node.data, allocator)
	delete(node.body, allocator)
	node^ = {}
}

// nodes_destroy releases a result of read_ancestry.
nodes_destroy :: proc(nodes: []Node, allocator := context.allocator) {
	for &node in nodes { node_destroy(&node, allocator) }
	delete(nodes, allocator)
}

// session_summary_destroy releases everything one summary owns.
session_summary_destroy :: proc(summary: ^Session_Summary, allocator := context.allocator) {
	if summary == nil { return }
	delete(summary.workspace, allocator)
	delete(summary.title, allocator)
	summary^ = {}
}

// session_summaries_destroy releases a result of list_sessions.
session_summaries_destroy :: proc(summaries: []Session_Summary, allocator := context.allocator) {
	for &summary in summaries { session_summary_destroy(&summary, allocator) }
	delete(summaries, allocator)
}

// branch_summary_destroy releases everything one branch summary owns.
branch_summary_destroy :: proc(summary: ^Branch_Summary, allocator := context.allocator) {
	if summary == nil { return }
	delete(summary.last_user_text, allocator)
	summary^ = {}
}

// branch_summaries_destroy releases a result of list_branches.
branch_summaries_destroy :: proc(summaries: []Branch_Summary, allocator := context.allocator) {
	for &summary in summaries { branch_summary_destroy(&summary, allocator) }
	delete(summaries, allocator)
}

// --- reading rows -----------------------------------------------------------

@(private)
RECORD_COLUMNS :: `seq, time_ms, mono_ns, run, kind, session, branch, node, turn, request, attempt, job, call, parent_call, task, subagent, hook, provider, model, data, body`

// SESSION_LIST_QUERY reduces every session to what a listing shows. The title
// is the latest `session.titled` payload's, read with SQLite's own JSON
// functions, and the activity is the highest seq the session holds.
@(private)
SESSION_LIST_QUERY :: `WITH summaries AS (
	SELECT sessions.session AS session,
	       sessions.created_ms AS created_ms,
	       sessions.workspace AS workspace,
	       sessions.role AS role,
	       sessions.parent_session AS parent_session,
	       sessions.parent_call AS parent_call,
	       COALESCE((SELECT json_extract(records.data, '$.title') FROM records WHERE records.session = sessions.session AND records.kind = 'session.titled' ORDER BY records.seq DESC LIMIT 1), '') AS title,
	       COALESCE((SELECT MAX(records.seq) FROM records WHERE records.session = sessions.session), 0) AS last_seq
	FROM sessions
)
SELECT session, created_ms, workspace, role, parent_session, parent_call, title, last_seq
FROM summaries
WHERE 1 = 1`

// BRANCH_LIST_QUERY names each branch's head and the text of the latest User
// node on it, which is what a frontend shows when the user picks a branch.
@(private)
BRANCH_LIST_QUERY :: `SELECT branches.branch,
	branches.base_node,
	branches.seq,
	COALESCE((SELECT MAX(nodes.node) FROM nodes WHERE nodes.session = branches.session AND nodes.branch = branches.branch), 0) AS head,
	COALESCE((SELECT CAST(nodes.body AS TEXT) FROM nodes WHERE nodes.session = branches.session AND nodes.branch = branches.branch AND nodes.kind = 'user' ORDER BY nodes.node DESC LIMIT 1), '') AS last_user_text
FROM branches
WHERE branches.session = ?
ORDER BY branches.branch ASC`

@(private)
NODE_SELECT_ONE :: `SELECT session, node, parent, branch, kind, turn, covers, seq, data, body FROM nodes WHERE session = ? AND node = ?`

@(private)
ANCESTRY_HEADROOM :: 16

@(private)
BRANCH_HEADROOM :: 4

// read_capacity is how many rows a result starts with: the page when the caller
// bounded it, and otherwise something small that grows with the result.
@(private)
read_capacity :: proc(page: int) -> int {
	if page <= 0 { return 16 }
	return min(page, 256)
}

// corrupt_row records the row that could not be read and reports it, so the
// harness can name the session and seq rather than only the kind.
@(private)
corrupt_row :: proc(j: ^Journal, session: Session_Id, seq: Journal_Seq) -> Error {
	j.corrupt = Corruption {
		session = session,
		seq     = seq,
	}
	return Journal_Error.Corrupt
}

// load_node reads one node of a session. A node that is not there is a parent
// the tree promised and does not have, so it is corrupt data.
@(private)
load_node :: proc(j: ^Journal, session: Session_Id, id: Node_Id, allocator: mem.Allocator) -> (Node, Error) {
	owner := session
	rows: db.Rows
	if err := db.query(&j.conn, &rows, NODE_SELECT_ONE, {db.Value(owner[:]), db.Value(i64(id))}); err != nil {
		return {}, err
	}
	defer db.rows_close(&rows)

	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return {}, next_err }
	if !has_row { return {}, corrupt_row(j, session, 0) }
	return scan_node(j, values, allocator)
}

@(private)
scan_record :: proc(j: ^Journal, values: []db.Value, allocator: mem.Allocator) -> (record: Record, err: Error) {
	transferred := false
	defer if !transferred { record_destroy(&record, allocator) }

	seq, seq_err := db.as_i64(values[0])
	if seq_err != nil { return {}, corrupt_row(j, Session_Id{}, 0) }
	record.seq = Journal_Seq(seq)

	session, session_ok := read_session_id(values[5])
	if !session_ok { return {}, corrupt_row(j, Session_Id{}, record.seq) }
	record.session = session

	run, run_ok := read_run_id(values[3])
	if !run_ok { return {}, corrupt_row(j, session, record.seq) }
	record.run = run

	time_ms, time_err := db.as_i64(values[1])
	if time_err != nil { return {}, corrupt_row(j, session, record.seq) }
	record.time_ms = time_ms
	mono_ns, mono_err := db.as_i64(values[2])
	if mono_err != nil { return {}, corrupt_row(j, session, record.seq) }
	record.mono_ns = mono_ns

	kind_name, kind_err := db.as_string(values[4])
	if kind_err != nil { return {}, corrupt_row(j, session, record.seq) }
	kind, kind_ok := record_kind_from_name(kind_name)
	if !kind_ok { return {}, corrupt_row(j, session, record.seq) }
	record.kind = kind

	branch, branch_ok := optional_id(values[6])
	if !branch_ok { return {}, corrupt_row(j, session, record.seq) }
	record.branch = Branch_Id(branch)
	node, node_ok := optional_id(values[7])
	if !node_ok { return {}, corrupt_row(j, session, record.seq) }
	record.node = Node_Id(node)
	turn, turn_ok := optional_id(values[8])
	if !turn_ok { return {}, corrupt_row(j, session, record.seq) }
	record.turn = Turn_Id(turn)
	request, request_ok := optional_id(values[9])
	if !request_ok { return {}, corrupt_row(j, session, record.seq) }
	record.request = Request_Id(request)
	attempt, attempt_ok := optional_id(values[10])
	if !attempt_ok { return {}, corrupt_row(j, session, record.seq) }
	record.attempt = Attempt_No(attempt)
	job, job_ok := optional_id(values[11])
	if !job_ok { return {}, corrupt_row(j, session, record.seq) }
	record.job = Job_Id(job)
	call, call_ok := optional_id(values[12])
	if !call_ok { return {}, corrupt_row(j, session, record.seq) }
	record.call = Call_Id(call)
	parent_call, parent_ok := optional_id(values[13])
	if !parent_ok { return {}, corrupt_row(j, session, record.seq) }
	record.parent_call = Call_Id(parent_call)

	task, task_ok := clone_text(values[14], allocator)
	if !task_ok { return {}, corrupt_row(j, session, record.seq) }
	record.task = task
	subagent, subagent_ok := read_session_id(values[15])
	if !subagent_ok { return {}, corrupt_row(j, session, record.seq) }
	record.subagent = subagent
	hook, hook_ok := clone_text(values[16], allocator)
	if !hook_ok { return {}, corrupt_row(j, session, record.seq) }
	record.hook = hook
	provider, provider_ok := clone_text(values[17], allocator)
	if !provider_ok { return {}, corrupt_row(j, session, record.seq) }
	record.provider = provider
	model, model_ok := clone_text(values[18], allocator)
	if !model_ok { return {}, corrupt_row(j, session, record.seq) }
	record.model = model

	data, data_ok := clone_text(values[19], allocator)
	if !data_ok { return {}, corrupt_row(j, session, record.seq) }
	record.data = data
	body, body_ok := clone_bytes(values[20], allocator)
	if !body_ok { return {}, corrupt_row(j, session, record.seq) }
	record.body = body

	transferred = true
	return record, nil
}

@(private)
scan_node :: proc(j: ^Journal, values: []db.Value, allocator: mem.Allocator) -> (node: Node, err: Error) {
	transferred := false
	defer if !transferred { node_destroy(&node, allocator) }

	session, session_ok := read_session_id(values[0])
	if !session_ok { return {}, corrupt_row(j, Session_Id{}, 0) }
	node.session = session

	id, id_err := db.as_i64(values[1])
	if id_err != nil { return {}, corrupt_row(j, session, 0) }
	node.id = Node_Id(id)
	parent, parent_ok := optional_id(values[2])
	if !parent_ok { return {}, corrupt_row(j, session, node.seq) }
	node.parent = Node_Id(parent)
	branch, branch_err := db.as_i64(values[3])
	if branch_err != nil { return {}, corrupt_row(j, session, node.seq) }
	node.branch = Branch_Id(branch)
	kind_name, kind_err := db.as_string(values[4])
	if kind_err != nil { return {}, corrupt_row(j, session, node.seq) }
	kind, kind_ok := node_kind_from_name(kind_name)
	if !kind_ok { return {}, corrupt_row(j, session, node.seq) }
	node.kind = kind
	turn, turn_ok := optional_id(values[5])
	if !turn_ok { return {}, corrupt_row(j, session, node.seq) }
	node.turn = Turn_Id(turn)
	covers, covers_ok := optional_id(values[6])
	if !covers_ok { return {}, corrupt_row(j, session, node.seq) }
	node.covers = Node_Id(covers)
	seq, seq_err := db.as_i64(values[7])
	if seq_err != nil { return {}, corrupt_row(j, session, node.seq) }
	node.seq = Journal_Seq(seq)

	data, data_ok := clone_text(values[8], allocator)
	if !data_ok { return {}, corrupt_row(j, session, node.seq) }
	node.data = data
	body, body_ok := clone_bytes(values[9], allocator)
	if !body_ok { return {}, corrupt_row(j, session, node.seq) }
	node.body = body

	transferred = true
	return node, nil
}

@(private)
scan_session_summary :: proc(j: ^Journal, values: []db.Value, allocator: mem.Allocator) -> (summary: Session_Summary, err: Error) {
	transferred := false
	defer if !transferred { session_summary_destroy(&summary, allocator) }

	id, id_ok := read_session_id(values[0])
	if !id_ok { return {}, corrupt_row(j, Session_Id{}, 0) }
	summary.id = id

	created_ms, created_err := db.as_i64(values[1])
	if created_err != nil { return {}, corrupt_row(j, id, 0) }
	summary.created_ms = created_ms
	workspace, workspace_ok := clone_text(values[2], allocator)
	if !workspace_ok { return {}, corrupt_row(j, id, 0) }
	summary.workspace = workspace
	role_name, role_err := db.as_string(values[3])
	if role_err != nil { return {}, corrupt_row(j, id, 0) }
	role, role_ok := session_role_from_name(role_name)
	if !role_ok { return {}, corrupt_row(j, id, 0) }
	summary.role = role
	parent, parent_ok := read_session_id(values[4])
	if !parent_ok { return {}, corrupt_row(j, id, 0) }
	summary.parent_session = parent
	parent_call, parent_call_ok := optional_id(values[5])
	if !parent_call_ok { return {}, corrupt_row(j, id, 0) }
	summary.parent_call = Call_Id(parent_call)
	title, title_ok := clone_text(values[6], allocator)
	if !title_ok { return {}, corrupt_row(j, id, 0) }
	summary.title = title
	last_seq, last_seq_err := db.as_i64(values[7])
	if last_seq_err != nil { return {}, corrupt_row(j, id, 0) }
	summary.last_seq = Journal_Seq(last_seq)

	transferred = true
	return summary, nil
}

@(private)
scan_branch_summary :: proc(j: ^Journal, values: []db.Value, allocator: mem.Allocator) -> (summary: Branch_Summary, err: Error) {
	transferred := false
	defer if !transferred { branch_summary_destroy(&summary, allocator) }

	branch, branch_err := db.as_i64(values[0])
	if branch_err != nil { return {}, corrupt_row(j, Session_Id{}, 0) }
	summary.id = Branch_Id(branch)
	base, base_err := db.as_i64(values[1])
	if base_err != nil { return {}, corrupt_row(j, Session_Id{}, 0) }
	summary.base_node = Node_Id(base)
	seq, seq_err := db.as_i64(values[2])
	if seq_err != nil { return {}, corrupt_row(j, Session_Id{}, 0) }
	summary.seq = Journal_Seq(seq)
	head, head_err := db.as_i64(values[3])
	if head_err != nil { return {}, corrupt_row(j, Session_Id{}, 0) }
	summary.head = Node_Id(head)
	text, text_ok := clone_text(values[4], allocator)
	if !text_ok { return {}, corrupt_row(j, Session_Id{}, 0) }
	summary.last_user_text = text

	transferred = true
	return summary, nil
}

// --- reading values ---------------------------------------------------------

// optional_id reads an integer column whose NULL is the absent value.
@(private)
optional_id :: proc(value: db.Value) -> (i64, bool) {
	if value == nil { return 0, true }
	number, err := db.as_i64(value)
	if err != nil { return 0, false }
	return number, true
}

// read_session_id reads a 16-byte session column, absent when NULL.
@(private)
read_session_id :: proc(value: db.Value) -> (Session_Id, bool) {
	raw, ok := read_id_bytes(value)
	if !ok { return Session_Id{}, false }
	return Session_Id(raw), true
}

// read_run_id reads the run column, which is never absent.
@(private)
read_run_id :: proc(value: db.Value) -> (Run_Id, bool) {
	raw, ok := read_id_bytes(value)
	if !ok { return Run_Id{}, false }
	return Run_Id(raw), true
}

@(private)
read_id_bytes :: proc(value: db.Value) -> ([16]u8, bool) {
	if value == nil { return {}, true }
	bytes, err := db.as_bytes(value)
	if err != nil || len(bytes) != 16 { return {}, false }
	raw: [16]u8
	copy(raw[:], bytes)
	return raw, true
}

// clone_text copies one text column into the caller's allocator. NULL is the
// empty text.
@(private)
clone_text :: proc(value: db.Value, allocator: mem.Allocator) -> (string, bool) {
	if value == nil { return "", true }
	text, err := db.as_string(value)
	if err != nil { return "", false }
	if text == "" { return "", true }
	copied := strings.clone(text, allocator)
	if copied == "" { return "", false }
	return copied, true
}

// clone_bytes copies one blob column into the caller's allocator. NULL and the
// empty blob are the same absent body.
@(private)
clone_bytes :: proc(value: db.Value, allocator: mem.Allocator) -> ([]u8, bool) {
	if value == nil { return nil, true }
	bytes, err := db.as_bytes(value)
	if err != nil { return nil, false }
	if len(bytes) == 0 { return nil, true }
	buffer, alloc_err := mem.alloc_bytes(len(bytes), 1, allocator)
	if alloc_err != nil { return nil, false }
	copy(buffer, bytes)
	return buffer, true
}
