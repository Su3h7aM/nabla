#+test
#+private file
package main

import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "nabla:acp"
import "nabla:agent"
import "nabla:agent/journal"

// The ACP interface never runs a turn: its worker appends the session's input and
// commands to the journal and polls what the session server commits. The tests below
// drive that contract directly: committed journal records translated through the follow
// observer, and one threaded prompt answered by the server steps the serve tests use.
//
// The suite also holds the frontend to its teardown. The test runner reports anything a
// run did not release, so an unclosed store, an unjoined worker, or a leaked frame shows
// up here. Every failure unwinds through the test's own cleanup: nothing aborts a test
// half-way, because a run left running would be reported as a leak that belongs to the
// harness rather than to this suite.
//
// JSON documents are assembled with builders rather than format strings: the format syntax
// reads a brace as a directive, and these documents are full of them.

ACP_TEST_BOUND :: 10 * time.Second

@(test)
test_request_params_decode_errors_use_json_rpc_internal_for_allocation :: proc(t: ^testing.T) {
	testing.expect_value(t, acp_request_params_error_code(acp.Params_Error.Invalid), acp.ERROR_INVALID_PARAMS)
	testing.expect_value(t, acp_request_params_error_code(acp.Params_Error.Allocation), acp.ERROR_INTERNAL)
}

@(test)
test_acp_session_meta_reads_client_title_and_system_prompt_extensions :: proc(t: ^testing.T) {
	appended: json.Object
	appended["append"] = json.String("client standing context")
	defer delete(appended)
	meta: json.Object
	defer delete(meta)
	meta["sessionTitle"] = json.String("a title")
	meta["systemPrompt"] = appended
	title, prompt := acp_session_meta(meta)
	testing.expect_value(t, title, "a title")
	testing.expect_value(t, prompt, "client standing context")
	meta["systemPrompt"] = json.String("plain context")
	_, prompt = acp_session_meta(meta)
	testing.expect_value(t, prompt, "plain context")
	_, prompt = acp_session_meta(nil)
	testing.expect_value(t, prompt, "")
}


// --- the client --------------------------------------------------------------

// ACP_Test_Client is a client with two ends: the messages it writes to the agent, and the
// frames it has read back. Both are guarded, because the run reads and writes on its own
// threads while the test does the same.
ACP_Test_Client :: struct {
	mu:            sync.Mutex,
	cond:          sync.Cond,
	input:         [dynamic]u8,
	// input_closed is the client's half of the connection ending: the run reads it as the
	// end of the stream.
	input_closed:  bool,
	output:        [dynamic]u8,
	output_closed: bool,
	read_at:       int,
}

acp_test_client_input :: proc(client: ^ACP_Test_Client) -> io.Reader {
	return io.Reader{data = client, procedure = acp_test_client_stream}
}

acp_test_client_output :: proc(client: ^ACP_Test_Client) -> io.Writer {
	return io.Writer{data = client, procedure = acp_test_client_stream}
}


acp_test_writer_cleanup :: proc(writer: ^acp.Writer) {
	_ = acp.writer_destroy(writer, time.Second)
}

acp_test_server_init :: proc(t: ^testing.T, server: ^ACP_Server) -> bool {
	server.alloc = context.allocator
	server.app.setup.alloc = server.alloc
	writer, writer_error := acp.writer_init({}, server.alloc)
	if writer_error != nil { return testing.expect(t, false, "the ACP test writer could not be created") }
	server.writer = writer
	return true
}

ACP_Test_Retained_Worker :: struct {
	session: ^ACP_Session,
	release: sync.One_Shot_Event,
}

acp_test_retained_worker :: proc(worker: ^thread.Thread) {
	state := cast(^ACP_Test_Retained_Worker)worker.data
	sync.one_shot_event_wait(&state.release)
	sync.one_shot_event_signal(&state.session.worker_done)
}

@(test)
test_acp_shutdown_settles_joined_sessions_and_retains_a_stuck_connection :: proc(t: ^testing.T) {
	server: ACP_Server
	client: ACP_Test_Client
	defer delete(client.output)
	server.alloc = context.allocator
	server.app.setup.alloc = server.alloc
	writer, writer_error := acp.writer_init(acp_test_client_output(&client), server.alloc)
	if !testing.expect(t, writer_error == nil, "the shared writer could not be created") { return }
	server.writer = writer
	joined, reason := acp_session_create(&server, "joined")
	if !testing.expectf(t, joined != nil, "the joined session could not be created: %s", reason) {
		_ = acp_server_destroy(&server)
		return
	}
	retained, made := acp_session_make(&server, "retained")
	if !testing.expect(t, made, "the retained session could not be created") {
		_ = acp_server_destroy(&server)
		return
	}
	state := ACP_Test_Retained_Worker {
		session = retained,
	}
	worker := thread.create(acp_test_retained_worker)
	if !testing.expect(t, worker != nil, "the retained worker could not be created") {
		acp_session_free(retained)
		_ = acp_server_destroy(&server)
		return
	}
	worker.data = &state
	retained.worker = worker
	server.sessions[1] = retained
	thread.start(worker)
	complete := acp_server_destroy(&server, time.Millisecond)
	testing.expect(t, !complete, "shutdown reported success while a worker still borrowed the connection")
	testing.expect(t, server.sessions[0] == nil, "the joined session was not released after another worker timed out")
	testing.expect(t, server.sessions[1] == retained, "the unjoined session was freed")
	testing.expect(
		t,
		acp.write_response(&server.writer, i64(1), acp.Empty_Result{}) == .None,
		"the shared writer was destroyed while a worker could still enqueue",
	)
	sync.one_shot_event_signal(&state.release)
	if join_retiring(worker, &retained.worker_done) {
		retained.worker = nil
		server.worker_stuck = false
	}
	testing.expect(t, acp_server_destroy(&server), "the retained connection did not shut down after its worker retired")
}

@(test)
test_acp_cancellation_routes_to_the_named_session :: proc(t: ^testing.T) {
	server: ACP_Server
	first: ACP_Session
	second: ACP_Session
	first.conn = &server
	first.id = "session-first"
	second.conn = &server
	second.id = "session-second"
	server.sessions[0] = &first
	server.sessions[1] = &second
	params, parse_error := json.parse_string(`{"sessionId":"session-second"}`, .JSON, true, context.allocator)
	if parse_error != nil { testing.fail_now(t, "the cancellation parameters could not be parsed") }
	defer json.destroy_value(params, context.allocator)
	envelope := acp.Envelope {
		kind   = .Request,
		id     = i64(1),
		params = params,
	}
	writer, writer_error := acp.writer_init({}, context.allocator)
	if writer_error != nil { testing.fail_now(t, "the test writer could not be created") }
	server.writer = writer
	defer acp_test_writer_cleanup(&server.writer)
	acp_request_cancel(&server, &envelope)
	testing.expect(t, !acp_cancel_take(&first), "cancellation stopped the wrong session")
	testing.expect(t, acp_cancel_take(&second), "cancellation did not stop the named session")
	testing.expect(t, !acp_cancel_take(&second), "cancellation was not claimed exactly once")
}

@(test)
test_acp_busy_sessions_refuse_a_ninth_open :: proc(t: ^testing.T) {
	server: ACP_Server
	if !acp_test_server_init(t, &server) { return }
	defer testing.expect(t, acp_server_destroy(&server), "the ACP test server did not shut down")
	for i in 0 ..< ACP_MAX_SESSIONS {
		session, reason := acp_session_create(&server, fmt.tprintf("session-%d", i))
		if !testing.expectf(t, session != nil, "session %d could not be created: %s", i, reason) { return }
		sync.mutex_lock(&session.queue_mu)
		session.pending_work = 1
		sync.mutex_unlock(&session.queue_mu)
	}
	refused, reason := acp_session_create(&server, "session-ninth")
	testing.expect(t, refused == nil, "a ninth session was admitted while all sessions were busy")
	testing.expect(t, strings.contains(reason, "all of them are busy"), "the full-table error did not explain that all sessions are busy")
	for i in 0 ..< ACP_MAX_SESSIONS {
		testing.expect(t, acp_session_find(&server, fmt.tprintf("session-%d", i)) != nil, "a busy session was lost when the ninth was refused")
	}
	for session in server.sessions {
		if session == nil { continue }
		sync.mutex_lock(&session.queue_mu)
		session.pending_work = 0
		sync.mutex_unlock(&session.queue_mu)
	}
}

@(test)
test_acp_idle_sessions_are_evicted_by_lru_and_can_be_loaded_again :: proc(t: ^testing.T) {
	server: ACP_Server
	if !acp_test_server_init(t, &server) { return }
	defer testing.expect(t, acp_server_destroy(&server), "the ACP test server did not shut down")
	for i in 0 ..< ACP_MAX_SESSIONS {
		session, reason := acp_session_create(&server, fmt.tprintf("session-%d", i))
		if !testing.expectf(t, session != nil, "session %d could not be created: %s", i, reason) { return }
	}
	acp_session_touch(acp_session_find(&server, "session-0"))
	opened, reason := acp_session_create(&server, "session-ninth")
	if !testing.expectf(t, opened != nil, "the idle session did not make room: %s", reason) { return }
	testing.expect(t, acp_session_find(&server, "session-1") == nil, "the least recently used idle session was not evicted")
	testing.expect(t, acp_session_find(&server, "session-0") != nil, "the recently used idle session was evicted")
	reloaded, reload_reason := acp_session_create(&server, "session-1")
	testing.expectf(t, reloaded != nil, "the evicted session could not be opened again: %s", reload_reason)
	testing.expect(t, acp_session_find(&server, "session-1") != nil, "the reloaded session was not published")
}

@(test)
test_acp_cancel_records_intent_for_the_worker :: proc(t: ^testing.T) {
	server: ACP_Server
	session: ACP_Session
	session.conn = &server
	session.id = "session-stalled"
	server.sessions[0] = &session
	// A cancellation records the intent for the worker, which owns the journal: it
	// touches no turn control and answers without waiting for anything.
	acp_cancel_session(&session)
	testing.expect(t, acp_cancel_take(&session), "the cancellation was not recorded")
	testing.expect(t, !acp_cancel_take(&session), "the cancellation was not claimed exactly once")
	params, parse_error := json.parse_string(`{"sessionId":"session-stalled"}`, .JSON, true, context.allocator)
	if parse_error != nil { testing.fail_now(t, "the cancellation parameters could not be parsed") }
	defer json.destroy_value(params, context.allocator)
	notification := acp.Envelope {
		kind   = .Notification,
		method = acp.METHOD_SESSION_CANCEL,
		params = params,
	}
	acp_handle_notification(&server, &notification)
	testing.expect(t, acp_cancel_take(&session), "the cancel notification was not recorded")
}

// acp_test_client_stream serves both ends of the client: a read takes the next message the
// test wrote, and a write appends what the run produced.
acp_test_client_stream :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	client := cast(^ACP_Test_Client)data
	switch mode {
	case .Read:
		sync.mutex_lock(&client.mu)
		defer sync.mutex_unlock(&client.mu)
		for len(client.input) == 0 && !client.input_closed { sync.cond_wait(&client.cond, &client.mu) }
		if len(client.input) == 0 { return 0, .EOF }
		count := copy(p, client.input[:])
		copy(client.input[:], client.input[count:])
		// A shrink never allocates, so it cannot fail.
		_ = resize(&client.input, len(client.input) - count)
		return i64(count), nil
	case .Write:
		sync.mutex_lock(&client.mu)
		append(&client.output, ..p)
		sync.cond_broadcast(&client.cond)
		sync.mutex_unlock(&client.mu)
		return i64(len(p)), nil
	case .Close, .Destroy:
		sync.mutex_lock(&client.mu)
		client.output_closed = true
		sync.cond_broadcast(&client.cond)
		sync.mutex_unlock(&client.mu)
		return 0, nil
	case .Query:
		return i64(io.Stream_Mode_Set{.Read, .Write}), nil
	case .Flush:
		return 0, nil
	case .Seek, .Read_At, .Write_At, .Size:
		return 0, .Unsupported
	}
	return 0, .Unsupported
}

acp_test_client_destroy :: proc(client: ^ACP_Test_Client) {
	sync.mutex_lock(&client.mu)
	defer sync.mutex_unlock(&client.mu)
	delete(client.input)
	delete(client.output)
	client.input = nil
	client.output = nil
	client.read_at = 0
}

// acp_test_client_send writes one whole message, including the newline that ends it.
acp_test_client_send :: proc(client: ^ACP_Test_Client, message: string) {
	sync.mutex_lock(&client.mu)
	defer sync.mutex_unlock(&client.mu)
	append(&client.input, ..transmute([]u8)message)
	sync.cond_broadcast(&client.cond)
}

// acp_test_client_hang_up ends the client's side of the stream, which is what a client
// that quits does.
acp_test_client_hang_up :: proc(client: ^ACP_Test_Client) {
	sync.mutex_lock(&client.mu)
	defer sync.mutex_unlock(&client.mu)
	client.input_closed = true
	sync.cond_broadcast(&client.cond)
}

// acp_test_client_receive reads one whole message. It returns "" when the run stopped
// writing or did not answer within the bound, so a failure is reported by the expectation
// that wanted the message rather than by aborting the test.
acp_test_client_receive :: proc(client: ^ACP_Test_Client, allocator := context.temp_allocator, include_commands := false) -> string {
	sync.mutex_lock(&client.mu)
	defer sync.mutex_unlock(&client.mu)
	for {
		pending := string(client.output[client.read_at:])
		if newline := strings.index_byte(pending, '\n'); newline >= 0 {
			frame := pending[:newline]
			client.read_at += newline + 1
			// Command advertisements are setup metadata, separate from a prompt's frames.
			if !include_commands && strings.contains(frame, `"sessionUpdate":"available_commands_update"`) { continue }
			return strings.clone(frame, allocator)
		}
		if client.output_closed { return "" }
		if !sync.cond_wait_with_timeout(&client.cond, &client.mu, ACP_TEST_BOUND) { return "" }
	}
}

// acp_test_client_expect reads one message and holds it to the text it must carry. The
// frame comes back so the rest of what one answer says can be checked with it; it is
// scratch, and it lives until the test's own free_all. An empty result means the
// expectation failed and the caller should stop reading.
acp_test_client_expect :: proc(t: ^testing.T, client: ^ACP_Test_Client, needle, what: string) -> string {
	frame := acp_test_client_receive(client)
	if frame == "" {
		testing.expectf(t, false, "%s: the run did not answer", what)
		return ""
	}
	if !testing.expectf(t, strings.contains(frame, needle), "%s: %s", what, frame) { return "" }
	return frame
}


// --- environment -------------------------------------------------------------

// acp_test_env points one XDG variable at a temporary directory, so a run that opens the
// session store or reads the catalog cache cannot touch the user's own state. It fails the
// test rather than leaving the variable pointing at the user's own directory.
acp_test_env :: proc(t: ^testing.T, variable, directory: string) -> (previous: string, had_previous: bool) {
	previous, had_previous = os.lookup_env(variable, context.allocator)
	if os.set_env(variable, directory) != nil { testing.fail_now(t, "the test state directory could not be set") }
	return
}

acp_test_env_restore :: proc(variable, previous: string, had_previous: bool) {
	// The process is the isolated child this suite runs in, so a restore that fails
	// changes nothing that outlives it.
	if had_previous {
		_ = os.set_env(variable, previous)
	} else {
		_ = os.unset_env(variable)
	}
	delete(previous, context.allocator)
}

// --- the conversation --------------------------------------------------------

// ACP_Test_Run is one frontend living on its own thread while the test plays the client.
ACP_Test_Run :: struct {
	client:  ^ACP_Test_Client,
	sources: []agent.Catalog_Provider_Source,
	served:  bool,
}

acp_test_run_thread :: proc(thread_handle: ^thread.Thread) {
	run := cast(^ACP_Test_Run)thread_handle.data
	run.served = acp_run(run.sources, {}, {}, acp_test_client_input(run.client), acp_test_client_output(run.client))
}

@(test)
test_acp_v2_negotiates_and_exposes_the_session_surface :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	workspace, workspace_err := os.make_directory_temp("", "nabla-acp-v2-workspace-*", context.allocator)
	if workspace_err != nil {
		testing.expectf(t, false, "could not create a temporary workspace: %v", workspace_err)
		return
	}
	defer {
		_ = os.remove_all(workspace)
		delete(workspace, context.allocator)
	}
	state, state_err := os.make_directory_temp("", "nabla-acp-v2-state-*", context.allocator)
	if state_err != nil {
		testing.expectf(t, false, "could not create a temporary state directory: %v", state_err)
		return
	}
	defer {
		_ = os.remove_all(state)
		delete(state, context.allocator)
	}
	previous_state, had_state := acp_test_env(t, "XDG_STATE_HOME", state)
	defer acp_test_env_restore("XDG_STATE_HOME", previous_state, had_state)
	previous_runtime, had_runtime := acp_test_env(t, "XDG_RUNTIME_DIR", state)
	defer acp_test_env_restore("XDG_RUNTIME_DIR", previous_runtime, had_runtime)
	previous_cache, had_cache := acp_test_env(t, "XDG_CACHE_HOME", state)
	defer acp_test_env_restore("XDG_CACHE_HOME", previous_cache, had_cache)

	client: ACP_Test_Client
	defer acp_test_client_destroy(&client)
	run := ACP_Test_Run {
		client = &client,
	}
	run_thread := thread.create(acp_test_run_thread, name = "nabla-acp-v2-test-run")
	if run_thread == nil {
		testing.expect(t, false, "the run thread could not be started")
		return
	}
	run_thread.data = &run
	thread.start(run_thread)
	defer {
		acp_test_client_hang_up(&client)
		thread.join(run_thread)
		testing.expect(t, run.served, "the run did not end cleanly")
		thread.destroy(run_thread)
		free_all(context.temp_allocator)
	}

	handshake := strings.builder_make(context.temp_allocator)
	fmt.sbprint(
		&handshake,
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":2,"capabilities":{},"info":{"name":"acp-test","version":"1"}}}`,
	)
	strings.write_byte(&handshake, '\n')
	acp_test_client_send(&client, strings.to_string(handshake))
	hello := acp_test_client_expect(t, &client, `"protocolVersion":2`, "v2 initialize was not answered")
	if hello == "" { return }
	testing.expect(t, strings.contains(hello, `"capabilities":{"session":{"prompt":{"image":{},"embeddedContext":{}},"mcp":{"stdio":{}}}}`))
	testing.expect(t, strings.contains(hello, `"info":{"name":"nabla","title":"Nabla","version":"0.1.0"}`))

	opening := strings.builder_make(context.temp_allocator)
	strings.write_string(&opening, `{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"`)
	strings.write_string(&opening, workspace)
	strings.write_string(&opening, `","mcpServers":[]}}`)
	strings.write_byte(&opening, '\n')
	acp_test_client_send(&client, strings.to_string(opening))
	opening_frame := acp_test_client_expect(t, &client, `"sessionId"`, "v2 session/new was not answered")
	if opening_frame == "" { return }
	if !strings.contains(opening_frame, `"configOptions":[]`) {
		testing.expectf(t, false, "v2 session/new did not expose configuration: %s", opening_frame)
		return
	}
	session_id := acp_test_client_session_id_from_frame(t, opening_frame)
	if session_id == "" { return }
	defer delete(session_id, context.allocator)

	listing := strings.builder_make(context.temp_allocator)
	strings.write_string(&listing, `{"jsonrpc":"2.0","id":3,"method":"session/list","params":{}}`)
	strings.write_byte(&listing, '\n')
	acp_test_client_send(&client, strings.to_string(listing))
	listing_frame := acp_test_client_expect(t, &client, `"sessions"`, "v2 session/list was not answered")
	if listing_frame == "" || !strings.contains(listing_frame, session_id) {
		testing.expectf(t, false, "v2 session/list omitted the active session: %s", listing_frame)
		return
	}

	closing := strings.builder_make(context.temp_allocator)
	strings.write_string(&closing, `{"jsonrpc":"2.0","id":4,"method":"session/close","params":{"sessionId":"`)
	strings.write_string(&closing, session_id)
	strings.write_string(&closing, `"}}`)
	strings.write_byte(&closing, '\n')
	acp_test_client_send(&client, strings.to_string(closing))
	if acp_test_client_expect(t, &client, `"id":4,"result":{}`, "v2 session/close was not answered") == "" { return }

	closed_listing := strings.builder_make(context.temp_allocator)
	strings.write_string(&closed_listing, `{"jsonrpc":"2.0","id":5,"method":"session/list","params":{}}`)
	strings.write_byte(&closed_listing, '\n')
	acp_test_client_send(&client, strings.to_string(closed_listing))
	closed_frame := acp_test_client_expect(t, &client, `"sessions"`, "v2 session/list after close was not answered")
	if closed_frame == "" { return }
	testing.expectf(t, strings.contains(closed_frame, session_id), "v2 session/list lost the detached session: %s", closed_frame)
}

@(test)
test_acp_v2_batch_answers_reader_owned_requests_as_one_frame :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	state, state_err := os.make_directory_temp("", "nabla-acp-batch-state-*", context.allocator)
	if state_err != nil {
		testing.expectf(t, false, "could not create a temporary state directory: %v", state_err)
		return
	}
	defer {
		_ = os.remove_all(state)
		delete(state, context.allocator)
	}
	previous_state, had_state := acp_test_env(t, "XDG_STATE_HOME", state)
	defer acp_test_env_restore("XDG_STATE_HOME", previous_state, had_state)
	previous_runtime, had_runtime := acp_test_env(t, "XDG_RUNTIME_DIR", state)
	defer acp_test_env_restore("XDG_RUNTIME_DIR", previous_runtime, had_runtime)
	previous_cache, had_cache := acp_test_env(t, "XDG_CACHE_HOME", state)
	defer acp_test_env_restore("XDG_CACHE_HOME", previous_cache, had_cache)

	client: ACP_Test_Client
	defer acp_test_client_destroy(&client)
	run := ACP_Test_Run {
		client = &client,
	}
	run_thread := thread.create(acp_test_run_thread, name = "nabla-acp-batch-run")
	if run_thread == nil {
		testing.expect(t, false, "the run thread could not be started")
		return
	}
	run_thread.data = &run
	thread.start(run_thread)
	defer {
		acp_test_client_hang_up(&client)
		thread.join(run_thread)
		testing.expect(t, run.served, "the run did not end cleanly")
		thread.destroy(run_thread)
		free_all(context.temp_allocator)
	}

	batch :=
		`[{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":2,"capabilities":{},"info":{"name":"batch-test","version":"1"}}},{"jsonrpc":"2.0","id":2,"method":"unknown/method","params":{}}]` +
		"\n"
	acp_test_client_send(&client, batch)
	frame := acp_test_client_receive(&client)
	if frame == "" { return }
	testing.expect(t, strings.has_prefix(frame, `[`))
	testing.expect(t, strings.contains(frame, `"id":1`) && strings.contains(frame, `"id":2`))
	testing.expect(t, strings.contains(frame, `"protocolVersion":2`))
}

@(test)
test_acp_v2_version_with_v1_fields_uses_the_v1_wire_profile_and_a_malformed_v1_request_is_refused :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	state, state_err := os.make_directory_temp("", "nabla-acp-v1-fallback-state-*", context.allocator)
	if state_err != nil {
		testing.expectf(t, false, "could not create a temporary state directory: %v", state_err)
		return
	}
	defer {
		_ = os.remove_all(state)
		delete(state, context.allocator)
	}
	previous_state, had_state := acp_test_env(t, "XDG_STATE_HOME", state)
	defer acp_test_env_restore("XDG_STATE_HOME", previous_state, had_state)
	previous_runtime, had_runtime := acp_test_env(t, "XDG_RUNTIME_DIR", state)
	defer acp_test_env_restore("XDG_RUNTIME_DIR", previous_runtime, had_runtime)
	previous_cache, had_cache := acp_test_env(t, "XDG_CACHE_HOME", state)
	defer acp_test_env_restore("XDG_CACHE_HOME", previous_cache, had_cache)

	client: ACP_Test_Client
	defer acp_test_client_destroy(&client)
	run := ACP_Test_Run {
		client = &client,
	}
	run_thread := thread.create(acp_test_run_thread, name = "nabla-acp-v1-fallback-run")
	if run_thread == nil {
		testing.expect(t, false, "the run thread could not be started")
		return
	}
	run_thread.data = &run
	thread.start(run_thread)
	defer {
		acp_test_client_hang_up(&client)
		thread.join(run_thread)
		testing.expect(t, run.served, "the run did not end cleanly")
		thread.destroy(run_thread)
		free_all(context.temp_allocator)
	}

	// A request that is not v2 is read as v1, so a malformed client description is refused.
	malformed := `{"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":1,"clientInfo":"v1-client"}}` + "\n"
	acp_test_client_send(&client, malformed)
	if acp_test_client_expect(t, &client, `"code":-32602`, "a malformed clientInfo was not refused as invalid params") == "" { return }

	message :=
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":2,"clientCapabilities":{},"clientInfo":{"name":"v1-client","version":"test"}}}` +
		"\n"
	acp_test_client_send(&client, message)
	frame := acp_test_client_expect(t, &client, `"protocolVersion":1`, "a version 2 request with v1 fields did not receive the v1 profile")
	if frame == "" { return }
	testing.expect(t, strings.contains(frame, `"agentCapabilities"`))
	testing.expect(t, strings.contains(frame, `"agentInfo"`))
	testing.expect(t, !strings.contains(frame, `"capabilities":{"session"`))

	// The options this agent offers take an id, so a boolean value is refused before any session is looked up.
	boolean :=
		`{"jsonrpc":"2.0","id":9,"method":"session/set_config_option","params":{"sessionId":"s","configId":"model","type":"boolean","value":true}}` + "\n"
	acp_test_client_send(&client, boolean)
	acp_test_client_expect(t, &client, `needs a session, config id, and value`, "a boolean config value was not refused")

	// An extension notification is ignored without a reply, and an extension request is not found.
	acp_test_client_send(&client, `{"jsonrpc":"2.0","method":"_vendor/ping","params":{}}` + "\n")
	acp_test_client_send(&client, `{"jsonrpc":"2.0","id":10,"method":"_vendor/call","params":{}}` + "\n")
	acp_test_client_expect(t, &client, `"id":10,"error":{"code":-32601`, "an extension request was not answered as not found")
}

@(test)
test_acp_worker_activity_prevents_eviction_until_idle :: proc(t: ^testing.T) {
	server: ACP_Server
	if !acp_test_server_init(t, &server) { return }
	defer testing.expect(t, acp_server_destroy(&server), "the ACP test server did not shut down")
	for i in 0 ..< ACP_MAX_SESSIONS {
		session, made := acp_session_make(&server, fmt.tprintf("session-%d", i))
		if !testing.expect(t, made, "the fixture session could not be allocated") { return }
		server.sessions[i] = session
		acp_session_touch(session)
		if sync.mutex_guard(&server.table_mu) {
			session.worker_active = true
		}
	}
	first := server.sessions[0]
	refused, reason := acp_session_create(&server, "session-ninth")
	testing.expect(t, refused == nil, "worker activity allowed eviction")
	testing.expect(t, strings.contains(reason, "all of them are busy"), "the refusal did not report busy sessions")
	if sync.mutex_guard(&server.table_mu) {
		first.worker_active = false
	}
	opened, open_reason := acp_session_create(&server, "session-ninth")
	testing.expectf(t, opened != nil, "restored idle did not allow eviction: %s", open_reason)
	testing.expect(t, acp_session_find(&server, "session-0") == nil, "the restored idle session was not evicted")
	closing := server.sessions[1]
	if sync.mutex_guard(&server.table_mu) {
		closing.closing = true
	}
	testing.expect(t, acp_session_is_closing(closing), "closing was not observed")
}

@(test)
test_acp_idle_workers_stay_evictable_after_a_wake :: proc(t: ^testing.T) {
	server: ACP_Server
	if !acp_test_server_init(t, &server) { return }
	defer testing.expect(t, acp_server_destroy(&server), "the ACP test server did not shut down")
	server.profile = .V2
	for i in 0 ..< ACP_MAX_SESSIONS {
		session, made := acp_session_make(&server, fmt.tprintf("session-%d", i))
		if !testing.expect(t, made, "the fixture session could not be allocated") { return }
		worker := thread.create(acp_worker, name = "nabla-acp-worker")
		if !testing.expect(t, worker != nil, "the fixture worker could not be created") {
			acp_session_free(session)
			return
		}
		worker.data = session
		session.worker = worker
		server.sessions[i] = session
		acp_session_touch(session)
		thread.start(worker)
	}
	// The wake is process-wide: every worker looks for work and finds none.
	agent.owner_wake_signal()
	opened, reason := acp_session_create(&server, "session-ninth")
	if !testing.expectf(t, opened != nil, "an idle session with a store blocked eviction: %s", reason) { return }
	testing.expect(t, acp_session_find(&server, "session-0") == nil, "the least recently used session was not evicted")
	testing.expect(t, acp_session_find(&server, "session-1") != nil, "a newer session was evicted instead")
	testing.expect(t, acp_session_find(&server, "session-ninth") != nil, "the new session was not published")
}

// --- the follower --------------------------------------------------------------

// ACP_Test_Buffer collects the frames the writer thread produces, so a test reads what
// the editor would have been sent.
ACP_Test_Buffer :: struct {
	mu:     sync.Mutex,
	cond:   sync.Cond,
	frames: [dynamic]u8,
}

acp_test_buffer_writer :: proc(buffer: ^ACP_Test_Buffer) -> io.Writer {
	return io.Writer{data = buffer, procedure = acp_test_buffer_stream}
}

acp_test_buffer_stream :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	buffer := cast(^ACP_Test_Buffer)data
	switch mode {
	case .Write:
		sync.mutex_lock(&buffer.mu)
		append(&buffer.frames, ..p)
		sync.cond_broadcast(&buffer.cond)
		sync.mutex_unlock(&buffer.mu)
		return i64(len(p)), nil
	case .Query:
		return i64(io.Stream_Mode_Set{.Write}), nil
	case .Close, .Destroy, .Flush:
		return 0, nil
	case .Read, .Seek, .Read_At, .Write_At, .Size:
		return 0, .Unsupported
	}
	return 0, .Unsupported
}

acp_test_buffer_text :: proc(buffer: ^ACP_Test_Buffer, allocator := context.temp_allocator) -> string {
	sync.mutex_lock(&buffer.mu)
	defer sync.mutex_unlock(&buffer.mu)
	return strings.clone(string(buffer.frames[:]), allocator)
}

// acp_test_buffer_wait blocks until the buffer holds needle, so a test reads what the
// writer thread had not flushed yet. False means the wait ran out, and the test fails.
acp_test_buffer_wait :: proc(t: ^testing.T, buffer: ^ACP_Test_Buffer, needle, what: string) -> bool {
	deadline := time.tick_add(time.tick_now(), ACP_TEST_BOUND)
	for {
		sync.mutex_lock(&buffer.mu)
		found := strings.contains(string(buffer.frames[:]), needle)
		if found {
			sync.mutex_unlock(&buffer.mu)
			return true
		}
		remaining := time.tick_diff(time.tick_now(), deadline)
		if remaining <= 0 {
			sync.mutex_unlock(&buffer.mu)
			break
		}
		sync.cond_wait_with_timeout(&buffer.cond, &buffer.mu, remaining)
		sync.mutex_unlock(&buffer.mu)
	}
	return testing.expectf(t, false, "%s: timed out waiting for %q", what, needle)
}

// acp_test_interface is a hand-built connection for tests that drive the worker
// directly: no reader thread, no session table insert, no server process. The catalog
// is borrowed, so the caller keeps it alive and destroys it.
ACP_Test_Interface :: struct {
	server: ACP_Server,
	buffer: ACP_Test_Buffer,
}

acp_test_interface_init :: proc(t: ^testing.T, iface: ^ACP_Test_Interface, profile: ACP_Wire_Profile, catalog: ^agent.Catalog) {
	iface.server.alloc = context.allocator
	iface.server.profile = profile
	iface.buffer.frames.allocator = context.allocator
	iface.server.app.setup.alloc = context.allocator
	iface.server.app.setup.catalog = catalog^
	writer, writer_error := acp.writer_init(acp_test_buffer_writer(&iface.buffer), context.allocator)
	if writer_error != nil { testing.fail_now(t, "the test writer could not be created") }
	iface.server.writer = writer
}

acp_test_interface_destroy :: proc(iface: ^ACP_Test_Interface) {
	acp_test_writer_cleanup(&iface.server.writer)
	delete(iface.buffer.frames)
}

@(test)
test_acp_model_values_identify_the_named_provider :: proc(t: ^testing.T) {
	catalog := acp_test_catalog(context.allocator)
	defer agent.catalog_destroy(&catalog)
	iface: ACP_Test_Interface
	acp_test_interface_init(t, &iface, .V1, &catalog)
	defer acp_test_interface_destroy(&iface)
	session: ACP_Session
	session.conn = &iface.server
	provider, model, found := acp_model_identify(&session, "test-provider/test-model")
	testing.expect(t, found, "the catalog value was not identified")
	testing.expect_value(t, provider, "test-provider")
	testing.expect_value(t, model, "test-model")
	_, _, missing := acp_model_identify(&session, "test-provider/no-such-model")
	testing.expect(t, !missing, "an unknown model value was identified")
	_, _, malformed := acp_model_identify(&session, "no-separator")
	testing.expect(t, !malformed, "a value without a provider was identified")
}

@(test)
test_acp_effort_allowed_follows_the_models_levels :: proc(t: ^testing.T) {
	catalog := acp_test_effort_catalog(context.allocator)
	defer agent.catalog_destroy(&catalog)
	iface: ACP_Test_Interface
	acp_test_interface_init(t, &iface, .V1, &catalog)
	defer acp_test_interface_destroy(&iface)
	session: ACP_Session
	session.conn = &iface.server
	// An empty level clears the override back to the provider default and is always allowed.
	testing.expect(t, acp_effort_allowed(&session, "test-provider", "test-model", ""), "the default effort was refused")
	testing.expect(t, acp_effort_allowed(&session, "test-provider", "test-model", "high"), "a stated level was refused")
	testing.expect(t, !acp_effort_allowed(&session, "test-provider", "test-model", "enormous"), "an unstated level was allowed")
	testing.expect(t, !acp_effort_allowed(&session, "test-provider", "no-such-model", "high"), "a level of an unknown model was allowed")
}

// acp_test_open_work builds an owned resume request for session id. The caller releases
// it with acp_work_destroy.
acp_test_open_work :: proc(
	t: ^testing.T,
	session_id: journal.Session_Id,
	workspace: string,
	servers: [dynamic]agent.MCP_Server_Config,
	allocator: mem.Allocator,
) -> ACP_Work_Open_Session {
	hex: [journal.SESSION_ID_HEX_LENGTH]u8
	session_ref, ref_error := strings.clone(journal.session_id_to_hex(session_id, hex[:]), allocator)
	if ref_error != nil { testing.fail_now(t, "the session reference could not be held") }
	owned_workspace, workspace_error := strings.clone(workspace, allocator)
	if workspace_error != nil { testing.fail_now(t, "the workspace could not be held") }
	prompt, prompt_error := strings.clone("speak plainly", allocator)
	if prompt_error != nil { testing.fail_now(t, "the instructions could not be held") }
	title, title_error := strings.clone("editor title", allocator)
	if title_error != nil { testing.fail_now(t, "the title could not be held") }
	return {
		workspace = owned_workspace,
		session_ref = session_ref,
		mcp_servers = servers,
		system_prompt = prompt,
		session_title = title,
		start = Start_Resume_Id(session_ref),
		replay = true,
	}
}

@(test)
test_acp_open_records_environment_and_follows :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	state, previous, had_previous := acp_test_state_isolate(t)
	defer acp_test_state_restore(state, previous, had_previous)
	workspace, workspace_error := os.make_directory_temp("", "nabla-acp-open-workspace-*", context.allocator)
	if workspace_error != nil { testing.fail_now(t, "could not create a temporary workspace") }
	defer {
		_ = os.remove_all(workspace)
		delete(workspace, context.allocator)
	}
	// Another process runs the session: its store holds the claim, so the connection
	// follows it and starts no server of its own.
	locks, _, locks_error := agent.session_lock_directory(context.allocator)
	if locks_error != .None { testing.fail_now(t, "the lock directory could not be resolved") }
	defer delete(locks, context.allocator)
	runner, runner_error := journal.open(state, locks, journal.run_id_create(), .Read_Write, context.allocator)
	if runner_error != nil { testing.fail_now(t, "the runner journal could not open") }
	defer _ = journal.close(runner)
	session_id, create_error := journal.create_session(runner, {workspace = workspace, role = .Main})
	if create_error != nil { testing.fail_now(t, "the session could not be created") }
	if _, commit_error := journal.commit(runner); commit_error != nil { testing.fail_now(t, "the session could not be committed") }

	catalog := acp_test_catalog(context.allocator)
	defer agent.catalog_destroy(&catalog)
	iface: ACP_Test_Interface
	acp_test_interface_init(t, &iface, .V2, &catalog)
	defer acp_test_interface_destroy(&iface)
	server := &iface.server
	server.app.setup.journal_directory = strings.clone(state, context.allocator)
	defer delete(server.app.setup.journal_directory, context.allocator)
	server.app.setup.lock_directory = strings.clone(locks, context.allocator)
	defer delete(server.app.setup.lock_directory, context.allocator)
	server.app.setup.run = journal.run_id_create()
	server.app.setup.provider_id = strings.clone("test-provider", context.allocator)
	defer delete(server.app.setup.provider_id, context.allocator)
	server.app.setup.model_id = strings.clone("test-model", context.allocator)
	defer delete(server.app.setup.model_id, context.allocator)

	mcp_servers := make([dynamic]agent.MCP_Server_Config, 0, 1, context.allocator)
	mcp_server, mcp_error := agent.MCP_Server_Config_From_Stdio("editor", "/bin/true", nil, nil, nil, context.allocator)
	if mcp_error != .None { testing.fail_now(t, "the MCP server could not be configured") }
	if append(&mcp_servers, mcp_server) != 1 { testing.fail_now(t, "the server list could not be built") }
	work := acp_test_open_work(t, session_id, workspace, mcp_servers, context.allocator)
	item := ACP_Work {
		id      = i64(1),
		variant = work,
	}
	defer acp_work_destroy(&item, context.allocator)
	session: ACP_Session
	session.conn = server
	acp_work_open_session(&session, i64(1), work)
	if !testing.expect(t, session.opened, "the session did not open") { return }
	defer acp_session_release(&session)
	hex: [journal.SESSION_ID_HEX_LENGTH]u8
	testing.expect_value(t, session.id, journal.session_id_to_hex(session_id, hex[:]))

	frames := acp_test_buffer_text(&iface.buffer)
	if !testing.expect(t, strings.contains(frames, `"configOptions"`), "the open answer has no config options") { return }
	testing.expect(t, strings.contains(frames, "test-provider/test-model"), "the open answer names no serving identity")
	testing.expect(t, strings.contains(frames, `"availableCommands"`), "the open answer advertises no commands")

	environment, _, env_found, env_error := journal.read_session_environment(session.store, session_id, context.temp_allocator)
	if !testing.expect(t, env_error == nil, "the environment could not be read") { return }
	if !testing.expect(t, env_found, "the interface recorded no environment") { return }
	defer agent.session_environment_destroy(&environment, context.temp_allocator)
	testing.expect_value(t, environment.instructions, "speak plainly")
	if testing.expect_value(t, len(environment.servers), 1) {
		testing.expect_value(t, environment.servers[0].id, "editor")
	}

	// Opening the same session again records its environment again and answers again.
	again_servers := make([dynamic]agent.MCP_Server_Config, context.allocator)
	again := acp_test_open_work(t, session_id, workspace, again_servers, context.allocator)
	again_item := ACP_Work {
		id      = i64(2),
		variant = again,
	}
	defer acp_work_destroy(&again_item, context.allocator)
	acp_work_open_session(&session, i64(2), again)
	testing.expect(t, session.opened, "the session did not stay open")
}

// --- driving a turn ------------------------------------------------------------

// acp_test_app_begin claims a session in a fresh directory and builds the running chat
// over it, the way the session server holds one. The caller ends it with
// acp_test_app_end. Only the subsystems a turn needs are initialized: no transcript,
// menu, or Code Mode state, which no driven turn touches.
acp_test_app_begin :: proc(t: ^testing.T, app: ^App, lock_directory := "") -> (directory, workspace: string) {
	state_directory, state_error := os.make_directory_temp("", "nabla-acp-test-*", context.allocator)
	if state_error != nil { testing.fail_now(t, "could not create a temporary directory") }
	work_directory, work_error := os.make_directory_temp("", "nabla-acp-test-workspace-*", context.allocator)
	if work_error != nil { testing.fail_now(t, "could not create a temporary workspace") }
	directory = state_directory
	workspace = work_directory
	locks := lock_directory if lock_directory != "" else directory

	app.run.alloc = context.allocator
	app.setup.alloc = context.allocator
	app.run.snap.entries = make([dynamic]Entry, 0, 4, app.run.alloc)

	app.setup.journal_directory = strings.clone(directory, app.setup.alloc)
	app.setup.lock_directory = strings.clone(locks, app.setup.alloc)
	app.setup.run = journal.run_id_create()
	store_open_error: journal.Error
	app.setup.store, store_open_error = journal.open(directory, locks, app.setup.run, .Read_Write, app.setup.alloc)
	if store_open_error != nil { testing.fail_now(t, "the journal could not open") }
	id, create_error := journal.create_session(app.setup.store, {workspace = workspace, role = .Main})
	if create_error != nil { testing.fail_now(t, "the session could not be created") }
	if _, commit_error := journal.commit(app.setup.store); commit_error != nil { testing.fail_now(t, "the session could not be committed") }
	app.setup.workspace = strings.clone(workspace, app.setup.alloc)
	tool_error: agent.Tool_Registry_Error
	app.setup.session, tool_error = agent.chat_session_init(app.setup.store, id, journal.INITIAL_BRANCH, 0, workspace, context.allocator)
	if tool_error.kind != .None { testing.fail_now(t, "the tool registry could not be created") }
	app.setup.session.skill_instructions = agent.test_skill_instructions(&app.setup.session)
	return directory, workspace
}

acp_test_app_end :: proc(app: ^App, directory, workspace: string) {
	journal.records_destroy(app.setup.follow_pending, app.setup.alloc)
	agent.chat_session_destroy(&app.setup.session)
	delete(app.setup.workspace, app.setup.alloc)
	app.setup.workspace = ""
	agent.session_watch_stop(&app.setup.watch)
	_ = session_store_close(app.setup.store)
	app.setup.store = nil
	for &entry in app.run.snap.entries {
		entry_destroy(&entry)
	}
	delete(app.run.snap.entries)
	delete(app.run.snap.status.provider_id, app.run.alloc)
	delete(app.run.snap.status.model_id, app.run.alloc)
	delete(app.run.snap.status.effort, app.run.alloc)
	delete(app.run.snap.status.cwd, app.run.alloc)
	for level in app.run.snap.status.effort_levels { delete(level, app.run.alloc) }
	delete(app.run.snap.status.effort_levels)
	delete(app.run.snap.setup_error, app.run.alloc)
	catalog_run_destroy(app)
	_ = os.remove_all(workspace)
	delete(workspace, app.setup.alloc)
	delete(app.setup.resumed_provider, app.setup.alloc)
	delete(app.setup.resumed_model, app.setup.alloc)
	delete(app.setup.resumed_effort, app.setup.alloc)
	delete(app.setup.provider_id, app.setup.alloc)
	delete(app.setup.model_id, app.setup.alloc)
	delete(app.setup.credential, app.setup.alloc)
	delete(app.setup.journal_directory, app.setup.alloc)
	delete(app.setup.lock_directory, app.setup.alloc)
	_ = os.remove_all(directory)
	delete(directory, context.allocator)
}

// acp_test_catalog is the smallest catalog a selection installs: one usable provider
// with a literal credential, and one model that states its window and supports tools.
acp_test_catalog :: proc(allocator: mem.Allocator, base_url := "http://127.0.0.1:1") -> agent.Catalog {
	sources := []agent.Catalog_Provider_Source {
		{
			id = "test-provider",
			base_url = base_url,
			api = "openai_chat_completions",
			api_key = "test-key",
			models = []agent.Catalog_Model_Source{{id = "test-model", context_window = 128_000, max_output_tokens = 4_096, tools = true}},
		},
	}
	catalog, _ := agent.resolve_catalog(sources, {}, {}, allocator)
	return catalog
}

// acp_test_effort_catalog serves one model that states two effort levels.
acp_test_effort_catalog :: proc(allocator: mem.Allocator) -> agent.Catalog {
	sources := []agent.Catalog_Provider_Source {
		{
			id = "test-provider",
			base_url = "http://127.0.0.1:1",
			api = "openai_chat_completions",
			api_key = "test-key",
			models = []agent.Catalog_Model_Source {
				{
					id = "test-model",
					context_window = 128_000,
					max_output_tokens = 4_096,
					tools = true,
					thinking = agent.Catalog_Thinking_Source{present = true, supported = true, levels = []string{"low", "high"}},
				},
			},
		},
	}
	catalog, _ := agent.resolve_catalog(sources, {}, {}, allocator)
	return catalog
}

// acp_test_state_isolate points the state and runtime directories at a temporary
// directory, so a test that follows a session through its lock file cannot touch the
// user's own files. It returns the previous state value, which acp_test_state_restore
// puts back. The variables are process-wide, so tests using this helper run isolated in
// a child of the test binary.
acp_test_state_isolate :: proc(t: ^testing.T) -> (state: string, previous: string, had_previous: bool) {
	directory, directory_error := os.make_directory_temp("", "nabla-acp-test-state-*", context.allocator)
	if directory_error != nil { testing.fail_now(t, "could not create a temporary state directory") }
	previous, had_previous = os.lookup_env("XDG_STATE_HOME", context.allocator)
	if os.set_env("XDG_STATE_HOME", directory) != nil { testing.fail_now(t, "could not set the state root") }
	if os.set_env("XDG_RUNTIME_DIR", directory) != nil { testing.fail_now(t, "could not set the runtime root") }
	return directory, previous, had_previous
}

acp_test_state_restore :: proc(state, previous: string, had_previous: bool) {
	// The process is the isolated child this suite runs in, so a restore that fails
	// changes nothing that outlives it.
	if had_previous {
		_ = os.set_env("XDG_STATE_HOME", previous)
	} else {
		_ = os.unset_env("XDG_STATE_HOME")
	}
	delete(previous, context.allocator)
	_ = os.remove_all(state)
	delete(state, context.allocator)
}

// acp_test_stub_replies answers each incoming request with the next reply, in order. It
// stands in for a provider endpoint, so a turn runs for real: the harness sends
// requests, reads streams, and records results exactly as it would against a server.
ACP_Test_Replies :: struct {
	listener: net.TCP_Socket,
	replies:  []string,
	served:   int,
	failed:   bool,
}

acp_test_stub_thread :: proc(thread_handle: ^thread.Thread) {
	stub := cast(^ACP_Test_Replies)thread_handle.data
	// The thread serves the replies in order and then exits, so a turn that asks for
	// more hangs nothing: its extra requests are refused. The test closes the
	// listener before joining, which releases a thread still waiting for a request
	// the turn never made.
	for stub.served < len(stub.replies) {
		client, _, accept_error := net.accept_tcp(stub.listener)
		if accept_error != nil { return }
		if !acp_test_stub_answer(client, stub.replies[stub.served]) {
			stub.failed = true
			return
		}
		stub.served += 1
	}
}

// acp_test_stub_answer reads one whole request before answering it, so the harness is
// never still writing when the connection closes.
acp_test_stub_answer :: proc(client: net.TCP_Socket, reply: string) -> bool {
	defer net.close(client)
	_ = net.set_option(client, .Receive_Timeout, ACP_TEST_BOUND)
	request := make([dynamic]u8, 0, 4096, context.temp_allocator)
	defer delete(request)
	header_end := -1
	for header_end < 0 {
		buffer: [4096]u8
		read, read_error := net.recv_tcp(client, buffer[:])
		if read_error != nil || read <= 0 { return false }
		append(&request, ..buffer[:read])
		header_end = strings.index(string(request[:]), "\r\n\r\n")
	}
	body_length := 0
	headers := string(request[:header_end])
	remaining := headers
	for line in strings.split_lines_iterator(&remaining) {
		if !strings.has_prefix(strings.to_lower(line), "content-length:") { continue }
		if parsed, ok := strconv.parse_int(strings.trim_space(line[len("content-length:"):]), 10); ok { body_length = parsed }
	}
	for len(request) < header_end + 4 + body_length {
		buffer: [4096]u8
		read, read_error := net.recv_tcp(client, buffer[:])
		if read_error != nil || read <= 0 { return false }
		append(&request, ..buffer[:read])
	}
	_, _ = net.send_tcp(client, transmute([]u8)reply)
	return true
}

// acp_test_stream_reply wraps one event stream as the HTTP reply a provider sends. The
// body is built in the test's scratch memory, because it is served as soon as it exists.
acp_test_stream_reply :: proc(events: []string, allocator := context.temp_allocator) -> string {
	body := strings.builder_make(allocator)
	for event in events {
		strings.write_string(&body, "data: ")
		strings.write_string(&body, event)
		strings.write_string(&body, "\n\n")
	}
	strings.write_string(&body, "data: [DONE]\n\n")
	stream := strings.to_string(body)
	reply := fmt.aprintf("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: %d\r\n\r\n%s", len(stream), stream, allocator = allocator)
	delete(body.buf)
	return reply
}

// acp_test_tool_reply builds the two replies of a turn that reads one file: the tool
// call for it, then the answer the turn ends on. The arguments are a JSON document
// inside a JSON string, so the encoder writes them.
acp_test_tool_reply :: proc(t: ^testing.T, note: string, allocator := context.temp_allocator) -> (first, second: string) {
	arguments, arguments_error := json.marshal(struct {
			path: string,
		}{path = note}, allocator = allocator)
	if arguments_error != nil { testing.fail_now(t, "the tool arguments could not be built") }
	quoted, quoted_error := json.marshal(string(arguments), allocator = allocator)
	if quoted_error != nil { testing.fail_now(t, "the tool arguments could not be quoted") }
	call_event := strings.builder_make(allocator)
	strings.write_string(&call_event, `{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read","arguments":`)
	strings.write_string(&call_event, string(quoted))
	strings.write_string(&call_event, `}}]},"finish_reason":null}]}`)
	first = acp_test_stream_reply({strings.to_string(call_event), `{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`}, allocator)
	second = acp_test_stream_reply(
		{`{"choices":[{"delta":{"content":"the note says so"},"finish_reason":null}]}`, `{"choices":[{"delta":{},"finish_reason":"stop"}]}`},
		allocator,
	)
	return first, second
}

// acp_test_stub_endpoint listens on a loopback port no other test uses, for the stub
// provider thread to serve.
acp_test_stub_endpoint :: proc(t: ^testing.T) -> (listener: net.TCP_Socket, endpoint: net.Endpoint) {
	sock, sock_error := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	if sock_error != nil { testing.fail_now(t, fmt.tprintf("the stub endpoint could not listen: %v", sock_error)) }
	bound, bound_error := net.bound_endpoint(sock)
	if bound_error != nil { testing.fail_now(t, fmt.tprintf("the stub endpoint address could not be read: %v", bound_error)) }
	listener = sock
	endpoint = bound
	return listener, endpoint
}

// acp_test_client_session_id_from_frame reads the session id out of a session/new
// answer frame. The reader tests only need the id to name later requests.
acp_test_client_session_id_from_frame :: proc(t: ^testing.T, frame: string) -> string {
	marker := `"sessionId":"`
	at := strings.index(frame, marker)
	if at < 0 { testing.fail_now(t, "the session/new frame had no session id") }
	rest := frame[at + len(marker):]
	end := strings.index_byte(rest, '"')
	if end < 0 { testing.fail_now(t, "the session/new frame had no session id") }
	return strings.clone(rest[:end], context.allocator)
}

@(test)
test_acp_follower_translates_committed_records :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	listener, endpoint := acp_test_stub_endpoint(t)
	app: App
	directory, workspace := acp_test_app_begin(t, &app)
	defer acp_test_app_end(&app, directory, workspace)
	note := fmt.aprintf("%s/note.txt", workspace, allocator = context.allocator)
	defer delete(note, context.allocator)
	if write_error := os.write_entire_file(note, "the file the tool reads\n"); write_error != nil {
		testing.fail_now(t, "the note could not be written")
	}
	first, second := acp_test_tool_reply(t, note)
	replies := []string{first, second}
	stub := ACP_Test_Replies {
		listener = listener,
		replies  = replies,
	}
	provider := thread.create(acp_test_stub_thread, name = "nabla-acp-test-provider")
	if provider == nil { testing.fail_now(t, "the stub thread could not be created") }
	provider.data = &stub
	thread.start(provider)
	defer {
		_ = net.shutdown(listener, .Both)
		net.close(listener)
		thread.join(provider)
		thread.destroy(provider)
		testing.expect(t, !stub.failed, "the stub provider failed")
		testing.expect_value(t, stub.served, len(replies))
	}

	base_url := fmt.aprintf("http://127.0.0.1:%d", endpoint.port, allocator = context.allocator)
	defer delete(base_url, context.allocator)
	app.setup.catalog = acp_test_catalog(app.setup.alloc, base_url)
	defer agent.catalog_destroy(&app.setup.catalog)
	if !testing.expect(t, selection_apply_direct(&app, "test-provider", "test-model", ""), "the stub model could not be selected") {
		return
	}
	chat := &app.setup.session
	id := chat.session

	// The follower appends the line and polls what the runner commits, the way the
	// interface worker does.
	follower, follower_error := journal.open(directory, directory, journal.run_id_create(), .Read_Write, context.allocator)
	if follower_error != nil { testing.fail_now(t, "the follower journal could not open") }
	if follow_error := journal.follow(follower, id); follow_error != nil { testing.fail_now(t, "the follower could not follow") }
	cursor, cursor_error := agent.follow_start(follower, id)
	if cursor_error != nil { testing.fail_now(t, "the follow could not start") }
	iface: ACP_Test_Interface
	acp_test_interface_init(t, &iface, .V2, &app.setup.catalog)
	defer acp_test_interface_destroy(&iface)
	session := ACP_Session {
		conn = &iface.server,
		store = follower,
		session_id = id,
		follow = Client_Follow{store = follower, session = id, cursor = cursor},
	}
	defer acp_session_release(&session)
	input, appended := acp_append_input(&session, "read the note", .Prompt, nil)
	if !testing.expect(t, appended, "the line was not appended") { return }
	session.follow.cursor.input = input

	// The runner delivers the line and runs one turn to its end.
	if accepted := agent.chat_session_accept_message(chat, "", .Agent, {}); !testing.expect(t, accepted == .Accepted, "the line was not accepted") { return }
	if !testing.expect(
		t,
		agent.chat_run_turn_steered(chat, app.run.connection, agent.chat_retry_policy_default(), {}, nil, nil),
		"the turn did not complete",
	) { return }

	if poll_error := client_follow_poll(&session.follow, acp_observer(&session));
	   !testing.expect(t, poll_error == nil, "the follow could not be polled") { return }
	testing.expect(t, session.follow.cursor.ended, "the turn did not end the wait")
	testing.expect_value(t, session.follow.cursor.outcome, journal.Turn_Outcome.Completed)

	// Every committed record arrives as the session/update notification that carries
	// it: the echoed line, the answer, the announced call and its result, and usage.
	if !acp_test_buffer_wait(t, &iface.buffer, `"sessionUpdate":"usage_update"`, "the usage report") { return }
	frames := acp_test_buffer_text(&iface.buffer)
	if !testing.expect(t, strings.contains(frames, `"sessionUpdate":"user_message"`), "the line was not echoed") { return }
	testing.expect(t, strings.contains(frames, "read the note"), "the echo lost the line")
	testing.expect(t, strings.contains(frames, `"sessionUpdate":"agent_message_chunk"`), "the answer did not stream")
	testing.expect(t, strings.contains(frames, "the note says so"), "the answer lost its text")
	testing.expect(t, strings.contains(frames, `"status":"pending"`), "the call was not announced")
	testing.expect(t, strings.contains(frames, `"toolCallId":"call_1"`), "the call lost its provider id")
	testing.expect(t, strings.contains(frames, note), "the call lost its arguments")
	testing.expect(t, strings.contains(frames, "the file the tool reads"), "the result lost its content")
	testing.expect(t, strings.contains(frames, `"sessionUpdate":"usage_update"`), "usage was not reported")
}

// test_acp_replay_reports_committed_history loads a finished turn and checks that the
// replay sends the committed user line, the answer, and the stored call.
@(test)
test_acp_replay_reports_committed_history :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	listener, endpoint := acp_test_stub_endpoint(t)
	app: App
	directory, workspace := acp_test_app_begin(t, &app)
	defer acp_test_app_end(&app, directory, workspace)
	note := fmt.aprintf("%s/note.txt", workspace, allocator = context.allocator)
	defer delete(note, context.allocator)
	if write_error := os.write_entire_file(note, "the file the tool reads\n"); write_error != nil {
		testing.fail_now(t, "the note could not be written")
	}
	first, second := acp_test_tool_reply(t, note)
	replies := []string{first, second}
	stub := ACP_Test_Replies {
		listener = listener,
		replies  = replies,
	}
	provider := thread.create(acp_test_stub_thread, name = "nabla-acp-test-provider")
	if provider == nil { testing.fail_now(t, "the stub thread could not be created") }
	provider.data = &stub
	thread.start(provider)
	defer {
		_ = net.shutdown(listener, .Both)
		net.close(listener)
		thread.join(provider)
		thread.destroy(provider)
		testing.expect(t, !stub.failed, "the stub provider failed")
		testing.expect_value(t, stub.served, len(replies))
	}

	base_url := fmt.aprintf("http://127.0.0.1:%d", endpoint.port, allocator = context.allocator)
	defer delete(base_url, context.allocator)
	app.setup.catalog = acp_test_catalog(app.setup.alloc, base_url)
	defer agent.catalog_destroy(&app.setup.catalog)
	if !testing.expect(t, selection_apply_direct(&app, "test-provider", "test-model", ""), "the stub model could not be selected") {
		return
	}
	chat := &app.setup.session
	id := chat.session
	if accepted := agent.chat_session_accept_user(chat, "read the note"); !testing.expect(t, accepted == .Accepted, "the prompt was not accepted") { return }
	if !testing.expect(
		t,
		agent.chat_run_turn_steered(chat, app.run.connection, agent.chat_retry_policy_default(), {}, nil, nil),
		"the turn did not complete",
	) { return }

	// A load replays the committed history through the same updates a live turn
	// streams: full user and assistant messages, and each stored call with the
	// result it produced. The store stays the app's until the replay has read it;
	// release must not close that store, because the app closes it.
	iface: ACP_Test_Interface
	acp_test_interface_init(t, &iface, .V2, &app.setup.catalog)
	defer acp_test_interface_destroy(&iface)
	session := ACP_Session {
		conn       = &iface.server,
		store      = app.setup.store,
		session_id = id,
	}
	defer {
		session.store = nil
		acp_session_release(&session)
	}
	acp_replay_session(&session)
	if !acp_test_buffer_wait(t, &iface.buffer, `"sessionUpdate":"agent_message"`, "the replayed answer") { return }
	frames := acp_test_buffer_text(&iface.buffer)
	testing.expect(t, strings.contains(frames, `"sessionUpdate":"user_message"`), "the replayed line is missing")
	testing.expect(t, strings.contains(frames, "read the note"), "the replay lost the line")
	testing.expect(t, strings.contains(frames, "the note says so"), "the replay lost the answer")
	testing.expect(t, strings.contains(frames, `"sessionUpdate":"tool_call_update"`), "the replayed call is missing")
	testing.expect(t, strings.contains(frames, `"toolCallId":"call_1"`), "the replayed call lost its id")
	testing.expect(t, strings.contains(frames, `"status":"completed"`), "the replay lost the call outcome")
}

// --- serving a turn ------------------------------------------------------------

// ACP_Test_Prompt drives one prompt through the worker while the test thread serves
// the session the way the session server does.
ACP_Test_Prompt :: struct {
	session: ^ACP_Session,
	id:      acp.JSONRPC_Id,
	text:    string,
}

acp_test_prompt_thread :: proc(thread_handle: ^thread.Thread) {
	waiter := cast(^ACP_Test_Prompt)thread_handle.data
	context.allocator = waiter.session.conn.alloc
	work := ACP_Work_Prompt {
		text = waiter.text,
	}
	acp_work_prompt(waiter.session, waiter.id, work)
	delete(work.text, waiter.session.conn.alloc)
}

// acp_test_fake_server marks the session as watched without starting a process: the
// test thread applies the server steps itself. The waiter then polls the journal the
// same way it would under a real server.
acp_test_fake_server :: proc(session: ^ACP_Session) {
	state := new(Client_Server_State, session.conn.alloc)
	session.server.state = state
}

acp_test_fake_server_destroy :: proc(session: ^ACP_Session) {
	free(session.server.state, session.conn.alloc)
	session.server.state = nil
}

// acp_test_await_inbox waits until the session holds an undelivered line, so the test
// thread can serve the turn the waiter appended.
@(require_results)
acp_test_await_inbox :: proc(t: ^testing.T, store: ^journal.Journal, id: journal.Session_Id) -> bool {
	deadline := time.tick_add(time.tick_now(), ACP_TEST_BOUND)
	for {
		seen := agent.owner_wake_seen()
		inbox, inbox_error := journal.read_inbox(store, id, 0, context.temp_allocator)
		defer free_all(context.temp_allocator)
		if inbox_error != nil {
			testing.expectf(t, false, "the inbox could not be read: %s", journal.error_text(inbox_error, context.temp_allocator))
			return false
		}
		if len(inbox) > 0 { return true }
		if time.tick_diff(time.tick_now(), deadline) <= 0 {
			testing.expect(t, false, "the appended line never reached the inbox")
			return false
		}
		agent.owner_wake_wait(seen, time.tick_add(time.tick_now(), 100 * time.Millisecond))
	}
}

// acp_test_prompt_roundtrip runs one prompt through the worker while the test thread
// serves its turn, and holds the served answer to the stop reason the profile reports.
acp_test_prompt_roundtrip :: proc(t: ^testing.T, profile: ACP_Wire_Profile, name: string) {
	if !test_isolate_process(t, name) { return }
	state, previous, had_previous := acp_test_state_isolate(t)
	defer acp_test_state_restore(state, previous, had_previous)
	listener, endpoint := acp_test_stub_endpoint(t)
	defer net.close(listener)
	reply := acp_test_stream_reply(
		[]string{`{"choices":[{"delta":{"content":"hello"},"finish_reason":null}]}`, `{"choices":[{"delta":{},"finish_reason":"stop"}]}`},
		context.allocator,
	)
	defer delete(reply, context.allocator)
	stub := ACP_Test_Replies {
		listener = listener,
		replies  = []string{reply},
	}
	provider := thread.create(acp_test_stub_thread, name = "nabla-acp-test-provider")
	if provider == nil { testing.fail_now(t, "the stub thread could not be created") }
	provider.data = &stub
	thread.start(provider)
	defer {
		_ = net.shutdown(listener, .Both)
		net.close(listener)
		thread.join(provider)
		thread.destroy(provider)
		testing.expect(t, !stub.failed, "the stub provider failed")
		testing.expect_value(t, stub.served, len(stub.replies))
	}

	locks, _, locks_error := agent.session_lock_directory(context.allocator)
	if locks_error != .None { testing.fail_now(t, "the lock directory could not be resolved") }
	defer delete(locks, context.allocator)
	app: App
	directory, workspace := acp_test_app_begin(t, &app, locks)
	defer acp_test_app_end(&app, directory, workspace)
	base_url := fmt.aprintf("http://127.0.0.1:%d", endpoint.port, allocator = context.allocator)
	defer delete(base_url, context.allocator)
	app.setup.catalog = acp_test_catalog(app.setup.alloc, base_url)
	defer agent.catalog_destroy(&app.setup.catalog)
	if !testing.expect(t, selection_apply_direct(&app, "test-provider", "test-model", ""), "the stub model could not be selected") {
		return
	}
	chat := &app.setup.session
	id := chat.session

	iface: ACP_Test_Interface
	acp_test_interface_init(t, &iface, profile, &app.setup.catalog)
	defer acp_test_interface_destroy(&iface)
	server := &iface.server
	server.app.setup.journal_directory = strings.clone(directory, context.allocator)
	defer delete(server.app.setup.journal_directory, context.allocator)
	server.app.setup.lock_directory = strings.clone(locks, context.allocator)
	defer delete(server.app.setup.lock_directory, context.allocator)
	server.app.setup.run = journal.run_id_create()

	store, store_error := journal.open(directory, locks, journal.run_id_create(), .Read_Write, context.allocator)
	if store_error != nil { testing.fail_now(t, "the follower journal could not open") }
	session := ACP_Session {
		conn       = server,
		store      = store,
		session_id = id,
	}
	follow, follow_error := client_follow_open(session.store, session.session_id)
	if follow_error.kind != .None { testing.fail_now(t, "the session could not be followed") }
	session.follow = follow
	provider_id, provider_error := strings.clone("test-provider", context.allocator)
	model_id, model_error := strings.clone("test-model", context.allocator)
	if provider_error != nil || model_error != nil { testing.fail_now(t, "the serving identity could not be held") }
	session.provider_id = provider_id
	session.model_id = model_id
	acp_test_fake_server(&session)
	defer {
		acp_test_fake_server_destroy(&session)
		acp_session_release(&session)
	}

	text, text_error := strings.clone("say hello", context.allocator)
	if text_error != nil { testing.fail_now(t, "the prompt could not be held") }
	waiter := ACP_Test_Prompt {
		session = &session,
		id      = i64(1),
		text    = text,
	}
	prompt_thread := thread.create(acp_test_prompt_thread, name = "nabla-acp-test-prompt")
	if prompt_thread == nil { testing.fail_now(t, "the prompt thread could not be created") }
	prompt_thread.data = &waiter
	thread.start(prompt_thread)
	defer {
		thread.join(prompt_thread)
		thread.destroy(prompt_thread)
	}
	if !acp_test_await_inbox(t, app.setup.store, id) { return }
	step, step_ok := serve_step(&app)
	if !testing.expect(t, step_ok, "the server step must read") { return }
	testing.expect_value(t, step, Serve_Step.Turn)
	testing.expect(t, serve_run_turn(&app), "the server turn did not run")

	if profile == .V2 {
		if !acp_test_buffer_wait(t, &iface.buffer, `"state":"idle"`, "the idle state") { return }
		frames := acp_test_buffer_text(&iface.buffer)
		testing.expect(t, strings.contains(frames, `"sessionUpdate":"user_message"`), "the prompt was not echoed")
		testing.expect(t, strings.contains(frames, `"state":"running"`), "the turn was not announced as running")
		testing.expect(t, strings.contains(frames, `"stopReason":"end_turn"`), "the turn did not report end_turn")
	} else {
		if !acp_test_buffer_wait(t, &iface.buffer, `"stopReason":"end_turn"`, "the prompt result") { return }
	}
	frames := acp_test_buffer_text(&iface.buffer)
	testing.expect(t, strings.contains(frames, "hello"), "the answer lost its text")
}

@(test)
test_acp_prompt_end_to_end_v1 :: proc(t: ^testing.T) {
	acp_test_prompt_roundtrip(t, .V1, "test_acp_prompt_end_to_end_v1")
}

@(test)
test_acp_prompt_end_to_end_v2 :: proc(t: ^testing.T) {
	acp_test_prompt_roundtrip(t, .V2, "test_acp_prompt_end_to_end_v2")
}

acp_test_prompt_record :: proc(t: ^testing.T, name, prompt: string, compact: bool) {
	if !test_isolate_process(t, name) { return }
	state, previous, had_previous := acp_test_state_isolate(t)
	defer acp_test_state_restore(state, previous, had_previous)
	locks, _, locks_error := agent.session_lock_directory(context.allocator)
	if locks_error != .None { testing.fail_now(t, "the lock directory could not be resolved") }
	defer delete(locks, context.allocator)
	app: App
	directory, workspace := acp_test_app_begin(t, &app, locks)
	defer acp_test_app_end(&app, directory, workspace)

	// The fake server does not apply the default model selection a prompt would request.
	app.setup.catalog = acp_test_catalog(app.setup.alloc, "http://127.0.0.1:1")
	defer agent.catalog_destroy(&app.setup.catalog)
	if !testing.expect(t, selection_apply_direct(&app, "test-provider", "test-model", ""), "the test model could not be selected") { return }

	iface: ACP_Test_Interface
	acp_test_interface_init(t, &iface, .V2, &app.setup.catalog)
	defer acp_test_interface_destroy(&iface)
	server := &iface.server
	server.initialized = true
	session, reason := acp_session_create(server, "test-session")
	if !testing.expectf(t, session != nil, "the session could not be created: %s", reason) { return }
	store, store_error := journal.open(directory, locks, journal.run_id_create(), .Read_Write, context.allocator)
	if store_error != nil { testing.fail_now(t, "the client journal could not open") }
	session.store = store
	session.opened = true
	session.session_id = app.setup.session.session
	follow, follow_error := client_follow_open(store, session.session_id)
	if follow_error.kind != .None { testing.fail_now(t, "the session could not be followed") }
	session.follow = follow
	session.provider_id = strings.clone("test-provider", context.allocator) or_else ""
	session.model_id = strings.clone("test-model", context.allocator) or_else ""
	acp_test_fake_server(session)
	fake := session.server.state
	defer {
		acp_session_drop(server, session)
		server.sessions[0] = nil
		free(fake, context.allocator)
	}

	params, parse_error := json.parse_string(prompt, .JSON, true, context.allocator)
	if parse_error != nil { testing.fail_now(t, "the prompt parameters could not be parsed") }
	defer json.destroy_value(params, context.allocator)
	envelope := acp.Envelope {
		kind   = .Request,
		id     = i64(1),
		params = params,
	}
	acp_request_prompt(server, &envelope)
	if compact {
		deadline := time.tick_add(time.tick_now(), ACP_TEST_BOUND)
		for {
			seen := agent.owner_wake_seen()
			commands, command_error := journal.read_pending_commands(app.setup.store, session.session_id, context.allocator)
			if !testing.expect_value(t, command_error, nil) { return }
			if len(commands) > 0 {
				defer journal.records_destroy(commands, context.allocator)
				if !testing.expect_value(t, len(commands), 1) { return }
				command, ok := journal.payload_as(commands[0], journal.User_Command)
				if !testing.expect(t, ok, "the prompt did not append a user.command") { return }
				testing.expect_value(t, command.kind, journal.COMMAND_KIND_NAMES[.Compact])
				break
			}
			journal.records_destroy(commands, context.allocator)
			if time.tick_diff(time.tick_now(), deadline) <= 0 {
				testing.expect(t, false, "the compact command was not appended")
				return
			}
			agent.owner_wake_wait(seen, time.tick_add(time.tick_now(), 100 * time.Millisecond))
		}
		inputs, input_error := journal.read_inbox(app.setup.store, session.session_id, 0, context.allocator)
		if !testing.expect_value(t, input_error, nil) { return }
		defer journal.records_destroy(inputs, context.allocator)
		testing.expect_value(t, len(inputs), 0)
		return
	}
	if !acp_test_await_inbox(t, app.setup.store, session.session_id) { return }
	inputs, input_error := journal.read_inbox(app.setup.store, session.session_id, 0, context.allocator)
	if !testing.expect_value(t, input_error, nil) { return }
	defer journal.records_destroy(inputs, context.allocator)
	if !testing.expect_value(t, len(inputs), 1) { return }
	{
		input, ok := journal.payload_as(inputs[0], journal.User_Input)
		if !testing.expect(t, ok, "the prompt did not append a user.input") { return }
		testing.expect_value(t, string(inputs[0].body), "what is this")
		if !testing.expect_value(t, len(input.attachments), 1) { return }
		testing.expect_value(t, input.attachments[0].media_type, "image/png")
		digest, valid := journal.digest_from_hex(input.attachments[0].digest)
		if !testing.expect(t, valid, "the attachment digest is invalid") { return }
		bytes, found, artifact_error := journal.read_artifact(app.setup.store, digest, context.allocator)
		if !testing.expect_value(t, artifact_error, nil) { return }
		defer delete(bytes, context.allocator)
		testing.expect(t, found, "the attachment artifact is missing")
		testing.expect_value(t, string(bytes), "\x89PNG\r\n\x1a\n")
	}
}

@(test)
test_acp_prompt_records_an_image_block_as_an_attachment :: proc(t: ^testing.T) {
	acp_test_prompt_record(
		t,
		#procedure,
		`{"sessionId":"test-session","prompt":[{"type":"text","text":"what is this"},{"type":"image","mimeType":"image/jpeg","data":"iVBORw0KGgo="}]}`,
		false,
	)
}

@(test)
test_acp_v2_compact_command_starts_compaction_without_user_input :: proc(t: ^testing.T) {
	acp_test_prompt_record(t, #procedure, `{"sessionId":"test-session","prompt":[{"type":"text","text":"/compact"}]}`, true)
}

// ACP_Test_Command drives one config change through the worker while the test thread
// applies it the way the session server does.
ACP_Test_Command :: struct {
	session: ^ACP_Session,
	id:      acp.JSONRPC_Id,
	config:  ACP_Work_Set_Config_Option,
	done:    bool,
}

acp_test_command_thread :: proc(thread_handle: ^thread.Thread) {
	commander := cast(^ACP_Test_Command)thread_handle.data
	context.allocator = commander.session.conn.alloc
	acp_work_set_config_option(commander.session, commander.id, commander.config)
	delete(commander.config.config_id, commander.session.conn.alloc)
	delete(commander.config.config_value, commander.session.conn.alloc)
	sync.atomic_store(&commander.done, true)
}

// acp_test_apply_command runs one config change through the worker while the test
// thread applies the pending commands. It holds the worker's answer.
acp_test_apply_command :: proc(t: ^testing.T, app: ^App, session: ^ACP_Session, id: i64, config_id, config_value: string) {
	owned_id, id_error := strings.clone(config_id, context.allocator)
	if id_error != nil { testing.fail_now(t, "the config id could not be held") }
	owned_value, value_error := strings.clone(config_value, context.allocator)
	if value_error != nil { testing.fail_now(t, "the config value could not be held") }
	commander := ACP_Test_Command {
		session = session,
		id = id,
		config = ACP_Work_Set_Config_Option{config_id = owned_id, config_value = owned_value},
	}
	command_thread := thread.create(acp_test_command_thread, name = "nabla-acp-test-command")
	if command_thread == nil { testing.fail_now(t, "the command thread could not be created") }
	command_thread.data = &commander
	thread.start(command_thread)
	defer {
		thread.join(command_thread)
		thread.destroy(command_thread)
	}
	deadline := time.tick_add(time.tick_now(), ACP_TEST_BOUND)
	for !sync.atomic_load(&commander.done) {
		seen := agent.owner_wake_seen()
		pending, pending_error := journal.read_pending_commands(app.setup.store, session.session_id, context.temp_allocator)
		defer free_all(context.temp_allocator)
		if pending_error != nil { testing.fail_now(t, "the pending commands could not be read") }
		if len(pending) > 0 {
			serve_commands_apply(app, .Boundary)
		}
		if time.tick_diff(time.tick_now(), deadline) <= 0 { testing.fail_now(t, "the command was never answered") }
		agent.owner_wake_wait(seen, time.tick_add(time.tick_now(), 100 * time.Millisecond))
	}
}

// acp_test_command_roundtrip applies one model change and one effort change through the
// worker while the test thread applies the pending commands. It holds the applied
// serving identity and the answers the worker gives for them.
@(test)
test_acp_command_roundtrip :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	state, previous, had_previous := acp_test_state_isolate(t)
	defer acp_test_state_restore(state, previous, had_previous)

	locks, _, locks_error := agent.session_lock_directory(context.allocator)
	if locks_error != .None { testing.fail_now(t, "the lock directory could not be resolved") }
	defer delete(locks, context.allocator)
	app: App
	directory, workspace := acp_test_app_begin(t, &app, locks)
	defer acp_test_app_end(&app, directory, workspace)
	app.setup.catalog = acp_test_effort_catalog(app.setup.alloc)
	defer agent.catalog_destroy(&app.setup.catalog)
	if !testing.expect(t, selection_apply_direct(&app, "test-provider", "test-model", ""), "the catalog model could not be selected") {
		return
	}
	id := app.setup.session.session

	iface: ACP_Test_Interface
	acp_test_interface_init(t, &iface, .V2, &app.setup.catalog)
	defer acp_test_interface_destroy(&iface)
	server := &iface.server
	server.app.setup.journal_directory = strings.clone(directory, context.allocator)
	defer delete(server.app.setup.journal_directory, context.allocator)
	server.app.setup.lock_directory = strings.clone(locks, context.allocator)
	defer delete(server.app.setup.lock_directory, context.allocator)
	server.app.setup.run = journal.run_id_create()

	store, store_error := journal.open(directory, locks, journal.run_id_create(), .Read_Write, context.allocator)
	if store_error != nil { testing.fail_now(t, "the follower journal could not open") }
	session := ACP_Session {
		conn       = server,
		store      = store,
		session_id = id,
	}
	follow, follow_error := client_follow_open(session.store, session.session_id)
	if follow_error.kind != .None { testing.fail_now(t, "the session could not be followed") }
	session.follow = follow
	provider_id, provider_error := strings.clone("test-provider", context.allocator)
	model_id, model_error := strings.clone("test-model", context.allocator)
	if provider_error != nil || model_error != nil { testing.fail_now(t, "the serving identity could not be held") }
	session.provider_id = provider_id
	session.model_id = model_id
	acp_test_fake_server(&session)
	defer {
		acp_test_fake_server_destroy(&session)
		acp_session_release(&session)
	}

	acp_test_apply_command(t, &app, &session, 1, "model", "test-provider/test-model")
	acp_test_apply_command(t, &app, &session, 2, "effort", "high")
	frames := acp_test_buffer_text(&iface.buffer)
	testing.expect(t, strings.contains(frames, `"currentValue":"test-provider/test-model"`), "the applied model was not answered")
	testing.expect(t, strings.contains(frames, `"currentValue":"high"`), "the applied effort was not answered")
	testing.expect_value(t, session.provider_id, "test-provider")
	testing.expect_value(t, session.model_id, "test-model")
	testing.expect_value(t, session.effort, "high")
}
