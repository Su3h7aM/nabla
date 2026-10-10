package http

import "base:runtime"

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

// Rate_Limit_Callback is a retained callback invoked after the limiter unlocks.
Rate_Limit_Callback :: struct {
	user_data: rawptr,
	on_limit:  proc(request: ^Request, response: ^Response, user_data: rawptr),
}

// Rate_Limit_On_Limit borrows a message or stores a custom callback. The message
// and callback data must outlive the limiter.
Rate_Limit_On_Limit :: union {
	string,
	Rate_Limit_Callback,
}

// rate_limit_message borrows message until the limiter is destroyed.
rate_limit_message :: proc(message: string) -> Rate_Limit_On_Limit {
	return message
}

Rate_Limit_Opts :: struct {
	window:   time.Duration,
	max:      int,
	on_limit: Rate_Limit_On_Limit,
}

Rate_Limit_Data :: struct {
	opts:       Rate_Limit_Opts,
	next_sweep: time.Time,
	hits:       map[net.Address]int,
	mu:         sync.Mutex,
}

rate_limit_destroy :: proc(data: ^Rate_Limit_Data) {
	sync.guard(&data.mu)
	delete(data.hits)
}

// Basic rate limit based on IP address. mem_err is set, and no handler is
// returned, when the table the limiter counts in could not be allocated.
@(require_results)
rate_limit :: proc(
	data: ^Rate_Limit_Data,
	next: ^Handler,
	opts: Rate_Limit_Opts,
	allocator := context.allocator,
) -> (
	result: Handler,
	mem_err: runtime.Allocator_Error,
) {
	assert(next != nil)

	result.next = next

	data.opts = opts
	hits, make_err := make(map[net.Address]int, 16, allocator)
	if make_err != nil { return {}, make_err }
	data.hits = hits
	data.next_sweep = time.time_add(time.now(), opts.window)
	result.user_data = data

	result.handle = proc(handler: ^Handler, request: ^Request, response: ^Response) {
		data := (^Rate_Limit_Data)(handler.user_data)

		sync.lock(&data.mu)

		if time.since(data.next_sweep) > 0 {
			clear(&data.hits)
			data.next_sweep = time.time_add(time.now(), data.opts.window)
		}

		_, count, _, count_err := map_entry(&data.hits, request.client.address)
		if count_err != nil {
			sync.unlock(&data.mu)
			respond(response, .Internal_Server_Error)
			return
		}
		hits := count^
		count^ += 1
		next_sweep := data.next_sweep
		sync.unlock(&data.mu)

		if hits > data.opts.max {
			response.status = .Too_Many_Requests

			retry_after := i64(time.diff(time.now(), next_sweep) / time.Second)
			buffer: [32]byte
			retry_text := strconv.write_int(buffer[:], retry_after, 10)
			if _, err := headers_set_unsafe(&response.headers, "retry-after", retry_text); err != nil { response._err = err }

			switch on_limit in data.opts.on_limit {
			case string:
				if err := body_set(response, on_limit); err != nil { response._err = err }
				respond(response)
			case Rate_Limit_Callback:
				if on_limit.on_limit != nil { on_limit.on_limit(request, response, on_limit.user_data) } else { respond(response) }
			case nil:
				respond(response)
			}
			return
		}

		next_handler := handler.next.(^Handler)
		next_handler.handle(next_handler, request, response)
	}

	return result, nil
}
