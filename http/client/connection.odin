package client

import "core:c"
import "core:mem"
import "core:net"

// Connection owns one socket and, for TLS, its session and context. Its holder is
// the sole I/O owner, so no thread frees TLS state while a read is in flight.
// Connect, handshake, writes, and reads are interruptible; name resolution is not.
Connection :: struct {
	socket:      net.TCP_Socket,
	ssl:         ^SSL,
	ctx:         ^SSL_CTX,
	probe:       Probe,
	ca_file:     string,
	allocator:   mem.Allocator,
	stop:        Transport_Stop,
	nonblocking: bool,
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
	connection := new(Connection, allocator)
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

// connection_handshake completes TLS and verifies the peer chain. A failed
// verification never yields a usable connection.
connection_handshake :: proc(connection: ^Connection, host: string) -> Error {
	ctx, ctx_err := tls_client_ctx_new(connection.ca_file, connection.allocator)
	if ctx_err != .None { return ctx_err }
	connection.ctx = ctx
	ssl := SSL_new(ctx)
	if ssl == nil { return .TLS_Config }
	connection.ssl = ssl
	if SSL_set_fd(ssl, c.int(i32(i64(connection.socket)))) != 1 { return .TLS_Config }
	if identity_err := tls_set_peer_identity(ssl, host, connection.allocator); identity_err != .None { return identity_err }
	for {
		result := SSL_connect(ssl)
		if result == 1 { break }
		switch SSL_get_error(ssl, result) {
		case SSL_ERROR_WANT_READ:
			if stop := connection_wait(connection, .Read); stop != .None { return error_from_stop(stop) }
		case SSL_ERROR_WANT_WRITE:
			if stop := connection_wait(connection, .Write); stop != .None { return error_from_stop(stop) }
		case SSL_ERROR_ZERO_RETURN:
			connection.stop = .Peer_Closed
			return .Closed
		case SSL_ERROR_SYSCALL:
			connection.stop = .Truncated
			return .Truncated
		case:
			if ssl_peer_closed() {
				connection.stop = .Peer_Closed
				return .Closed
			}
			return .TLS_Handshake
		}
	}
	if SSL_get_verify_result(ssl) != 0 { return .TLS_Peer_Rejected }
	return .None
}

// connection_write_all retries the same buffer after a retryable result and only
// advances past bytes the peer actually accepted. accepted counts plaintext bytes
// the socket or the TLS layer took, which is not evidence that the peer received
// them; a failure still reports what was taken before it, so a caller can tell a
// request that never started from one that stopped halfway.
connection_write_all :: proc(connection: ^Connection, buffer: []u8) -> (accepted: int, err: Error) {
	pending := buffer
	for len(pending) > 0 {
		if probed := stop_from_wait(probe_now(connection.probe)); probed != .None {
			if connection.stop == .None { connection.stop = probed }
			return accepted, error_from_stop(probed)
		}

		written: int
		if connection.ssl != nil {
			result := SSL_write(connection.ssl, raw_data(pending), c.int(len(pending)))
			if result > 0 {
				written = int(result)
			} else {
				switch SSL_get_error(connection.ssl, result) {
				case SSL_ERROR_WANT_READ:
					if stop := connection_wait(connection, .Read); stop != .None { return accepted, error_from_stop(stop) }
					continue
				case SSL_ERROR_WANT_WRITE:
					if stop := connection_wait(connection, .Write); stop != .None { return accepted, error_from_stop(stop) }
					continue
				case SSL_ERROR_ZERO_RETURN:
					connection.stop = .Peer_Closed
					return accepted, .Closed
				case:
					if ssl_peer_closed() {
						connection.stop = .Peer_Closed
						return accepted, .Closed
					}
					connection.stop = .Truncated
					return accepted, .TLS_Write
				}
			}
		} else {
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
		if written <= 0 {
			connection.stop = .Truncated
			return accepted, .Truncated
		}
		pending = pending[written:]
		accepted += written
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
	for {
		// A body that keeps flowing never leaves a read blocked, so waiting
		// alone would never ask the probe whether to stop. Asking here gives
		// cancellation and deadlines a check on every read, flowing or stalled.
		if probed := stop_from_wait(probe_now(connection.probe)); probed != .None {
			if connection.stop == .None { connection.stop = probed }
			return 0, error_from_stop(probed)
		}
		if connection.ssl != nil {
			result := SSL_read(connection.ssl, raw_data(buffer), c.int(len(buffer)))
			if result > 0 { return int(result), .None }
			switch SSL_get_error(connection.ssl, result) {
			case SSL_ERROR_WANT_READ:
				if stop := connection_wait(connection, .Read); stop != .None { return 0, error_from_stop(stop) }
				continue
			case SSL_ERROR_WANT_WRITE:
				if stop := connection_wait(connection, .Write); stop != .None { return 0, error_from_stop(stop) }
				continue
			case SSL_ERROR_ZERO_RETURN:
				connection.stop = .Peer_Closed
				return 0, .Closed
			case SSL_ERROR_SYSCALL:
				connection.stop = .Truncated
				return 0, .Truncated
			case:
				if ssl_peer_closed() {
					connection.stop = .Truncated
					return 0, .Truncated
				}
				connection.stop = .Truncated
				return 0, .TLS_Read
			}
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

connection_destroy :: proc(connection: ^Connection) {
	if connection == nil { return }
	if connection.ssl != nil {
		if connection.stop == .None && !connection.nonblocking { _ = SSL_shutdown(connection.ssl) }
		SSL_free(connection.ssl)
		connection.ssl = nil
	}
	if connection.ctx != nil {
		SSL_CTX_free(connection.ctx)
		connection.ctx = nil
	}
	if connection.socket != 0 {
		net.close(connection.socket)
		connection.socket = 0
	}
	allocator := connection.allocator
	free(connection, allocator)
}
