package ai

// Transport tests. These cover only the behavior this package is responsible for:
// certificate verification fails closed, an interrupted read retires, and a
// response that ends early is never reported as success.
//
// The fixture is an in-process TLS server that either completes the response or
// holds the connection open; the test synchronizes on the phase being reached
// rather than sleeping.

import "core:c"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "nabla:http/client"

// Paths resolve against this file, not the working directory. The certificates are
// test-only throwaways valid until 2126; their keys are intentionally committed.
TRANSPORT_CERT_LOCALHOST :: #directory + "testdata/localhost.pem"
TRANSPORT_KEY_LOCALHOST :: #directory + "testdata/localhost.key"
TRANSPORT_CERT_UNTRUSTED :: #directory + "testdata/selfsigned.pem"
TRANSPORT_KEY_UNTRUSTED :: #directory + "testdata/selfsigned.key"
TRANSPORT_CA :: #directory + "testdata/ca.pem"

// Bounds so a broken fixture or a broken interrupt fails the test instead of
// hanging the suite.
TRANSPORT_FIXTURE_BOUND :: 10 * time.Second
TRANSPORT_RETIRE_BOUND :: 2 * time.Second

TRANSPORT_PAYLOAD :: "transport-test-payload"

TRANSPORT_RESPONSE_COMPLETE ::
	"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n" +
	"data: {\"choices\":[{\"delta\":{\"content\":\"hello\"},\"finish_reason\":null}]}\n\n" +
	"data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" +
	"data: [DONE]\n\n"
TRANSPORT_RESPONSE_PARTIAL ::
	"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n" + "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n"

// Fixture_Phase is where the server stops making progress.
Fixture_Phase :: enum {
	// Send a complete response, then close with close_notify.
	Complete,
	// Send a partial response, then close without close_notify.
	Truncate,
	// Send headers and part of an event, then hold the connection open.
	Stall,
}

Transport_Fixture :: struct {
	phase:    Fixture_Phase,
	cert:     string,
	key:      string,
	listener: net.TCP_Socket,
	port:     int,
	// reached is posted once the server has entered the stall point.
	reached:  sync.Sema,
	// release lets the server leave the stall point and clean up.
	release:  sync.Sema,
	thread:   ^thread.Thread,
	failed:   bool,
}

transport_fixture_start :: proc(t: ^testing.T, fixture: ^Transport_Fixture, phase: Fixture_Phase, cert, key: string) -> bool {
	fixture^ = Transport_Fixture {
		phase = phase,
		cert  = cert,
		key   = key,
	}
	listener, listen_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	if listen_err != nil {
		testing.expectf(t, false, "fixture could not listen: %v", listen_err)
		return false
	}
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if endpoint_err != nil {
		testing.expectf(t, false, "fixture could not read its endpoint: %v", endpoint_err)
		net.close(listener)
		return false
	}
	fixture.listener = listener
	fixture.port = endpoint.port
	fixture.thread = thread.create(transport_fixture_serve, name = "svan-transport-fixture")
	if fixture.thread == nil {
		testing.expectf(t, false, "fixture thread could not start")
		net.close(listener)
		return false
	}
	fixture.thread.data = fixture
	thread.start(fixture.thread)
	return true
}

transport_fixture_stop :: proc(fixture: ^Transport_Fixture) {
	if fixture.thread == nil { return }
	sync.sema_post(&fixture.release)
	thread.join(fixture.thread)
	thread.destroy(fixture.thread)
	fixture.thread = nil
	if fixture.listener != {} {
		net.close(fixture.listener)
		fixture.listener = {}
	}
}

// transport_fixture_stall reports that the server has reached the phase under
// test, then holds until the test releases it.
transport_fixture_stall :: proc(fixture: ^Transport_Fixture) {
	sync.sema_post(&fixture.reached)
	if !sync.sema_wait_with_timeout(&fixture.release, TRANSPORT_FIXTURE_BOUND) {
		fixture.failed = true
	}
}

transport_fixture_serve :: proc(thread: ^thread.Thread) {
	fixture := cast(^Transport_Fixture)thread.data
	socket, _, accept_err := net.accept_tcp(fixture.listener)
	if accept_err != nil {
		fixture.failed = true
		sync.sema_post(&fixture.reached)
		return
	}
	defer net.close(socket)

	ctx := client.SSL_CTX_new(client.TLS_server_method())
	if ctx == nil {
		fixture.failed = true
		sync.sema_post(&fixture.reached)
		return
	}
	defer client.SSL_CTX_free(ctx)
	cert := strings.clone_to_cstring(fixture.cert, context.temp_allocator)
	key := strings.clone_to_cstring(fixture.key, context.temp_allocator)
	if client.SSL_CTX_use_certificate_file(ctx, cert, client.FILETYPE_PEM) != 1 ||
	   client.SSL_CTX_use_PrivateKey_file(ctx, key, client.FILETYPE_PEM) != 1 ||
	   client.SSL_CTX_check_private_key(ctx) != 1 {
		fixture.failed = true
		sync.sema_post(&fixture.reached)
		return
	}
	ssl := client.SSL_new(ctx)
	if ssl == nil {
		fixture.failed = true
		sync.sema_post(&fixture.reached)
		return
	}
	defer client.SSL_free(ssl)
	if client.SSL_set_fd(ssl, c.int(i32(i64(socket)))) != 1 {
		fixture.failed = true
		sync.sema_post(&fixture.reached)
		return
	}
	// A rejected certificate fails here, which is the expected outcome for the
	// untrusted case.
	if client.SSL_accept(ssl) != 1 {
		fixture.failed = true
		sync.sema_post(&fixture.reached)
		return
	}
	// Drain the request first: closing a socket that still holds unread data sends
	// RST, which would turn an orderly close into a truncation.
	if !transport_fixture_read_request(ssl) {
		fixture.failed = true
		sync.sema_post(&fixture.reached)
		return
	}
	switch fixture.phase {
	case .Complete:
		transport_fixture_write(ssl, TRANSPORT_RESPONSE_COMPLETE)
		_ = client.SSL_shutdown(ssl)
	case .Truncate:
		transport_fixture_write(ssl, TRANSPORT_RESPONSE_PARTIAL)
	case .Stall:
		transport_fixture_write(ssl, TRANSPORT_RESPONSE_PARTIAL)
		transport_fixture_stall(fixture)
	}
}

transport_fixture_write :: proc(ssl: ^client.SSL, text: string) -> bool {
	pending := text
	for len(pending) > 0 {
		written := client.SSL_write(ssl, raw_data(pending), c.int(len(pending)))
		if written <= 0 { return false }
		pending = pending[written:]
	}
	return true
}

transport_fixture_read_request :: proc(ssl: ^client.SSL) -> bool {
	collected: [8192]u8
	used := 0
	for used < len(collected) {
		count := client.SSL_read(ssl, raw_data(collected[used:]), c.int(len(collected) - used))
		if count <= 0 { return false }
		used += int(count)
		if header_end := strings.index(string(collected[:used]), "\r\n\r\n"); header_end >= 0 {
			if used - header_end >= len(TRANSPORT_PAYLOAD) { return true }
		}
	}
	return false
}

// Transport_Job is one request executed on its own thread, so the test can act
// while the request is blocked.
Transport_Job :: struct {
	thread:      ^thread.Thread,
	allocator:   mem.Allocator,
	connection:  Provider_Connection,
	request:     Provider_Request,
	options:     Provider_Operation_Options,
	endpoint:    string,
	content:     string,
	messages:    []Provider_Message,
	nameservers: []net.Endpoint,
	error:       Provider_Operation_Error,
	texts:       int,
	completions: int,
}

transport_job_callback :: proc(user_data: rawptr, event: Provider_Event) {
	job := cast(^Transport_Job)user_data
	#partial switch value in event {
	case Provider_Text_Event:
		job.texts += 1
	case Provider_Completed_Event:
		job.completions += 1
	}
}

transport_job_init :: proc(t: ^testing.T, job: ^Transport_Job, host: string, port: int, ca_file: string) -> bool {
	job.allocator = context.allocator
	job.content = TRANSPORT_PAYLOAD
	job.messages = make([]Provider_Message, 1, job.allocator)
	job.messages[0] = Provider_Message {
		Role    = .User,
		Content = job.content,
	}
	job.endpoint = fmt.aprintf("https://%s:%d", host, port, allocator = job.allocator)
	job.connection = Provider_Connection {
		API        = .OpenAI_Chat_Completions,
		Endpoint   = job.endpoint,
		Credential = "transport-test-credential",
	}
	job.request = Provider_Request {
		API              = .OpenAI_Chat_Completions,
		Model_Present    = true,
		Model            = "transport-test-model",
		Messages_Present = true,
		Messages         = job.messages,
	}
	job.options.ca_file = ca_file
	return true
}

transport_job_start :: proc(job: ^Transport_Job) {
	job.thread = thread.create(transport_job_serve, name = "svan-transport-job")
	job.thread.data = job
	thread.start(job.thread)
}

transport_job_serve :: proc(thread: ^thread.Thread) {
	job := cast(^Transport_Job)thread.data
	job.error = Provider_Request_Operation_Controlled(job.connection, job.request, job, transport_job_callback, job.options, job.allocator)
}

transport_job_join :: proc(job: ^Transport_Job) {
	if job.thread == nil { return }
	thread.join(job.thread)
	thread.destroy(job.thread)
	job.thread = nil
}

transport_job_destroy :: proc(job: ^Transport_Job, allocator: mem.Allocator) {
	if job.error.detail != "" { delete(job.error.detail, allocator) }
	if job.endpoint != "" { delete(job.endpoint, allocator) }
	if job.messages != nil { delete(job.messages, allocator) }
	if job.nameservers != nil { delete(job.nameservers, allocator) }
}

transport_open_fd_count :: proc() -> int {
	file, open_err := os.open("/proc/self/fd")
	if open_err != nil { return -1 }
	defer os.close(file)
	entries, read_err := os.read_dir(file, 0, context.temp_allocator)
	if read_err != nil { return -1 }
	return len(entries)
}

// --- resolution interruption -------------------------------------------------

// A bound UDP socket that nobody reads from is a silently unresponsive nameserver:
// the datagrams are dropped without an ICMP error, so a lookup against it can only
// end through cancellation or the deadline.
dns_stalled_server_start :: proc(t: ^testing.T) -> (net.UDP_Socket, net.Endpoint, bool) {
	created, create_err := net.create_socket(.IP4, .UDP)
	if create_err != .None {
		testing.expectf(t, false, "stalled nameserver socket failed: %v", create_err)
		return {}, {}, false
	}
	socket := created.(net.UDP_Socket)
	if bind_err := net.bind(socket, {address = net.IP4_Address{127, 0, 0, 1}, port = 0}); bind_err != nil {
		testing.expectf(t, false, "stalled nameserver could not bind: %v", bind_err)
		net.close(socket)
		return {}, {}, false
	}
	endpoint, endpoint_err := net.bound_endpoint(socket)
	if endpoint_err != nil {
		testing.expectf(t, false, "stalled nameserver had no endpoint: %v", endpoint_err)
		net.close(socket)
		return {}, {}, false
	}
	return socket, endpoint, true
}

// dns_stalled_server_await_query blocks until the stalled nameserver receives a
// query, so the test acts on a lookup that is genuinely waiting for a reply rather
// than racing it. The query is then dropped.
dns_stalled_server_await_query :: proc(socket: net.UDP_Socket, timeout: time.Duration) -> bool {
	_ = net.set_option(socket, .Receive_Timeout, timeout)
	scratch: [512]u8
	count, _, recv_err := net.recv_udp(socket, scratch[:])
	return recv_err == nil && count > 0
}

// dns_job_init points one request at a name that only the stalled nameserver can
// answer, so the operation cannot proceed past resolution.
dns_job_init :: proc(t: ^testing.T, job: ^Transport_Job, nameserver: net.Endpoint) -> bool {
	if !transport_job_init(t, job, "stalled.test", 443, TRANSPORT_CA) { return false }
	job.nameservers = make([]net.Endpoint, 1, job.allocator)
	job.nameservers[0] = nameserver
	job.options.nameservers = job.nameservers
	return true
}

@(test)
test_transport_trusted_certificate_is_accepted :: proc(t: ^testing.T) {
	fixture: Transport_Fixture
	if !transport_fixture_start(t, &fixture, .Complete, TRANSPORT_CERT_LOCALHOST, TRANSPORT_KEY_LOCALHOST) { return }
	defer transport_fixture_stop(&fixture)

	job: Transport_Job
	if !transport_job_init(t, &job, "localhost", fixture.port, TRANSPORT_CA) { return }
	defer transport_job_destroy(&job, job.allocator)
	transport_job_start(&job)
	transport_job_join(&job)

	testing.expectf(t, job.error.kind == .None, "trusted request failed: %v %s", job.error.kind, job.error.detail)
	testing.expect_value(t, job.texts, 1)
	testing.expect_value(t, job.completions, 1)
}

@(test)
test_transport_untrusted_certificate_is_rejected :: proc(t: ^testing.T) {
	fixture: Transport_Fixture
	if !transport_fixture_start(t, &fixture, .Complete, TRANSPORT_CERT_UNTRUSTED, TRANSPORT_KEY_UNTRUSTED) { return }
	defer transport_fixture_stop(&fixture)

	job: Transport_Job
	if !transport_job_init(t, &job, "localhost", fixture.port, TRANSPORT_CA) { return }
	defer transport_job_destroy(&job, job.allocator)
	transport_job_start(&job)
	transport_job_join(&job)

	testing.expectf(t, job.error.kind == .TLS, "untrusted certificate was not rejected: %v", job.error.kind)
	testing.expect_value(t, job.completions, 0)
}

@(test)
test_transport_truncated_response_is_not_success :: proc(t: ^testing.T) {
	fixture: Transport_Fixture
	if !transport_fixture_start(t, &fixture, .Truncate, TRANSPORT_CERT_LOCALHOST, TRANSPORT_KEY_LOCALHOST) { return }
	defer transport_fixture_stop(&fixture)

	job: Transport_Job
	if !transport_job_init(t, &job, "localhost", fixture.port, TRANSPORT_CA) { return }
	defer transport_job_destroy(&job, job.allocator)
	transport_job_start(&job)
	transport_job_join(&job)

	testing.expectf(t, job.error.kind == .Stream, "truncated response was not a stream failure: %v", job.error.kind)
	testing.expect_value(t, job.completions, 0)
}

@(test)
test_transport_cancel_interrupts_blocked_read :: proc(t: ^testing.T) {
	fixture: Transport_Fixture
	if !transport_fixture_start(t, &fixture, .Stall, TRANSPORT_CERT_LOCALHOST, TRANSPORT_KEY_LOCALHOST) { return }
	defer transport_fixture_stop(&fixture)

	interrupt: Interrupt

	job: Transport_Job
	if !transport_job_init(t, &job, "localhost", fixture.port, TRANSPORT_CA) { return }
	defer transport_job_destroy(&job, job.allocator)
	job.options.interrupt = &interrupt

	transport_job_start(&job)
	if !sync.sema_wait_with_timeout(&fixture.reached, TRANSPORT_FIXTURE_BOUND) {
		testing.expectf(t, false, "fixture never reached the stall")
		transport_job_join(&job)
		return
	}
	started := time.tick_now()
	interrupt_request(&interrupt)
	transport_job_join(&job)
	elapsed := time.tick_since(started)

	testing.expectf(t, job.error.kind == .Cancelled, "expected cancellation, got %v", job.error.kind)
	testing.expect_value(t, job.completions, 0)
	testing.expectf(t, elapsed < TRANSPORT_RETIRE_BOUND, "retirement took %v, above the %v bound", elapsed, TRANSPORT_RETIRE_BOUND)
}

@(test)
test_transport_refused_connection_fails_to_connect :: proc(t: ^testing.T) {
	// A socket that is bound but never listens refuses connections, so the port is
	// held for the whole test and no other process can claim it.
	held, create_err := net.create_socket(.IP4, .TCP)
	testing.expect(t, create_err == nil)
	defer net.close(held)
	interface := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = 0,
	}
	testing.expect(t, net.bind(held, interface) == nil)
	endpoint, info_err := net.bound_endpoint(held)
	testing.expect(t, info_err == nil)

	// The hook makes the dial nonblocking, which is the path that has to learn why
	// the connect failed from the socket error rather than from connect itself.
	control: HTTP_Control
	options := client.Options {
		wait = {hook = http_wait, data = &control},
	}
	connection, dial_err := client.connection_dial(endpoint, options, context.temp_allocator)
	testing.expect(t, connection == nil)
	testing.expect_value(t, dial_err, client.Error.Connect)
}

@(test)
test_dns_cancel_retires_stalled_resolution :: proc(t: ^testing.T) {
	server, nameserver, ok := dns_stalled_server_start(t)
	if !ok { return }
	defer net.close(server)

	interrupt: Interrupt

	job: Transport_Job
	if !dns_job_init(t, &job, nameserver) { return }
	defer transport_job_destroy(&job, job.allocator)
	job.options.interrupt = &interrupt

	baseline := transport_open_fd_count()
	transport_job_start(&job)
	if !dns_stalled_server_await_query(server, TRANSPORT_FIXTURE_BOUND) {
		testing.expectf(t, false, "resolution never reached the nameserver")
		transport_job_join(&job)
		return
	}
	started := time.tick_now()
	interrupt_request(&interrupt)
	transport_job_join(&job)
	elapsed := time.tick_since(started)

	testing.expectf(t, job.error.kind == .Cancelled, "expected cancellation, got %v (%s)", job.error.kind, job.error.detail)
	testing.expect_value(t, job.completions, 0)
	testing.expectf(t, elapsed < TRANSPORT_RETIRE_BOUND, "retirement took %v, above the %v bound", elapsed, TRANSPORT_RETIRE_BOUND)
	testing.expect_value(t, transport_open_fd_count(), baseline)
}

@(test)
test_dns_deadline_retires_stalled_resolution :: proc(t: ^testing.T) {
	server, nameserver, ok := dns_stalled_server_start(t)
	if !ok { return }
	defer net.close(server)

	job: Transport_Job
	if !dns_job_init(t, &job, nameserver) { return }
	defer transport_job_destroy(&job, job.allocator)
	// Well inside one resolution attempt, so the operation bound expires rather than
	// a single nameserver attempt.
	job.options.deadline = deadline_in(300 * time.Millisecond)

	baseline := transport_open_fd_count()
	transport_job_start(&job)
	if !dns_stalled_server_await_query(server, TRANSPORT_FIXTURE_BOUND) {
		testing.expectf(t, false, "resolution never reached the nameserver")
		transport_job_join(&job)
		return
	}
	started := time.tick_now()
	transport_job_join(&job)
	elapsed := time.tick_since(started)

	testing.expectf(t, job.error.kind == .Timed_Out, "expected deadline expiry, got %v (%s)", job.error.kind, job.error.detail)
	testing.expect_value(t, job.completions, 0)
	testing.expectf(t, elapsed < TRANSPORT_RETIRE_BOUND, "retirement took %v, above the %v bound", elapsed, TRANSPORT_RETIRE_BOUND)
	testing.expect_value(t, transport_open_fd_count(), baseline)
}
