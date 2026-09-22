#+test
#+private file
package client

// One real HTTPS request through this client and the tls package together,
// against `openssl s_server`. What it checks is the seam: the connection's
// TLS wiring, the transfer phases a caller observes, and that a response body
// arrives intact over a connection the tls package established. The server is
// `openssl s_server`, so this test needs it installed; it serves one request
// from a per-test directory.

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

HTTPS_STARTUP_TIMEOUT :: 10 * time.Second
HTTPS_ATTEMPTS :: 3

// Https_Body gathers the response body of one request. It is per test: the
// callback appends to it while the request runs.
Https_Body :: struct {
	buffer: [dynamic]u8,
}

// Https_Server owns one `openssl s_server` child. Stopping kills what is left
// and reaps it, so a failed request cannot leak a server into the next attempt.
Https_Server :: struct {
	process: os.Process,
	running: bool,
}

https_server_stop :: proc(t: ^testing.T, server: ^Https_Server) {
	if !server.running { return }
	server.running = false
	_ = os.process_kill(server.process)
	_, wait_err := os.process_wait(server.process, 10 * time.Second)
	testing.expect(t, wait_err == nil, "the server could not be reaped")
}

@(test)
test_https_request_completes_through_tls :: proc(t: ^testing.T) {
	directory, directory_err := os.make_directory_temp("", "nabla-http-tls-*", context.allocator)
	if directory_err != nil { testing.fail_now(t, "the temporary directory could not be made") }
	defer {
		os.remove_all(directory)
		delete(directory, context.allocator)
	}

	if !https_generate_certificate(t, directory) { return }

	// A freed port can be rebound before the server takes it under a parallel
	// run, so a request that never reaches a server is retried with a fresh
	// port rather than reported.
	done := false
	for _ in 0 ..< HTTPS_ATTEMPTS {
		if https_run_request(t, directory) {
			done = true
			break
		}
	}
	testing.expect(t, done, "the request never reached a server")
}

https_run_request :: proc(t: ^testing.T, directory: string) -> bool {
	port, port_ok := https_free_port()
	if !port_ok { return false }

	server := Https_Server{}
	if !https_start_server(&server, directory, port) { return false }
	defer https_server_stop(t, &server)

	options := Options {
		ca_file = strings.concatenate({directory, "/certificate.pem"}, context.allocator),
	}
	defer delete(options.ca_file)

	summary: Transfer_Summary
	options.observer = {
		user_data = &summary,
		complete  = https_observe,
	}
	options.probe = {
		check = https_keep_going,
	}

	request := Request {
		url       = fmt.aprintf("https://localhost:%d/", port, allocator = context.allocator),
		method    = .Get,
		allocator = context.allocator,
	}
	defer delete(request.url)

	body := Https_Body {
		buffer = make([dynamic]u8, 0, 64 * 1024, context.allocator),
	}
	defer delete(body.buffer)

	// The server needs a moment to listen, and a connection attempt is the only way
	// to find out: a refused one is retried, and anything else is the answer.
	failure: Failure
	deadline := time.tick_add(time.tick_now(), HTTPS_STARTUP_TIMEOUT)
	for {
		failure = stream_request(request, options, &body, https_collect)
		if failure.kind == .None || failure.cause != .Connect { break }
		failure_destroy(&failure, context.allocator)
		delete(body.buffer)
		body.buffer = make([dynamic]u8, 0, 64 * 1024, context.allocator)
		summary = {}
		if time.tick_since(deadline) >= 0 { return false }
		time.sleep(20 * time.Millisecond)
	}
	defer failure_destroy(&failure, context.allocator)
	if !testing.expect(t, failure.kind == .None, fmt.tprintf("the request failed: %v %s", failure.kind, failure.detail)) { return true }

	testing.expect_value(t, summary.status, 200)
	testing.expect(t, len(body.buffer) > 0, "no response body arrived")
	// The page s_server answers with is HTML, and a body that survived the
	// connection intact still says so.
	testing.expect(t, strings.contains(string(body.buffer[:]), "HTML"), "the response body is not the page the server sends")
	testing.expect_value(t, summary.stopped_at, Transfer_Phase.Complete)
	testing.expect(t, summary.response_head_received, "the response head was not observed")
	testing.expect(t, summary.request_complete, "the request was not written whole")
	return true
}

https_keep_going :: proc(_: rawptr) -> Wait_Status {
	return .Ready
}

https_collect :: proc(user_data: rawptr, chunk: []u8) {
	body := cast(^Https_Body)user_data
	room := cap(body.buffer) - len(body.buffer)
	if room <= 0 { return }
	count := min(room, len(chunk))
	append(&body.buffer, ..chunk[:count])
}

https_observe :: proc(user_data: rawptr, summary: Transfer_Summary) {
	observed := cast(^Transfer_Summary)user_data
	observed^ = summary
}

https_generate_certificate :: proc(t: ^testing.T, directory: string) -> bool {
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

https_start_server :: proc(server: ^Https_Server, directory: string, port: int) -> bool {
	process, err := os.process_start(
		{
			working_dir = directory,
			command = {
				"openssl",
				"s_server",
				"-accept",
				fmt.tprintf("127.0.0.1:%d", port),
				"-cert",
				"certificate.pem",
				"-key",
				"key.pem",
				"-tls1_3",
				"-alpn",
				"http/1.1",
				"-www",
				"-naccept",
				"1",
			},
		},
	)
	if err != nil { return false }
	server.process = process
	server.running = true
	return true
}

// https_free_port asks the kernel for a port and gives it back, which is the one way to
// pick a port that is not already in use.
https_free_port :: proc() -> (port: int, ok: bool) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	if listen_err != nil { return 0, false }
	defer net.close(listener)
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if endpoint_err != nil { return 0, false }
	return endpoint.port, true
}
