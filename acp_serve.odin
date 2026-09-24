#+build linux
package main

import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"

import "nabla:acp"
import "nabla:agent"
import "nabla:agent/session"

// The ACP conversation: reading messages, answering what the reader can answer on its
// own, and turning the rest into work for the worker. Everything a turn produces is
// written by the worker; everything a request means is decided here.

// NABLA_ACP_NAME and NABLA_ACP_VERSION are what this agent calls itself in initialize.
NABLA_ACP_NAME :: "nabla"
NABLA_ACP_VERSION :: "0.1.0"

// acp_serve reads messages until the input stream ends or the client stops reading, and
// answers each one. False means the stream failed; ending normally is true even when the
// client simply closed it, which is how a client says it is done.
acp_serve :: proc(server: ^Acp_Server, input: io.Reader) -> bool {
	decoder, decoder_error := acp.frame_decoder_init(acp.MAX_FRAME_BYTES, server.alloc)
	if decoder_error != nil {
		_ = acp.writer_write_error(&server.writer, nil, acp.ERROR_INTERNAL, "the ACP frame buffer could not be allocated")
		return false
	}
	defer acp.frame_decoder_destroy(&decoder)
	frames: [dynamic]string
	frames.allocator = server.alloc
	defer acp.frame_strings_destroy(&frames, server.alloc)

	buffer: [ACP_READ_BYTES]u8
	read_failed := false
	for !acp.writer_failed(&server.writer) {
		count, read_err := io.read(input, buffer[:])
		if count == 0 && read_err == nil {
			// A blocking stream that reports nothing read and no error has nothing more to
			// give. Waiting on it again would spin the reader.
			read_err = .EOF
		}
		if count > 0 {
			if frame_err := acp.frame_decoder_feed(&decoder, buffer[:count], &frames); frame_err != .None {
				// The message is dropped rather than half-read; the client is told what was
				// wrong with it, and the conversation continues.
				_ = acp.writer_write_error(&server.writer, nil, acp.ERROR_PARSE, acp.frame_error_text(frame_err))
			}
			for frame in frames {
				acp_handle_frame(server, frame)
				delete(frame, server.alloc)
				// Temp scratch belongs to one message: a request is decoded into it and
				// whatever outlives the message is cloned.
				free_all(context.temp_allocator)
			}
			clear(&frames)
		}
		if read_err != nil {
			// End of input is how a client closes the conversation; any other error means
			// the stream is gone either way.
			read_failed = read_err != .EOF
			break
		}
	}
	// A turn still running is stopped before the worker is joined: it settles as
	// cancelled, so the record says the session was interrupted rather than guessing.
	if acp_server_has_work(server) { agent.chat_cancel_request() }
	return !read_failed && !acp.writer_failed(&server.writer)
}

// acp_frame_error_code maps a frame failure to JSON-RPC codes: broken JSON is a parse
// error, anything else about the envelope is an invalid request, and a failure to
// store the message is internal.
acp_frame_error_code :: proc(err: acp.Envelope_Error) -> i64 {
	switch err {
	case .Invalid_JSON:
		return acp.ERROR_PARSE
	case .Allocation:
		return acp.ERROR_INTERNAL
	case .None, .Invalid_Envelope, .Invalid_Version, .Invalid_ID, .Invalid_Method, .Invalid_Result, .Invalid_Error:
		return acp.ERROR_INVALID_REQUEST
	}
	return acp.ERROR_INVALID_REQUEST
}

acp_handle_frame :: proc(server: ^Acp_Server, frame: string) {
	frames, is_batch, batch_err := acp.parse_batch(frame, server.alloc)
	if is_batch {
		if batch_err != .None {
			_ = acp.writer_write_error(&server.writer, nil, acp_frame_error_code(batch_err), acp.envelope_error_text(batch_err))
			for batch_frame in frames { delete(batch_frame, server.alloc) }
			delete(frames)
			return
		}
		if !acp.writer_begin_batch(&server.writer) {
			for batch_frame in frames { delete(batch_frame, server.alloc) }
			delete(frames)
			return
		}
		for batch_frame in frames {
			acp_handle_batch_frame(server, batch_frame)
			delete(batch_frame, server.alloc)
		}
		delete(frames)
		_ = acp.writer_end_batch(&server.writer)
		return
	}
	acp_handle_single_frame(server, frame)
}

acp_handle_batch_frame :: proc(server: ^Acp_Server, frame: string) {
	envelope, envelope_err := acp.parse_envelope(frame, context.temp_allocator)
	defer acp.destroy_envelope(&envelope, context.temp_allocator)
	if envelope_err != .None {
		_ = acp.writer_write_error(&server.writer, nil, acp_frame_error_code(envelope_err), acp.envelope_error_text(envelope_err))
		return
	}
	if envelope.kind == .Request {
		switch envelope.method {
		case acp.METHOD_SESSION_NEW,
		     acp.METHOD_SESSION_LOAD,
		     acp.METHOD_SESSION_RESUME,
		     acp.METHOD_SESSION_LIST,
		     acp.METHOD_SESSION_CLOSE,
		     acp.METHOD_SESSION_PROMPT,
		     acp.METHOD_SESSION_SET_MODEL,
		     acp.METHOD_SESSION_SET_CONFIG_OPTION:
			_ = acp.writer_write_error(&server.writer, envelope.id, acp.ERROR_INVALID_REQUEST, "lifecycle requests must not be sent in a JSON-RPC batch")
			return
		}
	}
	acp_handle_single_frame(server, frame)
}

acp_handle_single_frame :: proc(server: ^Acp_Server, frame: string) {
	envelope, envelope_err := acp.parse_envelope(frame, context.temp_allocator)
	defer acp.destroy_envelope(&envelope, context.temp_allocator)
	if envelope_err != .None {
		// The message named nothing this agent can answer, so the error is written with a
		// null id: the client matches it to the message it sent.
		_ = acp.writer_write_error(&server.writer, nil, acp_frame_error_code(envelope_err), acp.envelope_error_text(envelope_err))
		return
	}
	switch envelope.kind {
	case .Request:
		acp_handle_request(server, &envelope)
	case .Notification:
		acp_handle_notification(server, &envelope)
	case .Response:
	// This agent sends no requests of its own, so a response answers nothing. A client
	// extension that does is out of this protocol's scope.
	case .Invalid:
	}
}

// acp_handle_request answers one request. A request that opens a session or runs a turn
// is handed to the worker, which owns the session; everything else is answered here.
acp_handle_request :: proc(server: ^Acp_Server, envelope: ^acp.Envelope) {
	switch envelope.method {
	case acp.METHOD_INITIALIZE:
		acp_request_initialize(server, envelope)
	case acp.METHOD_AUTHENTICATE:
		acp_reply_error(server, envelope, acp.ERROR_INVALID_REQUEST, "nabla requires no authentication")
	case acp.METHOD_SESSION_NEW:
		acp_request_session_new(server, envelope)
	case acp.METHOD_SESSION_LOAD:
		acp_request_session_load(server, envelope)
	case acp.METHOD_SESSION_RESUME:
		acp_request_session_resume(server, envelope)
	case acp.METHOD_SESSION_LIST:
		acp_request_session_list(server, envelope)
	case acp.METHOD_SESSION_CLOSE:
		acp_request_session_close(server, envelope)
	case acp.METHOD_SESSION_SET_CONFIG_OPTION:
		acp_request_set_config_option(server, envelope)
	case acp.METHOD_AUTH_LOGIN, acp.METHOD_AUTH_LOGOUT:
		acp_reply_error(server, envelope, acp.ERROR_INVALID_REQUEST, "nabla advertises no authentication methods")
	case acp.METHOD_SESSION_PROMPT:
		acp_request_prompt(server, envelope)
	case acp.METHOD_SESSION_SET_MODEL:
		acp_request_set_model(server, envelope)
	case acp.SESSION_CANCEL:
		acp_request_cancel(server, envelope)
	case:
		acp_reply_error(server, envelope, acp.ERROR_METHOD_NOT_FOUND, fmt.tprintf("nabla does not implement %s", envelope.method))
	}
}

acp_request_cancel :: proc(server: ^Acp_Server, envelope: ^acp.Envelope) {
	params: acp.Session_Cancel_Params
	if !acp.params_decode(envelope.params, &params, context.temp_allocator) || params.session_id == "" {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "session/cancel needs a session id")
		return
	}
	acp_cancel_session(server, params.session_id)
	_ = acp.writer_write_response(&server.writer, envelope.id, acp.Empty_Result{})
}

acp_handle_notification :: proc(server: ^Acp_Server, envelope: ^acp.Envelope) {
	switch envelope.method {
	case acp.SESSION_CANCEL:
		params: acp.Session_Cancel_Params
		if !acp.params_decode(envelope.params, &params, context.temp_allocator) { return }
		acp_cancel_session(server, params.session_id)
	case:
	// A notification is an announcement, not a request: an unknown one is ignored, so a
	// client that speaks a newer version of the protocol is not disconnected by it.
	}
}

acp_reply_error :: proc(server: ^Acp_Server, envelope: ^acp.Envelope, code: i64, message: string) {
	_ = acp.writer_write_error(&server.writer, envelope.id, code, message)
}

// --- requests the reader answers alone ---------------------------------------

acp_request_initialize :: proc(server: ^Acp_Server, envelope: ^acp.Envelope) {
	params: acp.Initialize_Params
	if !acp.params_decode(envelope.params, &params, context.temp_allocator) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "initialize needs a protocol version")
		return
	}
	if params.protocol_version < 1 {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "initialize needs a positive protocol version")
		return
	}
	// A v2 request is valid only when it carries the v2 info object. Buzz currently
	// asks for version 2 while sending the v1 field names, so it deliberately receives
	// the v1 surface instead of being forced through a lifecycle it does not implement.
	v2_request := params.protocol_version >= acp.PROTOCOL_VERSION_V2 && params.info.name != "" && params.info.version != ""
	negotiated := params.protocol_version
	if v2_request {
		negotiated = acp.PROTOCOL_VERSION_V2
	} else if negotiated > acp.PROTOCOL_VERSION {
		negotiated = acp.PROTOCOL_VERSION
	}
	server.protocol_version = negotiated
	server.profile = .V2 if negotiated == acp.PROTOCOL_VERSION_V2 else .V1
	server.initialized = true
	auth_methods, auth_error := make([]json.Value, 0, server.alloc)
	if auth_error != nil {
		server.initialized = false
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the authentication list could not be allocated")
		return
	}
	defer delete(auth_methods, server.alloc)
	if negotiated == acp.PROTOCOL_VERSION_V2 {
		result := acp.V2_Initialize_Result {
			protocol_version = negotiated,
			info = {name = NABLA_ACP_NAME, title = "Nabla", version = NABLA_ACP_VERSION},
			capabilities = {
				// The v2 session surface is implemented below. Nabla does not expose
				// image or audio prompt variants, and it exposes stdio MCP only.
				session = {prompt = {embedded_context = {}}, mcp = {stdio = {}}},
			},
			auth_methods = auth_methods,
		}
		_ = acp.writer_write_response(&server.writer, envelope.id, result)
		return
	}
	result := acp.Initialize_Result {
		protocol_version = negotiated,
		agent_capabilities = {
			// A session can be reopened by the id it was given, with its conversation
			// replayed as updates.
			load_session = true,
			prompt_capabilities = {
				// Prompts are text, resource links, and embedded text: no images or audio.
				embedded_context = true,
			},
			// Stdio MCP is supported. HTTP and SSE are deliberately not advertised.
			mcp_capabilities = {},
		},
		auth_methods = auth_methods,
		agent_info = {name = NABLA_ACP_NAME, title = "Nabla", version = NABLA_ACP_VERSION},
	}
	_ = acp.writer_write_response(&server.writer, envelope.id, result)
}

// --- session requests --------------------------------------------------------

acp_request_session_new :: proc(server: ^Acp_Server, envelope: ^acp.Envelope) {
	if !server.initialized {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_REQUEST, "initialize must be answered before a session is opened")
		return
	}
	if acp_server_has_work(server) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_REQUEST, "a request is already in flight")
		return
	}
	params: acp.Session_New_Params
	if !acp.params_decode(envelope.params, &params, context.temp_allocator) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "session/new needs a working directory")
		return
	}
	if reason := acp_session_params_reason(params.mcp_servers, params.additional_directories, acp_is_v2(server)); reason != "" {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, reason)
		return
	}
	if params.cwd == "" {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "session/new needs a working directory")
		return
	}
	if !strings.has_prefix(params.cwd, "/") {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "session/new needs an absolute working directory")
		return
	}
	if !os.is_dir(params.cwd) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, fmt.tprintf("the working directory does not exist: %s", params.cwd))
		return
	}
	workspace, reference, system_prompt, title, strings_ok := acp_clone_open_strings(
		params.cwd,
		"",
		acp_session_prompt_text(params.system_prompt, &params.meta),
		params.meta.session_title,
		server.alloc,
	)
	if !strings_ok {
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the session parameters could not be allocated")
		return
	}
	client_mcp, mcp_ok := acp_mcp_servers_make(params.mcp_servers, server.alloc)
	if !mcp_ok {
		acp_destroy_open_strings(workspace, reference, system_prompt, title, server.alloc)
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "a client-provided MCP server could not be prepared")
		return
	}
	id, id_ok := acp_work_id(envelope.id, server.alloc)
	if !id_ok {
		acp_destroy_open_strings(workspace, reference, system_prompt, title, server.alloc)
		agent.MCP_Server_Configs_Destroy(&client_mcp, server.alloc)
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the request id could not be allocated")
		return
	}
	acp_enqueue_open_session(server, envelope, id, {kind = .New}, workspace, reference, system_prompt, title, client_mcp, false)
}

acp_request_session_load :: proc(server: ^Acp_Server, envelope: ^acp.Envelope) {
	if !server.initialized {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_REQUEST, "initialize must be answered before a session is opened")
		return
	}
	if acp_server_has_work(server) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_REQUEST, "a request is already in flight")
		return
	}
	params: acp.Session_Load_Params
	if !acp.params_decode(envelope.params, &params, context.temp_allocator) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "session/load needs a session id")
		return
	}
	if reason := acp_session_params_reason(params.mcp_servers, nil, acp_is_v2(server)); reason != "" {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, reason)
		return
	}
	if !session.session_id_valid(session.Session_Id(params.session_id)) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, fmt.tprintf("%s is not a session id", params.session_id))
		return
	}
	// The session is read once here to refuse an unknown id with a legible error, before
	// anything is given up for it.
	header, header_ok := acp_stored_session(server, envelope, params.session_id)
	if !header_ok { return }
	defer session.session_destroy(&header, context.temp_allocator)
	if !os.is_dir(header.workspace) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, fmt.tprintf("the session's directory is not usable: %s", header.workspace))
		return
	}
	if params.cwd != "" && params.cwd != header.workspace {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "the load working directory does not match the session")
		return
	}
	workspace, reference, system_prompt, title, strings_ok := acp_clone_open_strings(
		"",
		params.session_id,
		acp_session_prompt_text(params.system_prompt, &params.meta),
		params.meta.session_title,
		server.alloc,
	)
	if !strings_ok {
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the session parameters could not be allocated")
		return
	}
	client_mcp, mcp_ok := acp_mcp_servers_make(params.mcp_servers, server.alloc)
	if !mcp_ok {
		acp_destroy_open_strings(workspace, reference, system_prompt, title, server.alloc)
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "a client-provided MCP server could not be prepared")
		return
	}
	id, id_ok := acp_work_id(envelope.id, server.alloc)
	if !id_ok {
		acp_destroy_open_strings(workspace, reference, system_prompt, title, server.alloc)
		agent.MCP_Server_Configs_Destroy(&client_mcp, server.alloc)
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the request id could not be allocated")
		return
	}
	acp_enqueue_open_session(server, envelope, id, {kind = .Resume_Id, id = reference}, workspace, reference, system_prompt, title, client_mcp, true)
}

acp_request_session_resume :: proc(server: ^Acp_Server, envelope: ^acp.Envelope) {
	if !acp_is_v2(server) {
		acp_reply_error(server, envelope, acp.ERROR_METHOD_NOT_FOUND, "session/resume requires ACP v2")
		return
	}
	if !server.initialized {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_REQUEST, "initialize must be answered before a session is opened")
		return
	}
	if acp_server_has_work(server) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_REQUEST, "a request is already in flight")
		return
	}
	params: acp.Session_Resume_Params
	if !acp.params_decode(envelope.params, &params, context.temp_allocator) || params.session_id == "" || params.cwd == "" {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "session/resume needs a session id and working directory")
		return
	}
	if reason := acp_session_params_reason(params.mcp_servers, params.additional_directories, acp_is_v2(server)); reason != "" {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, reason)
		return
	}
	if !session.session_id_valid(session.Session_Id(params.session_id)) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, fmt.tprintf("%s is not a session id", params.session_id))
		return
	}
	header, header_ok := acp_stored_session(server, envelope, params.session_id)
	if !header_ok { return }
	defer session.session_destroy(&header, context.temp_allocator)
	if header.workspace != params.cwd {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "the resume working directory does not match the session")
		return
	}
	replay := false
	if cursor, present := params.replay_from.?; present {
		if cursor.type != "start" {
			acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "only the start replay cursor is supported")
			return
		}
		replay = true
	}
	workspace, reference, system_prompt, title, strings_ok := acp_clone_open_strings(
		"",
		params.session_id,
		acp_session_prompt_text(params.system_prompt, &params.meta),
		params.meta.session_title,
		server.alloc,
	)
	if !strings_ok {
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the session parameters could not be allocated")
		return
	}
	client_mcp, mcp_ok := acp_mcp_servers_make(params.mcp_servers, server.alloc)
	if !mcp_ok {
		acp_destroy_open_strings(workspace, reference, system_prompt, title, server.alloc)
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "a client-provided MCP server could not be prepared")
		return
	}
	id, id_ok := acp_work_id(envelope.id, server.alloc)
	if !id_ok {
		acp_destroy_open_strings(workspace, reference, system_prompt, title, server.alloc)
		agent.MCP_Server_Configs_Destroy(&client_mcp, server.alloc)
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the request id could not be allocated")
		return
	}
	acp_enqueue_open_session(server, envelope, id, {kind = .Resume_Id, id = reference}, workspace, reference, system_prompt, title, client_mcp, replay)
}

acp_request_session_list :: proc(server: ^Acp_Server, envelope: ^acp.Envelope) {
	if !acp_is_v2(server) {
		acp_reply_error(server, envelope, acp.ERROR_METHOD_NOT_FOUND, "session/list requires ACP v2")
		return
	}
	if !server.initialized {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_REQUEST, "initialize must be answered before sessions are listed")
		return
	}
	params: acp.Session_List_Params
	if envelope.params != nil && !acp.params_decode(envelope.params, &params, context.temp_allocator) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "session/list has invalid parameters")
		return
	}
	if params.cwd != "" && !strings.has_prefix(params.cwd, "/") {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "the session/list working directory must be absolute")
		return
	}
	cwd, cwd_error := strings.clone(params.cwd, server.alloc)
	if cwd_error != nil {
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the session list filter could not be allocated")
		return
	}
	cursor, cursor_error := strings.clone(params.cursor, server.alloc)
	if cursor_error != nil {
		delete(cwd, server.alloc)
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the session list cursor could not be allocated")
		return
	}
	id, id_ok := acp_work_id(envelope.id, server.alloc)
	if !id_ok {
		delete(cwd, server.alloc)
		delete(cursor, server.alloc)
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the request id could not be allocated")
		return
	}
	work := Acp_Work {
		kind        = .List_Sessions,
		id          = id,
		list_cwd    = cwd,
		list_cursor = cursor,
	}
	work.session_generation = acp_capture_session_generation(server)
	if !acp_enqueue(server, work) {
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the request could not be queued")
	}
}

acp_request_session_close :: proc(server: ^Acp_Server, envelope: ^acp.Envelope) {
	if !acp_is_v2(server) {
		acp_reply_error(server, envelope, acp.ERROR_METHOD_NOT_FOUND, "session/close requires ACP v2")
		return
	}
	params: acp.Session_Close_Params
	if !acp.params_decode(envelope.params, &params, context.temp_allocator) || params.session_id == "" {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "session/close needs a session id")
		return
	}
	if !acp_session_matches(server, params.session_id) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "no session is open for that id")
		return
	}
	acp_cancel_session(server, params.session_id)
	reference, reference_error := strings.clone(params.session_id, server.alloc)
	if reference_error != nil {
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the session reference could not be allocated")
		return
	}
	id, id_ok := acp_work_id(envelope.id, server.alloc)
	if !id_ok {
		delete(reference, server.alloc)
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the request id could not be allocated")
		return
	}
	work := Acp_Work {
		kind        = .Close_Session,
		id          = id,
		session_ref = reference,
	}
	acp_mark_session_closing(server)
	work.session_generation = acp_capture_session_generation(server)
	if !acp_enqueue(server, work) {
		acp_unmark_session_closing(server, work.session_generation)
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the request could not be queued")
	}
}

acp_request_set_config_option :: proc(server: ^Acp_Server, envelope: ^acp.Envelope) {
	if !server.initialized {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_REQUEST, "initialize must be answered before configuration can change")
		return
	}
	params: acp.Session_Set_Config_Option_Params
	if !acp.params_decode(envelope.params, &params, context.temp_allocator) || params.session_id == "" || params.config_id == "" || params.value == "" {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "session/set_config_option needs a session, config id, and value")
		return
	}
	if !acp_session_matches(server, params.session_id) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "no session is open for that id")
		return
	}
	config_id, config_id_error := strings.clone(params.config_id, server.alloc)
	if config_id_error != nil {
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the config id could not be allocated")
		return
	}
	value, value_error := strings.clone(params.value, server.alloc)
	if value_error != nil {
		delete(config_id, server.alloc)
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the config value could not be allocated")
		return
	}
	id, id_ok := acp_work_id(envelope.id, server.alloc)
	if !id_ok {
		delete(config_id, server.alloc)
		delete(value, server.alloc)
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the request id could not be allocated")
		return
	}
	work := Acp_Work {
		kind         = .Set_Config_Option,
		id           = id,
		config_id    = config_id,
		config_value = value,
	}
	work.session_generation = acp_capture_session_generation(server)
	if !acp_enqueue(server, work) {
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the request could not be queued")
	}
}

// acp_session_prompt_text reads the system prompt an open request carries: the
// top-level field first, then the `_meta` forms clients use to append or replace
// standing instructions.
acp_session_prompt_text :: proc(field: string, meta: ^acp.Session_Meta) -> string {
	if field != "" { return field }
	return acp_session_meta_system_prompt(meta)
}

// acp_clone_open_strings copies the owned strings one Open_Session work item carries.
// A failure releases whatever was already copied, so the caller answers and returns.
acp_clone_open_strings :: proc(
	workspace, reference, prompt, title: string,
	allocator := context.allocator,
) -> (
	owned_workspace, owned_reference, owned_prompt, owned_title: string,
	ok: bool,
) {
	workspace_copy, workspace_error := strings.clone(workspace, allocator)
	if workspace_error != nil { return "", "", "", "", false }
	reference_copy, reference_error := strings.clone(reference, allocator)
	if reference_error != nil {
		delete(workspace_copy, allocator)
		return "", "", "", "", false
	}
	prompt_copy, prompt_error := strings.clone(prompt, allocator)
	if prompt_error != nil {
		delete(workspace_copy, allocator)
		delete(reference_copy, allocator)
		return "", "", "", "", false
	}
	title_copy, title_error := strings.clone(title, allocator)
	if title_error != nil {
		delete(workspace_copy, allocator)
		delete(reference_copy, allocator)
		delete(prompt_copy, allocator)
		return "", "", "", "", false
	}
	return workspace_copy, reference_copy, prompt_copy, title_copy, true
}

// acp_destroy_open_strings releases open-request strings the worker will not own.
acp_destroy_open_strings :: proc(workspace, reference, prompt, title: string, allocator: mem.Allocator) {
	delete(workspace, allocator)
	delete(reference, allocator)
	delete(prompt, allocator)
	delete(title, allocator)
}

// acp_stored_session reads the stored session an open request names. An unknown id is
// refused as invalid params; a store that cannot answer is an internal error. The
// header is owned by the temp allocator.
acp_stored_session :: proc(server: ^Acp_Server, envelope: ^acp.Envelope, session_id: string) -> (header: session.Session, ok: bool) {
	loaded, load_error := session.session_load(&server.app.setup.store, session.Session_Id(session_id), context.temp_allocator)
	if load_error == nil { return loaded, true }
	if failure, is_failure := load_error.(session.Failure); is_failure && failure.kind == .Not_Found {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, fmt.tprintf("no session named %s", session_id))
	} else {
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, fmt.tprintf("the session %s could not be read", session_id))
	}
	return {}, false
}

// acp_enqueue_open_session hands a validated open request to the worker. The strings
// change owners here: on success the worker releases them, on failure the queue does,
// so the caller keeps nothing.
acp_enqueue_open_session :: proc(
	server: ^Acp_Server,
	envelope: ^acp.Envelope,
	id: acp.Jsonrpc_Id,
	start: Session_Start,
	workspace, session_ref, system_prompt, title: string,
	mcp_servers: [dynamic]agent.MCP_Server_Config,
	replay: bool,
) {
	// start.id aliases session_ref; the work item releases session_ref only.
	work := Acp_Work {
		kind          = .Open_Session,
		id            = id,
		workspace     = workspace,
		session_ref   = session_ref,
		mcp_servers   = mcp_servers,
		system_prompt = system_prompt,
		session_title = title,
		start         = start,
		replay        = replay,
	}
	work.session_generation = acp_capture_session_generation(server)
	if !acp_enqueue(server, work) {
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the request could not be queued")
	}
}
// acp_session_meta_system_prompt reads the two systemPrompt forms used by ACP
// clients. The object form appends to the agent's own instructions instead of
// replacing them.
acp_session_meta_system_prompt :: proc(meta: ^acp.Session_Meta) -> string {
	#partial switch prompt in meta.system_prompt {
	case json.String:
		return string(prompt)
	case json.Object:
		if append_value, present := prompt["append"]; present {
			if text, is_text := append_value.(json.String); is_text { return string(text) }
		}
	}
	return ""
}

// acp_session_params_reason reports a named capability that Nabla cannot honor.
// Refusing is safer than silently dropping tools or directories. The MCP type is
// required on v2 and optional on v1, matching what each profile's clients send.
acp_session_params_reason :: proc(mcp_servers: []acp.Mcp_Server, additional_directories: []string, is_v2: bool) -> string {
	for server in mcp_servers {
		if is_v2 {
			if server.type != "stdio" {
				return fmt.tprintf("MCP server %q needs the stdio transport", server.name)
			}
		} else if server.type != "" && server.type != "stdio" {
			return fmt.tprintf("MCP server %q uses an unsupported transport %q", server.name, server.type)
		}
		if server.command == "" || !strings.has_prefix(server.command, "/") {
			return fmt.tprintf("MCP server %q needs an absolute command path", server.name)
		}
	}
	if len(additional_directories) > 0 {
		return "nabla does not support additional directories yet"
	}
	return ""
}

acp_mcp_servers_make :: proc(servers: []acp.Mcp_Server, allocator: mem.Allocator) -> ([dynamic]agent.MCP_Server_Config, bool) {
	result, result_error := make([dynamic]agent.MCP_Server_Config, 0, len(servers), allocator)
	if result_error != nil { return {}, false }
	for server in servers {
		for existing in result {
			if existing.id == server.name { agent.MCP_Server_Configs_Destroy(&result, allocator); return {}, false }
		}
		names, names_error := make([dynamic]string, 0, len(server.env), context.temp_allocator)
		if names_error != nil { agent.MCP_Server_Configs_Destroy(&result, allocator); return {}, false }
		values, values_error := make([dynamic]string, 0, len(server.env), context.temp_allocator)
		if values_error != nil {
			delete(names)
			agent.MCP_Server_Configs_Destroy(&result, allocator)
			return {}, false
		}
		for entry in server.env {
			if append(&names, entry.name) != 1 {
				delete(names)
				delete(values)
				agent.MCP_Server_Configs_Destroy(&result, allocator)
				return {}, false
			}
			if append(&values, entry.value) != 1 {
				delete(names)
				delete(values)
				agent.MCP_Server_Configs_Destroy(&result, allocator)
				return {}, false
			}
		}
		config, config_error := agent.MCP_Server_Config_From_Stdio(server.name, server.command, server.args, names[:], values[:], allocator)
		delete(names)
		delete(values)
		if config_error != .None { agent.MCP_Server_Configs_Destroy(&result, allocator); return {}, false }
		appended := append(&result, config)
		if appended != 1 {
			if appended == 0 { agent.MCP_Server_Config_Destroy(&config, allocator) }
			agent.MCP_Server_Configs_Destroy(&result, allocator)
			return {}, false
		}
	}
	return result, true
}

acp_request_prompt :: proc(server: ^Acp_Server, envelope: ^acp.Envelope) {
	if !server.initialized {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_REQUEST, "initialize must be answered before a prompt")
		return
	}
	if acp_server_has_work(server) && !acp_is_v2(server) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_REQUEST, "a request is already in flight")
		return
	}
	params: acp.Session_Prompt_Params
	if !acp.params_decode(envelope.params, &params, context.temp_allocator) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "session/prompt needs a prompt")
		return
	}
	// The prompt names the session it belongs to. A request for a session this process is
	// not running is refused here: the process holds a session of its own from startup,
	// and only the client's own session/new may replace it.
	if !acp_session_matches(server, params.session_id) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "no session is open for that id; call session/new first")
		return
	}
	text, reason, ok := acp_prompt_text(params.prompt, context.temp_allocator)
	if !ok {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, reason)
		return
	}
	if text == "" {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "the prompt is empty")
		return
	}
	if server.app.setup.model_id == "" {
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "no model is selected; configure a provider in nabla's config.lua")
		return
	}
	prompt_text, prompt_error := strings.clone(text, server.alloc)
	if prompt_error != nil {
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the prompt could not be allocated")
		return
	}
	id, id_ok := acp_work_id(envelope.id, server.alloc)
	if !id_ok {
		delete(prompt_text, server.alloc)
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the request id could not be allocated")
		return
	}
	work := Acp_Work {
		kind = .Prompt,
		id   = id,
		text = prompt_text,
	}
	work.session_generation = acp_capture_session_generation(server)
	if !acp_enqueue(server, work) {
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the request could not be queued")
	}
}

acp_request_set_model :: proc(server: ^Acp_Server, envelope: ^acp.Envelope) {
	if acp_is_v2(server) {
		acp_reply_error(server, envelope, acp.ERROR_METHOD_NOT_FOUND, "session/set_model is a Buzz v1 extension; use session/set_config_option")
		return
	}
	if !server.initialized {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_REQUEST, "initialize must be answered before a model can be selected")
		return
	}
	if acp_server_has_work(server) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_REQUEST, "a request is already in flight")
		return
	}
	params: acp.Session_Set_Model_Params
	if !acp.params_decode(envelope.params, &params, context.temp_allocator) || params.session_id == "" || params.model_id == "" {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "session/set_model needs a session id and model id")
		return
	}
	if !acp_session_matches(server, params.session_id) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "no session is open for that id; call session/new first")
		return
	}
	model_id, model_error := strings.clone(params.model_id, server.alloc)
	if model_error != nil {
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the model id could not be allocated")
		return
	}
	id, id_ok := acp_work_id(envelope.id, server.alloc)
	if !id_ok {
		delete(model_id, server.alloc)
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the request id could not be allocated")
		return
	}
	work := Acp_Work {
		kind     = .Set_Model,
		id       = id,
		model_id = model_id,
	}
	work.session_generation = acp_capture_session_generation(server)
	if !acp_enqueue(server, work) {
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the request could not be queued")
	}
}

// acp_session_matches reports whether the id names the session this process runs. A
// request is matched against it before it is handed to the worker, so a request for a
// session the client never opened cannot reach the session the process started with.
acp_session_matches :: proc(server: ^Acp_Server, session_id: string) -> bool {
	sync.mutex_lock(&server.mu)
	defer sync.mutex_unlock(&server.mu)
	return !server.closing && server.session_id != "" && server.session_id == session_id
}

acp_closing_session_matches :: proc(server: ^Acp_Server, session_id: string) -> bool {
	sync.mutex_lock(&server.mu)
	defer sync.mutex_unlock(&server.mu)
	return server.closing && server.session_id != "" && server.session_id == session_id
}

// acp_cancel_session asks the running turn to stop. A cancellation for a session that is
// not running is ignored, which is what the protocol expects: a turn that already ended
// has nothing to cancel.
acp_cancel_session :: proc(server: ^Acp_Server, session_id: string) {
	if !acp_server_has_work(server) { return }
	if !acp_session_matches(server, session_id) { return }
	// The request is recorded, because accepting the prompt clears the process's
	// cancellation token and the worker re-issues it for the turn that must see it.
	sync.atomic_store(&server.cancel_seen, true)
	agent.chat_cancel_request()
}

// acp_enqueue hands one request to the worker. It owns work on both paths: on success the
// worker releases it, and on failure it is released here, so the caller must not free it
// again.
acp_enqueue :: proc(server: ^Acp_Server, work: Acp_Work) -> bool {
	item := work
	// The request is marked in flight before it is queued, so a worker that finishes it
	// immediately cannot clear a flag that was never set. The count keeps that flag set
	// while a v2 prompt waits behind the active turn.
	acp_queue_add(server)
	if chan.try_send(server.work, item) { return true }
	acp_queue_remove(server)
	acp_work_destroy(&item, server.alloc)
	return false
}

// --- prompts -----------------------------------------------------------------

// acp_prompt_text renders a prompt's content blocks as the one message the harness
// records. Text blocks are the message itself. A resource link becomes the path it names,
// so the model reads the file with its own tools rather than being handed a URI nothing
// in the harness can open. An embedded resource brings its text along. Content this agent
// does not accept is refused rather than dropped: a client must be told that part of what
// it sent never reached the model.
//
// reason is static text when ok is false.
acp_prompt_text :: proc(blocks: []acp.Content_Block, allocator := context.allocator) -> (text: string, reason: string, ok: bool) {
	builder, builder_error := strings.builder_make(allocator)
	if builder_error != nil { return "", "the prompt could not be allocated", false }
	complete := false
	defer if !complete { strings.builder_destroy(&builder) }
	for block in blocks {
		switch block.type {
		case acp.CONTENT_TEXT:
			if !acp_prompt_append(&builder, block.text) {
				return "", "the prompt could not be allocated", false
			}
		case acp.CONTENT_RESOURCE_LINK:
			if block.uri == "" { continue }
			path, path_ok := acp_resource_path(block.uri, context.temp_allocator)
			defer delete(path, context.temp_allocator)
			if !path_ok || !acp_prompt_append(&builder, path) {
				return "", "the resource path could not be allocated", false
			}
		case acp.CONTENT_RESOURCE:
			if block.resource.text != "" {
				if !acp_prompt_append(&builder, block.resource.text) {
					return "", "the prompt could not be allocated", false
				}
			} else if block.resource.uri != "" {
				path, path_ok := acp_resource_path(block.resource.uri, context.temp_allocator)
				defer delete(path, context.temp_allocator)
				if !path_ok || !acp_prompt_append(&builder, path) {
					return "", "the resource path could not be allocated", false
				}
			}
		case:
			strings.builder_destroy(&builder)
			return "", fmt.tprintf("prompt content of type %q is not supported", block.type), false
		}
	}
	text = strings.to_string(builder)
	complete = true
	return text, "", true
}

// acp_prompt_append keeps the blocks of one message apart, so two blocks do not run
// together into one sentence the user never wrote.
@(private)
acp_prompt_append :: proc(builder: ^strings.Builder, text: string) -> bool {
	if text == "" { return true }
	if strings.builder_len(builder^) > 0 && strings.write_string(builder, "\n\n") != 2 { return false }
	return strings.write_string(builder, text) == len(text)
}

// acp_resource_path is the path behind a resource uri. A `file://` uri names a file the
// harness can open itself, which is what its tools take; anything else is passed through
// as the client wrote it.
acp_resource_path :: proc(uri: string, allocator := context.allocator) -> (string, bool) {
	FILE_URI_PREFIX :: "file://"
	value := uri
	if strings.has_prefix(uri, FILE_URI_PREFIX) { value = uri[len(FILE_URI_PREFIX):] }
	path, clone_error := strings.clone(value, allocator)
	if clone_error != nil { return "", false }
	return path, true
}

// --- entry point -------------------------------------------------------------

acp_usage :: proc() {
	fmt.println("nabla acp [--config PATH]")
	fmt.println("runs an Agent Client Protocol agent on stdin and stdout, for an editor or another ACP client")
	fmt.println("default config: $XDG_CONFIG_HOME/nabla/config.lua (~/.config/nabla/config.lua)")
}

// acp_run opens the front-end, serves one conversation on the given streams, and releases
// everything it owns. It is the whole front-end except the configuration it is launched
// with and the process lifetime around it, which is what lets a test drive a real
// conversation without a process. False means the run could not be opened or the stream
// failed before it ended.
acp_run :: proc(
	sources: []agent.Catalog_Provider_Source,
	harness_options: agent.Harness_Options,
	mcp_servers: []agent.MCP_Server_Config,
	input: io.Reader,
	output: io.Writer,
) -> bool {
	server, server_error := new(Acp_Server)
	if server_error != nil { return false }
	defer free(server)
	server.alloc = context.allocator
	server.app.run.alloc = server.alloc
	server.app.setup.alloc = server.alloc
	server.app.setup.harness_options = harness_options
	server.base_mcp_servers = mcp_servers
	// The model this run picks belongs to the conversation, not to the user: an editor
	// session neither publishes a selection nor remembers one.
	server.app.setup.owns_selection = false
	// The writer is opened and the logger installed in the scope that owns the run, so
	// the launch and every turn below it are recorded.
	context.logger = run_log_open(&server.app.setup)
	run_log_header(&server.app.setup)
	if !run_catalog(sources, mcp_servers, &server.app.setup, Session_Start{kind = .New}) { return false }
	defer acp_server_destroy(server)

	writer, writer_err := acp.writer_init(output, server.alloc)
	if writer_err != nil {
		fmt.eprintln("nabla: cannot create the ACP writer")
		return false
	}
	server.writer = writer
	channel, channel_err := chan.create_buffered(Acp_Work_Chan, ACP_WORK_CAPACITY, server.alloc)
	if channel_err != nil {
		fmt.eprintln("nabla: cannot create the request queue")
		return false
	}
	server.work = channel
	worker := thread.create(acp_worker, name = "nabla-acp-worker")
	if worker == nil {
		fmt.eprintln("nabla: cannot start the ACP worker thread")
		return false
	}
	worker.data = server
	server.worker = worker
	thread.start(worker)

	if !acp_select_startup_model(server) {
		fmt.eprintln("nabla: no model could be selected; configure a provider in nabla's config.lua")
	}
	return acp_serve(server, input)
}

// acp_main runs the ACP agent and returns the process exit code. The launch path is the
// headless one: the same configuration, the same catalog, the same session store. Only
// the front-end differs.
acp_main :: proc(args: []string) -> int {
	config_path := ""
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if arg == "--help" || arg == "-h" {
			acp_usage()
			return 0
		}
		if strings.has_prefix(arg, "--config=") { config_path = arg[len("--config="):]; continue }
		if arg == "--config" {
			if i + 1 >= len(args) {
				acp_usage()
				return 2
			}
			i += 1
			config_path = args[i]
			continue
		}
		acp_usage()
		return 2
	}
	if config_path == "" {
		directory, directory_err := agent.xdg_directory(.Config, context.temp_allocator)
		if directory_err != .None {
			fmt.eprintln("nabla: cannot resolve the configuration directory")
			return 1
		}
		config_path = strings.concatenate([]string{directory, "/config.lua"}, allocator = context.temp_allocator)
	}
	sources, harness_options, mcp_servers, config_err := agent.load_lua_config_full(config_path)
	if config_err != .None && config_err != .Missing {
		fmt.eprintln("nabla:", agent.config_error_text(config_err))
		return 1
	}
	defer agent.catalog_sources_destroy(&sources)
	defer agent.mcp_servers_destroy(&mcp_servers)

	// Signals end the run the way a client closing the stream does, so a killed editor
	// leaves a session that says it was interrupted. This is the process's own lifetime,
	// not the conversation's, so it stays here.
	signals: agent.Chat_Interactive_Signals
	agent.chat_interactive_arm(&signals)
	defer agent.chat_interactive_disarm(&signals)

	served := acp_run(sources[:], harness_options, mcp_servers[:], io.to_reader(os.to_stream(os.stdin)), io.to_writer(os.to_stream(os.stdout)))
	// A signal ends the run the way a client closing the stream does: the handler set the
	// process's cancellation token, and stopping for it is not a stream failure.
	if served || agent.chat_cancel_requested() { return 0 }
	return 1
}
