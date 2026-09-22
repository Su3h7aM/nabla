#+build linux
package main

import "core:encoding/json"
import "core:fmt"
import "core:io"
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
	decoder := acp.frame_decoder_init(acp.MAX_FRAME_BYTES, server.alloc)
	defer acp.frame_decoder_destroy(&decoder)
	frames: [dynamic]string
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
	if sync.atomic_load(&server.busy) { agent.chat_cancel_request() }
	return !read_failed && !acp.writer_failed(&server.writer)
}

acp_handle_frame :: proc(server: ^Acp_Server, frame: string) {
	envelope, envelope_err := acp.parse_envelope(frame, context.temp_allocator)
	defer acp.destroy_envelope(&envelope, context.temp_allocator)
	if envelope_err != .None {
		// The message named nothing this agent can answer, so the error is written with a
		// null id: the client matches it to the message it sent.
		_ = acp.writer_write_error(&server.writer, nil, acp.ERROR_PARSE, acp.envelope_error_text(envelope_err))
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
	case acp.METHOD_SESSION_PROMPT:
		acp_request_prompt(server, envelope)
	case:
		acp_reply_error(server, envelope, acp.ERROR_METHOD_NOT_FOUND, fmt.tprintf("nabla does not implement %s", envelope.method))
	}
}

acp_handle_notification :: proc(server: ^Acp_Server, envelope: ^acp.Envelope) {
	switch envelope.method {
	case acp.NOTIFICATION_SESSION_CANCEL:
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
	// The answer is this agent's own version whatever the client asked for; a client that
	// cannot speak it says so by disconnecting.
	server.initialized = true
	result := acp.Initialize_Result {
		protocol_version = acp.PROTOCOL_VERSION,
		agent_capabilities = {
			// A session can be reopened by the id it was given, with its conversation
			// replayed as updates.
			load_session = true,
			prompt_capabilities = {
				// Prompts are text, resource links, and embedded text: no images or audio.
				embedded_context = true,
			},
		},
		auth_methods = make([]json.Value, 0),
		agent_info = {name = NABLA_ACP_NAME, version = NABLA_ACP_VERSION},
	}
	_ = acp.writer_write_response(&server.writer, envelope.id, result)
}

// --- session requests --------------------------------------------------------

acp_request_session_new :: proc(server: ^Acp_Server, envelope: ^acp.Envelope) {
	if !server.initialized {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_REQUEST, "initialize must be answered before a session is opened")
		return
	}
	if sync.atomic_load(&server.busy) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_REQUEST, "a request is already in flight")
		return
	}
	params: acp.Session_New_Params
	if !acp.params_decode(envelope.params, &params, context.temp_allocator) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "session/new needs a working directory")
		return
	}
	if reason := acp_session_params_reason(params.mcp_servers, params.additional_directories); reason != "" {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, reason)
		return
	}
	if params.cwd == "" {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "session/new needs a working directory")
		return
	}
	if !os.is_dir(params.cwd) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, fmt.tprintf("the working directory does not exist: %s", params.cwd))
		return
	}
	work := Acp_Work {
		kind = .Open_Session,
		id = acp_work_id(envelope.id, server.alloc),
		workspace = strings.clone(params.cwd, server.alloc),
		start = {kind = .New},
	}
	if !acp_enqueue(server, work) {
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the request could not be queued")
	}
}

acp_request_session_load :: proc(server: ^Acp_Server, envelope: ^acp.Envelope) {
	if !server.initialized {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_REQUEST, "initialize must be answered before a session is opened")
		return
	}
	if sync.atomic_load(&server.busy) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_REQUEST, "a request is already in flight")
		return
	}
	params: acp.Session_Load_Params
	if !acp.params_decode(envelope.params, &params, context.temp_allocator) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, "session/load needs a session id")
		return
	}
	if reason := acp_session_params_reason(params.mcp_servers, nil); reason != "" {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, reason)
		return
	}
	if !session.session_id_valid(session.Session_Id(params.session_id)) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, fmt.tprintf("%s is not a session id", params.session_id))
		return
	}
	// The session is read once here to refuse an unknown id with a legible error, before
	// anything is given up for it.
	header, load_err := session.session_load(&server.app.setup.store, session.Session_Id(params.session_id), context.temp_allocator)
	if load_err != nil {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, fmt.tprintf("no session named %s", params.session_id))
		return
	}
	defer session.session_destroy(&header, context.temp_allocator)
	if !os.is_dir(header.workspace) {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_PARAMS, fmt.tprintf("the session's directory is not usable: %s", header.workspace))
		return
	}
	reference := strings.clone(params.session_id, server.alloc)
	work := Acp_Work {
		kind = .Open_Session,
		id = acp_work_id(envelope.id, server.alloc),
		session_ref = reference,
		start = {kind = .Resume_Id, id = reference},
	}
	if !acp_enqueue(server, work) {
		acp_reply_error(server, envelope, acp.ERROR_INTERNAL, "the request could not be queued")
	}
}

// acp_session_params_reason says why the servers or directories a client named cannot be
// honored. Both are refusals rather than omissions: a client that asked for an MCP server
// and got no answer would believe the tools were there.
acp_session_params_reason :: proc(mcp_servers: []acp.Mcp_Server, additional_directories: []string) -> string {
	if len(mcp_servers) > 0 {
		return fmt.tprintf("nabla does not accept client-provided MCP servers yet; configure %s in nabla's config.lua", mcp_servers[0].name)
	}
	if len(additional_directories) > 0 {
		return "nabla does not support additional directories yet"
	}
	return ""
}

acp_request_prompt :: proc(server: ^Acp_Server, envelope: ^acp.Envelope) {
	if !server.initialized {
		acp_reply_error(server, envelope, acp.ERROR_INVALID_REQUEST, "initialize must be answered before a prompt")
		return
	}
	if sync.atomic_load(&server.busy) {
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
	work := Acp_Work {
		kind = .Prompt,
		id   = acp_work_id(envelope.id, server.alloc),
		text = strings.clone(text, server.alloc),
	}
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
	return server.session_id != "" && server.session_id == session_id
}

// acp_cancel_session asks the running turn to stop. A cancellation for a session that is
// not running is ignored, which is what the protocol expects: a turn that already ended
// has nothing to cancel.
acp_cancel_session :: proc(server: ^Acp_Server, session_id: string) {
	if !sync.atomic_load(&server.busy) { return }
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
	// immediately cannot clear a flag that was never set.
	sync.atomic_store(&server.busy, true)
	if chan.try_send(server.work, item) { return true }
	sync.atomic_store(&server.busy, false)
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
	builder := strings.builder_make(allocator)
	for block in blocks {
		switch block.type {
		case acp.CONTENT_TEXT:
			acp_prompt_append(&builder, block.text)
		case acp.CONTENT_RESOURCE_LINK:
			if block.uri == "" { continue }
			path := acp_resource_path(block.uri, context.temp_allocator)
			defer delete(path, context.temp_allocator)
			acp_prompt_append(&builder, path)
		case acp.CONTENT_RESOURCE:
			if block.resource.text != "" {
				acp_prompt_append(&builder, block.resource.text)
			} else if block.resource.uri != "" {
				path := acp_resource_path(block.resource.uri, context.temp_allocator)
				defer delete(path, context.temp_allocator)
				acp_prompt_append(&builder, path)
			}
		case:
			strings.builder_destroy(&builder)
			return "", fmt.tprintf("prompt content of type %q is not supported", block.type), false
		}
	}
	return strings.to_string(builder), "", true
}

// acp_prompt_append keeps the blocks of one message apart, so two blocks do not run
// together into one sentence the user never wrote.
@(private)
acp_prompt_append :: proc(builder: ^strings.Builder, text: string) {
	if text == "" { return }
	if strings.builder_len(builder^) > 0 { strings.write_string(builder, "\n\n") }
	strings.write_string(builder, text)
}

// acp_resource_path is the path behind a resource uri. A `file://` uri names a file the
// harness can open itself, which is what its tools take; anything else is passed through
// as the client wrote it.
acp_resource_path :: proc(uri: string, allocator := context.allocator) -> string {
	FILE_URI_PREFIX :: "file://"
	if strings.has_prefix(uri, FILE_URI_PREFIX) { return strings.clone(uri[len(FILE_URI_PREFIX):], allocator) }
	return strings.clone(uri, allocator)
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
	server := new(Acp_Server)
	if server == nil { return false }
	defer free(server)
	server.alloc = context.allocator
	server.app.run.alloc = server.alloc
	server.app.setup.alloc = server.alloc
	server.app.setup.harness_options = harness_options
	// The model this run picks belongs to the conversation, not to the user: an editor
	// session neither publishes a selection nor remembers one.
	server.app.setup.owns_selection = false
	// The writer is opened and the logger installed in the scope that owns the run, so
	// the launch and every turn below it are recorded.
	context.logger = run_log_open(&server.app.setup)
	run_log_header(&server.app.setup)
	if !run_catalog(sources, mcp_servers, &server.app.setup, Session_Start{kind = .New}) { return false }
	defer acp_server_destroy(server)

	server.writer = acp.writer_init(output, server.alloc)
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
