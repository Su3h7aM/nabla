#+build linux
package main

// Hands the tls package to a real TLS 1.3 server and asks for a page over it, once
// for each way the peer can make this client work for the handshake.
//
// This is an executable harness rather than an in-package @(test) suite because it
// forks: the server is `openssl s_server`, an independent implementation, so a
// handshake that completes here says the driver agrees with something other than
// this repository. Run by scripts/test.

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"

import "nabla:tls"

DIRECTORY :: "/tmp/nabla-tls-handshake"
CERTIFICATE_FILE :: "certificate.pem"
KEY_FILE :: "key.pem"
REQUEST : string : "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n"
ALPN :: "http/1.1"
SERVER_STARTUP_TIMEOUT :: 10 * time.Second

// Peer is one way of running the server. A server restricted to one suite has to choose
// it, so the client's adoption of the server's choice is part of what this harness
// checks. A server restricted to one group answers a key share for another with a
// HelloRetryRequest, and secp256r1 is the group this client offers without sending a
// share for it, so that case only completes when the retry is answered.
Peer :: struct {
	openssl_suite: string,
	openssl_group: string,
	suite:         tls.Cipher_Suite,
}

PEERS := [?]Peer {
	{"TLS_AES_128_GCM_SHA256", "X25519", .AES_128_GCM_SHA256},
	{"TLS_CHACHA20_POLY1305_SHA256", "X25519", .CHACHA20_POLY1305_SHA256},
	{"TLS_AES_256_GCM_SHA384", "X25519", .AES_256_GCM_SHA384},
	{"TLS_AES_128_GCM_SHA256", "P-256", .AES_128_GCM_SHA256},
	{"TLS_AES_256_GCM_SHA384", "P-256", .AES_256_GCM_SHA384},
}

Connection :: struct {
	socket: net.TCP_Socket,
}

connection_read :: proc(user_data: rawptr, buffer: []u8) -> (count: int, ok: bool) {
	connection := cast(^Connection)user_data
	read, err := net.recv_tcp(connection.socket, buffer)
	return read, err == nil && read > 0
}

connection_write :: proc(user_data: rawptr, buffer: []u8) -> (count: int, ok: bool) {
	connection := cast(^Connection)user_data
	written, err := net.send_tcp(connection.socket, buffer)
	return written, err == nil
}

failures: int

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

	if !check(generate_certificate(), "openssl could not make a certificate") { os.exit(1) }

	for peer in PEERS {
		port, port_ok := free_port()
		if !check(port_ok, "no free port could be found") { os.exit(1) }

		server, server_ok := start_server(port, peer.openssl_suite, peer.openssl_group)
		if !check(server_ok, "openssl s_server could not be started") { os.exit(1) }

		run_client(port, peer)

		// -naccept 1 makes the server leave after the connection it served, so waiting
		// for it reaps it and says it saw us.
		state, wait_err := os.process_wait(server, 10 * time.Second)
		if wait_err != nil || state.exit_code != 0 {
			check(false, fmt.tprintf("the server for %s over %s left with an error", peer.openssl_suite, peer.openssl_group))
			if wait_err != nil { fmt.eprintfln("  wait: %v", wait_err) }
		}
	}

	if failures > 0 { os.exit(1) }
	fmt.println("ok: the handshake completed against openssl s_server, for every suite and group")
}

run_client :: proc(port: int, expected: Peer) {
	roots_text, read_err := os.read_entire_file(
		strings.concatenate({DIRECTORY, "/", CERTIFICATE_FILE}),
		context.allocator,
	)
	defer delete(roots_text)
	if !check(read_err == nil, "the server certificate could not be read") { return }

	roots, roots_ok := tls.roots_parse(roots_text, context.allocator)
	defer tls.roots_destroy(&roots)
	if !check(roots_ok, "the server certificate is not a trust store") { return }

	anchors := tls.certificate_pointers(roots.certificates, context.allocator)
	defer delete(anchors, context.allocator)

	endpoint := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = port,
	}
	socket, dial_ok := dial_when_listening(endpoint)
	if !check(dial_ok, "the server never accepted a connection") { return }
	defer net.close(socket)

	connection := Connection{socket = socket}
	conn, init_err := tls.init(
		{read = connection_read, write = connection_write, user_data = &connection},
		{roots = anchors, allocator = context.allocator},
	)
	if !check(init_err == tls.Error.None, "the connection could not be prepared") { return }
	defer tls.destroy(conn)

	if err := tls.handshake(conn, "localhost", []string{ALPN}); err != tls.Error.None {
		check(false, fmt.tprintf("the handshake with %s over %s failed: %v (peer alert %v)", expected.openssl_suite, expected.openssl_group, err, conn.peer_alert))
		return
	}
	check(conn.alpn == ALPN, "the server did not select the protocol the client offered")
	// The server picks the suite, and the connection has to be the one it picked.
	check(conn.suite == expected.suite, fmt.tprintf("the connection is not the %s the server chose", expected.openssl_suite))

	written, write_err := tls.write(conn, transmute([]u8)REQUEST)
	check(write_err == tls.Error.None && written == len(REQUEST), "the request was not written whole")

	// The server answers a page, and its first record carries the head of it.
	response: [16 * 1024]u8
	received, read_response_err := tls.read(conn, response[:])
	if !check(read_response_err == tls.Error.None, fmt.tprintf("the response could not be read: %v after %v bytes, peer alert %v", read_response_err, received, conn.peer_alert)) { return }
	check(
		strings.has_prefix(string(response[:received]), "HTTP/1."),
		"the response does not begin with an HTTP status line",
	)
	check(tls.close(conn) == tls.Error.None, "the connection could not be closed")
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

start_server :: proc(port: int, suite: string, group: string) -> (os.Process, bool) {
	process, err := os.process_start(
		{
			working_dir = DIRECTORY,
			command = {
				"openssl",
				"s_server",
				"-accept",
				fmt.tprintf("127.0.0.1:%d", port),
				"-cert",
				CERTIFICATE_FILE,
				"-key",
				KEY_FILE,
				"-tls1_3",
				"-ciphersuites",
				suite,
				"-groups",
				group,
				"-alpn",
				ALPN,
				"-www",
				"-naccept",
				"1",
			},
		},
	)
	return process, err == nil
}

// free_port asks the kernel for a port and gives it back, which is the one way to
// pick a port that is not already in use.
free_port :: proc() -> (port: int, ok: bool) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	if listen_err != nil { return 0, false }
	defer net.close(listener)
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if endpoint_err != nil { return 0, false }
	return endpoint.port, true
}

// The server needs a moment to listen, and there is nothing to wait on but the
// connection itself.
dial_when_listening :: proc(endpoint: net.Endpoint) -> (net.TCP_Socket, bool) {
	deadline := time.tick_add(time.tick_now(), SERVER_STARTUP_TIMEOUT)
	for {
		socket, err := net.dial_tcp_from_endpoint(endpoint)
		if err == nil { return socket, true }
		if time.tick_since(deadline) >= 0 { return 0, false }
		time.sleep(20 * time.Millisecond)
	}
}
