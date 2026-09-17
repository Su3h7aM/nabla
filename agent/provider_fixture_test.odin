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
import "core:testing"
import "core:thread"
import "core:time"

// AGENT_PROVIDER_BOUND keeps a broken fixture from hanging the suite.
AGENT_PROVIDER_BOUND :: 10 * time.Second

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
	listener:  net.TCP_Socket,
	port:      int,
	responses: []string,
	allocator: mem.Allocator,
	// requests holds what each connection sent, in order, so a test can assert what
	// left this machine: an attempt chain that sends the same bytes sends equal ones.
	requests:  [dynamic]string,
	thread:    ^thread.Thread,
	failed:    bool,
}

agent_provider_start :: proc(t: ^testing.T, provider: ^Agent_Provider, responses: []string) -> bool {
	provider.responses = responses
	provider.allocator = context.allocator
	provider.requests = make([dynamic]string, 0, len(responses) + 1, provider.allocator)

	listener, listen_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, len(responses) + 1)
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
	thread.start(provider.thread)
	return true
}

// agent_provider_stop ends the fixture: it waits for the responses it was given to
// be served, then releases everything it kept. A test that never got that far still
// stops it, because the listener is closed here either way.
agent_provider_stop :: proc(provider: ^Agent_Provider) {
	if provider.thread != nil {
		thread.join(provider.thread)
		thread.destroy(provider.thread)
		provider.thread = nil
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
	for response in provider.responses {
		socket, _, accept_err := net.accept_tcp(provider.listener)
		if accept_err != nil {
			provider.failed = true
			return
		}
		request, read_ok := agent_provider_read(socket, provider.allocator)
		if !read_ok {
			provider.failed = true
			net.close(socket)
			return
		}
		append(&provider.requests, request)
		write_ok := agent_provider_write(socket, response)
		net.close(socket)
		if !write_ok {
			provider.failed = true
			return
		}
	}
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
