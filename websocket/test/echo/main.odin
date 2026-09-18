#+build linux
package main

// Runs real WebSockets over ws and over wss against a scripted Python peer, which is a
// second implementation of RFC 6455 rather than this package testing itself.
//
// It is an executable harness rather than an in-package @(test) suite because the peer
// is a child process. What it checks is the seam: the Upgrade handshake through
// http/client, a key the peer does not accept, messages in both directions, client
// fragmentation, a ping in each direction, a close, and the two frames a server may not
// send. Run by scripts/test.

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"

import "nabla:http/client"
import "nabla:websocket"

DIRECTORY :: "/tmp/nabla-websocket-echo"
SERVER_SCRIPT :: "echo_server.py"
CERTIFICATE_FILE :: "certificate.pem"
KEY_FILE :: "key.pem"

// Plain cases: the message cases, a masked frame from the server, an oversized control
// frame, and a response that does not accept the key.
PLAIN_CONNECTIONS :: 4
TLS_CONNECTIONS :: 1

SERVER_STARTUP_TIMEOUT :: 10 * time.Second
CASE_TIMEOUT :: 30 * time.Second

failures: int
message_buffer: [256 * 1024]u8
// case_deadline ends the case in progress, so a peer that stops answering fails the
// harness instead of hanging it. It outlives the connection that reads it.
case_deadline: time.Tick

check :: proc(ok: bool, what: string) -> bool {
	if !ok {
		fmt.eprintfln("FAIL %s", what)
		failures += 1
	}
	return ok
}

main :: proc() {
	os.remove_all(DIRECTORY)
	if err := os.make_directory(DIRECTORY); err != nil {
		fmt.eprintfln("FAIL the temporary directory could not be made: %v", err)
		os.exit(1)
	}
	defer os.remove_all(DIRECTORY)

	if !check(write_server_script(), "the peer script could not be written") { os.exit(1) }
	if !check(generate_certificate(), "openssl could not make a certificate") { os.exit(1) }

	plain_port, secure_port, ports_ok := free_ports()
	if !check(ports_ok, "two free ports could not be found") { os.exit(1) }

	plain, plain_started := start_server(plain_port, PLAIN_CONNECTIONS, false)
	if !check(plain_started, "the plain peer could not be started") { os.exit(1) }
	secure, secure_started := start_server(secure_port, TLS_CONNECTIONS, true)
	if !check(secure_started, "the TLS peer could not be started") { os.exit(1) }

	run_message_cases(plain_port)
	run_masked_case(plain_port)
	run_oversized_control_case(plain_port)
	run_rejected_key_case(plain_port)
	run_tls_cases(secure_port)

	// Each peer leaves once it has served the connections it was asked for, and reports
	// a non-zero status for a violation it saw in this client.
	wait_for_peer(plain)
	wait_for_peer(secure)

	if failures > 0 { os.exit(1) }
	fmt.println("ok: WebSocket messages, control frames, and closes ran over ws and wss")
}

wait_for_peer :: proc(peer: os.Process) {
	state, wait_err := os.process_wait(peer, CASE_TIMEOUT)
	if !check(wait_err == nil, fmt.tprintf("the peer could not be reaped: %v", wait_err)) { return }
	check(state.exit_code == 0, fmt.tprintf("the peer reported exit code %v", state.exit_code))
}

// open dials the peer, retrying while it is not listening yet: a refused connection is
// the only sign that it has not started, and every other outcome is its answer. A
// failure is the caller's to report and to release.
open :: proc(port: int, secure: bool, path: string) -> (conn: ^websocket.Conn, failure: websocket.Dial_Failure) {
	scheme := secure ? "wss" : "ws"
	url := fmt.aprintf("%s://localhost:%d%s", scheme, port, path)
	defer delete(url)

	options := websocket.Dial_Options {
		http = {
			probe = {check = keep_going},
		},
	}
	// The store has to outlive the dial that reads it, so it is released by this
	// procedure rather than by the block that sets it.
	ca_file: string
	defer if ca_file != "" { delete(ca_file) }
	if secure {
		ca_file = strings.concatenate({DIRECTORY, "/", CERTIFICATE_FILE})
		options.http.ca_file = ca_file
	}

	case_deadline = time.tick_add(time.tick_now(), CASE_TIMEOUT)
	startup := time.tick_add(time.tick_now(), SERVER_STARTUP_TIMEOUT)
	for {
		conn, failure = websocket.dial(url, options)
		if failure.kind == .None { return conn, failure }
		if failure.kind != .Exchange || failure.cause != .Connect { return nil, failure }
		websocket.dial_failure_destroy(&failure, context.allocator)
		conn = nil
		if time.tick_since(startup) >= 0 { return nil, failure }
		time.sleep(20 * time.Millisecond)
	}
}

// keep_going ends a case that has stalled, so a peer that stops answering fails the
// harness instead of hanging it.
keep_going :: proc(_: rawptr) -> client.Wait_Status {
	if time.tick_since(case_deadline) >= 0 { return .Timed_Out }
	return .Ready
}

// The message cases run on one connection, in the order the peer's script expects.
run_message_cases :: proc(port: int) {
	conn, failure := open(port, false, "/")
	if !check(failure.kind == .None, fmt.tprintf("ws did not open: %v %s", failure.kind, failure.detail)) {
		websocket.dial_failure_destroy(&failure, context.allocator)
		return
	}
	defer websocket.destroy(conn)

	// A message in each direction, of each type.
	send(conn, .Text, "echo")
	expect_message(conn, .Text, "echo")
	send(conn, .Binary, "binary")
	expect_message(conn, .Binary, "binary")

	// A fragmented message: the peer answers with two frames, so the first read ends
	// nothing and the second ends the message (RFC 6455 section 5.4).
	send(conn, .Text, "fragmented")
	length := 0
	count, _, complete, err := websocket.read(conn, message_buffer[:])
	if check(err == .None, fmt.tprintf("the first fragment failed: %v", err)) {
		length += count
		check(!complete, "the first fragment ended the message")
		check(string(message_buffer[:length]) == "frag", "the first fragment is not the peer's")
		count, _, complete, err = websocket.read(conn, message_buffer[length:])
		if check(err == .None, fmt.tprintf("the last fragment failed: %v", err)) {
			length += count
			check(complete, "the last fragment did not end the message")
			check(string(message_buffer[:length]) == "fragmented", "the fragments are not the peer's message")
		}
	}

	// A message far larger than one frame, and one read.
	send(conn, .Text, "large")
	message, received := receive(conn, .Text)
	check(received && len(message) == 100000, fmt.tprintf("the large message was %d octets", len(message)))

	// A ping this client sends is answered by the peer, and a ping from the peer is
	// answered while a message is read.
	body := "are you there"
	if err := websocket.ping(conn, transmute([]u8)body); err != websocket.Error.None {
		check(false, fmt.tprintf("the ping failed: %v", err))
	}
	send(conn, .Text, "echo")
	expect_message(conn, .Text, "echo")
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

// The frames a server may not send. The peer sends one and describes the close it
// expects, so this client has to send exactly that.
run_masked_case :: proc(port: int) {
	conn, failure := open(port, false, "/")
	if !check(failure.kind == .None, fmt.tprintf("the masked case did not open: %v %s", failure.kind, failure.detail)) {
		websocket.dial_failure_destroy(&failure, context.allocator)
		return
	}
	defer websocket.destroy(conn)

	send(conn, .Text, "masked")
	expect_protocol_failure(conn, "a masked frame from the server")
}

run_oversized_control_case :: proc(port: int) {
	conn, failure := open(port, false, "/")
	if !check(failure.kind == .None, fmt.tprintf("the oversized case did not open: %v %s", failure.kind, failure.detail)) {
		websocket.dial_failure_destroy(&failure, context.allocator)
		return
	}
	defer websocket.destroy(conn)

	send(conn, .Text, "oversized")
	expect_protocol_failure(conn, "a control frame over 125 octets")
}

// A response that does not accept the key it was sent is not a WebSocket, so no
// connection may be handed to a caller (RFC 6455 section 4.1).
run_rejected_key_case :: proc(port: int) {
	conn, failure := open(port, false, "/reject")
	defer websocket.dial_failure_destroy(&failure, context.allocator)
	if conn != nil {
		websocket.destroy(conn)
		check(false, "a connection was opened on a response that did not accept the key")
		return
	}
	check(failure.kind == .Response, fmt.tprintf("the rejected key failed as %v %s", failure.kind, failure.detail))
	check(failure.status == 101, fmt.tprintf("the rejection reported status %d", failure.status))
}

expect_protocol_failure :: proc(conn: ^websocket.Conn, what: string) {
	buffer: [1024]u8
	for {
		_, _, _, err := websocket.read(conn, buffer[:])
		if err == .None { continue }
		check(err == .Protocol, fmt.tprintf("%s read as %v", what, err))
		return
	}
}

run_tls_cases :: proc(port: int) {
	conn, failure := open(port, true, "/")
	if !check(failure.kind == .None, fmt.tprintf("wss did not open: %v %s", failure.kind, failure.detail)) {
		websocket.dial_failure_destroy(&failure, context.allocator)
		return
	}
	defer websocket.destroy(conn)

	send(conn, .Text, "echo")
	expect_message(conn, .Text, "echo")

	send(conn, .Text, "large")
	message, received := receive(conn, .Text)
	check(received && len(message) == 100000, fmt.tprintf("the large message over TLS was %d octets", len(message)))

	send(conn, .Text, "close")
	buffer: [1024]u8
	err := websocket.Error.None
	for err == .None { _, _, _, err = websocket.read(conn, buffer[:]) }
	check(err == .Closed, fmt.tprintf("the close over TLS read as %v", err))
	check(conn.close_code == .Normal, fmt.tprintf("the peer's close code over TLS was %d", u16(conn.close_code)))
}

send :: proc(conn: ^websocket.Conn, opcode: websocket.Opcode, message: string) -> bool {
	err := websocket.write(conn, opcode, transmute([]u8)message)
	return check(err == .None, fmt.tprintf("writing %q failed: %v", message, err))
}

expect_message :: proc(conn: ^websocket.Conn, opcode: websocket.Opcode, expected: string) -> string {
	message, received := receive(conn, opcode)
	if received {
		check(message == expected, fmt.tprintf("the message is %q, not %q", message, expected))
	}
	return message
}

// receive reads one whole message of the given type and reports what arrived, which is
// an empty string when the message failed.
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

write_server_script :: proc() -> bool {
	path := strings.concatenate({DIRECTORY, "/", SERVER_SCRIPT})
	defer delete(path)
	source := SERVER_SOURCE
	return os.write_entire_file(path, transmute([]u8)source) == nil
}

generate_certificate :: proc() -> bool {
	state, _, _, err := os.process_exec(
		{
			working_dir = DIRECTORY,
			command = {
				"openssl",
				"req",
				"-x509",
				"-newkey",
				"rsa:2048",
				"-keyout",
				KEY_FILE,
				"-out",
				CERTIFICATE_FILE,
				"-days",
				"1",
				"-nodes",
				"-subj",
				"/CN=localhost",
				"-addext",
				"subjectAltName=DNS:localhost",
				"-addext",
				"extendedKeyUsage=serverAuth",
			},
		},
		context.allocator,
	)
	return err == nil && state.exit_code == 0
}

start_server :: proc(port: int, connections: int, secure: bool) -> (os.Process, bool) {
	command := [dynamic]string{}
	defer delete(command)
	append(&command, "python3", SERVER_SCRIPT, fmt.tprintf("%d", port), fmt.tprintf("%d", connections))
	if secure { append(&command, CERTIFICATE_FILE, KEY_FILE) }

	// The peer's stderr is left open, so what it found wrong with this client is part
	// of this harness's own output.
	process, err := os.process_start({working_dir = DIRECTORY, command = command[:], stderr = os.stderr})
	return process, err == nil
}

// free_ports asks the kernel for ports and gives them back. Both are held at once so
// that the second cannot be the one the first returned.
free_ports :: proc() -> (first: int, second: int, ok: bool) {
	one, one_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	if one_err != nil { return 0, 0, false }
	defer net.close(one)
	two, two_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	if two_err != nil { return 0, 0, false }
	defer net.close(two)

	first_endpoint, first_err := net.bound_endpoint(one)
	second_endpoint, second_err := net.bound_endpoint(two)
	if first_err != nil || second_err != nil { return 0, 0, false }
	return first_endpoint.port, second_endpoint.port, true
}

// SERVER_SOURCE is the peer, which speaks RFC 6455 itself with nothing but the Python
// standard library, so it shares no code with the package it answers.
SERVER_SOURCE :: `
"""A scripted WebSocket peer for the harness.

It speaks RFC 6455 on a plain socket and on a TLS one, answers each case the harness
asks for, and reports the protocol violations it observes from the client.
"""
import base64
import hashlib
import socket
import ssl
import sys

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
CONTINUATION, TEXT, BINARY, CLOSE, PING, PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA
NORMAL, PROTOCOL_ERROR = 1000, 1002
LARGE_BYTES = 100000

violations = []


def note(what):
    violations.append(what)


def read_exact(conn, count):
    data = bytearray()
    while len(data) < count:
        chunk = conn.recv(count - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    return bytes(data)


def read_frame(conn):
    first, second = read_exact(conn, 2)
    fin = bool(first & 0x80)
    opcode = first & 0x0F
    masked = bool(second & 0x80)
    length = second & 0x7F
    if length == 126:
        length = int.from_bytes(read_exact(conn, 2), "big")
    elif length == 127:
        length = int.from_bytes(read_exact(conn, 8), "big")
    key = read_exact(conn, 4) if masked else b""
    payload = read_exact(conn, length)
    if masked:
        payload = bytes(octet ^ key[at % 4] for at, octet in enumerate(payload))
    return fin, opcode, masked, payload


def send_frame(conn, opcode, payload, fin=True, mask=False):
    header = bytes([(0x80 if fin else 0x00) | opcode])
    length = len(payload)
    mask_bit = 0x80 if mask else 0x00
    if length <= 125:
        header += bytes([mask_bit | length])
    elif length <= 0xFFFF:
        header += bytes([mask_bit | 126]) + length.to_bytes(2, "big")
    else:
        header += bytes([mask_bit | 127]) + length.to_bytes(8, "big")
    if mask:
        key = b"\x37\xfa\x21\x3d"
        header += key
        payload = bytes(octet ^ key[at % 4] for at, octet in enumerate(payload))
    conn.sendall(header + payload)


def handshake(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            return False
        data += chunk
    head, _, _ = data.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    target = lines[0].split(b" ")[1]
    fields = {}
    for line in lines[1:]:
        name, _, value = line.partition(b":")
        fields[name.strip().lower()] = value.strip()
    if fields.get(b"upgrade", b"").lower() != b"websocket":
        note("the request did not ask to upgrade to websocket")
    if fields.get(b"connection", b"").lower() != b"upgrade":
        note("the request did not name the upgrade in its connection field")
    if fields.get(b"sec-websocket-version") != b"13":
        note("the request did not ask for version 13")
    key = fields.get(b"sec-websocket-key")
    if key is None:
        note("the request carried no key")
        return False
    accept = base64.b64encode(hashlib.sha1(key + GUID.encode()).digest())
    if target == b"/reject":
        accept = b"a-key-this-client-never-sent="
    conn.sendall(
        b"HTTP/1.1 101 Switching Protocols\r\n"
        b"upgrade: websocket\r\n"
        b"connection: Upgrade\r\n"
        b"sec-websocket-accept: " + accept + b"\r\n\r\n"
    )
    return target != b"/reject"


def expect_close(conn, code):
    try:
        fin, opcode, masked, payload = read_frame(conn)
    except EOFError:
        note("the client closed the socket without a close frame")
        return
    if not masked:
        note("a client frame was not masked")
    if opcode != CLOSE:
        note("the client sent opcode %d instead of a close frame" % opcode)
        return
    if len(payload) < 2 or int.from_bytes(payload[:2], "big") != code:
        note("the client closed with %r instead of %d" % (payload, code))


def serve(conn):
    if not handshake(conn):
        return
    while True:
        try:
            fin, opcode, masked, payload = read_frame(conn)
        except EOFError:
            return
        if not masked:
            note("a client frame was not masked")
        if opcode == PING:
            send_frame(conn, PONG, payload)
            continue
        if opcode == PONG:
            continue
        if opcode == CLOSE:
            note("the client closed before the case asked it to")
            return
        if opcode == BINARY:
            send_frame(conn, BINARY, payload)
            continue
        if opcode != TEXT:
            note("the client sent opcode %d" % opcode)
            return
        case = payload.decode()
        if case == "echo":
            send_frame(conn, TEXT, payload)
        elif case == "fragmented":
            send_frame(conn, TEXT, b"frag", fin=False)
            send_frame(conn, CONTINUATION, b"mented", fin=True)
        elif case == "large":
            send_frame(conn, TEXT, b"x" * LARGE_BYTES)
        elif case == "ping":
            send_frame(conn, PING, b"are you there")
            fin, opcode, masked, pong = read_frame(conn)
            if opcode != PONG or pong != b"are you there":
                note("the client did not answer the ping with its payload")
            send_frame(conn, TEXT, b"pong")
        elif case == "masked":
            send_frame(conn, TEXT, b"illegal", mask=True)
            expect_close(conn, PROTOCOL_ERROR)
            return
        elif case == "oversized":
            send_frame(conn, PING, b"y" * 200)
            expect_close(conn, PROTOCOL_ERROR)
            return
        elif case == "close":
            send_frame(conn, CLOSE, NORMAL.to_bytes(2, "big"))
            expect_close(conn, NORMAL)
            return
        else:
            note("the harness sent a case this peer does not know: %r" % payload)
            return


def main():
    port = int(sys.argv[1])
    connections = int(sys.argv[2])
    certificate = sys.argv[3] if len(sys.argv) > 3 else None
    key_file = sys.argv[4] if len(sys.argv) > 4 else None

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    listener.listen(1)
    print("listening on %d" % port, flush=True)

    context = None
    if certificate:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certificate, key_file)

    served = 0
    while served < connections:
        conn, _ = listener.accept()
        conn.settimeout(20)
        if context is not None:
            try:
                conn = context.wrap_socket(conn, server_side=True)
            except (ssl.SSLError, OSError) as error:
                note("TLS failed: %s" % error)
                conn.close()
                served += 1
                continue
        try:
            serve(conn)
        except (EOFError, socket.timeout, ConnectionResetError, ssl.SSLError) as error:
            note("the connection ended: %r" % error)
        finally:
            conn.close()
        served += 1

    listener.close()
    for what in violations:
        print("FAIL %s" % what, file=sys.stderr)
    if violations:
        sys.exit(1)
    print("ok: %d connections" % served, flush=True)


main()
`
