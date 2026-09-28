#+test
#+private file
package main

import "core:crypto/sha2"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent"
import "nabla:agent/journal"

@(test)
test_export_session_payload_and_manifest_digest :: proc(test: ^testing.T) {
	if !test_isolate_process(test, #procedure) { return }
	diagnostics_request_state(test, "bundle", proc(test: ^testing.T) {
		directory, directory_error := agent.xdg_directory(.State, context.temp_allocator)
		if directory_error != .None { testing.fail_now(test, "state directory unavailable") }
		store: journal.Journal
		diagnostics_request_expect(test, journal.open(&store, directory, directory, journal.run_id_create(), .Read_Write))
		session, create_error := journal.create_session(&store, {workspace = "/tmp/project", role = .Main})
		diagnostics_request_expect(test, create_error)
		payload := "private payload"
		journal.append_record(
			&store,
			{kind = .Turn_Started, session = session, branch = journal.INITIAL_BRANCH, turn = 1},
			journal.Turn_Started{model = "gpt-4"},
			transmute([]u8)payload,
		)
		_, commit_error := journal.commit(&store)
		diagnostics_request_expect(test, commit_error)
		diagnostics_request_expect(test, journal.close(&store))
		buffer: [journal.SESSION_ID_HEX_LENGTH]u8
		session_text := journal.session_id_to_hex(session, buffer[:])
		for iteration in 0 ..< 2 {
			include_payloads := iteration == 1
			destination := fmt.aprintf("/tmp/nabla-diag-export-%d-%v", os.get_pid(), include_payloads)
			defer {
				_ = os.remove_all(destination)
				delete(destination)
			}
			_ = os.remove_all(destination)
			arguments := [4]string{session_text, "--export", destination, "--include-payloads"}
			if !include_payloads { arguments = [4]string{session_text, "--export", destination, ""} }
			output, errors: strings.Builder
			defer strings.builder_destroy(&output)
			defer strings.builder_destroy(&errors)
			argument_count := include_payloads ? 4 : 3
			testing.expect_value(test, diagnostics_main(arguments[:argument_count], strings.to_writer(&output), strings.to_writer(&errors)), 0)
			session_bytes, session_error := os.read_entire_file(fmt.tprintf("%s/session.jsonl", destination), context.allocator)
			if session_error != nil { testing.fail_now(test, "session stream missing") }
			defer delete(session_bytes, context.allocator)
			testing.expect(test, strings.contains(string(session_bytes), `"kind":"turn.started"`))
			testing.expect_value(test, strings.contains(string(session_bytes), "private payload"), include_payloads)
			manifest_bytes, manifest_error := os.read_entire_file(fmt.tprintf("%s/manifest.json", destination), context.allocator)
			if manifest_error != nil { testing.fail_now(test, "manifest missing") }
			defer delete(manifest_bytes, context.allocator)
			manifest, parse_error := json.parse_string(string(manifest_bytes), allocator = context.allocator)
			if parse_error != .None { testing.fail_now(test, "manifest invalid") }
			defer json.destroy_value(manifest, context.allocator)
			object := manifest.(json.Object)
			files := object["files"].(json.Array)
			testing.expect_value(test, len(files), 1)
			entry := files[0].(json.Object)
			digest: journal.Digest
			hash: sha2.Context_256
			sha2.init_256(&hash)
			sha2.update(&hash, session_bytes)
			sha2.final(&hash, digest[:])
			hex_text: [journal.DIGEST_HEX_LENGTH]u8
			testing.expect_value(test, string(entry["sha256"].(json.String)), journal.digest_to_hex(digest, hex_text[:]))
			testing.expect(test, !os.exists(fmt.tprintf("%s/runs", destination)))
		}
	})
}

@(test)
test_export_does_not_replace_an_existing_directory :: proc(test: ^testing.T) {
	if !test_isolate_process(test, #procedure) { return }
	diagnostics_request_state(test, "existing", proc(test: ^testing.T) {
		session, _ := diagnostics_request_fixture(test)
		buffer: [journal.SESSION_ID_HEX_LENGTH]u8
		destination, make_error := os.make_directory_temp("", "nabla-diag-existing-*", context.allocator)
		if make_error != nil { testing.fail_now(test, "temporary directory unavailable") }
		defer {
			_ = os.remove_all(destination)
			delete(destination, context.allocator)
		}
		arguments := [3]string{journal.session_id_to_hex(session, buffer[:]), "--export", destination}
		output, errors: strings.Builder
		defer strings.builder_destroy(&output)
		defer strings.builder_destroy(&errors)
		testing.expect_value(test, diagnostics_main(arguments[:], strings.to_writer(&output), strings.to_writer(&errors)), 1)
		testing.expect(test, !os.exists(fmt.tprintf("%s/manifest.json", destination)))
	})
}
