package client

import "core:nbio"
import "core:net"
import "core:strings"

import "nabla:http"

// connect_request establishes a tunnel to authority through proxy_url, which is
// the endpoint resolved and dialed. proxy_url may name the tunnel destination
// directly. A 2xx response returns an Upgraded connection; other statuses stream
// their ordinarily framed response body to callback and return an HTTP_Status
// failure. Validation, cancellation, timeout, TLS, transport, allocation, and
// malformed-response failures use their corresponding Failure kinds. The result
// and any failure detail are owned by allocator. The caller releases a response
// with upgraded_destroy and a failure with failure_destroy.
@(require_results)
connect_request :: proc(
	authority: string,
	proxy_url: string,
	headers: []Header,
	options: Options,
	user_data: rawptr,
	callback: Chunk_Callback,
	allocator := context.allocator,
) -> (
	response: ^Upgraded,
	failure: Failure,
) {
	summary: Transfer_Summary
	phase := Transfer_Phase.Validate
	defer {
		summary.stopped_at = phase
		summary.error = failure.cause
		if options.observer.complete != nil {
			options.observer.complete(options.observer.user_data, summary)
		}
	}

	if loop_failure := event_loop_acquire(allocator); loop_failure.kind != .None { return nil, loop_failure }
	defer nbio.release_thread_event_loop()

	request := Request {
		url       = proxy_url,
		method    = .Connect,
		headers   = headers,
		allocator = allocator,
	}
	connection, send_failure := request_send(request, options, &phase, &summary, authority)
	if send_failure.kind != .None { return nil, send_failure }
	defer if connection != nil { connection_destroy(connection) }

	phase = .Response_Head
	reader: Reader
	if reader_err := reader_init(&reader, connection_read_source, connection, allocator); reader_err != .None {
		return nil, failure_from_error(reader_err, allocator)
	}
	defer reader_destroy(&reader)

	head, response_headers, head_err := read_final_response_head(&reader, allocator, .Connect)
	defer http.headers_destroy(&response_headers)
	if head_err != .None { return nil, failure_from_error(head_err, allocator) }

	status := head.code
	summary.response_head_received = true
	summary.status = status
	status_usable := status >= 200 && status < 300
	if options.response_head.observed != nil {
		observed_head := Response_Head {
			status = status,
			usable = status_usable,
		}
		options.response_head.observed(options.response_head.user_data, observed_head, response_headers)
	}

	// RFC 9110 9.3.6 switches every successful CONNECT response to tunnel mode
	// immediately after this header section.
	if status_usable {
		handoff, response_err := upgraded_make(connection, &reader, response_headers, allocator)
		if response_err != .None { return nil, failure_from_error(response_err, allocator) }
		connection = nil
		response_headers = {}
		phase = .Complete
		return handoff, {}
	}

	failure = Failure {
		kind   = .HTTP_Status,
		status = status,
		detail = status_detail(status, allocator),
	}
	phase = .Response_Body
	framing, length, framing_err := response_framing(status, head.version, .Connect, response_headers)
	if framing_err == .None && framing == .Exact {
		summary.declared_body_bytes = u64(length)
		summary.declared_body_bytes_present = true
	}
	if framing_err != .None { return nil, failure }
	if body_err := stream_body(&reader, framing, length, user_data, callback); body_err != .None {
		failure.cause = body_err
		return nil, failure
	}
	phase = .Complete
	return nil, failure
}

// connect_authority_valid accepts the authority-form CONNECT requires: a URI
// reg-name or bracketed IPv6 literal, followed by a nonzero decimal TCP port.
@(require_results)
connect_authority_valid :: proc(authority: string) -> bool {
	if len(authority) == 0 { return false }

	host: string
	port_text: string
	if authority[0] == '[' {
		closing := strings.index_byte(authority, ']')
		if closing <= 1 || closing + 1 >= len(authority) || authority[closing + 1] != ':' { return false }
		_, ipv6_ok := net.parse_ip6_address(authority[1:closing])
		if !ipv6_ok { return false }
		host = authority[1:closing]
		port_text = authority[closing + 2:]
	} else {
		separator := -1
		for character, index in authority {
			if character == ':' {
				if separator >= 0 { return false }
				separator = index
			}
		}
		if separator <= 0 || separator == len(authority) - 1 { return false }
		host = authority[:separator]
		port_text = authority[separator + 1:]
		if !connect_reg_name_valid(host) { return false }
	}
	_, port_ok := parse_port(port_text)
	return port_ok
}

@(require_results)
connect_reg_name_valid :: proc(name: string) -> bool {
	if name == "" { return false }
	index := 0
	for index < len(name) {
		character := name[index]
		if character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character >= '0' && character <= '9' {
			index += 1
			continue
		}
		switch character {
		// RFC 3986 3.2.2: unreserved and sub-delims.
		case '-', '.', '_', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=':
			index += 1
			continue
		case '%':
			if len(name) - index < 3 || !connect_hex_digit(name[index + 1]) || !connect_hex_digit(name[index + 2]) {
				return false
			}
			index += 3
			continue
		case:
			return false
		}
	}
	return true
}

@(require_results)
connect_hex_digit :: proc(character: u8) -> bool {
	return character >= '0' && character <= '9' || character >= 'a' && character <= 'f' || character >= 'A' && character <= 'F'
}
