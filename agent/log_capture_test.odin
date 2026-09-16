#+test
package agent

import "core:os"
import "core:sort"
import "core:strings"
import "core:testing"

import "nabla:agent/session"
import "nabla:ai"

// Payload capture is tested at the boundary that fills it: the provider report the
// bridge turns into artifacts. The assertions read the files and the sidecar, which
// is the contract a later reader and an exporter depend on.

log_capture_begin :: proc(t: ^testing.T, fixture: ^Log_Test, mode: Capture_Mode) {
	directory, directory_err := os.make_directory_temp("", "nabla-capture-test-*", context.allocator)
	if directory_err != nil { testing.fail_now(t, "could not create a temporary directory") }
	fixture.directory = directory
	_, open_err := log_open(&fixture.log, {directory = directory, enabled = true, lowest = .Info, capture = mode})
	if open_err != nil {
		local := open_err
		testing.fail_now(t, strings.concatenate({"log_open failed: ", log_error_detail(&local)}, context.temp_allocator))
	}
}

// log_capture_names lists the artifact names of the fixture's run, sorted, which is
// what makes an existence claim about a specific artifact readable.
log_capture_names :: proc(t: ^testing.T, fixture: ^Log_Test) -> [dynamic]string {
	directory, okay := log_path_join(fixture.log.directory, LOG_CAPTURES_DIRECTORY, context.allocator)
	if !okay { testing.fail_now(t, "the captures path could not be built") }
	defer delete(directory, context.allocator)
	entries, read_err := os.read_all_directory_by_path(directory, context.allocator)
	if read_err != nil { return {} }
	defer os.file_info_slice_delete(entries, context.allocator)
	names := make([dynamic]string, 0, len(entries), context.allocator)
	for entry in entries { append(&names, strings.clone(entry.name, context.allocator)) }
	sort.quick_sort(names[:])
	return names
}

log_capture_names_destroy :: proc(names: ^[dynamic]string) {
	for name in names { delete(name, context.allocator) }
	delete(names^)
}

log_capture_artifact_path :: proc(fixture: ^Log_Test, name: string) -> string {
	directory, _ := log_path_join(fixture.log.directory, LOG_CAPTURES_DIRECTORY, context.temp_allocator)
	path, _ := log_path_join(directory, name, context.temp_allocator)
	return path
}

@(test)
test_capture_stores_the_request_and_the_response :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_capture_begin(t, &fixture, .Payloads)
	defer log_test_end(t, &fixture)

	session_id := session.Session_Id("00112233445566778899aabbccddeeff")
	binding := Log_Binding {
		sink = &fixture.log,
		correlation = Log_Correlation{session_id = session_id, request_no = 6, attempt = 1},
	}
	context.logger = log_logger(&binding)

	body := `{"model":"test-model","input":"hello"}`
	observation: Provider_Log
	log_provider_report(&observation, {stage = .Encoded, api = .OpenAI_Responses, model = "test-model", tools = 3, body = transmute([]u8)body})
	first := `data: {"type":"a"}`
	second := `data: {"type":"b"}`
	log_provider_report(&observation, {stage = .Response_Body, chunk = transmute([]u8)first, bytes = u64(len(first))})
	log_provider_report(&observation, {stage = .Response_Body, chunk = transmute([]u8)second, bytes = u64(len(first) + len(second))})
	// The stream ran to its end, which is what the artifact records as complete.
	log_capture_finish(&observation.response_capture, true)

	names := log_capture_names(t, &fixture)
	defer log_capture_names_destroy(&names)
	found := strings.join(names[:], " ", context.temp_allocator)
	testing.expectf(t, strings.contains(found, "response.body"), "the response artifact should exist: %s", found)
	testing.expect(t, !strings.contains(found, ".part"), "a finished capture should leave no partial payload")

	// The request payload is the exact bytes the operation was handed.
	request := log_test_text(t, log_capture_artifact_path(&fixture, "000001-request.body"))
	defer delete(request, context.allocator)
	testing.expect_value(t, request, body)

	// The response payload is the de-framed body stream, in arrival order.
	response := log_test_text(t, log_capture_artifact_path(&fixture, "000002-response.body"))
	defer delete(response, context.allocator)
	testing.expect_value(t, response, strings.concatenate({first, second}, context.temp_allocator))

	// The sidecar carries the metadata a record cannot: both digests, both counts,
	// and the correlation the artifact belongs to.
	sidecar := log_test_text(t, log_capture_artifact_path(&fixture, "000002-response.body.json"))
	defer delete(sidecar, context.allocator)
	log_test_expect_all(
		t,
		sidecar,
		{
			`"artifact_id":2`,
			`"kind":"response"`,
			`"observed_bytes":39`,
			`"stored_bytes":39`,
			`"observed_complete":true`,
			`"truncated":false`,
			`"failed":false`,
			`"session_id":"00112233445566778899aabbccddeeff"`,
			`"request_no":6`,
			`"attempt":1`,
		},
		"the sidecar",
	)

	// The stream also carries one record per artifact, so a reader that never opens
	// the directory still learns that payloads exist.
	text := log_test_segment_text(t, &fixture, 1)
	defer delete(text, context.allocator)
	testing.expect(t, strings.contains(text, `"event":"capture.finished"`), "the artifacts are recorded")
	testing.expect(t, strings.contains(text, `"artifact_kind":"request"`), "the request artifact is named")
	testing.expect(t, strings.contains(text, `"artifact_kind":"response"`), "the response artifact is named")
	testing.expect_value(t, log_health(&fixture.log).capture_denied, u64(0))
}

@(test)
test_capture_stays_off_without_permission :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_capture_begin(t, &fixture, .Off)
	defer log_test_end(t, &fixture)

	binding := Log_Binding {
		sink = &fixture.log,
	}
	context.logger = log_logger(&binding)

	body := `{"model":"test-model"}`
	observation: Provider_Log
	log_provider_report(&observation, {stage = .Encoded, api = .OpenAI_Responses, model = "test-model", body = transmute([]u8)body})

	names := log_capture_names(t, &fixture)
	defer log_capture_names_destroy(&names)
	testing.expect_value(t, len(names), 0)
	// The metadata record is unaffected: capture is a permission of its own.
	text := log_test_segment_text(t, &fixture, 1)
	defer delete(text, context.allocator)
	testing.expect(t, strings.contains(text, `"event":"provider.encoded"`), "metadata is still recorded")
}

@(test)
test_capture_keeps_a_prefix_and_says_so :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_capture_begin(t, &fixture, .Payloads)
	defer log_test_end(t, &fixture)

	binding := Log_Binding {
		sink = &fixture.log,
	}
	context.logger = log_logger(&binding)

	// More than one artifact may hold, so the stored copy is a prefix of what was
	// observed and the two counts differ.
	oversized := make([]u8, LOG_CAPTURE_BYTES + 4096, context.allocator)
	defer delete(oversized, context.allocator)
	for index in 0 ..< len(oversized) { oversized[index] = 'x' }

	capture, opened := log_capture_open(&fixture.log, {}, .Provider_Request)
	testing.expect(t, opened, "the artifact should be admitted")
	log_capture_write(&capture, oversized)
	summary := log_capture_finish(&capture, true)
	testing.expect_value(t, summary.observed_bytes, u64(len(oversized)))
	testing.expect_value(t, summary.stored_bytes, u64(LOG_CAPTURE_BYTES))
	testing.expect(t, summary.truncated, "a stored prefix is reported as truncated")
	testing.expect(t, summary.observed_complete, "the observation itself was complete")

	// The stored file really is the bounded prefix.
	payload := log_test_text(t, log_capture_artifact_path(&fixture, "000001-request.body"))
	defer delete(payload, context.allocator)
	testing.expect_value(t, len(payload), LOG_CAPTURE_BYTES)

	// The two digests differ, which is what makes them worth keeping apart.
	testing.expect(t, summary.observed_sha256 != summary.stored_sha256, "observed and stored digests describe different bytes")
}

@(test)
test_capture_declines_once_the_run_quota_is_spent :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_capture_begin(t, &fixture, .Payloads)
	defer log_test_end(t, &fixture)

	// Each admission reserves a whole artifact's allowance, so the run budget is
	// spent by reservations before any byte is stored.
	open := make([dynamic]Capture, 0, 16, context.allocator)
	defer {
		for &capture in open { log_capture_abort(&capture) }
		delete(open)
	}
	for _ in 0 ..< LOG_CAPTURE_BYTES_PER_RUN / LOG_CAPTURE_BYTES {
		capture, admitted := log_capture_open(&fixture.log, {}, .Provider_Response)
		testing.expect(t, admitted, "an artifact within the budget should be admitted")
		append(&open, capture)
	}

	_, refused := log_capture_open(&fixture.log, {}, .Provider_Response)
	testing.expect(t, !refused, "an artifact past the budget is declined")
	testing.expect_value(t, log_health(&fixture.log).capture_denied, u64(1))

	// The admitted artifacts have opened payload files but stored nothing, and the
	// declined one left none: nothing is presented as a completed capture.
	names := log_capture_names(t, &fixture)
	defer log_capture_names_destroy(&names)
	testing.expect_value(t, len(names), LOG_CAPTURE_BYTES_PER_RUN / LOG_CAPTURE_BYTES)
	for name in names {
		testing.expectf(t, strings.has_suffix(name, LOG_CAPTURE_PART_SUFFIX), "%s should be an open payload", name)
	}

	// Aborting the reservations returns the budget, so a later run of captures is
	// not permanently spent.
	for &capture in open { log_capture_abort(&capture) }
	clear(&open)
	reopened, admitted_again := log_capture_open(&fixture.log, {}, .Provider_Response)
	testing.expect(t, admitted_again, "released reservations are available again")
	log_capture_abort(&reopened)
}

@(test)
test_capture_withdraws_an_artifact_that_never_stored_anything :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_capture_begin(t, &fixture, .Payloads)
	defer log_test_end(t, &fixture)

	capture, opened := log_capture_open(&fixture.log, {}, .Provider_Request)
	testing.expect(t, opened, "the artifact should be admitted")
	summary := log_capture_finish(&capture, true)
	testing.expect_value(t, summary.artifact, u64(0))

	names := log_capture_names(t, &fixture)
	defer log_capture_names_destroy(&names)
	testing.expect_value(t, len(names), 0)
	testing.expect(t, !log_health(&fixture.log).failed, "an empty capture is not a failure")
}
