#+build linux
package main

// Runs real WebSocket connections over ws against the scripted peer in peer.odin, which
// frames the protocol itself rather than borrowing this package's encoder.
//
// It is an executable harness rather than an in-package @(test) suite because the peer is a
// second thread holding a socket. What it checks is the seam a byte fixture cannot reach:
// the Upgrade exchange through http/client over a real socket, a frame that arrives in the
// same segment as the response head, a response that does not accept the key, and the two
// frames a server may not send. Message framing, fragmentation and control frames are
// covered by this package's own byte fixtures. Run by scripts/test.

import "core:fmt"
import "core:os"
import "core:time"
import "nabla:http/client"
import "nabla:websocket"

CASE_TIMEOUT :: 30 * time.Second

failures: int
message_buffer: [256 * 1024]u8
// case_deadline ends the case in progress, so a peer that stops answering fails the harness
// instead of hanging it. It outlives the connection that reads it.
case_deadline: time.Tick

check :: proc(ok: bool, what: string) -> bool {
	if !ok {
		fmt.eprintfln("FAIL %s", what)
		failures += 1
	}
	return ok
}

main :: proc() {
	peer: Peer
	if !check(peer_start(&peer), "the peer could not be started") { os.exit(1) }
	defer peer_destroy(&peer)

	run_message_cases(peer.port)
	run_immediate_case(peer.port)
	run_rejected_key_case(peer.port)
	run_protocol_violation_case(peer.port, "a masked frame from the server")
	run_protocol_violation_case(peer.port, "a control frame over 125 octets")

	peer_wait(&peer)
	check(peer_saw(&peer, "the handshake was answered"), "the peer never answered a handshake")
	check(peer_saw(&peer, "the client closed with 1000"), "the client's close did not carry code 1000")
	check(peer_saw(&peer, "a masked frame from the server was closed with 1002"), "a masked frame was not refused as a protocol error")
	check(peer_saw(&peer, "a control frame over 125 octets was closed with 1002"), "an oversized control frame was not refused as a protocol error")
	check(!peer_saw(&peer, "a client frame was not masked"), "the client sent an unmasked frame")

	if failures > 0 { os.exit(1) }
	fmt.println("ok: WebSocket connections opened, upgraded, and refused what a server may not send")
}

// open dials the peer, which is listening before the first case runs.
open :: proc(port: int, path: string) -> (conn: ^websocket.Conn, failure: websocket.Dial_Failure) {
	url := fmt.aprintf("ws://localhost:%d%s", port, path)
	defer delete(url)
	case_deadline = time.tick_add(time.tick_now(), CASE_TIMEOUT)
	return websocket.dial(url, {http = {probe = {check = keep_going}}})
}

// keep_going ends a case that has stalled.
keep_going :: proc(_: rawptr) -> client.Wait_Status {
	if time.tick_since(case_deadline) >= 0 { return .Timed_Out }
	return .Ready
}

// The message cases run on one connection, in the order the peer's script expects.
run_message_cases :: proc(port: int) {
	conn, failure := open(port, "/")
	if !check(failure.kind == .None, fmt.tprintf("ws did not open: %v %s", failure.kind, failure.detail)) {
		websocket.dial_failure_destroy(&failure, context.allocator)
		return
	}
	defer websocket.destroy(conn)

	send(conn, .Text, "echo")
	expect_message(conn, .Text, "echo")
	send(conn, .Binary, "binary")
	expect_message(conn, .Binary, "binary")

	// A message the peer sends as two frames, so the first read ends nothing.
	send(conn, .Text, "fragmented")
	length := 0
	count, _, complete, err := websocket.read(conn, message_buffer[:])
	if check(err == .None, fmt.tprintf("the first fragment failed: %v", err)) {
		length += count
		check(!complete, "the first fragment ended the message")
		count, _, complete, err = websocket.read(conn, message_buffer[length:])
		if check(err == .None, fmt.tprintf("the last fragment failed: %v", err)) {
			length += count
			check(complete, "the last fragment did not end the message")
			check(string(message_buffer[:length]) == "fragmented", "the fragments are not the peer's message")
		}
	}

	// A message far larger than one frame, arriving as several.
	send(conn, .Text, "large")
	message, received := receive(conn, .Text)
	if check(received, "the large message could not be read") {
		if check(len(message) == LARGE_MESSAGE, fmt.tprintf("the large message was %d octets", len(message))) {
			content_ok := true
			for octet in transmute([]u8)message { if octet != 'a' { content_ok = false } }
			check(content_ok, "the large message is not what the peer sent")
		}
	}

	// A ping from the peer is answered while the next message is read.
	send(conn, .Text, "ping")
	expect_message(conn, .Text, "pong")

	// An orderly close, with the peer's code and this client's answer to it.
	send(conn, .Text, "close")
	buffer: [1024]u8
	err = .None
	for err == .None { _, _, _, err = websocket.read(conn, buffer[:]) }
	check(err == .Closed, fmt.tprintf("the close read as %v", err))
	check(conn.close_code == .Normal, fmt.tprintf("the peer's close code was %d", u16(conn.close_code)))
	if close_err := websocket.close(conn, .Normal, "", buffer[:]); close_err != websocket.Error.None {
		check(false, fmt.tprintf("the close could not be answered: %v", close_err))
	}
}

// A frame the peer sends in the same segment as its response head belongs to the WebSocket,
// not to the HTTP response, and it must still be the first thing read.
run_immediate_case :: proc(port: int) {
	conn, failure := open(port, "/")
	if !check(failure.kind == .None, fmt.tprintf("the immediate case did not open: %v %s", failure.kind, failure.detail)) {
		websocket.dial_failure_destroy(&failure, context.allocator)
		return
	}
	defer websocket.destroy(conn)
	expect_message(conn, .Text, "immediate")
}

// A response that does not accept the key it was sent is not a WebSocket, so no connection
// may be handed to a caller (RFC 6455 4.1).
run_rejected_key_case :: proc(port: int) {
	conn, failure := open(port, "/")
	defer websocket.dial_failure_destroy(&failure, context.allocator)
	if conn != nil {
		websocket.destroy(conn)
		check(false, "a connection was opened on a response that did not accept the key")
		return
	}
	check(failure.kind == .Response, fmt.tprintf("the rejected key failed as %v %s", failure.kind, failure.detail))
}

run_protocol_violation_case :: proc(port: int, what: string) {
	conn, failure := open(port, "/")
	if !check(failure.kind == .None, fmt.tprintf("%s did not open: %v %s", what, failure.kind, failure.detail)) {
		websocket.dial_failure_destroy(&failure, context.allocator)
		return
	}
	defer websocket.destroy(conn)

	buffer: [1024]u8
	for {
		_, _, _, err := websocket.read(conn, buffer[:])
		if err == .None { continue }
		check(err == .Protocol, fmt.tprintf("%s read as %v", what, err))
		return
	}
}

send :: proc(conn: ^websocket.Conn, opcode: websocket.Opcode, message: string) -> bool {
	err := websocket.write(conn, opcode, transmute([]u8)message)
	return check(err == .None, fmt.tprintf("writing %q failed: %v", message, err))
}

expect_message :: proc(conn: ^websocket.Conn, opcode: websocket.Opcode, expected: string) -> string {
	message, received := receive(conn, opcode)
	if received { check(message == expected, fmt.tprintf("the message is %q, not %q", message, expected)) }
	return message
}

// receive reads one whole message of the given type and reports it, which is an empty string
// when the message failed.
receive :: proc(conn: ^websocket.Conn, opcode: websocket.Opcode) -> (message: string, ok: bool) {
	length := 0
	for {
		count, frame_opcode, complete, err := websocket.read(conn, message_buffer[length:])
		if !check(err == .None, fmt.tprintf("reading a message failed: %v", err)) { return "", false }
		if !check(frame_opcode == opcode, fmt.tprintf("a message of type %v arrived instead of %v", frame_opcode, opcode)) {
			return "", false
		}
		length += count
		if complete { return string(message_buffer[:length]), true }
	}
}
