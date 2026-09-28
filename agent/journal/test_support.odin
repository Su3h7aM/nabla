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
	version: int,
	detail:  string,
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
	for index in 0 ..< len(id) { id[index] = 0xab }
	return id
}

_expect_ok :: proc(test: ^testing.T, error: Error) {
	if error == nil { return }
	testing.fail_now(test, fmt.tprintf("unexpected error: %s", _describe(error)))
}

// _body is the exact bytes a node's body holds. The journal copies them, so a
// view of the literal is enough.
_body :: proc(text: string) -> []u8 {
	return transmute([]u8)text
}

_expect_error :: proc(test: ^testing.T, error: Error, kind: Journal_Error) {
	if error_is(error, kind) { return }
	testing.expectf(test, false, "expected %v, got %s", kind, _describe(error))
}

_expect_db_ok :: proc(test: ^testing.T, error: db.Error) {
	if error == nil { return }
	local := error
	testing.fail_now(test, fmt.tprintf("unexpected database error: %s", db.error_message(&local)))
}

// _describe is the failure an error carries, whichever layer produced it.
_describe :: proc(error: Error) -> string {
	if error == nil { return "success" }
	switch value in error {
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

_temp_directory :: proc(test: ^testing.T) -> string {
	directory, error := os.make_directory_temp("", "nabla-journal-test-*", context.allocator)
	if error != nil { testing.fail_now(test, "could not create a temporary directory") }
	// A journal admits the owner alone, so the directory it is pointed at is
	// the owner's alone as well.
	_expect_ok(test, os.chmod(directory, PRIVATE_DIRECTORY_PERMISSIONS))
	return directory
}

_remove_directory :: proc(directory: string) {
	// The suite's directory is abandoned; a removal that fails changes nothing in a test.
	_ = os.remove_all(directory)
	delete(directory, context.allocator)
}

_open_journal :: proc(test: ^testing.T, journal: ^Journal, directory: string, mode := Open_Mode.Read_Write) {
	_expect_ok(test, open(journal, directory, _test_run_id(), mode))
}

_close_journal :: proc(test: ^testing.T, journal: ^Journal) {
	if error := close(journal); error != nil {
		testing.expectf(test, false, "closing the journal failed: %s", _describe(error))
	}
}

_create_session :: proc(test: ^testing.T, journal: ^Journal, new_session: New_Session) -> Session_Id {
	session, error := create_session(journal, new_session)
	_expect_ok(test, error)
	return session
}

// _commit_ok commits and returns the seq the journal reached.
_commit_ok :: proc(test: ^testing.T, journal: ^Journal) -> Journal_Seq {
	seq, error := commit(journal)
	_expect_ok(test, error)
	return seq
}

_decode_payload :: proc(test: ^testing.T, data: string, payload: ^$Payload) {
	if len(data) == 0 { testing.fail_now(test, "a record has no payload to read") }
	if error := json.unmarshal(transmute([]u8)data, payload, allocator = context.temp_allocator); error != nil {
		testing.fail_now(test, fmt.tprintf("a payload could not be decoded: %v", error))
	}
}

// _records_of_session reads every record of one session and leaves it to the
// caller to release.
_records_of_session :: proc(test: ^testing.T, journal: ^Journal, session: Session_Id) -> []Record {
	records, _, error := read_records(journal, Filter{session = session}, 0, 0, context.allocator)
	_expect_ok(test, error)
	return records
}

// _record_seq_of_kind is the seq of the first record of one kind, or 0.
_record_seq_of_kind :: proc(records: []Record, kind: Record_Kind) -> Journal_Seq {
	for record in records {
		if record.kind == kind { return record.seq }
	}
	return 0
}

OTHERS_ACCESS :: os.Permissions{.Read_Group, .Write_Group, .Execute_Group, .Read_Other, .Write_Other, .Execute_Other}
