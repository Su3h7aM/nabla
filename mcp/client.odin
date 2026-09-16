package mcp

import "core:encoding/json"
import "core:mem"
import "core:time"

// CLIENT_REQUEST_ATTEMPTS is how many times a request with no effect is sent. It is
// sent again only after the server is restarted and negotiated with again, and only
// for a method that cannot change anything: a tools/call is never reissued.
CLIENT_REQUEST_ATTEMPTS :: 2

// CLIENT_TOOL_PAGES is how many listing pages are followed, so a server that always
// reports another cursor cannot make the harness list forever.
CLIENT_TOOL_PAGES :: 32

// CLIENT_MAX_NOTIFICATIONS bounds how many notifications are consumed while waiting
// for a reply, so a server that only ever sends notifications cannot keep a request
// running.
CLIENT_MAX_NOTIFICATIONS :: 256

// CLIENT_HANDSHAKE_TIMEOUT bounds the notification that completes a handshake. It
// is short because the write is one line: a server that cannot take it is wedged.
CLIENT_HANDSHAKE_TIMEOUT :: 5 * time.Second

// Client is one server the harness can talk to. It owns the process, the config the
// process was started from, the request id counter, and the revision the server
// agreed to speak. One request is in flight at a time: the harness runs tools
// serially, and nothing about a turn benefits from multiplexing.
Client :: struct {
	stdio:     Stdio,
	config:    Stdio_Config,
	next_id:   i64,
	// version is the revision in force, agreed during client_connect. Nothing may be
	// sent before it is known: the request and result shapes depend on it.
	version:   Protocol_Version,
	allocator: mem.Allocator,
}

// client_start records how to reach the server and launches it. It does not
// negotiate anything: a launched process is not yet a server this client can talk
// to.
client_start :: proc(client: ^Client, config: Stdio_Config, allocator := context.allocator) -> Error {
	client.allocator = allocator
	client.config = stdio_config_clone(config, allocator)
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
client_restart :: proc(client: ^Client) -> Error {
	stdio_stop(&client.stdio)
	client.version = .Unknown
	return stdio_start(&client.stdio, client.config, client.allocator)
}

// client_connect agrees a protocol revision with the server.
//
// It probes with `server/discover`, which only the stateless revision defines. A
// server that answers with a discovery result speaks that revision and needs
// nothing more. A server that answers with an error, or that stopped answering, is
// of the handshake era and is asked to initialize instead.
//
// The probe comes first because it is unambiguous: a method only one revision
// defines cannot be answered by accident, whereas a method both revisions define
// could be read under the wrong semantics.
client_connect :: proc(client: ^Client, control: Control, allocator := context.allocator) -> (Connection, Error) {
	connection, answered, probe_err := client_try_discover(client, control, allocator)
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
	if !client_running(client) {
		if restart_err := client_restart(client); restart_err.kind != .None { return {}, restart_err }
	}
	return client_initialize(client, control, allocator)
}

// client_try_discover probes for the stateless revision. answered reports whether
// the server produced a discovery result, which is what separates "this server
// speaks the other era" from "this server speaks this era and refused".
@(private)
client_try_discover :: proc(client: ^Client, control: Control, allocator: mem.Allocator) -> (connection: Connection, answered: bool, err: Error) {
	params := request_params_make(.V2026_07_28, 0, client.allocator)
	result, exchange_err := client_exchange(client, METHOD_DISCOVER, params, control)
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
@(private)
client_initialize :: proc(client: ^Client, control: Control, allocator: mem.Allocator) -> (Connection, Error) {
	result, exchange_err := client_exchange(client, METHOD_INITIALIZE, initialize_params_make(client.allocator), control)
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
	}
	if notify_err := client_notify(client, NOTIFICATION_INITIALIZED, nil, handshake_control); notify_err.kind != .None {
		connection_destroy(&connection, allocator)
		client.version = .Unknown
		return {}, notify_err
	}
	return connection, {}
}

@(private)
client_notify :: proc(client: ^Client, method: string, params: json.Object, control: Control) -> Error {
	line, encode_err := notification_encode(method, params, client.allocator)
	defer delete(line, client.allocator)
	if encode_err.kind != .None { return encode_err }
	return stdio_write_line(&client.stdio, line, control)
}

// client_exchange sends one request and returns its result object. It takes
// ownership of params even when it fails before encoding.
//
// Notifications that arrive before the reply are consumed and discarded. A
// server-initiated request is answered with a refusal under a handshake-era
// revision, because the specification requires a reply to every request and this
// client declares no capability for any of them. Under the stateless revision such
// a request is a protocol violation, since that revision carries the interaction
// inside a result instead.
client_exchange :: proc(client: ^Client, method: string, params: json.Object, control: Control) -> (result: json.Value, err: Error) {
	client.next_id += 1
	id := client.next_id
	line, encode_err := request_encode(method, params, id, client.allocator)
	defer delete(line, client.allocator)
	if encode_err.kind != .None { return nil, encode_err }

	if write_err := stdio_write_line(&client.stdio, line, control); write_err.kind != .None { return nil, write_err }

	notifications := 0
	for {
		framed, read_err := stdio_read_line(&client.stdio, control)
		if read_err.kind != .None { return nil, read_err }

		message, decode_err := message_decode(string(framed), client.allocator)
		if decode_err.kind != .None {
			decode_err.delivery = .Delivered
			decode_err.stderr_tail = stdio_stderr_excerpt(&client.stdio, client.allocator)
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
			remote.stderr_tail = stdio_stderr_excerpt(&client.stdio, client.allocator)
			message_destroy(&message, client.allocator)
			return nil, remote

		case .Notification:
			message_destroy(&message, client.allocator)
			notifications += 1
			if notifications > CLIENT_MAX_NOTIFICATIONS {
				return nil, client_stream_error(client, .Unexpected_Message, "the server sent notifications without replying")
			}

		case .Request:
			if protocol_version_inlines_server_requests(client.version) {
				message_destroy(&message, client.allocator)
				return nil, client_stream_error(
					client,
					.Unexpected_Message,
					"the server sent a request; this revision carries such interaction inside a result",
				)
			}
			request_id := message.id
			message_destroy(&message, client.allocator)
			if refuse_err := client_refuse_request(client, request_id, control); refuse_err.kind != .None { return nil, refuse_err }
		}
	}
}

// client_refuse_request answers a server-initiated request with an error, which is
// the only honest reply from a client that declares no capability for it.
@(private)
client_refuse_request :: proc(client: ^Client, id: i64, control: Control) -> Error {
	line, encode_err := response_error_encode(
		id,
		ERROR_CODE_METHOD_NOT_FOUND,
		"this client declares no capability for server-initiated requests",
		client.allocator,
	)
	defer delete(line, client.allocator)
	if encode_err.kind != .None { return encode_err }
	return stdio_write_line(&client.stdio, line, control)
}

// client_stream_error reports a protocol violation observed after the request was
// written, which is also what makes the outcome of a call unknown.
@(private)
client_stream_error :: proc(client: ^Client, kind: Error_Kind, detail: string) -> Error {
	err := error_make(kind, detail, client.allocator)
	err.delivery = .Delivered
	err.stderr_tail = stdio_stderr_excerpt(&client.stdio, client.allocator)
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
// page. A cursor the server reports forever is refused at the page bound, because a
// listing that never ends is not a listing.
//
// The listing has no effect, so it may be sent again after the server is restarted;
// a tool call may not.
client_tools_list :: proc(client: ^Client, control: Control, allocator := context.allocator) -> (Tool_Page, Error) {
	if client.version == .Unknown {
		return {}, error_make(.Protocol_Violation, "the server has not been negotiated with yet", allocator = allocator)
	}
	page: Tool_Page
	page.allocator = allocator
	page.tools = make([dynamic]Tool, 0, allocator)
	page.rejected = make([dynamic]Rejected_Tool, 0, allocator)
	failed := true
	defer if failed { tool_page_destroy(&page, allocator) }

	cursor: string // owned by the loop; empty when the listing is complete
	defer if cursor != "" { delete(cursor, allocator) }
	for pages := 0;; pages += 1 {
		if pages >= CLIENT_TOOL_PAGES {
			return {}, error_make(.Malformed_Message, "the server reported more listing pages than the harness follows", allocator = allocator)
		}
		next: Tool_Page
		// The listing is read-only, so a transport failure is retried once against a
		// fresh server.
		for attempts := 0;; attempts += 1 {
			result, exchange_err := client_exchange(client, METHOD_TOOLS_LIST, tools_list_params_make(cursor, client.version, client.allocator), control)
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
			if _, connect_err := client_connect(client, control, allocator); connect_err.kind != .None { return {}, connect_err }
		}

		// The page's contents move into the merged page, and the cursor moves into
		// the loop's own variable, so clearing the page releases only what is left.
		moved_cursor := next.next_cursor
		next.next_cursor = ""
		append(&page.tools, ..next.tools[:])
		append(&page.rejected, ..next.rejected[:])
		clear(&next.tools)
		clear(&next.rejected)
		tool_page_destroy(&next, allocator)
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
client_tools_call :: proc(client: ^Client, name: string, arguments_json: string, control: Control, allocator := context.allocator) -> (Call_Result, Error) {
	if client.version == .Unknown {
		return {}, error_make(.Protocol_Violation, "the server has not been negotiated with yet", allocator = allocator)
	}
	params, params_err := tools_call_params_make(name, arguments_json, client.version, client.allocator)
	if params_err.kind != .None { return {}, params_err }

	result, exchange_err := client_exchange(client, METHOD_TOOLS_CALL, params, control)
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
