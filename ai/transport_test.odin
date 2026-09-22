package ai

// Transport tests. These cover only the behavior this package is responsible for:
// certificate verification fails closed, an interrupted read retires, and a
// response that ends early is never reported as success.
//
// The fixture is an in-process TLS server that either completes the response or
// holds the connection open; the test synchronizes on the phase being reached
// rather than sleeping.

import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "nabla:http/client"

// Paths resolve against this file, not the working directory. The certificates are
// test-only throwaways valid until 2126; their keys are intentionally committed.

// Bounds so a broken fixture or a broken interrupt fails the test instead of
// hanging the suite.
TRANSPORT_FIXTURE_BOUND :: 10 * time.Second
TRANSPORT_RETIRE_BOUND :: 2 * time.Second

TRANSPORT_PAYLOAD :: "transport-test-payload"

TRANSPORT_RESPONSE_BODY ::
	"data: {\"choices\":[{\"delta\":{\"content\":\"hello\"},\"finish_reason\":null}]}\n\n" +
	"data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" +
	"data: [DONE]\n\n"
TRANSPORT_RESPONSE_COMPLETE :: "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n" + TRANSPORT_RESPONSE_BODY
// TRANSPORT_RESPONSE_PARTIAL declares more body than it sends, which is what a
// response that stops early looks like once the head has stated a length.
TRANSPORT_RESPONSE_PARTIAL ::
	"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: 4096\r\n\r\n" +
	"data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n"

// Fixture_Phase is where the server stops making progress.
Fixture_Phase :: enum {
	// Send a complete response, then close.
	Complete,
	// Send less body than the head declared, then close.
	Truncate,
	// Send headers and part of an event, then hold the connection open.
	Stall,
	// Send the same body with a declared length, which is the only way a head
	// states how much body follows.
	Declared,
	// Send exactly the response the test wrote, then close. It is how a refusal and its fields are exercised without a second server.
	Custom,
}

Transport_Fixture :: struct {
	phase:          Fixture_Phase,
	// response is what the Custom phase writes, byte for byte.
	response:       string,
	listener:       net.TCP_Socket,
	port:           int,
	// request holds what the client sent, so a test can assert on the fields the
	// provider layer is responsible for. request_length is set once the read is
	// complete, before any response byte leaves.
	request:        [8192]u8,
	request_length: int,
	// reached is posted once the server has entered the stall point.
	reached:        sync.Sema,
	// release lets the server leave the stall point and clean up.
	release:        sync.Sema,
	thread:         ^thread.Thread,
	failed:         bool,
}

transport_fixture_start :: proc(t: ^testing.T, fixture: ^Transport_Fixture, phase: Fixture_Phase, response := "") -> bool {
	fixture^ = Transport_Fixture {
		phase    = phase,
		response = response,
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
	fixture.thread = thread.create(transport_fixture_serve, name = "nabla-transport-fixture")
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

	// Drain the request first: closing a socket that still holds unread data sends
	// RST, which would turn an orderly close into a truncation.
	if !transport_fixture_read_request(fixture, socket) {
		fixture.failed = true
		sync.sema_post(&fixture.reached)
		return
	}
	switch fixture.phase {
	case .Complete:
		transport_fixture_write(socket, TRANSPORT_RESPONSE_COMPLETE)
		net.shutdown(socket, .Send)
	case .Truncate:
		transport_fixture_write(socket, TRANSPORT_RESPONSE_PARTIAL)
	case .Stall:
		transport_fixture_write(socket, TRANSPORT_RESPONSE_PARTIAL)
		transport_fixture_stall(fixture)
	case .Declared:
		// The length is computed from the body rather than written down, so the
		// head cannot disagree with what follows it.
		head: [96]u8
		transport_fixture_write(
			socket,
			fmt.bprintf(head[:], "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: %d\r\n\r\n", len(TRANSPORT_RESPONSE_BODY)),
		)
		transport_fixture_write(socket, TRANSPORT_RESPONSE_BODY)
		net.shutdown(socket, .Send)
	case .Custom:
		transport_fixture_write(socket, fixture.response)
		net.shutdown(socket, .Send)
	}
}

transport_fixture_write :: proc(socket: net.TCP_Socket, text: string) -> bool {
	pending := transmute([]u8)text
	for len(pending) > 0 {
		written, send_err := net.send_tcp(socket, pending)
		if send_err != nil || written <= 0 { return false }
		pending = pending[written:]
	}
	return true
}

// transport_fixture_read_request drains the request and keeps it, so a test can
// check the fields the client sent. It waits for the whole payload so the server
// is responding to a complete request.
transport_fixture_read_request :: proc(fixture: ^Transport_Fixture, socket: net.TCP_Socket) -> bool {
	for used := 0; used < len(fixture.request); {
		count, recv_err := net.recv_tcp(socket, fixture.request[used:])
		if recv_err != nil || count <= 0 { return false }
		used += count
		fixture.request_length = used
		if header_end := strings.index(string(fixture.request[:used]), "\r\n\r\n"); header_end >= 0 {
			if used - header_end >= len(TRANSPORT_PAYLOAD) { return true }
		}
	}
	return false
}

// free_port asks the kernel for a port and gives it back, so the closed endpoint a
// test needs is one nothing is listening on.
free_port :: proc() -> (port: int, ok: bool) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	if listen_err != nil { return 0, false }
	defer net.close(listener)
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if endpoint_err != nil { return 0, false }
	return endpoint.port, true
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

transport_job_init :: proc(t: ^testing.T, job: ^Transport_Job, host: string, port: int) -> bool {
	job.allocator = context.allocator
	job.content = TRANSPORT_PAYLOAD
	job.messages = make([]Provider_Message, 1, job.allocator)
	job.messages[0] = Provider_Message {
		Role    = .User,
		Content = job.content,
	}
	job.endpoint = fmt.aprintf("http://%s:%d", host, port, allocator = job.allocator)
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
	return true
}

transport_job_start :: proc(job: ^Transport_Job) {
	job.thread = thread.create(transport_job_serve, name = "nabla-transport-job")
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
	Provider_Operation_Error_Destroy(&job.error, allocator)
	if job.endpoint != "" { delete(job.endpoint, allocator) }
	if job.messages != nil { delete(job.messages, allocator) }
	if job.nameservers != nil { delete(job.nameservers, allocator) }
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
	if !transport_job_init(t, job, "stalled.test", 443) { return false }
	job.nameservers = make([]net.Endpoint, 1, job.allocator)
	job.nameservers[0] = nameserver
	job.options.nameservers = job.nameservers
	return true
}

@(test)
test_transport_reports_what_it_encoded_and_received :: proc(t: ^testing.T) {
	fixture: Transport_Fixture
	if !transport_fixture_start(t, &fixture, .Complete) { return }
	defer transport_fixture_stop(&fixture)

	job: Transport_Job
	if !transport_job_init(t, &job, "localhost", fixture.port) { return }
	defer transport_job_destroy(&job, job.allocator)

	observed: Transport_Observation
	job.options.observer = {
		user_data = &observed,
		report    = transport_observation_report,
	}
	transport_job_start(&job)
	transport_job_join(&job)

	testing.expectf(t, job.error.kind == .None, "request failed: %v %s", job.error.kind, job.error.detail)
	// The body is reported once, and it is the body the provider encoded. Nothing is
	// kept from the report: its bytes are borrowed for the call only, and the call
	// runs on another thread.
	testing.expect_value(t, observed.encoded_reports, 1)
	testing.expect(t, observed.body_has_model, "the encoded report should carry the model the request named")
	testing.expect(t, observed.body_bytes > 0, "the encoded report should carry the body itself")
	// The response arrives as chunks before the operation returns, and the count
	// is the plaintext byte count.
	testing.expect(t, observed.chunks > 0, "the response should be reported as it arrives")
	testing.expect_value(t, observed.bytes, u64(observed.chunk_bytes))
}

// Transport_Observation is what the observer records about one operation. It holds
// values rather than borrowed bytes, because a report is only valid for the call it
// arrives in.
Transport_Observation :: struct {
	encoded_reports: int,
	body_bytes:      int,
	body_has_model:  bool,
	chunks:          int,
	chunk_bytes:     int,
	bytes:           u64,
	// transfer_seen says the transport reported how the attempt ended, and
	// transfer is what it reported. The operation's own error is a separate fact.
	transfer_seen:   bool,
	transfer:        Provider_Transfer_Summary,
}

transport_observation_report :: proc(user_data: rawptr, report: Provider_Operation_Report) {
	observed := cast(^Transport_Observation)user_data
	switch report.stage {
	case .Encoded:
		observed.encoded_reports += 1
		observed.body_bytes = len(report.body)
		observed.body_has_model = strings.contains(string(report.body), `"model":"transport-test-model"`)
	case .Response_Body:
		observed.chunks += 1
		observed.chunk_bytes += len(report.chunk)
		observed.bytes = report.bytes
	case .Transfer:
		observed.transfer_seen = true
		observed.transfer = report.transfer
	}
}

@(test)
test_transport_truncated_response_is_not_success :: proc(t: ^testing.T) {
	fixture: Transport_Fixture
	if !transport_fixture_start(t, &fixture, .Truncate) { return }
	defer transport_fixture_stop(&fixture)

	job: Transport_Job
	if !transport_job_init(t, &job, "localhost", fixture.port) { return }
	defer transport_job_destroy(&job, job.allocator)
	transport_job_start(&job)
	transport_job_join(&job)

	testing.expectf(t, job.error.kind == .Transport, "a truncated response is a transport failure: %v", job.error.kind)
	testing.expect_value(t, job.completions, 0)
}

@(test)
test_transport_cancel_interrupts_blocked_read :: proc(t: ^testing.T) {
	fixture: Transport_Fixture
	if !transport_fixture_start(t, &fixture, .Stall) { return }
	defer transport_fixture_stop(&fixture)

	interrupt: Interrupt

	job: Transport_Job
	if !transport_job_init(t, &job, "localhost", fixture.port) { return }
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

	// The probe makes the dial nonblocking, which is the path that has to learn why
	// the connect failed from the socket error rather than from connect itself.
	control: HTTP_Control
	options := client.Options {
		probe = {check = http_probe, user_data = &control},
	}
	// connection_dial waits on the calling thread's event loop, so a test that
	// drives the transport directly owns one the way stream_request does.
	testing.expect(t, nbio.acquire_thread_event_loop() == nil)
	defer nbio.release_thread_event_loop()

	connection, dial_err := client.connection_dial(endpoint, options, context.temp_allocator)
	testing.expect(t, connection == nil)
	testing.expect_value(t, dial_err, client.Error.Connect)
}

@(test)
test_dns_retires_stalled_resolution :: proc(t: ^testing.T) {
	// Cancellation retires a resolution stalled at the nameserver.
	{
		server, nameserver, ok := dns_stalled_server_start(t)
		if !ok { return }
		defer net.close(server)

		interrupt: Interrupt
		job: Transport_Job
		if !dns_job_init(t, &job, nameserver) { return }
		defer transport_job_destroy(&job, job.allocator)
		job.options.interrupt = &interrupt

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
	}
	// A deadline retires it too, well inside one resolution attempt so the
	// operation bound expires rather than a nameserver attempt.
	{
		server, nameserver, ok := dns_stalled_server_start(t)
		if !ok { return }
		defer net.close(server)

		job: Transport_Job
		if !dns_job_init(t, &job, nameserver) { return }
		defer transport_job_destroy(&job, job.allocator)
		job.options.deadline = deadline_in(300 * time.Millisecond)

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
	}
}

// --- provider refusals -------------------------------------------------------

// refusal_response builds a response with the fields a refusal carries, so a test
// writes only the part it is about. extra_fields ends every line it names with CRLF.
// The response is built in the test's own temporary memory: it has to outlive the
// request the fixture answers, and no longer.
refusal_response :: proc(status, content_type, extra_fields, body: string) -> string {
	return fmt.aprintf(
		"HTTP/1.1 %s\r\ncontent-type: %s\r\ncontent-length: %d\r\n%s\r\n%s",
		status,
		content_type,
		len(body),
		extra_fields,
		body,
		allocator = context.temp_allocator,
	)
}

// transport_refusal_once performs one request against a fixture that answers with
// exactly `response`, and leaves the attempt in job and observed. The fixture is
// started and stopped here, so the caller owns only what it named.
transport_refusal_once :: proc(t: ^testing.T, response: string, job: ^Transport_Job, observed: ^Transport_Observation) -> bool {
	fixture: Transport_Fixture
	if !transport_fixture_start(t, &fixture, .Custom, response) {
		return false
	}
	defer transport_fixture_stop(&fixture)

	if !transport_job_init(t, job, "localhost", fixture.port) { return false }
	job.options.observer = {
		user_data = observed,
		report    = transport_observation_report,
	}
	transport_job_start(job)
	transport_job_join(job)
	return true
}

// A 429 that names a quota is a quota failure, not throttling, and everything the
// response said about the refusal survives to the operation's error. The body
// itself reaches the caller's callback, because keeping it is the caller's policy
// and not a transport one.
@(test)
test_a_quota_refusal_keeps_its_evidence :: proc(t: ^testing.T) {
	body := `{"error":{"message":"You exceeded your current quota","type":"insufficient_quota","code":"insufficient_quota"}}`
	fields := "x-request-id: req_quota\r\nretry-after: 7\r\nx-should-retry: false\r\n"

	job: Transport_Job
	observed: Transport_Observation
	if !transport_refusal_once(t, refusal_response("429 Too Many Requests", "application/json", fields, body), &job, &observed) {
		return
	}
	defer transport_job_destroy(&job, job.allocator)

	testing.expect_value(t, job.error.kind, Provider_Operation_Error_Kind.HTTP)
	testing.expect_value(t, job.error.status, 429)
	testing.expect_value(t, job.error.failure_class, Provider_Failure_Class.Quota)
	testing.expect_value(t, job.error.provider_code, "insufficient_quota")
	testing.expect_value(t, job.error.provider_request_id, "req_quota")
	testing.expect_value(t, job.error.retry_directive, Provider_Retry_Directive.Forbid)
	if delay, present := job.error.retry_after.?; testing.expect(t, present, "the provider asked for a delay") {
		testing.expect_value(t, delay, 7 * time.Second)
	}
	// The provider's own words are the reason, so they are what the failure carries.
	testing.expect(t, strings.contains(job.error.detail, "exceeded your current quota"), job.error.detail)
	// The transport's own account of the attempt is an independent fact from all of
	// the above, and it is collected whether or not diagnostics are on.
	testing.expect(t, job.error.transfer_present)
	testing.expect_value(t, job.error.transfer.status, 429)
	testing.expect_value(t, job.error.transfer.stopped_at, Provider_Transfer_Phase.Response_Body)
	testing.expect_value(t, observed.chunk_bytes, len(body))
	testing.expect_value(t, job.texts, 0)
	testing.expect_value(t, job.completions, 0)
}

// A 429 with nothing in it is throttling, and a provider that says nothing about a
// delay gets no delay invented for it.
@(test)
test_a_rate_limit_without_a_code_is_throttling :: proc(t: ^testing.T) {
	body := `{"error":{"message":"Rate limit reached"}}`

	job: Transport_Job
	observed: Transport_Observation
	if !transport_refusal_once(t, refusal_response("429 Too Many Requests", "application/json", "", body), &job, &observed) {
		return
	}
	defer transport_job_destroy(&job, job.allocator)

	testing.expect_value(t, job.error.kind, Provider_Operation_Error_Kind.HTTP)
	testing.expect_value(t, job.error.failure_class, Provider_Failure_Class.Rate_Limited)
	testing.expect_value(t, job.error.provider_code, "")
	testing.expect_value(t, job.error.retry_directive, Provider_Retry_Directive.Unspecified)
	testing.expect(t, job.error.retry_after == nil, "a provider that asked for no delay must report none")
}

// A rejected credential identifies itself without the status that carried it.
@(test)
test_an_authentication_refusal_names_itself :: proc(t: ^testing.T) {
	body := `{"error":{"message":"Incorrect API key provided","code":"invalid_api_key"}}`

	job: Transport_Job
	observed: Transport_Observation
	if !transport_refusal_once(t, refusal_response("401 Unauthorized", "application/json", "", body), &job, &observed) {
		return
	}
	defer transport_job_destroy(&job, job.allocator)

	testing.expect_value(t, job.error.kind, Provider_Operation_Error_Kind.HTTP)
	testing.expect_value(t, job.error.status, 401)
	testing.expect_value(t, job.error.failure_class, Provider_Failure_Class.Authentication)
}

// A 2xx that is not the stream the request asked for is still a refusal, and the
// body of it is the provider's error document. No non-200 status is invented for
// it: the code it wrote is what classifies it.
@(test)
test_a_200_error_document_is_classified_by_its_code :: proc(t: ^testing.T) {
	body := `{"error":{"message":"This model's maximum context length is 8192 tokens","code":"context_length_exceeded"}}`

	job: Transport_Job
	observed: Transport_Observation
	if !transport_refusal_once(t, refusal_response("200 OK", "application/json", "", body), &job, &observed) {
		return
	}
	defer transport_job_destroy(&job, job.allocator)

	testing.expect_value(t, job.error.kind, Provider_Operation_Error_Kind.Stream)
	testing.expect_value(t, job.error.status, 200)
	testing.expect_value(t, job.error.failure_class, Provider_Failure_Class.Context_Overflow)
	testing.expect_value(t, job.error.provider_code, "context_length_exceeded")
	testing.expect_value(t, observed.chunk_bytes, len(body))
	testing.expect_value(t, job.completions, 0)
}

// A large valid error document carries its rejection evidence wherever it
// lies: only the complete body is parsed, so a code past the old prefix bound
// still classifies the refusal instead of leaving the status to decide alone.
@(test)
test_a_large_error_document_is_classified_by_its_code :: proc(t: ^testing.T) {
	pad := strings.repeat("x", 9000, context.temp_allocator)
	body := strings.concatenate(
		{`{"error":{"pad":"`, pad, `","message":"This model's maximum context length is 8192 tokens","code":"context_length_exceeded"}}`},
		context.temp_allocator,
	)
	testing.expect(t, len(body) > 8192, "the code must lie past the old prefix bound")

	job: Transport_Job
	observed: Transport_Observation
	if !transport_refusal_once(t, refusal_response("400 Bad Request", "application/json", "", body), &job, &observed) {
		return
	}
	defer transport_job_destroy(&job, job.allocator)

	testing.expect_value(t, job.error.kind, Provider_Operation_Error_Kind.HTTP)
	testing.expect_value(t, job.error.status, 400)
	testing.expect_value(t, job.error.failure_class, Provider_Failure_Class.Context_Overflow)
	testing.expect_value(t, job.error.provider_code, "context_length_exceeded")
	testing.expect_value(t, observed.chunk_bytes, len(body))
	testing.expect_value(t, job.completions, 0)
}

// A request that was written and got nothing back may have run: the operation says
// so, so recovery can refuse to send the same bytes again.
@(test)
test_a_request_with_no_answer_reports_delivery_evidence :: proc(t: ^testing.T) {
	job: Transport_Job
	observed: Transport_Observation
	if !transport_refusal_once(t, "", &job, &observed) { return }
	defer transport_job_destroy(&job, job.allocator)

	testing.expect_value(t, job.error.kind, Provider_Operation_Error_Kind.Transport)
	testing.expect(t, job.error.transfer_present)
	testing.expect(t, job.error.transfer.request_write_started, "the request writer was entered")
	testing.expect(t, job.error.delivery_present)
	testing.expect_value(t, job.error.delivery, Provider_Delivery_State.Model_Send_Started)
}

// A stream that framed cleanly but never reached its terminal event is incomplete,
// which is a different fact from a connection that broke: the text it did deliver
// is real, and it is what an automatic retry must not repeat.
@(test)
test_an_unfinished_stream_is_incomplete :: proc(t: ^testing.T) {
	body := "data: {\"choices\":[{\"delta\":{\"content\":\"half\"}}]}\n\n"

	job: Transport_Job
	observed: Transport_Observation
	if !transport_refusal_once(t, refusal_response("200 OK", "text/event-stream", "", body), &job, &observed) {
		return
	}
	defer transport_job_destroy(&job, job.allocator)

	testing.expect_value(t, job.error.kind, Provider_Operation_Error_Kind.Stream)
	testing.expect_value(t, job.error.failure_class, Provider_Failure_Class.Incomplete_Stream)
	testing.expect_value(t, job.error.transport_cause, Provider_Transport_Cause.None)
	testing.expect(t, job.error.transfer_present)
	testing.expect_value(t, job.error.transfer.stopped_at, Provider_Transfer_Phase.Complete)
	testing.expect_value(t, job.texts, 1)
	testing.expect_value(t, job.completions, 0)
}

// Authentication is provider policy built from the connection. A credential
// produces the header the family uses; no credential produces no header at all
// rather than a refused request, because an unauthenticated endpoint is a valid
// deployment and not a malformed request.
@(test)
test_provider_auth_headers_are_optional :: proc(t: ^testing.T) {
	authenticated := Provider_Connection {
		API        = .OpenAI_Chat_Completions,
		Credential = "secret",
	}
	headers := provider_encoded_headers(authenticated, {}, context.allocator)
	defer provider_headers_destroy(headers, context.allocator)
	if testing.expect_value(t, len(headers), 1) {
		testing.expect_value(t, headers[0].name, "authorization")
		testing.expect_value(t, headers[0].value, "Bearer secret")
	}

	anonymous := Provider_Connection {
		API = .OpenAI_Responses,
	}
	none := provider_encoded_headers(anonymous, {}, context.allocator)
	defer provider_headers_destroy(none, context.allocator)
	testing.expect_value(t, len(none), 0)

	// Anthropic authenticates with its own header and requires the API version.
	messages := Provider_Connection {
		API        = .Anthropic_Messages,
		Credential = "secret",
	}
	versioned := provider_encoded_headers(messages, {}, context.allocator)
	defer provider_headers_destroy(versioned, context.allocator)
	if testing.expect_value(t, len(versioned), 2) {
		testing.expect_value(t, versioned[0].name, "x-api-key")
		testing.expect_value(t, versioned[0].value, "secret")
		testing.expect_value(t, versioned[1].name, "anthropic-version")
		testing.expect_value(t, versioned[1].value, ANTHROPIC_VERSION)
	}
}

// A client names itself and the conversation it is having. Both are opaque to
// this package, and an endpoint that routes, throttles, or traces by client has
// only these to read; a caller that names neither sends neither header.
@(test)
test_provider_request_headers_carry_the_client_identity :: proc(t: ^testing.T) {
	connection := Provider_Connection {
		API        = .OpenAI_Responses,
		Credential = "secret",
	}
	named := Provider_Encoded_Request {
		User_Agent_Present = true,
		User_Agent         = "nabla/0.1.0",
		Session_Id_Present = true,
		Session_Id         = "0123456789abcdef0123456789abcdef",
	}
	headers := provider_encoded_headers(connection, named, context.allocator)
	defer provider_headers_destroy(headers, context.allocator)
	if testing.expect_value(t, len(headers), 3) { return }
	testing.expect_value(t, headers[0].name, "authorization")
	testing.expect_value(t, headers[1].name, "user-agent")
	testing.expect_value(t, headers[1].value, "nabla/0.1.0")
	testing.expect_value(t, headers[2].name, "session-id")
	testing.expect_value(t, headers[2].value, "0123456789abcdef0123456789abcdef")

	// A present but empty value is not an identity, so no header is sent for it.
	blank := Provider_Encoded_Request {
		User_Agent_Present = true,
		Session_Id_Present = true,
	}
	headers = provider_encoded_headers(connection, blank, context.allocator)
	defer provider_headers_destroy(headers, context.allocator)
	testing.expect_value(t, len(headers), 1)
	testing.expect_value(t, headers[0].name, "authorization")
}

@(test)
test_transport_reports_where_a_completed_request_stopped :: proc(t: ^testing.T) {
	fixture: Transport_Fixture
	if !transport_fixture_start(t, &fixture, .Declared) { return }
	defer transport_fixture_stop(&fixture)

	job: Transport_Job
	if !transport_job_init(t, &job, "localhost", fixture.port) { return }
	defer transport_job_destroy(&job, job.allocator)

	observed: Transport_Observation
	job.options.observer = {
		user_data = &observed,
		report    = transport_observation_report,
	}
	transport_job_start(&job)
	transport_job_join(&job)

	testing.expectf(t, job.error.kind == .None, "request failed: %v %s", job.error.kind, job.error.detail)
	// The transport reports once per operation, whatever else the observer saw.
	testing.expect(t, observed.transfer_seen, "the transport should account for the attempt")
	testing.expect_value(t, observed.transfer.stopped_at, Provider_Transfer_Phase.Complete)
	// The whole request was taken: the request line, the fields, and the body.
	testing.expect(t, observed.transfer.request_complete, "the transport should have taken the whole request")
	// The body the transport took is exactly the body the provider encoded, which
	// is the property that makes the two counts comparable across a run.
	testing.expect_value(t, observed.transfer.request_body_bytes_accepted, u64(observed.body_bytes))
	testing.expect(t, observed.transfer.request_bytes_accepted > observed.transfer.request_body_bytes_accepted, "the head is counted too")

	testing.expect(t, observed.transfer.response_head_received, "a head arrived")
	testing.expect_value(t, observed.transfer.status, 200)
	// The head stated how much body follows, which is a different fact from how
	// much of it was read.
	testing.expect(t, observed.transfer.declared_body_bytes_present, "the head declared a length")
	testing.expect_value(t, observed.transfer.declared_body_bytes, u64(len(TRANSPORT_RESPONSE_BODY)))
}

@(test)
test_transport_separates_a_refused_connection_from_a_broken_stream :: proc(t: ^testing.T) {
	// A truncated stream: the head arrived and the body stopped early. The
	// high-level failure is a transport error either way, so the phase is the only
	// thing that says whether anything was sent or received.
	fixture: Transport_Fixture
	if !transport_fixture_start(t, &fixture, .Truncate) { return }
	defer transport_fixture_stop(&fixture)

	job: Transport_Job
	if !transport_job_init(t, &job, "localhost", fixture.port) { return }
	defer transport_job_destroy(&job, job.allocator)

	observed: Transport_Observation
	job.options.observer = {
		user_data = &observed,
		report    = transport_observation_report,
	}
	transport_job_start(&job)
	transport_job_join(&job)

	testing.expect(t, job.error.kind != .None, "a truncated stream is not success")
	testing.expect(t, observed.transfer_seen, "the transport should account for the attempt")
	testing.expect_value(t, observed.transfer.stopped_at, Provider_Transfer_Phase.Response_Body)
	testing.expect(t, observed.transfer.request_complete, "the whole request was taken before the stream broke")
	testing.expect(t, observed.transfer.response_head_received, "the head arrived before the stream broke")
}

@(test)
test_transport_reports_a_request_that_never_left :: proc(t: ^testing.T) {
	// A port nothing listens on: the connection never opens, so no request byte was
	// ever taken. This is what a caller must be able to tell apart from a stream
	// that broke after the request went out.
	closed_port, port_ok := free_port()
	if !testing.expect(t, port_ok, "no closed port could be found") { return }

	job: Transport_Job
	if !transport_job_init(t, &job, "localhost", closed_port) { return }
	defer transport_job_destroy(&job, job.allocator)

	observed: Transport_Observation
	job.options.observer = {
		user_data = &observed,
		report    = transport_observation_report,
	}
	transport_job_start(&job)
	transport_job_join(&job)

	testing.expect(t, job.error.kind != .None, "an untrusted peer is not success")
	testing.expect(t, observed.transfer_seen, "the transport should account for the attempt")
	testing.expect_value(t, observed.transfer.stopped_at, Provider_Transfer_Phase.Connect)
	testing.expect_value(t, observed.transfer.request_bytes_accepted, u64(0))
	testing.expect(t, !observed.transfer.request_complete, "nothing was taken, so the request is not complete")
	testing.expect(t, !observed.transfer.response_head_received, "no head arrives without a connection")
	testing.expect(t, !observed.transfer.declared_body_bytes_present, "an absent head declares nothing")
}
