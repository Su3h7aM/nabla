package client

import "core:fmt"
import "core:mem"
import "core:net"

import "nabla:tls"

// This file is where this client hands the socket to the TLS layer: the adapter
// that lets tls move bytes, the mapping from its errors onto this client's own,
// and the hostname rules the handshake is tied to.

// tls_transport moves the plaintext a TLS session reads and writes through the same
// socket movers the rest of this client uses, so neither side can take bytes the
// other has. A connection whose probe ends the request ends the transport too, which
// is the only interruption the TLS layer needs to know about.
tls_transport :: proc(connection: ^Connection) -> tls.Transport {
	return {read = connection_transport_read, write = connection_transport_write, user_data = connection}
}

connection_transport_read :: proc(user_data: rawptr, buffer: []u8) -> (count: int, ok: bool) {
	connection := cast(^Connection)user_data
	read, err := connection_read_socket(connection, buffer)
	return read, err == .None
}

connection_transport_write :: proc(user_data: rawptr, buffer: []u8) -> (count: int, ok: bool) {
	connection := cast(^Connection)user_data
	written, err := connection_write_socket(connection, buffer)
	return written, err == .None
}

// tls_error maps what the TLS layer reported onto this client's classification. A
// transport that failed is this client's own business, so the caller's reason is
// preferred over anything the TLS layer could guess.
tls_error :: proc(connection: ^Connection, tls_err: tls.Error, fallback: Error) -> Error {
	if tls_err == .Transport {
		if connection.stop != .None { return error_from_stop(connection.stop) }
		return .Truncated
	}
	switch tls_err {
	case .None:
		return .None
	case .Transport:
		unreachable()
	case .Record, .Handshake, .Alert:
		return .TLS_Handshake
	case .Unsupported, .No_Room:
		return .TLS_Config
	case .Peer_Rejected, .Signature, .Finished:
		// The peer's own chain or its proof of it was not acceptable.
		return .TLS_Peer_Rejected
	}
	return fallback
}

// handshake_failure_detail is this client's account of a failed handshake, with the
// peer's own alert added when it sent one: an alert description is the only reason a
// server gives, and a server that speaks no version this client does says so that way.
// An empty string leaves the account to error_text.
handshake_failure_detail :: proc(connection: ^Connection, err: Error, allocator: mem.Allocator) -> string {
	alert := peer_alert_text(connection, allocator)
	if alert == "" { return "" }
	defer delete(alert, allocator)
	return fmt.aprintf("%s: %s", error_text(err), alert, allocator = allocator)
}

// peer_alert_text describes why the peer ended the handshake, and is empty when it did not
// end it itself. A close_notify carries no reason, and a peer that sends one has given up
// on the handshake rather than finished it.
peer_alert_text :: proc(connection: ^Connection, allocator: mem.Allocator) -> string {
	if connection.tls_conn == nil { return "" }
	if connection.tls_conn.peer_alert != 0 {
		description := tls.Alert_Description(connection.tls_conn.peer_alert)
		return fmt.aprintf("the peer sent the %v alert (%d)", description, connection.tls_conn.peer_alert, allocator = allocator)
	}
	if connection.tls_conn.closed {
		return fmt.aprintf("the peer closed the connection before the handshake finished", allocator = allocator)
	}
	return ""
}

// host_without_port returns the name alone, because a name that keeps its port
// can never match a certificate.
host_without_port :: proc(host: string) -> (name: string, is_ip: bool) {
	parsed, _, ok := host_and_port(host)
	if !ok { return "", false }
	return parsed, net.parse_address(parsed) != nil
}
