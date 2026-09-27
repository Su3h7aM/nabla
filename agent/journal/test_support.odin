#+test
package journal

// Helpers shared by this package's test files. They are package-private rather
// than file-private so every suite uses one definition, and the file only
// compiles under `odin test`.

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"

import "nabla:db"

// _Test_Payload stands in for a payload kind whose struct this phase does not
// declare: the write path needs a struct with a leading version field, and the
// harness declares the rest of them when it records those facts.
_Test_Payload :: struct {
	v:      int,
	detail: string,
}

// _test_run_id is one process run for a whole suite. Every record a test writes
// names it.
_test_run_id :: proc() -> Run_Id {
	run: Run_Id
	run[0] = 1
	return run
}

// _absent_session is an id no test creates.
_absent_session :: proc() -> Session_Id {
	id: Session_Id
	for i in 0 ..< len(id) { id[i] = 0xab }
	return id
}

_expect_ok :: proc(t: ^testing.T, err: Error) {
	if err == nil { return }
	testing.fail_now(t, fmt.tprintf("unexpected error: %s", _describe(err)))
}

// _body is the exact bytes a node's body holds. The journal copies them, so a
// view of the literal is enough.
_body :: proc(text: string) -> []u8 {
	return transmute([]u8)text
}

_expect_error :: proc(t: ^testing.T, err: Error, kind: Journal_Error) {
	if error_is(err, kind) { return }
	testing.expectf(t, false, "expected %v, got %s", kind, _describe(err))
}

_expect_db_ok :: proc(t: ^testing.T, err: db.Error) {
	if err == nil { return }
	local := err
	testing.fail_now(t, fmt.tprintf("unexpected database error: %s", db.error_message(&local)))
}

// _describe is the failure an error carries, whichever layer produced it.
_describe :: proc(err: Error) -> string {
	if err == nil { return "success" }
	switch value in err {
	case Journal_Error:
		return fmt.tprintf("journal error %v", value)
	case db.Error:
		local := value
		return fmt.tprintf("database error: %s", db.error_message(&local))
	case os.Error:
		return fmt.tprintf("filesystem error: %s", os.error_string(value))
	case mem.Allocator_Error:
		return fmt.tprintf("allocator error %v", value)
	case json.Marshal_Error:
		return fmt.tprintf("encoding error %v", value)
	case:
		return "unknown error"
	}
}

_temp_directory :: proc(t: ^testing.T) -> string {
	directory, err := os.make_directory_temp("", "nabla-journal-test-*", context.allocator)
	if err != nil { testing.fail_now(t, "could not create a temporary directory") }
	// A journal admits the owner alone, so the directory it is pointed at is
	// the owner's alone as well.
	_expect_ok(t, os.chmod(directory, PRIVATE_DIRECTORY_PERMISSIONS))
	return directory
}

_remove_directory :: proc(directory: string) {
	_ = os.remove_all(directory)
	delete(directory, context.allocator)
}

_open_journal :: proc(t: ^testing.T, j: ^Journal, directory: string, mode := Open_Mode.Read_Write) {
	_expect_ok(t, open(j, directory, _test_run_id(), mode))
}

_close_journal :: proc(t: ^testing.T, j: ^Journal) {
	if err := close(j); err != nil {
		testing.expectf(t, false, "closing the journal failed: %s", _describe(err))
	}
}

_create_session :: proc(t: ^testing.T, j: ^Journal, info: Session_Info) -> Session_Id {
	session, err := create_session(j, info)
	_expect_ok(t, err)
	return session
}

// _commit_ok commits and returns the seq the journal reached.
_commit_ok :: proc(t: ^testing.T, j: ^Journal) -> Journal_Seq {
	seq, err := commit(j)
	_expect_ok(t, err)
	return seq
}

_decode_payload :: proc(t: ^testing.T, data: string, payload: ^$T) {
	if len(data) == 0 { testing.fail_now(t, "a record has no payload to read") }
	if err := json.unmarshal(transmute([]u8)data, payload, allocator = context.temp_allocator); err != nil {
		testing.fail_now(t, fmt.tprintf("a payload could not be decoded: %v", err))
	}
}

// _records_of_session reads every record of one session and leaves it to the
// caller to release.
_records_of_session :: proc(t: ^testing.T, j: ^Journal, session: Session_Id) -> []Record {
	records, _, err := read_records(j, Filter{session = session}, 0, 0, context.allocator)
	_expect_ok(t, err)
	return records
}

// _record_seq_of_kind is the seq of the first record of one kind, or 0.
_record_seq_of_kind :: proc(records: []Record, kind: Record_Kind) -> Journal_Seq {
	for record in records {
		if record.kind == kind { return record.seq }
	}
	return 0
}
