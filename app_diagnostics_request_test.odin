#+test
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent"
import "nabla:agent/journal"

// Environment changes stay in the isolated child process.
diagnostics_request_state :: proc(test: ^testing.T, name: string, body: proc(test: ^testing.T)) {
	root := fmt.aprintf("/tmp/nabla-diag-state-%s-%d", name, os.get_pid())
	defer {
		_ = os.remove_all(root)
		delete(root)
	}
	previous, present := os.lookup_env("XDG_STATE_HOME", context.temp_allocator)
	defer if present { _ = os.set_env("XDG_STATE_HOME", previous) } else { _ = os.unset_env("XDG_STATE_HOME") }
	if os.set_env("XDG_STATE_HOME", root) != nil { testing.fail_now(test, "state root could not be set") }
	body(test)
}

diagnostics_request_expect :: proc(test: ^testing.T, error: journal.Error) {
	if error != nil { testing.fail_now(test, journal.error_text(error, context.temp_allocator)) }
}

diagnostics_request_fixture :: proc(test: ^testing.T) -> (session: journal.Session_Id, request: journal.Request_Id) {
	directory, directory_error := agent.xdg_directory(.State, context.temp_allocator)
	if directory_error != .None { testing.fail_now(test, "state directory unavailable") }
	store: journal.Journal
	diagnostics_request_expect(test, journal.open(&store, directory, journal.run_id_create(), .Read_Write))
	defer diagnostics_request_expect(test, journal.close(&store))
	create_error: journal.Error
	session, create_error = journal.create_session(&store, {workspace = "/tmp/project", role = .Main})
	diagnostics_request_expect(test, create_error)
	request = journal.next_request(&store)
	header := journal.Record {
		session  = session,
		branch   = journal.INITIAL_BRANCH,
		turn     = 1,
		request  = request,
		attempt  = 1,
		provider = "openai",
		model    = "gpt-4",
	}
	header.kind = .Request_Sent
	journal.append_record(&store, header, journal.Request_Sent{purpose = "response", api = "chat", model_requested = "gpt-4"})
	header.kind = .Response_Committed
	journal.append_record(&store, header, journal.Response_Committed{finish = "stop", model_resolved = "gpt-4", input_tokens = 10})
	_, commit_error := journal.commit(&store)
	diagnostics_request_expect(test, commit_error)
	return
}

@(test)
test_diagnostics_request_summary_and_export :: proc(test: ^testing.T) {
	if !test_isolate_process(test, #procedure) { return }
	diagnostics_request_state(test, "request", proc(test: ^testing.T) {
		session, request := diagnostics_request_fixture(test)
		buffer: [journal.SESSION_ID_HEX_LENGTH]u8
		session_text := journal.session_id_to_hex(session, buffer[:])
		destination := fmt.aprintf("/tmp/nabla-diag-request-export-%d", os.get_pid())
		defer {
			_ = os.remove_all(destination)
			delete(destination)
		}
		_ = os.remove_all(destination)
		arguments := [5]string{session_text, "--request", fmt.tprintf("%d", i64(request)), "--export", destination}
		output, errors: strings.Builder
		defer strings.builder_destroy(&output)
		defer strings.builder_destroy(&errors)
		testing.expect_value(test, diagnostics_main(arguments[:], strings.to_writer(&output), strings.to_writer(&errors)), 0)
		testing.expect(test, strings.contains(strings.to_string(errors), "input 10"))
		content, read_error := os.read_entire_file(fmt.tprintf("%s/request.json", destination), context.allocator)
		if read_error != nil { testing.fail_now(test, "request.json missing") }
		defer delete(content, context.allocator)
		value, parse_error := json.parse_string(string(content), parse_integers = true, allocator = context.allocator)
		if parse_error != .None { testing.fail_now(test, "request.json invalid") }
		defer json.destroy_value(value, context.allocator)
		object, valid := value.(json.Object)
		if !valid { testing.fail_now(test, "request.json is not an object") }
		testing.expect_value(test, i64(object["input_tokens"].(json.Integer)), i64(10))
		testing.expect_value(test, string(object["outcome"].(json.String)), "completed")
	})
}

@(test)
test_diagnostics_missing_request_reports_failure :: proc(test: ^testing.T) {
	if !test_isolate_process(test, #procedure) { return }
	diagnostics_request_state(test, "missing", proc(test: ^testing.T) {
		session, _ := diagnostics_request_fixture(test)
		buffer: [journal.SESSION_ID_HEX_LENGTH]u8
		arguments := [3]string{journal.session_id_to_hex(session, buffer[:]), "--request", "999"}
		output, errors: strings.Builder
		defer strings.builder_destroy(&output)
		defer strings.builder_destroy(&errors)
		testing.expect_value(test, diagnostics_main(arguments[:], strings.to_writer(&output), strings.to_writer(&errors)), 1)
		testing.expect(test, strings.contains(strings.to_string(errors), "could not be read"))
	})
}
