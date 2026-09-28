package http

import "base:runtime"

import "core:log"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:text/match"

Query_Entry :: struct {
	key, value: string,
}

query_iter :: proc(query: ^string) -> (entry: Query_Entry, ok: bool) {
	if len(query) == 0 { return }

	ok = true

	pair: string
	separator := strings.index(query^, "&")
	if separator < 0 {
		pair = query^
		query^ = ""
	} else {
		pair = query[:separator]
		query^ = query[separator + 1:]
	}

	separator = strings.index(pair, "=")
	if separator < 0 {
		entry.key = pair
		entry.value = ""
		return
	}

	entry.key = pair[:separator]
	entry.value = pair[separator + 1:]

	return
}

query_get :: proc(url: URL, key: string) -> (value: string, ok: bool) #optional_ok {
	query := url.query
	for entry in #force_inline query_iter(&query) {
		if entry.key == key {
			return entry.value, true
		}
	}
	return
}

query_get_percent_decoded :: proc(url: URL, key: string, allocator := context.temp_allocator) -> (value: string, ok: bool) {
	encoded := query_get(url, key) or_return
	return net.percent_decode(encoded, allocator)
}

query_get_bool :: proc(url: URL, key: string) -> (result, set: bool) #optional_ok {
	text := query_get(url, key) or_return
	set = true
	switch text {
	case "", "false", "0", "no":
	case:
		result = true
	}
	return
}

query_get_int :: proc(url: URL, key: string, base := 0) -> (result: int, ok: bool, set: bool) {
	text := query_get(url, key) or_return
	set = true
	result, ok = strconv.parse_int(text, base)
	return
}

query_get_uint :: proc(url: URL, key: string, base := 0) -> (result: uint, ok: bool, set: bool) {
	text := query_get(url, key) or_return
	set = true
	result, ok = strconv.parse_uint(text, base)
	return
}

Route :: struct {
	handler: Handler,
	pattern: string,
}

Router :: struct {
	allocator: runtime.Allocator,
	routes:    map[Method][dynamic]Route,
	all:       [dynamic]Route,
}

router_init :: proc(router: ^Router, allocator := context.allocator) {
	router.allocator = allocator
	router.routes = make(map[Method][dynamic]Route, len(Method), allocator)
}

router_destroy :: proc(router: ^Router) {
	context.allocator = router.allocator

	for route in router.all {
		delete(route.pattern)
	}
	delete(router.all)

	for _, routes in router.routes {
		for route in routes {
			delete(route.pattern)
		}

		delete(routes)
	}

	delete(router.routes)
}

router_handler :: proc(router: ^Router) -> Handler {
	result: Handler
	result.user_data = router

	result.handle = proc(handler: ^Handler, request: ^Request, response: ^Response) {
		router := (^Router)(handler.user_data)
		line := request.line.(Requestline)

		if routes_try(router.routes[line.method], request, response) {
			return
		}

		if routes_try(router.all, request, response) {
			return
		}

		// The method is a structural fact. The target is peer-supplied text that a
		// persistent log has no business carrying, and a handler can record it
		// itself when it decides that is safe.
		log.infof("no route matched %s", method_string(line.method))
		response.status = .Not_Found
		respond(response)
	}

	return result
}

route_get :: proc(router: ^Router, pattern: string, handler: Handler) {
	route_add(router, .Get, Route{handler = handler, pattern = strings.concatenate([]string{"^", pattern, "$"}, router.allocator)})
}

route_post :: proc(router: ^Router, pattern: string, handler: Handler) {
	route_add(router, .Post, Route{handler = handler, pattern = strings.concatenate([]string{"^", pattern, "$"}, router.allocator)})
}

// NOTE: this does not get called when `Server_Opts.redirect_head_to_get` is set to true.
route_head :: proc(router: ^Router, pattern: string, handler: Handler) {
	route_add(router, .Head, Route{handler = handler, pattern = strings.concatenate([]string{"^", pattern, "$"}, router.allocator)})
}

route_put :: proc(router: ^Router, pattern: string, handler: Handler) {
	route_add(router, .Put, Route{handler = handler, pattern = strings.concatenate([]string{"^", pattern, "$"}, router.allocator)})
}

route_patch :: proc(router: ^Router, pattern: string, handler: Handler) {
	route_add(router, .Patch, Route{handler = handler, pattern = strings.concatenate([]string{"^", pattern, "$"}, router.allocator)})
}

route_trace :: proc(router: ^Router, pattern: string, handler: Handler) {
	route_add(router, .Trace, Route{handler = handler, pattern = strings.concatenate([]string{"^", pattern, "$"}, router.allocator)})
}

route_delete :: proc(router: ^Router, pattern: string, handler: Handler) {
	route_add(router, .Delete, Route{handler = handler, pattern = strings.concatenate([]string{"^", pattern, "$"}, router.allocator)})
}

route_connect :: proc(router: ^Router, pattern: string, handler: Handler) {
	route_add(router, .Connect, Route{handler = handler, pattern = strings.concatenate([]string{"^", pattern, "$"}, router.allocator)})
}

route_options :: proc(router: ^Router, pattern: string, handler: Handler) {
	route_add(router, .Options, Route{handler = handler, pattern = strings.concatenate([]string{"^", pattern, "$"}, router.allocator)})
}

// Adds a catch-all fallback route (all methods, ran if no other routes match).
route_all :: proc(router: ^Router, pattern: string, handler: Handler) {
	if router.all == nil {
		router.all = make([dynamic]Route, 0, 1, router.allocator)
	}

	append(&router.all, Route{handler = handler, pattern = strings.concatenate([]string{"^", pattern, "$"}, router.allocator)})
}

@(private)
route_add :: proc(router: ^Router, method: Method, route: Route) {
	if method not_in router.routes {
		router.routes[method] = make([dynamic]Route, router.allocator)
	}

	append(&router.routes[method], route)
}

@(private)
routes_try :: proc(routes: [dynamic]Route, request: ^Request, response: ^Response) -> bool {
	matches: [match.MAX_CAPTURES]match.Match = ---
	for route in routes {
		count, err := match.find_aux(request.url.path, route.pattern, 0, true, &matches)
		if err != .OK {
			log.errorf("Error matching route: %v", err)
			continue
		}

		if count > 0 {
			params := make([]string, count - 1, context.temp_allocator)
			for capture, index in matches[1:count] {
				params[index] = request.url.path[capture.byte_start:capture.byte_end]
			}

			request.url_params = params
			route_handler := route.handler
			route_handler.handle(&route_handler, request, response)
			return true
		}
	}

	return false
}
