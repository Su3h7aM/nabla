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
	opts:            Server_Opts,
	tcp_sock:        net.TCP_Socket,
	conn_allocator:  mem.Allocator,
	handler:         Handler,
	threads:         []Server_Thread,
	// threads_mutex guards threads and each thread's event_loop, so
	// server_shutdown, which may run on any thread, never wakes a loop that is
	// gone or reads threads while serve frees it.
	threads_mutex:   sync.Mutex,
	// Once the server starts closing/shutdown this is set to true, all threads will check it
	// and start their thread local shutdown procedure.
	closing:         Atomic(bool),
	// Threads will decrement the wait group when they have fully closed/shutdown.
	// The main thread waits on this to clean up global data and return.
	threads_closed:  sync.Wait_Group,
	// interrupt_read becomes readable when SIGINT arrives, once
	// server_shutdown_on_interrupt armed it.
	interrupt_read:  ^os.File,
	interrupt_write: ^os.File,
}

Server_Thread :: struct {
	thread:      ^thread.Thread,
	event_loop:  ^nbio.Event_Loop,
	conns:       map[net.TCP_Socket]^Connection,
	state:       Server_State,
	accept:      ^nbio.Operation,
	interrupt:   ^nbio.Operation,
	// The Date field value for date_second, formatted once per second on the
	// thread that sends it, so no response formats a date and no thread shares one.
	date_second: i64,
	date:        [HTTP_DATE_LENGTH]byte,
}

@(private, disabled = ODIN_DISABLE_ASSERT)
assert_has_td :: #force_inline proc(loc := #caller_location) {
	assert(td.state != .Uninitialized, "The thread you are calling from is not a server/handler thread", loc)
}

@(thread_local)
td: ^Server_Thread

Default_Endpoint := net.Endpoint {
	address = net.IP4_Any,
	port    = 8080,
}

Server_Error :: union #shared_nil {
	net.Network_Error,
	nbio.General_Error,
}

listen :: proc(s: ^Server, endpoint: net.Endpoint = Default_Endpoint, opts: Server_Opts = Default_Server_Opts) -> (err: Server_Error) {
	s.opts = opts
	s.conn_allocator = context.allocator

	if loop_err := nbio.acquire_thread_event_loop(); loop_err != nil { return loop_err }
	listen_err: net.Network_Error
	s.tcp_sock, listen_err = nbio.listen_tcp(endpoint)
	if listen_err != nil {
		nbio.release_thread_event_loop()
		return listen_err
	}
	return nil
}

serve :: proc(s: ^Server, h: Handler) -> (err: Server_Error) {
	if atomic_load(&s.closing) { return }
	s.handler = h

	if s.opts.thread_count == 0 {
		s.opts.thread_count = os.get_processor_core_count()
	}

	thread_count := max(1, s.opts.thread_count)
	sync.wait_group_add(&s.threads_closed, thread_count)
	sync.mutex_lock(&s.threads_mutex)
	s.threads = make([]Server_Thread, thread_count, s.conn_allocator)
	for &td in s.threads[1:] {
		td.thread = thread.create_and_start_with_poly_data2(s, &td, _server_thread_init, context)
	}
	sync.mutex_unlock(&s.threads_mutex)

	_server_thread_init(s, &s.threads[0])

	sync.wait(&s.threads_closed)

	net.shutdown(s.tcp_sock, .Both)
	net.close(s.tcp_sock)
	sync.mutex_lock(&s.threads_mutex)
	defer sync.mutex_unlock(&s.threads_mutex)
	for t in s.threads[1:] { thread.destroy(t.thread) }
	delete(s.threads, s.conn_allocator)
	s.threads = nil
	return nil
}

listen_and_serve :: proc(s: ^Server, h: Handler, endpoint: net.Endpoint = Default_Endpoint, opts: Server_Opts = Default_Server_Opts) -> (err: Server_Error) {
	listen(s, endpoint, opts) or_return
	return serve(s, h)
}

_server_thread_init :: proc(s: ^Server, ttd: ^Server_Thread) {
	td = ttd
	defer sync.wait_group_done(&s.threads_closed)

	if td != &s.threads[0] {
		if err := nbio.acquire_thread_event_loop(); err != nil {
			log.errorf("a server thread could not start its event loop: %v", err)
			return
		}
	}
	td.conns = make(map[net.TCP_Socket]^Connection)
	sync.mutex_lock(&s.threads_mutex)
	td.event_loop = nbio.current_thread_event_loop()
	sync.mutex_unlock(&s.threads_mutex)

	td.accept = nbio.accept_poly(s.tcp_sock, s, on_accept)
	if td == &s.threads[0] && s.interrupt_read != nil {
		// The event loop polls descriptors, and the pipe's read end is one.
		td.interrupt = nbio.poll_poly(net.TCP_Socket(os.fd(s.interrupt_read)), .Receive, s, on_interrupt)
	}

	td.state = .Serving
	for td.state != .Closed {
		if atomic_load(&s.closing) {
			_server_thread_shutdown(s)
			break
		}
		if err := nbio.tick(); err != nil {
			log.errorf("non-blocking io tick error: %v", err)
			break
		}
	}

	if td != &s.threads[0] {
		runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
	}
}

// server_shutdown starts a graceful shutdown from any thread: every thread
// stops accepting, closes its connections that are between requests, lets the
// active ones finish their response, and ends once it has none left. serve
// then returns.
server_shutdown :: proc(s: ^Server) {
	atomic_store(&s.closing, true)
	sync.guard(&s.threads_mutex)
	for &t in s.threads {
		// A thread's own loop needs no wake: it checks on its next turn.
		if &t != td && t.event_loop != nil { nbio.wake_up(t.event_loop) }
	}
}

_server_thread_shutdown :: proc(s: ^Server, loc := #caller_location) {
	assert_has_td(loc)

	td.state = .Closing
	if td.accept != nil {
		nbio.remove(td.accept)
		td.accept = nil
	}
	if td.interrupt != nil {
		nbio.remove(td.interrupt)
		td.interrupt = nil
	}

	// Connections between requests close now; active ones close after their
	// response, because clean_request_loop sees the server closing. Every
	// state change arrives through the loop, so ticking waits for the next.
	for len(td.conns) > 0 {
		for _, conn in td.conns {
			#partial switch conn.state {
			case .New, .Idle, .Pending:
				connection_close(conn)
			}
		}
		if err := nbio.tick(); err != nil {
			log.errorf("non-blocking io tick error during shutdown: %v", err)
			break
		}
	}
	delete(td.conns)

	td.state = .Cleaning
	if err := nbio.run(); err != nil {
		log.errorf("non-blocking io error while draining: %v", err)
	}
	sync.mutex_lock(&s.threads_mutex)
	td.event_loop = nil
	sync.mutex_unlock(&s.threads_mutex)
	nbio.release_thread_event_loop()
	td.state = .Closed
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
on_interrupt :: proc(op: ^nbio.Operation, s: ^Server) {
	td.interrupt = nil
	server_shutdown(s)
}

// server_shutdown_on_interrupt shuts the server down gracefully on SIGINT. The
// signal handler only writes to a pipe the server's first thread waits on, so
// the shutdown itself runs in ordinary thread context. Call it before serve,
// once per program: the pipe stays open for the handler it serves.
server_shutdown_on_interrupt :: proc(s: ^Server) -> os.Error {
	read, write := os.pipe() or_return
	s.interrupt_read, s.interrupt_write = read, write
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
connection_set_state :: proc(c: ^Connection, s: Connection_State) -> bool {
	if s < .Closing && c.state >= .Closing {
		return false
	}

	if s == .Closing && c.state == .Closed {
		return false
	}

	c.state = s
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
	conn: ^Connection,
	req:  Request,
	res:  Response,
}

// connection_close ends a connection in the stages RFC 9112 9.6 describes: it
// closes the write side, reads until the client closes or CLOSE_LINGER passes,
// and only then closes the socket, so the client is not sent a reset that could
// discard the response it has not read yet.
@(private)
connection_close :: proc(c: ^Connection, loc := #caller_location) {
	assert_has_td(loc)
	if c.state >= .Closing { return }
	c.state = .Closing

	// A read still waiting for the next request must never complete into a
	// closing connection.
	if c.scanner.recv != nil {
		nbio.remove(c.scanner.recv)
		c.scanner.recv = nil
	}
	if len(c.scanner.buf) == 0 && resize(&c.scanner.buf, INIT_BUF_SIZE) != nil {
		connection_release(c)
		return
	}

	net.shutdown(c.socket, .Send)
	c.close_deadline = time.time_add(nbio.now(), CLOSE_LINGER)
	nbio.recv_poly(c.socket, {c.scanner.buf[:]}, c, on_linger_read, timeout = CLOSE_LINGER)
}

@(private)
on_linger_read :: proc(op: ^nbio.Operation, c: ^Connection) {
	remaining := time.diff(nbio.now(), c.close_deadline)
	if op.recv.err == nil && op.recv.received > 0 && remaining > 0 {
		nbio.recv_poly(c.socket, {c.scanner.buf[:]}, c, on_linger_read, timeout = remaining)
		return
	}
	connection_release(c)
}

@(private)
connection_release :: proc(c: ^Connection) {
	nbio.close_poly(c.socket, c, proc(_: ^nbio.Operation, c: ^Connection) {
		c.state = .Closed
		virtual.arena_destroy(&c.temp_allocator)
		scanner_destroy(&c.scanner)
		delete_key(&td.conns, c.socket)
		free(c, c.server.conn_allocator)
	})
}

@(private)
on_accept :: proc(op: ^nbio.Operation, server: ^Server) {
	td.accept = nil
	if atomic_load(&server.closing) {
		if op.accept.err == nil { net.close(op.accept.client) }
		return
	}

	if op.accept.err != nil {
		#partial switch op.accept.err {
		case .Insufficient_Resources:
			log.error("out of descriptors, pausing accepts")
			nbio.timeout_poly(ACCEPT_RETRY_DELAY, server, proc(_: ^nbio.Operation, server: ^Server) {
				if !atomic_load(&server.closing) { td.accept = nbio.accept_poly(server.tcp_sock, server, on_accept) }
			})
		case:
			// A failed accept concerns one client that went away; the listener
			// keeps serving the rest.
			log.warnf("accept error: %v", op.accept.err)
			td.accept = nbio.accept_poly(server.tcp_sock, server, on_accept)
		}
		return
	}

	// Accept next connection.
	td.accept = nbio.accept_poly(server.tcp_sock, server, on_accept)

	c, alloc_err := new(Connection, server.conn_allocator)
	if alloc_err != nil {
		log.errorf("a connection could not be allocated: %v", alloc_err)
		net.close(op.accept.client)
		return
	}
	c.state = .New
	c.server = server
	c.socket = op.accept.client
	c.loop.req.client = op.accept.client_endpoint
	td.conns[c.socket] = c

	scanner_init(&c.scanner, c, server.conn_allocator)
	if err := virtual.arena_init_growing(&c.temp_allocator); err != nil {
		log.errorf("a connection arena could not be created: %v", err)
		connection_close(c)
		return
	}
	context.temp_allocator = virtual.arena_allocator(&c.temp_allocator)
	conn_handle_req(c, context.temp_allocator)
}

// respond_early answers a request the server rejects before a handler sees it,
// and closes the connection after, since the rest of what the client sent can
// no longer be framed.
@(private)
respond_early :: proc(l: ^Loop, status: Status) {
	headers_set_close(&l.res.headers)
	l.res.status = status
	respond(&l.res)
}

@(private)
conn_handle_req :: proc(c: ^Connection, allocator := context.temp_allocator) {
	on_rline1 :: proc(loop: rawptr, token: string, err: bufio.Scanner_Error) {
		l := cast(^Loop)loop

		if !connection_set_state(l.conn, .Active) { return }

		// RFC 9112 2.2: a server SHOULD ignore at least one empty line received
		// before the request-line.
		if err == nil && len(token) == 0 {
			scanner_scan(&l.conn.scanner, loop, on_rline2)
			return
		}

		on_rline2(loop, token, err)
	}

	on_rline2 :: proc(loop: rawptr, token: string, err: bufio.Scanner_Error) {
		l := cast(^Loop)loop

		if err == .Too_Long {
			respond_early(l, .URI_Too_Long)
			return
		}
		if err != nil {
			if err != .EOF { log.warnf("request scanning error: %v", err) }
			clean_request_loop(l.conn, close = true)
			return
		}

		rline, rline_err := requestline_parse(token, context.temp_allocator)
		switch rline_err {
		case .Method_Not_Implemented:
			respond_early(l, .Not_Implemented)
			return
		case .Invalid_Version_Format, .Not_Enough_Fields:
			// RFC 9112 3: an invalid request-line is answered with 400.
			respond_early(l, .Bad_Request)
			return
		case .None:
		}

		// RFC 9110 2.5: a later HTTP/1 minor version is handled as the highest
		// one this server implements, and a different major version is refused.
		if rline.version.major != 1 {
			respond_early(l, .HTTP_Version_Not_Supported)
			return
		}
		l.req.line = rline
		l.req.url = url_parse(rline.target.(string))

		l.conn.scanner.max_token_size = l.conn.server.opts.limit_headers
		scanner_scan(&l.conn.scanner, loop, on_header_line)
	}

	on_header_line :: proc(loop: rawptr, token: string, err: bufio.Scanner_Error) {
		l := cast(^Loop)loop

		if err == .Too_Long {
			respond_early(l, .Request_Header_Fields_Too_Large)
			return
		}
		if err != nil {
			log.warnf("request scanning error: %v", err)
			clean_request_loop(l.conn, close = true)
			return
		}

		// The first empty line denotes the end of the headers section.
		if len(token) == 0 {
			on_headers_end(l)
			return
		}

		// A field line that does not parse, including an obs-fold, which RFC
		// 9112 5.2 lets a server reject, is answered with 400.
		if _, ok := header_parse(&l.req.headers, token); !ok {
			respond_early(l, .Bad_Request)
			return
		}

		if l.conn.scanner.max_token_size > 0 {
			l.conn.scanner.max_token_size -= len(token)
			if l.conn.scanner.max_token_size <= 0 {
				respond_early(l, .Request_Header_Fields_Too_Large)
				return
			}
		}

		scanner_scan(&l.conn.scanner, loop, on_header_line)
	}

	on_headers_end :: proc(l: ^Loop) {
		l.conn.scanner.max_token_size = 0
		line := l.req.line.(Requestline)
		headers := &l.req.headers

		valid, close := headers_validate_for_server(headers, line.version)
		if !valid {
			respond_early(l, .Bad_Request)
			return
		}
		if close { connection_set_state(l.conn, .Will_Close) }

		headers.readonly = true

		// RFC 9110 10.1.1: the expectation is case-insensitive, and one in an
		// HTTP/1.0 request is ignored.
		expect, expects := headers_get_unsafe(headers^, "expect")
		if expects && line.version.minor >= 1 && l.conn.server.opts.auto_expect_continue && strings.equal_fold(expect, "100-continue") {
			nbio.send_poly(l.conn.socket, {transmute([]byte)string(CONTINUE_RESPONSE)}, l, on_continue_sent)
			return
		}
		dispatch(l)
	}

	on_continue_sent :: proc(op: ^nbio.Operation, l: ^Loop) {
		context.temp_allocator = virtual.arena_allocator(&l.conn.temp_allocator)
		if op.send.err != nil {
			clean_request_loop(l.conn, close = true)
			return
		}
		dispatch(l)
	}

	dispatch :: proc(l: ^Loop) {
		rline := &l.req.line.(Requestline)
		// OPTIONS with "*" asks about the server itself, not a resource
		// (RFC 9110 9.3.7), so no handler answers it.
		if rline.method == .Options && rline.target.(string) == "*" {
			l.res.status = .OK
			respond(&l.res)
			return
		}
		// RFC 9110 9.3.2: HEAD is GET without the content, so a handler that
		// answers GET answers HEAD, and the response is sent without its body.
		if rline.method == .Head {
			l.req.is_head = true
			if l.conn.server.opts.redirect_head_to_get { rline.method = .Get }
		}
		l.conn.server.handler.handle(&l.conn.server.handler, &l.req, &l.res)
	}

	c.loop.conn = c
	c.loop.res._conn = c
	c.loop.req._scanner = &c.scanner
	request_init(&c.loop.req, allocator)
	response_init(&c.loop.res, allocator)

	c.scanner.max_token_size = c.server.opts.limit_request_line
	scanner_scan(&c.scanner, &c.loop, on_rline1)
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
	if second != td.date_second {
		td.date_second = second
		builder := strings.builder_from_bytes(td.date[:])
		date_write(strings.to_writer(&builder), now)
	}
	return string(td.date[:])
}
