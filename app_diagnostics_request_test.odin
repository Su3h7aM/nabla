#+test
#+private file
package main

import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent"
import "nabla:agent/session"

// diagnostics_test_err collects what the command reports on its diagnosis
// writer, so a passing test leaves the test runner's own output alone and can
// assert on the text itself.
diagnostics_test_err :: proc(builder: ^strings.Builder) -> io.Writer {
	return strings.to_writer(builder)
}

// The request join reads the session database, so these tests point the XDG state
// directory at a temporary root. The environment is process-wide, so each test
// runs its body in a child of the test binary (see isolate_test.odin) while the
// parent only checks the child's result.

// diagnostics_request_state points the XDG state directory at a fresh temporary
// root for one test, so the join reads a store this test created rather than the
// user's own. The environment is restored even when a check fails.
diagnostics_request_state :: proc(t: ^testing.T, name: string, body: proc(t: ^testing.T)) {
	root := fmt.aprintf("/tmp/nabla-diag-state-%s-%d", name, os.get_pid())
	defer {
		os.remove_all(root)
		delete(root)
	}

	previous, had_previous := os.lookup_env("XDG_STATE_HOME", context.temp_allocator)
	defer if had_previous {
		os.set_env("XDG_STATE_HOME", previous)
	} else {
		os.unset_env("XDG_STATE_HOME")
	}
	testing.expect(t, os.set_env("XDG_STATE_HOME", root) == nil)

	body(t)
}

// diagnostics_request_expect is the session-error counterpart of the log
// package's own expectation helper.
@(private)
diagnostics_request_expect :: proc(t: ^testing.T, err: session.Error) {
	if err == nil { return }
	local := err
	testing.fail_now(t, strings.concatenate({"unexpected session error: ", session.error_detail(&local)}, context.temp_allocator))
}

// diagnostics_request_fixture finishes one request in a store under the test's
// state root, so a join has a durable row to find. The usage it was given is what
// the row reports, which is how a test states which buckets were measured.
//
// The header it returns owns its strings, exactly as session_create's own result
// does, so the caller releases it with session_destroy.
diagnostics_request_fixture :: proc(
	t: ^testing.T,
	outcome: session.Outcome,
	usage: session.Usage,
) -> (
	created: session.Session,
	request_no: session.Request_No,
) {
	directory, directory_err := agent.xdg_directory(.State, context.temp_allocator)
	if directory_err != .None { testing.fail_now(t, "the state directory could not be resolved") }

	store: session.Store
	diagnostics_request_expect(t, session.store_open(&store, directory))
	defer session.store_close(&store)

	create_err: session.Error
	created, create_err = session.session_create(&store, {workspace = "/tmp/project", title = "first"}, 1_000)
	diagnostics_request_expect(t, create_err)
	diagnostics_request_expect(t, session.session_claim(&store, created.id))
	defer session.session_release(&store)

	turn, turn_err := session.turn_begin(&store, created.id, "explain the parser", .Prompt, 2_000)
	diagnostics_request_expect(t, turn_err)
	begin_err: session.Error
	request_no, begin_err = session.request_begin(
		&store,
		created.id,
		{
			turn_no = turn,
			purpose = .Response,
			provider = "openai",
			model_requested = "gpt-4",
			api = "openai_chat_completions",
			config_json = "{}",
			input_json = `{"messages":1}`,
		},
		2_100,
	)
	diagnostics_request_expect(t, begin_err)
	diagnostics_request_expect(
		t,
		session.request_finish(
			&store,
			created.id,
			request_no,
			{outcome = outcome, model_resolved = "gpt-4-0613", response_json = `{"reason":"stop"}`, usage = usage, at_ms = 2_200},
		),
	)
	diagnostics_request_expect(t, session.turn_finish(&store, created.id, turn, .Completed, "", 2_300))
	return
}

// diagnostics_request_run writes one run holding a record for the session, into
// the root the diagnostics command itself resolves. The run id is owned by the
// caller.
diagnostics_request_run :: proc(t: ^testing.T, session_id: session.Session_Id) -> string {
	logs_root, directory_err := agent.log_default_directory(context.allocator)
	if directory_err != nil { testing.fail_now(t, "the log directory could not be resolved") }
	defer delete(logs_root, context.allocator)

	log_record: agent.Log
	_, open_err := agent.log_open(&log_record, {directory = logs_root, enabled = true, lowest = .Info}, context.allocator)
	if open_err != nil { testing.fail_now(t, "the log could not be opened") }
	run_id := strings.clone(log_record.run_id, context.allocator)

	binding := agent.Log_Binding {
		sink = &log_record,
		correlation = agent.Log_Correlation{session_id = session_id, turn_no = 1},
	}
	context.logger = agent.log_logger(&binding)
	agent.log_emit(agent.Log_Record{level = .Info, category = .Agent, event = "turn.started"})
	_ = agent.log_close(&log_record)
	return run_id
}

// diagnostics_request_export_dir creates the exclusive destination an export
// needs, which means a path that does not exist yet. It is owned by the caller.
diagnostics_request_export_dir :: proc(t: ^testing.T, name: string) -> string {
	destination := fmt.aprintf("/tmp/nabla-diag-export-%s-%d", name, os.get_pid())
	os.remove_all(destination)
	return destination
}

@(test)
test_request_join_reads_the_durable_row :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	diagnostics_request_state(
		t,
		"join",
		proc(t: ^testing.T) {
			created, request_no := diagnostics_request_fixture(t, .Completed, {input = 10, output = 4})
			defer session.session_destroy(&created)

			row, load_err := diagnostics_request_open(created.id, request_no, context.temp_allocator)
			diagnostics_request_expect(t, load_err)
			defer session.request_destroy(&row, context.temp_allocator)

			// The stored row is the answer, so every field the summary prints comes
			// from here rather than from anything the log observed.
			testing.expect_value(t, row.purpose, session.Request_Purpose.Response)
			testing.expect_value(t, row.outcome, session.Outcome.Completed)
			testing.expect_value(t, row.provider, "openai")
			testing.expect_value(t, row.api, "openai_chat_completions")
			testing.expect_value(t, row.model_requested, "gpt-4")
			testing.expect_value(t, row.model_resolved, "gpt-4-0613")
			testing.expect_value(t, row.usage.input, Maybe(i64)(10))
			testing.expect_value(t, row.usage.output, Maybe(i64)(4))
			// A bucket the provider never reported stays unreported. Reading it as
			// zero would invent a measurement.
			if _, present := row.usage.cache_read.?; present { testing.fail_now(t, "an unreported bucket must stay unreported") }
			if _, present := row.usage.cache_write.?; present { testing.fail_now(t, "an unreported bucket must stay unreported") }

			usage := diagnostics_usage_text(row.usage)
			for needle in ([]string{"input 10", "output 4", "cache read unreported", "cache write unreported"}) {
				testing.expectf(t, strings.contains(usage, needle), "the usage summary should say %q, got %q", needle, usage)
			}

			// The join is the command's contract, not a best-effort extra.
			err_text: strings.Builder
			defer strings.builder_destroy(&err_text)
			testing.expect(t, diagnostics_report_request(created.id, request_no, diagnostics_test_err(&err_text)), "a present request should be reported")
			testing.expect(t, strings.contains(strings.to_string(err_text), "openai"), "the report should name the provider")
		},
	)
}

@(test)
test_request_join_reports_a_request_the_database_does_not_have :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	diagnostics_request_state(t, "missing-row", proc(t: ^testing.T) {
		created, _ := diagnostics_request_fixture(t, .Completed, {input = 10})
		defer session.session_destroy(&created)

		_, load_err := diagnostics_request_open(created.id, 99, context.temp_allocator)
		testing.expect_value(t, session.error_kind(load_err), session.Error_Kind.Not_Found)
		err_text: strings.Builder
		defer strings.builder_destroy(&err_text)
		testing.expect(
			t,
			!diagnostics_report_request(created.id, 99, diagnostics_test_err(&err_text)),
			"a request the database does not have is not an answer",
		)
		testing.expect(t, strings.contains(strings.to_string(err_text), "could not be read"), "the absence should be reported")
	})
}

@(test)
test_request_join_never_creates_the_store_it_reads :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	diagnostics_request_state(
		t,
		"missing-store",
		proc(t: ^testing.T) {
			session_id := session.Session_Id("00112233445566778899aabbccddeeff")

			// A diagnostics run must never create the store it was pointed at, so a
			// missing database is an absence the command reports rather than one it
			// invents.
			err_text: strings.Builder
			defer strings.builder_destroy(&err_text)
			testing.expect(t, !diagnostics_report_request(session_id, 1, diagnostics_test_err(&err_text)))

			directory, directory_err := agent.xdg_directory(.State, context.allocator)
			defer delete(directory, context.allocator)
			if directory_err != .None { testing.fail_now(t, "the state directory could not be resolved") }
			database := fmt.tprintf("%s/%s", directory, session.DATABASE_NAME)
			testing.expect(t, !os.exists(database), "the join must not create a session database")
			testing.expect(t, !os.exists(directory), "the join must not create the state directory")
		},
	)
}

@(test)
test_export_writes_the_durable_row_for_a_selected_request :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	diagnostics_request_state(
		t,
		"export-row",
		proc(t: ^testing.T) {
			created, request_no := diagnostics_request_fixture(t, .Completed, {input = 10, output = 4, cache_read = 2})
			defer session.session_destroy(&created)
			run_id := diagnostics_request_run(t, created.id)
			defer delete(run_id, context.allocator)

			destination := diagnostics_request_export_dir(t, "row")
			defer {
				os.remove_all(destination)
				delete(destination)
			}

			// Driven through the command itself, so the read-only store, the durable
			// read, and the export are one path rather than three.
			number_buffer: [16]u8
			args := [5]string{string(created.id), "--request", fmt.bprintf(number_buffer[:], "%d", i64(request_no)), "--export", destination}
			out_text, err_text: strings.Builder
			defer strings.builder_destroy(&out_text)
			defer strings.builder_destroy(&err_text)
			testing.expect_value(t, diagnostics_main(args[:], strings.to_writer(&out_text), strings.to_writer(&err_text)), 0)
			testing.expect(t, strings.contains(strings.to_string(err_text), "exported"), "the export should be reported")

			request_path := fmt.tprintf("%s/%s", destination, EXPORT_REQUEST_NAME)
			request_text, read_err := os.read_entire_file(request_path, context.allocator)
			if read_err != nil { testing.fail_now(t, "request.json was not written") }
			defer delete(request_text)

			value, parse_err := json.parse_string(string(request_text), parse_integers = true, allocator = context.allocator)
			if parse_err != .None { testing.fail_now(t, "request.json is not JSON") }
			defer json.destroy_value(value, context.allocator)
			object, is_object := value.(json.Object)
			if !testing.expect(t, is_object, "request.json should be one object") { return }

			testing.expect_value(t, diagnostics_value_string(t, object, "session_id"), string(created.id))
			testing.expect_value(t, diagnostics_value_string(t, object, "outcome"), "completed")
			testing.expect_value(t, diagnostics_value_string(t, object, "provider"), "openai")
			testing.expect_value(t, diagnostics_value_string(t, object, "model_requested"), "gpt-4")
			testing.expect_value(t, diagnostics_value_string(t, object, "model_resolved"), "gpt-4-0613")
			testing.expect_value(t, diagnostics_value_integer(t, object, "request_no"), i64(request_no))
			testing.expect_value(t, diagnostics_value_integer(t, object, "input_tokens"), i64(10))
			testing.expect_value(t, diagnostics_value_integer(t, object, "output_tokens"), i64(4))
			testing.expect_value(t, diagnostics_value_integer(t, object, "cache_read_tokens"), i64(2))
			testing.expect_value(t, diagnostics_value_bool(t, object, "input_tokens_present"), true)
			testing.expect_value(t, diagnostics_value_bool(t, object, "cache_read_tokens_present"), true)
			testing.expect_value(t, diagnostics_value_bool(t, object, "cache_write_tokens_present"), false)

			// The durable conversation is not a diagnostics artifact, so it stays out
			// of the bundle however the payload switch is set.
			for absent in ([]string{"config_json", "input_json", "response_json", "error_json"}) {
				testing.expectf(t, object[absent] == nil, "request.json must not carry %s", absent)
			}

			manifest_path := fmt.tprintf("%s/%s", destination, EXPORT_MANIFEST_NAME)
			manifest, manifest_err := os.read_entire_file(manifest_path, context.allocator)
			if manifest_err != nil { testing.fail_now(t, "the manifest was not written") }
			defer delete(manifest)
			testing.expect(t, strings.contains(string(manifest), `"request_joined": true`), "the manifest should record the join")
			testing.expect(t, strings.contains(string(manifest), EXPORT_REQUEST_NAME), "the manifest should describe request.json")
		},
	)
}

@(test)
test_export_reports_a_request_the_database_does_not_have :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	diagnostics_request_state(
		t,
		"export-missing",
		proc(t: ^testing.T) {
			created, _ := diagnostics_request_fixture(t, .Completed, {input = 10})
			defer session.session_destroy(&created)
			run_id := diagnostics_request_run(t, created.id)
			defer delete(run_id, context.allocator)

			destination := diagnostics_request_export_dir(t, "missing")
			defer {
				os.remove_all(destination)
				delete(destination)
			}

			// An answer whose authoritative half is missing is an incomplete answer,
			// so the bundle is written, says so, and the command fails.
			args := [5]string{string(created.id), "--request", "99", "--export", destination}
			out_text, err_text: strings.Builder
			defer strings.builder_destroy(&out_text)
			defer strings.builder_destroy(&err_text)
			testing.expect_value(t, diagnostics_main(args[:], strings.to_writer(&out_text), strings.to_writer(&err_text)), 1)
			testing.expect(t, !os.exists(fmt.tprintf("%s/%s", destination, EXPORT_REQUEST_NAME)), "no row means no request.json")

			manifest_path := fmt.tprintf("%s/%s", destination, EXPORT_MANIFEST_NAME)
			manifest, manifest_err := os.read_entire_file(manifest_path, context.allocator)
			if manifest_err != nil { testing.fail_now(t, "the manifest was not written") }
			defer delete(manifest)
			testing.expect(t, strings.contains(string(manifest), `"request_joined": false`), "the manifest should record the missing join")
			testing.expect(t, strings.contains(string(manifest), "session database"), "the omission should name what was missing")
		},
	)
}

@(private)
diagnostics_value_string :: proc(t: ^testing.T, object: json.Object, key: string) -> string {
	value, present := object[key]
	if !present { return "" }
	text, is_text := value.(json.String)
	if !is_text {
		testing.expectf(t, false, "%s should be a string", key)
		return ""
	}
	return string(text)
}

@(private)
diagnostics_value_integer :: proc(t: ^testing.T, object: json.Object, key: string) -> i64 {
	value, present := object[key]
	if !present { return 0 }
	number, is_number := value.(json.Integer)
	if !is_number {
		testing.expectf(t, false, "%s should be an integer", key)
		return 0
	}
	return i64(number)
}

@(private)
diagnostics_value_bool :: proc(t: ^testing.T, object: json.Object, key: string) -> bool {
	value, present := object[key]
	if !present { return false }
	flag, is_flag := value.(json.Boolean)
	if !is_flag {
		testing.expectf(t, false, "%s should be a boolean", key)
		return false
	}
	return bool(flag)
}
