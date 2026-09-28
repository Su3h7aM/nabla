#+test
#+private file
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent"
import "nabla:agent/journal"

@(test)
test_diagnostics_reads_journal_in_order_and_filters_runtime_level :: proc(test: ^testing.T) {
	if !test_isolate_process(test, #procedure) { return }
	diagnostics_request_state(test, "stream", proc(test: ^testing.T) {
		directory, directory_error := agent.xdg_directory(.State, context.temp_allocator)
		if directory_error != .None { testing.fail_now(test, "state directory unavailable") }
		store: journal.Journal
		diagnostics_request_expect(test, journal.open(&store, directory, journal.run_id_create(), .Read_Write))
		session, create_error := journal.create_session(&store, {workspace = "/tmp/project", role = .Main})
		diagnostics_request_expect(test, create_error)
		for turn in 1 ..= 2 {
			journal.append_record(
				&store,
				{kind = .Turn_Started, session = session, branch = journal.INITIAL_BRANCH, turn = journal.Turn_Id(turn)},
				journal.Turn_Started{model = "model"},
			)
		}
		journal.append_record(&store, {kind = .Runtime_Message, session = session, turn = 2}, journal.Runtime_Message{level = "debug", text = "hidden"})
		journal.append_record(&store, {kind = .Runtime_Message, session = session, turn = 2}, journal.Runtime_Message{level = "error", text = "shown"})
		_, commit_error := journal.commit(&store)
		diagnostics_request_expect(test, commit_error)
		diagnostics_request_expect(test, journal.close(&store))
		buffer: [journal.SESSION_ID_HEX_LENGTH]u8
		arguments := [5]string{journal.session_id_to_hex(session, buffer[:]), "--turn", "2", "--level", "warn"}
		output, errors: strings.Builder
		defer strings.builder_destroy(&output)
		defer strings.builder_destroy(&errors)
		testing.expect_value(test, diagnostics_main(arguments[:], strings.to_writer(&output), strings.to_writer(&errors)), 0)
		text := strings.to_string(output)
		testing.expect(test, strings.contains(text, `"kind":"turn.started"`))
		testing.expect(test, strings.contains(text, `"text":"shown"`))
		testing.expect(test, !strings.contains(text, `"text":"hidden"`))
		testing.expect_value(test, strings.count(text, `"kind":"turn.started"`), 1)
	})
}

@(test)
test_diagnostics_missing_journal_is_read_only :: proc(test: ^testing.T) {
	if !test_isolate_process(test, #procedure) { return }
	diagnostics_request_state(test, "absent", proc(test: ^testing.T) {
		arguments := [1]string{"00112233445566778899aabbccddeeff"}
		output, errors: strings.Builder
		defer strings.builder_destroy(&output)
		defer strings.builder_destroy(&errors)
		file_directory, directory_error := agent.xdg_directory(.State, context.allocator)
		if directory_error != .None { testing.fail_now(test, "state directory unavailable") }
		defer delete(file_directory, context.allocator)
		testing.expect_value(test, diagnostics_main(arguments[:], strings.to_writer(&output), strings.to_writer(&errors)), 1)
		testing.expect(test, !os.exists(fmt.tprintf("%s/%s", file_directory, journal.DATABASE_NAME)))
	})
}
