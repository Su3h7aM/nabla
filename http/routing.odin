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

@(require_results)
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

@(require_results)
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

@(require_results)
query_get_int :: proc(url: URL, key: string, base := 0) -> (result: int, ok: bool, set: bool) {
	text := query_get(url, key) or_return
	set = true
	result, ok = strconv.parse_int(text, base)
	return
}

@(require_results)
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

// router_init prepares a router whose patterns live in allocator. mem_err is set,
// and the router owns nothing, when its table could not be allocated.
@(require_results)
router_init :: proc(router: ^Router, allocator := context.allocator) -> (mem_err: runtime.Allocator_Error) {
	router.allocator = allocator
	routes, make_err := make(map[Method][dynamic]Route, len(Method), allocator)
	if make_err != nil { return make_err }
	router.routes = routes
	return nil
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

		matched, routes_err := routes_try(router.routes[line.method], request, response)
		if routes_err != nil {
			response.status = .Internal_Server_Error
			respond(response)
			return
		}
		if matched { return }

		matched, routes_err = routes_try(router.all, request, response)
		if routes_err != nil {
			response.status = .Internal_Server_Error
			respond(response)
			return
		}
		if matched { return }

		// The method is a structural fact. The target is peer-supplied text that a
		// persistent log has no business carrying, and a handler can record it
		// itself when it decides that is safe.
		log.infof("no route matched %s", method_string(line.method))
		response.status = .Not_Found
		respond(response)
	}

	return result
}

// The route_* procedures each add one handler to a router. mem_err is set, and no
// route was added, when the pattern or the route's slot could not be allocated.

@(require_results)
route_get :: proc(router: ^Router, pattern: string, handler: Handler) -> runtime.Allocator_Error {
	return route_add(router, .Get, pattern, handler)
}

@(require_results)
route_post :: proc(router: ^Router, pattern: string, handler: Handler) -> runtime.Allocator_Error {
	return route_add(router, .Post, pattern, handler)
}

// NOTE: this does not get called when `Server_Opts.redirect_head_to_get` is set to true.
@(require_results)
route_head :: proc(router: ^Router, pattern: string, handler: Handler) -> runtime.Allocator_Error {
	return route_add(router, .Head, pattern, handler)
}

@(require_results)
route_put :: proc(router: ^Router, pattern: string, handler: Handler) -> runtime.Allocator_Error {
	return route_add(router, .Put, pattern, handler)
}

@(require_results)
route_patch :: proc(router: ^Router, pattern: string, handler: Handler) -> runtime.Allocator_Error {
	return route_add(router, .Patch, pattern, handler)
}

@(require_results)
route_trace :: proc(router: ^Router, pattern: string, handler: Handler) -> runtime.Allocator_Error {
	return route_add(router, .Trace, pattern, handler)
}

@(require_results)
route_delete :: proc(router: ^Router, pattern: string, handler: Handler) -> runtime.Allocator_Error {
	return route_add(router, .Delete, pattern, handler)
}

@(require_results)
route_connect :: proc(router: ^Router, pattern: string, handler: Handler) -> runtime.Allocator_Error {
	return route_add(router, .Connect, pattern, handler)
}

@(require_results)
route_options :: proc(router: ^Router, pattern: string, handler: Handler) -> runtime.Allocator_Error {
	return route_add(router, .Options, pattern, handler)
}

// Adds a catch-all fallback route (all methods, ran if no other routes match).
@(require_results)
route_all :: proc(router: ^Router, pattern: string, handler: Handler) -> (mem_err: runtime.Allocator_Error) {
	anchored, concat_err := strings.concatenate({"^", pattern, "$"}, router.allocator)
	if concat_err != nil { return concat_err }
	if router.all == nil {
		all, make_err := make([dynamic]Route, 0, 1, router.allocator)
		if make_err != nil {
			delete(anchored, router.allocator)
			return make_err
		}
		router.all = all
	}

	if _, append_err := append(&router.all, Route{handler = handler, pattern = anchored}); append_err != nil {
		delete(anchored, router.allocator)
		return append_err
	}
	return nil
}

// route_add anchors a pattern and adds it to one method's routes. mem_err is set,
// and no route was added, when the pattern or the method's slot could not be
// allocated.
@(private, require_results)
route_add :: proc(router: ^Router, method: Method, pattern: string, handler: Handler) -> (mem_err: runtime.Allocator_Error) {
	anchored, concat_err := strings.concatenate({"^", pattern, "$"}, router.allocator)
	if concat_err != nil { return concat_err }
	if method not_in router.routes {
		routes, make_err := make([dynamic]Route, router.allocator)
		if make_err != nil {
			delete(anchored, router.allocator)
			return make_err
		}
		router.routes[method] = routes
	}

	if _, append_err := append(&router.routes[method], Route{handler = handler, pattern = anchored}); append_err != nil {
		delete(anchored, router.allocator)
		return append_err
	}
	return nil
}

// routes_try runs the first route that matches. mem_err is set when the captures
// that route's handler receives could not be allocated, in which case no handler
// ran.
@(private, require_results)
routes_try :: proc(routes: [dynamic]Route, request: ^Request, response: ^Response) -> (matched: bool, mem_err: runtime.Allocator_Error) {
	matches: [match.MAX_CAPTURES]match.Match = ---
	for route in routes {
		count, err := match.find_aux(request.url.path, route.pattern, 0, true, &matches)
		if err != .OK {
			log.errorf("Error matching route: %v", err)
			continue
		}

		if count > 0 {
			params, make_err := make([]string, count - 1, context.temp_allocator)
			if make_err != nil { return false, make_err }
			for capture, index in matches[1:count] {
				params[index] = request.url.path[capture.byte_start:capture.byte_end]
			}

			request.url_params = params
			route_handler := route.handler
			route_handler.handle(&route_handler, request, response)
			return true, nil
		}
	}

	return false, nil
}
