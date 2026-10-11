package agent

import "base:runtime"
import "core:container/queue"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "nabla:acp"
import "nabla:agent/journal"
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

// SUBAGENT_ACP_STDERR_TAIL_BYTES is how much of an agent's standard error the
// connection keeps. It sizes the memory for a diagnostic stream: an ACP agent can live
// for a whole session and write without end, so only its most recent bytes are held. It
// caps nothing the agent exchanges.
SUBAGENT_ACP_STDERR_TAIL_BYTES :: 32 * 1024

SUBAGENT_ACP_READ_BYTES :: 16 * 1024

// SUBAGENT_ACP_CLOSE_GRACE gives EOF and exited readers time to finish before abandonment.
SUBAGENT_ACP_CLOSE_GRACE :: 500 * time.Millisecond

// ACP_OPTION_CATEGORY_MODEL and ACP_OPTION_CATEGORY_EFFORT are the session config option
// categories that choose a model and its reasoning effort.
ACP_OPTION_CATEGORY_MODEL :: "model"
ACP_OPTION_CATEGORY_EFFORT :: "thought_level"

// ACP_Configure owns a pending model, effort, and compact request under the team mutex.
ACP_Configure :: struct {
	call:      journal.Call_Id,
	model:     string,
	effort:    string,
	switching: bool,
	compact:   bool,
	allocator: mem.Allocator,
}

acp_configure_destroy :: proc(configuration: ^ACP_Configure) {
	delete(configuration.model, configuration.allocator)
	delete(configuration.effort, configuration.allocator)
	configuration^ = {}
}

// acp_model_named reports whether name is "provider_id/id", without building it.
@(private, require_results)
acp_model_named :: proc(provider_id, id, name: string) -> bool {
	return(
		len(name) == len(provider_id) + 1 + len(id) &&
		strings.has_prefix(name, provider_id) &&
		name[len(provider_id)] == '/' &&
		strings.has_suffix(name, id) \
	)
}

// acp_native_model resolves catalog identity and effort, not a provider connection.
// The returned strings are temporary-allocated.
@(private, require_results)
acp_native_model :: proc(
	provider, model, effort: string,
	parent: ^Agent_Parent,
	resume: Subagent_Resume,
	current_value := "",
) -> (
	value, resolved_effort, problem: string,
) {
	provider, model := provider, model
	default_provider := parent.provider_id
	default_model := parent.model_id
	parent_effort := parent.effort
	if resume.provider_id != "" { default_provider = resume.provider_id }
	if resume.model_id != "" { default_model = resume.model_id }
	if resume.effort != "" { parent_effort = resume.effort }
	if parent.catalog.catalog == nil { return "", "", "the model catalog is not available" }
	if parent.catalog.mutex != nil { sync.mutex_lock(parent.catalog.mutex) }
	defer if parent.catalog.mutex != nil { sync.mutex_unlock(parent.catalog.mutex) }
	catalog := parent.catalog.catalog
	if current_value != "" {
		found := false
		for candidate in catalog.models {
			if !acp_model_named(candidate.provider_id, candidate.id, current_value) { continue }
			default_provider, default_model = candidate.provider_id, candidate.id
			found = true
			break
		}
		if !found { return "", "", fmt.tprintf("the current native model %q is no longer in the catalog", current_value) }
	}
	if provider == "" && model != "" {
		for candidate in catalog.models {
			if acp_model_named(candidate.provider_id, candidate.id, model) {
				provider, model = candidate.provider_id, candidate.id
				break
			}
		}
	}
	switch {
	case provider == "" && model == "":
		provider, model = default_provider, default_model
	case model == "":
		if provider != default_provider { return "", "", fmt.tprintf("name a model of provider %s: %s", provider, catalog_model_names(catalog, provider)) }
		model = default_model
	case provider == "":
		provider, problem = catalog_model_provider(catalog, model, default_provider)
		if problem != "" { return "", "", problem }
	}
	provider_index, provider_found := catalog_find_provider(catalog, provider)
	if !provider_found { return "", "", fmt.tprintf("provider not found: %s; configured providers: %s", provider, catalog_provider_names(catalog)) }
	if !provider_usable(&catalog.providers[provider_index]) { return "", "", fmt.tprintf("provider %s needs base_url, api, and api_key", provider) }
	selected, found := catalog_model(catalog, provider, model)
	if !found { return "", "", fmt.tprintf("model not found for provider: %s %s", provider, model) }
	levels := selected.thinking.levels.? or_else nil
	for level in levels { if level == effort { resolved_effort = effort; break } }
	if effort == "" {
		if resume.name != "" { resolved_effort = parent_effort } else { resolved_effort = effort_step_down(parent.effort_levels, levels, parent_effort) }
	}
	value_error: mem.Allocator_Error
	value, value_error = strings.concatenate({provider, "/", model}, context.temp_allocator)
	if value_error != nil { return "", "", "the model identity could not be held" }
	resolved_effort, value_error = strings.clone(resolved_effort, context.temp_allocator)
	if value_error != nil { return "", "", "the model effort could not be held" }
	return value, resolved_effort, ""
}

@(private, require_results)
acp_program :: proc(
	args: Agent_Start_Args,
	parent: ^Agent_Parent,
	resume: Subagent_Resume,
	allocator: mem.Allocator,
) -> (
	program: Subagent_Program,
	effort, problem: string,
) {
	if args.acp_agent != "" {
		arguments := args
		if args.provider != "" && args.model != "" { arguments.model = fmt.tprintf("%s/%s", args.provider, args.model) }
		program, problem = subagent_program(arguments, parent, allocator)
		return program, args.effort, problem
	}
	if parent.nabla_executable == "" { return {}, "", "the Nabla executable path is not available" }
	model: string
	model, effort, problem = acp_native_model(args.provider, args.model, args.effort, parent, resume)
	if problem != "" { return {}, "", problem }
	arguments: []string = {"acp"}
	if parent.nabla_config != "" { arguments = {"acp", "--config", parent.nabla_config} }
	clone_error: mem.Allocator_Error
	program, clone_error = subagent_program_clone({arguments = arguments}, parent.nabla_executable, model, parent, allocator)
	if clone_error != nil { return {}, "", "the native subagent's program could not be held" }
	return program, effort, ""
}

// acp_inbox reads only this parent's messages to this child. The child consumes these through
// ACP prompts, never through its own journal inbox. The result belongs to allocator.
@(private, require_results)
acp_inbox :: proc(
	store: ^journal.Journal,
	member: ^Subagent,
	after: journal.Journal_Seq,
	allocator: mem.Allocator,
) -> (
	records: []journal.Record,
	error: journal.Error,
) {
	records, _, error = journal.read_records(
		store,
		{session = member.parent_session, subagent = member.session, kinds = {.Subagent_Message}},
		after,
		0,
		allocator,
	)
	return
}

// acp_inbox_text joins the parent's messages to this child after the last one it consumed into
// one prompt. after is the sequence of the latest message, and 0 with text "" when there is
// none. text belongs to allocator.
@(private, require_results)
acp_inbox_text :: proc(store: ^journal.Journal, member: ^Subagent, allocator: mem.Allocator) -> (text: string, after: journal.Journal_Seq, problem: string) {
	records, read_error := acp_inbox(store, member, member.acp_after, context.temp_allocator)
	if read_error != nil { return "", 0, "the subagent's inbox could not be read" }
	if len(records) == 0 { return "", 0, "" }
	lines, lines_error := make([]string, len(records), context.temp_allocator)
	if lines_error != nil { return "", 0, "the orchestrator's message could not be held" }
	for record, index in records { lines[index], _ = inbox_text(record) }
	joined, join_error := strings.join(lines, "\n\n", allocator)
	if join_error != nil { return "", 0, "the orchestrator's message could not be held" }
	return joined, records[len(records) - 1].seq, ""
}

@(private)
acp_inbox_consumed :: proc(member: ^Subagent, after: journal.Journal_Seq) {
	sync.mutex_guard(&member.team.mutex)
	member.acp_after = after
}

@(private, require_results)
acp_configure_plan :: proc(team: ^Agent_Team, update: ^Agent_Message_Args) -> (session: journal.Session_Id, live: bool, problem: string) {
	parent: Agent_Parent
	current_model, current_effort: string
	native: bool
	member_allocator: mem.Allocator
	{
		sync.mutex_guard(&team.mutex)
		member := subagent_find(team, update.agent)
		if member == nil { return {}, false, "" }
		session, live = member.session, true
		member_allocator = member.allocator
		native = subagent_native(member)
		copy_error: mem.Allocator_Error
		parent, copy_error = agent_parent_temp_copy(team.parent, context.temp_allocator)
		if copy_error != nil { return session, true, "the orchestrator's selection could not be copied" }
		model, effort := member.program.model, member.effort
		if member.configuration.switching {
			if member.configuration.model != "" { model = member.configuration.model }
			if member.configuration.effort != "" { effort = member.configuration.effort }
		}
		current_model, copy_error = strings.clone(model, context.temp_allocator)
		if copy_error != nil { return session, true, "the orchestrator's selection could not be copied" }
		current_effort, copy_error = strings.clone(effort, context.temp_allocator)
		if copy_error != nil { return session, true, "the orchestrator's selection could not be copied" }
	}
	if update.model == "" && update.provider == "" && update.effort == "" && !update.compact { return session, true, "" }
	configuration := ACP_Configure {
		compact   = update.compact,
		allocator = member_allocator,
	}
	failed := true
	defer if failed { acp_configure_destroy(&configuration) }
	if update.model != "" || update.provider != "" || update.effort != "" {
		model, effort := update.model, update.effort
		if native {
			resolved_model: string
			resolved_model, _, problem = acp_native_model(
				update.provider,
				update.model,
				"",
				&parent,
				{name = update.agent, effort = current_effort},
				current_model,
			)
			if problem != "" { return session, true, problem }
			if update.provider != "" || update.model != "" { model = resolved_model }
		} else if update.provider != "" && model != "" { model = fmt.tprintf("%s/%s", update.provider, model) }
		configuration.model = strings.clone(model, member_allocator) or_else ""
		configuration.effort = strings.clone(effort, member_allocator) or_else ""
		if (model != "" && configuration.model == "") ||
		   (effort != "" && configuration.effort == "") { return session, true, "the pending configuration could not be held" }
		configuration.switching = true
	}
	update.control = configuration
	failed = false
	return session, true, ""
}

acp_configure_queue :: proc(team: ^Agent_Team, name: string, configuration: ^ACP_Configure) {
	sync.mutex_guard(&team.mutex)
	member := subagent_find(team, name)
	if member == nil { acp_configure_destroy(configuration); return }
	compact := member.configuration.compact || configuration.compact
	if configuration.switching {
		if configuration.model == "" { configuration.model, member.configuration.model = member.configuration.model, "" }
		if configuration.effort == "" { configuration.effort, member.configuration.effort = member.configuration.effort, "" }
		acp_configure_destroy(&member.configuration)
		member.configuration = configuration^
		configuration^ = {}
	}
	member.configuration.compact = compact
	if configuration.call != 0 { member.configuration.call = configuration.call }
	configuration^ = {}
	sync.sema_post(&member.wake)
}

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
@(private, require_results)
subagent_program :: proc(args: Agent_Start_Args, parent: ^Agent_Parent, allocator: mem.Allocator) -> (program: Subagent_Program, problem: string) {
	config: ACP_Agent_Config
	for candidate in parent.acp_agents {
		if candidate.name == args.acp_agent { config = candidate }
	}
	if config.name == "" {
		configured := "none"
		names, names_error := make([dynamic]string, 0, len(parent.acp_agents), context.temp_allocator)
		if names_error == nil {
			for candidate in parent.acp_agents { append(&names, candidate.name) }
			if len(names) > 0 {
				if joined, join_error := strings.join(names[:], ", ", context.temp_allocator); join_error == nil { configured = joined }
			}
		}
		return {}, fmt.tprintf("no ACP agent named %q is configured; configured: %s", args.acp_agent, configured)
	}
	path, found := subagent_command_path(config.command, parent.workspace)
	if !found { return {}, fmt.tprintf("ACP agent %s: command %q is neither an executable file nor a program on PATH; nothing started", config.name, config.command) }
	built, clone_error := subagent_program_clone(config, path, args.model, parent, allocator)
	if clone_error != nil { return {}, "the ACP agent's program could not be held" }
	return built, ""
}

@(private, require_results)
subagent_program_clone :: proc(
	config: ACP_Agent_Config,
	path, model: string,
	parent: ^Agent_Parent,
	allocator: mem.Allocator,
) -> (
	result_value: Subagent_Program,
	error: mem.Allocator_Error,
) {
	built: Subagent_Program
	complete := false
	defer if !complete { subagent_program_destroy(&built, allocator) }
	built.name = strings.clone(config.name, allocator) or_return
	built.command = strings.clone(path, allocator) or_return
	built.arguments = make([]string, len(config.arguments), allocator) or_return
	for argument, index in config.arguments {
		built.arguments[index] = strings.clone(argument, allocator) or_return
	}
	built.model = strings.clone(model, allocator) or_return
	built.parent_effort = strings.clone(parent.effort, allocator) or_return
	built.parent_levels = make([]string, len(parent.effort_levels), allocator) or_return
	for level, index in parent.effort_levels {
		built.parent_levels[index] = strings.clone(level, allocator) or_return
	}
	complete = true
	return built, nil
}

// subagent_command_path finds the executable command names, temp-allocated: a path relative to
// directory when it has a slash, else the first match on PATH. found is false when the path
// could not be built or no candidate is executable.
@(private, require_results)
subagent_command_path :: proc(command, directory: string) -> (string, bool) {
	if strings.contains_rune(command, '/') {
		path := command
		if !strings.has_prefix(command, "/") {
			joined, join_error := strings.concatenate({directory, "/", command}, context.temp_allocator)
			if join_error != nil { return "", false }
			path = joined
		}
		return path, subagent_executable(path)
	}
	search := os.get_env("PATH", context.temp_allocator)
	for entry in strings.split_iterator(&search, ":") {
		if entry == "" { continue }
		path, join_error := strings.concatenate({entry, "/", command}, context.temp_allocator)
		if join_error != nil { return "", false }
		if subagent_executable(path) { return path, true }
	}
	return "", false
}

@(private, require_results)
subagent_executable :: proc(path: string) -> bool {
	return os.exists(path) && !os.is_dir(path)
}

@(private)
ACP_Worker :: enum {
	Output,
	Errors,
	Process,
}

// ACP_Readers owns the three blocking workers and their shared observations. The connection
// releases it after all workers finish, or leaks it after detaching its borrowed wake.
@(private)
ACP_Readers :: struct {
	allocator:   mem.Allocator,
	mutex:       sync.Mutex,
	wake:        ^sync.Sema,
	completion:  sync.Sema,
	output:      ^os.File,
	errors:      ^os.File,
	process:     os.Process,
	threads:     [ACP_Worker]^thread.Thread,
	done:        [ACP_Worker]bool,
	decoder:     acp.Frame_Decoder,
	frames:      queue.Queue(string),
	frame_error: acp.Frame_Error,
	read_error:  os.Error,
	wait_error:  os.Error,
	state:       os.Process_State,
	stderr_tail: [dynamic]u8,
}

// acp_readers_signal posts observations while the caller holds readers.mutex, so wake
// cannot be detached between the check and the post.
@(private)
acp_readers_signal :: proc(readers: ^ACP_Readers) {
	if readers.wake != nil { sync.sema_post(readers.wake) }
	sync.sema_post(&readers.completion)
}

@(private)
acp_output_read :: proc(worker: ^thread.Thread) {
	readers := cast(^ACP_Readers)worker.data
	context.allocator = readers.allocator
	defer {
		_ = os.close(readers.output)
		sync.mutex_guard(&readers.mutex)
		readers.done[.Output] = true
		acp_readers_signal(readers)
	}
	buffer: [SUBAGENT_ACP_READ_BYTES]u8
	for {
		taken, err := os.read(readers.output, buffer[:])
		if err != nil || taken == 0 {
			sync.mutex_guard(&readers.mutex)
			if err != io.Error.EOF { readers.read_error = err }
			return
		}
		frames: [dynamic]string
		frames.allocator = readers.allocator
		frame_error := acp.frame_decoder_feed(&readers.decoder, buffer[:taken], &frames)
		{
			sync.mutex_guard(&readers.mutex)
			if _, push_error := queue.push_back_elems(&readers.frames, ..frames[:]); push_error != nil {
				for frame in frames { delete(frame, readers.allocator) }
				frame_error = .Allocation
			}
			if frame_error != .None && frame_error != .Empty_Frame { readers.frame_error = frame_error }
			acp_readers_signal(readers)
		}
		delete(frames)
		if frame_error != .None && frame_error != .Empty_Frame { return }
	}
}

@(private)
acp_errors_read :: proc(worker: ^thread.Thread) {
	readers := cast(^ACP_Readers)worker.data
	context.allocator = readers.allocator
	defer {
		_ = os.close(readers.errors)
		sync.mutex_guard(&readers.mutex)
		readers.done[.Errors] = true
		acp_readers_signal(readers)
	}
	buffer: [SUBAGENT_ACP_READ_BYTES]u8
	for {
		taken, err := os.read(readers.errors, buffer[:])
		if err != nil || taken == 0 { return }
		{
			sync.mutex_guard(&readers.mutex)
			acp_stderr_retain(&readers.stderr_tail, buffer[:taken])
		}
	}
}

@(private)
acp_process_wait :: proc(worker: ^thread.Thread) {
	readers := cast(^ACP_Readers)worker.data
	context.allocator = readers.allocator
	state, err := os.process_wait(readers.process)
	{
		sync.mutex_guard(&readers.mutex)
		readers.state = state
		readers.wait_error = err
		readers.done[.Process] = true
		acp_readers_signal(readers)
	}
}

// ACP_Connection is one running agent program and the client state of its session.
@(private)
ACP_Connection :: struct {
	inbox:          ^journal.Journal,
	live_prompt:    bool,
	pending:        [dynamic]ACP_Outstanding,
	config_options: []ACP_Config_Option,
	member:         ^Subagent,
	child:          os.Process,
	started:        bool,
	input:          ^os.File, // the agent's stdin; ours to write, closed once the writer has retired
	readers:        ^ACP_Readers,
	writer:         acp.Writer,
	next_id:        i64,
	version:        int, // the ACP version the agent agreed to
	session_id:     string,
	opened:         ACP_Session_Opened, // borrowed from the thread's scratch memory
	replaying:      bool,
	answer:         [dynamic]u8, // the text of the agent's latest message since its last tool call
	message_id:     string, // the latest message's id, owned; "" when the agent sends none
	idle:           bool, // version 2: the agent reported its turn over
	stop_reason:    string,
	turn_error:     string, // why the turn ended, owned
	cancel_sent:    bool,
	stop_deadline:  time.Tick,
}

// subagent_native reports whether the member is a Nabla child rather than a configured ACP agent.
@(private, require_results)
subagent_native :: proc(member: ^Subagent) -> bool {
	return member.program.name == ""
}

// subagent_acp_run runs the member's ACP agent until it answers the task and every message the
// orchestrator sent after that, and records the outcome in member.
@(private)
subagent_acp_run :: proc(member: ^Subagent) {
	allocator := member.allocator
	connection := ACP_Connection {
		member = member,
	}
	defer acp_connection_close(&connection, TOOL_JOBS_STOP_PATIENCE)
	answer_buffer, answer_error := make([dynamic]u8, allocator)
	if answer_error != nil {
		subagent_fail(member, .Failed, "the agent's connection could not be held")
		return
	}
	connection.pending.allocator = allocator
	connection.answer = answer_buffer
	defer if member.status != .Completed && len(connection.answer) > 0 {
		delete(member.answer, allocator)
		member.answer = strings.clone(string(connection.answer[:]), allocator) or_else ""
	}
	if !acp_run_start(&connection) { return }
	if !acp_run_prompts(&connection) { return }
	// An answer that cannot be held is not the answer the orchestrator asked for, so the
	// outcome says the delegation failed rather than reporting none as a completion.
	answer_text, clone_error := strings.clone(string(connection.answer[:]), allocator)
	if clone_error != nil {
		subagent_fail(member, .Failed, "the agent's answer could not be held")
		return
	}
	delete(member.answer, allocator)
	member.answer = answer_text
}

// acp_run_start creates a native child's session, starts the agent, opens or resumes its
// session, and applies the configuration chosen before it started. It records the failure in
// the member and returns false when the run cannot go on.
@(private, require_results)
acp_run_start :: proc(connection: ^ACP_Connection) -> (started: bool) {
	member := connection.member
	allocator := member.allocator
	previous_session := member.acp_session
	hex: [journal.SESSION_ID_HEX_LENGTH]u8
	if subagent_native(member) {
		if !member.resumed {
			if problem := acp_native_session_create(member); problem != "" {
				subagent_fail(member, .Failed, problem)
				return false
			}
		}
		previous_session = journal.session_id_to_hex(member.session, hex[:])
	}
	if problem := acp_connection_open(connection); problem != "" {
		subagent_fail(member, .Failed, problem)
		return false
	}
	if problem := acp_session_open(connection, previous_session); problem != "" {
		subagent_fail(member, acp_stopped(connection) ? .Stopped : .Failed, problem)
		return false
	}
	session_text, session_error := strings.clone(connection.session_id, allocator)
	if session_error != nil {
		subagent_fail(member, .Failed, "the agent's session id could not be held")
		return false
	}

	{
		sync.mutex_guard(&member.team.mutex)
		delete(member.acp_session, allocator)
		member.acp_session = session_text
	}

	if problem := acp_control_apply(connection); problem != "" {
		subagent_fail(member, .Failed, problem)
		return false
	}
	for len(connection.pending) > 0 || !connection.idle {
		if problem := acp_receive(connection); problem != "" {
			subagent_fail(member, .Failed, problem)
			return false
		}
	}
	return true
}

// acp_native_session_create commits the journal session a new native child works in.
@(private, require_results)
acp_native_session_create :: proc(member: ^Subagent) -> (problem: string) {
	store, open_error := journal.open(member.store_directory, member.lock_directory, member.run, .Read_Write, member.allocator)
	if open_error != nil { return "the native child session could not be created" }
	_, create_error := journal.create_session(
		store,
		{id = member.session, workspace = member.workspace, role = .Subagent, parent_session = member.parent_session, parent_call = member.parent_call},
	)
	if create_error == nil { _, create_error = journal.commit(store) }
	close_error := journal.close(store)
	if create_error != nil || close_error != nil { return "the native child session could not be committed" }
	return ""
}

// acp_run_prompts sends the task, then every message the orchestrator sends and every pending
// compaction, until a turn ends with nothing left to answer. It marks the member completed and
// returns true then; otherwise it records the failure and returns false.
@(private, require_results)
acp_run_prompts :: proc(connection: ^ACP_Connection) -> (completed: bool) {
	member := connection.member
	allocator := member.allocator
	// Parent messages are read through a separate journal connection; the client never owns the child's claim.
	store, store_open_error := journal.open(member.store_directory, member.lock_directory, member.run, .Read_Only, allocator)
	if store_open_error != nil {
		subagent_fail(
			member,
			.Failed,
			fmt.tprintf("the subagent's inbox could not be opened: %s", journal.error_text(store_open_error, context.temp_allocator)),
		)
		return false
	}
	// This is the client's read-only view of the parent's records: a close that fails cannot
	// change what the child did, so the outcome stays as the run left it.
	defer _ = journal.close(store)
	connection.inbox = store
	defer connection.inbox = nil

	text := member.prompt
	if !subagent_native(member) &&
	   !member.resumed &&
	   member.instruction != "" { text = strings.concatenate({member.instruction, "\n\n", member.prompt}, context.temp_allocator) }
	// text is a copy this loop releases once its prompt is answered, after the first.
	owned := false
	after: journal.Journal_Seq
	if member.resumed {
		inbox, inbox_after, problem := acp_inbox_text(store, member, allocator)
		if problem != "" {
			subagent_fail(member, .Failed, problem)
			return false
		}
		if inbox_after != 0 { text, after, owned = inbox, inbox_after, true }
	}
	for {
		// Each prompt releases the temp memory its answers were decoded into.
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		if member.compact {
			member.compact = false
			if problem := acp_prompt_send(connection, "/compact"); problem != "" {
				subagent_fail(member, .Failed, problem)
				return false
			}
		}
		stop_reason, problem := acp_prompt(connection, text, after)
		if owned { delete(text, allocator) }
		text, after, owned = "", 0, false
		if !acp_turn_succeeded(connection, stop_reason, problem) { return false }
		inbox, inbox_after, inbox_problem := acp_inbox_text(store, member, allocator)
		if inbox_problem != "" {
			subagent_fail(member, .Failed, inbox_problem)
			return false
		}
		if inbox_after == 0 {
			sync.mutex_guard(&member.team.mutex)
			if member.configuration.switching || member.configuration.compact { continue }
			member.status = .Completed
			return true
		}
		text, after, owned = inbox, inbox_after, true
	}
}

// acp_turn_succeeded reports whether a prompt ended with the agent's answer. Otherwise it
// records why the member stopped or failed.
@(private, require_results)
acp_turn_succeeded :: proc(connection: ^ACP_Connection, stop_reason, problem: string) -> bool {
	member := connection.member
	switch {
	case problem != "":
		subagent_fail(member, acp_stopped(connection) ? .Stopped : .Failed, problem)
	case stop_reason == "cancelled" || acp_stopped(connection):
		subagent_fail(member, .Stopped, "the subagent was stopped before it finished")
	case stop_reason == "error":
		subagent_fail(
			member,
			.Failed,
			connection.turn_error if connection.turn_error != "" else "the agent reported that its turn failed without an error message",
		)
	case stop_reason != "end_turn":
		reason := fmt.tprintf("the agent ended its turn with %q; what it answered:\n\n%s", stop_reason, string(connection.answer[:]))
		subagent_fail(member, .Failed, reason)
	case:
		return true
	}
	return false
}

// ACP_Outstanding owns the identity and values needed when its response arrives.
@(private)
ACP_Model_Reply :: struct {
	model, effort: string,
}
@(private)
ACP_Effort_Reply :: struct {
	effort: string,
}
// ACP_Reply is what installing an answer needs beyond the answer. A prompt's answer carries
// only its stop reason, so a prompt is the nil reply.
@(private)
ACP_Reply :: union {
	ACP_Model_Reply,
	ACP_Effort_Reply,
}
@(private)
ACP_Outstanding :: struct {
	id:      i64,
	variant: ACP_Reply,
}

@(private)
acp_request_destroy :: proc(request: ^ACP_Outstanding, allocator: mem.Allocator) {
	switch reply in request.variant {
	case nil:
	case ACP_Model_Reply:
		delete(reply.model, allocator); delete(reply.effort, allocator)
	case ACP_Effort_Reply:
		delete(reply.effort, allocator)
	}
	request^ = {}
}

@(private, require_results)
acp_send :: proc(connection: ^ACP_Connection, reply: ACP_Reply, method: string, params: $P) -> string {
	allocator := connection.member.allocator
	request := ACP_Outstanding {
		id = connection.next_id,
	}
	failed := true
	defer if failed { acp_request_destroy(&request, allocator) }
	// A failed clone leaves its string empty, so the deferred destroy releases the other.
	switch value in reply {
	case nil:
	case ACP_Model_Reply:
		owned: ACP_Model_Reply
		model_error, effort_error: mem.Allocator_Error
		owned.model, model_error = strings.clone(value.model, allocator)
		owned.effort, effort_error = strings.clone(value.effort, allocator)
		request.variant = owned
		if model_error != nil || effort_error != nil { return "the pending ACP request could not be held" }
	case ACP_Effort_Reply:
		owned: ACP_Effort_Reply
		effort_error: mem.Allocator_Error
		owned.effort, effort_error = strings.clone(value.effort, allocator)
		request.variant = owned
		if effort_error != nil { return "the pending ACP request could not be held" }
	}
	if _, append_error := append(&connection.pending, request); append_error != nil { return "the pending ACP request could not be held" }
	connection.next_id += 1
	failed = false
	if acp.write_request(&connection.writer, request.id, method, params) != .None { return acp_ended(connection, "stopped reading its input") }
	return ""
}

@(private, require_results)
acp_option_send :: proc(connection: ^ACP_Connection, reply: ACP_Reply, option: ACP_Config_Option, value: string) -> string {
	return acp_send(connection, reply, acp.METHOD_SESSION_SET_CONFIG_OPTION, acp_option_request(connection, option, value))
}

// acp_option_request is the session/set_config_option that sets option to value. Version 2
// requires the value's type; version 1 reads a missing type as an id. The strings borrow
// connection and option.
@(private)
acp_option_request :: proc(connection: ^ACP_Connection, option: ACP_Config_Option, value: string) -> acp.Session_Set_Config_Option_Params {
	return {
		session_id = connection.session_id,
		config_id = option.config_id if option.config_id != "" else option.id,
		type = "id" if connection.version == 2 else "",
		value = value,
	}
}

// acp_option_install records the agent's answer to a set_config_option for the option of
// category: the options it sent back replace ours, or when it sent none the value just set
// becomes the option's current value. problem is static text, "" when the answer is held.
@(private, require_results)
acp_option_install :: proc(connection: ^ACP_Connection, answered: []ACP_Config_Option, category, value: string) -> (problem: string) {
	if len(answered) > 0 {
		if !acp_options_replace(connection, answered) { return "the agent's config options could not be held" }
	} else if !acp_option_current(connection, category, value) {
		return "the selected option could not be held"
	}
	return ""
}

@(private, require_results)
acp_effort_send :: proc(connection: ^ACP_Connection, effort: string) -> string {
	if effort == "" { return "" }
	option, found := acp_option(connection.config_options, ACP_OPTION_CATEGORY_EFFORT)
	if !found { return "" }
	value := acp_option_value(option, effort)
	if value == "" { return "" }
	return acp_option_send(connection, ACP_Effort_Reply{effort = value}, option, value)
}

@(private, require_results)
acp_configure_refusal :: proc(connection: ^ACP_Connection, reason: string) -> string {
	member := connection.member
	if !acp_replace(&connection.turn_error, reason, member.allocator) { return "the configuration refusal could not be held" }
	text := fmt.tprintf("%s asks:\nYour request to switch model or effort was not applied: %s", member.name, reason)
	sender := journal.open(member.store_directory, member.lock_directory, member.run, .Read_Write, member.allocator) or_else nil
	if sender == nil { return "the refusal of a model switch could not be recorded" }
	defer _ = journal.close(sender)
	if journal.follow(sender, member.parent_session) != nil ||
	   journal.append_input(sender, text, .Agent) != nil { return "the refusal of a model switch could not be recorded" }
	owner_wake_signal()
	return ""
}

// acp_receive is the live exchange's only receive step. Service paths only send.
@(private, require_results)
acp_receive :: proc(connection: ^ACP_Connection) -> string {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	envelope, problem := acp_next(connection)
	if problem != "" { return problem }
	defer acp.destroy_envelope(&envelope, connection.member.allocator)
	if envelope.kind != .Response {
		return acp_handle(connection, envelope)
	}
	id, is_number := envelope.id.(i64)
	if !is_number { return "" }
	index := -1
	for request, candidate in connection.pending { if request.id == id { index = candidate; break } }
	if index < 0 { return "" }
	request := connection.pending[index]
	ordered_remove(&connection.pending, index)
	defer acp_request_destroy(&request, connection.member.allocator)
	if failed, has_error := envelope.rpc_error.?; has_error {
		if request.variant == nil { return fmt.tprintf("the agent refused session/prompt: %s", failed.message) }
		return acp_configure_refusal(connection, failed.message)
	}
	if request.variant == nil {
		accepted: acp.Prompt_Result
		if acp.params_decode(envelope.result, &accepted, context.temp_allocator) != .None { return "the agent's prompt answer is not what ACP defines" }
		connection.idle = accepted.stop_reason != ""
		if accepted.stop_reason != "" &&
		   !acp_replace(&connection.stop_reason, accepted.stop_reason, connection.member.allocator) { return "the agent's stop reason could not be held" }
		return ""
	}
	configured: ACP_Session_Opened
	if acp.params_decode(envelope.result, &configured, context.temp_allocator) != .None { return "the agent's configuration answer is not what ACP defines" }
	category, value := ACP_OPTION_CATEGORY_EFFORT, ""
	switch reply in request.variant {
	case ACP_Model_Reply:
		category, value = ACP_OPTION_CATEGORY_MODEL, reply.model
	case ACP_Effort_Reply:
		value = reply.effort
	case nil:
	}
	if install_problem := acp_option_install(connection, configured.config_options, category, value); install_problem != "" { return install_problem }
	member := connection.member
	if !acp_selection_apply(connection) { return "the agent's selected options could not be held" }
	switch &reply in request.variant {
	case nil:
	case ACP_Model_Reply:
		if _, reported := acp_option(configured.config_options, ACP_OPTION_CATEGORY_MODEL); !reported {
			sync.mutex_guard(&member.team.mutex)
			delete(member.program.model, member.allocator)
			member.program.model = reply.model
			reply.model = ""
		}
		return acp_effort_send(connection, reply.effort)
	case ACP_Effort_Reply:
		if _, reported := acp_option(configured.config_options, ACP_OPTION_CATEGORY_EFFORT); !reported {
			sync.mutex_guard(&member.team.mutex)
			delete(member.effort, member.allocator)
			member.effort = reply.effort
			reply.effort = ""
		}
	}
	return ""
}

@(private, require_results)
acp_option_current :: proc(connection: ^ACP_Connection, category, value: string) -> bool {
	for &option in connection.config_options {
		if option.category != category { continue }
		return acp_replace(&option.current_value, value, connection.member.allocator)
	}
	return true
}

@(private, require_results)
acp_selection_apply :: proc(connection: ^ACP_Connection) -> bool {
	member := connection.member
	for category in ([]string{ACP_OPTION_CATEGORY_MODEL, ACP_OPTION_CATEGORY_EFFORT}) {
		option, found := acp_option(connection.config_options, category)
		if !found || (category == ACP_OPTION_CATEGORY_MODEL && option.current_value == "") { continue }
		value, clone_error := strings.clone(option.current_value, member.allocator)
		if clone_error != nil { return false }
		sync.mutex_guard(&member.team.mutex)
		selected := &member.program.model if category == ACP_OPTION_CATEGORY_MODEL else &member.effort
		delete(selected^, member.allocator)
		selected^ = value
	}
	return true
}

@(private)
acp_options_destroy :: proc(options: []ACP_Config_Option, allocator: mem.Allocator) {
	for option in options {
		delete(option.id, allocator)
		delete(option.config_id, allocator)
		delete(option.category, allocator)
		delete(option.current_value, allocator)
		for choice in option.options { delete(choice.value, allocator); delete(choice.name, allocator) }
		delete(option.options, allocator)
	}
	delete(options, allocator)
}

@(private, require_results)
acp_options_replace :: proc(connection: ^ACP_Connection, options: []ACP_Config_Option) -> bool {
	allocator := connection.member.allocator
	copied := make([]ACP_Config_Option, len(options), allocator) or_else nil
	if len(options) > 0 && copied == nil { return false }
	complete := false
	defer if !complete { acp_options_destroy(copied, allocator) }
	for option, index in options {
		for pair in ([]struct {
				out:  ^string,
				text: string,
			}{{&copied[index].id, option.id}, {&copied[index].config_id, option.config_id}, {&copied[index].category, option.category}, {&copied[index].current_value, option.current_value}}) {
			pair.out^ = strings.clone(pair.text, allocator) or_else ""
			if pair.text != "" && pair.out^ == "" { return false }
		}
		copied[index].options = make([]acp.Config_Value, len(option.options), allocator) or_else nil
		if len(option.options) > 0 && copied[index].options == nil { return false }
		for choice, choice_index in option.options {
			owned := &copied[index].options[choice_index]
			owned.value = strings.clone(choice.value, allocator) or_else ""
			owned.name = strings.clone(choice.name, allocator) or_else ""
			if (choice.value != "" && owned.value == "") || (choice.name != "" && owned.name == "") { return false }
		}
	}
	acp_options_destroy(connection.config_options, allocator)
	connection.config_options = copied
	complete = true
	return true
}

// acp_prompt_send acknowledges additional version 2 input without waiting for idle.
@(private, require_results)
acp_prompt_send :: proc(connection: ^ACP_Connection, text: string) -> string {
	return acp_send(
		connection,
		nil,
		acp.METHOD_SESSION_PROMPT,
		acp.Session_Prompt_Params{session_id = connection.session_id, prompt = {{type = acp.CONTENT_TEXT, text = text}}},
	)
}

@(private, require_results)
acp_service :: proc(connection: ^ACP_Connection) -> string {
	if problem := acp_control_apply(connection); problem != "" { return problem }
	if connection.inbox == nil { return "" }
	member := connection.member
	text, after, problem := acp_inbox_text(connection.inbox, member, context.temp_allocator)
	if problem != "" { return problem }
	if after == 0 { return "" }
	if problem = acp_prompt_send(connection, text); problem != "" { return problem }
	acp_inbox_consumed(member, after)
	return ""
}

// acp_serve_live applies what the parent changed while a prompt is live. Version 2 takes the
// configuration and forwards new messages as prompts at once; version 1 reconfigures only once
// its turn is over. A stopped connection takes nothing new.
@(private, require_results)
acp_serve_live :: proc(connection: ^ACP_Connection) -> string {
	if !connection.live_prompt || acp_stopped(connection) { return "" }
	if connection.version == 2 { return acp_service(connection) }
	if connection.idle && len(connection.pending) == 0 { return acp_control_apply(connection) }
	return ""
}

// acp_prompt sends one prompt and waits until the agent's turn is over. Version 1 ends the turn
// with the prompt's answer; version 2 acknowledges the prompt and reports the end as an idle
// state update. stop_reason is the agent's, temp-allocated.
@(private, require_results)
acp_prompt :: proc(connection: ^ACP_Connection, text: string, after := journal.Journal_Seq(0)) -> (stop_reason: string, problem: string) {
	if text != "" {
		clear(&connection.answer)
		for owned in ([]^string{&connection.message_id, &connection.stop_reason, &connection.turn_error}) {
			delete(owned^, connection.member.allocator)
			owned^ = ""
		}
		if problem = acp_prompt_send(connection, text); problem != "" { return }
		if after != 0 { acp_inbox_consumed(connection.member, after) }
	}
	connection.live_prompt = true
	defer connection.live_prompt = false
	for {
		if problem = acp_serve_live(connection); problem != "" { return }
		if connection.idle && len(connection.pending) == 0 { break }
		if problem = acp_receive(connection); problem != "" { return }
	}
	if text == "" && connection.turn_error != "" { return "", connection.turn_error }
	if connection.stop_reason == "" { return "end_turn", "" }
	stop_reason = strings.clone(connection.stop_reason, context.temp_allocator) or_else ""
	if stop_reason == "" { return "", "the agent's stop reason could not be held" }
	return stop_reason, ""
}

// acp_connection_open starts the agent program with its three standard streams piped here.
// Everything it made before a failure is already recorded in connection, in the order it
// was made, so the caller's acp_connection_close releases it and retires the reader threads
// that were started; open itself releases nothing beyond the child's ends of the pipes.
@(private, require_results)
acp_connection_open :: proc(connection: ^ACP_Connection) -> (problem: string) {
	member := connection.member
	input_read, input_write, input_error := os.pipe()
	if input_error != nil { return "the agent's input could not be created; nothing ran" }
	defer _ = os.close(input_read)
	connection.input = input_write
	readers, readers_error := new(ACP_Readers, member.allocator)
	if readers_error != nil { return "the agent's readers could not be held; nothing ran" }
	connection.readers = readers
	readers.allocator = member.allocator
	readers.wake = &member.wake
	if queue.init(&readers.frames, allocator = member.allocator) != nil { return "the agent's frame queue could not be held; nothing ran" }
	readers.stderr_tail.allocator = member.allocator
	output_read, output_write, output_error := os.pipe()
	if output_error != nil { return "the agent's output pipe could not be created; nothing ran" }
	defer _ = os.close(output_write)
	readers.output = output_read
	errors_read, errors_write, errors_error := os.pipe()
	if errors_error != nil { return "the agent's error pipe could not be created; nothing ran" }
	defer _ = os.close(errors_write)
	readers.errors = errors_read
	argv, argv_error := make([]string, len(member.program.arguments) + 1, context.temp_allocator)
	if argv_error != nil { return "the agent's arguments could not be held; nothing ran" }
	argv[0] = member.program.command
	copy(argv[1:], member.program.arguments)
	child, spawn_error := os.process_start({command = argv, working_dir = member.workspace, stdin = input_read, stdout = output_write, stderr = errors_write})
	if spawn_error != nil { return fmt.tprintf("%s could not be started: %v; nothing ran", member.program.command, spawn_error) }
	connection.child = child
	connection.started = true
	readers.process = child
	writer, writer_error := acp.writer_init(os.to_writer(input_write), member.allocator)
	connection.writer = writer
	decoder, decoder_error := acp.frame_decoder_init(allocator = member.allocator)
	readers.decoder = decoder
	if writer_error != nil || decoder_error != nil { return "the agent's connection could not be allocated" }
	procedures := [ACP_Worker]thread.Thread_Proc {
		.Output  = acp_output_read,
		.Errors  = acp_errors_read,
		.Process = acp_process_wait,
	}
	previous_allocator := context.allocator
	context.allocator = member.allocator
	defer context.allocator = previous_allocator
	for procedure, index in procedures {
		worker := thread.create(procedure)
		if worker == nil { return "the agent's reader thread could not be created" }
		readers.threads[index] = worker
		worker.data = readers
		thread.start(worker)
	}
	return ""
}

// acp_readers_wait waits only for the stated teardown deadline, never for an inherited pipe.
@(private, require_results)
acp_readers_wait :: proc(readers: ^ACP_Readers, process_only: bool, deadline: time.Tick) -> bool {
	for {
		{
			sync.mutex_guard(&readers.mutex)
			complete := true
			for worker, index in readers.threads {
				if worker != nil && !readers.done[index] && (!process_only || index == .Process) { complete = false }
			}
			if complete { return true }
		}
		remaining := time.tick_diff(time.tick_now(), deadline)
		if remaining <= 0 { return false }
		_ = sync.sema_wait_with_timeout(&readers.completion, remaining)
	}
}

// acp_connection_close ends stdin, lets the child exit, then kills it if necessary. A
// worker held by a descendant is detached and its state retained, never killed or freed.
@(private)
acp_connection_close :: proc(connection: ^ACP_Connection, patience: time.Duration) {
	readers := connection.readers
	writer_retired := acp.writer_destroy(&connection.writer, min(patience, SUBAGENT_ACP_CLOSE_GRACE))
	if !writer_retired && connection.started {
		process_finished: bool
		{
			sync.mutex_guard(&readers.mutex)
			process_finished = readers.done[.Process]
		}
		if !process_finished { _ = os.process_kill(connection.child) }
		writer_retired = acp.writer_destroy(&connection.writer, SUBAGENT_ACP_CLOSE_GRACE)
	}
	if writer_retired && connection.input != nil {
		_ = os.close(connection.input)
		connection.input = nil
	}
	if connection.started {
		if readers.threads[.Process] == nil {
			_ = os.process_kill(connection.child)
			_, wait_error := os.process_wait(connection.child, SUBAGENT_ACP_CLOSE_GRACE)
			if wait_error != nil {
				message := fmt.tprintf("the agent could not be reaped: %v; its outcome is unknown", wait_error)
				subagent_fail(connection.member, .Failed, message)
			}
		} else if !acp_readers_wait(readers, true, time.tick_add(time.tick_now(), SUBAGENT_ACP_CLOSE_GRACE)) {
			_ = os.process_kill(connection.child)
			_ = acp_readers_wait(readers, true, time.tick_add(time.tick_now(), SUBAGENT_ACP_CLOSE_GRACE))
		}
	}
	if !writer_retired {
		subagent_fail(connection.member, .Failed, "the agent's writer did not retire; its outcome is unknown and its resources were retained")
	}
	if readers != nil {
		retired := acp_readers_wait(readers, false, time.tick_add(time.tick_now(), SUBAGENT_ACP_CLOSE_GRACE))
		{
			sync.mutex_guard(&readers.mutex)
			readers.wake = nil
		}
		if retired {
			for worker in readers.threads {
				if worker != nil { thread.join(worker); thread.destroy(worker) }
			}
			if readers.threads[.Output] == nil && readers.output != nil { _ = os.close(readers.output) }
			if readers.threads[.Errors] == nil && readers.errors != nil { _ = os.close(readers.errors) }
			for {
				frame, queued := queue.pop_front_safe(&readers.frames)
				if !queued { break }
				delete(frame, readers.allocator)
			}
			queue.destroy(&readers.frames)
			delete(readers.stderr_tail)
			acp.frame_decoder_destroy(&readers.decoder)
			free(readers, connection.member.allocator)
		} else {
			subagent_fail(connection.member, .Failed, "the agent's transport worker did not retire; its outcome is unknown and its resources were retained")
		}
	}
	delete(connection.session_id, connection.member.allocator)
	delete(connection.message_id, connection.member.allocator)
	delete(connection.stop_reason, connection.member.allocator)
	delete(connection.turn_error, connection.member.allocator)
	delete(connection.answer)
	for &request in connection.pending { acp_request_destroy(&request, connection.member.allocator) }
	delete(connection.pending)
	acp_options_destroy(connection.config_options, connection.member.allocator)
	connection^ = {}
}

// acp_session_open initializes the connection, opens a new session or continues previous_session,
// and chooses the model and effort among what the agent offers.
@(private, require_results)
acp_session_open :: proc(connection: ^ACP_Connection, previous_session := "") -> (problem: string) {
	connection.idle = true
	session_id := previous_session
	member := connection.member
	// Version 2 names the client in info; a version 1 agent answers with its own version and
	// reads the missing clientCapabilities as no file system and no terminal.
	Initialized :: struct {
		protocol_version:   int `json:"protocolVersion"`,
		info:               acp.Implementation `json:"info"`,
		agent_capabilities: struct {
			load_session:         bool `json:"loadSession"`,
			session_capabilities: struct {
				resume: json.Value `json:"resume"`,
			} `json:"sessionCapabilities"`,
		} `json:"agentCapabilities"`,
	}
	initialized: Initialized
	request := acp.Initialize_Params {
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

	opened: ACP_Session_Opened
	if session_id == "" {
		if problem = acp_call(connection, acp.METHOD_SESSION_NEW, acp.Session_New_Params{cwd = member.workspace}, &opened); problem != "" { return }
		if opened.session_id == "" { return "the agent opened a session without an id" }
		session_id = opened.session_id
	} else {
		method := acp.METHOD_SESSION_RESUME
		_, supports_resume := initialized.agent_capabilities.session_capabilities.resume.(json.Object)
		if connection.version == 1 && !supports_resume {
			if !initialized.agent_capabilities.load_session { return "the ACP agent advertises neither sessionCapabilities.resume nor loadSession; its session cannot be resumed" }
			method = acp.METHOD_SESSION_LOAD
		}
		connection.replaying = true
		if method == acp.METHOD_SESSION_LOAD {
			problem = acp_call(connection, method, acp.Session_Load_Params{session_id = session_id, cwd = member.workspace}, &opened)
		} else {
			problem = acp_call(connection, method, acp.Session_Resume_Params{session_id = session_id, cwd = member.workspace}, &opened)
		}
		connection.replaying = false
		if problem != "" { return }
	}
	connection.session_id = strings.clone(session_id, member.allocator) or_else ""
	if connection.session_id == "" { return "the agent's session id could not be held" }
	connection.opened = opened
	if !acp_options_replace(connection, opened.config_options) { return "the agent's config options could not be held" }
	return acp_session_configure(connection, opened, member.program.model, member.effort)
}

@(private, require_results)
acp_session_configure :: proc(
	connection: ^ACP_Connection,
	opened: ACP_Session_Opened,
	model, requested_effort: string,
	default_effort := true,
) -> (
	problem: string,
) {
	member := connection.member

	if model != "" {
		option, value, listed := acp_model_find(opened.config_options, opened.models, model)
		switch {
		case value != "":
			if value != option.current_value {
				if problem = acp_set_option(connection, option, value); problem != "" { return }
			}
		case listed:
			set: acp.Session_Set_Model_Result
			if model != opened.models.current_model_id {
				if problem = acp_call(
					connection,
					acp.METHOD_SESSION_SET_MODEL,
					acp.Session_Set_Model_Params{session_id = connection.session_id, model_id = model},
					&set,
				); problem != "" { return }
			}
		case:
			return acp_model_unavailable(opened, model)
		}
	}
	// An effort the agent does not offer is treated as one left out, as for a native subagent.
	// When the agent shares no level with the orchestrator, its own default stays, since its
	// lowest level may turn reasoning off.
	if option, found := acp_option(connection.config_options, ACP_OPTION_CATEGORY_EFFORT); found && (default_effort || requested_effort != "") {
		levels, levels_error := make([]string, len(option.options), context.temp_allocator)
		if levels_error != nil { return "the agent's effort levels could not be held" }
		for choice, index in option.options { levels[index] = choice.value }
		effort := acp_option_value(option, requested_effort)
		if effort == "" { effort = effort_step_down(member.program.parent_levels, levels, member.program.parent_effort) }
		if effort != "" && effort != option.current_value {
			if problem = acp_set_option(connection, option, effort); problem != "" { return }
		}
	}
	if !acp_selection_apply(connection) { return "the agent's selected options could not be held" }
	return ""
}

@(private, require_results)
acp_control_apply :: proc(connection: ^ACP_Connection) -> string {
	member := connection.member
	configuration: ACP_Configure
	{
		sync.mutex_guard(&member.team.mutex)
		configuration = member.configuration
		member.configuration = {}
	}
	defer acp_configure_destroy(&configuration)
	if configuration.switching {
		if configuration.model != "" {
			option, value, listed := acp_model_find(connection.config_options, connection.opened.models, configuration.model)
			switch {
			case value != "":
				if problem := acp_option_send(connection, ACP_Model_Reply{model = value, effort = configuration.effort}, option, value);
				   problem != "" { return problem }
			case listed:
				if problem := acp_send(
					connection,
					ACP_Model_Reply{model = configuration.model, effort = configuration.effort},
					acp.METHOD_SESSION_SET_MODEL,
					acp.Session_Set_Model_Params{session_id = connection.session_id, model_id = configuration.model},
				); problem != "" { return problem }
			case:
				return acp_configure_refusal(connection, acp_model_unavailable(connection.opened, configuration.model))
			}
		} else if problem := acp_effort_send(connection, configuration.effort); problem != "" { return problem }
	}
	if configuration.compact { return acp_prompt_send(connection, "/compact") }
	return ""
}

// ACP_Config_Option is a session config option of either version: version 1 names it by id and
// version 2 by configId.
@(private)
ACP_Config_Option :: struct {
	id:            string `json:"id"`,
	config_id:     string `json:"configId"`,
	category:      string `json:"category"`,
	current_value: string `json:"currentValue"`,
	options:       []acp.Config_Value `json:"options"`,
}

// ACP_Session_Opened is the configuration returned by session/new, session/resume, or session/load.
// Only session/new returns session_id. models is the pre-standard list some version 1 agents send.
@(private)
ACP_Session_Opened :: struct {
	session_id:     string `json:"sessionId"`,
	config_options: []ACP_Config_Option `json:"configOptions"`,
	models:         acp.Models_State `json:"models"`,
}

@(private, require_results)
acp_set_option :: proc(connection: ^ACP_Connection, option: ACP_Config_Option, value: string) -> (problem: string) {
	set: ACP_Session_Opened
	if problem = acp_call(connection, acp.METHOD_SESSION_SET_CONFIG_OPTION, acp_option_request(connection, option, value), &set);
	   problem != "" { return problem }
	return acp_option_install(connection, set.config_options, option.category, value)
}

@(private, require_results)
acp_option :: proc(options: []ACP_Config_Option, category: string) -> (ACP_Config_Option, bool) {
	for option in options {
		if option.category == category { return option, true }
	}
	return {}, false
}

// acp_option_value is the value of the choice named wanted, by value or display name, or "".
@(private)
acp_option_value :: proc(option: ACP_Config_Option, wanted: string) -> string {
	if wanted == "" { return "" }
	for choice in option.options {
		if choice.value == wanted || choice.name == wanted { return choice.value }
	}
	return ""
}

@(private, require_results)
acp_model_offered :: proc(models: acp.Models_State, model: string) -> bool {
	for offered in models.available_models {
		if offered.model_id == model { return true }
	}
	return false
}

// acp_model_find looks model up among what an agent offers: a config option that names it, or
// else the pre-standard model list. value is the option's own spelling of model, and is empty
// when no option offers it; listed says the model list offers it. A model neither offers is
// unavailable. options and models must outlive the results.
@(private)
acp_model_find :: proc(options: []ACP_Config_Option, models: acp.Models_State, model: string) -> (option: ACP_Config_Option, value: string, listed: bool) {
	if found, is_found := acp_option(options, ACP_OPTION_CATEGORY_MODEL); is_found {
		if value = acp_option_value(found, model); value != "" { return found, value, false }
	}
	return {}, "", acp_model_offered(models, model)
}

// acp_model_unavailable says that opened offers no model, with what it does offer. The
// text is temp-allocated.
@(private)
acp_model_unavailable :: proc(opened: ACP_Session_Opened, model: string) -> string {
	return fmt.tprintf("the agent offers no model %q; it offers: %s", model, acp_models_text(opened))
}

// acp_models_text lists the models a session offers, temp-allocated. A list that cannot be
// held says so rather than reading as an agent that offers no model.
@(private)
acp_models_text :: proc(opened: ACP_Session_Opened) -> string {
	names, names_error := make([dynamic]string, context.temp_allocator)
	if names_error != nil { return "the model list could not be held" }
	if option, found := acp_option(opened.config_options, ACP_OPTION_CATEGORY_MODEL); found {
		for choice in option.options { append(&names, choice.value) }
	}
	for offered in opened.models.available_models { append(&names, offered.model_id) }
	if len(names) == 0 { return "no choice of model" }
	joined, join_error := strings.join(names[:], ", ", context.temp_allocator)
	if join_error != nil { return "the model list could not be held" }
	return joined
}

// acp_call sends one request and reads until its answer, which it decodes into result with
// the temp allocator. problem, temp-allocated, says why there is no answer.
@(private, require_results)
acp_call :: proc(connection: ^ACP_Connection, method: string, params: $P, result: ^$R) -> (problem: string) {
	id := connection.next_id
	connection.next_id += 1
	if acp.write_request(&connection.writer, id, method, params) != .None { return acp_ended(connection, "stopped reading its input") }
	for {
		envelope, next_problem := acp_next(connection)
		if next_problem != "" { return next_problem }
		defer acp.destroy_envelope(&envelope, connection.member.allocator)
		if envelope.kind != .Response {
			if handle_problem := acp_handle(connection, envelope); handle_problem != "" { return handle_problem }
			continue
		}
		answered, is_number := envelope.id.(i64)
		if !is_number || answered != id { continue }
		if failed, has_error := envelope.rpc_error.?; has_error { return fmt.tprintf("the agent refused %s: %s", method, failed.message) }
		if _, is_null := envelope.result.(json.Null); is_null { return "" }
		switch acp.params_decode(envelope.result, result, context.temp_allocator) {
		case .None:
			return ""
		case .Invalid:
			return fmt.tprintf("the agent's answer to %s is not what ACP defines", method)
		case .Allocation:
			return fmt.tprintf("the agent's answer to %s could not be held because allocation failed", method)
		}
	}
}

// ACP_MESSAGE_NOT_HELD and ACP_PERMISSION_REPLY_NOT_SENT are the static texts of the two
// ways handling an agent's message fails.
ACP_MESSAGE_NOT_HELD :: "the agent's message could not be held"
ACP_PERMISSION_REPLY_NOT_SENT :: "the reply to the agent's permission request was not sent"

// acp_handle acts on a message that answers nothing this client asked. problem is static
// text, "" when the message was handled: it says that what the message carries could not be
// held, or that a reply to the agent was not sent. Either ends the connection rather than
// letting the answer, the stop reason, or an unanswered request go missing.
@(private, require_results)
acp_handle :: proc(connection: ^ACP_Connection, envelope: acp.Envelope) -> (problem: string) {
	// What a message is decoded into is released with it, so a long turn holds no scratch.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	#partial switch envelope.kind {
	case .Notification:
		if !acp_notification(connection, envelope) { return ACP_MESSAGE_NOT_HELD }
	case .Request:
		return acp_answer(connection, envelope)
	}
	return ""
}

// acp_notification follows the agent's latest message and, in version 2, the end of its turn.
// Text before a tool call is narration, so a tool call starts the answer over, and so does a
// message with a new id. It reports false when what it followed could not be held.
@(private, require_results)
acp_notification :: proc(connection: ^ACP_Connection, envelope: acp.Envelope) -> bool {
	owner_wake_signal()
	if connection.replaying || envelope.method != acp.METHOD_SESSION_UPDATE { return true }
	kind: acp.Session_Notification(acp.Update_Kind)
	switch acp.params_decode(envelope.params, &kind, context.temp_allocator) {
	case .None:
	case .Invalid:
		return true
	case .Allocation:
		return false
	}
	if kind.session_id != connection.session_id { return true }
	switch kind.update.session_update {
	case acp.UPDATE_TOOL_CALL, acp.UPDATE_TOOL_CALL_UPDATE:
		clear(&connection.answer)
		return acp_replace(&connection.message_id, "", connection.member.allocator)
	case acp.UPDATE_AGENT_MESSAGE_CHUNK:
		chunk: acp.Session_Notification(acp.Message_Chunk)
		switch acp.params_decode(envelope.params, &chunk, context.temp_allocator) {
		case .None:
		case .Invalid:
			return true
		case .Allocation:
			return false
		}
		if !acp_message_begin(connection, chunk.update.message_id) { return false }
		if chunk.update.content.type != acp.CONTENT_TEXT { return true }
		_, append_error := append(&connection.answer, chunk.update.content.text)
		return append_error == nil
	case acp.UPDATE_AGENT_MESSAGE:
		message: acp.Session_Notification(acp.Message_Update)
		switch acp.params_decode(envelope.params, &message, context.temp_allocator) {
		case .None:
		case .Invalid:
			return true
		case .Allocation:
			return false
		}
		if !acp_message_begin(connection, message.update.message_id) { return false }
		// The update is an upsert: content left out keeps the message as it is.
		if !acp_update_has(envelope.params, "content") { return true }
		clear(&connection.answer)
		for block in message.update.content {
			if block.type != acp.CONTENT_TEXT { continue }
			if _, append_error := append(&connection.answer, block.text); append_error != nil { return false }
		}
	case acp.UPDATE_STATE:
		state: acp.Session_Notification(acp.State_Update)
		switch acp.params_decode(envelope.params, &state, context.temp_allocator) {
		case .None:
		case .Invalid:
			return true
		case .Allocation:
			return false
		}
		if state.update.state == "running" { connection.idle = false; return true }
		if state.update.state != "idle" { return true }
		if failed, has_error := state.update.error.?; has_error {
			if !acp_replace(&connection.turn_error, failed.message, connection.member.allocator) { return false }
		}
		connection.idle = true
		return acp_replace(&connection.stop_reason, state.update.stop_reason, connection.member.allocator)
	}
	return true
}

// acp_update_has reports whether a session/update's update object carries key.
@(private, require_results)
acp_update_has :: proc(params: json.Value, key: string) -> bool {
	notification, is_object := params.(json.Object)
	if !is_object { return false }
	update, update_is_object := notification["update"].(json.Object)
	if !update_is_object { return false }
	_, present := update[key]
	return present
}

// acp_message_begin starts the answer over when the agent begins a message with a new id. It
// reports false when the id could not be held.
@(private, require_results)
acp_message_begin :: proc(connection: ^ACP_Connection, message_id: string) -> bool {
	if message_id == "" || message_id == connection.message_id { return true }
	clear(&connection.answer)
	return acp_replace(&connection.message_id, message_id, connection.member.allocator)
}

// acp_replace sets an owned string to a copy of value. It reports false when the copy could
// not be held, in which case the string is empty.
@(private, require_results)
acp_replace :: proc(owned: ^string, value: string, allocator: mem.Allocator) -> bool {
	delete(owned^, allocator)
	owned^ = ""
	if value == "" { return true }
	cloned, clone_error := strings.clone(value, allocator)
	if clone_error != nil { return false }
	owned^ = cloned
	return true
}

// acp_answer answers a request the agent sent. A permission request is granted once, as a
// native subagent's tools run without asking; nothing else is offered. problem is static
// text, "" when the agent was answered. A reply the writer did not queue leaves the agent
// waiting for it, so it ends the exchange.
@(private, require_results)
acp_answer :: proc(connection: ^ACP_Connection, envelope: acp.Envelope) -> (problem: string) {
	if envelope.method != acp.METHOD_SESSION_REQUEST_PERMISSION {
		if acp.write_error(&connection.writer, envelope.id, acp.ERROR_METHOD_NOT_FOUND, "this client offers no such method") != .None {
			return "the refusal of the agent's unsupported request was not sent"
		}
		return ""
	}
	request: acp.Request_Permission_Params
	switch acp.params_decode(envelope.params, &request, context.temp_allocator) {
	case .None:
	case .Invalid:
		if acp.write_error(&connection.writer, envelope.id, acp.ERROR_INVALID_PARAMS, "the permission request is not what ACP defines") != .None {
			return "the refusal of the agent's malformed permission request was not sent"
		}
		return ""
	case .Allocation:
		return ACP_MESSAGE_NOT_HELD
	}
	outcome := acp.Permission_Outcome {
		outcome = "cancelled",
	}
	if acp_stopped(connection) {
		if acp.write_response(&connection.writer, envelope.id, acp.Request_Permission_Result{outcome = outcome}) != .None {
			return ACP_PERMISSION_REPLY_NOT_SENT
		}
		return ""
	}
	for kind in ([]string{"allow_once", "allow_always"}) {
		for option in request.options {
			if option.kind == kind && outcome.option_id == "" {
				outcome = {
					outcome   = "selected",
					option_id = option.option_id,
				}
			}
		}
	}
	if acp.write_response(&connection.writer, envelope.id, acp.Request_Permission_Result{outcome = outcome}) != .None {
		return ACP_PERMISSION_REPLY_NOT_SENT
	}
	return ""
}

// acp_next returns the next message the agent sent, owned by the member's allocator, reading
// and waiting as needed. A stop sends the agent session/cancel and waits the stop patience
// for its answer; problem says the agent ended, went silent past that, or could not be read.
@(private, require_results)
acp_next :: proc(connection: ^ACP_Connection) -> (envelope: acp.Envelope, problem: string) {
	allocator := connection.member.allocator
	for {
		if frame, taken := acp_frame_take(connection.readers); taken {
			defer delete(frame, allocator)
			parsed, parse_error := acp.parse_envelope(frame, allocator)
			if parse_error == .None { return parsed, "" }
			return {}, fmt.tprintf("the agent sent a message that could not be parsed as JSON-RPC: %s", acp.envelope_error_text(parse_error))
		}
		if wait_problem := acp_wait(connection); wait_problem != "" { return {}, wait_problem }
	}
}

// acp_frame_take removes the oldest frame the reader thread decoded, which the caller then
// owns. The lock is held only for the removal, so decoding and handling happen outside it.
@(private, require_results)
acp_frame_take :: proc(readers: ^ACP_Readers) -> (frame: string, taken: bool) {
	sync.mutex_guard(&readers.mutex)
	return queue.pop_front_safe(&readers.frames)
}

// acp_wait blocks until the agent wrote something or a stop arrived. It returns "" once a
// frame is waiting for acp_frame_take.
@(private, require_results)
acp_wait :: proc(connection: ^ACP_Connection) -> (problem: string) {
	member := connection.member
	readers := connection.readers
	for {
		if service_problem := acp_serve_live(connection); service_problem != "" { return service_problem }

		if ai.interrupt_requested(&member.stop) && !connection.cancel_sent {
			connection.cancel_sent = true
			connection.stop_deadline = time.tick_add(time.tick_now(), TOOL_JOBS_STOP_PATIENCE)
			if connection.session_id == "" { return "the subagent was stopped before its session opened" }
			_ = acp.write_notification(&connection.writer, acp.METHOD_SESSION_CANCEL, acp.Session_Cancel_Params{session_id = connection.session_id})
		}
		ended: bool
		what := "exited"
		{
			sync.mutex_guard(&readers.mutex)
			if queue.len(readers.frames) > 0 { return "" }
			if readers.frame_error != .None {
				return fmt.tprintf("the agent sent a message that could not be read: %s", acp.frame_error_text(readers.frame_error))
			}
			ended = readers.done[.Output] || readers.done[.Process]
			if readers.read_error != nil { what = "could not be read" }
			if readers.wait_error != nil { return fmt.tprintf("the agent could not be waited on: %v", readers.wait_error) }
		}
		if ended {
			_ = acp_readers_wait(readers, false, time.tick_add(time.tick_now(), SUBAGENT_ACP_CLOSE_GRACE))
			{
				sync.mutex_guard(&readers.mutex)
				if queue.len(readers.frames) > 0 { return "" }
			}
			return acp_ended(connection, what)
		}
		if connection.cancel_sent {
			remaining := time.tick_diff(time.tick_now(), connection.stop_deadline)
			if remaining <= 0 { return "the agent did not stop in time and was ended" }
			_ = sync.sema_wait_with_timeout(&member.wake, remaining)
		} else {
			sync.sema_wait(&member.wake)
		}
	}
}

// acp_stderr_retain adds what the agent just wrote and keeps only the most recent
// SUBAGENT_ACP_STDERR_TAIL_BYTES of it. The cut is moved to the next rune start, so the
// retained text stays valid UTF-8.
@(private)
acp_stderr_retain :: proc(tail: ^[dynamic]u8, data: []u8) {
	// A tail that cannot grow keeps what it has; it is diagnostic only.
	if _, append_error := append(tail, ..data); append_error != nil { return }
	excess := len(tail) - SUBAGENT_ACP_STDERR_TAIL_BYTES
	if excess <= 0 { return }
	// A byte with the top bits 10 is the continuation of a rune that the cut would
	// otherwise split, so it is dropped along with the bytes before it.
	for excess < len(tail) && tail[excess] & 0b1100_0000 == 0b1000_0000 { excess += 1 }
	remove_range(tail, 0, excess)
}

// acp_ended says the agent went away, with the end of what it wrote to stderr.
@(private)
acp_ended :: proc(connection: ^ACP_Connection, what: string) -> string {
	readers := connection.readers
	sync.mutex_guard(&readers.mutex)
	tail := strings.trim_space(string(readers.stderr_tail[:]))
	if tail == "" { return fmt.tprintf("the agent %s before it answered", what) }
	return fmt.tprintf("the agent %s before it answered. The end of its stderr:\n%s", what, tail)
}

@(private, require_results)
acp_stopped :: proc(connection: ^ACP_Connection) -> bool {
	return connection.cancel_sent || ai.interrupt_requested(&connection.member.stop)
}
