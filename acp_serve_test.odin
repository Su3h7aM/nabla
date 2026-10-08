#+test
#+private file
package main

import "core:encoding/json"
import "core:fmt"
import "core:io"
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

// The ACP frontend is driven the way a client drives it: a scripted provider behind a
// socket, a client that writes one message and reads one answer at a time, and the run
// living on its own thread in between. That is what the real thing is, so the test covers
// the parts only a live conversation reaches: the reader answering while the worker runs a
// turn, updates streaming out of the turn, and a loaded conversation replayed.
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
test_acp_model_selection_does_not_mark_foreground_work_busy :: proc(t: ^testing.T) {
	session: ACP_Session
	session.model_request.active = true
	testing.expect(t, !acp_session_has_work(&session), "a pending model RPC is not foreground work")
	session.model_request = {}
	session.model_selection.active = true
	testing.expect(t, !acp_session_has_work(&session), "a model switch waiting for compaction is not foreground work")
	session.model_selection = {}
	acp_queue_add(&session)
	testing.expect(t, acp_session_has_work(&session), "queued foreground work remains busy")
	acp_queue_remove(&session)
}

@(test)
test_request_params_decode_errors_use_json_rpc_internal_for_allocation :: proc(t: ^testing.T) {
	testing.expect_value(t, acp_request_params_error_code(acp.Params_Error.Invalid), acp.ERROR_INVALID_PARAMS)
	testing.expect_value(t, acp_request_params_error_code(acp.Params_Error.Allocation), acp.ERROR_INTERNAL)
}

@(test)
test_acp_session_meta_reads_client_system_prompt_extensions :: proc(t: ^testing.T) {
	meta: acp.Session_Meta
	object: json.Object
	object["append"] = json.String("client standing context")
	meta.system_prompt = object
	testing.expect_value(t, acp_session_meta_system_prompt(&meta), "client standing context")
	delete(object)
	meta.system_prompt = json.String("plain context")
	testing.expect_value(t, acp_session_meta_system_prompt(&meta), "plain context")
}

// --- messages on the wire ----------------------------------------------------

// acp_test_end closes one message with the newline the framing requires.
acp_test_end :: proc(builder: ^strings.Builder) {
	strings.write_byte(builder, '\n')
}

acp_test_initialize_message :: proc(builder: ^strings.Builder, id: int) {
	fmt.sbprint(builder, `{"jsonrpc":"2.0","id":`, id)
	strings.write_string(builder, `,"method":"initialize","params":{"protocolVersion":1}}`)
	acp_test_end(builder)
}

acp_test_new_session_message :: proc(builder: ^strings.Builder, id: int, cwd: string) {
	fmt.sbprint(builder, `{"jsonrpc":"2.0","id":`, id)
	strings.write_string(builder, `,"method":"session/new","params":{"cwd":"`)
	strings.write_string(builder, cwd)
	strings.write_string(builder, `","mcpServers":[]}}`)
	acp_test_end(builder)
}

acp_test_load_session_message :: proc(builder: ^strings.Builder, id: int, session_id, cwd: string) {
	fmt.sbprint(builder, `{"jsonrpc":"2.0","id":`, id)
	strings.write_string(builder, `,"method":"session/load","params":{"sessionId":"`)
	strings.write_string(builder, session_id)
	strings.write_string(builder, `","cwd":"`)
	strings.write_string(builder, cwd)
	strings.write_string(builder, `","mcpServers":[]}}`)
	acp_test_end(builder)
}

acp_test_prompt_message :: proc(builder: ^strings.Builder, id: int, session_id, text: string) {
	fmt.sbprint(builder, `{"jsonrpc":"2.0","id":`, id)
	strings.write_string(builder, `,"method":"session/prompt","params":{"sessionId":"`)
	strings.write_string(builder, session_id)
	strings.write_string(builder, `","prompt":[{"type":"text","text":"`)
	strings.write_string(builder, text)
	strings.write_string(builder, `"}]}}`)
	acp_test_end(builder)
}

// acp_test_sse_body is one provider response body, from its event documents. It is built
// in the test's scratch memory, because it is wrapped into a reply as soon as it exists.
acp_test_sse_body :: proc(events: []string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for event in events {
		strings.write_string(&builder, "data: ")
		strings.write_string(&builder, event)
		strings.write_string(&builder, "\n\n")
	}
	strings.write_string(&builder, "data: [DONE]\n\n")
	return strings.to_string(builder)
}

// acp_test_stream_reply wraps a response body as the HTTP reply a provider sends.
acp_test_stream_reply :: proc(body: string, allocator := context.allocator) -> string {
	return fmt.aprintf("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: %d\r\n\r\n%s", len(body), body, allocator = allocator)
}

// --- a scripted provider -----------------------------------------------------

// ACP_Test_Provider answers one canned HTTP response per connection, in order. It stands
// in for a provider endpoint, so a turn runs for real: the harness sends requests, reads
// streams, and records results exactly as it would against a server.
ACP_Test_Provider :: struct {
	listener: net.TCP_Socket,
	port:     int,
	replies:  []string,
	served:   int,
	lock:     sync.Mutex,
	failed:   bool,
	thread:   ^thread.Thread,
}

acp_test_provider_start :: proc(t: ^testing.T, provider: ^ACP_Test_Provider, replies: []string) -> bool {
	provider.replies = replies
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	if listen_err != nil { return testing.expectf(t, false, "the provider socket could not be opened: %v", listen_err) }
	provider.listener = listener
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if endpoint_err != nil { return testing.expectf(t, false, "the provider address could not be read: %v", endpoint_err) }
	provider.port = endpoint.port
	provider.thread = thread.create(acp_test_provider_serve, name = "nabla-acp-test-provider")
	if provider.thread == nil { return testing.expectf(t, false, "the provider thread could not be started") }
	provider.thread.data = provider
	thread.start(provider.thread)
	return true
}

acp_test_provider_stop :: proc(t: ^testing.T, provider: ^ACP_Test_Provider) {
	// Closing a listener in another thread does not wake a blocked Linux accept.
	_ = net.shutdown(provider.listener, .Both)
	net.close(provider.listener)
	if provider.thread != nil {
		thread.join(provider.thread)
		thread.destroy(provider.thread)
		provider.thread = nil
	}
	sync.mutex_lock(&provider.lock)
	served, failed := provider.served, provider.failed
	sync.mutex_unlock(&provider.lock)
	testing.expectf(t, !failed, "the provider fixture failed")
	testing.expectf(t, served == len(provider.replies), "the provider served %d of %d replies", served, len(provider.replies))
}

acp_test_provider_serve :: proc(thread_handle: ^thread.Thread) {
	provider := cast(^ACP_Test_Provider)thread_handle.data
	for index in 0 ..< len(provider.replies) {
		client, _, accept_err := net.accept_tcp(provider.listener)
		if accept_err != nil { return }
		acp_test_provider_answer(provider, client, provider.replies[index])
	}
}

// acp_test_provider_answer reads one whole request before answering it, so the harness is
// never still writing when the connection closes.
acp_test_provider_answer :: proc(provider: ^ACP_Test_Provider, client: net.TCP_Socket, reply: string) {
	defer net.close(client)
	_ = net.set_option(client, .Receive_Timeout, ACP_TEST_BOUND)

	request := make([dynamic]u8, 0, 4096, context.temp_allocator)
	defer delete(request)
	header_end := -1
	for header_end < 0 {
		buffer: [4096]u8
		read, read_err := net.recv_tcp(client, buffer[:])
		if read_err != nil || read <= 0 {
			sync.mutex_lock(&provider.lock)
			provider.failed = true
			sync.mutex_unlock(&provider.lock)
			return
		}
		append(&request, ..buffer[:read])
		header_end = strings.index(string(request[:]), "\r\n\r\n")
	}
	body_length := 0
	headers := string(request[:header_end])
	remaining := headers
	for line in strings.split_lines_iterator(&remaining) {
		if !strings.has_prefix(strings.to_lower(line), "content-length:") { continue }
		if parsed, ok := strconv.parse_int(strings.trim_space(line[len("content-length:"):])); ok { body_length = parsed }
	}
	for len(request) < header_end + 4 + body_length {
		buffer: [4096]u8
		read, read_err := net.recv_tcp(client, buffer[:])
		if read_err != nil || read <= 0 { break }
		append(&request, ..buffer[:read])
	}

	sync.mutex_lock(&provider.lock)
	provider.served += 1
	sync.mutex_unlock(&provider.lock)
	_, _ = net.send_tcp(client, transmute([]u8)reply)
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

ACP_Test_Stalled_Output :: struct {
	mutex:   sync.Mutex,
	cond:    sync.Cond,
	entered: bool,
	release: bool,
	output:  [dynamic]u8,
}

acp_test_stalled_output :: proc(state: ^ACP_Test_Stalled_Output) -> io.Writer {
	return io.Writer {
		data = state,
		procedure = proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
			state := cast(^ACP_Test_Stalled_Output)data
			switch mode {
			case .Write:
				sync.mutex_lock(&state.mutex)
				state.entered = true
				sync.cond_broadcast(&state.cond)
				for !state.release { sync.cond_wait(&state.cond, &state.mutex) }
				append(&state.output, ..p)
				sync.mutex_unlock(&state.mutex)
				return i64(len(p)), nil
			case .Query:
				return i64(io.Stream_Mode_Set{.Write}), nil
			case .Close, .Flush, .Destroy:
				return 0, nil
			case .Read, .Seek, .Read_At, .Write_At, .Size:
				return 0, .Unsupported
			}
			return 0, .Unsupported
		},
	}
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
		acp.writer_write_response(&server.writer, i64(1), acp.Empty_Result{}),
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
	first.pending_work = 1
	second.conn = &server
	second.id = "session-second"
	second.pending_work = 1
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
	acp_request_cancel(&server, &envelope)
	testing.expect(t, !agent.turn_control_stop_requested(&first.app.run.control), "cancellation stopped the wrong session")
	testing.expect(t, agent.turn_control_stop_requested(&second.app.run.control), "cancellation did not stop the named session")
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

acp_test_stalled_output_wait :: proc(t: ^testing.T, state: ^ACP_Test_Stalled_Output) {
	sync.mutex_lock(&state.mutex)
	deadline := time.tick_add(time.tick_now(), time.Second)
	for !state.entered {
		remaining := time.tick_diff(time.tick_now(), deadline)
		if remaining <= 0 { break }
		_ = sync.cond_wait_with_timeout(&state.cond, &state.mutex, remaining)
	}
	entered := state.entered
	sync.mutex_unlock(&state.mutex)
	testing.expect(t, entered, "the writer did not enter its blocked output call")
}

ACP_Test_Cancel_Run :: struct {
	server:   ^ACP_Server,
	envelope: acp.Envelope,
	mutex:    sync.Mutex,
	cond:     sync.Cond,
	done:     bool,
}

acp_test_cancel_request :: proc(thread_handle: ^thread.Thread) {
	run := cast(^ACP_Test_Cancel_Run)thread_handle.data
	acp_request_cancel(run.server, &run.envelope)
	sync.mutex_lock(&run.mutex)
	run.done = true
	sync.cond_broadcast(&run.cond)
	sync.mutex_unlock(&run.mutex)
}

@(test)
test_acp_cancel_request_returns_while_stdout_is_stalled :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	state: ACP_Test_Stalled_Output
	output, output_error := make([dynamic]u8, 0, 0, context.allocator)
	if output_error != nil { testing.fail_now(t, "the test output buffer could not be created") }
	state.output = output
	defer delete(state.output)
	server: ACP_Server
	server.alloc = context.allocator
	session: ACP_Session
	session.conn = &server
	session.id = "session-stalled"
	session.pending_work = 1
	server.sessions[0] = &session
	writer, writer_error := acp.writer_init(acp_test_stalled_output(&state), server.alloc)
	if writer_error != nil { testing.fail_now(t, "the writer could not be created") }
	server.writer = writer
	defer acp_test_writer_cleanup(&server.writer)
	defer {
		sync.mutex_lock(&state.mutex)
		state.release = true
		sync.cond_broadcast(&state.cond)
		sync.mutex_unlock(&state.mutex)
	}

	testing.expect(
		t,
		acp.writer_write_notification(
			&server.writer,
			"session/update",
			acp.Session_Notification(acp.Session_Info_Update) {
				session_id = "session-stalled",
				update = acp.Session_Info_Update{session_update = acp.UPDATE_SESSION_INFO, title = "stall"},
			},
		),
	)
	acp_test_stalled_output_wait(t, &state)

	params, parse_error := json.parse_string(`{"sessionId":"session-stalled"}`, .JSON, true, context.allocator)
	if parse_error != nil { testing.fail_now(t, "the cancellation parameters could not be parsed") }
	defer json.destroy_value(params, context.allocator)
	run := ACP_Test_Cancel_Run {
		server = &server,
		envelope = acp.Envelope{kind = .Request, id = i64(1), params = params},
	}
	cancel_thread := thread.create(acp_test_cancel_request, name = "nabla-test-acp-cancel")
	if cancel_thread == nil { testing.fail_now(t, "the cancellation thread could not be created") }
	cancel_thread.data = &run
	thread.start(cancel_thread)
	sync.mutex_lock(&run.mutex)
	deadline := time.tick_add(time.tick_now(), 200 * time.Millisecond)
	for !run.done {
		remaining := time.tick_diff(time.tick_now(), deadline)
		if remaining <= 0 { break }
		_ = sync.cond_wait_with_timeout(&run.cond, &run.mutex, remaining)
	}
	completed_while_stalled := run.done
	sync.mutex_unlock(&run.mutex)

	sync.mutex_lock(&state.mutex)
	state.release = true
	sync.cond_broadcast(&state.cond)
	sync.mutex_unlock(&state.mutex)
	thread.join(cancel_thread)
	thread.destroy(cancel_thread)
	testing.expect(t, completed_while_stalled, "the cancellation handler waited for stdout")
	testing.expect(t, agent.turn_control_stop_requested(&session.app.run.control), "the cancellation did not stop the turn")
	testing.expect(t, acp.writer_destroy(&server.writer, time.Second), "the released writer should retire")
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
acp_test_client_receive :: proc(client: ^ACP_Test_Client, allocator := context.temp_allocator) -> string {
	sync.mutex_lock(&client.mu)
	defer sync.mutex_unlock(&client.mu)
	for {
		pending := string(client.output[client.read_at:])
		if newline := strings.index_byte(pending, '\n'); newline >= 0 {
			frame := strings.clone(pending[:newline], allocator)
			client.read_at += newline + 1
			return frame
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

// acp_test_client_carries holds one frame to every fact it must state. The frame is read
// once and checked whole, because one update carries the call's id, kind, status, and
// arguments together.
acp_test_client_carries :: proc(t: ^testing.T, frame: string, facts: []string, what: string) -> bool {
	for fact in facts {
		if !testing.expectf(t, strings.contains(frame, fact), "%s: %s", what, frame) { return false }
	}
	return true
}

// acp_test_client_session_id reads the id a session/new answer names.
acp_test_client_session_id_from_frame :: proc(t: ^testing.T, frame: string, allocator := context.allocator) -> string {
	answer: struct {
		result: struct {
			session_id: string `json:"sessionId"`,
		} `json:"result"`,
	}
	if unmarshal_err := json.unmarshal(transmute([]u8)frame, &answer, allocator = allocator); unmarshal_err != nil {
		testing.expectf(t, false, "the session/new answer could not be read: %s", frame)
		return ""
	}
	_, valid := journal.session_id_parse(answer.result.session_id)
	if !testing.expectf(t, valid && len(answer.result.session_id) == journal.SESSION_ID_HEX_LENGTH, "session/new returned an invalid journal id: %s", frame) {
		delete(answer.result.session_id, allocator)
		return ""
	}
	return answer.result.session_id
}

acp_test_client_session_id :: proc(t: ^testing.T, client: ^ACP_Test_Client, allocator := context.allocator) -> string {
	frame := acp_test_client_receive(client)
	if frame == "" {
		testing.expectf(t, false, "session/new: the run did not answer")
		return ""
	}
	return acp_test_client_session_id_from_frame(t, frame, allocator = allocator)
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
test_acp_serves_a_turn_and_replays_a_loaded_session :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	acp_test_session_protocol(t, .Independent)
}

@(test)
test_acp_refused_claim_keeps_an_existing_session_usable :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	acp_test_session_protocol(t, .Refused_Claim)
}

@(test)
test_acp_evicted_persisted_session_replays_and_accepts_another_prompt :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	acp_test_session_protocol(t, .Persisted_Eviction)
}

ACP_Test_Session_Scenario :: enum {
	Independent,
	Refused_Claim,
	Persisted_Eviction,
}

acp_test_session_protocol :: proc(t: ^testing.T, scenario: ACP_Test_Session_Scenario) {
	workspace, workspace_err := os.make_directory_temp("", "nabla-acp-workspace-*", context.allocator)
	if workspace_err != nil {
		testing.expectf(t, false, "could not create a temporary workspace: %v", workspace_err)
		return
	}
	defer {
		_ = os.remove_all(workspace)
		delete(workspace, context.allocator)
	}
	state, state_err := os.make_directory_temp("", "nabla-acp-state-*", context.allocator)
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
	// The catalog cache is pointed at the state directory too: a run must never read or
	// write the user's own cache.
	previous_cache, had_cache := acp_test_env(t, "XDG_CACHE_HOME", state)
	defer acp_test_env_restore("XDG_CACHE_HOME", previous_cache, had_cache)

	note := fmt.aprintf("%s/note.txt", workspace, allocator = context.allocator)
	defer delete(note, context.allocator)
	if write_err := os.write_entire_file(note, "the file the tool reads\n"); write_err != nil {
		testing.expectf(t, false, "the note could not be written: %v", write_err)
		return
	}

	// The provider answers the first request with a tool call for the note, and the second
	// with the answer the turn ends on. The call's arguments are a JSON document inside a
	// JSON string, so the encoder writes them.
	arguments, arguments_err := json.marshal(struct {
			path: string `json:"path"`,
		}{path = note}, allocator = context.temp_allocator)
	if arguments_err != nil {
		testing.expectf(t, false, "the tool arguments could not be built: %v", arguments_err)
		return
	}
	quoted_arguments, quoted_err := json.marshal(string(arguments), allocator = context.temp_allocator)
	if quoted_err != nil {
		testing.expectf(t, false, "the tool arguments could not be quoted: %v", quoted_err)
		return
	}
	call_event := strings.builder_make(context.temp_allocator)
	strings.write_string(&call_event, `{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read","arguments":`)
	strings.write_string(&call_event, string(quoted_arguments))
	strings.write_string(&call_event, `}}]},"finish_reason":null}]}`)
	replies := []string {
		acp_test_stream_reply(acp_test_sse_body({strings.to_string(call_event), `{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`})),
		acp_test_stream_reply(
			acp_test_sse_body(
				{`{"choices":[{"delta":{"content":"the note says so"},"finish_reason":null}]}`, `{"choices":[{"delta":{},"finish_reason":"stop"}]}`},
			),
		),
		acp_test_stream_reply(
			acp_test_sse_body(
				{
					`{"choices":[{"delta":{"content":"the second session answered"},"finish_reason":null}]}`,
					`{"choices":[{"delta":{},"finish_reason":"stop"}]}`,
				},
			),
		),
	}
	defer for reply in replies { delete(reply, context.allocator) }

	provider: ACP_Test_Provider
	if !acp_test_provider_start(t, &provider, replies) { return }
	defer acp_test_provider_stop(t, &provider)

	sources := make([]agent.Catalog_Provider_Source, 1, context.allocator)
	defer delete(sources, context.allocator)
	models := make([]agent.Catalog_Model_Source, 1, context.allocator)
	defer delete(models, context.allocator)
	models[0] = {
		id                = "testmodel",
		context_window    = 100000,
		max_output_tokens = 4096,
		tools             = true,
	}
	sources[0] = {
		id       = "testprovider",
		base_url = fmt.aprintf("http://127.0.0.1:%d/v1", provider.port, allocator = context.allocator),
		api      = "openai_chat_completions",
		api_key  = "test-key",
		models   = models,
	}
	defer delete(sources[0].base_url.?, context.allocator)

	client: ACP_Test_Client
	defer acp_test_client_destroy(&client)
	run := ACP_Test_Run {
		client  = &client,
		sources = sources,
	}
	run_thread := thread.create(acp_test_run_thread, name = "nabla-acp-test-run")
	if run_thread == nil {
		testing.expectf(t, false, "the run thread could not be started")
		return
	}
	run_thread.data = &run
	thread.start(run_thread)
	defer {
		// Hanging up ends the run, and joining it releases everything the run owns. It runs
		// first among the cleanups, so the client's own buffers outlive the run that reads
		// them, and the teardown is checked on a failing path too.
		acp_test_client_hang_up(&client)
		thread.join(run_thread)
		testing.expect(t, run.served, "the run did not end cleanly")
		thread.destroy(run_thread)
		free_all(context.temp_allocator)
	}

	// initialize: the answer is the agent's own protocol version, and one message carries
	// everything the client learns from it.
	handshake := strings.builder_make(context.temp_allocator)
	acp_test_initialize_message(&handshake, 1)
	acp_test_client_send(&client, strings.to_string(handshake))
	hello := acp_test_client_expect(t, &client, `"protocolVersion":1`, "initialize was not answered")
	if hello == "" { return }
	testing.expectf(t, strings.contains(hello, `"loadSession":true`), "initialize did not announce loadSession: %s", hello)
	testing.expectf(t, strings.contains(hello, `"sessionCapabilities":{"list":{}}`), "initialize did not announce session/list: %s", hello)
	testing.expectf(t, strings.contains(hello, `"embeddedContext":true`), "initialize did not announce embedded context: %s", hello)
	listing := strings.builder_make(context.temp_allocator)
	strings.write_string(&listing, `{"jsonrpc":"2.0","id":6,"method":"session/list","params":{}}`)
	strings.write_byte(&listing, '\n')
	acp_test_client_send(&client, strings.to_string(listing))
	if acp_test_client_expect(t, &client, `"sessions":[]`, "v1 session/list was not answered") == "" { return }

	// session/new: the client gets the id it will name from then on, with the model
	// selector it may switch.
	opening := strings.builder_make(context.temp_allocator)
	acp_test_new_session_message(&opening, 2, workspace)
	acp_test_client_send(&client, strings.to_string(opening))
	opened := acp_test_client_expect(t, &client, `"sessionId"`, "session/new was not answered")
	if opened == "" { return }
	if !acp_test_client_carries(t, opened, {`"configOptions"`, `"value":"testmodel"`, `"currentValue":"testmodel"`}, "the session answer") { return }
	session_id := acp_test_client_session_id_from_frame(t, opened)
	if session_id == "" { return }
	defer delete(session_id, context.allocator)

	// session/prompt: every request the turn makes reports what it used, so the frame order
	// is the context meter, the call announced, the call settled with the file's text, the
	// model's answer, and the answer to the prompt.
	prompting := strings.builder_make(context.temp_allocator)
	acp_test_prompt_message(&prompting, 3, session_id, "read the note")
	acp_test_client_send(&client, strings.to_string(prompting))
	if acp_test_client_expect(t, &client, `"sessionUpdate":"usage_update"`, "the request did not report its usage") == "" { return }
	announced := acp_test_client_expect(t, &client, `"sessionUpdate":"tool_call"`, "the call was not announced")
	if announced == "" { return }
	if !acp_test_client_carries(t, announced, {`"toolCallId":"call_1"`, `"kind":"read"`, `"status":"pending"`, note}, "the announcement") { return }
	settled := acp_test_client_expect(t, &client, `"sessionUpdate":"tool_call_update"`, "the call was not settled")
	if settled == "" { return }
	if !acp_test_client_carries(t, settled, {`"toolCallId":"call_1"`, `"status":"completed"`, "the file the tool reads"}, "the settle") { return }
	if acp_test_client_expect(t, &client, "the note says so", "the model's answer did not reach the client") == "" { return }
	if acp_test_client_expect(t, &client, `"sessionUpdate":"usage_update"`, "the second request did not report its usage") == "" { return }
	if acp_test_client_expect(t, &client, `"stopReason":"end_turn"`, "the turn was not answered") == "" { return }

	// session/load: the conversation the turn left behind replays before the load is
	// answered. A session is stored once it has a conversation, so this is the first point
	// at which the id names something a client could come back to.
	reloading := strings.builder_make(context.temp_allocator)
	acp_test_load_session_message(&reloading, 4, session_id, workspace)
	acp_test_client_send(&client, strings.to_string(reloading))
	replayed_user := acp_test_client_expect(t, &client, `"sessionUpdate":"user_message_chunk"`, "the conversation did not replay the user's message")
	if replayed_user == "" { return }
	if !acp_test_client_carries(t, replayed_user, {"read the note"}, "the replayed message") { return }
	replayed_call := acp_test_client_expect(t, &client, `"sessionUpdate":"tool_call"`, "the conversation did not replay the tool call")
	if replayed_call == "" { return }
	if !acp_test_client_carries(t, replayed_call, {`"toolCallId":"call_1"`, `"status":"completed"`, "the file the tool reads"}, "the replayed call") { return }
	if acp_test_client_expect(t, &client, "the note says so", "the conversation did not replay the answer") == "" { return }
	if acp_test_client_expect(t, &client, `"id":4,"result":{}`, "session/load was not answered") == "" { return }

	// session/load of a name the store does not hold is refused rather than answered with
	// a fresh session the client did not ask for.
	missing := strings.builder_make(context.temp_allocator)
	acp_test_load_session_message(&missing, 5, "00000000000000000000000000000000", workspace)
	acp_test_client_send(&client, strings.to_string(missing))
	if acp_test_client_expect(t, &client, `"code":-32602`, "loading an unknown session was not refused") == "" { return }

	if scenario == .Refused_Claim {
		directory, directory_error := agent.xdg_directory(.State, context.allocator)
		if !testing.expect_value(t, directory_error, agent.XDG_Error.None) { return }
		defer delete(directory, context.allocator)
		locks, _, locks_error := agent.session_lock_directory(context.allocator)
		if !testing.expect_value(t, locks_error, agent.XDG_Error.None) { return }
		defer delete(locks, context.allocator)
		other: journal.Journal
		if !testing.expect_value(t, journal.open(&other, directory, locks, journal.run_id_create(), .Read_Write, context.allocator), nil) { return }
		defer _ = journal.close(&other)
		target, create_error := journal.create_session(&other, {workspace = workspace})
		if !testing.expect_value(t, create_error, nil) { return }
		_, commit_error := journal.commit(&other)
		if !testing.expect_value(t, commit_error, nil) { return }
		refused := strings.builder_make(context.temp_allocator)
		target_text: [32]u8
		acp_test_load_session_message(&refused, 20, journal.session_id_to_hex(target, target_text[:]), workspace)
		acp_test_client_send(&client, strings.to_string(refused))
		refusal := acp_test_client_expect(t, &client, `"id":20,"error":`, "loading a claimed session was not refused")
		if refusal == "" { return }
		if !testing.expect(t, strings.contains(refusal, `"code":-32602`), "the claim refusal did not use invalid parameters") { return }
	}
	if scenario == .Persisted_Eviction {
		for i in 0 ..< ACP_MAX_SESSIONS {
			opening_idle := strings.builder_make(context.temp_allocator)
			acp_test_new_session_message(&opening_idle, 10 + i, workspace)
			acp_test_client_send(&client, strings.to_string(opening_idle))
			if acp_test_client_expect(t, &client, fmt.tprintf(`"id":%d,"result":`, 10 + i), "an idle session did not open") == "" { return }
		}
		unknown := strings.builder_make(context.temp_allocator)
		acp_test_prompt_message(&unknown, 20, session_id, "the evicted id must be unknown")
		acp_test_client_send(&client, strings.to_string(unknown))
		if acp_test_client_expect(t, &client, `"id":20,"error":`, "the evicted session id was still routed") == "" { return }
		reload_evicted := strings.builder_make(context.temp_allocator)
		acp_test_load_session_message(&reload_evicted, 21, session_id, workspace)
		acp_test_client_send(&client, strings.to_string(reload_evicted))
		replayed := acp_test_client_expect(t, &client, `"sessionUpdate":"user_message_chunk"`, "the evicted session did not replay its history")
		if !acp_test_client_carries(t, replayed, {session_id, "read the note"}, "the evicted session replay") { return }
		if acp_test_client_expect(t, &client, `"sessionUpdate":"tool_call"`, "the evicted session did not replay its completed call") == "" { return }
		if acp_test_client_expect(t, &client, "the note says so", "the evicted session did not replay its answer") == "" { return }
		if acp_test_client_expect(t, &client, `"id":21,"result":{}`, "the evicted session did not finish loading") == "" { return }
	}
	if scenario != .Independent {
		still_usable := strings.builder_make(context.temp_allocator)
		acp_test_prompt_message(&still_usable, 22, session_id, "answer after the session lifecycle change")
		acp_test_client_send(&client, strings.to_string(still_usable))
		answer := acp_test_client_expect(t, &client, "the second session answered", "the earlier session could not answer another prompt")
		if !acp_test_client_carries(t, answer, {session_id}, "the surviving session answer") { return }
		if acp_test_client_expect(t, &client, `"sessionUpdate":"usage_update"`, "the surviving session did not report usage") == "" { return }
		if acp_test_client_expect(t, &client, `"id":22,"result":`, "the surviving session prompt was not answered") == "" { return }
		return
	}

	second_opening := strings.builder_make(context.temp_allocator)
	acp_test_new_session_message(&second_opening, 7, workspace)
	acp_test_client_send(&client, strings.to_string(second_opening))
	second_opened := acp_test_client_expect(t, &client, `"sessionId"`, "the second session was not opened")
	if second_opened == "" { return }
	second_session_id := acp_test_client_session_id_from_frame(t, second_opened)
	if second_session_id == "" { return }
	defer delete(second_session_id, context.allocator)
	if !testing.expect(t, second_session_id != session_id, "independent opens returned the same session id") { return }

	second_prompt := strings.builder_make(context.temp_allocator)
	acp_test_prompt_message(&second_prompt, 8, second_session_id, "answer from the second session")
	acp_test_client_send(&client, strings.to_string(second_prompt))
	second_answer := acp_test_client_expect(t, &client, "the second session answered", "the second session prompt was routed incorrectly")
	if second_answer == "" { return }
	if !strings.contains(second_answer, second_session_id) {
		testing.expectf(t, false, "the second session answer named the wrong session: %s", second_answer)
		return
	}
	if acp_test_client_expect(t, &client, `"sessionUpdate":"usage_update"`, "the second session did not report usage") == "" { return }
	second_result := acp_test_client_expect(t, &client, `"stopReason":"end_turn"`, "the second session prompt was not answered")
	if second_result == "" { return }
	testing.expectf(t, strings.contains(second_result, `"id":8`), "the second session prompt response used the wrong request id: %s", second_result)
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
	testing.expect(t, strings.contains(hello, `"capabilities":{"session":{"prompt":{"embeddedContext":{}},"mcp":{"stdio":{}}}}`))
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
	closed_frame := acp_test_client_expect(t, &client, `"sessions":[]`, "v2 session/list after close was not answered")
	if closed_frame == "" { return }
	testing.expectf(t, !strings.contains(closed_frame, session_id), "v2 session/list retained an unprompted session: %s", closed_frame)
}

@(test)
test_acp_v2_prompt_reports_insertion_state_and_completion :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	workspace, workspace_err := os.make_directory_temp("", "nabla-acp-v2-prompt-workspace-*", context.allocator)
	if workspace_err != nil {
		testing.expectf(t, false, "could not create a temporary workspace: %v", workspace_err)
		return
	}
	defer {
		_ = os.remove_all(workspace)
		delete(workspace, context.allocator)
	}
	state, state_err := os.make_directory_temp("", "nabla-acp-v2-prompt-state-*", context.allocator)
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

	replies := []string {
		acp_test_stream_reply(
			acp_test_sse_body({`{"choices":[{"delta":{"content":"v2 answer"},"finish_reason":null}]}`, `{"choices":[{"delta":{},"finish_reason":"stop"}]}`}),
		),
	}
	defer for reply in replies { delete(reply, context.allocator) }
	provider: ACP_Test_Provider
	if !acp_test_provider_start(t, &provider, replies) { return }
	defer acp_test_provider_stop(t, &provider)

	sources := make([]agent.Catalog_Provider_Source, 1, context.allocator)
	defer delete(sources, context.allocator)
	models := make([]agent.Catalog_Model_Source, 1, context.allocator)
	defer delete(models, context.allocator)
	models[0] = {
		id                = "v2model",
		context_window    = 100000,
		max_output_tokens = 4096,
		tools             = true,
	}
	sources[0] = {
		id       = "v2provider",
		base_url = fmt.aprintf("http://127.0.0.1:%d/v1", provider.port, allocator = context.allocator),
		api      = "openai_chat_completions",
		api_key  = "test-key",
		models   = models,
	}
	defer delete(sources[0].base_url.?, context.allocator)

	client: ACP_Test_Client
	defer acp_test_client_destroy(&client)
	run := ACP_Test_Run {
		client  = &client,
		sources = sources,
	}
	run_thread := thread.create(acp_test_run_thread, name = "nabla-acp-v2-prompt-run")
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
	if acp_test_client_expect(t, &client, `"protocolVersion":2`, "v2 initialize was not answered") == "" { return }

	opening := strings.builder_make(context.temp_allocator)
	strings.write_string(&opening, `{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"`)
	strings.write_string(&opening, workspace)
	strings.write_string(&opening, `","mcpServers":[]}}`)
	strings.write_byte(&opening, '\n')
	acp_test_client_send(&client, strings.to_string(opening))
	opening_frame := acp_test_client_expect(t, &client, `"sessionId"`, "v2 session/new was not answered")
	if opening_frame == "" { return }
	if !strings.contains(opening_frame, `"configId":"model"`) || !strings.contains(opening_frame, `"value":"v2model"`) {
		testing.expectf(t, false, "v2 session/new did not expose the model catalog: %s", opening_frame)
		return
	}
	session_id := acp_test_client_session_id_from_frame(t, opening_frame)
	if session_id == "" { return }
	defer delete(session_id, context.allocator)

	prompting := strings.builder_make(context.temp_allocator)
	strings.write_string(&prompting, `{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"`)
	strings.write_string(&prompting, session_id)
	strings.write_string(&prompting, `","prompt":[{"type":"text","text":"say hello"}]}}`)
	strings.write_byte(&prompting, '\n')
	acp_test_client_send(&client, strings.to_string(prompting))
	if acp_test_client_expect(t, &client, `"sessionUpdate":"user_message"`, "v2 did not acknowledge the user message") == "" { return }
	if acp_test_client_expect(t, &client, `"result":{"messageId":"msg-user-1-1"}`, "v2 did not return the inserted message id") == "" { return }
	if acp_test_client_expect(t, &client, `"sessionUpdate":"state_update","state":"running"`, "v2 did not report running state") == "" { return }
	agent_frame := acp_test_client_expect(t, &client, `"sessionUpdate":"agent_message_chunk"`, "v2 did not stream the agent message")
	if agent_frame == "" { return }
	if !strings.contains(agent_frame, "v2 answer") {
		testing.expectf(t, false, "v2 did not deliver the model text: %s", agent_frame)
		return
	}
	if acp_test_client_expect(t, &client, `"sessionUpdate":"usage_update"`, "v2 did not report usage") == "" { return }
	if acp_test_client_expect(t, &client, `"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn"`, "v2 did not report completion") ==
	   "" { return }

	resuming := strings.builder_make(context.temp_allocator)
	strings.write_string(&resuming, `{"jsonrpc":"2.0","id":4,"method":"session/resume","params":{"sessionId":"`)
	strings.write_string(&resuming, session_id)
	strings.write_string(&resuming, `","cwd":"`)
	strings.write_string(&resuming, workspace)
	strings.write_string(&resuming, `","mcpServers":[],"replayFrom":{"type":"start"}}}`)
	strings.write_byte(&resuming, '\n')
	acp_test_client_send(&client, strings.to_string(resuming))
	replayed_user := acp_test_client_expect(t, &client, `"sessionUpdate":"user_message"`, "v2 replay did not include the user message")
	if replayed_user == "" || !strings.contains(replayed_user, `"messageId":"msg-user-1-1"`) {
		testing.expectf(t, false, "v2 replay changed the user message id: %s", replayed_user)
		return
	}
	replayed_assistant := acp_test_client_expect(t, &client, `"sessionUpdate":"agent_message"`, "v2 replay did not include the assistant message")
	if replayed_assistant == "" || !strings.contains(replayed_assistant, `"messageId":"msg-assistant-1-1"`) {
		testing.expectf(t, false, "v2 replay changed the assistant message id: %s", replayed_assistant)
		return
	}
	if acp_test_client_expect(t, &client, `"id":4,"result"`, "v2 resume did not answer after replay") == "" { return }

	plain_resume := strings.builder_make(context.temp_allocator)
	strings.write_string(&plain_resume, `{"jsonrpc":"2.0","id":5,"method":"session/resume","params":{"sessionId":"`)
	strings.write_string(&plain_resume, session_id)
	strings.write_string(&plain_resume, `","cwd":"`)
	strings.write_string(&plain_resume, workspace)
	strings.write_string(&plain_resume, `","mcpServers":[]}}`)
	strings.write_byte(&plain_resume, '\n')
	acp_test_client_send(&client, strings.to_string(plain_resume))
	if acp_test_client_expect(t, &client, `"id":5,"result"`, "v2 plain resume did not answer") == "" { return }
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
test_acp_buzz_v2_request_uses_the_v1_wire_profile :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	state, state_err := os.make_directory_temp("", "nabla-acp-buzz-state-*", context.allocator)
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
	run_thread := thread.create(acp_test_run_thread, name = "nabla-acp-buzz-run")
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

	message :=
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":2,"clientCapabilities":{},"clientInfo":{"name":"buzz-acp","version":"test"}}}` +
		"\n"
	acp_test_client_send(&client, message)
	frame := acp_test_client_expect(t, &client, `"protocolVersion":1`, "Buzz did not receive the v1 profile")
	if frame == "" { return }
	testing.expect(t, strings.contains(frame, `"agentCapabilities"`))
	testing.expect(t, strings.contains(frame, `"agentInfo"`))
	testing.expect(t, !strings.contains(frame, `"capabilities":{"session"`))
}

@(test)
test_acp_buzz_set_model_switches_the_session_model :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	workspace, workspace_err := os.make_directory_temp("", "nabla-acp-model-workspace-*", context.allocator)
	if workspace_err != nil {
		testing.expectf(t, false, "could not create a temporary workspace: %v", workspace_err)
		return
	}
	defer {
		_ = os.remove_all(workspace)
		delete(workspace, context.allocator)
	}
	state, state_err := os.make_directory_temp("", "nabla-acp-model-state-*", context.allocator)
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

	sources := make([]agent.Catalog_Provider_Source, 1, context.allocator)
	defer delete(sources, context.allocator)
	models := make([]agent.Catalog_Model_Source, 2, context.allocator)
	defer delete(models, context.allocator)
	models[0] = {
		id             = "buzzmodel",
		context_window = 100000,
		tools          = true,
	}
	models[1] = {
		id             = "buzzmodel-next",
		context_window = 100000,
		tools          = true,
	}
	sources[0] = {
		id       = "buzzprovider",
		base_url = "http://127.0.0.1:1/v1",
		api      = "openai_chat_completions",
		api_key  = "test-key",
		models   = models,
	}

	client: ACP_Test_Client
	defer acp_test_client_destroy(&client)
	run := ACP_Test_Run {
		client  = &client,
		sources = sources,
	}
	run_thread := thread.create(acp_test_run_thread, name = "nabla-acp-model-run")
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
	acp_test_initialize_message(&handshake, 1)
	acp_test_client_send(&client, strings.to_string(handshake))
	if acp_test_client_expect(t, &client, `"protocolVersion":1`, "initialize was not answered") == "" { return }

	opening := strings.builder_make(context.temp_allocator)
	acp_test_new_session_message(&opening, 2, workspace)
	acp_test_client_send(&client, strings.to_string(opening))
	opened := acp_test_client_expect(t, &client, `"sessionId"`, "session/new was not answered")
	if opened == "" { return }
	if !acp_test_client_carries(t, opened, {`"currentModelId":"buzzmodel"`, `"modelId":"buzzmodel"`}, "the session answer") { return }
	session_id := acp_test_client_session_id_from_frame(t, opened)
	if session_id == "" { return }
	defer delete(session_id, context.allocator)

	switching := strings.builder_make(context.temp_allocator)
	fmt.sbprint(&switching, `{"jsonrpc":"2.0","id":3,"method":"session/set_model","params":{"sessionId":"`)
	strings.write_string(&switching, session_id)
	strings.write_string(&switching, `","modelId":"buzzmodel-next"}}`)
	acp_test_end(&switching)
	acp_test_client_send(&client, strings.to_string(switching))
	switched := acp_test_client_expect(t, &client, `"modelId":"buzzmodel-next"`, "session/set_model was not answered")
	if switched == "" { return }

	configuring := strings.builder_make(context.temp_allocator)
	fmt.sbprint(&configuring, `{"jsonrpc":"2.0","id":4,"method":"session/set_config_option","params":{"sessionId":"`)
	strings.write_string(&configuring, session_id)
	strings.write_string(&configuring, `","configId":"model","value":"buzzmodel"}}`)
	acp_test_end(&configuring)
	acp_test_client_send(&client, strings.to_string(configuring))
	configured := acp_test_client_expect(t, &client, `"currentValue":"buzzmodel"`, "the model config option was not applied")
	if configured == "" { return }

	unknown := strings.builder_make(context.temp_allocator)
	fmt.sbprint(&unknown, `{"jsonrpc":"2.0","id":5,"method":"session/set_model","params":{"sessionId":"`)
	strings.write_string(&unknown, session_id)
	strings.write_string(&unknown, `","modelId":"no-such-model"}}`)
	acp_test_end(&unknown)
	acp_test_client_send(&client, strings.to_string(unknown))
	if acp_test_client_expect(t, &client, `"code":-32602`, "an unknown model was not refused") == "" { return }
}

@(test)
test_acp_buzz_effort_option_selects_thinking_level :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	workspace, workspace_err := os.make_directory_temp("", "nabla-acp-effort-workspace-*", context.allocator)
	if workspace_err != nil {
		testing.expectf(t, false, "could not create a temporary workspace: %v", workspace_err)
		return
	}
	defer {
		_ = os.remove_all(workspace)
		delete(workspace, context.allocator)
	}
	state, state_err := os.make_directory_temp("", "nabla-acp-effort-state-*", context.allocator)
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

	levels := make([]string, 2, context.allocator)
	levels[0] = "low"
	levels[1] = "high"
	defer delete(levels, context.allocator)
	sources := make([]agent.Catalog_Provider_Source, 1, context.allocator)
	defer delete(sources, context.allocator)
	models := make([]agent.Catalog_Model_Source, 1, context.allocator)
	defer delete(models, context.allocator)
	models[0] = {
		id = "effortmodel",
		context_window = 100000,
		tools = true,
		thinking = agent.Catalog_Thinking_Source{present = true, levels = levels},
	}
	sources[0] = {
		id       = "effortprovider",
		base_url = "http://127.0.0.1:1/v1",
		api      = "openai_chat_completions",
		api_key  = "test-key",
		models   = models,
	}

	client: ACP_Test_Client
	defer acp_test_client_destroy(&client)
	run := ACP_Test_Run {
		client  = &client,
		sources = sources,
	}
	run_thread := thread.create(acp_test_run_thread, name = "nabla-acp-effort-run")
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
	acp_test_initialize_message(&handshake, 1)
	acp_test_client_send(&client, strings.to_string(handshake))
	if acp_test_client_expect(t, &client, `"protocolVersion":1`, "initialize was not answered") == "" { return }

	opening := strings.builder_make(context.temp_allocator)
	acp_test_new_session_message(&opening, 2, workspace)
	acp_test_client_send(&client, strings.to_string(opening))
	opened := acp_test_client_expect(t, &client, `"sessionId"`, "session/new was not answered")
	if opened == "" { return }
	if !acp_test_client_carries(
		t,
		opened,
		{`"category":"thought_level"`, `"id":"effort"`, `"value":"low"`, `"value":"high"`},
		"the thought level option",
	) { return }
	session_id := acp_test_client_session_id_from_frame(t, opened)
	if session_id == "" { return }
	defer delete(session_id, context.allocator)

	selecting := strings.builder_make(context.temp_allocator)
	fmt.sbprint(&selecting, `{"jsonrpc":"2.0","id":3,"method":"session/set_config_option","params":{"sessionId":"`)
	strings.write_string(&selecting, session_id)
	strings.write_string(&selecting, `","configId":"effort","value":"high"}}`)
	acp_test_end(&selecting)
	acp_test_client_send(&client, strings.to_string(selecting))
	selected := acp_test_client_expect(t, &client, `"currentValue":"high"`, "the effort level was not applied")
	if selected == "" { return }

	rejected := strings.builder_make(context.temp_allocator)
	fmt.sbprint(&rejected, `{"jsonrpc":"2.0","id":4,"method":"session/set_config_option","params":{"sessionId":"`)
	strings.write_string(&rejected, session_id)
	strings.write_string(&rejected, `","configId":"effort","value":"extreme"}}`)
	acp_test_end(&rejected)
	acp_test_client_send(&client, strings.to_string(rejected))
	if acp_test_client_expect(t, &client, `"code":-32602`, "an unknown effort level was not refused") == "" { return }

	unknown_option := strings.builder_make(context.temp_allocator)
	fmt.sbprint(&unknown_option, `{"jsonrpc":"2.0","id":5,"method":"session/set_config_option","params":{"sessionId":"`)
	strings.write_string(&unknown_option, session_id)
	strings.write_string(&unknown_option, `","configId":"no-such-option","value":"high"}}`)
	acp_test_end(&unknown_option)
	acp_test_client_send(&client, strings.to_string(unknown_option))
	if acp_test_client_expect(t, &client, `"code":-32602`, "an unknown config option was not refused") == "" { return }
}
@(test)
test_acp_owner_activity_prevents_eviction_until_idle :: proc(t: ^testing.T) {
	server: ACP_Server
	if !acp_test_server_init(t, &server) { return }
	defer testing.expect(t, acp_server_destroy(&server), "the ACP test server did not shut down")
	for i in 0 ..< ACP_MAX_SESSIONS {
		session, made := acp_session_make(&server, fmt.tprintf("session-%d", i))
		if !testing.expect(t, made, "the fixture session could not be allocated") { return }
		server.sessions[i] = session
		acp_session_touch(session)
		testing.expect(t, acp_owner_service_begin(session), "the owner could not reserve background servicing")
	}
	first := server.sessions[0]
	first.model_selection.active = true
	acp_owner_service_end(first)
	refused, reason := acp_session_create(&server, "session-ninth")
	testing.expect(t, refused == nil, "owner activity or a pending model selection allowed eviction")
	testing.expect(t, strings.contains(reason, "all of them are busy"), "the refusal did not report busy sessions")
	first.model_selection.active = false
	acp_owner_service_end(first)
	opened, open_reason := acp_session_create(&server, "session-ninth")
	testing.expectf(t, opened != nil, "restored idle did not allow eviction: %s", open_reason)
	testing.expect(t, acp_session_find(&server, "session-0") == nil, "the restored idle session was not evicted")
	closing := server.sessions[1]
	sync.mutex_lock(&server.table_mu)
	closing.closing = true
	sync.mutex_unlock(&server.table_mu)
	testing.expect(t, !acp_owner_service_begin(closing), "background servicing began after closing")
}
