package http

import "core:net"
import "core:strconv"
import "core:sync"
import "core:time"

Handler_Proc :: proc(handler: ^Handler, request: ^Request, response: ^Response)
Handle_Proc :: proc(request: ^Request, response: ^Response)

Handler :: struct {
	user_data: rawptr,
	next:      Maybe(^Handler),
	handle:    Handler_Proc,
}

// TODO: something like http.handler_with_body which gets the body before calling the handler.

handler :: proc(handle: Handle_Proc) -> Handler {
	result: Handler
	result.user_data = rawptr(handle)

	result.handle = proc(handler: ^Handler, request: ^Request, response: ^Response) {
		next := (Handle_Proc)(handler.user_data)
		next(request, response)
	}

	return result
}

middleware_proc :: proc(next: Maybe(^Handler), handle: Handler_Proc) -> Handler {
	result: Handler
	result.next = next
	result.handle = handle
	return result
}

Rate_Limit_On_Limit :: struct {
	user_data: rawptr,
	on_limit:  proc(request: ^Request, response: ^Response, user_data: rawptr),
}

// Convenience method to create a Rate_Limit_On_Limit that writes the given message.
rate_limit_message :: proc(message: ^string) -> Rate_Limit_On_Limit {
	return Rate_Limit_On_Limit{user_data = message, on_limit = proc(_: ^Request, response: ^Response, user_data: rawptr) {
			text := (^string)(user_data)
			body_set(response, text^)
			respond(response)
		}}
}

Rate_Limit_Opts :: struct {
	window:   time.Duration,
	max:      int,

	// Optional handler to call when a request is being rate-limited, allows you to customize the response.
	on_limit: Maybe(Rate_Limit_On_Limit),
}

Rate_Limit_Data :: struct {
	opts:       ^Rate_Limit_Opts,
	next_sweep: time.Time,
	hits:       map[net.Address]int,
	mu:         sync.Mutex,
}

rate_limit_destroy :: proc(data: ^Rate_Limit_Data) {
	sync.guard(&data.mu)
	delete(data.hits)
}

// Basic rate limit based on IP address.
rate_limit :: proc(data: ^Rate_Limit_Data, next: ^Handler, opts: ^Rate_Limit_Opts, allocator := context.allocator) -> Handler {
	assert(next != nil)

	result: Handler
	result.next = next

	data.opts = opts
	data.hits = make(map[net.Address]int, 16, allocator)
	data.next_sweep = time.time_add(time.now(), opts.window)
	result.user_data = data

	result.handle = proc(handler: ^Handler, request: ^Request, response: ^Response) {
		data := (^Rate_Limit_Data)(handler.user_data)

		sync.lock(&data.mu)

		// PERF: if this is not performing, we could run a thread that sweeps on a regular basis.
		if time.since(data.next_sweep) > 0 {
			clear(&data.hits)
			data.next_sweep = time.time_add(time.now(), data.opts.window)
		}

		hits := data.hits[request.client.address]
		data.hits[request.client.address] = hits + 1
		sync.unlock(&data.mu)

		if hits > data.opts.max {
			response.status = .Too_Many_Requests

			retry_after := i64(time.diff(time.now(), data.next_sweep) / time.Second)
			buffer := make([]byte, 32, context.temp_allocator)
			retry_text := strconv.write_int(buffer, retry_after, 10)
			headers_set_unsafe(&response.headers, "retry-after", retry_text)

			if on_limit, ok := data.opts.on_limit.(Rate_Limit_On_Limit); ok {
				on_limit.on_limit(request, response, on_limit.user_data)
			} else {
				respond(response)
			}
			return
		}

		next_handler := handler.next.(^Handler)
		next_handler.handle(next_handler, request, response)
	}

	return result
}
