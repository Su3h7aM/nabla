package client

import "core:mem"
import "core:net"
import "core:os"

import "core:crypto/x509"

import "nabla:tls"

// Connection owns one socket and, once the handshake has run, its TLS session. Its
// holder is the sole I/O owner, so no thread frees TLS state while a read is in
// flight. Connect, handshake, writes, and reads are interruptible; name resolution
// is not.
Connection :: struct {
	socket:      net.TCP_Socket,
	tls_conn:    ^tls.Conn,
	roots:       tls.Roots,
	anchors:     []^x509.Certificate,
	probe:       Probe,
	ca_file:     string,
	allocator:   mem.Allocator,
	stop:        Transport_Stop,
	nonblocking: bool,
}

// dial_first dials each candidate in order and returns the first connection
// that answers. An unreachable address moves on to the next; only the
// caller's own stop ends the attempts, so fallback never becomes a way to
// ignore cancellation.
dial_first :: proc(endpoints: []net.Endpoint, options: Options, allocator: mem.Allocator) -> (connection: ^Connection, err: Error) {
	for endpoint in endpoints {
		if stop := stop_from_wait(probe_now(options.probe)); stop != .None {
			return nil, error_from_stop(stop)
		}
		dialed, dial_err := connection_dial(endpoint, options, allocator)
		if dial_err == .None { return dialed, .None }
		if dial_err != .Connect { return nil, dial_err }
	}
	return nil, .Connect
}

// connection_dial returns nil on failure, so a caller never owns a half-built
// connection. It waits on the calling thread's core:nbio event loop, which the
// caller must have acquired.
//
// The probe decides which connect core offers. Waiting for a connect and asking
// the probe whether to stop at the same time needs an event loop, so a probe
// selects nbio's dial. With nothing to interrupt the attempt, core:net's own
// blocking dial is the whole requirement, and the socket it returns blocks.
connection_dial :: proc(endpoint: net.Endpoint, options: Options, allocator: mem.Allocator) -> (^Connection, Error) {
	if endpoint.port == 0 { return nil, .Connect }
	connection, alloc_error := new(Connection, allocator)
	if alloc_error != nil { return nil, .No_Room }
	connection.allocator = allocator
	connection.probe = options.probe
	connection.ca_file = options.ca_file
	connection.nonblocking = options.probe.check != nil

	socket: net.TCP_Socket
	if connection.nonblocking {
		stop: Transport_Stop
		socket, stop = wait_connected(endpoint, connection.probe)
		if stop != .None {
			connection_destroy(connection)
			return nil, error_from_stop(stop)
		}
		if socket == 0 {
			connection_destroy(connection)
			return nil, .Connect
		}
	} else {
		dialed, dial_err := net.dial_tcp_from_endpoint(endpoint)
		if dial_err != nil {
			connection_destroy(connection)
			return nil, .Connect
		}
		socket = dialed
	}

	connection.socket = socket
	return connection, .None
}

// PLATFORM_STORES are the files a Linux system keeps its trust anchors in, in the order
// this client tries them: Debian, Ubuntu, Arch, and Alpine keep the first, Red Hat and
// Fedora the second, and openSUSE the third. The bundle is present on every system this
// targets, and the hash-named directory some distributions keep beside it answers the
// same question at the cost of a directory scan, so it is not read.
PLATFORM_STORES := [?]string{"/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt", "/etc/ssl/ca-bundle.pem", "/etc/ssl/cert.pem"}

// load_roots reads the trust store this connection verifies against: the caller's own
// when it named one, and the platform's otherwise. A store is either read whole or not
// used at all, since a store this client could only partly read would refuse peers the
// platform accepts.
load_roots :: proc(connection: ^Connection) -> (roots: tls.Roots, ok: bool) {
	if connection.ca_file != "" {
		return read_roots(connection, connection.ca_file)
	}
	for path in PLATFORM_STORES {
		if found, found_ok := read_roots(connection, path); found_ok { return found, true }
	}
	return {}, false
}

read_roots :: proc(connection: ^Connection, path: string) -> (roots: tls.Roots, ok: bool) {
	store, read_err := os.read_entire_file(path, connection.allocator)
	if read_err != nil { return {}, false }
	defer delete(store, connection.allocator)
	return tls.roots_parse(store, connection.allocator)
}

// connection_handshake loads the trust store, completes TLS, and verifies the peer's
// chain and its name. A failed verification never yields a usable connection, and a
// store that cannot be loaded is a failure rather than an unverified connection.
connection_handshake :: proc(connection: ^Connection, host: string) -> Error {
	name, _ := host_without_port(host)
	if name == "" { return .TLS_Hostname }

	roots, roots_ok := load_roots(connection)
	if !roots_ok { return .TLS_Trust }
	connection.roots = roots
	connection.anchors = tls.certificate_pointers(roots.certificates, connection.allocator)

	conn, init_err := tls.init(tls_transport(connection), {roots = connection.anchors, allocator = connection.allocator})
	if init_err != tls.Error.None { return .TLS_Config }
	connection.tls_conn = conn

	if err := tls.handshake(conn, name, TLS_ALPN); err != tls.Error.None {
		return tls_error(connection, err, .TLS_Handshake)
	}
	return .None
}

// TLS_ALPN is what this client speaks over TLS. A server that negotiates something
// else is not answering in a framing this client can read.
TLS_ALPN :: []string{"http/1.1"}

// connection_write_all retries the same buffer after a retryable result and only
// advances past bytes the peer actually accepted. accepted counts plaintext bytes
// the socket or the TLS layer took, which is not evidence that the peer received
// them; a failure still reports what was taken before it, so a caller can tell a
// request that never started from one that stopped halfway.
connection_write_all :: proc(connection: ^Connection, buffer: []u8) -> (accepted: int, err: Error) {
	if connection.tls_conn != nil { return connection_write_tls(connection, buffer) }
	return connection_write_socket(connection, buffer)
}

// connection_write_tls hands plaintext to the TLS session, which owns the socket's
// bytes from there on.
connection_write_tls :: proc(connection: ^Connection, buffer: []u8) -> (accepted: int, err: Error) {
	written, tls_err := tls.write(connection.tls_conn, buffer)
	if tls_err == tls.Error.None { return written, .None }
	return written, tls_error(connection, tls_err, .TLS_Write)
}

// connection_write_socket writes plaintext straight to the socket, waiting on the
// event loop when the socket will not take it. TLS writes through this too, so a
// record layer has no second way to reach the socket.
connection_write_socket :: proc(connection: ^Connection, buffer: []u8) -> (accepted: int, err: Error) {
	pending := buffer
	for len(pending) > 0 {
		if probed := stop_from_wait(probe_now(connection.probe)); probed != .None {
			if connection.stop == .None { connection.stop = probed }
			return accepted, error_from_stop(probed)
		}

		// net.send_tcp may accept a prefix before a later send would block or
		// fail. Consume that prefix before handling the error, or a retry writes
		// the same bytes twice.
		count, send_err := net.send_tcp(connection.socket, pending)
		if count > 0 {
			pending = pending[count:]
			accepted += count
		}
		#partial switch send_err {
		case nil:
			if count == 0 {
				connection.stop = .Truncated
				return accepted, .Truncated
			}
			continue
		case .Would_Block:
			if stop := connection_wait(connection, .Write); stop != .None { return accepted, error_from_stop(stop) }
			continue
		case .Interrupted:
			continue
		case .Connection_Closed, .Not_Connected:
			connection.stop = .Peer_Closed
			return accepted, .Closed
		case:
			connection.stop = .Truncated
			return accepted, .Send
		}
	}
	return accepted, .None
}

// connection_read_source adapts connection_read to the Reader's byte source. Odin
// procedure types are nominal, so the typed connection pointer cannot stand in
// for the rawptr the source takes.
connection_read_source :: proc(user_data: rawptr, buffer: []u8) -> (count: int, err: Error) {
	return connection_read(cast(^Connection)user_data, buffer)
}

// connection_read returns .Closed for an orderly end of stream. The caller decides
// whether the message was complete.
connection_read :: proc(connection: ^Connection, buffer: []u8) -> (count: int, err: Error) {
	if connection.tls_conn != nil { return connection_read_tls(connection, buffer) }
	return connection_read_socket(connection, buffer)
}

// connection_read_tls reads plaintext out of the TLS session. The session owns the
// connection_read_tls takes plaintext out of the TLS session. The session owns the
// socket's bytes from there on.
connection_read_tls :: proc(connection: ^Connection, buffer: []u8) -> (count: int, err: Error) {
	read, tls_err := tls.read(connection.tls_conn, buffer)
	switch tls_err {
	case .None:
		// A close_notify is the peer's orderly end of the stream, which reads the
		// same as a socket that has no more bytes.
		if read == 0 { return 0, .Closed }
		return read, .None
	case .Transport:
		return 0, tls_error(connection, tls_err, .Truncated)
	case .Record, .Handshake, .Alert, .Unsupported, .No_Room, .Peer_Rejected, .Signature, .Finished:
		return 0, tls_error(connection, tls_err, .TLS_Read)
	}
	return 0, .TLS_Read
}

// connection_read_socket moves plaintext off the socket, waiting on the event loop
// when there is none. TLS reads the socket through this and nothing else, so a
// record layer can never see bytes the message path already took.
connection_read_socket :: proc(connection: ^Connection, buffer: []u8) -> (count: int, err: Error) {
	for {
		// A body that keeps flowing never leaves a read blocked, so waiting
		// alone would never ask the probe whether to stop. Asking here gives
		// cancellation and deadlines a check on every read, flowing or stalled.
		if probed := stop_from_wait(probe_now(connection.probe)); probed != .None {
			if connection.stop == .None { connection.stop = probed }
			return 0, error_from_stop(probed)
		}
		received, recv_err := net.recv_tcp(connection.socket, buffer)
		#partial switch recv_err {
		case nil:
			if received == 0 {
				if connection.stop == .None { connection.stop = .Peer_Closed }
				return 0, .Closed
			}
			return received, .None
		case .Would_Block:
			if stop := connection_wait(connection, .Read); stop != .None { return 0, error_from_stop(stop) }
			continue
		case .Interrupted:
			continue
		case .Connection_Closed, .Not_Connected:
			if connection.stop == .None { connection.stop = .Peer_Closed }
			return 0, .Closed
		case .Timeout:
			connection.stop = .Timed_Out
			return 0, .Timed_Out
		case:
			connection.stop = .Truncated
			return 0, .Recv
		}
	}
}

// connection_wait waits on the event loop until the socket is ready, or the
// caller's probe ends the request. Cancellation is reported ahead of readiness,
// so an accepted cancellation can never turn into a success.
connection_wait :: proc(connection: ^Connection, kind: Ready_For) -> Transport_Stop {
	result, stop := wait_ready(connection.socket, kind, connection.probe)
	if result == .Ready { return .None }
	if connection.stop == .None { connection.stop = stop }
	return stop
}

connection_abort :: proc(connection: ^Connection) {
	if connection == nil { return }
	if connection.stop == .None { connection.stop = .Cancelled }
	connection_destroy(connection)
}

connection_destroy :: proc(connection: ^Connection) {
	if connection == nil { return }
	if connection.tls_conn != nil {
		// A close_notify is the polite end of a TLS stream, but sending it can wait
		// on a peer that has stopped reading, so it goes out only when this
		// connection was not the interruptible kind and the request ended well.
		if connection.stop == .None && !connection.nonblocking { _ = tls.close(connection.tls_conn) }
		tls.destroy(connection.tls_conn)
		connection.tls_conn = nil
	}
	delete(connection.anchors, connection.allocator)
	tls.roots_destroy(&connection.roots)
	if connection.socket != 0 {
		net.close(connection.socket)
		connection.socket = 0
	}
	allocator := connection.allocator
	free(connection, allocator)
}
