package agent

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

import "nabla:acp"
import "nabla:ai"

// An ACP subagent is another agent program, driven over the Agent Client Protocol on its
// stdin and stdout. The subagent's thread is the only one using the connection: it sends one
// request at a time and reads until that request is answered, handling whatever the agent
// sends meanwhile. The agent brings its own tools, so the client offers no file system or
// terminal, and it grants the agent's permission requests the way a native subagent runs its
// tools without asking.

// Subagent_Program is the ACP agent a subagent runs as. Every field is owned.
Subagent_Program :: struct {
	name:          string, // the configured agent's name; "" for a native subagent
	command:       string, // the executable's resolved path
	arguments:     []string,
	model:         string, // one of the agent's models, or "" for its default
	parent_effort: string, // the orchestrator's effort and levels, for the default effort
	parent_levels: []string,
}

// SUBAGENT_ACP_STDERR_BYTES is how much of the end of an agent's stderr a failure report
// quotes. It sizes a diagnostic, not the agent's work.
SUBAGENT_ACP_STDERR_BYTES :: 4096

SUBAGENT_ACP_READ_BYTES :: 16 * 1024

// ACP_OPTION_CATEGORY_MODEL and ACP_OPTION_CATEGORY_EFFORT are the session config option
// categories that choose a model and its reasoning effort.
ACP_OPTION_CATEGORY_MODEL :: "model"
ACP_OPTION_CATEGORY_EFFORT :: "thought_level"

subagent_program_destroy :: proc(program: ^Subagent_Program, allocator: mem.Allocator) {
	delete(program.name, allocator)
	delete(program.command, allocator)
	for argument in program.arguments { delete(argument, allocator) }
	delete(program.arguments, allocator)
	delete(program.model, allocator)
	delete(program.parent_effort, allocator)
	for level in program.parent_levels { delete(level, allocator) }
	delete(program.parent_levels, allocator)
	program^ = {}
}

// subagent_program defines the configured ACP agent a start call names. problem, temp-allocated,
// says why it cannot run.
@(private)
subagent_program :: proc(args: Agent_Spawn_Args, parent: ^Agent_Parent, allocator: mem.Allocator) -> (program: Subagent_Program, problem: string) {
	config: ACP_Agent_Config
	for candidate in parent.acp_agents {
		if candidate.name == args.acp_agent { config = candidate }
	}
	if config.name == "" {
		names := make([dynamic]string, 0, len(parent.acp_agents), context.temp_allocator)
		for candidate in parent.acp_agents { append(&names, candidate.name) }
		configured := strings.join(names[:], ", ", context.temp_allocator) if len(names) > 0 else "none"
		return {}, fmt.tprintf("no ACP agent named %q is configured; configured: %s", args.acp_agent, configured)
	}
	path, found := subagent_command_path(config.command, parent.workspace)
	if !found { return {}, fmt.tprintf("ACP agent %s: command %q is neither an executable file nor a program on PATH; nothing started", config.name, config.command) }
	program.name = strings.clone(config.name, allocator)
	program.command = strings.clone(path, allocator)
	program.arguments = make([]string, len(config.arguments), allocator)
	for argument, index in config.arguments { program.arguments[index] = strings.clone(argument, allocator) }
	program.model = strings.clone(args.model, allocator)
	program.parent_effort = strings.clone(parent.effort, allocator)
	program.parent_levels = make([]string, len(parent.effort_levels), allocator)
	for level, index in parent.effort_levels { program.parent_levels[index] = strings.clone(level, allocator) }
	return program, ""
}

// subagent_command_path finds the executable command names, temp-allocated: a path relative to
// directory when it has a slash, else the first match on PATH.
@(private)
subagent_command_path :: proc(command, directory: string) -> (string, bool) {
	if strings.contains_rune(command, '/') {
		path := command
		if !strings.has_prefix(command, "/") { path = strings.concatenate({directory, "/", command}, context.temp_allocator) }
		return path, subagent_executable(path)
	}
	search := string(posix.getenv("PATH"))
	for entry in strings.split_iterator(&search, ":") {
		if entry == "" { continue }
		path := strings.concatenate({entry, "/", command}, context.temp_allocator)
		if subagent_executable(path) { return path, true }
	}
	return "", false
}

@(private)
subagent_executable :: proc(path: string) -> bool {
	text := strings.clone_to_cstring(path, context.temp_allocator)
	return posix.access(text, {.X_OK}) == .OK && !os.is_dir(path)
}

// Acp_Connection is one running agent program and the client state of its session.
@(private)
Acp_Connection :: struct {
	member:        ^Subagent,
	child:         Tool_Child,
	started:       bool,
	input:         Acp_Input,
	output:        ^os.File, // read end of the agent's stdout
	errors:        ^os.File, // read end of the agent's stderr; nil once it ends
	writer:        acp.Writer,
	decoder:       acp.Frame_Decoder,
	frames:        [dynamic]string,
	next_frame:    int,
	next_id:       i64,
	version:       int, // the ACP version the agent agreed to
	session_id:    string,
	answer:        [dynamic]u8, // the text of the agent's latest message since its last tool call
	message_id:    string, // the latest message's id, owned; "" when the agent sends none
	idle:          bool, // version 2: the agent reported its turn over
	stop_reason:   string, // why the turn ended, owned
	stderr_tail:   [dynamic]u8,
	cancel_sent:   bool,
	stop_deadline: time.Tick,
}

// subagent_acp_run runs the member's ACP agent until it answers the task and every message the
// orchestrator sent after that, and records the outcome in member.
@(private)
subagent_acp_run :: proc(member: ^Subagent) {
	allocator := member.allocator
	connection := Acp_Connection {
		member      = member,
		frames      = make([dynamic]string, allocator),
		answer      = make([dynamic]u8, allocator),
		stderr_tail = make([dynamic]u8, allocator),
	}
	defer acp_connection_close(&connection)
	if problem := acp_connection_open(&connection); problem != "" {
		subagent_fail(member, .Failed, problem)
		return
	}
	if problem := acp_session_open(&connection); problem != "" {
		subagent_fail(member, acp_stopped(&connection) ? .Stopped : .Failed, problem)
		return
	}
	member.session_id = strings.clone(connection.session_id, allocator)

	text := member.prompt
	if member.instruction != "" { text = strings.concatenate({member.instruction, "\n\n", member.prompt}, context.temp_allocator) }
	from_inbox := false
	for {
		// Each prompt releases the temp memory its answers were decoded into.
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		stop_reason, problem := acp_prompt(&connection, text)
		if from_inbox { steer_line_free(&member.inbox, text) }
		switch {
		case problem != "":
			subagent_fail(member, acp_stopped(&connection) ? .Stopped : .Failed, problem)
			return
		case stop_reason == "cancelled" || acp_stopped(&connection):
			subagent_fail(member, .Stopped, "the subagent was stopped before it finished")
			return
		case stop_reason != "end_turn":
			reason := fmt.tprintf("the agent ended its turn with %q; what it answered:\n\n%s", stop_reason, string(connection.answer[:]))
			subagent_fail(member, .Failed, reason)
			return
		}
		line, more := subagent_next_message(member)
		if !more { break }
		text, from_inbox = line, true
	}
	member.status = .Completed
	member.answer = strings.clone(string(connection.answer[:]), allocator)
}

// acp_prompt sends one prompt and waits until the agent's turn is over. Version 1 ends the turn
// with the prompt's answer; version 2 acknowledges the prompt and reports the end as an idle
// state update. stop_reason is the agent's, temp-allocated.
@(private)
acp_prompt :: proc(connection: ^Acp_Connection, text: string) -> (stop_reason: string, problem: string) {
	Text_Block :: struct {
		type: string `json:"type"`,
		text: string `json:"text"`,
	}
	Prompt :: struct {
		session_id: string `json:"sessionId"`,
		prompt:     []Text_Block `json:"prompt"`,
	}
	clear(&connection.answer)
	acp_replace(&connection.message_id, "", connection.member.allocator)
	acp_replace(&connection.stop_reason, "", connection.member.allocator)
	connection.idle = false
	prompt := Prompt {
		session_id = connection.session_id,
		prompt     = {{type = acp.CONTENT_TEXT, text = text}},
	}
	if connection.version == 1 {
		result: acp.Prompt_Result
		if problem = acp_call(connection, acp.METHOD_SESSION_PROMPT, prompt, &result); problem != "" { return }
		return result.stop_reason, ""
	}
	// A stop reason in the answer is version 1's end of the turn, which an agent that
	// misstates its version may still send.
	Accepted :: struct {
		message_id:  string `json:"messageId"`,
		stop_reason: string `json:"stopReason"`,
	}
	accepted: Accepted
	if problem = acp_call(connection, acp.METHOD_SESSION_PROMPT, prompt, &accepted); problem != "" { return }
	if accepted.stop_reason != "" { return accepted.stop_reason, "" }
	for !connection.idle {
		envelope, next_problem := acp_next(connection)
		if next_problem != "" { return "", next_problem }
		acp_handle(connection, envelope)
		acp.destroy_envelope(&envelope, connection.member.allocator)
	}
	// An agent that states no reason ended its turn normally.
	if connection.stop_reason == "" { return "end_turn", "" }
	return strings.clone(connection.stop_reason, context.temp_allocator), ""
}

// acp_connection_open starts the agent program with its three standard streams piped here.
@(private)
acp_connection_open :: proc(connection: ^Acp_Connection) -> (problem: string) {
	member := connection.member
	input, input_ok := acp_input_open()
	if !input_ok { return "the agent's input could not be created; nothing ran" }
	connection.input = input
	output_read, output_write, output_error := os.pipe()
	if output_error != nil { return "the agent's output pipe could not be created; nothing ran" }
	defer _ = os.close(output_write)
	connection.output = output_read
	errors_read, errors_write, errors_error := os.pipe()
	if errors_error != nil { return "the agent's error pipe could not be created; nothing ran" }
	defer _ = os.close(errors_write)
	connection.errors = errors_read

	argv := make([]string, len(member.program.arguments) + 1, context.temp_allocator)
	argv[0] = member.program.command
	copy(argv[1:], member.program.arguments)
	child, spawn, spawn_error := tool_spawn_command(argv, member.workspace, connection.input.theirs, output_write, errors_write, parent_death = true)
	switch spawn {
	case .Started:
	case .Exec_Failed:
		return fmt.tprintf("%s could not be executed: %v; nothing ran", member.program.command, spawn_error)
	case .Failed:
		return fmt.tprintf("%s could not be started: %v; nothing ran", member.program.command, spawn_error)
	}
	connection.child = child
	connection.started = true
	_ = os.close(connection.input.theirs)
	connection.input.theirs = nil

	writer, writer_error := acp.writer_init(acp_input_writer(&connection.input), member.allocator)
	decoder, decoder_error := acp.frame_decoder_init(allocator = member.allocator)
	connection.writer = writer
	connection.decoder = decoder
	if writer_error != nil || decoder_error != nil { return "the agent's connection could not be allocated" }
	return ""
}

// acp_connection_close ends the agent: end of input first, then the process group, then what
// the connection holds. The agent keeps its own session; nothing here waits for it to save.
@(private)
acp_connection_close :: proc(connection: ^Acp_Connection) {
	acp_input_close(&connection.input)
	if connection.started {
		tool_terminate_group(&connection.child)
		tool_child_close(&connection.child)
	}
	if connection.output != nil { _ = os.close(connection.output) }
	if connection.errors != nil { _ = os.close(connection.errors) }
	acp.writer_destroy(&connection.writer)
	for frame in connection.frames { delete(frame, connection.member.allocator) }
	delete(connection.frames)
	acp.frame_decoder_destroy(&connection.decoder)
	delete(connection.session_id, connection.member.allocator)
	delete(connection.message_id, connection.member.allocator)
	delete(connection.stop_reason, connection.member.allocator)
	delete(connection.answer)
	delete(connection.stderr_tail)
	connection^ = {}
}

// acp_session_open agrees on the protocol, preferring version 2, opens a session in the workspace,
// and chooses the model and effort among what the agent offers.
@(private)
acp_session_open :: proc(connection: ^Acp_Connection) -> (problem: string) {
	member := connection.member
	// Version 2 names the client in info; a version 1 agent answers with its own version and
	// reads the missing clientCapabilities as no file system and no terminal.
	Initialize :: struct {
		protocol_version: int `json:"protocolVersion"`,
		capabilities:     struct{} `json:"capabilities"`,
		info:             acp.Implementation `json:"info"`,
	}
	Initialized :: struct {
		protocol_version: int `json:"protocolVersion"`,
		info:             acp.Implementation `json:"info"`,
	}
	initialized: Initialized
	request := Initialize {
		protocol_version = acp.PROTOCOL_VERSION_V2,
		info = {name = "nabla", version = "0"},
	}
	if problem = acp_call(connection, acp.METHOD_INITIALIZE, request, &initialized); problem != "" { return }
	if initialized.protocol_version != acp.PROTOCOL_VERSION && initialized.protocol_version != acp.PROTOCOL_VERSION_V2 {
		return fmt.tprintf("the agent speaks ACP version %d, and this client speaks versions 1 and 2", initialized.protocol_version)
	}
	connection.version = initialized.protocol_version
	// Some agents echo version 2 while answering in version 1's shape, without the info
	// version 2 requires; they speak version 1.
	if initialized.info.name == "" { connection.version = acp.PROTOCOL_VERSION }

	New_Session :: struct {
		cwd:         string `json:"cwd"`,
		mcp_servers: []acp.Mcp_Server `json:"mcpServers"`,
	}
	opened: Acp_Session_Opened
	if problem = acp_call(connection, acp.METHOD_SESSION_NEW, New_Session{cwd = member.workspace}, &opened); problem != "" { return }
	if opened.session_id == "" { return "the agent opened a session without an id" }
	connection.session_id = strings.clone(opened.session_id, member.allocator)

	model := member.program.model
	if model != "" {
		if option, found := acp_option(opened.config_options, ACP_OPTION_CATEGORY_MODEL); found && acp_option_value(option, model) != "" {
			if problem = acp_set_option(connection, option, acp_option_value(option, model)); problem != "" { return }
		} else if acp_model_offered(opened.models, model) {
			Set_Model :: struct {
				session_id: string `json:"sessionId"`,
				model_id:   string `json:"modelId"`,
			}
			set: acp.Session_Set_Model_Result
			if problem = acp_call(connection, acp.METHOD_SESSION_SET_MODEL, Set_Model{session_id = connection.session_id, model_id = model}, &set);
			   problem != "" { return }
		} else {
			return fmt.tprintf("the agent offers no model %q; it offers: %s", model, acp_models_text(opened))
		}
	}
	// An effort the agent does not offer is treated as one left out, as for a native subagent.
	// When the agent shares no level with the orchestrator, its own default stays, since its
	// lowest level may turn reasoning off.
	if option, found := acp_option(opened.config_options, ACP_OPTION_CATEGORY_EFFORT); found {
		levels := make([]string, len(option.options), context.temp_allocator)
		for choice, index in option.options { levels[index] = choice.value }
		effort := acp_option_value(option, member.effort)
		if effort == "" { effort = effort_step_down(member.program.parent_levels, levels, member.program.parent_effort) }
		if effort != "" && effort != option.current_value {
			if problem = acp_set_option(connection, option, effort); problem != "" { return }
		}
	}
	return ""
}

// Acp_Config_Option is a session config option of either version: version 1 names it by id and
// version 2 by configId.
@(private)
Acp_Config_Option :: struct {
	id:            string `json:"id"`,
	config_id:     string `json:"configId"`,
	category:      string `json:"category"`,
	current_value: string `json:"currentValue"`,
	options:       []acp.Config_Value `json:"options"`,
}

// Acp_Session_Opened is what session/new answers in either version. models is the
// pre-standard model list some version 1 agents send.
@(private)
Acp_Session_Opened :: struct {
	session_id:     string `json:"sessionId"`,
	config_options: []Acp_Config_Option `json:"configOptions"`,
	models:         acp.Models_State `json:"models"`,
}

@(private)
acp_set_option :: proc(connection: ^Acp_Connection, option: Acp_Config_Option, value: string) -> (problem: string) {
	// Version 2 requires the value's type; version 1 reads a missing type as an id.
	Set_Option :: struct {
		session_id: string `json:"sessionId"`,
		config_id:  string `json:"configId"`,
		type:       string `json:"type,omitempty"`,
		value:      string `json:"value"`,
	}
	request := Set_Option {
		session_id = connection.session_id,
		config_id  = option.config_id if option.config_id != "" else option.id,
		type       = "id" if connection.version == 2 else "",
		value      = value,
	}
	set: struct{}
	return acp_call(connection, acp.METHOD_SESSION_SET_CONFIG_OPTION, request, &set)
}

@(private)
acp_option :: proc(options: []Acp_Config_Option, category: string) -> (Acp_Config_Option, bool) {
	for option in options {
		if option.category == category { return option, true }
	}
	return {}, false
}

// acp_option_value is the value of the choice named wanted, by value or display name, or "".
@(private)
acp_option_value :: proc(option: Acp_Config_Option, wanted: string) -> string {
	if wanted == "" { return "" }
	for choice in option.options {
		if choice.value == wanted || choice.name == wanted { return choice.value }
	}
	return ""
}

@(private)
acp_model_offered :: proc(models: acp.Models_State, model: string) -> bool {
	for offered in models.available_models {
		if offered.model_id == model { return true }
	}
	return false
}

// acp_models_text lists the models a session offers, temp-allocated.
@(private)
acp_models_text :: proc(opened: Acp_Session_Opened) -> string {
	names := make([dynamic]string, context.temp_allocator)
	if option, found := acp_option(opened.config_options, ACP_OPTION_CATEGORY_MODEL); found {
		for choice in option.options { append(&names, choice.value) }
	}
	for offered in opened.models.available_models { append(&names, offered.model_id) }
	if len(names) == 0 { return "no choice of model" }
	return strings.join(names[:], ", ", context.temp_allocator)
}

// acp_call sends one request and reads until its answer, which it decodes into result with
// the temp allocator. problem, temp-allocated, says why there is no answer.
@(private)
acp_call :: proc(connection: ^Acp_Connection, method: string, params: $P, result: ^$R) -> (problem: string) {
	id := connection.next_id
	connection.next_id += 1
	if !acp.writer_write_request(&connection.writer, id, method, params) { return acp_ended(connection, "stopped reading its input") }
	for {
		envelope, next_problem := acp_next(connection)
		if next_problem != "" { return next_problem }
		defer acp.destroy_envelope(&envelope, connection.member.allocator)
		switch envelope.kind {
		case .Response:
			answered, is_number := envelope.id.(i64)
			if !is_number || answered != id { continue }
			if envelope.error_present {
				return fmt.tprintf("the agent refused %s: %s", method, envelope.rpc_error.message)
			}
			if _, is_null := envelope.result.(json.Null); is_null { return "" }
			if !acp.params_decode(envelope.result, result, context.temp_allocator) {
				return fmt.tprintf("the agent's answer to %s is not what ACP defines", method)
			}
			return ""
		case .Notification, .Request, .Invalid:
			acp_handle(connection, envelope)
		}
	}
}

// acp_handle acts on a message that answers nothing this client asked.
@(private)
acp_handle :: proc(connection: ^Acp_Connection, envelope: acp.Envelope) {
	// What a message is decoded into is released with it, so a long turn holds no scratch.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	#partial switch envelope.kind {
	case .Notification:
		acp_notification(connection, envelope)
	case .Request:
		acp_answer(connection, envelope)
	}
}

// acp_notification follows the agent's latest message and, in version 2, the end of its turn.
// Text before a tool call is narration, so a tool call starts the answer over, and so does a
// message with a new id.
@(private)
acp_notification :: proc(connection: ^Acp_Connection, envelope: acp.Envelope) {
	if envelope.method != acp.NOTIFICATION_SESSION_UPDATE { return }
	kind: acp.Session_Notification(acp.Update_Kind)
	if !acp.params_decode(envelope.params, &kind, context.temp_allocator) { return }
	switch kind.update.session_update {
	case acp.UPDATE_TOOL_CALL, acp.UPDATE_TOOL_CALL_UPDATE:
		clear(&connection.answer)
		acp_replace(&connection.message_id, "", connection.member.allocator)
	case acp.UPDATE_AGENT_MESSAGE_CHUNK:
		chunk: acp.Session_Notification(acp.Message_Chunk)
		if !acp.params_decode(envelope.params, &chunk, context.temp_allocator) { return }
		acp_message_begin(connection, chunk.update.message_id)
		if chunk.update.content.type == acp.CONTENT_TEXT { append(&connection.answer, chunk.update.content.text) }
	case acp.UPDATE_AGENT_MESSAGE:
		message: acp.Session_Notification(acp.Message_Update)
		if !acp.params_decode(envelope.params, &message, context.temp_allocator) { return }
		acp_message_begin(connection, message.update.message_id)
		// The update is an upsert: content left out keeps the message as it is.
		if !acp_update_has(envelope.params, "content") { return }
		clear(&connection.answer)
		for block in message.update.content {
			if block.type == acp.CONTENT_TEXT { append(&connection.answer, block.text) }
		}
	case acp.UPDATE_STATE:
		state: acp.Session_Notification(acp.State_Update)
		if !acp.params_decode(envelope.params, &state, context.temp_allocator) || state.update.state != "idle" { return }
		connection.idle = true
		acp_replace(&connection.stop_reason, state.update.stop_reason, connection.member.allocator)
	}
}

// acp_update_has reports whether a session/update's update object carries key.
@(private)
acp_update_has :: proc(params: json.Value, key: string) -> bool {
	notification, is_object := params.(json.Object)
	if !is_object { return false }
	update, update_is_object := notification["update"].(json.Object)
	if !update_is_object { return false }
	_, present := update[key]
	return present
}

// acp_message_begin starts the answer over when the agent begins a message with a new id.
@(private)
acp_message_begin :: proc(connection: ^Acp_Connection, message_id: string) {
	if message_id == "" || message_id == connection.message_id { return }
	clear(&connection.answer)
	acp_replace(&connection.message_id, message_id, connection.member.allocator)
}

// acp_replace sets an owned string to a copy of value.
@(private)
acp_replace :: proc(owned: ^string, value: string, allocator: mem.Allocator) {
	delete(owned^, allocator)
	owned^ = strings.clone(value, allocator) if value != "" else ""
}

// acp_answer answers a request the agent sent. A permission request is granted once, as a
// native subagent's tools run without asking; nothing else is offered.
@(private)
acp_answer :: proc(connection: ^Acp_Connection, envelope: acp.Envelope) {
	if envelope.method != acp.METHOD_SESSION_REQUEST_PERMISSION {
		_ = acp.writer_write_error(&connection.writer, envelope.id, acp.ERROR_METHOD_NOT_FOUND, "this client offers no such method")
		return
	}
	request: acp.Request_Permission_Params
	if !acp.params_decode(envelope.params, &request, context.temp_allocator) {
		_ = acp.writer_write_error(&connection.writer, envelope.id, acp.ERROR_INVALID_PARAMS, "the permission request is not what ACP defines")
		return
	}
	outcome := acp.Permission_Outcome {
		outcome = "cancelled",
	}
	if acp_stopped(connection) {
		_ = acp.writer_write_response(&connection.writer, envelope.id, acp.Request_Permission_Result{outcome = outcome})
		return
	}
	for kind in ([]string{"allow_once", "allow_always"}) {
		for option in request.options {
			if option.kind == kind && outcome.option_id == "" {outcome = {
					outcome   = "selected",
					option_id = option.option_id,
				}}
		}
	}
	_ = acp.writer_write_response(&connection.writer, envelope.id, acp.Request_Permission_Result{outcome = outcome})
}

// acp_next returns the next message the agent sent, owned by the member's allocator, reading
// and waiting as needed. A stop
// sends the agent session/cancel and waits the stop patience for its answer; problem says
// the agent ended, went silent past that, or could not be read.
@(private)
acp_next :: proc(connection: ^Acp_Connection) -> (envelope: acp.Envelope, problem: string) {
	for {
		for connection.next_frame < len(connection.frames) {
			frame := connection.frames[connection.next_frame]
			connection.next_frame += 1
			parsed, parse_error := acp.parse_envelope(frame, connection.member.allocator)
			if parse_error == .None { return parsed, "" }
		}
		for frame in connection.frames { delete(frame, connection.member.allocator) }
		clear(&connection.frames)
		connection.next_frame = 0
		if wait_problem := acp_wait(connection); wait_problem != "" { return {}, wait_problem }
	}
}

// acp_wait blocks until the agent wrote something or a stop arrived, and reads what came.
@(private)
acp_wait :: proc(connection: ^Acp_Connection) -> (problem: string) {
	member := connection.member
	if ai.interrupt_requested(&member.stop) && !connection.cancel_sent {
		connection.cancel_sent = true
		connection.stop_deadline = time.tick_add(time.tick_now(), TOOL_JOBS_STOP_PATIENCE)
		if connection.session_id == "" { return "the subagent was stopped before its session opened" }
		_ = acp.writer_write_notification(&connection.writer, acp.SESSION_CANCEL, acp.Session_Cancel_Params{session_id = connection.session_id})
	}
	// The agent's exit is watched beside its output, because a descendant that inherited
	// stdout can keep it open after the agent itself is gone.
	fds: [5]posix.pollfd
	fds[0] = {
		fd     = tool_fd(connection.output),
		events = {.IN},
	}
	fds[1] = {
		fd     = tool_exit_watch_fd(connection.child.exit),
		events = {.IN},
	}
	count := 2
	errors_index := -1
	if connection.errors != nil {
		errors_index = count
		fds[count] = {
			fd     = tool_fd(connection.errors),
			events = {.IN},
		}
		count += 1
	}
	if !connection.cancel_sent {
		fds[count] = {
			fd     = tool_fd(member.wake.read),
			events = {.IN},
		}
		count += 1
		if member.parent_wake != nil {
			fds[count] = {
				fd     = tool_fd(member.parent_wake),
				events = {.IN},
			}
			count += 1
		}
	}
	if poll_error := tool_poll(fds[:count], connection.stop_deadline, connection.cancel_sent); poll_error != nil {
		return fmt.tprintf("the agent could not be waited on: %v", poll_error)
	}
	if connection.cancel_sent && time.tick_diff(time.tick_now(), connection.stop_deadline) <= 0 {
		return "the agent did not stop in time and was ended"
	}
	buffer: [SUBAGENT_ACP_READ_BYTES]u8
	if errors_index >= 0 && fds[errors_index].revents != {} {
		taken, status := tool_read(connection.errors, buffer[:])
		if status == .Failed || (status == .Ok && taken == 0) {
			_ = os.close(connection.errors)
			connection.errors = nil
		} else if status == .Ok {
			append(&connection.stderr_tail, ..buffer[:taken])
			if extra := len(connection.stderr_tail) - SUBAGENT_ACP_STDERR_BYTES; extra > 0 { remove_range(&connection.stderr_tail, 0, extra) }
		}
	}
	// What the agent wrote before it exited is read first; its exit counts once nothing is
	// waiting, whoever still holds its pipes.
	if fds[0].revents == {} {
		stderr_waiting := errors_index >= 0 && fds[errors_index].revents != {}
		if fds[1].revents != {} && !stderr_waiting { return acp_ended(connection, "exited") }
		return ""
	}
	read, status := tool_read(connection.output, buffer[:])
	switch status {
	case .Again:
		return ""
	case .Failed:
		return acp_ended(connection, "could not be read")
	case .Ok:
	}
	if read == 0 { return acp_ended(connection, "exited") }
	if frame_error := acp.frame_decoder_feed(&connection.decoder, buffer[:read], &connection.frames); frame_error == .Frame_Too_Large {
		return fmt.tprintf("the agent sent a message larger than %d bytes", acp.MAX_FRAME_BYTES)
	}
	return ""
}

// acp_ended says the agent went away, with the end of what it wrote to stderr.
@(private)
acp_ended :: proc(connection: ^Acp_Connection, what: string) -> string {
	tail := strings.trim_space(string(connection.stderr_tail[:]))
	if tail == "" { return fmt.tprintf("the agent %s before it answered", what) }
	return fmt.tprintf("the agent %s before it answered. The end of its stderr:\n%s", what, tail)
}

@(private)
acp_stopped :: proc(connection: ^Acp_Connection) -> bool {
	return connection.cancel_sent || ai.interrupt_requested(&connection.member.stop)
}
