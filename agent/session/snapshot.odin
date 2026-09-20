package session

import "nabla:db"

INSTRUCTION_SNAPSHOT_VERSION :: 1

Instruction_Snapshot :: struct {
	format_version: u32,
	instructions:   string,
	manifest_json:  string,
	seq:            Seq,
}

instruction_snapshot_destroy :: proc(snapshot: ^Instruction_Snapshot, allocator := context.allocator) {
	if snapshot == nil { return }
	delete(snapshot.instructions, allocator)
	delete(snapshot.manifest_json, allocator)
	snapshot^ = {}
}

instruction_snapshot_append :: proc(store: ^Store, id: Session_Id, snapshot: Instruction_Snapshot, at_ms: i64) -> (seq: Seq, err: Error) {
	require_claim(store, id) or_return
	if snapshot.format_version !=
	   INSTRUCTION_SNAPSHOT_VERSION { return 0, error_make(.Invalid_Argument, "an instruction snapshot needs the current format version") }
	if snapshot.instructions == "" { return 0, error_make(.Invalid_Argument, "an instruction snapshot needs instructions") }
	if snapshot.manifest_json == "" { return 0, error_make(.Invalid_Argument, "an instruction snapshot needs a manifest") }
	if at_ms <= 0 { return 0, error_make(.Invalid_Argument, "an instruction snapshot needs a timestamp") }

	if err := db.exec(&store.conn, "BEGIN IMMEDIATE"); err != nil { return 0, storage_error("begin snapshot write", err) }
	committed := false
	defer if !committed { abandon_transaction(store) }

	existing, existing_err := scalar_i64(store, SNAPSHOT_COUNT, {db.Value(string(id))})
	if existing_err != nil { return 0, existing_err }
	if existing > 0 { return 0, error_make(.Invalid_Argument, "an instruction snapshot already exists") }

	base, base_err := scalar_i64(store, ENTRY_NEXT_SEQ, {db.Value(string(id))})
	if base_err != nil { return 0, base_err }
	payload := Instruction_Snapshot_Entry {
		format_version = snapshot.format_version,
		instructions   = snapshot.instructions,
		manifest_json  = snapshot.manifest_json,
	}
	entry := New_Entry {
		created_at_ms = at_ms,
		payload       = payload,
	}
	if validate_err := validate_new_entry(store, id, Seq(base), entry); validate_err != nil { return 0, validate_err }
	if insert_err := insert_entry(store, id, Seq(base), entry); insert_err != nil { return 0, insert_err }
	if touch_err := touch_session(store, id, at_ms); touch_err != nil { return 0, touch_err }
	if err := db.commit(&store.conn); err != nil { return 0, storage_error("commit snapshot write", err) }
	committed = true
	return Seq(base), nil
}

instruction_snapshot_read :: proc(
	store: ^Store,
	id: Session_Id,
	allocator := context.allocator,
) -> (
	snapshot: Instruction_Snapshot,
	present: bool,
	err: Error,
) {
	if !store.open { return {}, false, error_make(.Invalid_State, "the store is closed") }
	entries, read_err := entries_read(store, SNAPSHOT_SELECT, {db.Value(string(id))}, false, allocator)
	if read_err != nil { return {}, false, read_err }
	defer entries_destroy(entries, allocator)
	if len(entries) == 0 { return {}, false, nil }
	payload, is_snapshot := entries[0].payload.(Instruction_Snapshot_Entry)
	if !is_snapshot { return {}, false, error_make(.Corrupt, "the instruction snapshot does not hold a snapshot payload") }
	snapshot = Instruction_Snapshot {
		format_version = payload.format_version,
		instructions   = clone_snapshot_text(payload.instructions, allocator),
		manifest_json  = clone_snapshot_text(payload.manifest_json, allocator),
		seq            = entries[0].seq,
	}
	return snapshot, true, nil
}

clone_snapshot_text :: proc(value: string, allocator := context.allocator) -> string {
	out := make([]u8, len(value), allocator)
	copy(out, transmute([]u8)value)
	return string(out)
}

@(private)
SNAPSHOT_COUNT :: `SELECT COUNT(*) FROM entries WHERE session_id = ? AND kind = 'instruction_snapshot'`

@(private)
SNAPSHOT_SELECT :: `SELECT ` + ENTRY_COLUMNS + ` FROM entries WHERE session_id = ? AND kind = 'instruction_snapshot' ORDER BY seq LIMIT 1`
