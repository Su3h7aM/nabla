package http

import "base:runtime"

import "core:bufio"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:nbio"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

Server_Opts :: struct {
	// Whether the server answers "Expect: 100-continue" with an interim 100
	// (Continue) before the handler runs. Defaults to true.
	auto_expect_continue: bool,
	// When this is true, any HEAD request is automatically redirected to the handler as a GET request.
	// Then, when the response is sent, the body is removed from the response.
	// Defaults to true.
	redirect_head_to_get: bool,
	// The longest request line this server reads, answered with 414 (URI Too
	// Long) when exceeded. Zero reads any length: HTTP sets no limit, and
	// RFC 9112 3 recommends supporting at least 8000 octets.
	limit_request_line:   int,
	// The largest header section this server reads, answered with 431
	// (Request Header Fields Too Large, RFC 6585 5) when exceeded. Zero reads
	// any size: HTTP sets no limit (RFC 9110 5.4).
	limit_headers:        int,
	// The thread count to use, defaults to the core count.
	thread_count:         int,
}

Default_Server_Opts := Server_Opts {
	auto_expect_continue = true,
	redirect_head_to_get = true,
}

Server_State :: enum {
	Uninitialized,
	Idle,
	Listening,
	Serving,
	Running,
	Closing,
	Cleaning,
	Closed,
}

Server :: struct {
	opts:                 Server_Opts,
	tcp_socket:           net.TCP_Socket,
	connection_allocator: mem.Allocator,
	handler:              Handler,
	threads:              []Server_Thread,
	// threads_mutex guards threads and each thread's event_loop, so
	// server_shutdown, which may run on any thread, never wakes a loop that is
	// gone or reads threads while serve frees it.
	threads_mutex:        sync.Mutex,
	// Once the server starts closing/shutdown this is set to true, all threads will check it
	// and start their thread local shutdown procedure.
	closing:              Atomic(bool),
	// Threads will decrement the wait group when they have fully closed/shutdown.
	// The main thread waits on this to clean up global data and return.
	threads_closed:       sync.Wait_Group,
	// interrupt_read becomes readable when SIGINT arrives, once
	// server_shutdown_on_interrupt armed it.
	interrupt_read:       ^os.File,
	interrupt_write:      ^os.File,
}

Server_Thread :: struct {
	thread:      ^thread.Thread,
	event_loop:  ^nbio.Event_Loop,
	connections: map[net.TCP_Socket]^Connection,
	state:       Server_State,
	accept:      ^nbio.Operation,
	interrupt:   ^nbio.Operation,
	// The Date field value for date_second, formatted once per second on the
	// thread that sends it, so no response formats a date and no thread shares one.
	date_second: i64,
	date:        [HTTP_DATE_LENGTH]byte,
}

// current_thread is the calling thread's own server thread, which every handler
// and every connection callback runs on.
@(thread_local)
current_thread: ^Server_Thread

@(private, disabled = ODIN_DISABLE_ASSERT)
assert_on_server_thread :: #force_inline proc(loc := #caller_location) {
	assert(current_thread.state != .Uninitialized, "The thread you are calling from is not a server/handler thread", loc)
}

Default_Endpoint := net.Endpoint {
	address = net.IP4_Any,
	port    = 8080,
}

Server_Error :: union #shared_nil {
	net.Network_Error,
	nbio.General_Error,
	mem.Allocator_Error,
}

listen :: proc(server: ^Server, endpoint: net.Endpoint = Default_Endpoint, opts: Server_Opts = Default_Server_Opts) -> (err: Server_Error) {
	server.opts = opts
	server.connection_allocator = context.allocator

	if loop_err := nbio.acquire_thread_event_loop(); loop_err != nil { return loop_err }
	listen_err: net.Network_Error
	server.tcp_socket, listen_err = nbio.listen_tcp(endpoint)
	if listen_err != nil {
		nbio.release_thread_event_loop()
		return listen_err
	}
	return nil
}

serve :: proc(server: ^Server, handler: Handler) -> (err: Server_Error) {
	if atomic_load(&server.closing) { return }
	server.handler = handler

	if server.opts.thread_count == 0 {
		server.opts.thread_count = os.get_processor_core_count()
	}

	thread_count := max(1, server.opts.thread_count)
	threads, threads_err := make([]Server_Thread, thread_count, server.connection_allocator)
	if threads_err != nil { return threads_err }
	sync.wait_group_add(&server.threads_closed, thread_count)
	sync.mutex_lock(&server.threads_mutex)
	server.threads = threads
	for &server_thread in server.threads[1:] {
		server_thread.thread = thread.create_and_start_with_poly_data2(server, &server_thread, _server_thread_init, context)
	}
	sync.mutex_unlock(&server.threads_mutex)

	_server_thread_init(server, &server.threads[0])

	sync.wait(&server.threads_closed)

	// A failed shutdown changes nothing: the socket closes on the next line.
	_ = net.shutdown(server.tcp_socket, .Both)
	net.close(server.tcp_socket)
	sync.mutex_lock(&server.threads_mutex)
	defer sync.mutex_unlock(&server.threads_mutex)
	for server_thread in server.threads[1:] { thread.destroy(server_thread.thread) }
	delete(server.threads, server.connection_allocator)
	server.threads = nil
	return nil
}

listen_and_serve :: proc(
	server: ^Server,
	handler: Handler,
	endpoint: net.Endpoint = Default_Endpoint,
	opts: Server_Opts = Default_Server_Opts,
) -> (
	err: Server_Error,
) {
	listen(server, endpoint, opts) or_return
	return serve(server, handler)
}

_server_thread_init :: proc(server: ^Server, server_thread: ^Server_Thread) {
	current_thread = server_thread
	defer sync.wait_group_done(&server.threads_closed)

	if current_thread != &server.threads[0] {
		if err := nbio.acquire_thread_event_loop(); err != nil {
			log.errorf("a server thread could not start its event loop: %v", err)
			return
		}
	}
	current_thread.connections = make(map[net.TCP_Socket]^Connection)
	sync.mutex_lock(&server.threads_mutex)
	current_thread.event_loop = nbio.current_thread_event_loop()
	sync.mutex_unlock(&server.threads_mutex)

	current_thread.accept = nbio.accept_poly(server.tcp_socket, server, on_accept)
	if current_thread == &server.threads[0] && server.interrupt_read != nil {
		// The event loop polls descriptors, and the pipe's read end is one.
		current_thread.interrupt = nbio.poll_poly(net.TCP_Socket(os.fd(server.interrupt_read)), .Receive, server, on_interrupt)
	}

	current_thread.state = .Serving
	for current_thread.state != .Closed {
		if atomic_load(&server.closing) {
			_server_thread_shutdown(server)
			break
		}
		if err := nbio.tick(); err != nil {
			log.errorf("non-blocking io tick error: %v", err)
			break
		}
	}

	if current_thread != &server.threads[0] {
		runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
	}
}

// server_shutdown starts a graceful shutdown from any thread: every thread
// stops accepting, closes its connections that are between requests, lets the
// active ones finish their response, and ends once it has none left. serve
// then returns.
server_shutdown :: proc(server: ^Server) {
	atomic_store(&server.closing, true)
	sync.guard(&server.threads_mutex)
	for &server_thread in server.threads {
		// A thread's own loop needs no wake: it checks on its next turn.
		if &server_thread != current_thread && server_thread.event_loop != nil { nbio.wake_up(server_thread.event_loop) }
	}
}

_server_thread_shutdown :: proc(server: ^Server, loc := #caller_location) {
	assert_on_server_thread(loc)

	current_thread.state = .Closing
	if current_thread.accept != nil {
		nbio.remove(current_thread.accept)
		current_thread.accept = nil
	}
	if current_thread.interrupt != nil {
		nbio.remove(current_thread.interrupt)
		current_thread.interrupt = nil
	}

	// Connections between requests close now; active ones close after their
	// response, because clean_request_loop sees the server closing. Every
	// state change arrives through the loop, so ticking waits for the next.
	for len(current_thread.connections) > 0 {
		for _, connection in current_thread.connections {
			#partial switch connection.state {
			case .New, .Idle, .Pending:
				connection_close(connection)
			}
		}
		if err := nbio.tick(); err != nil {
			log.errorf("non-blocking io tick error during shutdown: %v", err)
			break
		}
	}
	delete(current_thread.connections)

	current_thread.state = .Cleaning
	if err := nbio.run(); err != nil {
		log.errorf("non-blocking io error while draining: %v", err)
	}
	sync.mutex_lock(&server.threads_mutex)
	current_thread.event_loop = nil
	sync.mutex_unlock(&server.threads_mutex)
	nbio.release_thread_event_loop()
	current_thread.state = .Closed
}

@(private)
on_interrupt_write: posix.FD = -1

@(private)
on_interrupt_signal :: proc "c" (_: posix.Signal) {
	// write is async-signal-safe; the byte only makes the pipe readable.
	signaled := u8(1)
	posix.write(on_interrupt_write, &signaled, 1)
}

@(private)
on_interrupt :: proc(op: ^nbio.Operation, server: ^Server) {
	current_thread.interrupt = nil
	server_shutdown(server)
}

// server_shutdown_on_interrupt shuts the server down gracefully on SIGINT. The
// signal handler only writes to a pipe the server's first thread waits on, so
// the shutdown itself runs in ordinary thread context. Call it before serve,
// once per program: the pipe stays open for the handler it serves.
server_shutdown_on_interrupt :: proc(server: ^Server) -> os.Error {
	read, write := os.pipe() or_return
	server.interrupt_read, server.interrupt_write = read, write
	on_interrupt_write = posix.FD(os.fd(write))

	action := posix.sigaction_t {
		sa_handler = on_interrupt_signal,
	}
	posix.sigemptyset(&action.sa_mask)
	if posix.sigaction(.SIGINT, &action, nil) != .OK {
		return os.Platform_Error(posix.errno())
	}
	return nil
}

// ACCEPT_RETRY_DELAY is how long accepting pauses when the process is out of
// descriptors, so the loop serves its open connections instead of spinning on
// a listen queue it cannot drain.
@(private)
ACCEPT_RETRY_DELAY :: time.Second

// CLOSE_LINGER bounds the read after a half-close. RFC 9112 9.6: the server
// reads until the client closes, or until it is reasonably certain the client
// received the last response, so a client that never closes cannot hold the
// connection.
@(private)
CLOSE_LINGER :: 500 * time.Millisecond

Connection_State :: enum {
	Pending, // Pending a client to attach.
	New, // Got client, waiting to service first request.
	Active, // Servicing request.
	Idle, // Waiting for next request.
	Will_Close, // Closing after the current response is sent.
	Closing, // Going to close, cleaning up.
	Closed, // Fully closed.
}

@(private)
connection_set_state :: proc(connection: ^Connection, state: Connection_State) -> bool {
	if state < .Closing && connection.state >= .Closing {
		return false
	}

	if state == .Closing && connection.state == .Closed {
		return false
	}

	connection.state = state
	return true
}

Connection :: struct {
	server:         ^Server,
	socket:         net.TCP_Socket,
	state:          Connection_State,
	scanner:        Scanner,
	temp_allocator: virtual.Arena,
	loop:           Loop,
	close_deadline: time.Time,
}

// Loop/request cycle state.
@(private)
Loop :: struct {
	connection: ^Connection,
	request:    Request,
	response:   Response,
}

// connection_close ends a connection in the stages RFC 9112 9.6 describes: it
// closes the write side, reads until the client closes or CLOSE_LINGER passes,
// and only then closes the socket, so the client is not sent a reset that could
// discard the response it has not read yet.
@(private)
connection_close :: proc(connection: ^Connection, loc := #caller_location) {
	assert_on_server_thread(loc)
	if connection.state >= .Closing { return }
	connection.state = .Closing

	// A read still waiting for the next request must never complete into a
	// closing connection.
	if connection.scanner.recv != nil {
		nbio.remove(connection.scanner.recv)
		connection.scanner.recv = nil
	}
	if len(connection.scanner.buffer) == 0 && resize(&connection.scanner.buffer, INIT_BUF_SIZE) != nil {
		connection_release(connection)
		return
	}

	// A failed half-close changes nothing: the linger read still ends the
	// connection, and the socket closes after it.
	_ = net.shutdown(connection.socket, .Send)
	connection.close_deadline = time.time_add(nbio.now(), CLOSE_LINGER)
	nbio.recv_poly(connection.socket, {connection.scanner.buffer[:]}, connection, on_linger_read, timeout = CLOSE_LINGER)
}

@(private)
on_linger_read :: proc(op: ^nbio.Operation, connection: ^Connection) {
	remaining := time.diff(nbio.now(), connection.close_deadline)
	if op.recv.err == nil && op.recv.received > 0 && remaining > 0 {
		nbio.recv_poly(connection.socket, {connection.scanner.buffer[:]}, connection, on_linger_read, timeout = remaining)
		return
	}
	connection_release(connection)
}

@(private)
connection_release :: proc(connection: ^Connection) {
	nbio.close_poly(connection.socket, connection, proc(_: ^nbio.Operation, connection: ^Connection) {
		connection.state = .Closed
		virtual.arena_destroy(&connection.temp_allocator)
		scanner_destroy(&connection.scanner)
		delete_key(&current_thread.connections, connection.socket)
		free(connection, connection.server.connection_allocator)
	})
}

@(private)
on_accept :: proc(op: ^nbio.Operation, server: ^Server) {
	current_thread.accept = nil
	if atomic_load(&server.closing) {
		if op.accept.err == nil { net.close(op.accept.client) }
		return
	}

	if op.accept.err != nil {
		#partial switch op.accept.err {
		case .Insufficient_Resources:
			log.error("out of descriptors, pausing accepts")
			nbio.timeout_poly(ACCEPT_RETRY_DELAY, server, proc(_: ^nbio.Operation, server: ^Server) {
				if !atomic_load(&server.closing) { current_thread.accept = nbio.accept_poly(server.tcp_socket, server, on_accept) }
			})
		case:
			// A failed accept concerns one client that went away; the listener
			// keeps serving the rest.
			log.warnf("accept error: %v", op.accept.err)
			current_thread.accept = nbio.accept_poly(server.tcp_socket, server, on_accept)
		}
		return
	}

	// Accept next connection.
	current_thread.accept = nbio.accept_poly(server.tcp_socket, server, on_accept)

	connection, alloc_error := new(Connection, server.connection_allocator)
	if alloc_error != nil {
		log.errorf("a connection could not be allocated: %v", alloc_error)
		net.close(op.accept.client)
		return
	}
	connection.state = .New
	connection.server = server
	connection.socket = op.accept.client
	connection.loop.request.client = op.accept.client_endpoint
	current_thread.connections[connection.socket] = connection

	scanner_init(&connection.scanner, connection, server.connection_allocator)
	if err := virtual.arena_init_growing(&connection.temp_allocator); err != nil {
		log.errorf("a connection arena could not be created: %v", err)
		connection_close(connection)
		return
	}
	context.temp_allocator = virtual.arena_allocator(&connection.temp_allocator)
	connection_handle_request(connection, context.temp_allocator)
}

// respond_early answers a request the server rejects before a handler sees it,
// and closes the connection after, since the rest of what the client sent can
// no longer be framed.
@(private)
respond_early :: proc(loop: ^Loop, status: Status) {
	headers_set_close(&loop.response.headers)
	loop.response.status = status
	respond(&loop.response)
}

@(private)
connection_handle_request :: proc(connection: ^Connection, allocator := context.temp_allocator) {
	on_request_line :: proc(loop_data: rawptr, token: string, err: bufio.Scanner_Error) {
		loop := cast(^Loop)loop_data

		if !connection_set_state(loop.connection, .Active) { return }

		// RFC 9112 2.2: a server SHOULD ignore at least one empty line received
		// before the request-line.
		if err == nil && len(token) == 0 {
			scanner_scan(&loop.connection.scanner, loop_data, on_request_line_parse)
			return
		}

		on_request_line_parse(loop_data, token, err)
	}

	on_request_line_parse :: proc(loop_data: rawptr, token: string, err: bufio.Scanner_Error) {
		loop := cast(^Loop)loop_data

		if err == .Too_Long {
			respond_early(loop, .URI_Too_Long)
			return
		}
		if err != nil {
			if err != .EOF { log.warnf("request scanning error: %v", err) }
			clean_request_loop(loop.connection, close_connection = true)
			return
		}

		line, line_err := requestline_parse(token, context.temp_allocator)
		switch line_err {
		case .Method_Not_Implemented:
			respond_early(loop, .Not_Implemented)
			return
		case .Invalid_Version_Format, .Not_Enough_Fields:
			// RFC 9112 3: an invalid request-line is answered with 400.
			respond_early(loop, .Bad_Request)
			return
		case .Allocation:
			// The request line could not be copied, so this request cannot be
			// served; the connection closes after the response.
			respond_early(loop, .Internal_Server_Error)
			return
		case .None:
		}

		// RFC 9110 2.5: a later HTTP/1 minor version is handled as the highest
		// one this server implements, and a different major version is refused.
		if line.version.major != 1 {
			respond_early(loop, .HTTP_Version_Not_Supported)
			return
		}
		loop.request.line = line
		loop.request.url = url_parse(line.target.(string))

		loop.connection.scanner.max_token_size = loop.connection.server.opts.limit_headers
		scanner_scan(&loop.connection.scanner, loop_data, on_header_line)
	}

	on_header_line :: proc(loop_data: rawptr, token: string, err: bufio.Scanner_Error) {
		loop := cast(^Loop)loop_data

		if err == .Too_Long {
			respond_early(loop, .Request_Header_Fields_Too_Large)
			return
		}
		if err != nil {
			log.warnf("request scanning error: %v", err)
			clean_request_loop(loop.connection, close_connection = true)
			return
		}

		// The first empty line denotes the end of the headers section.
		if len(token) == 0 {
			on_headers_end(loop)
			return
		}

		// A field line that does not parse, including an obs-fold, which RFC
		// 9112 5.2 lets a server reject, is answered with 400.
		if _, ok := header_parse(&loop.request.headers, token); !ok {
			respond_early(loop, .Bad_Request)
			return
		}

		if loop.connection.scanner.max_token_size > 0 {
			loop.connection.scanner.max_token_size -= len(token)
			if loop.connection.scanner.max_token_size <= 0 {
				respond_early(loop, .Request_Header_Fields_Too_Large)
				return
			}
		}

		scanner_scan(&loop.connection.scanner, loop_data, on_header_line)
	}

	on_headers_end :: proc(loop: ^Loop) {
		loop.connection.scanner.max_token_size = 0
		line := loop.request.line.(Requestline)
		headers := &loop.request.headers

		valid, will_close := headers_validate_for_server(headers, line.version)
		if !valid {
			respond_early(loop, .Bad_Request)
			return
		}
		if will_close { connection_set_state(loop.connection, .Will_Close) }

		headers.readonly = true

		// RFC 9110 10.1.1: the expectation is case-insensitive, and one in an
		// HTTP/1.0 request is ignored.
		expect, expects := headers_get_unsafe(headers^, "expect")
		if expects && line.version.minor >= 1 && loop.connection.server.opts.auto_expect_continue && strings.equal_fold(expect, "100-continue") {
			nbio.send_poly(loop.connection.socket, {transmute([]byte)string(CONTINUE_RESPONSE)}, loop, on_continue_sent)
			return
		}
		dispatch(loop)
	}

	on_continue_sent :: proc(op: ^nbio.Operation, loop: ^Loop) {
		context.temp_allocator = virtual.arena_allocator(&loop.connection.temp_allocator)
		if op.send.err != nil {
			clean_request_loop(loop.connection, close_connection = true)
			return
		}
		dispatch(loop)
	}

	dispatch :: proc(loop: ^Loop) {
		line := &loop.request.line.(Requestline)
		// OPTIONS with "*" asks about the server itself, not a resource
		// (RFC 9110 9.3.7), so no handler answers it.
		if line.method == .Options && line.target.(string) == "*" {
			loop.response.status = .OK
			respond(&loop.response)
			return
		}
		// RFC 9110 9.3.2: HEAD is GET without the content, so a handler that
		// answers GET answers HEAD, and the response is sent without its body.
		if line.method == .Head {
			loop.request.is_head = true
			if loop.connection.server.opts.redirect_head_to_get { line.method = .Get }
		}
		loop.connection.server.handler.handle(&loop.connection.server.handler, &loop.request, &loop.response)
	}

	connection.loop.connection = connection
	connection.loop.response._conn = connection
	connection.loop.request._scanner = &connection.scanner
	request_init(&connection.loop.request, allocator)
	response_init(&connection.loop.response, allocator)

	connection.scanner.max_token_size = connection.server.opts.limit_request_line
	scanner_scan(&connection.scanner, &connection.loop, on_request_line)
}

// CONTINUE_RESPONSE is the interim response that asks the client to send the
// content it is holding back (RFC 9110 15.2.1).
@(private)
CONTINUE_RESPONSE :: "HTTP/1.1 100 Continue\r\n\r\n"

// server_date returns the Date field value for the current second.
@(private)
server_date :: proc() -> string {
	now := time.now()
	second := time.to_unix_seconds(now)
	if second != current_thread.date_second {
		current_thread.date_second = second
		builder := strings.builder_from_bytes(current_thread.date[:])
		// The date is a fixed-length format written into an exactly sized buffer,
		// so the write cannot fail.
		_ = date_write(strings.to_writer(&builder), now)
	}
	return string(current_thread.date[:])
}
