package journal

import "base:runtime"
import "core:crypto/hash"
import "core:mem"
import "core:mem/virtual"
import "core:os"

import "nabla:ai"
import "nabla:db"

Queue_Kind :: enum {
	Steering,
	Follow_Up,
}
Queue_Entry :: struct {
	id:          u64,
	kind:        Queue_Kind,
	text:        string,
	held:        bool,
	attachments: []string,
}

// queue_push adds an entry without a session claim. A busy error leaves no changes.
@(require_results)
queue_push :: proc(journal: ^Journal, session: Session_Id, kind: Queue_Kind, text: string, attachments: []string) -> (id: u64, error: Error) {
	session := session
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	db.exec(&journal.connection, "BEGIN IMMEDIATE") or_return
	defer if error != nil {
		if rollback_error := db.rollback(&journal.connection); rollback_error != nil && error_is_busy(error) { error = rollback_error }
	}
	args := [1]db.Value{db.Value(session[:])}
	db.exec(
		&journal.connection,
		`INSERT INTO prompt_queue_counter (session, last_id) VALUES (?, 1) ON CONFLICT(session) DO UPDATE SET last_id = last_id + 1`,
		args[:],
	) or_return
	value := query_int(journal, `SELECT last_id FROM prompt_queue_counter WHERE session = ?`, args[:]) or_return
	insert := [4]db.Value{db.Value(session[:]), db.Value(value), db.Value(i64(kind)), db.Value(text)}
	db.exec(&journal.connection, `INSERT INTO prompt_queue (session, id, kind, text) VALUES (?, ?, ?, ?)`, insert[:]) or_return
	for path, ordinal in attachments {
		args := [4]db.Value{db.Value(session[:]), db.Value(value), db.Value(i64(ordinal)), db.Value(path)}
		db.exec(&journal.connection, `INSERT INTO prompt_queue_attachment (session, id, ordinal, path) VALUES (?, ?, ?, ?)`, args[:]) or_return
	}
	db.commit(&journal.connection) or_return
	queue_notify(journal, session)
	return u64(value), nil
}

// queue_list returns entries oldest first, owned by allocator. Release them with queue_entries_destroy.
@(require_results)
queue_list :: proc(journal: ^Journal, session: Session_Id, allocator: mem.Allocator) -> (entries: []Queue_Entry, error: Error) {
	session := session
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	db.exec(&journal.connection, "BEGIN") or_return
	defer if error != nil { _ = db.rollback(&journal.connection) }
	list := make([dynamic]Queue_Entry, allocator) or_return
	defer if error != nil { queue_entries_destroy(list[:], allocator) }
	rows: db.Rows
	defer _ = db.rows_close(&rows)
	db.query(&journal.connection, &rows, `SELECT id, kind, text, held FROM prompt_queue WHERE session = ? ORDER BY id`, {db.Value(session[:])}) or_return
	for {
		values, found := db.rows_next(&rows) or_return
		if !found { break }
		row := Row {
			values    = values,
			allocator = allocator,
		}
		entry := Queue_Entry {
			id   = u64(row_int(&row)),
			kind = Queue_Kind(row_int(&row)),
			text = row_text(&row),
		}
		entry.held = row_int(&row) != 0
		if row.error != nil { delete(entry.text, allocator); return nil, row.error }
		if _, append_error := append(&list, entry); append_error != nil { queue_entry_destroy(&entry, allocator); return nil, append_error }
	}
	db.rows_close(&rows) or_return
	for &entry in list {
		entry.attachments = queue_paths(journal, session, entry.id, allocator) or_return
	}
	db.commit(&journal.connection) or_return
	return list[:], nil
}

@(private, require_results)
queue_paths :: proc(journal: ^Journal, session: Session_Id, id: u64, allocator: mem.Allocator) -> (paths: []string, error: Error) {
	session := session
	list := make([dynamic]string, allocator) or_return
	defer if error != nil { history_destroy(list[:], allocator) }
	rows: db.Rows
	defer _ = db.rows_close(&rows)
	db.query(
		&journal.connection,
		&rows,
		`SELECT path FROM prompt_queue_attachment WHERE session = ? AND id = ? ORDER BY ordinal`,
		{db.Value(session[:]), db.Value(i64(id))},
	) or_return
	for {
		values, found := db.rows_next(&rows) or_return
		if !found { break }
		row := Row {
			values    = values,
			allocator = allocator,
		}
		path := row_text(&row)
		if row.error != nil { return nil, row.error }
		if _, append_error := append(&list, path); append_error != nil { delete(path, allocator); return nil, append_error }
	}
	return list[:], nil
}

@(private)
queue_entry_destroy :: proc(entry: ^Queue_Entry, allocator: mem.Allocator) {
	delete(entry.text, allocator)
	for path in entry.attachments { delete(path, allocator) }
	delete(entry.attachments, allocator)
}

// queue_entries_destroy releases the result of queue_list with its allocator.
queue_entries_destroy :: proc(entries: []Queue_Entry, allocator: mem.Allocator) {
	for &entry in entries { queue_entry_destroy(&entry, allocator) }
	delete(entries, allocator)
}

// queue_edit changes an unheld entry and reports whether it existed and was not held.
@(require_results)
queue_edit :: proc(journal: ^Journal, session: Session_Id, id: u64, text: string) -> (found: bool, error: Error) {
	session := session
	return queue_change(
		journal,
		`UPDATE prompt_queue SET text = ? WHERE session = ? AND id = ? AND held = 0 RETURNING id`,
		session,
		{db.Value(text), db.Value(session[:]), db.Value(i64(id))},
	)
}

// queue_remove removes an undelivered entry and reports whether it existed.
@(require_results)
queue_remove :: proc(journal: ^Journal, session: Session_Id, id: u64) -> (found: bool, error: Error) {
	session := session
	return queue_change(journal, `DELETE FROM prompt_queue WHERE session = ? AND id = ? RETURNING id`, session, {db.Value(session[:]), db.Value(i64(id))})
}

@(private, require_results)
queue_change :: proc(journal: ^Journal, sql: string, session: Session_Id, args: []db.Value) -> (found: bool, error: Error) {
	rows: db.Rows
	defer if close_error := db.rows_close(&rows); error == nil { error = close_error }
	db.query(&journal.connection, &rows, sql, args) or_return
	_, found = db.rows_next(&rows) or_return
	db.rows_close(&rows) or_return
	if found { queue_notify(journal, session) }
	return found, nil
}

// queue_hold marks an unheld entry and returns its current text, owned by allocator. A missing or already held entry returns found false.
@(require_results)
queue_hold :: proc(journal: ^Journal, session: Session_Id, id: u64, allocator: mem.Allocator) -> (text: string, found: bool, error: Error) {
	session := session
	db.exec(&journal.connection, "BEGIN IMMEDIATE") or_return
	defer if error != nil {
		delete(text, allocator)
		text = ""
		if rollback_error := db.rollback(&journal.connection); rollback_error != nil && error_is_busy(error) { error = rollback_error }
	}
	rows: db.Rows
	defer _ = db.rows_close(&rows)
	db.query(
		&journal.connection,
		&rows,
		`UPDATE prompt_queue SET held = 1 WHERE session = ? AND id = ? AND held = 0 RETURNING text`,
		{db.Value(session[:]), db.Value(i64(id))},
	) or_return
	values, has_row := db.rows_next(&rows) or_return
	if has_row {
		row := Row {
			values    = values,
			allocator = allocator,
		}
		text = row_text(&row)
		if row.error != nil { return "", false, row.error }
	}
	db.rows_close(&rows) or_return
	db.commit(&journal.connection) or_return
	if has_row { queue_notify(journal, session) }
	return text, has_row, nil
}

// queue_release updates the text and clears the hold, or removes the entry if text is empty. It reports whether the entry existed.
@(require_results)
queue_release :: proc(journal: ^Journal, session: Session_Id, id: u64, text: string) -> (found: bool, error: Error) {
	session := session
	if text == "" {
		return queue_remove(journal, session, id)
	}
	return queue_change(
		journal,
		`UPDATE prompt_queue SET text = ?, held = 0 WHERE session = ? AND id = ? RETURNING id`,
		session,
		{db.Value(text), db.Value(session[:]), db.Value(i64(id))},
	)
}

// queue_unhold clears the hold without changing text and reports whether the entry existed.
@(require_results)
queue_unhold :: proc(journal: ^Journal, session: Session_Id, id: u64) -> (found: bool, error: Error) {
	session := session
	return queue_change(
		journal,
		`UPDATE prompt_queue SET held = 0 WHERE session = ? AND id = ? RETURNING id`,
		session,
		{db.Value(session[:]), db.Value(i64(id))},
	)
}

// queue_notify wakes a watcher after a queue mutation is durable. As with commit, a failed touch only delays the wake.
@(private)
queue_notify :: proc(journal: ^Journal, session: Session_Id) {
	if journal.lock_file != nil && (journal.claimed == session || journal.followed == session) {
		_ = claim_file_touch(journal.lock_file)
		return
	}
	file, error := lock_open(journal, session)
	if error != nil { return }
	_ = claim_file_touch(file)
	_ = os.close(file)
}

// history_append adds a submitted prompt without requiring a session claim.
@(require_results)
history_append :: proc(journal: ^Journal, session: Session_Id, text: string) -> (error: Error) {
	session := session
	db.exec(&journal.connection, "BEGIN IMMEDIATE") or_return
	defer if error != nil {
		if rollback_error := db.rollback(&journal.connection); rollback_error != nil && error_is_busy(error) { error = rollback_error }
	}
	args := [4]db.Value{db.Value(session[:]), db.Value(session[:]), db.Value(text), db.Value(now_ms())}
	db.exec(
		&journal.connection,
		`INSERT INTO prompt_history (session, ordinal, text, time_ms) VALUES (?, (SELECT COALESCE(MAX(ordinal), 0) + 1 FROM prompt_history WHERE session = ?), ?, ?)`,
		args[:],
	) or_return
	return db.commit(&journal.connection)
}

// history_list returns prompt texts oldest first, owned by allocator. Release them with history_destroy.
@(require_results)
history_list :: proc(journal: ^Journal, session: Session_Id, allocator: mem.Allocator) -> (history: []string, error: Error) {
	session := session
	list := make([dynamic]string, allocator) or_return
	defer if error != nil { history_destroy(list[:], allocator) }
	rows: db.Rows
	defer _ = db.rows_close(&rows)
	db.query(&journal.connection, &rows, `SELECT text FROM prompt_history WHERE session = ? ORDER BY ordinal`, {db.Value(session[:])}) or_return
	for {
		values, found := db.rows_next(&rows) or_return
		if !found { break }
		row := Row {
			values    = values,
			allocator = allocator,
		}
		text := row_text(&row)
		if row.error != nil { return nil, row.error }
		if _, append_error := append(&list, text); append_error != nil { delete(text, allocator); return nil, append_error }
	}
	return list[:], nil
}

// history_destroy releases the result of history_list with its allocator.
history_destroy :: proc(history: []string, allocator: mem.Allocator) {
	for text in history { delete(text, allocator) }
	delete(history, allocator)
}

// Queue_Delivery is filled after a successful commit. seq is zero if the row was gone, held, or blocked by an earlier held row of the same kind.
Queue_Delivery :: struct {
	completed: bool,
	seq:       Journal_Seq,
}

@(private)
Queue_Delivery_Row :: struct {
	session:     Session_Id,
	id:          u64,
	attachments: []ai.Provider_Attachment,
	result:      ^Queue_Delivery,
	seq:         Journal_Seq,
}

// queue_deliver buffers delivery of an entry belonging to the claimed session. The caller loads the listed paths into attachments before calling. result must
// remain live until commit succeeds or the journal closes. A successful commit sets completed and seq, which is zero if the row was removed, held, or blocked by
// an earlier held row of the same kind. A busy commit keeps the delivery pending, and a failed commit never deletes the row. Attachments are copied for the pending batch.
queue_deliver :: proc(journal: ^Journal, session: Session_Id, id: u64, attachments: []ai.Provider_Attachment, result: ^Queue_Delivery) {
	assert(result != nil)
	assert(session == journal.claimed && session != {}, "delivery needs the session claim")
	result^ = {}
	if !writable(journal, session) { return }
	copied, error := make([]ai.Provider_Attachment, len(attachments), virtual.arena_allocator(&journal.batch))
	if error != nil { latch(journal, error); return }
	for attachment, index in attachments {
		copied[index] = {
			Media = attachment.Media,
			Name  = batch_text(journal, attachment.Name),
			Data  = batch_bytes(journal, attachment.Data),
		}
	}
	push(journal, Queue_Delivery_Row{session = session, id = id, attachments = copied, result = result})
}

@(private, require_results)
queue_write_delivery :: proc(journal: ^Journal, delivery: ^Queue_Delivery_Row) -> (seq: Journal_Seq, error: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	delivery.seq = 0
	rows: db.Rows
	defer _ = db.rows_close(&rows)
	args := [2]db.Value{id_or_null(&delivery.session), db.Value(i64(delivery.id))}
	db.query(
		&journal.connection,
		&rows,
		`SELECT queued.kind, queued.text FROM prompt_queue AS queued WHERE queued.session = ? AND queued.id = ? AND queued.held = 0 AND NOT EXISTS (SELECT 1 FROM prompt_queue AS earlier WHERE earlier.session = queued.session AND earlier.kind = queued.kind AND earlier.id < queued.id AND earlier.held = 1)`,
		args[:],
	) or_return
	values, found := db.rows_next(&rows) or_return
	if !found { return 0, nil }
	row := Row {
		values    = values,
		allocator = context.temp_allocator,
	}
	kind := Queue_Kind(row_int(&row))
	text := row_text(&row)
	if row.error != nil { return 0, row.error }
	db.rows_close(&rows) or_return
	origin := User_Origin.Prompt
	if kind == .Steering { origin = .Steering }
	record := Record {
		kind    = .User_Input,
		session = delivery.session,
		run     = journal.run,
		time_ms = now_ms(),
		mono_ns = now_mono_ns(),
		body    = transmute([]u8)text,
	}
	seq = insert_record(journal, &record) or_return
	db.exec(&journal.connection, `INSERT INTO record_user_input (seq, origin) VALUES (?, ?)`, {db.Value(i64(seq)), db.Value(i64(origin))}) or_return
	for attachment, ordinal in delivery.attachments {
		digest: Digest
		hash.hash_bytes_to_buffer(.SHA256, attachment.Data, digest[:])
		artifact := [4]db.Value{db.Value(digest[:]), db.Value(ATTACHMENT_ARTIFACT), db.Value(now_ms()), db.Value(attachment.Data)}
		db.statement_exec(&journal.inserts[.Artifact], artifact[:]) or_return
		reference := [5]db.Value {
			db.Value(i64(seq)),
			db.Value(i64(ordinal)),
			db.Value(ai.PROVIDER_MEDIA_TYPES[attachment.Media]),
			db.Value(attachment.Name),
			db.Value(digest[:]),
		}
		db.exec(&journal.connection, `INSERT INTO record_attachment (seq, ordinal, media_type, name, digest) VALUES (?, ?, ?, ?, ?)`, reference[:]) or_return
	}
	db.exec(&journal.connection, `DELETE FROM prompt_queue WHERE session = ? AND id = ?`, args[:]) or_return
	delivery.seq = seq
	return seq, nil
}
