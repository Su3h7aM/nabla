package sse

import "core:mem"

import "nabla:http/client"

// Post_Request is one request for an event stream. allocator owns the assembled
// header list for the duration of the call; the header values belong to the
// caller.
Post_Request :: struct {
	url:       string,
	body:      []u8,
	// headers are the request's own fields, authentication included. This call
	// adds only what every event-stream request has: the content type and the
	// accept type it is asking for. How an API authenticates is its provider's
	// business, not the transport's.
	headers:   []client.Header,
	allocator: mem.Allocator,
}

// post performs one POST that expects a text/event-stream response and delivers
// the response body to callback as it arrives.
//
// Transport policy stays with the caller: options carries the caller's wait
// hook, so cancellation and deadlines are the caller's decision rather than
// something invented here. The returned failure is the transport's own
// classification, not a caller-specific taxonomy -- mapping it into provider
// error kinds is the caller's job.
post :: proc(request: Post_Request, options: client.Options, user_data: rawptr, callback: client.Chunk_Callback) -> client.Failure {
	headers := make([dynamic]client.Header, 0, len(request.headers) + 2, request.allocator)
	defer delete(headers)
	append(&headers, client.Header{"content-type", "application/json"})
	append(&headers, client.Header{"accept", CONTENT_TYPE})
	append(&headers, ..request.headers)

	return client.stream_request(
		{url = request.url, method = .Post, headers = headers[:], body = request.body, expected_content_type = CONTENT_TYPE, allocator = request.allocator},
		options,
		user_data,
		callback,
	)
}
