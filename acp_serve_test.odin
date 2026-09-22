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

import "nabla:agent"

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

// Acp_Test_Provider answers one canned HTTP response per connection, in order. It stands
// in for a provider endpoint, so a turn runs for real: the harness sends requests, reads
// streams, and records results exactly as it would against a server.
Acp_Test_Provider :: struct {
	listener: net.TCP_Socket,
	port:     int,
	replies:  []string,
	served:   int,
	lock:     sync.Mutex,
	failed:   bool,
	thread:   ^thread.Thread,
}

acp_test_provider_start :: proc(t: ^testing.T, provider: ^Acp_Test_Provider, replies: []string) -> bool {
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

acp_test_provider_stop :: proc(t: ^testing.T, provider: ^Acp_Test_Provider) {
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
	provider := cast(^Acp_Test_Provider)thread_handle.data
	for index in 0 ..< len(provider.replies) {
		client, _, accept_err := net.accept_tcp(provider.listener)
		if accept_err != nil { return }
		acp_test_provider_answer(provider, client, provider.replies[index])
	}
}

// acp_test_provider_answer reads one whole request before answering it, so the harness is
// never still writing when the connection closes.
acp_test_provider_answer :: proc(provider: ^Acp_Test_Provider, client: net.TCP_Socket, reply: string) {
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

// Acp_Test_Client is a client with two ends: the messages it writes to the agent, and the
// frames it has read back. Both are guarded, because the run reads and writes on its own
// threads while the test does the same.
Acp_Test_Client :: struct {
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

acp_test_client_input :: proc(client: ^Acp_Test_Client) -> io.Reader {
	return io.Reader{data = client, procedure = acp_test_client_stream}
}

acp_test_client_output :: proc(client: ^Acp_Test_Client) -> io.Writer {
	return io.Writer{data = client, procedure = acp_test_client_stream}
}

// acp_test_client_stream serves both ends of the client: a read takes the next message the
// test wrote, and a write appends what the run produced.
acp_test_client_stream :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	client := cast(^Acp_Test_Client)data
	switch mode {
	case .Read:
		sync.mutex_lock(&client.mu)
		defer sync.mutex_unlock(&client.mu)
		for len(client.input) == 0 && !client.input_closed { sync.cond_wait(&client.cond, &client.mu) }
		if len(client.input) == 0 { return 0, .EOF }
		count := copy(p, client.input[:])
		copy(client.input[:], client.input[count:])
		resize(&client.input, len(client.input) - count)
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

acp_test_client_destroy :: proc(client: ^Acp_Test_Client) {
	sync.mutex_lock(&client.mu)
	defer sync.mutex_unlock(&client.mu)
	delete(client.input)
	delete(client.output)
	client.input = nil
	client.output = nil
	client.read_at = 0
}

// acp_test_client_send writes one whole message, including the newline that ends it.
acp_test_client_send :: proc(client: ^Acp_Test_Client, message: string) {
	sync.mutex_lock(&client.mu)
	defer sync.mutex_unlock(&client.mu)
	append(&client.input, ..transmute([]u8)message)
	sync.cond_broadcast(&client.cond)
}

// acp_test_client_hang_up ends the client's side of the stream, which is what a client
// that quits does.
acp_test_client_hang_up :: proc(client: ^Acp_Test_Client) {
	sync.mutex_lock(&client.mu)
	defer sync.mutex_unlock(&client.mu)
	client.input_closed = true
	sync.cond_broadcast(&client.cond)
}

// acp_test_client_receive reads one whole message. It returns "" when the run stopped
// writing or did not answer within the bound, so a failure is reported by the expectation
// that wanted the message rather than by aborting the test.
acp_test_client_receive :: proc(client: ^Acp_Test_Client, allocator := context.temp_allocator) -> string {
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
acp_test_client_expect :: proc(t: ^testing.T, client: ^Acp_Test_Client, needle, what: string) -> string {
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
acp_test_client_session_id :: proc(t: ^testing.T, client: ^Acp_Test_Client, allocator := context.allocator) -> string {
	frame := acp_test_client_receive(client)
	if frame == "" {
		testing.expectf(t, false, "session/new: the run did not answer")
		return ""
	}
	answer: struct {
		result: struct {
			session_id: string `json:"sessionId"`,
		} `json:"result"`,
	}
	if unmarshal_err := json.unmarshal(transmute([]u8)frame, &answer, allocator = allocator); unmarshal_err != nil {
		testing.expectf(t, false, "the session/new answer could not be read: %s", frame)
		return ""
	}
	return answer.result.session_id
}

// --- environment -------------------------------------------------------------

// acp_test_env points one XDG variable at a temporary directory, so a run that opens the
// session store or reads the catalog cache cannot touch the user's own state.
acp_test_env :: proc(variable, directory: string) -> (previous: string, had_previous: bool) {
	previous, had_previous = os.lookup_env(variable, context.allocator)
	os.set_env(variable, directory)
	return
}

acp_test_env_restore :: proc(variable, previous: string, had_previous: bool) {
	if had_previous {
		os.set_env(variable, previous)
	} else {
		os.unset_env(variable)
	}
	delete(previous, context.allocator)
}

// --- the conversation --------------------------------------------------------

// Acp_Test_Run is one frontend living on its own thread while the test plays the client.
Acp_Test_Run :: struct {
	client:  ^Acp_Test_Client,
	sources: []agent.Catalog_Provider_Source,
	served:  bool,
}

acp_test_run_thread :: proc(thread_handle: ^thread.Thread) {
	run := cast(^Acp_Test_Run)thread_handle.data
	run.served = acp_run(run.sources, {}, {}, acp_test_client_input(run.client), acp_test_client_output(run.client))
}

@(test)
test_acp_serves_a_turn_and_replays_a_loaded_session :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	workspace, workspace_err := os.make_directory_temp("", "nabla-acp-workspace-*", context.allocator)
	if workspace_err != nil {
		testing.expectf(t, false, "could not create a temporary workspace: %v", workspace_err)
		return
	}
	defer {
		os.remove_all(workspace)
		delete(workspace, context.allocator)
	}
	state, state_err := os.make_directory_temp("", "nabla-acp-state-*", context.allocator)
	if state_err != nil {
		testing.expectf(t, false, "could not create a temporary state directory: %v", state_err)
		return
	}
	defer {
		os.remove_all(state)
		delete(state, context.allocator)
	}
	previous_state, had_state := acp_test_env("XDG_STATE_HOME", state)
	defer acp_test_env_restore("XDG_STATE_HOME", previous_state, had_state)
	// The catalog cache is pointed at the state directory too: a run must never read or
	// write the user's own cache.
	previous_cache, had_cache := acp_test_env("XDG_CACHE_HOME", state)
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
	strings.write_string(
		&call_event,
		`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"builtin_read","arguments":`,
	)
	strings.write_string(&call_event, string(quoted_arguments))
	strings.write_string(&call_event, `}}]},"finish_reason":null}]}`)
	replies := []string {
		acp_test_stream_reply(acp_test_sse_body({strings.to_string(call_event), `{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`})),
		acp_test_stream_reply(
			acp_test_sse_body(
				{`{"choices":[{"delta":{"content":"the note says so"},"finish_reason":null}]}`, `{"choices":[{"delta":{},"finish_reason":"stop"}]}`},
			),
		),
	}
	defer for reply in replies { delete(reply, context.allocator) }

	provider: Acp_Test_Provider
	if !acp_test_provider_start(t, &provider, replies) { return }
	defer acp_test_provider_stop(t, &provider)

	sources := make([]agent.Catalog_Provider_Source, 1, context.allocator)
	defer delete(sources, context.allocator)
	models := make([]agent.Catalog_Model_Source, 1, context.allocator)
	defer delete(models, context.allocator)
	models[0] = {
		id                        = "testmodel",
		context_window_present    = true,
		context_window            = 100000,
		max_output_tokens_present = true,
		max_output_tokens         = 4096,
		tools_present             = true,
		tools                     = true,
	}
	sources[0] = {
		id               = "testprovider",
		base_url_present = true,
		base_url         = fmt.aprintf("http://127.0.0.1:%d/v1", provider.port, allocator = context.allocator),
		api_present      = true,
		api              = "openai_chat_completions",
		api_key_present  = true,
		api_key          = "test-key",
		models           = models,
	}
	defer delete(sources[0].base_url, context.allocator)

	client: Acp_Test_Client
	defer acp_test_client_destroy(&client)
	run := Acp_Test_Run {
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
	testing.expectf(t, strings.contains(hello, `"embeddedContext":true`), "initialize did not announce embedded context: %s", hello)

	// session/new: the client gets the id it will name from then on.
	opening := strings.builder_make(context.temp_allocator)
	acp_test_new_session_message(&opening, 2, workspace)
	acp_test_client_send(&client, strings.to_string(opening))
	session_id := acp_test_client_session_id(t, &client)
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
}
