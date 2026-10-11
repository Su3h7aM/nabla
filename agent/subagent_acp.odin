package agent

import "base:runtime"
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

// ACP_Input is the agent's stdin. Its descriptor pair comes from acp_input_open.
@(private)
ACP_Input :: struct {
	ours:   ^os.File,
	theirs: ^os.File, // for the child's stdin; closed once the child has it
}

@(private)
acp_input_writer :: proc(input: ^ACP_Input) -> io.Writer {
	return io.Stream{procedure = acp_input_stream, data = input}
}

@(private = "file", require_results)
acp_input_stream :: proc(stream_data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	input := cast(^ACP_Input)stream_data
	#partial switch mode {
	case .Write:
		sent, ok := acp_input_send(input, p)
		if !ok { return i64(sent), .Unexpected_EOF }
		return i64(sent), nil
	case .Query:
		return io.query_utility({.Write, .Query})
	}
	return 0, .Unsupported
}

@(private, require_results)
acp_input_open :: proc() -> (input: ACP_Input, ok: bool) {
	read, write, err := os.pipe()
	if err != nil { return {}, false }
	return {ours = write, theirs = read}, true
}

@(private)
acp_input_close :: proc(input: ^ACP_Input) {
	if input.theirs != nil { _ = os.close(input.theirs) }
	if input.ours != nil { _ = os.close(input.ours) }
	input^ = {}
}

@(private, require_results)
acp_input_send :: proc(input: ^ACP_Input, data: []u8) -> (sent: int, ok: bool) {
	for sent < len(data) {
		taken, err := os.write(input.ours, data[sent:])
		if err != nil || taken == 0 { return sent, false }
		sent += taken
	}
	return sent, true
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
	frames:      [dynamic]string,
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
			if _, append_error := append(&readers.frames, ..frames[:]); append_error != nil {
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
	member:        ^Subagent,
	child:         os.Process,
	started:       bool,
	input:         ^ACP_Input,
	readers:       ^ACP_Readers,
	writer:        acp.Writer,
	frames:        [dynamic]string,
	next_frame:    int,
	next_id:       i64,
	version:       int, // the ACP version the agent agreed to
	session_id:    string,
	opened:        ACP_Session_Opened, // borrowed from the thread's scratch memory
	replaying:     bool,
	answer:        [dynamic]u8, // the text of the agent's latest message since its last tool call
	message_id:    string, // the latest message's id, owned; "" when the agent sends none
	idle:          bool, // version 2: the agent reported its turn over
	stop_reason:   string, // why the turn ended, owned
	cancel_sent:   bool,
	stop_deadline: time.Tick,
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
	frames, frames_error := make([dynamic]string, allocator)
	answer_buffer, answer_error := make([dynamic]u8, allocator)
	if frames_error != nil || answer_error != nil {
		subagent_fail(member, .Failed, "the agent's connection could not be held")
		return
	}
	connection.frames = frames
	connection.answer = answer_buffer
	if problem := acp_connection_open(&connection); problem != "" {
		subagent_fail(member, .Failed, problem)
		return
	}
	if problem := acp_session_open(&connection, member.acp_session); problem != "" {
		subagent_fail(member, acp_stopped(&connection) ? .Stopped : .Failed, problem)
		return
	}
	session_text, session_error := strings.clone(connection.session_id, allocator)
	if session_error != nil {
		subagent_fail(member, .Failed, "the agent's session id could not be held")
		return
	}

	{
		sync.mutex_guard(&member.team.mutex)
		delete(member.acp_session, allocator)
		member.acp_session = session_text
	}

	// The program has no Nabla session, so what the orchestrator sends it is read from the
	// orchestrator's journal records, through a connection of its own.
	store, store_open_error := journal.open(member.store_directory, member.lock_directory, member.run, .Read_Only, allocator)
	if store_open_error != nil {
		subagent_fail(
			member,
			.Failed,
			fmt.tprintf("the subagent's inbox could not be opened: %s", journal.error_text(store_open_error, context.temp_allocator)),
		)
		return
	}
	// Nothing is written through it, so a close that fails changes nothing.
	defer _ = journal.close(store)

	text := member.prompt
	if !member.resumed && member.instruction != "" { text = strings.concatenate({member.instruction, "\n\n", member.prompt}, context.temp_allocator) }
	// text is a copy this loop releases once its prompt is answered, after the first.
	owned := false
	after := member.acp_after
	if member.resumed {
		records, read_error := journal.read_inbox(store, member.session, after, context.temp_allocator)
		if read_error != nil { subagent_fail(member, .Failed, "the subagent's inbox could not be read"); return }
		if len(records) > 0 {
			after = records[len(records) - 1].seq
			lines, lines_error := make([]string, len(records), context.temp_allocator)
			if lines_error != nil { subagent_fail(member, .Failed, "the orchestrator's message could not be held"); return }
			for record, index in records { lines[index], _ = inbox_text(record) }
			joined, join_error := strings.join(lines, "\n\n", allocator)
			if join_error != nil { subagent_fail(member, .Failed, "the orchestrator's message could not be held"); return }
			text, owned = joined, true
		}
	}
	loop: for {
		// Each prompt releases the temp memory its answers were decoded into.
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		if problem := acp_control_apply(&connection); problem != "" {
			if owned { delete(text, allocator) }
			subagent_fail(member, .Failed, problem); return
		}
		stop_reason, problem := acp_prompt(&connection, text)
		if owned { delete(text, allocator) }
		owned = false
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
		if problem = acp_control_apply(&connection); problem != "" {
			subagent_fail(member, .Failed, problem)
			return
		}
		records, read_error := journal.read_inbox(store, member.session, after, context.temp_allocator)
		if read_error != nil {
			subagent_fail(member, .Failed, "the subagent's inbox could not be read")
			return
		}
		if len(records) == 0 { break loop }
		after = records[len(records) - 1].seq
		lines, lines_error := make([]string, len(records), context.temp_allocator)
		if lines_error != nil { subagent_fail(member, .Failed, "the orchestrator's message could not be held"); return }
		for record, index in records { lines[index], _ = inbox_text(record) }
		joined, join_error := strings.join(lines, "\n\n", allocator)
		if join_error != nil {
			subagent_fail(member, .Failed, "the orchestrator's message could not be held")
			return
		}
		text, owned = joined, true
	}
	// An answer that cannot be held is not the answer the orchestrator asked for, so the
	// outcome says the delegation failed rather than reporting none as a completion.
	answer_text, clone_error := strings.clone(string(connection.answer[:]), allocator)
	if clone_error != nil {
		subagent_fail(member, .Failed, "the agent's answer could not be held")
		return
	}
	member.acp_after = after
	member.status = .Completed
	member.answer = answer_text
}

// acp_prompt sends one prompt and waits until the agent's turn is over. Version 1 ends the turn
// with the prompt's answer; version 2 acknowledges the prompt and reports the end as an idle
// state update. stop_reason is the agent's, temp-allocated.
@(private, require_results)
acp_prompt :: proc(connection: ^ACP_Connection, text: string) -> (stop_reason: string, problem: string) {
	Text_Block :: struct {
		type: string `json:"type"`,
		text: string `json:"text"`,
	}
	Prompt :: struct {
		session_id: string `json:"sessionId"`,
		prompt:     []Text_Block `json:"prompt"`,
	}
	clear(&connection.answer)
	// Both resets pass an empty value, so neither can fail.
	_ = acp_replace(&connection.message_id, "", connection.member.allocator)
	_ = acp_replace(&connection.stop_reason, "", connection.member.allocator)
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
		followed := acp_handle(connection, envelope)
		acp.destroy_envelope(&envelope, connection.member.allocator)
		if !followed { return "", "the agent's message could not be held" }
	}
	// An agent that states no reason ended its turn normally.
	if connection.stop_reason == "" { return "end_turn", "" }
	reason, clone_error := strings.clone(connection.stop_reason, context.temp_allocator)
	if clone_error != nil { return "", "the agent's stop reason could not be held" }
	return reason, ""
}

// acp_connection_open starts the agent program with its three standard streams piped here.
@(private, require_results)
acp_connection_open :: proc(connection: ^ACP_Connection) -> (problem: string) {
	member := connection.member
	opened_input, input_ok := acp_input_open()
	if !input_ok { return "the agent's input could not be created; nothing ran" }
	input, input_error := new(ACP_Input, member.allocator)
	if input_error != nil {
		acp_input_close(&opened_input)
		return "the agent's input could not be held; nothing ran"
	}
	input^ = opened_input
	connection.input = input
	readers, readers_error := new(ACP_Readers, member.allocator)
	if readers_error != nil { return "the agent's readers could not be held; nothing ran" }
	connection.readers = readers
	readers.allocator = member.allocator
	readers.wake = &member.wake
	readers.frames.allocator = member.allocator
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
	child, spawn_error := os.process_start(
		{command = argv, working_dir = member.workspace, stdin = input.theirs, stdout = output_write, stderr = errors_write},
	)
	if spawn_error != nil { return fmt.tprintf("%s could not be started: %v; nothing ran", member.program.command, spawn_error) }
	connection.child = child
	connection.started = true
	readers.process = child
	_ = os.close(input.theirs)
	input.theirs = nil
	writer, writer_error := acp.writer_init(acp_input_writer(input), member.allocator)
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
	if writer_retired && connection.input != nil && connection.input.ours != nil {
		_ = os.close(connection.input.ours)
		connection.input.ours = nil
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
	if writer_retired && connection.input != nil {
		acp_input_close(connection.input)
		free(connection.input, connection.member.allocator)
	} else if !writer_retired {
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
			for frame in readers.frames { delete(frame, readers.allocator) }
			delete(readers.frames)
			delete(readers.stderr_tail)
			acp.frame_decoder_destroy(&readers.decoder)
			free(readers, connection.member.allocator)
		} else {
			subagent_fail(connection.member, .Failed, "the agent's transport worker did not retire; its outcome is unknown and its resources were retained")
		}
	}
	for frame in connection.frames { delete(frame, connection.member.allocator) }
	delete(connection.frames)
	delete(connection.session_id, connection.member.allocator)
	delete(connection.message_id, connection.member.allocator)
	delete(connection.stop_reason, connection.member.allocator)
	delete(connection.answer)
	connection^ = {}
}

// acp_session_open initializes the connection, opens a new session or continues previous_session,
// and chooses the model and effort among what the agent offers.
@(private, require_results)
acp_session_open :: proc(connection: ^ACP_Connection, previous_session := "") -> (problem: string) {
	session_id := previous_session
	member := connection.member
	// Version 2 names the client in info; a version 1 agent answers with its own version and
	// reads the missing clientCapabilities as no file system and no terminal.
	Initialize :: struct {
		protocol_version: int `json:"protocolVersion"`,
		capabilities:     struct{} `json:"capabilities"`,
		info:             acp.Implementation `json:"info"`,
	}
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
		mcp_servers: []acp.MCP_Server `json:"mcpServers"`,
	}
	opened: ACP_Session_Opened
	if session_id == "" {
		if problem = acp_call(connection, acp.METHOD_SESSION_NEW, New_Session{cwd = member.workspace}, &opened); problem != "" { return }
		if opened.session_id == "" { return "the agent opened a session without an id" }
		session_id = opened.session_id
	} else {
		method := acp.METHOD_SESSION_RESUME
		_, supports_resume := initialized.agent_capabilities.session_capabilities.resume.(json.Object)
		if connection.version == 1 && !supports_resume {
			if !initialized.agent_capabilities.load_session { return "the ACP agent advertises neither sessionCapabilities.resume nor loadSession; its session cannot be resumed" }
			method = acp.METHOD_SESSION_LOAD
		}
		Resume :: struct {
			session_id:  string `json:"sessionId"`,
			cwd:         string `json:"cwd"`,
			mcp_servers: []acp.MCP_Server `json:"mcpServers"`,
		}
		connection.replaying = true
		problem = acp_call(connection, method, Resume{session_id = session_id, cwd = member.workspace}, &opened)
		connection.replaying = false
		if problem != "" { return }
	}
	connection.session_id = strings.clone(session_id, member.allocator) or_else ""
	if connection.session_id == "" { return "the agent's session id could not be held" }
	connection.opened = opened
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
	if option, found := acp_option(opened.config_options, ACP_OPTION_CATEGORY_EFFORT); found && (default_effort || requested_effort != "") {
		levels, levels_error := make([]string, len(option.options), context.temp_allocator)
		if levels_error != nil { return "the agent's effort levels could not be held" }
		for choice, index in option.options { levels[index] = choice.value }
		effort := acp_option_value(option, requested_effort)
		if effort == "" { effort = effort_step_down(member.program.parent_levels, levels, member.program.parent_effort) }
		if effort != "" {
			if problem = acp_set_option(connection, option, effort); problem != "" { return }
		}
	}
	return ""
}

@(private, require_results)
acp_control_apply :: proc(connection: ^ACP_Connection) -> (problem: string) {
	member := connection.member
	control: Subagent_Control
	{
		sync.mutex_guard(&member.team.mutex)
		control = member.control
		member.control = {}
	}
	defer subagent_control_destroy(&control)
	if !control.switching { return "" }
	if refused := acp_session_configure(connection, connection.opened, control.acp_model, control.effort, false); refused != "" {
		text := fmt.tprintf("%s asks:\nYour request to switch model or effort was not applied: %s", member.name, refused)
		// The ACP child owns no journal session. Feedback enters the parent's inbox as agent input.
		sender, sender_open_error := journal.open(member.store_directory, member.lock_directory, member.run, .Read_Write, member.allocator)
		if sender_open_error != nil { return "the refusal of a model switch could not be recorded" }
		defer _ = journal.close(sender)
		if follow_error := journal.follow(sender, member.parent_session); follow_error != nil { return "the refusal of a model switch could not be recorded" }
		if append_error := journal.append_input(sender, text, .Agent); append_error != nil { return "the refusal of a model switch could not be recorded" }

		owner_wake_signal()
		return ""
	}

	{
		sync.mutex_guard(&member.team.mutex)
		if control.acp_model != "" {
			delete(member.program.model, member.allocator)
			member.program.model = control.acp_model
			control.acp_model = ""
		}
		if control.effort != "" {
			delete(member.effort, member.allocator)
			member.effort = control.effort
			control.effort = ""
		}
	}
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
	if !acp.writer_write_request(&connection.writer, id, method, params) { return acp_ended(connection, "stopped reading its input") }
	for {
		envelope, next_problem := acp_next(connection)
		if next_problem != "" { return next_problem }
		defer acp.destroy_envelope(&envelope, connection.member.allocator)
		switch envelope.kind {
		case .Response:
			answered, is_number := envelope.id.(i64)
			if !is_number || answered != id { continue }
			if envelope.rpc_error != nil {
				rpc_error := envelope.rpc_error.?
				return fmt.tprintf("the agent refused %s: %s", method, rpc_error.message)
			}
			if _, is_null := envelope.result.(json.Null); is_null { return "" }
			switch acp.params_decode(envelope.result, result, context.temp_allocator) {
			case .None:
			case .Invalid:
				return fmt.tprintf("the agent's answer to %s is not what ACP defines", method)
			case .Allocation:
				return fmt.tprintf("the agent's answer to %s could not be held because allocation failed", method)
			}
			return ""
		case .Notification, .Request, .Invalid:
			if !acp_handle(connection, envelope) { return "the agent's message could not be held" }
		}
	}
}

// acp_handle acts on a message that answers nothing this client asked. It reports false when
// what the message carries could not be held, which ends the connection rather than letting
// the answer or the stop reason go missing.
@(private, require_results)
acp_handle :: proc(connection: ^ACP_Connection, envelope: acp.Envelope) -> bool {
	// What a message is decoded into is released with it, so a long turn holds no scratch.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	#partial switch envelope.kind {
	case .Notification:
		return acp_notification(connection, envelope)
	case .Request:
		return acp_answer(connection, envelope)
	}
	return true
}

// acp_notification follows the agent's latest message and, in version 2, the end of its turn.
// Text before a tool call is narration, so a tool call starts the answer over, and so does a
// message with a new id. It reports false when what it followed could not be held.
@(private, require_results)
acp_notification :: proc(connection: ^ACP_Connection, envelope: acp.Envelope) -> bool {
	if connection.replaying || envelope.method != acp.NOTIFICATION_SESSION_UPDATE { return true }
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
		if state.update.state != "idle" { return true }
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
// native subagent's tools run without asking; nothing else is offered.
@(private, require_results)
acp_answer :: proc(connection: ^ACP_Connection, envelope: acp.Envelope) -> bool {
	// A write to the agent that fails ends the exchange: the next read reports it.
	if envelope.method != acp.METHOD_SESSION_REQUEST_PERMISSION {
		_ = acp.writer_write_error(&connection.writer, envelope.id, acp.ERROR_METHOD_NOT_FOUND, "this client offers no such method")
		return true
	}
	request: acp.Request_Permission_Params
	switch acp.params_decode(envelope.params, &request, context.temp_allocator) {
	case .None:
	case .Invalid:
		_ = acp.writer_write_error(&connection.writer, envelope.id, acp.ERROR_INVALID_PARAMS, "the permission request is not what ACP defines")
		return true
	case .Allocation:
		return false
	}
	outcome := acp.Permission_Outcome {
		outcome = "cancelled",
	}
	if acp_stopped(connection) {
		_ = acp.writer_write_response(&connection.writer, envelope.id, acp.Request_Permission_Result{outcome = outcome})
		return true
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
	_ = acp.writer_write_response(&connection.writer, envelope.id, acp.Request_Permission_Result{outcome = outcome})
	return true
}

// acp_next returns the next message the agent sent, owned by the member's allocator, reading
// and waiting as needed. A stop sends the agent session/cancel and waits the stop patience
// for its answer; problem says the agent ended, went silent past that, or could not be read.
@(private, require_results)
acp_next :: proc(connection: ^ACP_Connection) -> (envelope: acp.Envelope, problem: string) {
	for {
		for connection.next_frame < len(connection.frames) {
			frame := connection.frames[connection.next_frame]
			connection.next_frame += 1
			parsed, parse_error := acp.parse_envelope(frame, connection.member.allocator)
			if parse_error == .None { return parsed, "" }
			return {}, fmt.tprintf("the agent sent a message that could not be parsed as JSON-RPC: %s", acp.envelope_error_text(parse_error))
		}
		for frame in connection.frames { delete(frame, connection.member.allocator) }
		clear(&connection.frames)
		connection.next_frame = 0
		if wait_problem := acp_wait(connection); wait_problem != "" { return {}, wait_problem }
	}
}

// acp_wait blocks until the agent wrote something or a stop arrived, and reads what came.
@(private, require_results)
acp_wait :: proc(connection: ^ACP_Connection) -> (problem: string) {
	member := connection.member
	readers := connection.readers
	for {
		if ai.interrupt_requested(&member.stop) && !connection.cancel_sent {
			connection.cancel_sent = true
			connection.stop_deadline = time.tick_add(time.tick_now(), TOOL_JOBS_STOP_PATIENCE)
			if connection.session_id == "" { return "the subagent was stopped before its session opened" }
			_ = acp.writer_write_notification(&connection.writer, acp.SESSION_CANCEL, acp.Session_Cancel_Params{session_id = connection.session_id})
		}
		ended: bool
		what := "exited"
		{
			sync.mutex_guard(&readers.mutex)
			if len(readers.frames) > 0 {
				connection.frames, readers.frames = readers.frames, connection.frames
				return ""
			}
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
				if len(readers.frames) > 0 {
					connection.frames, readers.frames = readers.frames, connection.frames
					return ""
				}
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
