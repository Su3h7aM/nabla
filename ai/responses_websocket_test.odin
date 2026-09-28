#+test
package ai

// Responses WebSocket tests. The fixture is an in-process WebSocket server that answers the
// upgrade and one request per connection, so what these tests exercise is a session over a
// real socket rather than its own encoder.
//
// The reconnect case is a peer that ends a connection it has answered: the next request on
// the same session finds the socket gone, and it must be sent again on a new one.

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "nabla:websocket"

@(test)
test_responses_websocket_endpoint_preserves_authority_and_resource :: proc(t: ^testing.T) {
	cases := []struct {
		base: string,
		want: string,
		ok:   bool,
	} {
		{"https://api.openai.com/v1", "wss://api.openai.com/v1/responses", true},
		{"https://api.openai.com/v1/responses", "wss://api.openai.com/v1/responses", true},
		{"http://127.0.0.1:8080/v1/", "ws://127.0.0.1:8080/v1/responses", true},
		{"wss://example.test/api", "wss://example.test/api/responses", true},
		// A query belongs after the resource path, not inside it.
		{"https://example.test/v1?api-version=1", "wss://example.test/v1/responses?api-version=1", true},
		{"ftp://example.test", "", false},
		{"not a url", "", false},
	}
	for entry in cases {
		endpoint, endpoint_error := provider_websocket_endpoint(entry.base, context.temp_allocator)
		testing.expect_value(t, endpoint_error.kind == .None, entry.ok)
		testing.expect_value(t, endpoint, entry.want)
	}
}

// --- the peer fixture ---------------------------------------------------------

// RESPONSES_WEBSOCKET_FIXTURE_BOUND ends a fixture that stopped making progress, so a
// client that never opens the connection the fixture expects fails the test instead of
// hanging the suite.
RESPONSES_WEBSOCKET_FIXTURE_BOUND :: 10 * time.Second

// RESPONSES_WEBSOCKET_COMPLETION is the terminal event the fixture answers with: a
// completed response with no output, which is the shortest stream a request can end on.
RESPONSES_WEBSOCKET_COMPLETION :: `{"type":"response.completed","response":{"status":"completed","output":[]}}`

// RESPONSES_WEBSOCKET_CLOSE is a close frame's payload: the normal closure code, which is
// what a peer that ends a healthy connection sends (RFC 6455 7.1.1).
RESPONSES_WEBSOCKET_CLOSE :: "\x03\xE8"

// Responses_WebSocket_Fixture_Mode is what the fixture's server does with the connections
// its test asks it for.
Responses_WebSocket_Fixture_Mode :: enum {
	// Answer the first connection with the terminal event and end it, then answer the
	// second: a peer that closed the connection it had just answered, which is what the
	// request that follows finds.
	End_After_Answering,
	// End the one connection without answering it: a peer that dropped a connection none of
	// the response arrived on.
	Silence,
}

// Responses_WebSocket_Fixture is the test's own WebSocket server. It answers the upgrade,
// drains one request frame per connection, and then does what its mode asks. Every value
// belongs to the test that declared it, and the port is asked of the kernel, so two tests
// never share one.
Responses_WebSocket_Fixture :: struct {
	mode:           Responses_WebSocket_Fixture_Mode,
	listener:       net.TCP_Socket,
	port:           int,
	connections:    int,
	// answered_first is posted once the server has answered its first connection and ended
	// it, so the test acts only on a socket that is already gone.
	answered_first: sync.Sema,
	failed:         bool,
	thread:         ^thread.Thread,
}

// responses_websocket_fixture_start listens on a port of the kernel's choosing and starts
// the server. Every other observer of the fixture reads it after the server is joined.
responses_websocket_fixture_start :: proc(t: ^testing.T, fixture: ^Responses_WebSocket_Fixture, mode: Responses_WebSocket_Fixture_Mode) -> bool {
	fixture^ = Responses_WebSocket_Fixture {
		mode = mode,
	}
	listener, listen_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	if listen_err != nil {
		testing.expectf(t, false, "the fixture could not listen: %v", listen_err)
		return false
	}
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if endpoint_err != nil {
		testing.expectf(t, false, "the fixture could not read its endpoint: %v", endpoint_err)
		net.close(listener)
		return false
	}
	// An accept that waits for a connection the client never opens would hold the suite, so
	// it gives up at the bound and the test hears that the fixture served less than its mode
	// asks for.
	if option_err := net.set_option(listener, .Receive_Timeout, RESPONSES_WEBSOCKET_FIXTURE_BOUND); option_err != .None {
		testing.expectf(t, false, "the fixture could not bound its accept: %v", option_err)
		net.close(listener)
		return false
	}
	fixture.listener = listener
	fixture.port = endpoint.port
	fixture.thread = thread.create(responses_websocket_fixture_serve, name = "nabla-responses-websocket-fixture")
	if fixture.thread == nil {
		testing.expectf(t, false, "the fixture thread could not start")
		net.close(listener)
		fixture.listener = {}
		return false
	}
	fixture.thread.data = fixture
	thread.start(fixture.thread)
	return true
}

// responses_websocket_fixture_stop joins the server and reports whether it served
// everything its mode asks for, which is only knowable once it has stopped.
responses_websocket_fixture_stop :: proc(t: ^testing.T, fixture: ^Responses_WebSocket_Fixture) {
	if fixture.thread == nil { return }
	thread.join(fixture.thread)
	thread.destroy(fixture.thread)
	fixture.thread = nil
	testing.expect(t, !fixture.failed, "the fixture did not serve every connection its mode asks for")
}

// responses_websocket_fixture_serve accepts the connections the mode asks for, one at a
// time, and closes the listener when its script is done: a request that asks for another
// connection is refused rather than left waiting on a server that has stopped.
responses_websocket_fixture_serve :: proc(thread: ^thread.Thread) {
	fixture := cast(^Responses_WebSocket_Fixture)thread.data
	defer net.close(fixture.listener)
	connections := 1
	if fixture.mode == .End_After_Answering { connections = 2 }
	for index in 0 ..< connections {
		socket, _, accept_err := net.accept_tcp(fixture.listener)
		if accept_err != nil {
			fixture.failed = true
			return
		}
		served := responses_websocket_fixture_connection(fixture, socket)
		net.close(socket)
		if !served {
			fixture.failed = true
			return
		}
		if index == 0 && fixture.mode == .End_After_Answering {
			sync.sema_post(&fixture.answered_first)
		}
	}
}

// responses_websocket_fixture_connection serves one connection: it answers the upgrade,
// drains the request frame, answers with the terminal event unless the mode is silence, and
// ends the WebSocket. The close frame is sent before the socket is closed, so the client
// reads the peer's close rather than a stream that stopped between frames.
responses_websocket_fixture_connection :: proc(fixture: ^Responses_WebSocket_Fixture, socket: net.TCP_Socket) -> bool {
	if !responses_websocket_fixture_upgrade(socket) { return false }
	fixture.connections += 1
	if !responses_websocket_fixture_read_request(socket) { return false }
	if fixture.mode == .End_After_Answering {
		if !responses_websocket_fixture_write_frame(socket, .Text, RESPONSES_WEBSOCKET_COMPLETION) { return false }
	}
	return responses_websocket_fixture_write_frame(socket, .Close, RESPONSES_WEBSOCKET_CLOSE)
}

// responses_websocket_fixture_upgrade answers the upgrade: it reads the request head and
// states the accept value the key asks for, which is the only value the client accepts
// (RFC 6455 4.2.2).
responses_websocket_fixture_upgrade :: proc(socket: net.TCP_Socket) -> bool {
	request: [4096]u8
	used := 0
	key := ""
	for {
		count, recv_err := net.recv_tcp(socket, request[used:])
		if recv_err != nil || count <= 0 { return false }
		used += count
		head := string(request[:used])
		if header_end := strings.index(head, "\r\n\r\n"); header_end >= 0 {
			found: bool
			key, found = responses_websocket_fixture_head_field(head[:header_end], "sec-websocket-key")
			if !found || key == "" { return false }
			break
		}
		if used == len(request) { return false }
	}
	accept := websocket.accept_key(key)
	answer := fmt.bprintf(
		request[:],
		"HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: %s\r\n\r\n",
		string(accept[:]),
	)
	return responses_websocket_fixture_write(socket, transmute([]u8)answer)
}

// responses_websocket_fixture_head_field reads one field of a request head. A field name is
// not case-sensitive (RFC 9110 5.1).
responses_websocket_fixture_head_field :: proc(head: string, name: string) -> (value: string, found: bool) {
	remaining := head
	for line in strings.split_iterator(&remaining, "\r\n") {
		colon := strings.index_byte(line, ':')
		if colon < 0 { continue }
		if strings.equal_fold(line[:colon], name) {
			return strings.trim_space(line[colon + 1:]), true
		}
	}
	return "", false
}

// responses_websocket_fixture_read_request reads and discards one whole frame: the request
// the client sent, which a fixture asserting on the session's transport never inspects.
// Draining it before the connection ends is what keeps the close orderly.
responses_websocket_fixture_read_request :: proc(socket: net.TCP_Socket) -> bool {
	head: [10]u8
	if !responses_websocket_fixture_read_exact(socket, head[:2]) { return false }
	masked := head[1] & 0x80 != 0
	length := int(head[1] & 0x7f)
	switch length {
	case 126:
		if !responses_websocket_fixture_read_exact(socket, head[:2]) { return false }
		length = int(u16(head[0]) << 8 | u16(head[1]))
	case 127:
		if !responses_websocket_fixture_read_exact(socket, head[:8]) { return false }
		length = 0
		for octet in head[:8] { length = length << 8 | int(octet) }
	}
	// A client masks every frame it sends (RFC 6455 5.1), and the key is dropped with the
	// payload it protects.
	if masked {
		mask: [4]u8
		if !responses_websocket_fixture_read_exact(socket, mask[:]) { return false }
	}
	buffer: [4096]u8
	for length > 0 {
		count := min(length, len(buffer))
		if !responses_websocket_fixture_read_exact(socket, buffer[:count]) { return false }
		length -= count
	}
	return true
}

responses_websocket_fixture_read_exact :: proc(socket: net.TCP_Socket, buffer: []u8) -> bool {
	filled := 0
	for filled < len(buffer) {
		count, recv_err := net.recv_tcp(socket, buffer[filled:])
		if recv_err != nil || count <= 0 { return false }
		filled += count
	}
	return true
}

// responses_websocket_fixture_write_frame states one unmasked frame and sends it. A server
// never masks, and a fixture payload always fits the two-octet length form.
responses_websocket_fixture_write_frame :: proc(socket: net.TCP_Socket, opcode: websocket.Opcode, payload: string) -> bool {
	buffer: [512]u8
	frame := responses_websocket_fixture_frame(buffer[:], opcode, payload)
	if frame == nil { return false }
	return responses_websocket_fixture_write(socket, frame)
}

// responses_websocket_fixture_frame states one unmasked, unfragmented frame in buffer,
// which must hold its header and payload, and returns the octets of it.
responses_websocket_fixture_frame :: proc(buffer: []u8, opcode: websocket.Opcode, payload: string) -> []u8 {
	if len(payload) > len(buffer) - 4 { return nil }
	frame := buffer[:len(payload) + 4]
	// A server sets the FIN bit on every frame it sends here: no fixture message is
	// fragmented.
	frame[0] = 0x80 | u8(opcode)
	if len(payload) < 126 {
		frame[1] = u8(len(payload))
		copy(frame[2:], transmute([]u8)payload)
		return frame[:2 + len(payload)]
	}
	if len(payload) > 65535 { return nil }
	frame[1] = 126
	frame[2] = u8(len(payload) >> 8)
	frame[3] = u8(len(payload) & 0xff)
	copy(frame[4:], transmute([]u8)payload)
	return frame[:4 + len(payload)]
}

responses_websocket_fixture_write :: proc(socket: net.TCP_Socket, data: []u8) -> bool {
	pending := data
	for len(pending) > 0 {
		written, send_err := net.send_tcp(socket, pending)
		if send_err != nil || written <= 0 { return false }
		pending = pending[written:]
	}
	return true
}

// --- the session under test ---------------------------------------------------

// Responses_WebSocket_Case is one test's half of the conversation: the session it sends on
// and the one frozen request it sends.
Responses_WebSocket_Case :: struct {
	endpoint: string,
	session:  ^Provider_WebSocket_Session,
	encoded:  Provider_Encoded_Request,
}

// responses_websocket_case_open opens a session against the fixture on port and freezes the
// request both tests send. The case owns the session and the body it sends, and ends them
// with responses_websocket_case_destroy.
responses_websocket_case_open :: proc(t: ^testing.T, port: int) -> (test_case: Responses_WebSocket_Case, ok: bool) {
	test_case.endpoint = fmt.aprintf("http://127.0.0.1:%d/v1", port, allocator = context.allocator)
	connection := Provider_Connection {
		API        = .OpenAI_Responses,
		Endpoint   = test_case.endpoint,
		Credential = "responses-websocket-test-credential",
	}
	session, open_err := Provider_WebSocket_Session_Open(connection, context.allocator)
	opened := testing.expectf(t, open_err.kind == .None, "the session could not be opened: %v %s", open_err.kind, open_err.detail)
	Provider_Operation_Error_Destroy(&open_err, context.allocator)
	if !opened { return test_case, false }
	test_case.session = session

	messages := []Provider_Message{{Role = .User, Content = "responses-websocket-test-payload"}}
	request := Provider_Request {
		API              = .OpenAI_Responses,
		Model_Present    = true,
		Model            = "responses-websocket-test-model",
		Messages_Present = true,
		Messages         = messages,
	}
	encoded, encode_err := Provider_Request_Freeze_WebSocket(request, context.allocator)
	encoded_ok := testing.expectf(t, encode_err.kind == .None, "the request could not be encoded: %v %s", encode_err.kind, encode_err.detail)
	Provider_Operation_Error_Destroy(&encode_err, context.allocator)
	if !encoded_ok { return test_case, false }
	test_case.encoded = encoded
	return test_case, true
}

// responses_websocket_case_destroy ends the session before the body it borrows.
responses_websocket_case_destroy :: proc(test_case: ^Responses_WebSocket_Case) {
	Provider_WebSocket_Session_Destroy(test_case.session)
	test_case.session = nil
	if test_case.encoded.Body != nil {
		delete(test_case.encoded.Body, context.allocator)
		test_case.encoded.Body = nil
	}
	if test_case.endpoint != "" {
		delete(test_case.endpoint, context.allocator)
		test_case.endpoint = ""
	}
}

// Responses_WebSocket_Outcome is what one request returned and what its callback saw.
Responses_WebSocket_Outcome :: struct {
	error:       Provider_Operation_Error,
	completions: int,
}

responses_websocket_outcome_event :: proc(user_data: rawptr, event: Provider_Event) {
	outcome := cast(^Responses_WebSocket_Outcome)user_data
	#partial switch value in event {
	case Provider_Completed_Event:
		outcome.completions += 1
	}
}

// responses_websocket_request_run performs one request on the case's session, adding what
// the operation reported to observed. The outcome owns its error.
responses_websocket_request_run :: proc(test_case: ^Responses_WebSocket_Case, observed: ^Transport_Observation, outcome: ^Responses_WebSocket_Outcome) {
	options := Provider_Operation_Options {
		observer = {user_data = observed, report = transport_observation_report},
	}
	outcome.error = Provider_WebSocket_Request(test_case.session, test_case.encoded, outcome, responses_websocket_outcome_event, options)
}

// A peer that ends the connection it has answered must not end the request: the session
// replaces the socket and sends the same bytes again, once, on a new connection.
@(test)
test_responses_websocket_sends_again_when_a_reused_socket_ended :: proc(t: ^testing.T) {
	fixture: Responses_WebSocket_Fixture
	if !responses_websocket_fixture_start(t, &fixture, .End_After_Answering) { return }
	defer responses_websocket_fixture_stop(t, &fixture)

	test_case, opened := responses_websocket_case_open(t, fixture.port)
	defer responses_websocket_case_destroy(&test_case)
	if !opened { return }

	observed: Transport_Observation
	first: Responses_WebSocket_Outcome
	responses_websocket_request_run(&test_case, &observed, &first)
	defer Provider_Operation_Error_Destroy(&first.error, context.allocator)
	if !testing.expectf(t, first.error.kind == .None, "the first request failed: %v %s", first.error.kind, first.error.detail) {
		return
	}
	testing.expect_value(t, first.completions, 1)

	// The peer has ended the connection it answered, so the socket the session holds is
	// already gone when the next request writes to it.
	if !sync.sema_wait_with_timeout(&fixture.answered_first, RESPONSES_WEBSOCKET_FIXTURE_BOUND) {
		testing.expectf(t, false, "the fixture never ended its first connection")
		return
	}

	second: Responses_WebSocket_Outcome
	responses_websocket_request_run(&test_case, &observed, &second)
	defer Provider_Operation_Error_Destroy(&second.error, context.allocator)
	testing.expectf(t, second.error.kind == .None, "the request on the ended connection failed: %v %s", second.error.kind, second.error.detail)
	testing.expect_value(t, second.completions, 1)
	// One replacement, and both responses arrived whole: the ended socket was dropped
	// rather than answered twice, and the request that was sent again was answered.
	testing.expect_value(t, observed.reconnects, 1)
	testing.expect_value(t, observed.chunks, 2)
	testing.expect_value(t, observed.chunk_bytes, 2 * len(RESPONSES_WEBSOCKET_COMPLETION))
	testing.expect_value(t, fixture.connections, 2)
}

// A connection opened for this request that ends before any of the response arrived is a
// transport failure, not a stale socket: nothing was reused, so nothing authorizes a
// second send.
@(test)
test_responses_websocket_a_connection_that_never_answered_is_not_replaced :: proc(t: ^testing.T) {
	fixture: Responses_WebSocket_Fixture
	if !responses_websocket_fixture_start(t, &fixture, .Silence) { return }
	defer responses_websocket_fixture_stop(t, &fixture)

	test_case, opened := responses_websocket_case_open(t, fixture.port)
	defer responses_websocket_case_destroy(&test_case)
	if !opened { return }

	observed: Transport_Observation
	outcome: Responses_WebSocket_Outcome
	responses_websocket_request_run(&test_case, &observed, &outcome)
	defer Provider_Operation_Error_Destroy(&outcome.error, context.allocator)

	testing.expect_value(t, outcome.error.kind, Provider_Operation_Error_Kind.Transport)
	testing.expect_value(t, outcome.completions, 0)
	testing.expect_value(t, observed.reconnects, 0)
	testing.expect_value(t, observed.chunks, 0)
	testing.expect_value(t, fixture.connections, 1)
}
