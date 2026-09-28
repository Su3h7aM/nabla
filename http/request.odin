package http

import "core:net"

Request :: struct {
	// If in a handler, this is always there and never None.
	// TODO: we should not expose this as a maybe to package users.
	line:       Maybe(Requestline),

	// Is true if the request is actually a HEAD request,
	// line.method will be .Get if Server_Opts.redirect_head_to_get is set.
	is_head:    bool,
	headers:    Headers,
	url:        URL,
	client:     net.Endpoint,

	// Route params/captures.
	url_params: []string,

	// Internal usage only.
	_scanner:   ^Scanner,
	_body_ok:   Maybe(bool),
}

request_init :: proc(request: ^Request, allocator := context.allocator) {
	headers_init(&request.headers, allocator)
}

// headers_validate_for_server checks a request's header section the way a
// server must before it reads the content, and normalizes its framing: a
// Content-Length next to a Transfer-Encoding is removed, because the transfer
// coding overrides it (RFC 9112 6.1). valid is false for a request that is
// answered with 400; will_close is true for one after whose response the
// connection closes.
@(require_results)
headers_validate_for_server :: proc(headers: ^Headers, version: Version) -> (valid: bool, will_close: bool) {
	// RFC 9112 3.2: an HTTP/1.1 request must carry Host. More than one Host
	// field line is refused by header_parse.
	if version.minor >= 1 && !headers_has_unsafe(headers^, "host") { return false, true }

	if coding, has_coding := headers_get_unsafe(headers^, "transfer-encoding"); has_coding {
		// RFC 9112 6.1: Transfer-Encoding in an HTTP/1.0 message is faulty
		// framing, and RFC 9112 6.3 item 4: chunked must be the final coding.
		if version.minor == 0 || !final_transfer_coding_is_chunked(coding) { return false, true }
		// RFC 9112 6.1: the connection closes after responding to a request
		// that carried both framing fields.
		if headers_has_unsafe(headers^, "content-length") {
			headers_delete_unsafe(headers, "content-length")
			return true, true
		}
		return true, false
	}
	// RFC 9112 6.3 item 5: an invalid Content-Length is answered with 400.
	if length, has_length := headers_get_unsafe(headers^, "content-length"); has_length {
		if _, length_ok := content_length_parse(length); !length_ok { return false, true }
	}
	return true, false
}
