package agent

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "nabla:agent/journal"
import "nabla:ai"

Subagent_Status :: enum {
	Running,
	Completed,
	Failed,
	Stopped,
}

subagent_status_names := [Subagent_Status]string {
	.Running   = "running",
	.Completed = "completed",
	.Failed    = "failed",
	.Stopped   = "stopped",
}

// The shared harness instructions precede this role and the caller-provided instruction.
SUBAGENT_ROLE :: "You are a subagent. An orchestrator agent started you for one task, stated in the first message, and it reads only your final answer. You do not see the orchestrator's conversation: the task message and what your tools find are all you have. Work with your tools until the task is done, then answer concisely with what the orchestrator needs: findings, decisions, and exact paths and identifiers, without narrating your process. Messages from the orchestrator may arrive while you work; follow them. Use agent_send only when the orchestrator must know something before you finish, such as missing information that blocks the task. You cannot start subagents or reach other subagents."

// Subagent is the orchestrator's record of one subagent. Everything above inbox is fixed
// before the subagent starts and owned by allocator. The subagent's thread writes the outcome
// fields and then done; the orchestrator reads them only after it sees done, and frees the
// record after that, joining the thread first when there is one.
Subagent :: struct {
	name:                         string,
	instruction:                  string,
	prompt:                       string,
	selection:                    Model_Selection,
	program:                      Subagent_Program, // an ACP agent to run instead of a native session
	effort:                       string,
	tools:                        Tool_Registry,
	workspace:                    string,
	store_directory:              string,
	parent_session:               journal.Session_Id,
	parent_call:                  journal.Call_Id, // the orchestrator's call that started it
	session:                      journal.Session_Id, // the child session, named when the start was recorded
	parent_session_hex:           [journal.SESSION_ID_HEX_LENGTH]u8, // read through chat_parent_session
	run:                          journal.Run_Id, // the run the subagent's own journal writes under
	disable_project_instructions: bool,
	background:                   bool,
	log_sink:                     ^Diag_Ring,
	team:                         ^Agent_Team, // the orchestrator's, which outlives every member
	allocator:                    mem.Allocator,

	// inbox holds the orchestrator's messages. closed, guarded by team.mutex, says it takes
	// no more, so a message is either recorded by the subagent or refused to its sender.
	inbox:                        Steer_Queue,
	closed:                       bool,
	abandoned:                    bool,
	// stop ends the subagent's work. It chains to the call that waits for it, or to the
	// process interrupt for a background subagent.
	stop:                         ai.Interrupt,
	// wake is signalled with stop, so a subagent asleep in poll sees it; parent_wake is the
	// wake of the call a blocking subagent runs for, borrowed.
	wake:                         Tool_Wake,
	parent_wake:                  ^os.File,
	thread:                       ^thread.Thread, // background only
	session_id:                   string,
	status:                       Subagent_Status,
	answer:                       string, // the final answer, or why there is none
	done:                         bool, // atomic; set last
}

// Agent_Team is an orchestrator's subagents and the messages they sent it. It is heap-allocated
// apart from its session, because a subagent that does not stop keeps using it.
Agent_Team :: struct {
	mutex:     sync.Mutex,
	members:   [dynamic]^Subagent,
	started:   int,
	starting:  int,
	closing:   bool,
	abandoned: bool,
	inbox:     Steer_Queue,
	allocator: mem.Allocator,
	// parent is what a start copies from the orchestrator. The owner writes it under mutex
	// when it admits a start; tools is the orchestrator's registry, frozen while a turn runs.
	parent:    Agent_Parent,
}

Agent_Parent :: struct {
	session:                      journal.Session_Id,
	run:                          journal.Run_Id,
	workspace:                    string,
	store_directory:              string,
	provider_id:                  string,
	model_id:                     string,
	effort:                       string,
	effort_levels:                []string,
	disable_project_instructions: bool,
	tools:                        Tool_Registry,
	catalog:                      Catalog_Ref,
	acp_agents:                   []ACP_Agent_Config, // borrowed from the loaded config
}

agent_team_make :: proc(allocator: mem.Allocator) -> ^Agent_Team {
	team, alloc_error := new(Agent_Team, allocator)
	if alloc_error != nil { return nil }
	team.allocator = allocator
	team.members = make([dynamic]^Subagent, allocator)
	team.inbox = steer_queue_init(allocator)
	return team
}

@(private)
agent_parent_destroy :: proc(parent: ^Agent_Parent, allocator: mem.Allocator) {
	delete(parent.workspace, allocator)
	delete(parent.store_directory, allocator)
	delete(parent.provider_id, allocator)
	delete(parent.model_id, allocator)
	delete(parent.effort, allocator)
	for level in parent.effort_levels { delete(level, allocator) }
	delete(parent.effort_levels, allocator)
	tool_registry_destroy(&parent.tools)
	parent^ = {}
}

// agent_team_note_parent copies what a subagent start needs from the orchestrator. Owner only.
agent_team_note_parent :: proc(chat: ^Chat_Session) {
	team := chat.team
	if team == nil { return }
	sync.mutex_guard(&team.mutex)
	allocator := team.allocator
	tools, tools_error := tool_registry_clone(&chat.tools, allocator)
	if tools_error.kind != .None { return }
	effort_levels := make([]string, len(chat.effort_levels), allocator)
	for level, index in chat.effort_levels { effort_levels[index] = strings.clone(level, allocator) }
	agent_parent_destroy(&team.parent, allocator)
	directory := chat.store.directory if chat.store != nil else ""
	run := chat.store.run if chat.store != nil else {}
	team.parent = Agent_Parent {
		session                      = chat.session,
		run                          = run,
		workspace                    = strings.clone(chat.workspace, allocator),
		store_directory              = strings.clone(directory, allocator),
		provider_id                  = strings.clone(chat.provider_id, allocator),
		model_id                     = strings.clone(chat.model_id, allocator),
		effort                       = strings.clone(chat.effort, allocator),
		effort_levels                = effort_levels,
		disable_project_instructions = chat.disable_project_instructions,
		tools                        = tools,
		catalog                      = chat.catalog,
		acp_agents                   = chat.acp_agents,
	}
}

// agent_team_reap releases every subagent that is done and, given the orchestrator's
// session, commits each one's subagent.completed there first. Owner only.
agent_team_reap :: proc(team: ^Agent_Team, chat: ^Chat_Session) {
	if team == nil { return }
	finished: [dynamic]^Subagent
	finished.allocator = context.temp_allocator
	sync.mutex_lock(&team.mutex)
	for index := 0; index < len(team.members); {
		member := team.members[index]
		if !sync.atomic_load(&member.done) || member.abandoned {
			index += 1
			continue
		}
		append(&finished, member)
		ordered_remove(&team.members, index)
	}
	sync.mutex_unlock(&team.mutex)
	if chat != nil && chat.store != nil && len(finished) > 0 {
		for member in finished { subagent_record_completion(chat, member) }
		_ = chat_commit(chat, "a subagent's outcome could not be recorded")
	}
	for member in finished {
		if member.thread != nil { thread.destroy(member.thread) }
		subagent_destroy(member)
	}
}

// subagent_record_completion buffers the subagent.completed that closes a member's
// delegation, with its final answer in the body when it completed.
@(private)
subagent_record_completion :: proc(chat: ^Chat_Session, member: ^Subagent) {
	if member.session == {} { return }
	outcome := journal.Tool_Outcome.Tool_Failed
	detail, body := member.answer, ""
	switch member.status {
	case .Completed:
		outcome = .Success
		detail, body = "", member.answer
	case .Stopped:
		outcome = .Cancelled
	case .Failed, .Running:
	}
	chat_record(
		chat,
		{kind = .Subagent_Completed, call = member.parent_call, subagent = member.session},
		journal.Subagent_Completed{outcome = journal.TOOL_OUTCOME_NAMES[outcome], detail = detail},
		transmute([]u8)body,
	)
}

// agent_team_destroy stops every subagent, waits for them within the stop patience, and
// releases the team. A subagent that does not stop keeps the team: both leak, and the
// session is released anyway.
agent_team_destroy :: proc(team: ^Agent_Team, retain := false) -> bool {
	if team == nil { return true }
	sync.mutex_lock(&team.mutex)
	team.closing = true
	for member in team.members { subagent_request_stop(member) }
	sync.mutex_unlock(&team.mutex)
	owner_wake_signal()
	deadline := time.tick_add(time.tick_now(), TOOL_JOBS_STOP_PATIENCE)
	for {
		seen := owner_wake_seen()
		// Teardown commits nothing more; recovery closes what this leaves open.
		agent_team_reap(team, nil)
		if !agent_team_running(team) { break }
		if time.tick_diff(time.tick_now(), deadline) <= 0 {
			log_emit({level = .Error, category = .Agent, event = "subagent.abandoned"})
			return false
		}
		owner_wake_wait(seen, deadline)
	}
	if retain || sync.atomic_load(&team.abandoned) { return false }
	steer_queue_destroy(&team.inbox)
	delete(team.members)
	agent_parent_destroy(&team.parent, team.allocator)
	free(team, team.allocator)
	return true
}

// agent_team_running reports whether a subagent the team started is not yet released.
agent_team_running :: proc(team: ^Agent_Team) -> bool {
	if team == nil { return false }
	sync.mutex_guard(&team.mutex)
	if team.starting > 0 { return true }
	for member in team.members {
		if !sync.atomic_load(&member.done) { return true }
	}
	return false
}

subagent_destroy :: proc(member: ^Subagent) {
	allocator := member.allocator
	delete(member.name, allocator)
	delete(member.instruction, allocator)
	delete(member.prompt, allocator)
	model_selection_destroy(&member.selection, allocator)
	subagent_program_destroy(&member.program, allocator)
	tool_wake_close(&member.wake)
	delete(member.effort, allocator)
	tool_registry_destroy(&member.tools)
	delete(member.workspace, allocator)
	delete(member.store_directory, allocator)
	steer_queue_destroy(&member.inbox)
	delete(member.session_id, allocator)
	delete(member.answer, allocator)
	free(member, allocator)
}

// subagent_start defines one subagent from a start call and adds it to the team. It resolves
// the model, the orchestrator's by default, and the effort, one level below the orchestrator's
// by default. problem, temp-allocated, says why nothing started. Worker thread.
subagent_start :: proc(
	team: ^Agent_Team,
	args: Agent_Spawn_Args,
	call: journal.Call_Id,
	session: journal.Session_Id,
	allocator: mem.Allocator,
) -> (
	member: ^Subagent,
	problem: string,
) {
	sync.mutex_lock(&team.mutex)
	if team.closing {
		sync.mutex_unlock(&team.mutex)
		return nil, "the orchestrator is closing; nothing started"
	}
	team.starting += 1
	parent := team.parent
	tools, tools_error := tool_registry_clone(&parent.tools, allocator)
	parent.provider_id = strings.clone(parent.provider_id, context.temp_allocator)
	parent.model_id = strings.clone(parent.model_id, context.temp_allocator)
	parent.effort = strings.clone(parent.effort, context.temp_allocator)
	levels := make([]string, len(parent.effort_levels), context.temp_allocator)
	for level, index in parent.effort_levels { levels[index] = strings.clone(level, context.temp_allocator) }
	parent.effort_levels = levels
	parent.workspace = strings.clone(parent.workspace, context.temp_allocator)
	parent.store_directory = strings.clone(parent.store_directory, context.temp_allocator)
	sync.mutex_unlock(&team.mutex)

	defer {
		sync.mutex_lock(&team.mutex)
		team.starting -= 1
		sync.mutex_unlock(&team.mutex)
		owner_wake_signal()
	}
	defer tool_registry_destroy(&tools)
	if tools_error.kind != .None { return nil, "the subagent tools could not be copied" }
	for index := len(tools.definitions) - 1; index >= 0; index -= 1 {
		definition := &tools.definitions[index]
		if definition.kind == .Agent_Spawn || definition.kind == .Agent_Stop {
			tool_definition_destroy(definition, tools.allocator)
			ordered_remove(&tools.definitions, index)
		}
	}
	selection: Model_Selection
	program: Subagent_Program
	effort := args.effort
	if args.acp_agent != "" {
		program, problem = subagent_program(args, &parent, allocator)
	} else {
		if len(tools.definitions) == 0 { return nil, "subagents are not available in this session" }
		selection, effort, problem = subagent_select(args, &parent, allocator)
	}
	if problem != "" { return nil, problem }

	member = new(Subagent, allocator)
	if member == nil {
		model_selection_destroy(&selection, allocator)
		subagent_program_destroy(&program, allocator)
		return nil, "the subagent could not be allocated"
	}
	member^ = {
		instruction                  = strings.clone(args.instruction, allocator),
		prompt                       = strings.clone(args.prompt, allocator),
		selection                    = selection,
		program                      = program,
		effort                       = strings.clone(effort, allocator),
		tools                        = tools,
		workspace                    = strings.clone(parent.workspace, allocator),
		store_directory              = strings.clone(parent.store_directory, allocator),
		parent_session               = parent.session,
		parent_call                  = call,
		session                      = session,
		run                          = parent.run,
		disable_project_instructions = parent.disable_project_instructions,
		background                   = args.background,
		log_sink                     = subagent_log_sink(),
		team                         = team,
		allocator                    = allocator,
		inbox                        = steer_queue_init(allocator),
	}
	tools = {}
	if program.name != "" {
		wake, wake_error := tool_wake_open()
		if wake_error != nil {
			subagent_destroy(member)
			return nil, "the subagent's stop signal could not be created"
		}
		member.wake = wake
	}
	sync.mutex_lock(&team.mutex)
	if team.closing {
		sync.mutex_unlock(&team.mutex)
		subagent_destroy(member)
		return nil, "the orchestrator is closing; nothing started"
	}
	team.started += 1
	member.name = fmt.aprintf("agent-%d", team.started, allocator = allocator)
	append(&team.members, member)
	sync.mutex_unlock(&team.mutex)
	return member, ""
}

// subagent_select resolves the model and effort a native subagent runs. problem, temp-allocated,
// says why it cannot run; selection is then empty.
@(private)
subagent_select :: proc(
	args: Agent_Spawn_Args,
	parent: ^Agent_Parent,
	allocator: mem.Allocator,
) -> (
	selection: Model_Selection,
	effort: string,
	problem: string,
) {
	if parent.catalog.catalog == nil { return {}, "", "subagents are not available in this session" }
	{
		if parent.catalog.mutex != nil { sync.mutex_lock(parent.catalog.mutex) }
		defer if parent.catalog.mutex != nil { sync.mutex_unlock(parent.catalog.mutex) }
		provider_id, model_id := args.provider, args.model
		switch {
		case model_id == "" && (provider_id == "" || provider_id == parent.provider_id):
			provider_id, model_id = parent.provider_id, parent.model_id
		case model_id == "":
			return {}, "", fmt.tprintf("name a model of provider %s: %s", provider_id, catalog_model_names(parent.catalog.catalog, provider_id))
		case provider_id == "":
			provider_id, problem = catalog_model_provider(parent.catalog.catalog, model_id, parent.provider_id)
			if problem != "" { return {}, "", problem }
		}
		if model_id == "" { return {}, "", "the orchestrator has no model selected, so name one in model" }
		selection, problem = model_selection_resolve(parent.catalog.catalog, provider_id, model_id, allocator)
		if problem != "" { return {}, "", problem }
	}
	// An effort the model does not state is treated as one left out.
	effort = args.effort
	if effort_level_index(selection.effort_levels, effort) < 0 {
		effort = effort_step_down(parent.effort_levels, selection.effort_levels, parent.effort)
		// A model with other level names still thinks when its orchestrator does.
		if effort == "" && parent.effort != "" && len(selection.effort_levels) > 0 { effort = selection.effort_levels[0] }
	}
	return selection, effort, ""
}

// subagent_log_sink is where the calling thread's diagnostics go, so a subagent's thread
// writes to the same place.
@(private)
subagent_log_sink :: proc() -> ^Diag_Ring {
	return log_active_ring()
}

// subagent_launch starts a background subagent on a thread of its own. The watched signals are
// blocked across creation, so the process handler never runs there.
subagent_launch :: proc(member: ^Subagent) -> bool {
	member.stop.parent = &process_interrupt
	previous := chat_signal_block_watched()
	worker := thread.create(subagent_thread, name = "nabla-subagent")
	chat_signal_restore(previous)
	if worker == nil { return false }
	worker.data = member
	member.thread = worker
	thread.start(worker)
	return true
}

@(private)
subagent_thread :: proc(worker: ^thread.Thread) {
	member := cast(^Subagent)worker.data
	context.allocator = member.allocator
	subagent_run(member)
	subagent_finish(member, report = true)
}

// subagent_finish closes the subagent's inbox, reports its outcome to the orchestrator's inbox
// when asked, and marks it done. It touches nothing after that.
subagent_finish :: proc(member: ^Subagent, report: bool) {
	team := member.team
	sync.mutex_lock(&team.mutex)
	member.closed = true
	sync.mutex_unlock(&team.mutex)
	if report {
		text: string
		switch member.status {
		case .Completed:
			text = fmt.tprintf("Subagent %s completed. Its answer:\n\n%s", member.name, member.answer)
		case .Stopped:
			text = fmt.tprintf("Subagent %s was stopped before it finished.", member.name)
		case .Failed, .Running:
			text = fmt.tprintf("Subagent %s failed: %s", member.name, member.answer)
		}
		if !steer_push(&team.inbox, text) { log_emit({level = .Error, category = .Agent, event = "subagent.report_lost"}) }
	}
	sync.atomic_store(&member.done, true)
	owner_wake_signal()
}

// Subagent_Answer keeps the text of the latest response, which is the final answer once the
// subagent's turn ends.
@(private)
Subagent_Answer :: struct {
	text: [dynamic]u8,
}

@(private)
subagent_answer_restart :: proc(user_data: rawptr) {
	answer := cast(^Subagent_Answer)user_data
	clear(&answer.text)
}

@(private)
subagent_answer_text :: proc(user_data: rawptr, text: string) {
	answer := cast(^Subagent_Answer)user_data
	append(&answer.text, text)
}

@(private)
subagent_fail :: proc(member: ^Subagent, status: Subagent_Status, reason: string) {
	member.status = status
	delete(member.answer, member.allocator)
	member.answer = strings.clone(reason, member.allocator)
}

// subagent_run runs the subagent's session until it answers its task and every message its
// orchestrator sent after that, and records the outcome in member. Runs on the subagent's own
// thread and reaches nothing of the orchestrator's except the team.
subagent_run :: proc(member: ^Subagent) {
	binding := Log_Binding {
		ring = member.log_sink,
	}
	previous_logger := context.logger
	context.logger = log_logger(&binding)
	defer context.logger = previous_logger
	allocator := member.allocator

	if member.program.name != "" {
		subagent_acp_run(member)
		return
	}
	store: journal.Journal
	if open_error := journal.open(&store, member.store_directory, member.run, .Read_Write, allocator); open_error != nil {
		subagent_fail(
			member,
			.Failed,
			fmt.tprintf("the subagent's session store could not be opened: %s", journal.error_text(open_error, context.temp_allocator)),
		)
		return
	}
	// The subagent's session is over when this returns, so the claim the journal
	// holds with it is never released by anyone else.
	defer _ = journal.close(&store)

	session_id, create_error := journal.create_session(
		&store,
		journal.New_Session {
			id = member.session,
			workspace = member.workspace,
			role = .Subagent,
			parent_session = member.parent_session,
			parent_call = member.parent_call,
		},
	)
	if create_error != nil {
		subagent_fail(
			member,
			.Failed,
			fmt.tprintf("the subagent's session could not be created: %s", journal.error_text(create_error, context.temp_allocator)),
		)
		return
	}
	session_hex: [journal.SESSION_ID_HEX_LENGTH]u8
	member.session_id = strings.clone(journal.session_id_to_hex(session_id, session_hex[:]), allocator)

	chat, init_error := chat_session_init(&store, session_id, journal.INITIAL_BRANCH, 0, member.workspace, allocator)
	if init_error.kind != .None {
		subagent_fail(member, .Failed, "the subagent's session could not be initialized")
		return
	}
	defer {
		chat_session_destroy(&chat)
		if chat_session_workers_outstanding(&chat) {
			sync.mutex_guard(&member.team.mutex)
			member.abandoned = true
			sync.atomic_store(&member.team.abandoned, true)
		}
	}
	// A subagent starts no subagents, so its session has no team.
	agent_team_destroy(chat.team)
	chat.team = nil
	chat.member = member
	chat.inbox = &member.inbox
	chat.stop_parent = &member.stop
	chat.disable_project_instructions = member.disable_project_instructions
	chat.role_instructions = strings.concatenate({SUBAGENT_ROLE, "\n\n", member.instruction}, allocator)
	if replace_error := chat_session_replace_tools(&chat, &member.tools); replace_error != .None {
		subagent_fail(member, .Failed, "the subagent's tools could not be installed")
		return
	}
	chat_session_select(&chat, member.selection, member.effort)
	binding.correlation = log_correlation(&chat)

	answer := Subagent_Answer {
		text = make([dynamic]u8, allocator),
	}
	defer delete(answer.text)
	observer := Chat_Observer {
		user_data        = &answer,
		request_prepared = subagent_answer_restart,
		assistant_text   = subagent_answer_text,
	}
	text, origin, from_inbox := member.prompt, journal.User_Origin.Prompt, false
	for {
		accepted := chat_session_accept_message(&chat, text, origin)
		if from_inbox { steer_line_free(&member.inbox, text) }
		if accepted != .Accepted {
			subagent_fail(member, .Failed, chat.last_error if chat.last_error != "" else "the task could not be recorded")
			return
		}
		fields := [3]Log_Field {
			{key = "agent", value = member.name},
			{key = "model", value = member.selection.model_id},
			{key = "effort", value = member.effort},
		}
		log_emit({level = .Info, category = .Agent, event = "subagent.turn_started", fields = fields[:]})
		if !chat_turn_drive(&chat, member.selection.connection, chat_retry_policy_default(), observer, nil, nil) {
			if chat.terminal_status == .Cancelled {
				subagent_fail(member, .Stopped, "the subagent was stopped before it finished")
			} else {
				subagent_fail(member, .Failed, chat.last_error if chat.last_error != "" else "the subagent's turn did not complete")
			}
			return
		}
		// Steering answers every message taken before the turn settled. One that arrived
		// after its last check is taken here, and the inbox closes only when it is empty.
		line, more := subagent_next_message(member)
		if !more { break }
		text, origin, from_inbox = line, .Agent, true
	}
	member.status = .Completed
	member.answer = strings.clone(string(answer.text[:]), allocator)
}

// subagent_next_message takes the oldest message the orchestrator sent, or closes the inbox
// when there is none, in one step, so a message sent at the same moment is either taken here
// or refused to its sender.
@(private)
subagent_next_message :: proc(member: ^Subagent) -> (string, bool) {
	sync.mutex_guard(&member.team.mutex)
	line, ok := steer_pop(&member.inbox)
	if !ok { member.closed = true }
	return line, ok
}

// subagent_find returns the running member named name. The caller holds team.mutex.
@(private)
subagent_find :: proc(team: ^Agent_Team, name: string) -> ^Subagent {
	for member in team.members {
		if member.name == name { return member }
	}
	return nil
}

// subagent_send queues the orchestrator's message for a subagent and returns the child
// session it went to. problem, temp-allocated, says why it was not queued.
subagent_send :: proc(team: ^Agent_Team, name, text: string) -> (session: journal.Session_Id, problem: string) {
	message := fmt.tprintf("Message from the orchestrator:\n%s", text)
	sync.mutex_guard(&team.mutex)
	member := subagent_find(team, name)
	if member == nil { return {}, subagent_unknown(team, name) }
	if member.closed { return {}, fmt.tprintf("%s has finished and takes no more messages", name) }
	if !steer_push(&member.inbox, message) { return {}, "the message could not be allocated" }
	return member.session, ""
}

// subagent_stop asks a subagent to stop. Its outcome reaches the orchestrator like any other.
subagent_stop :: proc(team: ^Agent_Team, name: string) -> (problem: string) {
	defer owner_wake_signal()
	sync.mutex_guard(&team.mutex)
	member := subagent_find(team, name)
	if member == nil { return subagent_unknown(team, name) }
	if member.closed { return fmt.tprintf("%s has already finished", name) }
	subagent_request_stop(member)
	return ""
}

// subagent_request_stop asks a subagent to stop and wakes it. The caller holds team.mutex.
@(private)
subagent_request_stop :: proc(member: ^Subagent) {
	ai.interrupt_request(&member.stop)
	tool_wake_signal(&member.wake)
}

// subagent_unknown names the running subagents for a name that is not one. The caller holds
// team.mutex.
@(private)
subagent_unknown :: proc(team: ^Agent_Team, name: string) -> string {
	names := make([dynamic]string, 0, len(team.members), context.temp_allocator)
	for member in team.members { append(&names, member.name) }
	if len(names) == 0 { return fmt.tprintf("no subagent named %q is running; none is", name) }
	return fmt.tprintf("no subagent named %q is running; running: %s", name, strings.join(names[:], ", ", context.temp_allocator))
}

// subagent_report_message queues a subagent's message for its orchestrator.
subagent_report_message :: proc(member: ^Subagent, text: string) -> bool {
	return steer_push(&member.team.inbox, fmt.tprintf("Message from subagent %s:\n%s", member.name, text))
}

// --- the orchestrator's front-end --------------------------------------------------

// chat_parent_session is the orchestrator's session id for a subagent's session, else "".
chat_parent_session :: proc(chat: ^Chat_Session) -> string {
	if chat.member == nil { return "" }
	return journal.session_id_to_hex(chat.member.parent_session, chat.member.parent_session_hex[:])
}

// chat_agents_pending reports whether a subagent's message waits or a subagent still runs.
// It releases finished subagents first. Owner only.
chat_agents_pending :: proc(chat: ^Chat_Session) -> bool {
	if chat.team == nil { return false }
	agent_team_reap(chat.team, chat)
	return steer_pending(&chat.team.inbox) || agent_team_running(chat.team)
}

// chat_agents_wait blocks until a subagent's message waits, and reports false instead when no
// subagent runs any more or stop is requested. Owner only.
chat_agents_wait :: proc(chat: ^Chat_Session, stop: ^ai.Interrupt) -> bool {
	if chat.team == nil { return false }
	for {
		seen := owner_wake_seen()
		if steer_pending(&chat.team.inbox) { return true }
		if !chat_agents_pending(chat) || ai.interrupt_requested(stop) || ai.interrupt_requested(&process_interrupt) { return false }
		owner_wake_wait(seen, nil)
	}
}

// chat_session_accept_agent_message opens a turn for the oldest message a subagent sent while
// no turn ran. had_message is false when none waits. A message the store refused stays queued.
chat_session_accept_agent_message :: proc(chat: ^Chat_Session, observer: Chat_Observer) -> (accepted: Chat_Accept, had_message: bool) {
	if chat.team == nil { return .Accepted, false }
	text, ok := steer_pop(&chat.team.inbox)
	if !ok { return .Accepted, false }
	accepted = chat_session_accept_message(chat, text, .Agent)
	if accepted == .Accepted {
		_observer_user_text(observer, text)
		steer_line_free(&chat.team.inbox, text)
	} else {
		steer_requeue(&chat.team.inbox, text)
	}
	return accepted, true
}
