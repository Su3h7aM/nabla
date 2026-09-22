#+test
package websocket

// Live upgrade coverage against the scripted peer below, which frames the
// protocol itself over a plain socket, so a client that agrees with it agrees
// with something other than its own encoder.
//
// This is what an in-package byte fixture cannot reach: the Upgrade exchange
// through http/client over a real socket, a frame that arrives in the same
// segment as the response head, a response that does not accept the key, and
// the two frames a server may not send. Message framing, fragmentation and
// control frames are covered by the byte fixtures. The peer runs on a thread
// because the client blocks on the answer to each case, and every fixture
// (port, findings, message buffer) is per test.

import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

import "nabla:http/client"

ECHO_CASE_TIMEOUT :: 30 * time.Second

// Echo_State is one test's side of the conversation: the message buffer and
// the deadline that ends a case whose peer stopped answering.
Echo_State :: struct {
	t:        ^testing.T,
	buffer:   []u8,
	deadline: time.Tick,
}

@(test)
test_websocket_live_peer_upgrade_and_violations :: proc(t: ^testing.T) {
	state := Echo_State {
		t = t,
	}
	state.buffer = make([]u8, PEER_BUFFER, context.allocator)
	defer delete(state.buffer)

	peer: Peer
	if !testing.expect(t, peer_start(&peer), "the peer could not be started") { return }
	defer peer_destroy(&peer)

	echo_run_message_cases(&state, peer.port)
	echo_run_immediate_case(&state, peer.port)
	echo_run_rejected_key_case(&state, peer.port)
	echo_run_protocol_violation_case(&state, peer.port, "a masked frame from the server")
	echo_run_protocol_violation_case(&state, peer.port, "a control frame over 125 octets")

	peer_wait(&peer)
	testing.expect(t, peer_saw(&peer, "the handshake was answered"), "the peer never answered a handshake")
	testing.expect(t, peer_saw(&peer, "the client closed with 1000"), "the client's close did not carry code 1000")
	testing.expect(t, peer_saw(&peer, "a masked frame from the server was closed with 1002"), "a masked frame was not refused as a protocol error")
	testing.expect(
		t,
		peer_saw(&peer, "a control frame over 125 octets was closed with 1002"),
		"an oversized control frame was not refused as a protocol error",
	)
	testing.expect(t, !peer_saw(&peer, "a client frame was not masked"), "the client sent an unmasked frame")
}

// echo_open dials the peer, which is listening before the first case runs.
echo_open :: proc(state: ^Echo_State, port: int, path: string) -> (conn: ^Conn, failure: Dial_Failure) {
	url := fmt.aprintf("ws://localhost:%d%s", port, path)
	defer delete(url)
	state.deadline = time.tick_add(time.tick_now(), ECHO_CASE_TIMEOUT)
	return dial(url, {http = {probe = {check = echo_keep_going, user_data = &state.deadline}}})
}

// echo_keep_going ends a case that has stalled.
echo_keep_going :: proc(user_data: rawptr) -> client.Wait_Status {
	deadline := cast(^time.Tick)user_data
	if time.tick_since(deadline^) >= 0 { return .Timed_Out }
	return .Ready
}

// The message cases run on one connection, in the order the peer's script expects.
echo_run_message_cases :: proc(state: ^Echo_State, port: int) {
	t := state.t
	conn, failure := echo_open(state, port, "/")
	if !testing.expect_value(t, failure.kind, Dial_Error.None) {
		dial_failure_destroy(&failure, context.allocator)
		return
	}
	defer destroy(conn)

	echo_send(state, conn, .Text, "echo")
	echo_expect_message(state, conn, .Text, "echo")
	echo_send(state, conn, .Binary, "binary")
	echo_expect_message(state, conn, .Binary, "binary")

	// A message the peer sends as two frames, so the first read ends nothing.
	echo_send(state, conn, .Text, "fragmented")
	length := 0
	count, _, complete, err := read(conn, state.buffer[:])
	if testing.expect_value(t, err, Error.None) {
		length += count
		testing.expect(t, !complete, "the first fragment ended the message")
		count, _, complete, err = read(conn, state.buffer[length:])
		if testing.expect_value(t, err, Error.None) {
			length += count
			testing.expect(t, complete, "the last fragment did not end the message")
			testing.expect_value(t, string(state.buffer[:length]), "fragmented")
		}
	}

	// A message far larger than one frame, arriving as several.
	echo_send(state, conn, .Text, "large")
	message, received := echo_receive(state, conn, .Text)
	if testing.expect(t, received, "the large message could not be read") {
		if testing.expect_value(t, len(message), LARGE_MESSAGE) {
			content_ok := true
			for octet in transmute([]u8)message { if octet != 'a' { content_ok = false } }
			testing.expect(t, content_ok, "the large message is not what the peer sent")
		}
	}

	// A ping from the peer is answered while the next message is read.
	echo_send(state, conn, .Text, "ping")
	echo_expect_message(state, conn, .Text, "pong")

	// An orderly close, with the peer's code and this client's answer to it.
	echo_send(state, conn, .Text, "close")
	buffer: [1024]u8
	err = .None
	for err == .None { _, _, _, err = read(conn, buffer[:]) }
	testing.expect_value(t, err, Error.Closed)
	testing.expect_value(t, conn.close_code, Close_Code.Normal)
	testing.expect_value(t, close(conn, .Normal, "", buffer[:]), Error.None)
}

// A frame the peer sends in the same segment as its response head belongs to the WebSocket,
// not to the HTTP response, and it must still be the first thing read.
echo_run_immediate_case :: proc(state: ^Echo_State, port: int) {
	t := state.t
	conn, failure := echo_open(state, port, "/")
	if !testing.expect_value(t, failure.kind, Dial_Error.None) {
		dial_failure_destroy(&failure, context.allocator)
		return
	}
	defer destroy(conn)
	echo_expect_message(state, conn, .Text, "immediate")
}

// A response that does not accept the key it was sent is not a WebSocket, so no connection
// may be handed to a caller (RFC 6455 4.1).
echo_run_rejected_key_case :: proc(state: ^Echo_State, port: int) {
	t := state.t
	conn, failure := echo_open(state, port, "/")
	defer dial_failure_destroy(&failure, context.allocator)
	if conn != nil {
		destroy(conn)
		testing.fail_now(t, "a connection was opened on a response that did not accept the key")
	}
	testing.expect_value(t, failure.kind, Dial_Error.Response)
}

echo_run_protocol_violation_case :: proc(state: ^Echo_State, port: int, what: string) {
	t := state.t
	conn, failure := echo_open(state, port, "/")
	if !testing.expect_value(t, failure.kind, Dial_Error.None) {
		dial_failure_destroy(&failure, context.allocator)
		return
	}
	defer destroy(conn)

	buffer: [1024]u8
	for {
		_, _, _, err := read(conn, buffer[:])
		if err == .None { continue }
		testing.expect_value(t, err, Error.Protocol)
		return
	}
}

echo_send :: proc(state: ^Echo_State, conn: ^Conn, opcode: Opcode, message: string) {
	t := state.t
	testing.expect_value(t, write(conn, opcode, transmute([]u8)message), Error.None)
}

echo_expect_message :: proc(state: ^Echo_State, conn: ^Conn, opcode: Opcode, expected: string) -> string {
	message, received := echo_receive(state, conn, opcode)
	if received { testing.expect_value(state.t, message, expected) }
	return message
}

// echo_receive reads one whole message of the given type and reports it, which is an empty
// string when the message failed.
echo_receive :: proc(state: ^Echo_State, conn: ^Conn, opcode: Opcode) -> (message: string, ok: bool) {
	t := state.t
	length := 0
	for {
		count, frame_opcode, complete, err := read(conn, state.buffer[length:])
		if !testing.expect_value(t, err, Error.None) { return "", false }
		if !testing.expect_value(t, frame_opcode, opcode) { return "", false }
		length += count
		if complete { return string(state.buffer[:length]), true }
	}
}

// --- the scripted peer --------------------------------------------------------

// Peer is a scripted RFC 6455 server for this test. It frames the protocol itself over a
// plain socket, so a client that agrees with it agrees with something other than its own
// encoder. It runs on a thread because the client blocks on the answer to each case, and
// each accepted connection is served by the next case in the script.

GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

OP_CONTINUATION :: 0x0
OP_TEXT :: 0x1
OP_BINARY :: 0x2
OP_CLOSE :: 0x8
OP_PING :: 0x9
OP_PONG :: 0xa

// LARGE_MESSAGE is the size of the message sent as several frames, which is larger than any
// frame the peer sends.
LARGE_MESSAGE :: 100_000

// PEER_BUFFER holds the largest payload a case moves. A client may fragment what it sends,
// but no case asks it to, so a whole message fits.
PEER_BUFFER :: 256 * 1024

// Case is what one accepted connection is for, in the order the harness dials them.
Case :: enum {
	Messages,
	Immediate,
	Rejected_Key,
	Masked_Frame,
	Oversized_Control,
}

SCRIPT :: []Case{.Messages, .Immediate, .Rejected_Key, .Masked_Frame, .Oversized_Control}

Peer :: struct {
	listener:  net.TCP_Socket,
	started:   bool,
	port:      int,
	thread:    ^thread.Thread,
	buffer:    []u8,
	// findings is what the peer saw, in order. It is read after the thread has been
	// joined, so the two threads never touch it at once.
	findings:  [dynamic]string,
	allocator: mem.Allocator,
}

peer_start :: proc(peer: ^Peer, allocator := context.allocator) -> bool {
	peer.allocator = allocator
	peer.buffer = make([]u8, PEER_BUFFER, allocator)
	listener, listen_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, len(SCRIPT))
	if listen_err != nil { return false }
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if endpoint_err != nil {
		net.close(listener)
		return false
	}
	peer.listener = listener
	peer.started = true
	peer.port = endpoint.port
	peer.thread = thread.create(peer_serve, name = "nabla-websocket-peer")
	if peer.thread == nil {
		net.close(listener)
		return false
	}
	peer.thread.data = peer
	thread.start(peer.thread)
	return true
}

// peer_wait blocks until every case has been served, which is what makes the findings a
// complete account of the run.
peer_wait :: proc(peer: ^Peer) {
	if peer.thread != nil {
		thread.join(peer.thread)
		thread.destroy(peer.thread)
		peer.thread = nil
	}
}

peer_destroy :: proc(peer: ^Peer) {
	if peer.started { net.close(peer.listener) }
	peer_wait(peer)
	for finding in peer.findings { delete(finding, peer.allocator) }
	delete(peer.findings)
	delete(peer.buffer, peer.allocator)
	peer^ = {}
}

// peer_saw reports whether the peer recorded this finding, which is how a case states what
// the client was supposed to do rather than what it was supposed to return.
peer_saw :: proc(peer: ^Peer, text: string) -> bool {
	for finding in peer.findings { if finding == text { return true } }
	return false
}

peer_note :: proc(peer: ^Peer, text: string) {
	append(&peer.findings, strings.clone(text, peer.allocator))
}

@(private)
peer_serve :: proc(thread: ^thread.Thread) {
	peer := cast(^Peer)thread.data
	for scripted in SCRIPT {
		socket, _, accept_err := net.accept_tcp(peer.listener)
		if accept_err != nil {
			peer_note(peer, "the peer could not accept the next case")
			return
		}
		switch scripted {
		case .Messages:
			peer_case_messages(peer, socket)
		case .Immediate:
			peer_case_immediate(peer, socket)
		case .Rejected_Key:
			peer_handshake(peer, socket, accept_key = false)
		case .Masked_Frame:
			peer_case_refuses(peer, socket, "a masked frame from the server", masked = true)
		case .Oversized_Control:
			peer_case_refuses(peer, socket, "a control frame over 125 octets", masked = false)
		}
		net.close(socket)
	}
}

// --- one case each ------------------------------------------------------------

// The message cases run on one connection in the order the harness sends them.
@(private)
peer_case_messages :: proc(peer: ^Peer, socket: net.TCP_Socket) {
	if !peer_handshake(peer, socket, accept_key = true) { return }
	buffer := peer.buffer
	for {
		frame, read_ok := peer_frame_read(socket, buffer)
		if !read_ok {
			peer_note(peer, "the client's frame could not be read")
			return
		}
		if !frame.masked { peer_note(peer, "a client frame was not masked") }
		switch frame.opcode {
		case OP_CLOSE:
			peer_note(peer, fmt.tprintf("the client closed with %d", int(peer_close_code(buffer[:frame.length]))))
			peer_frame_send(socket, OP_CLOSE, true, buffer[:frame.length])
			return
		case OP_PING:
			peer_frame_send(socket, OP_PONG, true, buffer[:frame.length])
		case OP_PONG:
		// The answer to a ping this case sent. Nothing is done with it.
		case OP_TEXT, OP_BINARY:
			message := string(buffer[:frame.length])
			switch message {
			case "echo":
				peer_frame_send(socket, OP_TEXT, true, buffer[:frame.length])
			case "binary":
				peer_frame_send(socket, OP_BINARY, true, buffer[:frame.length])
			case "fragmented":
				peer_frame_send(socket, OP_TEXT, false, transmute([]u8)string("frag"))
				peer_frame_send(socket, OP_CONTINUATION, true, transmute([]u8)string("mented"))
			case "large":
				peer_send_large(peer, socket)
			case "ping":
				peer_frame_send(socket, OP_PING, true, transmute([]u8)string("are you there"))
				peer_frame_send(socket, OP_TEXT, true, transmute([]u8)string("pong"))
			case "close":
				// An orderly close: the peer closes first and the client answers it.
				closing := [2]u8{0x03, 0xe8}
				peer_frame_send(socket, OP_CLOSE, true, closing[:])
				answer, answered := peer_frame_read(socket, buffer)
				if !answered {
					peer_note(peer, "the close went unanswered")
					return
				}
				if answer.opcode != OP_CLOSE {
					peer_note(peer, "the close was answered with a data frame")
					return
				}
				peer_note(peer, fmt.tprintf("the client closed with %d", int(peer_close_code(buffer[:answer.length]))))
				return
			case:
				peer_note(peer, fmt.tprintf("the client sent %q, which no case asked for", message))
			}
		case:
			peer_note(peer, fmt.tprintf("the client sent opcode %d", int(frame.opcode)))
		}
	}
}

// A frame the client must refuse, followed by the close it should answer with.
@(private)
peer_case_refuses :: proc(peer: ^Peer, socket: net.TCP_Socket, what: string, masked: bool) {
	if !peer_handshake(peer, socket, accept_key = true) { return }
	payload := make([]u8, masked ? 6 : 256, peer.allocator)
	defer delete(payload, peer.allocator)
	for octet, index in payload { payload[index] = u8('a' + index % 26) }
	violation := peer_frame_bytes(masked ? OP_TEXT : OP_PING, true, payload, masked, peer.allocator)
	defer delete(violation, peer.allocator)
	if !peer_write_all(socket, violation) { return }

	frame, read_ok := peer_frame_read(socket, peer.buffer)
	if !read_ok {
		peer_note(peer, fmt.tprintf("%s went unanswered", what))
		return
	}
	if frame.opcode != OP_CLOSE {
		peer_note(peer, fmt.tprintf("%s was answered with opcode %d", what, int(frame.opcode)))
		return
	}
	peer_note(peer, fmt.tprintf("%s was closed with %d", what, int(peer_close_code(peer.buffer[:frame.length]))))
	peer_frame_send(socket, OP_CLOSE, true, peer.buffer[:frame.length])
}

// The response head and the first frame go out in one write, so they can arrive in one
// segment, which is the case the client's pending buffer exists for.
@(private)
peer_case_immediate :: proc(peer: ^Peer, socket: net.TCP_Socket) {
	answer, answered := peer_read_and_answer(peer, socket)
	if !answered { return }
	defer delete(answer, peer.allocator)
	head := peer_head_text(answer, peer.allocator)
	defer delete(head, peer.allocator)
	frame := peer_frame_bytes(OP_TEXT, true, transmute([]u8)string("immediate"), false, peer.allocator)
	defer delete(frame, peer.allocator)

	response := make([dynamic]u8, 0, len(head) + len(frame), peer.allocator)
	defer delete(response)
	append(&response, ..transmute([]u8)head)
	append(&response, ..frame)
	if !peer_write_all(socket, response[:]) { return }
	peer_note(peer, "a frame was sent with the response head")
}

@(private)
peer_send_large :: proc(peer: ^Peer, socket: net.TCP_Socket) {
	chunk := make([]u8, 33_334, peer.allocator)
	defer delete(chunk, peer.allocator)
	for octet, index in chunk { chunk[index] = u8('a') }
	remaining := LARGE_MESSAGE
	first := true
	for remaining > 0 {
		count := min(remaining, len(chunk))
		remaining -= count
		opcode := u8(OP_TEXT)
		if !first { opcode = OP_CONTINUATION }
		peer_frame_send(socket, opcode, remaining == 0, chunk[:count])
		first = false
	}
}

// --- the handshake ------------------------------------------------------------

@(private)
peer_handshake :: proc(peer: ^Peer, socket: net.TCP_Socket, accept_key: bool) -> bool {
	answer, answered := peer_read_and_answer(peer, socket)
	if !answered { return false }
	defer delete(answer, peer.allocator)
	if !accept_key {
		wrong := peer_accept_key("a key this client never sent", peer.allocator)
		defer delete(wrong, peer.allocator)
		head := peer_head_text(wrong, peer.allocator)
		defer delete(head, peer.allocator)
		if !peer_write_all(socket, transmute([]u8)head) { return false }
		peer_note(peer, "the response answered a different key")
		return true
	}
	head := peer_head_text(answer, peer.allocator)
	defer delete(head, peer.allocator)
	if !peer_write_all(socket, transmute([]u8)head) { return false }
	peer_note(peer, "the handshake was answered")
	return true
}

// peer_read_and_answer reads the request head and computes the answer its key asks for.
@(private)
peer_read_and_answer :: proc(peer: ^Peer, socket: net.TCP_Socket) -> (answer: string, ok: bool) {
	request: [4096]u8
	head, read_ok := peer_read_head(socket, request[:])
	if !read_ok {
		peer_note(peer, "the handshake request could not be read")
		return "", false
	}
	key, has_key := peer_head_field(head, "sec-websocket-key")
	if !has_key || key == "" {
		peer_note(peer, "the handshake carried no key")
		return "", false
	}
	return peer_accept_key(key, peer.allocator), true
}

@(private)
peer_head_text :: proc(accept: string, allocator: mem.Allocator) -> string {
	return fmt.aprintf(
		"HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: %s\r\n\r\n",
		accept,
		allocator = allocator,
	)
}

@(private)
peer_accept_key :: proc(key: string, allocator: mem.Allocator) -> string {
	guid := GUID
	sha_context: sha1.Context
	sha1.init(&sha_context)
	sha1.update(&sha_context, transmute([]u8)key)
	sha1.update(&sha_context, transmute([]u8)guid)
	digest: [sha1.DIGEST_SIZE]u8
	sha1.final(&sha_context, digest[:])
	return base64.encode(digest[:], allocator = allocator)
}

// peer_head_field reads one field of a request head. A field name is not case-sensitive
// (RFC 9110 5.1).
@(private)
peer_head_field :: proc(head: string, name: string) -> (value: string, found: bool) {
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

// --- framing ------------------------------------------------------------------

@(private)
Frame :: struct {
	opcode: u8,
	final:  bool,
	masked: bool,
	length: int,
}

// peer_frame_read reads one whole frame, unmasking its payload in place. A payload larger
// than the buffer is refused rather than truncated.
@(private)
peer_frame_read :: proc(socket: net.TCP_Socket, payload: []u8) -> (frame: Frame, ok: bool) {
	head: [10]u8
	if !peer_read_exact(socket, head[:2]) { return {}, false }
	frame.final = head[0] & 0x80 != 0
	frame.opcode = head[0] & 0x0f
	frame.masked = head[1] & 0x80 != 0
	frame.length = int(head[1] & 0x7f)
	switch frame.length {
	case 126:
		if !peer_read_exact(socket, head[:2]) { return {}, false }
		frame.length = int(u16(head[0]) << 8 | u16(head[1]))
	case 127:
		if !peer_read_exact(socket, head[:8]) { return {}, false }
		frame.length = 0
		for octet in head[:8] { frame.length = frame.length << 8 | int(octet) }
	}
	if frame.length > len(payload) { return {}, false }
	mask: [4]u8
	if frame.masked && !peer_read_exact(socket, mask[:]) { return {}, false }
	if frame.length > 0 {
		if !peer_read_exact(socket, payload[:frame.length]) { return {}, false }
		if frame.masked {
			for octet, index in payload[:frame.length] { payload[index] = octet ~ mask[index % 4] }
		}
	}
	return frame, true
}

@(private)
peer_frame_send :: proc(socket: net.TCP_Socket, opcode: u8, final: bool, payload: []u8) -> bool {
	encoded := peer_frame_bytes(opcode, final, payload, false, context.temp_allocator)
	return peer_write_all(socket, encoded)
}

// peer_frame_bytes states one frame as the octets of it. A server does not mask, so masked
// is only ever set for a frame a case sends to be refused.
@(private)
peer_frame_bytes :: proc(opcode: u8, final: bool, payload: []u8, masked: bool, allocator: mem.Allocator) -> []u8 {
	head: [14]u8
	head[0] = opcode
	if final { head[0] |= 0x80 }
	mask: [4]u8
	if masked {
		head[1] = 0x80
		for octet, index in mask { mask[index] = u8(index + 1) }
	}
	count := 2
	switch {
	case len(payload) < 126:
		head[1] |= u8(len(payload))
	case len(payload) < 65536:
		head[1] |= 126
		head[2] = u8(len(payload) >> 8)
		head[3] = u8(len(payload) & 0xff)
		count = 4
	case:
		head[1] |= 127
		for index in 0 ..< 8 { head[2 + index] = u8(len(payload) >> uint(8 * (7 - index))) }
		count = 10
	}
	if masked {
		copy(head[count:count + 4], mask[:])
		count += 4
	}
	frame := make([]u8, count + len(payload), allocator)
	copy(frame[:count], head[:count])
	for octet, index in payload {
		frame[count + index] = masked ? octet ~ mask[index % 4] : octet
	}
	return frame
}

@(private)
peer_close_code :: proc(payload: []u8) -> u16 {
	if len(payload) < 2 { return 0 }
	return u16(payload[0]) << 8 | u16(payload[1])
}

// --- bytes on the socket ------------------------------------------------------

@(private)
peer_write_all :: proc(socket: net.TCP_Socket, data: []u8) -> bool {
	pending := data
	for len(pending) > 0 {
		written, write_err := net.send_tcp(socket, pending)
		if write_err != nil || written <= 0 { return false }
		pending = pending[written:]
	}
	return true
}

@(private)
peer_read_exact :: proc(socket: net.TCP_Socket, dst: []u8) -> bool {
	filled := 0
	for filled < len(dst) {
		count, read_err := net.recv_tcp(socket, dst[filled:])
		if read_err != nil || count <= 0 { return false }
		filled += count
	}
	return true
}

@(private)
peer_read_head :: proc(socket: net.TCP_Socket, buffer: []u8) -> (head: string, ok: bool) {
	filled := 0
	for filled < len(buffer) {
		count, read_err := net.recv_tcp(socket, buffer[filled:])
		if read_err != nil || count <= 0 { return "", false }
		filled += count
		if marker := strings.index(string(buffer[:filled]), "\r\n\r\n"); marker >= 0 {
			return string(buffer[:marker]), true
		}
	}
	return "", false
}
