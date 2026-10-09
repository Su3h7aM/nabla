#+test
package agent

// A scripted provider: a plain HTTP server that answers one canned response per
// connection, in order, and keeps what the harness sent. The harness's request path
// is about what it sends and what it records, and both are observable from the far
// end of a socket, so this is the fixture a retry chain is tested against. The
// client reaches an http:// endpoint without TLS, and the TLS paths are covered
// where the provider layer's own fixture exercises them.

import "core:fmt"
import "core:mem"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// AGENT_PROVIDER_BOUND keeps a broken fixture from hanging the suite.
AGENT_PROVIDER_BOUND :: 10 * time.Second

// COMPACT_DIRECTIVE_MARKER is the directive's first sentence, which has no character a JSON
// body escapes, so it appears verbatim in a compaction request.
COMPACT_DIRECTIVE_MARKER :: "Summarize the conversation above into a checkpoint"

// agent_provider_reply is one response the harness reads as a complete Chat
// Completions stream: the text, then a stop, then the sentinel. It is built in the
// calling test's temporary memory: it has to outlive the request it answers, and
// no longer.
agent_provider_reply :: proc(text: string, allocator := context.temp_allocator) -> string {
	// The JSON is assembled from fragments rather than written into a format string:
	// fmt reads braces in a format string as directives, and this is a document.
	quoted := fmt.aprintf("%q", text, allocator = allocator)
	defer delete(quoted, allocator)
	return strings.concatenate(
		{
			"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n",
			"data: {\"choices\":[{\"delta\":{\"content\":",
			quoted,
			"},\"finish_reason\":null}]}\n\n",
			"data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
			"data: [DONE]\n\n",
		},
		allocator,
	)
}

// agent_provider_truncated is one response whose stream ends before its own marker,
// after publishing nothing: the provider accepted the request and the connection broke
// while it was answering. Its content type makes it a stream to the client, and the
// missing sentinel is what the stream layer calls incomplete.
agent_provider_truncated :: proc(allocator := context.temp_allocator) -> string {
	return strings.concatenate(
		{
			"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n",
			// An event that carries no text and no finish reason: an attempt can be lost
			// this way without the conversation ever seeing part of an answer.
			"data: {\"choices\":[{\"delta\":{},\"finish_reason\":null}]}\n\n",
		},
		allocator,
	)
}

// agent_provider_refusal is one response that refuses the request with a provider
// error document. headers carries the rest of the refusal, such as the request id and
// the retry delay the provider reports, each including its own line ending.
agent_provider_refusal :: proc(status, body: string, headers := "", allocator := context.temp_allocator) -> string {
	return fmt.aprintf(
		"HTTP/1.1 %s\r\ncontent-type: application/json\r\n%scontent-length: %d\r\n\r\n%s",
		status,
		headers,
		len(body),
		body,
		allocator = allocator,
	)
}

Agent_Provider :: struct {
	listener:   net.TCP_Socket,
	// connection is the connection the serve thread is reading or answering right now,
	// and is empty while it waits in accept. agent_provider_stop takes it, so a read that
	// is already waiting on it ends instead of waiting for a request that never comes.
	connection: net.TCP_Socket,
	port:       int,
	responses:  []string,
	// summaries answers the requests that carry the compaction directive, in order, apart
	// from responses: a compaction request is sent from a job thread, so where it falls among
	// the other connections is not fixed. Set it before agent_provider_start.
	summaries:  []string,
	allocator:  mem.Allocator,
	// requests holds what each connection sent, in order, so a test can assert what
	// left this machine: an attempt chain that sends the same bytes sends equal ones.
	requests:   [dynamic]string,
	thread:     ^thread.Thread,
	failed:     bool,
	// hold is the 1-based index of the response that waits for release before it is written,
	// after its request was read and recorded. Zero holds nothing. agent_provider_stop posts
	// release, so a test that fails first never leaves the serve thread waiting.
	hold:       int,
	release:    sync.Sema,
	// lock orders the state the serve thread writes with the test that reads it. The
	// socket a response crosses does not give that ordering, so the fixture states it.
	lock:       sync.Mutex,
}

// The accessors below are the only way a test touches what the serve thread wrote. Each
// takes the lock, so a recorded request is published to the reader that observes it rather
// than raced with it.
agent_provider_record :: proc(provider: ^Agent_Provider, request: string) {
	sync.mutex_guard(&provider.lock)
	append(&provider.requests, request)
}

agent_provider_note_failure :: proc(provider: ^Agent_Provider) {
	sync.mutex_guard(&provider.lock)
	provider.failed = true
}

agent_provider_request_count :: proc(provider: ^Agent_Provider) -> int {
	sync.mutex_guard(&provider.lock)
	return len(provider.requests)
}

// agent_provider_request is one recorded request's bytes, or empty when the fixture has not
// recorded that many. The bytes are borrowed and live until the fixture stops.
agent_provider_request :: proc(provider: ^Agent_Provider, index: int) -> string {
	sync.mutex_guard(&provider.lock)
	if index < 0 || index >= len(provider.requests) { return "" }
	return provider.requests[index]
}

agent_provider_failed :: proc(provider: ^Agent_Provider) -> bool {
	sync.mutex_guard(&provider.lock)
	return provider.failed
}

// agent_provider_start listens and serves responses in order. A deferred provider listens
// but answers nothing until agent_provider_serve_now, so a test can hold a client mid-request.
agent_provider_start :: proc(t: ^testing.T, provider: ^Agent_Provider, responses: []string, deferred := false) -> bool {
	provider.responses = responses
	provider.allocator = context.allocator
	provider.requests = make([dynamic]string, 0, len(responses) + len(provider.summaries) + 1, provider.allocator)

	listener, listen_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, len(responses) + len(provider.summaries) + 1)
	if listen_err != nil {
		testing.expectf(t, false, "the scripted provider could not listen: %v", listen_err)
		return false
	}
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if endpoint_err != nil {
		testing.expectf(t, false, "the scripted provider had no endpoint: %v", endpoint_err)
		net.close(listener)
		return false
	}
	provider.listener = listener
	provider.port = endpoint.port
	provider.thread = thread.create(agent_provider_serve, name = "nabla-scripted-provider")
	if provider.thread == nil {
		testing.expectf(t, false, "the scripted provider thread could not start")
		net.close(listener)
		return false
	}
	provider.thread.data = provider
	if !deferred { thread.start(provider.thread) }
	return true
}

agent_provider_serve_now :: proc(provider: ^Agent_Provider) {
	thread.start(provider.thread)
}

// agent_provider_stop ends the fixture and always returns promptly: it wakes the serve
// thread out of the accept or read it is waiting in, joins it, then releases everything
// the fixture kept. A test that failed before it made every request stops the fixture
// too, so the stop does not wait for the requests that never come.
agent_provider_stop :: proc(provider: ^Agent_Provider) {
	if provider.thread != nil {
		sync.sema_post(&provider.release)
		// Closing a socket another thread is already waiting in does not end that wait,
		// so the stop ends both ways of waiting. It takes the open connection and shuts
		// it down, which returns a read that is waiting on it, and then connects to
		// itself once, which is what an accept that is waiting returns from. The wake
		// connection is closed here, so the read the serve thread enters on it meets the
		// end of its stream at once.
		connection: net.TCP_Socket
		if sync.mutex_guard(&provider.lock) {
			connection = provider.connection
			provider.connection = {}
		}
		if connection != {} { net.shutdown(connection, .Both) }
		wake_endpoint := net.Endpoint {
			address = net.IP4_Address{127, 0, 0, 1},
			port    = provider.port,
		}
		if wake, wake_err := net.dial_tcp_from_endpoint(wake_endpoint); wake_err == nil { net.close(wake) }
		thread.join(provider.thread)
		thread.destroy(provider.thread)
		provider.thread = nil
		if connection != {} { net.close(connection) }
	}
	if provider.listener != {} {
		net.close(provider.listener)
		provider.listener = {}
	}
	for request in provider.requests { delete(request, provider.allocator) }
	delete(provider.requests)
	provider^ = {}
}

agent_provider_endpoint :: proc(provider: ^Agent_Provider, allocator := context.allocator) -> string {
	return fmt.aprintf("http://127.0.0.1:%d", provider.port, allocator = allocator)
}

agent_provider_serve :: proc(thread: ^thread.Thread) {
	provider := cast(^Agent_Provider)thread.data
	next, next_summary := 0, 0
	for _ in 0 ..< len(provider.responses) + len(provider.summaries) {
		socket, _, accept_err := net.accept_tcp(provider.listener)
		if accept_err != nil {
			agent_provider_note_failure(provider)
			return
		}
		agent_provider_publish(provider, socket)
		request, read_ok := agent_provider_read(socket, provider.allocator)
		if !read_ok {
			agent_provider_note_failure(provider)
			agent_provider_release(provider, socket)
			return
		}
		agent_provider_record(provider, request)
		response: string
		if next_summary < len(provider.summaries) && strings.contains(request, COMPACT_DIRECTIVE_MARKER) {
			response = provider.summaries[next_summary]
			next_summary += 1
		} else if next < len(provider.responses) {
			response = provider.responses[next]
			next += 1
			if provider.hold == next { _ = sync.sema_wait_with_timeout(&provider.release, AGENT_PROVIDER_BOUND) }
		} else {
			agent_provider_note_failure(provider)
			agent_provider_release(provider, socket)
			return
		}
		write_ok := agent_provider_write(socket, response)
		agent_provider_release(provider, socket)
		if !write_ok {
			agent_provider_note_failure(provider)
			return
		}
	}
}

// agent_provider_publish marks the connection this thread is about to read, so a stop
// that arrives while that read waits can end it.
agent_provider_publish :: proc(provider: ^Agent_Provider, socket: net.TCP_Socket) {
	sync.mutex_guard(&provider.lock)
	provider.connection = socket
}

// agent_provider_release ends the connection's turn and closes its socket, unless
// agent_provider_stop took the connection first: then the socket is the stop's to shut
// down and close, and neither thread touches a descriptor the other may have closed.
agent_provider_release :: proc(provider: ^Agent_Provider, socket: net.TCP_Socket) {
	owned: bool
	if sync.mutex_guard(&provider.lock) {
		owned = provider.connection == socket
		if owned { provider.connection = {} }
	}
	if owned { net.close(socket) }
}

// agent_provider_read reads one whole request: its head, then the body that head's
// own Content-Length declares. Reading only what the first receive returned would
// make the recorded bytes depend on how the kernel split them, and a body larger than
// any fixed buffer is still one request, so what is read grows to what the head
// promised.
agent_provider_read :: proc(socket: net.TCP_Socket, allocator: mem.Allocator) -> (string, bool) {
	_ = net.set_option(socket, .Receive_Timeout, AGENT_PROVIDER_BOUND)
	received := make([dynamic]u8, 0, 16 * 1024, allocator)
	defer delete(received)
	scratch: [16 * 1024]u8
	head_end := -1
	body_length := 0
	for {
		count, recv_err := net.recv_tcp(socket, scratch[:])
		if recv_err != nil || count <= 0 { return "", false }
		append(&received, ..scratch[:count])
		if head_end < 0 {
			at := strings.index(string(received[:]), "\r\n\r\n")
			if at < 0 { continue }
			head_end = at + 4
			body_length = agent_provider_content_length(string(received[:head_end]))
			if body_length < 0 { return "", false }
		}
		if len(received) >= head_end + body_length { break }
	}
	return strings.clone(string(received[:head_end + body_length]), allocator), true
}

// agent_provider_content_length reads the declared body length, or -1 when the head
// declared one this fixture cannot use.
agent_provider_content_length :: proc(head: string) -> int {
	remaining := head
	for line in strings.split_iterator(&remaining, "\r\n") {
		name, separator, value := strings.partition(line, ":")
		if separator == "" { continue }
		if !strings.equal_fold(strings.trim_space(name), "content-length") { continue }
		length, ok := strconv.parse_int(strings.trim_space(value))
		return ok && length >= 0 ? length : -1
	}
	return 0
}

agent_provider_write :: proc(socket: net.TCP_Socket, response: string) -> bool {
	pending := transmute([]u8)response
	for len(pending) > 0 {
		sent, send_err := net.send_tcp(socket, pending)
		if send_err != nil { return false }
		pending = pending[sent:]
	}
	return true
}
