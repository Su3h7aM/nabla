// This is a single-threaded executable harness rather than an in-package @(test)
// suite because it forks a server process, and fork() into a multi-threaded test
// runner can deadlock on an allocator lock another thread holds.
//
// It runs itself in a fake-server mode: the child speaks the protocol on standard
// input and output, and the parent drives the real client against it. A scenario
// whose name starts with "legacy" speaks the handshake era instead of the stateless
// one, which is what makes the negotiation and both result shapes covered.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import linux "core:sys/linux"
import "core:time"

import "nabla:mcp"

failures: int

check :: proc(condition: bool, what: string) {
	if condition {
		fmt.printf("ok: %s\n", what)
		return
	}
	fmt.eprintf("FAIL: %s\n", what)
	failures += 1
}

main :: proc() {
	if len(os.args) > 2 && os.args[1] == "serve" {
		serve(os.args[2], os.args[3:])
		return
	}
	scenario_happy_path()
	scenario_wire_observation()
	scenario_unusable_tool()
	scenario_tool_failure()
	scenario_input_required()
	scenario_lost_reply()
	scenario_stderr_flood()
	scenario_oversized_message()
	scenario_version_refused()
	scenario_handshake()
	scenario_handshake_server_request()
	scenario_handshake_unsupported()
	if failures > 0 {
		fmt.eprintf("%d checks failed\n", failures)
		os.exit(1)
	}
	fmt.println("stdio: ok")
}

// --- the parent --------------------------------------------------------------

@(private)
executable :: proc() -> string {
	if strings.has_prefix(os.args[0], "/") { return os.args[0] }
	directory, err := os.get_working_directory(context.temp_allocator)
	if err != nil { return "" }
	return fmt.aprintf("%s/%s", directory, os.args[0], allocator = context.temp_allocator)
}

// scenario_config asks this binary to serve a scenario. argv is built on the
// scratch allocator and the strings are borrowed by the config, which the client
// clones before it spawns anything.
@(private)
scenario_config :: proc(scenario: string, extra: []string = nil) -> mcp.Stdio_Config {
	arguments := make([dynamic]string, 0, 2 + len(extra), context.temp_allocator)
	append(&arguments, "serve", scenario)
	append(&arguments, ..extra)
	return mcp.Stdio_Config{executable = executable(), arguments = arguments[:]}
}

@(private)
start :: proc(client: ^mcp.Client, config: mcp.Stdio_Config) -> bool {
	err := mcp.client_start(client, config)
	if err.kind != .None {
		fmt.eprintf("FAIL: the server did not start: %v\n", err.kind)
		failures += 1
		return false
	}
	return true
}

@(private)
negotiate :: proc(client: ^mcp.Client) -> bool {
	connection, err := mcp.client_connect(client, mcp.Operation_Options{})
	ok := err.kind == .None
	mcp.connection_destroy(&connection)
	mcp.error_destroy(&err)
	if !ok { check(false, "the server negotiates") }
	return ok
}

@(private)
scenario_happy_path :: proc() {
	client: mcp.Client
	defer mcp.client_destroy(&client)
	if !start(&client, scenario_config("ok")) { return }
	check(true, "a stdio server starts")

	options := mcp.Operation_Options{}
	// The fake server refuses to answer a request without the per-request protocol
	// metadata, so every check below also asserts the envelope.
	connection, connect_err := mcp.client_connect(&client, options)
	if connect_err.kind == .None {
		check(connection.version == .V2026_07_28, "the probe negotiates the stateless revision")
		check(connection.tools_supported, "discovery reports the tools capability")
		check(connection.server_name == "fake", "discovery reports the server identity")
	} else {
		check(false, "discovery succeeds")
	}
	mcp.connection_destroy(&connection)
	mcp.error_destroy(&connect_err)

	page, page_err := mcp.client_tools_list(&client, options)
	if page_err.kind == .None {
		check(len(page.tools) == 2, "pagination merges both pages in order")
		check(len(page.rejected) == 1, "one unusable tool is reported rather than dropping the page")
		if len(page.tools) == 2 {
			check(page.tools[0].name == "good_a", "the first page's tool comes first")
			check(page.tools[1].name == "good_b", "the second page's tool follows")
			check(page.tools[0].annotations.read_only == .Yes, "an annotation is read")
		}
	} else {
		check(false, "the listing succeeds")
	}
	mcp.tool_page_destroy(&page)
	mcp.error_destroy(&page_err)

	result, call_err := mcp.client_tools_call(&client, "good_a", `{"title":"x"}`, options)
	if call_err.kind == .None {
		check(!result.is_error, "a successful call is not a failure")
		check(len(result.content) == 1 && result.content[0].kind == .Text, "the text content is read")
		check(result.content[0].text == "created", "the text survives")
		check(result.structured_json == `{"ok":true}`, "the structured content is kept")
	} else {
		check(false, "the call succeeds")
	}
	mcp.call_result_destroy(&result)
	mcp.error_destroy(&call_err)
}

// Wire_Log is what one scenario observed. Each message is copied, because the
// report borrows its bytes only until the callback returns.
Wire_Log :: struct {
	lines:  [dynamic]string,
	report: [dynamic]mcp.Wire_Report,
}

wire_log_report :: proc(user_data: rawptr, report: mcp.Wire_Report) {
	log := cast(^Wire_Log)user_data
	append(&log.lines, strings.clone(string(report.message), context.allocator))
	// The report's own fields are copied too, without the borrowed message.
	copied := report
	copied.message = nil
	append(&log.report, copied)
}

wire_log_destroy :: proc(log: ^Wire_Log) {
	for line in log.lines { delete(line, context.allocator) }
	delete(log.lines)
	delete(log.report)
}

// The observer sees the exact JSON-RPC lines each exchange carries, both ways, and
// observing changes nothing about the operation: the same call succeeds with and
// without it.
@(private)
scenario_wire_observation :: proc() {
	client: mcp.Client
	defer mcp.client_destroy(&client)
	if !start(&client, scenario_config("ok")) { return }

	log: Wire_Log
	defer wire_log_destroy(&log)

	options := mcp.Operation_Options {
		observer = {user_data = &log, report = wire_log_report},
	}
	connection, connect_err := mcp.client_connect(&client, options)
	check(connect_err.kind == .None, "an observed connection still negotiates")
	mcp.connection_destroy(&connection)
	mcp.error_destroy(&connect_err)

	result, call_err := mcp.client_tools_call(&client, "good_a", `{"title":"x"}`, options)
	check(call_err.kind == .None, "an observed call still succeeds")
	mcp.call_result_destroy(&result)
	mcp.error_destroy(&call_err)

	// Every line is a whole JSON-RPC message, and the observer saw both directions.
	outgoing, incoming := 0, 0
	for report, index in log.report {
		line := log.lines[index]
		if report.direction == .Outgoing { outgoing += 1 } else { incoming += 1 }
		// The line is parsed rather than pattern-matched: whether the id or the
		// version comes first is an encoding detail, but a message that is not one
		// JSON-RPC object is not a message.
		value, parse_err := json.parse_string(line, allocator = context.temp_allocator)
		check(parse_err == .None, "an observed line is JSON")
		if object, is_object := value.(json.Object); is_object {
			_, has_version := object["jsonrpc"]
			_, has_id := object["id"]
			_, has_method := object["method"]
			check(has_version, "an observed line is a JSON-RPC message")
			check(has_id || has_method, "an observed line carries an id or a method")
		} else {
			check(false, "an observed line is one JSON object")
		}
		json.destroy_value(value, context.temp_allocator)
		check(report.operation != "", "an observed line names the operation it belongs to")
		check(!strings.has_suffix(line, "\n"), "the framing newline is not part of the message")
		// A report that outlived its callback would point into freed memory, so the
		// copied text is the only thing that is checked after the fact.
		check(report.message == nil || len(report.message) > 0, "the borrowed message is reported")
	}
	check(outgoing > 0, "the observer sees what the client sent")
	check(incoming > 0, "the observer sees what the server answered")

	// The probe, the initialized notification, and the call are all reported, which
	// is what makes the trace cover the whole operation rather than one method.
	joined := strings.join(log.lines[:], "\n", context.temp_allocator)
	check(strings.contains(joined, `"method":"server/discover"`), "the discovery probe is observed")
	check(strings.contains(joined, `"method":"tools/call"`), "the tool call is observed")
	check(strings.contains(joined, `"result"`), "the server's reply is observed")

	// A zero observer changes nothing: the same call produces the same outcome.
	plain: mcp.Client
	defer mcp.client_destroy(&plain)
	if !start(&plain, scenario_config("ok")) { return }
	plain_connection, plain_err := mcp.client_connect(&plain, mcp.Operation_Options{})
	check(plain_err.kind == .None, "an unobserved connection negotiates the same way")
	mcp.connection_destroy(&plain_connection)
	mcp.error_destroy(&plain_err)
}

// A stateless server that answers the probe but does not list this client's
// revision is refused, and the handshake is not attempted: an answer to the probe
// settles which era the server belongs to.
@(private)
scenario_version_refused :: proc() {
	client: mcp.Client
	defer mcp.client_destroy(&client)
	if !start(&client, scenario_config("unsupported")) { return }

	connection, err := mcp.client_connect(&client, mcp.Operation_Options{})
	check(err.kind == .Version_Unsupported, "a stateless server without our revision is refused")
	check(strings.contains(err.message, "2025-06-18"), "the refusal names the revisions it does support")
	mcp.connection_destroy(&connection)
	mcp.error_destroy(&err)
}

@(private)
scenario_unusable_tool :: proc() {
	client: mcp.Client
	defer mcp.client_destroy(&client)
	if !start(&client, scenario_config("bad_tool")) { return }
	if !negotiate(&client) { return }
	page, err := mcp.client_tools_list(&client, mcp.Operation_Options{})
	if err.kind == .None {
		check(len(page.tools) == 1, "a usable tool survives a malformed sibling")
		check(len(page.rejected) == 1, "the malformed tool is reported")
		if len(page.rejected) == 1 { check(page.rejected[0].name == "no_description", "the report names it") }
	} else {
		check(false, "the listing succeeds")
	}
	mcp.tool_page_destroy(&page)
	mcp.error_destroy(&err)
}

@(private)
scenario_tool_failure :: proc() {
	client: mcp.Client
	defer mcp.client_destroy(&client)
	if !start(&client, scenario_config("is_error")) { return }
	if !negotiate(&client) { return }

	result, err := mcp.client_tools_call(&client, "good_a", `{}`, mcp.Operation_Options{})
	if err.kind == .None {
		check(result.is_error, "a server-reported failure is read as one")
	} else {
		check(false, "a reported tool failure is a result, not a transport error")
	}
	mcp.call_result_destroy(&result)
	mcp.error_destroy(&err)
}

@(private)
scenario_input_required :: proc() {
	client: mcp.Client
	defer mcp.client_destroy(&client)
	if !start(&client, scenario_config("input_required")) { return }
	if !negotiate(&client) { return }

	result, err := mcp.client_tools_call(&client, "good_a", `{}`, mcp.Operation_Options{})
	if err.kind == .None {
		check(result.input_required, "a request for input is recognised")
		check(result.request_state == "opaque", "the server's state token is kept")
	} else {
		check(false, "an input-required reply is a result, not a transport error")
	}
	mcp.call_result_destroy(&result)
	mcp.error_destroy(&err)
}

// A reply lost after the request was written is the case the harness must never
// reissue: the server may have performed the call. The marker file holds one byte
// per call the server saw, so a retry would be visible.
@(private)
scenario_lost_reply :: proc() {
	directory, directory_err := os.make_directory_temp("", "nabla-mcp-lost-*", context.temp_allocator)
	if directory_err != nil {
		check(false, "a scratch directory is available")
		return
	}
	marker := fmt.aprintf("%s/calls", directory, allocator = context.temp_allocator)

	client: mcp.Client
	defer mcp.client_destroy(&client)
	if !start(&client, scenario_config("lost_reply", []string{marker})) { return }
	if !negotiate(&client) { return }

	result, err := mcp.client_tools_call(&client, "good_a", `{}`, mcp.Operation_Options{})
	check(err.kind != .None, "a lost reply is a failure")
	check(mcp.error_delivered(err), "the outcome is reported as delivered, so it is unknown rather than absent")
	mcp.call_result_destroy(&result)

	observed, read_err := os.read_entire_file(marker, context.temp_allocator)
	check(read_err == nil && len(observed) == 1, "the call was sent exactly once")
	mcp.error_destroy(&err)
}

// A server that fills its standard error while the harness waits for a reply must
// not block, and the diagnostic that comes back must be bounded.
@(private)
scenario_stderr_flood :: proc() {
	client: mcp.Client
	defer mcp.client_destroy(&client)
	if !start(&client, scenario_config("stderr_flood")) { return }

	_, err := mcp.client_connect(&client, mcp.Operation_Options{})
	check(err.kind != .None, "a server that exits without replying fails the request")
	check(len(err.stderr_tail) > 0, "the server's own last output is attached")
	// The flood is larger than the bound, so a bounded tail is exactly full.
	check(len(err.stderr_tail) == mcp.MAX_STDERR_TAIL_BYTES, "the diagnostic is bounded")
	mcp.error_destroy(&err)
}

@(private)
scenario_oversized_message :: proc() {
	client: mcp.Client
	defer mcp.client_destroy(&client)
	if !start(&client, scenario_config("oversized")) { return }

	_, err := mcp.client_connect(&client, mcp.Operation_Options{})
	check(err.kind == .Message_Too_Large, "a message past the bound is refused")
	mcp.error_destroy(&err)
}

// A handshake-era server knows nothing of the stateless probe, so the client must
// read the refusal as "the other era" and negotiate. Both result shapes then arrive
// without a resultType, and the requests must not carry the stateless envelope.
@(private)
scenario_handshake :: proc() {
	client: mcp.Client
	defer mcp.client_destroy(&client)
	if !start(&client, scenario_config("legacy")) { return }

	connection, connect_err := mcp.client_connect(&client, mcp.Operation_Options{})
	if connect_err.kind == .None {
		check(connection.version == .V2025_11_25, "the handshake takes the revision the server chose")
		check(connection.tools_supported, "the handshake reports the tools capability")
		check(connection.server_name == "fake", "the handshake reports the server identity, which is not under _meta")
		check(connection.instructions != "", "the handshake keeps the server's guidance")
	} else {
		check(false, "a handshake-era server is negotiated with")
	}
	mcp.connection_destroy(&connection)
	mcp.error_destroy(&connect_err)

	page, page_err := mcp.client_tools_list(&client, mcp.Operation_Options{})
	if page_err.kind == .None {
		check(len(page.tools) == 1, "a listing with no resultType is read")
	} else {
		check(false, "a handshake-era listing is read")
	}
	mcp.tool_page_destroy(&page)
	mcp.error_destroy(&page_err)

	result, call_err := mcp.client_tools_call(&client, "good_a", `{}`, mcp.Operation_Options{})
	if call_err.kind == .None {
		check(!result.input_required, "a handshake-era result is always a completion")
		check(len(result.content) == 1 && result.content[0].text == "legacy ok", "the text is read")
		check(result.structured_json == `{"legacy":true}`, "structured content is read without a resultType")
	} else {
		check(false, "a handshake-era call is read")
	}
	mcp.call_result_destroy(&result)
	mcp.error_destroy(&call_err)
}

// A handshake-era server may ask the client for something at any point, and the
// specification requires a reply. The fake server refuses to answer the call until
// it has seen one, so this fails loudly if the client stays silent.
@(private)
scenario_handshake_server_request :: proc() {
	client: mcp.Client
	defer mcp.client_destroy(&client)
	if !start(&client, scenario_config("legacy_server_request")) { return }
	if !negotiate(&client) { return }

	result, call_err := mcp.client_tools_call(&client, "good_a", `{}`, mcp.Operation_Options{})
	if call_err.kind == .None {
		check(len(result.content) == 1 && result.content[0].text == "legacy ok", "the call completes while the server's own request is answered")
	} else {
		check(false, "a call completes while the server's own request is answered")
	}
	mcp.call_result_destroy(&result)
	mcp.error_destroy(&call_err)
}

@(private)
scenario_handshake_unsupported :: proc() {
	client: mcp.Client
	defer mcp.client_destroy(&client)
	if !start(&client, scenario_config("legacy_unsupported")) { return }

	connection, err := mcp.client_connect(&client, mcp.Operation_Options{})
	check(err.kind == .Version_Unsupported, "a revision this client does not implement is refused")
	check(strings.contains(err.message, "2024-11-05"), "the refusal names the revision the server chose")
	mcp.connection_destroy(&connection)
	mcp.error_destroy(&err)
}

// --- the fake server ---------------------------------------------------------

@(private)
send_raw :: proc(text: string) {
	data := transmute([]u8)text
	written := 0
	for written < len(data) {
		count, write_errno := linux.write(1, data[written:])
		if write_errno != .NONE || count <= 0 { return }
		written += count
	}
	newline := [1]u8{'\n'}
	_, _ = linux.write(1, newline[:])
}

// These build JSON by concatenation rather than through fmt: in a fmt format
// string a brace opens a verb, so every literal brace in a JSON document would
// have to be doubled.
@(private)
send :: proc(id: i64, result: string) {
	send_raw(
		strings.concatenate(
			{`{"jsonrpc":"2.0","id":`, fmt.aprintf("%d", id, allocator = context.temp_allocator), `,"result":`, result, `}`},
			context.temp_allocator,
		),
	)
}

@(private)
send_method_not_found :: proc(id: i64) {
	send_raw(
		strings.concatenate(
			{`{"jsonrpc":"2.0","id":`, fmt.aprintf("%d", id, allocator = context.temp_allocator), `,"error":{"code":-32601,"message":"method not found"}}`},
			context.temp_allocator,
		),
	)
}

// Message_Reader is the fake server's line framing.
//
// It keeps whatever followed a message for the next read, because a client may write
// two messages without waiting between them: `notifications/initialized` and the
// first request after it are exactly that pair, and a reader that dropped the second
// would leave both ends waiting forever.
@(private)
Message_Reader :: struct {
	buffer: [dynamic]u8,
	offset: int,
}

// reader_next returns a view of the next message, or false at end of input. The view
// is valid until the next call.
@(private)
reader_next :: proc(reader: ^Message_Reader) -> ([]u8, bool) {
	for {
		for index in reader.offset ..< len(reader.buffer) {
			if reader.buffer[index] == '\n' {
				start := reader.offset
				reader.offset = index + 1
				return reader.buffer[start:index], true
			}
		}
		// Drop what was already returned before reading more, so the buffer holds only
		// the unconsumed tail.
		if reader.offset > 0 {
			remaining := len(reader.buffer) - reader.offset
			copy(reader.buffer[:remaining], reader.buffer[reader.offset:])
			resize(&reader.buffer, remaining)
			reader.offset = 0
		}
		buffer: [4096]u8
		count, read_errno := linux.read(0, buffer[:])
		if read_errno != .NONE || count <= 0 { return nil, false }
		append(&reader.buffer, ..buffer[:count])
	}
}

@(private)
parse :: proc(line: string) -> (json.Object, bool) {
	value, parse_err := json.parse_string(line, .JSON, true, context.temp_allocator)
	if parse_err != nil { return nil, false }
	object, is_object := value.(json.Object)
	if !is_object { return nil, false }
	return object, true
}

@(private)
message_id :: proc(object: json.Object) -> (i64, bool) {
	value, present := object["id"]
	if !present { return 0, false }
	number, is_integer := value.(json.Integer)
	if !is_integer { return 0, false }
	return i64(number), true
}

@(private)
message_method :: proc(object: json.Object) -> (string, bool) {
	value, present := object["method"]
	if !present { return "", false }
	text, is_string := value.(json.String)
	if !is_string { return "", false }
	return string(text), true
}

// request_has_stateless_meta reports whether a request carries the per-request
// protocol metadata the stateless revision requires.
@(private)
request_has_stateless_meta :: proc(object: json.Object) -> bool {
	params_value, has_params := object["params"]
	if !has_params { return false }
	params, params_is_object := params_value.(json.Object)
	if !params_is_object { return false }
	meta_value, has_meta := params["_meta"]
	if !has_meta { return false }
	meta, meta_is_object := meta_value.(json.Object)
	if !meta_is_object { return false }
	version, _ := meta["io.modelcontextprotocol/protocolVersion"].(json.String)
	if string(version) != mcp.VERSION_2026_07_28 { return false }
	capabilities_value, has_capabilities := meta["io.modelcontextprotocol/clientCapabilities"]
	if !has_capabilities { return false }
	_, capabilities_is_object := capabilities_value.(json.Object)
	return capabilities_is_object
}

@(private)
request_cursor :: proc(object: json.Object) -> string {
	params_value, has_params := object["params"]
	if !has_params { return "" }
	params, params_is_object := params_value.(json.Object)
	if !params_is_object { return "" }
	cursor, _ := params["cursor"].(json.String)
	return string(cursor)
}

@(private)
Fake_Good_A :: `{"name":"good_a","description":"A good tool.","inputSchema":{"type":"object","properties":{"title":{"type":"string"}},"required":["title"]},"annotations":{"readOnlyHint":true}}`

@(private)
Fake_Bad_Annotation :: `{"name":"bad_ann","description":"d","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":"yes"}}`

@(private)
Fake_Good_B :: `{"name":"good_b","description":"Another good tool.","inputSchema":{"type":"object"}}`

@(private)
Fake_No_Description :: `{"name":"no_description","inputSchema":{"type":"object"}}`

@(private)
serve :: proc(scenario: string, extra: []string) {
	// A scenario whose name starts with "legacy" speaks the handshake era: it knows
	// nothing of the stateless probe, negotiates once, and carries no resultType.
	legacy := strings.has_prefix(scenario, "legacy")
	reader: Message_Reader
	for {
		message, read := reader_next(&reader)
		if !read { break }
		if scenario == "stderr_flood" {
			flood_stderr()
			// Exiting without a reply is the failure the parent reads, and by now the
			// harness has had to drain the flood to let the writes complete.
			linux.exit_group(0)
		}
		object, parsed := parse(string(message))
		if !parsed { continue }
		method, has_method := message_method(object)
		if !has_method { continue }
		id, has_id := message_id(object)
		if !has_id {
			// A notification. Only the handshake has one the server cares about.
			continue
		}
		if legacy {
			// Every request but the probe must not carry the stateless envelope: the
			// handshake revisions do not define it, and the negotiated version lives in
			// the handshake result instead. The probe is exempt because it is
			// deliberately shaped like a stateless request, which is what makes the era
			// unambiguous.
			if method != "server/discover" && request_has_stateless_meta(object) { linux.exit_group(6) }
			handle_legacy(&reader, scenario, id, method, extra)
		} else {
			// A stateless request without its protocol metadata is not one this server
			// can act on, so the client is wrong rather than the request unlucky.
			if !request_has_stateless_meta(object) { linux.exit_group(3) }
			handle_stateless(scenario, id, method, object, message, extra)
		}
	}
}

@(private)
handle_stateless :: proc(scenario: string, id: i64, method: string, object: json.Object, raw: []u8, extra: []string) {
	switch method {
	case "server/discover":
		if scenario == "oversized" {
			huge := strings.repeat("x", mcp.MAX_MESSAGE_BYTES + 4096, context.temp_allocator)
			send(
				id,
				strings.concatenate(
					{`{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"instructions":"`, huge, `"}`},
					context.temp_allocator,
				),
			)
			return
		}
		send(id, discover_result(scenario))

	case "tools/list":
		send(id, list_result(scenario, request_cursor(object)))

	case "tools/call":
		if scenario == "lost_reply" {
			if len(extra) > 0 {
				// One byte per call the server saw, so the parent can prove a lost reply
				// was not reissued.
				mark := [1]u8{'c'}
				file, open_err := os.open(extra[0], {.Write, .Create, .Append})
				if open_err == nil {
					_, _ = os.write(file, mark[:])
					os.close(file)
				}
			}
			linux.exit_group(0)
		}
		send(id, call_result(scenario))

	case:
		send_method_not_found(id)
	}
	_ = raw
}

@(private)
handle_legacy :: proc(reader: ^Message_Reader, scenario: string, id: i64, method: string, extra: []string) {
	switch method {
	case "server/discover":
		// The stateless revision's probe is unknown here, which is exactly how the
		// client learns which era it is talking to.
		send_method_not_found(id)

	case "initialize":
		send(id, handshake_result(scenario))

	case "tools/list":
		send(id, strings.concatenate({`{"tools":[`, Fake_Good_A, `]}`}, context.temp_allocator))

	case "tools/call":
		if scenario == "legacy_server_request" {
			// Ask for something this client has no capability for, then wait for its
			// refusal. A client that stayed silent would leave this blocked, so the call
			// it is waiting on would never be answered and the parent would see the
			// server exit.
			send_raw(`{"jsonrpc":"2.0","id":999,"method":"sampling/createMessage","params":{"messages":[]}}`)
			if !await_refusal(reader, 999) { linux.exit_group(4) }
		}
		send(id, `{"content":[{"type":"text","text":"legacy ok"}],"structuredContent":{"legacy":true}}`)

	case:
		send_method_not_found(id)
	}
	_ = extra
}

// await_refusal reads until the client answers the server's own request, and reports
// whether that answer was an error.
@(private)
await_refusal :: proc(reader: ^Message_Reader, id: i64) -> bool {
	for {
		message, read := reader_next(reader)
		if !read { return false }
		object, parsed := parse(string(message))
		if !parsed { continue }
		response_id, has_id := message_id(object)
		if !has_id || response_id != id { continue }
		_, has_error := object["error"]
		_, has_result := object["result"]
		return has_error && !has_result
	}
	return false
}

@(private)
discover_result :: proc(scenario: string) -> string {
	versions := `["2026-07-28"]`
	if scenario == "unsupported" { versions = `["2025-06-18"]` }
	return strings.concatenate(
		{
			`{"resultType":"complete","supportedVersions":`,
			versions,
			`,"capabilities":{"tools":{"listChanged":false}},"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"fake","version":"1"}}}`,
		},
		context.temp_allocator,
	)
}

// handshake_result has no resultType and reports identity at its top level, which is
// the shape the handshake revisions define.
@(private)
handshake_result :: proc(scenario: string) -> string {
	version := `"2025-11-25"`
	if scenario == "legacy_unsupported" { version = `"2024-11-05"` }
	return strings.concatenate(
		{
			`{"protocolVersion":`,
			version,
			`,"capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"fake","version":"1"},"instructions":"a handshake-era test server"}`,
		},
		context.temp_allocator,
	)
}

@(private)
list_result :: proc(scenario: string, cursor: string) -> string {
	switch scenario {
	case "bad_tool":
		return strings.concatenate({`{"resultType":"complete","tools":[`, Fake_Good_A, `,`, Fake_No_Description, `]}`}, context.temp_allocator)
	case "ok":
		if cursor == "" {
			return strings.concatenate(
				{`{"resultType":"complete","nextCursor":"p2","tools":[`, Fake_Good_A, `,`, Fake_Bad_Annotation, `]}`},
				context.temp_allocator,
			)
		}
		return strings.concatenate({`{"resultType":"complete","tools":[`, Fake_Good_B, `]}`}, context.temp_allocator)
	}
	return `{"resultType":"complete","tools":[]}`
}

@(private)
call_result :: proc(scenario: string) -> string {
	switch scenario {
	case "is_error":
		return `{"resultType":"complete","isError":true,"content":[{"type":"text","text":"no such repo"}]}`
	case "input_required":
		return `{"resultType":"input_required","requestState":"opaque","inputRequests":{"q1":{"method":"elicitation/create"}}}`
	}
	return `{"resultType":"complete","content":[{"type":"text","text":"created"}],"structuredContent":{"ok":true}}`
}

// flood_stderr writes more than the harness keeps, so the harness must be draining
// it for these writes to complete at all.
@(private)
flood_stderr :: proc() {
	chunk := strings.repeat("e", 64 * 1024, context.temp_allocator)
	for _ in 0 ..< 4 {
		written := 0
		data := transmute([]u8)chunk
		for written < len(data) {
			count, write_errno := linux.write(2, data[written:])
			if write_errno != .NONE || count <= 0 { return }
			written += count
		}
	}
	// A little time for the drainer to catch up before the stream ends.
	time.sleep(100 * time.Millisecond)
}
