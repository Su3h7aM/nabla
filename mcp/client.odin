package mcp

import "core:encoding/json"
import "core:mem"

// CLIENT_REQUEST_ATTEMPTS is how many times a request with no effect is sent. It is
// sent again only after the server is restarted, and only for a method that cannot
// change anything: a `tools/call` is never reissued.
CLIENT_REQUEST_ATTEMPTS :: 2

// CLIENT_MAX_NOTIFICATIONS bounds how many notifications are consumed while waiting
// for a reply, so a server that only ever sends notifications cannot keep a request
// running.
CLIENT_MAX_NOTIFICATIONS :: 256

// CLIENT_MAX_TOOL_PAGES bounds how many listing pages are followed, so a server that
// always reports another cursor cannot make the harness list forever.
CLIENT_MAX_TOOL_PAGES :: 32

// Client is one server the harness can talk to. It owns the process, the config the
// process was started from, and the request id counter. One request is in flight at
// a time: the harness runs tools serially, and nothing about a turn benefits from
// multiplexing.
Client :: struct {
	stdio:     Stdio,
	config:    Stdio_Config,
	next_id:   i64,
	allocator: mem.Allocator,
}

// client_start records how to reach the server and launches it.
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

// client_restart replaces a server that is no longer usable. The config is kept for
// exactly this: the protocol is stateless, so a restarted server is a fresh one and
// an in-flight request is simply lost.
client_restart :: proc(client: ^Client) -> Error {
	stdio_stop(&client.stdio)
	return stdio_start(&client.stdio, client.config, client.allocator)
}

// client_exchange sends one request and returns its result object. It takes
// ownership of params even when it fails before encoding.
//
// Notifications that arrive before the reply are consumed and discarded, and a
// server-initiated request ends the exchange: this revision carries server-to-client
// interaction inside a result, so a request on the stream is a protocol violation
// rather than something to answer.
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
				detail := "a reply arrived for a request this client did not send"
				message_destroy(&message, client.allocator)
				return nil, client_stream_error(client, .Unexpected_Message, detail)
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
			message_destroy(&message, client.allocator)
			return nil, client_stream_error(client, .Unexpected_Message, "the server sent a request; this revision carries such interaction inside a result")
		}
	}
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

// client_discover asks the server what it supports. Discovery has no effect, so it
// is the one kind of request that may be sent again, and only after the server has
// been restarted.
client_discover :: proc(client: ^Client, control: Control, allocator := context.allocator) -> (Discover_Result, Error) {
	attempts := 0
	for {
		attempts += 1
		result, exchange_err := client_exchange(client, METHOD_DISCOVER, discover_params_make(client.allocator), control)
		if exchange_err.kind == .None {
			object, is_object := result.(json.Object)
			if !is_object {
				json.destroy_value(result, client.allocator)
				return {}, error_make(.Malformed_Message, "the discovery result is not an object", allocator = allocator)
			}
			discover, decode_err := discover_decode(object, allocator)
			json.destroy_value(result, client.allocator)
			return discover, decode_err
		}
		if attempts >= CLIENT_REQUEST_ATTEMPTS || control_stop(control) != .None { return {}, exchange_err }
		if !client_error_is_transport(exchange_err) { return {}, exchange_err }
		error_destroy(&exchange_err, allocator)
		if restart_err := client_restart(client); restart_err.kind != .None { return {}, restart_err }
	}
}

// client_tools_list follows the listing to its end and returns every page as one
// page. A cursor the server reports forever is refused at the page bound, because a
// listing that never ends is not a listing.
client_tools_list :: proc(client: ^Client, control: Control, allocator := context.allocator) -> (Tool_Page, Error) {
	page: Tool_Page
	page.allocator = allocator
	page.tools = make([dynamic]Tool, 0, allocator)
	page.rejected = make([dynamic]Rejected_Tool, 0, allocator)
	failed := true
	defer if failed { tool_page_destroy(&page, allocator) }

	cursor: string // owned by the loop; empty when the listing is complete
	defer if cursor != "" { delete(cursor, allocator) }
	for pages := 0;; pages += 1 {
		if pages >= CLIENT_MAX_TOOL_PAGES {
			return {}, error_make(.Malformed_Message, "the server reported more listing pages than the harness follows", allocator = allocator)
		}
		attempts := 0
		next: Tool_Page
		for {
			attempts += 1
			result, exchange_err := client_exchange(client, METHOD_TOOLS_LIST, tools_list_params_make(cursor, client.allocator), control)
			if exchange_err.kind == .None {
				object, is_object := result.(json.Object)
				if !is_object {
					json.destroy_value(result, client.allocator)
					return {}, error_make(.Malformed_Message, "the tool listing is not an object", allocator = allocator)
				}
				decoded, decode_err := tools_list_decode(object, allocator)
				json.destroy_value(result, client.allocator)
				if decode_err.kind != .None { return {}, decode_err }
				next = decoded
				break
			}
			if attempts >= CLIENT_REQUEST_ATTEMPTS || control_stop(control) != .None { return {}, exchange_err }
			if !client_error_is_transport(exchange_err) { return {}, exchange_err }
			error_destroy(&exchange_err, allocator)
			if restart_err := client_restart(client); restart_err.kind != .None { return {}, restart_err }
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
	params, params_err := tools_call_params_make(name, arguments_json, client.allocator)
	if params_err.kind != .None { return {}, params_err }

	result, exchange_err := client_exchange(client, METHOD_TOOLS_CALL, params, control)
	if exchange_err.kind != .None { return {}, exchange_err }

	object, is_object := result.(json.Object)
	if !is_object {
		json.destroy_value(result, client.allocator)
		return {}, client_stream_error(client, .Malformed_Message, "the tool result is not an object")
	}
	decoded, decode_err := call_result_decode(object, allocator)
	json.destroy_value(result, client.allocator)
	return decoded, decode_err
}
