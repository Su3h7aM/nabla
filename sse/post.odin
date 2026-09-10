package sse

import "core:mem"
import "core:strings"

import "nabla:http/client"

// Post_Request is one request for an event stream. allocator owns the derived
// header values for the duration of the call.
Post_Request :: struct {
	url:          string,
	body:         []u8,
	bearer_token: string,
	allocator:    mem.Allocator,
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
	headers: [3]client.Header
	count := 0
	headers[count] = {"content-type", "application/json"}; count += 1
	headers[count] = {"accept", "text/event-stream"}; count += 1
	token := ""
	defer delete(token, request.allocator)
	if request.bearer_token != "" {
		token = strings.concatenate([]string{"Bearer ", request.bearer_token}, allocator = request.allocator)
		headers[count] = {"authorization", token}; count += 1
	}

	return client.stream_request(
		{
			url = request.url,
			method = .Post,
			headers = headers[:count],
			body = request.body,
			expected_content_type = "text/event-stream",
			allocator = request.allocator,
		},
		options,
		user_data,
		callback,
	)
}
