#+build linux
package main

// Runs one real HTTPS request through http/client and the tls package together,
// against `openssl s_server`.
//
// It is an executable harness rather than an in-package @(test) suite because the
// server is a child process. What it checks is the seam: the connection's TLS
// wiring, the transfer phases a caller observes, and that a response body arrives
// intact over a connection the tls package established. Run by scripts/test.

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"

import "nabla:http"
import "nabla:http/client"

DIRECTORY :: "/tmp/nabla-http-tls-handshake"
CERTIFICATE_FILE :: "certificate.pem"
KEY_FILE :: "key.pem"
SERVER_STARTUP_TIMEOUT :: 10 * time.Second

failures: int
response_body: [64 * 1024]u8
response_length: int

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

	port, port_ok := free_port()
	if !check(port_ok, "no free port could be found") { os.exit(1) }

	server, server_ok := start_server(port)
	if !check(server_ok, "openssl s_server could not be started") { os.exit(1) }

	run_request(port)

	// -naccept 1 makes the server leave once it has answered.
	if _, wait_err := os.process_wait(server, 10 * time.Second); wait_err != nil {
		check(false, fmt.tprintf("the server could not be reaped: %v", wait_err))
	}

	if failures > 0 { os.exit(1) }
	fmt.println("ok: an HTTPS request completed through the tls package")
}

run_request :: proc(port: int) {
	options := client.Options {
		ca_file = strings.concatenate({DIRECTORY, "/", CERTIFICATE_FILE}),
	}
	defer delete(options.ca_file)

	summary: client.Transfer_Summary
	options.observer = {
		user_data = &summary,
		complete  = observe,
	}

	options.probe = {
		check = keep_going,
	}

	request := client.Request {
		url       = fmt.aprintf("https://localhost:%d/", port, allocator = context.allocator),
		method    = .Get,
		allocator = context.allocator,
	}
	defer delete(request.url)

	// The server needs a moment to listen, and a connection attempt is the only way
	// to find out: a refused one is retried, and anything else is the answer.
	failure: client.Failure
	deadline := time.tick_add(time.tick_now(), SERVER_STARTUP_TIMEOUT)
	for {
		failure = client.stream_request(request, options, nil, collect)
		if failure.kind == .None || failure.cause != .Connect { break }
		client.failure_destroy(&failure, context.allocator)
		response_length = 0
		summary = {}
		if time.tick_since(deadline) >= 0 { break }
		time.sleep(20 * time.Millisecond)
	}
	defer client.failure_destroy(&failure, context.allocator)
	if !check(failure.kind == .None, fmt.tprintf("the request failed: %v %s", failure.kind, failure.detail)) { return }

	check(summary.status == 200, fmt.tprintf("the response status was %v", summary.status))
	check(response_length > 0, "no response body arrived")
	// The page s_server answers with is HTML, and a body that survived the
	// connection intact still says so.
	check(strings.contains(string(response_body[:response_length]), "HTML"), "the response body is not the page the server sends")
	check(summary.stopped_at == .Complete, "the transfer did not complete")
	check(summary.response_head_received, "the response head was not observed")
	check(summary.request_complete, "the request was not written whole")
}

keep_going :: proc(_: rawptr) -> client.Wait_Status {
	return .Ready
}

collect :: proc(user_data: rawptr, chunk: []u8) {
	room := len(response_body) - response_length
	if room <= 0 { return }
	count := min(room, len(chunk))
	copy(response_body[response_length:], chunk[:count])
	response_length += count
}

observe :: proc(user_data: rawptr, summary: client.Transfer_Summary) {
	observed := cast(^client.Transfer_Summary)user_data
	observed^ = summary
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

start_server :: proc(port: int) -> (os.Process, bool) {
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
				"-alpn",
				"http/1.1",
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
