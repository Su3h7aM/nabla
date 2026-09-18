package websocket

import "core:fmt"
import "core:mem"
import "core:strings"

import "nabla:http"
import "nabla:http/client"

// Dial_Options is what a caller supplies to open a WebSocket.
Dial_Options :: struct {
	// http is the policy of the handshake request: cancellation, deadlines, the
	// trust store to verify the peer with, and the request's own observers.
	http:    client.Options,
	// headers are added to the handshake request, which is how a caller states what
	// its peer expects of it, an authorization field among them. Whatever a caller
	// asks for here, the caller reads the response's answer to itself.
	headers: []client.Header,
}

// Dial_Error is how the handshake failed.
Dial_Error :: enum {
	None,
	// Exchange is a failure before any response arrived: the URL, the name, the
	// connection, TLS, or the request write.
	Exchange,
	// Response is a response that does not accept the upgrade.
	Response,
}

// Dial_Failure explains why a WebSocket could not be opened. It owns its detail, so
// one destructor releases any of them.
Dial_Failure :: struct {
	kind:   Dial_Error,
	// cause is the transport error the exchange ended on, and is .None when a
	// response arrived.
	cause:  client.Error,
	// status is the response status, and is zero when no response arrived.
	status: int,
	detail: string,
}

dial_failure_destroy :: proc(failure: ^Dial_Failure, allocator: mem.Allocator) {
	if failure == nil { return }
	if failure.detail != "" { delete(failure.detail, allocator) }
	failure^ = {}
}

// dial opens a WebSocket at url, over ws or wss, and returns it. The handshake asks
// the peer to take the connection over, and the response must accept it: a 101 whose
// fields name the upgrade and whose Sec-WebSocket-Accept answers the key this call
// sent (RFC 6455 4.1).
//
// The connection owns the socket and the TLS session beneath it, so destroy closes
// both. A failure owns its detail, released by dial_failure_destroy with the same
// allocator.
dial :: proc(url: string, options: Dial_Options, allocator := context.allocator) -> (conn: ^Conn, failure: Dial_Failure) {
	exchange_url, url_ok := http_url(url, allocator)
	defer delete(exchange_url, allocator)
	if !url_ok {
		return nil, Dial_Failure {
			kind   = .Exchange,
			detail = strings.clone("the URL is not a ws or wss one", allocator),
		}
	}

	nonce: [NONCE_ENCODED_SIZE]u8
	key := nonce_generate(nonce[:])

	// The caller's fields come first, so a field both supply is written once, by the
	// caller.
	headers := make([dynamic]client.Header, 0, len(options.headers) + 4, allocator)
	defer delete(headers)
	append(&headers, ..options.headers)
	append(&headers,
		client.Header{name = "upgrade", value = "websocket"},
		client.Header{name = "connection", value = "Upgrade"},
		client.Header{name = "sec-websocket-version", value = "13"},
		client.Header{name = "sec-websocket-key", value = key},
	)

	request := client.Request {
		url       = exchange_url,
		method    = .Get,
		headers   = headers[:],
		allocator = allocator,
	}

	upgraded, exchange_failure := client.upgrade_request(request, options.http)
	if exchange_failure.kind != .None {
		kind := Dial_Error.Exchange
		if exchange_failure.kind == .HTTP_Status { kind = .Response }
		return nil, Dial_Failure {
			kind   = kind,
			cause  = exchange_failure.cause,
			status = exchange_failure.status,
			detail = exchange_failure.detail,
		}
	}

	if accept_failure := response_accepts(upgraded, key, allocator); accept_failure.kind != .None {
		client.upgraded_destroy(upgraded)
		return nil, accept_failure
	}

	connection, err := init(transport_for(upgraded), allocator)
	if err != .None {
		client.upgraded_destroy(upgraded)
		return nil, Dial_Failure {
			kind   = .Exchange,
			detail = strings.clone("the WebSocket connection could not be prepared", allocator),
		}
	}
	return connection, {}
}

// http_url states a WebSocket URL as the HTTP URL of the same request, which is what
// it is: RFC 6455 4.1 gives an HTTP request over TCP the scheme ws and one over TLS the
// scheme wss. A URL that is not a WebSocket one is refused.
http_url :: proc(url: string, allocator: mem.Allocator) -> (converted: string, ok: bool) {
	parsed := http.url_parse(url)
	scheme: string
	switch parsed.scheme {
	case "ws":
		scheme = "http"
	case "wss":
		scheme = "https"
	case:
		return "", false
	}
	if parsed.host == "" { return "", false }

	path := http.request_path(parsed, allocator)
	defer delete(path, allocator)
	return fmt.aprintf("%s://%s%s", scheme, parsed.host, path, allocator = allocator), true
}

// response_accepts reports why a response does not accept the handshake request.
// RFC 6455 4.1 makes each of these a failure of the WebSocket connection, because a
// connection that was not accepted is not a WebSocket.
response_accepts :: proc(upgraded: ^client.Upgraded, key: string, allocator: mem.Allocator) -> Dial_Failure {
	upgrade, has_upgrade := http.headers_get_unsafe(upgraded.headers, "upgrade")
	if !has_upgrade || !field_has_token(upgrade, "websocket") {
		return response_refusal(allocator, "the response does not upgrade the connection to websocket")
	}
	connection, has_connection := http.headers_get_unsafe(upgraded.headers, "connection")
	if !has_connection || !field_has_token(connection, "Upgrade") {
		return response_refusal(allocator, "the response does not name the upgrade in its connection field")
	}
	accept, has_accept := http.headers_get_unsafe(upgraded.headers, "sec-websocket-accept")
	expected := accept_key(key)
	if !has_accept || accept != string(expected[:]) {
		return response_refusal(allocator, "the response does not accept the key this client sent")
	}
	return {}
}

response_refusal :: proc(allocator: mem.Allocator, detail: string) -> Dial_Failure {
	return Dial_Failure {
		kind   = .Response,
		status = 101,
		detail = strings.clone(detail, allocator),
	}
}

// field_has_token reports whether a field value holds one of a list of tokens,
// compared without case, since HTTP field values are not case-sensitive
// (RFC 9110 5.6.1).
field_has_token :: proc(value, token: string) -> bool {
	remaining := value
	for part in strings.split_iterator(&remaining, ",") {
		if strings.equal_fold(http.trim_ows(part), token) { return true }
	}
	return false
}

// transport_for reads and writes an upgraded connection, and closes it when the
// WebSocket is destroyed.
transport_for :: proc(upgraded: ^client.Upgraded) -> Transport {
	return Transport {
		read      = upgraded_read,
		write     = upgraded_write,
		release   = upgraded_release,
		user_data = upgraded,
	}
}

@(private)
upgraded_read :: proc(user_data: rawptr, buffer: []u8) -> (count: int, err: Error) {
	upgraded := cast(^client.Upgraded)user_data
	read, read_err := client.upgraded_read(upgraded, buffer)
	// The exchange's own classification is kept: an orderly end of stream is the
	// peer's close, and a cancellation or a deadline is not.
	if read_err == .Closed { return read, .Closed }
	if read_err != .None { return read, .Transport }
	return read, .None
}

@(private)
upgraded_write :: proc(user_data: rawptr, buffer: []u8) -> (count: int, err: Error) {
	upgraded := cast(^client.Upgraded)user_data
	accepted, write_err := client.upgraded_write(upgraded, buffer)
	if write_err != .None { return accepted, .Transport }
	return accepted, .None
}

@(private)
upgraded_release :: proc(user_data: rawptr) {
	client.upgraded_destroy(cast(^client.Upgraded)user_data)
}
