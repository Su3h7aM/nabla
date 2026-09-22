#+test
package tls

// Interop coverage against a real TLS 1.3 server, once for each way the peer
// can make this client work: suite choice, HelloRetryRequest groups, and
// optional client authentication. A handshake that completes here says the
// driver agrees with something other than this repository, which no
// self-consistent vector can. The server is `openssl s_server`, so this test
// needs it installed; it runs the six peers sequentially through one
// certificate in a per-test directory.

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

INTEROP_REQUEST: string : "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n"
INTEROP_ALPN :: "http/1.1"
INTEROP_STARTUP_TIMEOUT :: 10 * time.Second
INTEROP_ATTEMPTS :: 3

// Interop_Peer is one way of running the server. A server restricted to one
// suite has to choose it, so the client's adoption of the server's choice is
// part of what this test checks. A server restricted to one group answers a
// key share for another with a HelloRetryRequest, and secp256r1 is the group
// this client offers without sending a share for it, so that case only
// completes when the retry is answered.
Interop_Peer :: struct {
	openssl_suite:       string,
	openssl_group:       string,
	suite:               Cipher_Suite,
	request_certificate: bool,
}

INTEROP_PEERS := [?]Interop_Peer {
	{"TLS_AES_128_GCM_SHA256", "X25519", .AES_128_GCM_SHA256, false},
	{"TLS_CHACHA20_POLY1305_SHA256", "X25519", .CHACHA20_POLY1305_SHA256, false},
	{"TLS_AES_256_GCM_SHA384", "X25519", .AES_256_GCM_SHA384, false},
	{"TLS_AES_128_GCM_SHA256", "P-256", .AES_128_GCM_SHA256, false},
	{"TLS_AES_256_GCM_SHA384", "P-256", .AES_256_GCM_SHA384, false},
	{"TLS_AES_128_GCM_SHA256", "X25519", .AES_128_GCM_SHA256, true},
}

Interop_Connection :: struct {
	socket: net.TCP_Socket,
}

interop_connection_read :: proc(user_data: rawptr, buffer: []u8) -> (count: int, ok: bool) {
	connection := cast(^Interop_Connection)user_data
	read, err := net.recv_tcp(connection.socket, buffer)
	return read, err == nil && read > 0
}

interop_connection_write :: proc(user_data: rawptr, buffer: []u8) -> (count: int, ok: bool) {
	connection := cast(^Interop_Connection)user_data
	written, err := net.send_tcp(connection.socket, buffer)
	return written, err == nil
}

// Interop_Server owns one `openssl s_server` child. Stopping kills what is
// left and reaps it, so a failed peer cannot leak a server into the next one.
Interop_Server :: struct {
	process: os.Process,
	running: bool,
}

interop_server_stop :: proc(t: ^testing.T, server: ^Interop_Server) {
	if !server.running { return }
	server.running = false
	_ = os.process_kill(server.process)
	_, wait_err := os.process_wait(server.process, 10 * time.Second)
	testing.expect(t, wait_err == nil, "the server could not be reaped")
}

@(test)
test_tls_handshake_completes_against_openssl :: proc(t: ^testing.T) {
	directory, directory_err := os.make_directory_temp("", "nabla-tls-handshake-*", context.allocator)
	if directory_err != nil { testing.fail_now(t, "the temporary directory could not be made") }
	defer {
		os.remove_all(directory)
		delete(directory, context.allocator)
	}

	if !interop_generate_certificate(t, directory) { return }

	for peer in INTEROP_PEERS {
		// ponytail: the chacha20-poly1305 peer is release-only until the
		// toolchain fixes core:crypto/chacha20poly1305 miscompiling inputs
		// of 64 bytes and up at -o:none (the debug configuration). The other
		// five peers run in both modes, and release still checks chacha20
		// against openssl. Re-enable unconditionally once `odin test` with
		// -o:none passes a 64-byte chacha20poly1305 round trip.
		when ODIN_DEBUG {
			if peer.suite == .CHACHA20_POLY1305_SHA256 { continue }
		}
		// A freed port can be rebound before the server takes it under a
		// parallel run, so a peer that never starts listening is retried
		// with a fresh port rather than reported.
		served := false
		for _ in 0 ..< INTEROP_ATTEMPTS {
			if interop_run_peer(t, directory, peer) {
				served = true
				break
			}
		}
		testing.expect(t, served, "the peer never became reachable")
	}
}

// interop_run_peer serves one peer and runs the client against it. False means
// the peer never became reachable, which the caller retries; a reachable peer
// whose handshake misbehaves fails the test outright.
interop_run_peer :: proc(t: ^testing.T, directory: string, peer: Interop_Peer) -> bool {
	port, port_ok := interop_free_port()
	if !port_ok { return false }

	server := Interop_Server{}
	if !interop_start_server(&server, directory, port, peer) { return false }
	defer interop_server_stop(t, &server)

	endpoint := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = port,
	}
	socket, dial_ok := interop_dial_when_listening(endpoint)
	if !dial_ok { return false }
	defer net.close(socket)

	interop_run_client(t, directory, socket, peer)
	return true
}

interop_run_client :: proc(t: ^testing.T, directory: string, socket: net.TCP_Socket, expected: Interop_Peer) {
	roots_text, read_err := os.read_entire_file(strings.concatenate({directory, "/certificate.pem"}, context.temp_allocator), context.allocator)
	defer delete(roots_text)
	if !testing.expect(t, read_err == nil, "the server certificate could not be read") { return }

	roots, roots_ok := roots_parse(roots_text, context.allocator)
	defer roots_destroy(&roots)
	if !testing.expect(t, roots_ok, "the server certificate is not a trust store") { return }

	anchors := certificate_pointers(roots.certificates, context.allocator)
	defer delete(anchors, context.allocator)

	connection := Interop_Connection {
		socket = socket,
	}
	conn, init_err := init(
		{read = interop_connection_read, write = interop_connection_write, user_data = &connection},
		{roots = anchors, allocator = context.allocator},
	)
	if !testing.expect_value(t, init_err, Error.None) { return }
	defer destroy(conn)

	if err := handshake(conn, "localhost", []string{INTEROP_ALPN}); err != Error.None {
		testing.expect(
			t,
			false,
			fmt.tprintf(
				"the handshake with %s over %s failed: %v (peer alert %v, certificate requested %v)",
				expected.openssl_suite,
				expected.openssl_group,
				err,
				conn.peer_alert,
				conn.certificate_requested,
			),
		)
		return
	}
	testing.expect(t, conn.alpn == INTEROP_ALPN, "the server did not select the protocol the client offered")
	// The server picks the suite, and the connection has to be the one it picked.
	testing.expect_value(t, conn.suite, expected.suite)

	written, write_err := write(conn, transmute([]u8)INTEROP_REQUEST)
	testing.expect(t, write_err == Error.None && written == len(INTEROP_REQUEST), "the request was not written whole")

	// The server answers a page, and its first record carries the head of it.
	response: [16 * 1024]u8
	received, read_response_err := read(conn, response[:])
	if !testing.expect(
		t,
		read_response_err == Error.None,
		fmt.tprintf("the response could not be read: %v after %v bytes, peer alert %v", read_response_err, received, conn.peer_alert),
	) { return }
	testing.expect(t, strings.has_prefix(string(response[:received]), "HTTP/1."), "the response does not begin with an HTTP status line")
	testing.expect_value(t, close(conn), Error.None)
}

interop_generate_certificate :: proc(t: ^testing.T, directory: string) -> bool {
	state, cert_out, cert_err, err := os.process_exec(
		{
			working_dir = directory,
			command = {
				"openssl",
				"req",
				"-x509",
				"-newkey",
				"rsa:2048",
				"-keyout",
				"key.pem",
				"-out",
				"certificate.pem",
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
	defer delete(cert_out)
	defer delete(cert_err)
	if err != nil || state.exit_code != 0 {
		testing.fail_now(t, "openssl could not make a certificate")
	}
	return true
}

interop_start_server :: proc(server: ^Interop_Server, directory: string, port: int, peer: Interop_Peer) -> bool {
	command := make([dynamic]string, 0, 24, context.temp_allocator)
	append(
		&command,
		"openssl",
		"s_server",
		"-accept",
		fmt.tprintf("127.0.0.1:%d", port),
		"-cert",
		"certificate.pem",
		"-key",
		"key.pem",
		"-tls1_3",
		"-ciphersuites",
		peer.openssl_suite,
		"-groups",
		peer.openssl_group,
		"-alpn",
		INTEROP_ALPN,
		"-www",
		"-naccept",
		"1",
	)
	if peer.request_certificate { append(&command, "-verify", "1") }

	process, err := os.process_start({working_dir = directory, command = command[:]})
	if err != nil { return false }
	server.process = process
	server.running = true
	return true
}

// interop_free_port asks the kernel for a port and gives it back, which is the one way to
// pick a port that is not already in use.
interop_free_port :: proc() -> (port: int, ok: bool) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	if listen_err != nil { return 0, false }
	defer net.close(listener)
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if endpoint_err != nil { return 0, false }
	return endpoint.port, true
}

// The server needs a moment to listen, and there is nothing to wait on but the
// connection itself.
interop_dial_when_listening :: proc(endpoint: net.Endpoint) -> (net.TCP_Socket, bool) {
	deadline := time.tick_add(time.tick_now(), INTEROP_STARTUP_TIMEOUT)
	for {
		socket, err := net.dial_tcp_from_endpoint(endpoint)
		if err == nil { return socket, true }
		if time.tick_since(deadline) >= 0 { return 0, false }
		time.sleep(20 * time.Millisecond)
	}
}
