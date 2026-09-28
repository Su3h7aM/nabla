package mcp

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"

// CLIENT_REQUEST_ATTEMPTS is how many times a request with no effect is sent. It is
// sent again only after the server is restarted and negotiated with again, and only
// for a method that cannot change anything: a tools/call is never reissued.
CLIENT_REQUEST_ATTEMPTS :: 2

// CLIENT_HANDSHAKE_TIMEOUT bounds the notification that completes a handshake. It
// is short because the write is one line: a server that cannot take it is wedged.
CLIENT_HANDSHAKE_TIMEOUT :: 5 * time.Second

// Client is one server the harness can talk to. It owns the process, the config the
// process was started from, the request id counter, and the revision the server
// agreed to speak. One request is in flight at a time; a request made while another
// is in flight, from any thread, is refused with Busy before anything is written.
Client :: struct {
	stdio:     Stdio,
	config:    Stdio_Config,
	next_id:   i64,
	// version is the revision in force, agreed during client_connect. Nothing may be
	// sent before it is known: the request and result shapes depend on it.
	version:   Protocol_Version,
	allocator: mem.Allocator,
	// busy is atomic: set while a request owns the stream.
	busy:      bool,
}

// client_start records how to reach the server and launches it. It does not
// negotiate anything: a launched process is not yet a server this client can talk
// to.
@(require_results)
client_start :: proc(client: ^Client, config: Stdio_Config, allocator := context.allocator) -> Error {
	client.allocator = allocator
	cloned_config, clone_error := stdio_config_clone(config, allocator)
	if clone_error.kind != .None { return clone_error }
	client.config = cloned_config
	if start_err := stdio_start(&client.stdio, client.config, allocator); start_err.kind != .None {
		stdio_config_destroy(&client.config, allocator)
		return start_err
	}
	return {}
}

// client_destroy stops the server and releases everything the client owns.
client_destroy :: proc(client: ^Client) {
	allocator := client.allocator
	stdio_stop(&client.stdio)
	stdio_config_destroy(&client.config, allocator)
	client^ = {}
}

client_running :: proc(client: ^Client) -> bool {
	return stdio_running(&client.stdio)
}

client_version :: proc(client: ^Client) -> Protocol_Version {
	return client.version
}

// client_restart replaces a server that is no longer usable. The config is kept for
// exactly this: a restarted server is a fresh one, so the handshake has to happen
// again.
@(require_results)
client_restart :: proc(client: ^Client) -> Error {
	stdio_stop(&client.stdio)
	client.version = .Unknown
	return stdio_start(&client.stdio, client.config, client.allocator)
}

// client_connect agrees a protocol revision with the server and returns the
// connection it agreed on. It probes with `server/discover`, a method only the
// stateless revision defines, and falls back to the 2025 handshake when the server
// answers that probe with an error or stops answering it.
@(require_results)
client_connect :: proc(client: ^Client, options: Operation_Options, allocator := context.allocator) -> (Connection, Error) {
	control := options.control
	connection, answered, probe_err := client_try_discover(client, options, allocator)
	if probe_err.kind == .None { return connection, {} }
	if answered {
		// The server produced a discovery result, so it speaks the stateless
		// revision. Refusing this client's version is then an answer, not a reason to
		// try the other era.
		return {}, probe_err
	}
	error_destroy(&probe_err, allocator)

	if stop := control_stop(control); stop != .None { return {}, control_error(stop, .Not_Delivered, allocator) }

	// A server that met an unknown method may have closed or wedged itself, so the
	// handshake starts from a fresh process.
	// A restarted server is a fresh one, so it is negotiated with from the same
	// observer the caller asked for.
	if !client_running(client) {
		if restart_err := client_restart(client); restart_err.kind != .None { return {}, restart_err }
	}
	return client_initialize(client, options, allocator)
}

// client_try_discover probes for the stateless revision. answered reports whether
// the server produced a discovery result, which is what separates "this server
// speaks the other era" from "this server speaks this era and refused".
@(private, require_results)
client_try_discover :: proc(client: ^Client, options: Operation_Options, allocator: mem.Allocator) -> (connection: Connection, answered: bool, err: Error) {
	params, build_error := request_params_make(.V2026_07_28, 0, client.allocator)
	if build_error.kind != .None { return {}, false, build_error }
	result, exchange_err := client_exchange(client, METHOD_DISCOVER, params, options)
	if exchange_err.kind != .None { return {}, false, exchange_err }

	object, is_object := result.(json.Object)
	if !is_object {
		json.destroy_value(result, client.allocator)
		return {}, true, error_make(.Malformed_Message, "the discovery result is not an object", allocator = allocator)
	}
	decoded, decode_err := connection_from_stateless(object, allocator)
	json.destroy_value(result, client.allocator)
	if decode_err.kind != .None { return {}, true, decode_err }

	client.version = decoded.version
	return decoded, true, {}
}

// client_initialize performs the handshake the 2025 revisions define: one
// initialize request, which the server answers with the revision it will use, and
// one notification saying the client is ready.
@(private, require_results)
client_initialize :: proc(client: ^Client, options: Operation_Options, allocator: mem.Allocator) -> (Connection, Error) {
	control := options.control
	params, build_error := initialize_params_make(client.allocator)
	if build_error.kind != .None { return {}, build_error }
	result, exchange_err := client_exchange(client, METHOD_INITIALIZE, params, options)
	if exchange_err.kind != .None { return {}, exchange_err }

	object, is_object := result.(json.Object)
	if !is_object {
		json.destroy_value(result, client.allocator)
		return {}, error_make(.Malformed_Message, "the handshake result is not an object", allocator = allocator)
	}
	connection, decode_err := connection_from_handshake(object, allocator)
	json.destroy_value(result, client.allocator)
	if decode_err.kind != .None { return {}, decode_err }

	// The server is told the handshake is complete before anything else is asked of
	// it. The revision is in force from here, which is what lets the notification be
	// framed correctly.
	client.version = connection.version
	handshake_control := Control {
		user_data    = control.user_data,
		interrupted  = control.interrupted,
		deadline_at  = time.tick_add(time.tick_now(), CLIENT_HANDSHAKE_TIMEOUT),
		has_deadline = true,
		wake         = control.wake,
	}
	// The continuation keeps the caller's observer: the notification is part of
	// the same handshake the caller asked to watch.
	if notify_err := client_notify(client, NOTIFICATION_INITIALIZED, nil, Operation_Options{control = handshake_control, observer = options.observer});
	   notify_err.kind != .None {
		connection_destroy(&connection, allocator)
		client.version = .Unknown
		return {}, notify_err
	}
	return connection, {}
}

@(private, require_results)
client_notify :: proc(client: ^Client, method: string, params: json.Object, options: Operation_Options) -> Error {
	line, encode_err := notification_encode(method, params, client.allocator)
	defer delete(line, client.allocator)
	if encode_err.kind != .None { return encode_err }
	operation_report(options, {direction = .Outgoing, operation = method, message = transmute([]u8)line})
	return stdio_write_line(&client.stdio, line, options.control)
}

// client_exchange sends one request and returns its result object. It takes
// ownership of params even when it fails before encoding.
//
// Notifications that arrive before the reply are consumed and discarded, and a
// server-initiated request is answered with a refusal.
@(require_results)
client_exchange :: proc(client: ^Client, method: string, params: json.Object, options: Operation_Options) -> (result: json.Value, err: Error) {
	if _, claimed := sync.atomic_compare_exchange_strong(&client.busy, false, true); !claimed {
		json.destroy_value(json.Value(params), client.allocator)
		return nil, error_make(.Busy, allocator = client.allocator)
	}
	defer sync.atomic_store(&client.busy, false)
	control := options.control
	client.next_id += 1
	id := client.next_id
	line, encode_err := request_encode(method, params, id, client.allocator)
	defer delete(line, client.allocator)
	if encode_err.kind != .None { return nil, encode_err }

	// The line is reported before it is written, because this is the last moment
	// it is one buffer rather than bytes inside the transport.
	operation_report(options, {direction = .Outgoing, operation = method, request_id = id, message = transmute([]u8)line})
	if write_err := stdio_write_line(&client.stdio, line, control); write_err.kind != .None { return nil, write_err }

	for {
		framed, read_err := stdio_read_line(&client.stdio, control)
		if read_err.kind != .None { return nil, read_err }

		// Every complete line is reported before it is decoded, so a reader sees
		// what the peer actually sent rather than what this client made of it.
		operation_report(options, {direction = .Incoming, operation = method, request_id = id, message = framed})

		message, decode_err := message_decode(string(framed), client.allocator)
		if decode_err.kind != .None {
			decode_err.delivery = .Delivered
			stdio_stderr_attach(&client.stdio, &decode_err)
			return nil, decode_err
		}

		switch message.kind {
		case .Result:
			if message.id != id {
				message_destroy(&message, client.allocator)
				return nil, client_stream_error(client, .Unexpected_Message, "a reply arrived for a request this client did not send")
			}
			result = message.result
			// The result moves to the caller, so the message must not release it.
			message.result = nil
			message_destroy(&message, client.allocator)
			return result, {}

		case .Error:
			if message.id_present && message.id != id {
				message_destroy(&message, client.allocator)
				return nil, client_stream_error(client, .Unexpected_Message, "an error arrived for a request this client did not send")
			}
			remote := error_from_remote(message.remote_error, .Delivered, client.allocator)
			stdio_stderr_attach(&client.stdio, &remote)
			message_destroy(&message, client.allocator)
			return nil, remote

		case .Notification:
			message_destroy(&message, client.allocator)

		case .Request:
			if protocol_version_inlines_server_requests(client.version) {
				message_destroy(&message, client.allocator)
				return nil, client_stream_error(
					client,
					.Unexpected_Message,
					"the server sent a request; this revision carries such interaction inside a result",
				)
			}
			// The refusal is written after the message is released, so the method it
			// answers is copied for the length of this iteration.
			request_id := message.id
			refused_method, method_error := strings.clone(message.method, client.allocator)
			message_destroy(&message, client.allocator)
			if method_error != nil { return nil, error_make(.Out_Of_Memory, allocator = client.allocator) }
			refuse_err := client_refuse_request(client, refused_method, request_id, options)
			delete(refused_method, client.allocator)
			if refuse_err.kind != .None { return nil, refuse_err }
		}
	}
}

// client_refuse_request answers a server-initiated request with an error, which is
// the only honest reply from a client that declares no capability for it.
@(private, require_results)
client_refuse_request :: proc(client: ^Client, method: string, id: i64, options: Operation_Options) -> Error {
	line, encode_err := response_error_encode(
		id,
		ERROR_CODE_METHOD_NOT_FOUND,
		"this client declares no capability for server-initiated requests",
		client.allocator,
	)
	defer delete(line, client.allocator)
	if encode_err.kind != .None { return encode_err }
	// The refusal is this client's own message, and is reported as such so a trace
	// shows both sides of the exchange.
	operation_report(options, {direction = .Outgoing, operation = method, request_id = id, message = transmute([]u8)line})
	return stdio_write_line(&client.stdio, line, options.control)
}

// client_stream_error reports a protocol violation observed after the request was
// written, which is also what makes the outcome of a call unknown.
@(private, require_results)
client_stream_error :: proc(client: ^Client, kind: Error_Kind, detail: string) -> Error {
	err := error_make(kind, detail, client.allocator)
	err.delivery = .Delivered
	stdio_stderr_attach(&client.stdio, &err)
	return err
}

// client_error_is_transport reports whether a failure means the server is no longer
// usable, which is the only case where a restart can help.
@(private)
client_error_is_transport :: proc(err: Error) -> bool {
	#partial switch err.kind {
	case .Server_Exited, .End_Of_Stream, .Read_Failed, .Write_Failed:
		return true
	}
	return false
}

// client_tools_list follows the listing to its end and returns every page as one
// page. A repeated cursor is refused rather than followed: it asks for a page that
// has already been read, and no page count would end such a listing.
//
// The listing has no effect, so it may be sent again after the server is restarted;
// a tool call may not.
@(require_results)
client_tools_list :: proc(client: ^Client, options: Operation_Options, allocator := context.allocator) -> (Tool_Page, Error) {
	control := options.control
	if client.version == .Unknown {
		return {}, error_make(.Protocol_Violation, "the server has not been negotiated with yet", allocator = allocator)
	}
	page: Tool_Page
	page.allocator = allocator
	page_tools, tools_error := make([dynamic]Tool, 0, allocator)
	if tools_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
	page.tools = page_tools
	page_rejected, rejected_error := make([dynamic]Rejected_Tool, 0, allocator)
	if rejected_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
	page.rejected = page_rejected
	failed := true
	defer if failed { tool_page_destroy(&page, allocator) }

	cursor: string // owned by the loop; empty when the listing is complete
	defer if cursor != "" { delete(cursor, allocator) }
	for {
		next: Tool_Page
		// The listing is read-only, so a transport failure is retried once against a
		// fresh server.
		for attempts := 0;; attempts += 1 {
			params, build_error := tools_list_params_make(cursor, client.version, client.allocator)
			if build_error.kind != .None { return {}, build_error }
			result, exchange_err := client_exchange(client, METHOD_TOOLS_LIST, params, options)
			if exchange_err.kind == .None {
				object, is_object := result.(json.Object)
				if !is_object {
					json.destroy_value(result, client.allocator)
					return {}, error_make(.Malformed_Message, "the tool listing is not an object", allocator = allocator)
				}
				decoded, decode_err := tools_list_decode(object, client.version, allocator)
				json.destroy_value(result, client.allocator)
				if decode_err.kind != .None { return {}, decode_err }
				next = decoded
				break
			}
			if attempts + 1 >= CLIENT_REQUEST_ATTEMPTS || control_stop(control) != .None { return {}, exchange_err }
			if !client_error_is_transport(exchange_err) { return {}, exchange_err }
			error_destroy(&exchange_err, allocator)
			if restart_err := client_restart(client); restart_err.kind != .None { return {}, restart_err }
			// A restarted server is a fresh one and must be negotiated with again.
			if _, connect_err := client_connect(client, options, allocator); connect_err.kind != .None { return {}, connect_err }
		}

		// The page's contents move into the merged page, and the cursor moves into
		// the loop's own variable, so clearing the page releases only what is left.
		moved_cursor := next.next_cursor
		next.next_cursor = ""
		old_tools_len := len(page.tools)
		tools_appended := append(&page.tools, ..next.tools[:])
		if tools_appended != len(next.tools) {
			// The rollback only shortens the array, which never allocates.
			_ = resize(&page.tools, old_tools_len)
			tool_page_destroy(&next, allocator)
			return {}, error_make(.Out_Of_Memory, allocator = allocator)
		}
		clear(&next.tools)
		old_rejected_len := len(page.rejected)
		rejected_appended := append(&page.rejected, ..next.rejected[:])
		if rejected_appended != len(next.rejected) {
			// The rollback only shortens the array, which never allocates.
			_ = resize(&page.rejected, old_rejected_len)
			tool_page_destroy(&next, allocator)
			return {}, error_make(.Out_Of_Memory, allocator = allocator)
		}
		clear(&next.rejected)
		tool_page_destroy(&next, allocator)
		// The cursor that produced this page is the one the server just answered
		// with: asking again with it would read the same page forever.
		if moved_cursor != "" && moved_cursor == cursor {
			delete(moved_cursor, allocator)
			return {}, error_make(.Malformed_Message, "the server reported the same listing cursor again", allocator = allocator)
		}
		if cursor != "" { delete(cursor, allocator) }
		cursor = moved_cursor
		if cursor == "" { break }
	}

	failed = false
	return page, {}
}

// client_tools_call runs one tool. It is sent exactly once: a server may have
// performed the call before a lost reply, so a failure after the request was written
// reports that the outcome is unknown rather than trying again.
@(require_results)
client_tools_call :: proc(
	client: ^Client,
	name: string,
	arguments_json: string,
	options: Operation_Options,
	allocator := context.allocator,
) -> (
	Call_Result,
	Error,
) {
	if client.version == .Unknown {
		return {}, error_make(.Protocol_Violation, "the server has not been negotiated with yet", allocator = allocator)
	}
	params, params_err := tools_call_params_make(name, arguments_json, client.version, client.allocator)
	if params_err.kind != .None { return {}, params_err }

	result, exchange_err := client_exchange(client, METHOD_TOOLS_CALL, params, options)
	if exchange_err.kind != .None { return {}, exchange_err }

	object, is_object := result.(json.Object)
	if !is_object {
		json.destroy_value(result, client.allocator)
		return {}, client_stream_error(client, .Malformed_Message, "the tool result is not an object")
	}
	decoded, decode_err := call_result_decode(object, client.version, allocator)
	json.destroy_value(result, client.allocator)
	return decoded, decode_err
}
