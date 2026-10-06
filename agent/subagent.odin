package agent

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "nabla:agent/journal"
import "nabla:ai"

// SUBAGENTS_MAX_RUNNING is how many subagents run at once, native and ACP together. It is a
// concurrency default, not a refusal: the `subagents_max_running` configuration option replaces
// it. A background subagent started past the bound queues and starts when a running one
// finishes, and a blocking subagent always runs on its caller's worker.
SUBAGENTS_MAX_RUNNING :: 4

Subagent_Status :: enum {
	Running,
	Completed,
	Failed,
	Stopped,
	Queued,
}

subagent_status_names := [Subagent_Status]string {
	.Running   = "running",
	.Completed = "completed",
	.Failed    = "failed",
	.Stopped   = "stopped",
	.Queued    = "queued",
}

// The shared harness instructions precede this role and the caller-provided instruction.
SUBAGENT_ROLE :: "You are a subagent. An orchestrator agent started you for one task, stated in the first message, and it reads only your final answer. You do not see the orchestrator's conversation: the task message and what your tools find are all you have.\n\nStay inside the task. Do what it asks and return what it asks for; do not fix, refactor, or investigate beyond it, even when you notice something nearby, and mention such things in one line of your answer instead. Work with your tools until the task is done, then answer concisely with exactly what the task asked you to return: findings, decisions, and exact paths, line numbers, and identifiers. Do not narrate your process or paste file contents the task did not ask for.\n\nThe orchestrator may message you while you work. Its messages start with \"Message from the orchestrator\" and override the original task where they conflict. Use agent_send, leaving agent out, to reach the orchestrator before you finish when information you need is missing or ambiguous, when the task rests on a wrong premise, or when you find something it should act on now. Ask rather than guess on a decision that would change the result. After sending, keep working on what does not depend on the reply; the reply arrives as a message between your steps. If nothing is left that you can do without it, finish with an answer that states what you found and what is missing. You cannot start subagents or reach other subagents; the orchestrator relays between you when needed.\n\nYou share the workspace with the orchestrator and possibly other subagents working at the same time. Edit only the files your task covers. Do not revert, reformat, or overwrite changes you did not make, and do not run commands that discard work you did not do, such as resetting version control, checking out files, or deleting files you did not create. If a change you did not make is in your way, or your task needs a file outside its scope, ask the orchestrator with agent_send instead of acting."

// Subagent is the orchestrator's record of one running or just finished subagent. Everything
// above admitted is fixed before the subagent starts and owned by allocator. The subagent's
// thread writes the outcome fields and then done; the orchestrator reads them only after it
// sees done, and then frees the record, joining the thread first when there is one, or runs
// the same record again when a message arrived too late for the run that just ended.
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
	lock_directory:               string,
	parent_session:               journal.Session_Id,
	parent_call:                  journal.Call_Id, // the orchestrator's call that started it
	session:                      journal.Session_Id, // the child session, named when the start was recorded
	parent_session_hex:           [journal.SESSION_ID_HEX_LENGTH]u8, // read through chat_parent_session
	run:                          journal.Run_Id, // the run the subagent's own journal writes under
	disable_project_instructions: bool,
	background:                   bool, // delivers its outcome to the orchestrator's inbox rather than as a call's result
	resumed:                      bool, // its session exists: subagent_run claims and continues it instead of creating it
	compact:                      bool, // a resumed child compacts its context first; with no prompt it ends once the summary is installed
	team:                         ^Agent_Team, // the orchestrator's, which outlives every member
	allocator:                    mem.Allocator,
	// control is what the orchestrator asked of the running child since the child last looked,
	// guarded by team.mutex; selection and effort are also written under it when the child
	// installs a switch. retired holds the selections a switch replaced, which a request or a
	// summary in flight may still read, until the member is destroyed.
	control:                      Subagent_Control,
	retired:                      [dynamic]Model_Selection,
	admitted:                     bool, // holds one of team.running's slots; guarded by team.mutex
	abandoned:                    bool,
	// stop ends the subagent's work. It chains to the call that waits for it, or to the
	// process interrupt for a background subagent.
	stop:                         ai.Interrupt,
	// wake is signalled with stop, so a subagent asleep in poll sees it; parent_wake is the
	// wake of the call a blocking subagent runs for, borrowed.
	wake:                         Tool_Wake,
	parent_wake:                  ^os.File,
	thread:                       ^thread.Thread, // background only
	acp_after:                    journal.Journal_Seq,
	acp_session:                  string, // the ACP agent's own session id; "" for a native subagent, whose session is session
	status:                       Subagent_Status,
	cause:                        string, // why the subagent did not complete; "" once it completed
	answer:                       string, // the text of its last committed answer, partial when it failed or was stopped mid-answer
	done:                         bool, // atomic; set last
}

// Subagent_Control is the newest thing the orchestrator asked of a running child: a switch of
// provider, model, and effort, already resolved so a name that does not exist was refused at
// dispatch, and a compaction. Its selection and effort are owned by allocator.
Subagent_Control :: struct {
	acp_model: string,
	selection: Model_Selection,
	effort:    string,
	switching: bool,
	compact:   bool,
	allocator: mem.Allocator,
}

// subagent_control_destroy releases the switch a control holds, if any.
subagent_control_destroy :: proc(control: ^Subagent_Control) {
	if control.switching {
		delete(control.acp_model, control.allocator)
		model_selection_destroy(&control.selection, control.allocator)
		delete(control.effort, control.allocator)
	}
	control^ = {}
}

// Agent_Team is an orchestrator's subagents. It is heap-allocated apart from its session,
// because a subagent that does not stop keeps using it.
Agent_Team :: struct {
	mutex:     sync.Mutex,
	members:   [dynamic]^Subagent,
	starting:  int,
	running:   int, // slots in use: running children, which a blocking child may take past the configured bound
	waiting:   [dynamic]^Subagent, // background children queued for a slot, oldest first
	closing:   bool,
	abandoned: bool,
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
	lock_directory:               string,
	provider_id:                  string,
	model_id:                     string,
	effort:                       string,
	effort_levels:                []string,
	disable_project_instructions: bool,
	subagents_max_running:        int, // zero means SUBAGENTS_MAX_RUNNING
	compact_on_switch:            bool,
	tools:                        Tool_Registry,
	catalog:                      Catalog_Ref,
	acp_agents:                   []ACP_Agent_Config, // borrowed from the loaded config
}

@(require_results)
agent_team_make :: proc(allocator: mem.Allocator) -> ^Agent_Team {
	team, alloc_error := new(Agent_Team, allocator)
	if alloc_error != nil { return nil }
	team.allocator = allocator
	team.members.allocator = allocator
	team.waiting.allocator = allocator
	return team
}

@(private)
agent_parent_destroy :: proc(parent: ^Agent_Parent, allocator: mem.Allocator) {
	delete(parent.workspace, allocator)
	delete(parent.store_directory, allocator)
	delete(parent.lock_directory, allocator)
	delete(parent.provider_id, allocator)
	delete(parent.model_id, allocator)
	delete(parent.effort, allocator)
	for level in parent.effort_levels { delete(level, allocator) }
	delete(parent.effort_levels, allocator)
	tool_registry_destroy(&parent.tools)
	parent^ = {}
}

// agent_team_note_parent copies what a subagent start needs from the orchestrator. A copy
// that cannot be held leaves the team with no parent at all, so a start is refused rather
// than run against a half-copied orchestrator. Owner only.
agent_team_note_parent :: proc(chat: ^Chat_Session) {
	team := chat.team
	if team == nil { return }
	held: bool
	{
		sync.mutex_guard(&team.mutex)
		allocator := team.allocator
		parent: Agent_Parent
		held = agent_parent_copy(chat, allocator, &parent)
		agent_parent_destroy(&team.parent, allocator)
		if held { team.parent = parent }
	}
	// The journal write stays outside the team lock.
	if !held { chat_runtime_message(chat, .Error, "the orchestrator could not be copied, so subagent starts are refused") }
}

// agent_parent_copy copies what a subagent start needs from the orchestrator into out. It
// reports false when a field could not be copied, in which case out holds nothing.
@(private, require_results)
agent_parent_copy :: proc(chat: ^Chat_Session, allocator: mem.Allocator, out: ^Agent_Parent) -> bool {
	failed := true
	defer if failed { agent_parent_destroy(out, allocator) }
	tools, tools_error := tool_registry_clone(&chat.tools, allocator)
	if tools_error.kind != .None { return false }
	out.tools = tools
	source := Agent_Parent {
		workspace       = chat.workspace,
		store_directory = chat.store.directory if chat.store != nil else "",
		lock_directory  = chat.store.locks if chat.store != nil else "",
		provider_id     = chat.provider_id,
		model_id        = chat.model_id,
		effort          = chat.effort,
		effort_levels   = chat.effort_levels[:],
	}
	if agent_parent_clone_strings(source, out, allocator) != nil { return false }
	out.session = chat.session
	if chat.store != nil { out.run = chat.store.run }
	out.disable_project_instructions = chat.disable_project_instructions
	out.subagents_max_running = chat.subagents_max_running
	out.compact_on_switch = chat.compact_on_switch
	out.catalog = chat.catalog
	out.acp_agents = chat.acp_agents
	failed = false
	return true
}

@(private, require_results)
agent_parent_clone_strings :: proc(parent: Agent_Parent, out: ^Agent_Parent, allocator: mem.Allocator) -> mem.Allocator_Error {
	out.workspace = strings.clone(parent.workspace, allocator) or_return
	out.store_directory = strings.clone(parent.store_directory, allocator) or_return
	out.lock_directory = strings.clone(parent.lock_directory, allocator) or_return
	out.provider_id = strings.clone(parent.provider_id, allocator) or_return
	out.model_id = strings.clone(parent.model_id, allocator) or_return
	out.effort = strings.clone(parent.effort, allocator) or_return
	out.effort_levels = model_selection_clone_levels(parent.effort_levels, allocator) or_return
	return nil
}

// agent_parent_temp_copy copies one parent snapshot into scratch memory, so a worker thread
// can keep using it after it releases the team lock. It returns an allocator error when a
// field could not be copied.
@(private, require_results)
agent_parent_temp_copy :: proc(parent: Agent_Parent, allocator: mem.Allocator) -> (snapshot: Agent_Parent, error: mem.Allocator_Error) {
	copied := parent
	agent_parent_clone_strings(parent, &copied, allocator) or_return
	return copied, nil
}

// agent_team_reap releases every subagent that is done and, given the orchestrator's
// session, commits each one's subagent.completed there first. A background child that
// completed while a message to it still waits unread is run again instead, with no
// completion (see subagent_reopen), and reopened says so. A child whose workers are still
// outstanding is recorded and removed but not freed, because they may still reach it.
// Owner only.
agent_team_reap :: proc(team: ^Agent_Team, chat: ^Chat_Session) -> (reopened: bool) {
	if team == nil { return false }
	finished: [dynamic]^Subagent
	finished.allocator = context.temp_allocator
	{
		sync.mutex_guard(&team.mutex)
		for index := 0; index < len(team.members); {
			member := team.members[index]
			if !sync.atomic_load(&member.done) {
				index += 1
				continue
			}
			if _, append_error := append(&finished, member); append_error != nil {
				// The list of finished members could not grow; they are reaped next time.
				break
			}
			ordered_remove(&team.members, index)
		}
	}
	if chat != nil && chat.store != nil {
		for index := 0; index < len(finished); {
			if subagent_reopen(chat, finished[index]) {
				ordered_remove(&finished, index)
				reopened = true
				continue
			}
			index += 1
		}
		if len(finished) > 0 {
			for member in finished { subagent_record_completion(chat, member) }
			// A commit that fails records the failure on the session, which is what the next
			// turn reports; there is nothing this reap can do with it here.
			_ = chat_commit(chat, "a subagent's outcome could not be recorded")
		}
	}
	for member in finished {
		if member.thread != nil {
			thread.destroy(member.thread)
			member.thread = nil
		}
		if !member.abandoned { subagent_destroy(member) }
	}
	return reopened
}

// subagent_reopen runs member again, on the same record, when it completed in the
// background while a message to it waits unread in its inbox: the message arrived after the
// run's last read, and a child that finished is otherwise never read again. It reports
// whether it did. A child that failed, was stopped, answered a call as a blocking one, or
// left workers outstanding is not reopened; its message stays in the journal
// for its next resume. Owner only.
@(private, require_results)
subagent_reopen :: proc(chat: ^Chat_Session, member: ^Subagent) -> bool {
	if member.status != .Completed || !member.background || member.abandoned { return false }
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	delivered := member.acp_after
	if member.program.name == "" {
		latest, delivered_error := journal.last_delivered_message(chat.store, member.session)
		if delivered_error != nil { return false }
		delivered = latest
	}
	waiting, read_error := journal.read_inbox(chat.store, member.session, delivered, context.temp_allocator)
	if read_error != nil || len(waiting) == 0 { return false }
	team := member.team
	{
		sync.mutex_guard(&team.mutex)
		if _, append_error := append(&team.members, member); append_error != nil { return false }
	}
	if member.thread != nil {
		thread.destroy(member.thread)
		member.thread = nil
	}
	delete(member.answer, member.allocator)
	member.answer = ""
	member.resumed = true
	member.stop = {}
	member.status = .Running
	sync.atomic_store(&member.done, false)
	if _, launched := subagent_launch(member); !launched {
		subagent_fail(member, .Failed, "its thread could not be created")
		subagent_finish(member)
	}
	return true
}

// subagent_record_completion buffers the subagent.completed that closes a member's
// delegation: the outcome, the cause in detail, and the text of its last committed answer
// in the body, partial when it did not complete.
@(private)
subagent_record_completion :: proc(chat: ^Chat_Session, member: ^Subagent) {
	if member.session == {} { return }
	outcome := journal.Tool_Outcome.Tool_Failed
	switch member.status {
	case .Completed:
		outcome = .Success
	case .Stopped:
		outcome = .Cancelled
	case .Failed, .Running, .Queued:
	}
	chat_record(
		chat,
		{kind = .Subagent_Completed, call = member.parent_call, subagent = member.session},
		journal.Subagent_Completed {
			outcome = journal.TOOL_OUTCOME_NAMES[outcome],
			detail = member.cause,
			name = member.name,
			acp_session = member.acp_session,
			acp_after = member.acp_after,
			acp_model = member.program.model,
			acp_effort = member.effort if member.program.name != "" else "",
		},
		transmute([]u8)member.answer,
	)
}

// agent_team_destroy stops every subagent, waits for them within the stop patience, and
// releases the team. A subagent that does not stop keeps the team: both leak, and the
// session is released anyway. Each such subagent is recorded as abandoned in chat's
// journal, so the owner of that journal is the only caller.
agent_team_destroy :: proc(team: ^Agent_Team, chat: ^Chat_Session, retain := false) -> bool {
	if team == nil { return true }
	{
		sync.mutex_guard(&team.mutex)
		team.closing = true
		for member in team.members { subagent_request_stop(member) }
	}
	subagent_stop_waiting(team)
	owner_wake_signal()
	began := time.tick_now()
	deadline := time.tick_add(began, TOOL_JOBS_STOP_PATIENCE)
	for {
		seen := owner_wake_seen()
		// Observe completion before the reap so exiting cannot leave an unreaped member.
		running := agent_team_running(team)
		// Teardown commits nothing more; recovery closes what this leaves open.
		agent_team_reap(team, nil)
		if !running { break }
		if time.tick_diff(time.tick_now(), deadline) <= 0 {
			subagent_record_abandoned(team, chat, time.tick_since(began))
			return false
		}
		owner_wake_wait(seen, deadline)
	}
	if retain || sync.atomic_load(&team.abandoned) { return false }
	delete(team.members)
	delete(team.waiting)
	agent_parent_destroy(&team.parent, team.allocator)
	free(team, team.allocator)
	return true
}

// subagent_record_abandoned buffers job.abandoned for every subagent still running, named
// by its parent's call and its own session. Owner only.
@(private)
subagent_record_abandoned :: proc(team: ^Agent_Team, chat: ^Chat_Session, waited: time.Duration) {
	Running :: struct {
		parent_call: journal.Call_Id,
		session:     journal.Session_Id,
	}
	running := make([dynamic]Running, context.temp_allocator)
	{
		sync.mutex_guard(&team.mutex)
		for member in team.members {
			if sync.atomic_load(&member.done) { continue }
			append(&running, Running{parent_call = member.parent_call, session = member.session})
		}
	}
	for member in running {
		chat_record_job_abandoned(chat, {call = member.parent_call, subagent = member.session}, .Subagent, waited)
	}
}

// agent_team_running reports whether a subagent the team started is not yet released.
@(require_results)
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
	subagent_control_destroy(&member.control)
	for &retired in member.retired { model_selection_destroy(&retired, allocator) }
	delete(member.retired)
	subagent_program_destroy(&member.program, allocator)
	tool_wake_close(&member.wake)
	delete(member.effort, allocator)
	tool_registry_destroy(&member.tools)
	delete(member.workspace, allocator)
	delete(member.store_directory, allocator)
	delete(member.lock_directory, allocator)
	delete(member.acp_session, allocator)
	delete(member.cause, allocator)
	delete(member.answer, allocator)
	free(member, allocator)
}

// subagent_name is the id the orchestrator's model knows the child by: it names the
// spawn call, so the same call has the same name in every process. The result is
// allocated with allocator.
@(require_results)
subagent_name :: proc(call: journal.Call_Id, allocator: mem.Allocator) -> string {
	return fmt.aprintf("agent-%d", call, allocator = allocator)
}

// Subagent_Resume says which finished child a start continues. name is its id, which is also
// what tells a start from a continuation, and the instruction it was defined with goes in the
// start's args. provider_id, model_id, and effort are its newest selection, which a
// continuation keeps unless the call names others; model_id is "" for a child that ran no
// turn, which then starts from the orchestrator's selection as a new child does. The strings
// are borrowed and valid until the start returns.
Subagent_Resume :: struct {
	program:     string,
	acp_session: string,
	after:       journal.Journal_Seq,
	name:        string,
	instruction: string,
	provider_id: string,
	model_id:    string,
	effort:      string,
	compact:     bool,
}

// subagent_start defines one subagent from a start call and adds it to the team. It resolves
// the model, the orchestrator's by default, and the effort, one level below the orchestrator's
// by default. With resume it continues the child resume names in session instead, keeping the
// newest selection by default. problem, temp-allocated, says why nothing started.
// Worker thread or owner.
@(require_results)
subagent_start :: proc(
	team: ^Agent_Team,
	args: Agent_Spawn_Args,
	call: journal.Call_Id,
	session: journal.Session_Id,
	allocator: mem.Allocator,
	resume := Subagent_Resume{},
) -> (
	member: ^Subagent,
	problem: string,
) {
	parent: Agent_Parent
	parent_error: mem.Allocator_Error
	{
		sync.mutex_guard(&team.mutex)
		if team.closing { return nil, "the orchestrator is closing; nothing started" }
		team.starting += 1
		// The snapshot is copied into scratch memory while the lock is held, so the owner
		// replacing it cannot release what this start still reads.
		parent, parent_error = agent_parent_temp_copy(team.parent, context.temp_allocator)
	}
	defer {
		{
			sync.mutex_guard(&team.mutex)
			team.starting -= 1
		}
		owner_wake_signal()
	}
	if parent_error != nil { return nil, "the orchestrator's selection could not be copied" }
	tools, tools_error := tool_registry_clone(&parent.tools, allocator)
	defer tool_registry_destroy(&tools)
	if tools_error.kind != .None { return nil, "the subagent tools could not be copied" }
	selection: Model_Selection
	program: Subagent_Program
	effort := args.effort
	if args.acp_agent != "" {
		program, problem = subagent_program(args, &parent, allocator)
	} else {
		if len(tools.definitions) == 0 { return nil, "subagents are not available in this session" }
		selection, effort, problem = subagent_select(args.provider, args.model, args.effort, subagent_defaults(&parent, resume), parent.catalog, allocator)
	}
	if problem != "" { return nil, problem }

	created := new(Subagent, allocator)
	if created == nil {
		model_selection_destroy(&selection, allocator)
		subagent_program_destroy(&program, allocator)
		return nil, "the subagent could not be allocated"
	}
	created^ = {
		selection                    = selection,
		program                      = program,
		tools                        = tools,
		parent_session               = parent.session,
		parent_call                  = call,
		session                      = session,
		run                          = parent.run,
		disable_project_instructions = parent.disable_project_instructions,
		background                   = !args.wait,
		resumed                      = resume.name != "",
		compact                      = resume.compact,
		team                         = team,
		allocator                    = allocator,
	}
	tools = {}
	// The record's own texts are copied now that it exists, so a copy that fails releases
	// the record instead of starting a half-defined subagent.
	failed := true
	defer if failed { subagent_destroy(created) }
	if subagent_clone_strings(created, args, parent, effort, resume.name, call, allocator) != nil {
		return nil, "the subagent could not be allocated"
	}
	if program.name != "" {
		created.acp_session = strings.clone(resume.acp_session, allocator) or_else ""
		if resume.acp_session != "" && created.acp_session == "" { return nil, "the agent's session id could not be held" }
		created.acp_after = resume.after
		wake, wake_error := tool_wake_open()
		if wake_error != nil {
			return nil, "the subagent's stop signal could not be created"
		}
		created.wake = wake
	}

	{
		sync.mutex_guard(&team.mutex)
		if team.closing { return nil, "the orchestrator is closing; nothing started" }
		if _, append_error := append(&team.members, created); append_error != nil {
			return nil, "the subagent could not be allocated"
		}
	}
	failed = false
	member = created
	return member, ""
}

@(private, require_results)
subagent_clone_strings :: proc(
	created: ^Subagent,
	args: Agent_Spawn_Args,
	parent: Agent_Parent,
	effort, resume_name: string,
	call: journal.Call_Id,
	allocator: mem.Allocator,
) -> mem.Allocator_Error {
	created.instruction = strings.clone(args.instruction, allocator) or_return
	created.prompt = strings.clone(args.prompt, allocator) or_return
	created.effort = strings.clone(effort, allocator) or_return
	if resume_name != "" {
		created.name = strings.clone(resume_name, allocator) or_return
	} else {
		created.name = subagent_name(call, allocator)
	}
	created.workspace = strings.clone(parent.workspace, allocator) or_return
	created.store_directory = strings.clone(parent.store_directory, allocator) or_return
	created.lock_directory = strings.clone(parent.lock_directory, allocator) or_return
	return nil
}

// Subagent_Defaults is what a selection falls back to for what its call leaves out. A new child
// defaults to its orchestrator's model and, with step_down, to the level one below the
// orchestrator's effort in effort_levels; a continued child keeps its newest selection.
Subagent_Defaults :: struct {
	provider_id:   string,
	model_id:      string,
	effort:        string,
	effort_levels: []string, // the levels effort is one of; read only with step_down
	step_down:     bool,
}

// subagent_defaults is what a start falls back to: a continued child's newest selection,
// else the orchestrator's with the effort stepped down.
@(private)
subagent_defaults :: proc(parent: ^Agent_Parent, resume: Subagent_Resume) -> Subagent_Defaults {
	if resume.model_id != "" { return {provider_id = resume.provider_id, model_id = resume.model_id, effort = resume.effort} }
	return {provider_id = parent.provider_id, model_id = parent.model_id, effort = parent.effort, effort_levels = parent.effort_levels, step_down = true}
}

// subagent_select resolves the model and effort a native subagent runs from what its call
// named, provider, model, and requested_effort, each "" when left out, and defaults. problem,
// temp-allocated, says why it cannot run, naming the configured providers or the provider's
// models when the call named one that does not exist; selection is then empty.
@(private, require_results)
subagent_select :: proc(
	provider, model, requested_effort: string,
	defaults: Subagent_Defaults,
	catalog: Catalog_Ref,
	allocator: mem.Allocator,
) -> (
	selection: Model_Selection,
	effort: string,
	problem: string,
) {
	if catalog.catalog == nil { return {}, "", "subagents are not available in this session" }
	{
		if catalog.mutex != nil { sync.mutex_lock(catalog.mutex) }
		defer if catalog.mutex != nil { sync.mutex_unlock(catalog.mutex) }
		provider_id, model_id := provider, model
		switch {
		case model_id == "" && (provider_id == "" || provider_id == defaults.provider_id):
			provider_id, model_id = defaults.provider_id, defaults.model_id
		case model_id == "":
			if _, found := catalog_find_provider(catalog.catalog, provider_id); !found {
				return {}, "", fmt.tprintf("provider not found: %s; configured providers: %s", provider_id, catalog_provider_names(catalog.catalog))
			}
			return {}, "", fmt.tprintf("name a model of provider %s: %s", provider_id, catalog_model_names(catalog.catalog, provider_id))
		case provider_id == "":
			provider_id, problem = catalog_model_provider(catalog.catalog, model_id, defaults.provider_id)
			if problem != "" { return {}, "", problem }
		}
		if model_id == "" { return {}, "", "no model is selected to default to, so name one in model" }
		selection, problem = model_selection_resolve(catalog.catalog, provider_id, model_id, allocator)
		if problem != "" { return {}, "", problem }
	}
	// An effort the model does not state is treated as one left out.
	effort = requested_effort
	if effort_level_index(selection.effort_levels, effort) < 0 {
		switch {
		case defaults.effort == "":
			effort = ""
		case defaults.step_down:
			effort = effort_step_down(defaults.effort_levels, selection.effort_levels, defaults.effort)
			// A model with other level names still thinks when its orchestrator does.
			if effort == "" && len(selection.effort_levels) > 0 { effort = selection.effort_levels[0] }
		case:
			effort = model_selection_effort(selection, defaults.effort)
		}
	}
	return selection, effort, ""
}

// subagent_launch starts a background subagent on a thread of its own, or queues it when
// the configured number of slots are in use. It returns false when the subagent neither started
// nor queued; a failed thread creation leaves the slot held, which subagent_finish releases.
// queued says the subagent waits for a slot: it may start, finish, and be released at any
// moment after, so the caller must not touch member again.
@(require_results)
subagent_launch :: proc(member: ^Subagent) -> (queued, ok: bool) {
	team := member.team
	member.stop.parent = &process_interrupt
	{
		sync.mutex_guard(&team.mutex)
		// A closing team has already asked every member to stop, so this one starts only to end.
		limit := team.parent.subagents_max_running if team.parent.subagents_max_running > 0 else SUBAGENTS_MAX_RUNNING
		if team.running >= limit && !team.closing {
			member.status = .Queued
			_, append_error := append(&team.waiting, member)
			return append_error == nil, append_error == nil
		}
		team.running += 1
		member.admitted = true
	}
	return false, subagent_thread_start(member)
}

// subagent_take_slot counts a blocking subagent among the running ones, past the bound if need
// be, until subagent_finish releases it.
@(private)
subagent_take_slot :: proc(member: ^Subagent) {
	sync.mutex_guard(&member.team.mutex)
	member.team.running += 1
	member.admitted = true
}

// subagent_thread_start runs a subagent on a thread of its own. The watched signals are
// blocked across creation, so the process handler never runs there. The thread is allocated
// with the member's allocator because the caller may be a worker whose own allocator is
// short-lived.
@(private, require_results)
subagent_thread_start :: proc(member: ^Subagent) -> bool {
	context.allocator = member.allocator
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
	subagent_finish(member)
}

// subagent_finish releases the subagent's slot and marks it done, which wakes the
// orchestrator to reap it: the reap commits the outcome the orchestrator reads from its
// journal. It then starts the queued subagents the slot admits. A queued subagent
// whose thread cannot be created fails and is finished the same way. It touches nothing of
// member after done.
subagent_finish :: proc(member: ^Subagent) {
	next := subagent_conclude(member)
	for next != nil {
		if subagent_thread_start(next) { return }
		subagent_fail(next, .Failed, "its thread could not be created")
		next = subagent_conclude(next)
	}
}

// subagent_conclude is subagent_finish without starting anything. It returns the queued
// subagent the released slot now belongs to, or nil when there is none or the team is closing.
@(private)
subagent_conclude :: proc(member: ^Subagent) -> (next: ^Subagent) {
	team := member.team
	{
		sync.mutex_guard(&team.mutex)
		if member.admitted {
			member.admitted = false
			team.running -= 1
			if len(team.waiting) > 0 && !team.closing {
				next = team.waiting[0]
				ordered_remove(&team.waiting, 0)
				next.status = .Running
				next.admitted = true
				team.running += 1
			}
		}
	}
	sync.atomic_store(&member.done, true)
	owner_wake_signal()
	return next
}

// subagent_fail records why a subagent ended. The status is the outcome either way; a reason
// that cannot be kept leaves the status as the whole outcome.
@(private)
subagent_fail :: proc(member: ^Subagent, status: Subagent_Status, reason: string) {
	member.status = status
	delete(member.cause, member.allocator)
	member.cause = strings.clone(reason, member.allocator) or_else ""
}

// subagent_keep_answer sets member.answer to the text of the last Assistant node the
// subagent's session committed, whatever the outcome: the answer of a completed subagent,
// the partial text a failed or stopped one had streamed, or the last text it wrote before
// it ended. A completed subagent whose answer cannot be read or held is not the answer the
// orchestrator asked for, so its outcome becomes failed rather than reporting a short one.
@(private)
subagent_keep_answer :: proc(member: ^Subagent, store: ^journal.Journal) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	node, found, read_error := journal.read_last_node(store, member.session, .Assistant, context.temp_allocator)
	if read_error == nil && !found { return }
	answer: string
	clone_error: mem.Allocator_Error
	if read_error == nil { answer, clone_error = strings.clone(string(node.body), member.allocator) }
	if read_error != nil || clone_error != nil {
		if member.status == .Completed { subagent_fail(member, .Failed, "the subagent's answer could not be recorded") }
		return
	}
	member.answer = answer
}

// subagent_session_open creates the member's session, or claims and recovers it when the
// member continues one, and returns the branch and head the session runs from. The claim is
// the same as any session's, so a session another process runs is refused. problem,
// temp-allocated, says why the session cannot be opened.
@(private)
subagent_session_open :: proc(member: ^Subagent, store: ^journal.Journal) -> (branch: journal.Branch_Id, head: journal.Node_Id, problem: string) {
	if !member.resumed {
		_, create_error := journal.create_session(
			store,
			journal.New_Session {
				id = member.session,
				workspace = member.workspace,
				role = .Subagent,
				parent_session = member.parent_session,
				parent_call = member.parent_call,
			},
		)
		if create_error != nil {
			return 0, 0, fmt.tprintf("the subagent's session could not be created: %s", journal.error_text(create_error, context.temp_allocator))
		}
		// The session's role is read from its row, so the row is committed before the session
		// is set up.
		if _, commit_error := journal.commit(store); commit_error != nil {
			return 0, 0, fmt.tprintf("the subagent's session could not be created: %s", journal.error_text(commit_error, context.temp_allocator))
		}
		return journal.INITIAL_BRANCH, 0, ""
	}
	if _, claim_error := journal.claim(store, member.session); claim_error != nil {
		return 0, 0, fmt.tprintf("the subagent's session could not be claimed to continue it: %s", journal.error_text(claim_error, context.temp_allocator))
	}
	if _, recover_error := journal.recover(store); recover_error != nil {
		return 0, 0, fmt.tprintf("the subagent's session could not be recovered: %s", journal.error_text(recover_error, context.temp_allocator))
	}
	head_error: journal.Error
	branch, head, head_error = journal.session_head(store, member.session)
	if head_error != nil {
		return 0, 0, fmt.tprintf("the subagent's session history could not be read: %s", journal.error_text(head_error, context.temp_allocator))
	}
	return branch, head, ""
}

// chat_session_role_setup gives chat the instructions and tools of the role its journal row
// names, so a subagent session is the same agent whoever opens it: the orchestrator that runs it
// or a person who resumes it. A Main session, and one the journal has no row for yet, keeps what
// chat_session_init built and ignores base. A Subagent session gets SUBAGENT_ROLE followed by
// the instruction in its parent's newest subagent.started for it, a copy of base without the
// tools that manage subagents, and no team, because a subagent starts none. base is borrowed
// and may be chat's own registry. problem is static text, "" when the role is set up. Owner
// only, with chat idle.
@(require_results)
chat_session_role_setup :: proc(chat: ^Chat_Session, base: ^Tool_Registry) -> (problem: string) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	summaries, list_error := journal.list_sessions(chat.store, {session = chat.session, limit = 1}, context.temp_allocator)
	if list_error != nil { return "the session's role could not be read" }
	if len(summaries) == 0 || summaries[0].role != .Subagent {
		chat.role = .Main
		return ""
	}
	filter := journal.Filter {
		session  = summaries[0].parent_session,
		subagent = chat.session,
		kinds    = {.Subagent_Started},
	}
	start, found, read_error := journal.read_latest(chat.store, filter, context.temp_allocator)
	if read_error != nil { return "the subagent's instruction could not be read from its parent's journal" }
	if !found { return "the subagent's definition is not in its parent's journal" }
	instructions, instructions_error := strings.concatenate({SUBAGENT_ROLE, "\n\n", string(start.body)}, chat.allocator)
	if instructions_error != nil { return "the subagent's instructions could not be held" }
	tools, tools_error := tool_registry_clone(base, chat.allocator)
	if tools_error.kind != .None {
		delete(instructions, chat.allocator)
		return "the subagent's tools could not be copied"
	}
	chat.role = .Subagent
	if chat_session_replace_tools(chat, &tools) != .None {
		chat.role = .Main
		delete(instructions, chat.allocator)
		tool_registry_destroy(&tools)
		return "the subagent's tools could not be installed"
	}
	delete(chat.role_instructions, chat.allocator)
	chat.role_instructions = instructions
	agent_team_destroy(chat.team, chat)
	chat.team = nil
	return ""
}

// subagent_compact_wait services the child's compaction as an idle session does, until no
// summary is running, waiting or recorded, or the child is stopped.
@(private)
subagent_compact_wait :: proc(member: ^Subagent, chat: ^Chat_Session, connection: ai.Provider_Connection) {
	for {
		seen := owner_wake_seen()
		chat_session_observe_stop(chat)
		if chat_session_cancelled(chat) { return }
		_ = chat_compact_idle_service(chat, {}, connection)
		if chat.compact.state == .Idle { return }
		owner_wake_wait(seen, chat_compact_deadline(chat))
	}
}

// subagent_run runs the subagent's session until it answers its task and every message its
// orchestrator sent after that, and records the outcome in member. A member that continues a
// session starts from the message its orchestrator sent instead of a task. Runs on the
// subagent's own thread and reaches nothing of the orchestrator's except the team.
subagent_run :: proc(member: ^Subagent) {
	allocator := member.allocator

	if member.program.name != "" {
		subagent_acp_run(member)
		return
	}
	store: journal.Journal
	if open_error := journal.open(&store, member.store_directory, member.lock_directory, member.run, .Read_Write, allocator); open_error != nil {
		subagent_fail(
			member,
			.Failed,
			fmt.tprintf("the subagent's session store could not be opened: %s", journal.error_text(open_error, context.temp_allocator)),
		)
		return
	}
	// The subagent's session is over when this returns, so the claim the journal
	// holds with it is never released by anyone else, and a close that fails
	// changes nothing about that.
	defer _ = journal.close(&store)

	branch, head, problem := subagent_session_open(member, &store)
	if problem != "" {
		subagent_fail(member, .Failed, problem)
		return
	}
	// The answer is read after the session is destroyed and before the store closes, whatever
	// the outcome.
	defer subagent_keep_answer(member, &store)

	chat, init_error := chat_session_init(&store, member.session, branch, head, member.workspace, allocator)
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
	chat.member = member
	chat.stop_parent = &member.stop
	chat.disable_project_instructions = member.disable_project_instructions
	if role_problem := chat_session_role_setup(&chat, &member.tools); role_problem != "" {
		subagent_fail(member, .Failed, role_problem)
		return
	}
	installed, _ := chat_session_select(&chat, member.selection, member.effort)
	if !installed {
		subagent_fail(member, .Failed, "the subagent's model could not be held")
		return
	}
	steer := Subagent_Steer {
		member     = member,
		chat       = &chat,
		connection = member.selection.connection,
	}
	defer subagent_control_destroy(&steer.pending)

	// The task is the first message, so what the orchestrator sent while this subagent
	// waited for a slot is delivered after it, at the first settled point. A continued
	// session has had its task, so its first message is what waits in its inbox.
	text, origin, inbox_first := member.prompt, journal.User_Origin.Prompt, false
	if member.resumed { text, origin, inbox_first = "", .Agent, true }
	if member.compact {
		if chat_compact_request(&chat, .User_Command) == .Unavailable {
			subagent_fail(member, .Failed, "the subagent's context could not be compacted")
			return
		}
		if member.prompt == "" {
			// Nothing was sent to continue it, so it ends once the summary is installed. A
			// summary may take many minutes, so nothing but a stop ends the wait.
			subagent_compact_wait(member, &chat, steer.connection)
			if chat_session_cancelled(
				&chat,
			) { subagent_fail(member, .Stopped, "the subagent was stopped before it finished") } else { member.status = .Completed }
			return
		}
	}
	for {
		subagent_steer_service(&steer)
		accepted := chat_session_accept_message(&chat, text, origin, {}, inbox_first)
		if accepted != .Accepted {
			subagent_fail(member, .Failed, chat.last_error if chat.last_error != "" else "the task could not be recorded")
			return
		}
		turn_steer := Steer_Context {
			observe    = subagent_steer_observe,
			apply      = subagent_steer_apply,
			apply_data = &steer,
		}
		if !chat_turn_drive(&chat, steer.connection, chat_retry_policy_default(), {}, &turn_steer, nil) {
			if chat.terminal_status == .Cancelled {
				subagent_fail(member, .Stopped, "the subagent was stopped before it finished")
			} else {
				subagent_fail(member, .Failed, chat.last_error if chat.last_error != "" else "the subagent's turn did not complete")
			}
			return
		}
		subagent_steer_service(&steer)
		if chat.compact.state != .Idle {
			subagent_compact_wait(member, &chat, steer.connection)
			if chat_session_cancelled(&chat) {
				subagent_fail(member, .Stopped, "the subagent was stopped before it finished")
				return
			}
			subagent_steer_service(&steer)
		}
		// Steering answers every message taken before the turn settled. One that arrived
		// after its last check starts the next turn, which delivers it. One that arrives
		// after this read is found when the orchestrator reaps the child, which runs it again.
		waiting, read_error := journal.read_inbox(&store, member.session, chat.delivered, context.temp_allocator)
		if read_error != nil {
			subagent_fail(member, .Failed, "the subagent's inbox could not be read")
			return
		}
		if len(waiting) == 0 { break }
		text, origin, inbox_first = "", .Agent, true
	}
	member.status = .Completed
}

// subagent_find returns the running member named name. The caller holds team.mutex.
@(private)
subagent_find :: proc(team: ^Agent_Team, name: string) -> ^Subagent {
	for member in team.members {
		if member.name == name { return member }
	}
	return nil
}

// subagent_control_plan finds the running member named by send.agent and, when the call also
// asks for a switch or a compaction, resolves what it asks while the message is still
// unrecorded: the switch is resolved against the control the member has not yet taken, else its
// selection, into send.control, so a name that does not exist is refused here and records
// nothing. live is false when no member has that name. problem, temp-allocated, says why the
// request cannot be queued. Owner only.
@(private, require_results)
subagent_control_plan :: proc(team: ^Agent_Team, send: ^Agent_Send_Args) -> (session: journal.Session_Id, live: bool, problem: string) {
	switching := send.model != "" || send.provider != "" || send.effort != ""
	defaults: Subagent_Defaults
	allocator: mem.Allocator
	catalog: Catalog_Ref
	{
		sync.mutex_guard(&team.mutex)
		member := subagent_find(team, send.agent)
		if member == nil { return {}, false, "" }
		session, live = member.session, true
		if !switching && !send.compact { return }
		if member.program.name != "" {
			if send.compact { return session, true, "ACP agents manage their own context" }
			if send.provider != "" { return session, true, "ACP agents choose their own provider; name only model and effort" }
			wanted_model, wanted_effort := member.program.model, member.effort
			if member.control.switching { wanted_model, wanted_effort = member.control.acp_model, member.control.effort }
			if send.model != "" { wanted_model = send.model }
			if send.effort != "" { wanted_effort = send.effort }
			model, model_error := strings.clone(wanted_model, member.allocator)
			effort, effort_error := strings.clone(wanted_effort, member.allocator)
			if model_error != nil ||
			   effort_error != nil { delete(model, member.allocator); delete(effort, member.allocator); return session, true, "the switch could not be held" }
			send.control = {
				acp_model = model,
				effort    = effort,
				switching = true,
				allocator = member.allocator,
			}
			return
		}
		current, effort := &member.selection, member.effort
		if member.control.switching { current, effort = &member.control.selection, member.control.effort }
		defaults = {
			provider_id = fmt.tprintf("%s", current.provider_id),
			model_id    = fmt.tprintf("%s", current.model_id),
			effort      = fmt.tprintf("%s", effort),
		}
		allocator, catalog = member.allocator, team.parent.catalog
	}
	send.control.compact = send.compact
	if !switching { return }
	selection: Model_Selection
	effort: string
	selection, effort, problem = subagent_select(send.provider, send.model, send.effort, defaults, catalog, allocator)
	if problem != "" { return }
	kept, clone_error := strings.clone(effort, allocator)
	if clone_error != nil {
		model_selection_destroy(&selection, allocator)
		return session, true, "the switch could not be held"
	}
	send.control = {
		selection = selection,
		effort    = kept,
		switching = true,
		compact   = send.compact,
		allocator = allocator,
	}
	return
}

// subagent_control_apply gives the running member named name what subagent_control_plan
// resolved, replacing a switch it has not yet taken and adding to a compaction it has not yet
// started, and wakes it. It takes over control's switch; a member that is gone releases it.
// Owner only, after the message is committed.
@(private)
subagent_control_apply :: proc(team: ^Agent_Team, name: string, control: ^Subagent_Control) {
	if !control.switching && !control.compact { return }
	{
		sync.mutex_guard(&team.mutex)
		member := subagent_find(team, name)
		if member == nil {
			subagent_control_destroy(control)
			return
		}
		if control.switching {
			compact := member.control.compact
			subagent_control_destroy(&member.control)
			member.control = control^
			member.control.compact ||= compact
		} else {
			member.control.compact = true
		}
		control^ = {}
	}
	owner_wake_signal()
}

// Subagent_Steer is the request-boundary state of one running child, owned by its thread:
// the connection its next request uses, and the switch it is fitting, if any. It is the
// apply_data of the child's Steer_Context.
Subagent_Steer :: struct {
	member:     ^Subagent,
	chat:       ^Chat_Session,
	connection: ai.Provider_Connection, // borrowed from member.selection or a selection it retired
	pending:    Subagent_Control, // the switch being fitted; its compact is never set
	transition: Selection_Transition,
}

// subagent_steer_take moves what the orchestrator asked since the child last looked out of the
// member, under the team lock: a switch replaces the one being fitted, and compact says a
// compaction was asked for. Nothing is done under the lock.
@(private)
subagent_steer_take :: proc(state: ^Subagent_Steer) -> (compact: bool) {
	taken: Subagent_Control
	{
		sync.mutex_guard(&state.member.team.mutex)
		taken = state.member.control
		state.member.control = {}
	}
	if taken.switching {
		subagent_control_destroy(&state.pending)
		state.pending = taken
		state.pending.compact = false
		state.transition = {}
	}
	return taken.compact
}

// subagent_steer_observe is the child's collection step: a compaction the orchestrator asked
// for becomes the same intent the user's /compact makes in the main session.
@(private)
subagent_steer_observe :: proc(steer: ^Steer_Context, observer: Chat_Observer) {
	state := cast(^Subagent_Steer)steer.apply_data
	if subagent_steer_take(state) { _ = chat_compact_request(state.chat, .User_Command) }
}

// subagent_steer_apply is the child's request-boundary hook: it advances the switch the
// orchestrator asked for and returns the connection the next request is built for.
@(private)
subagent_steer_apply :: proc(steer: ^Steer_Context) -> ai.Provider_Connection {
	state := cast(^Subagent_Steer)steer.apply_data
	subagent_steer_service(state)
	return state.connection
}

// subagent_steer_service takes what the orchestrator asked and advances the switch through the
// session's fit check as the main session does: a target that fits is installed, one that does
// not waits for the compaction the check requests and is checked again after it installs, and
// one the check refuses is reported to the orchestrator. It runs at each request boundary and
// between turns, including before the child finishes.
@(private)
subagent_steer_service :: proc(state: ^Subagent_Steer) {
	if subagent_steer_take(state) { _ = chat_compact_request(state.chat, .User_Command) }
	if !state.pending.switching { return }
	chat := state.chat
	status, problem, check_error := chat_selection_check(chat, state.pending.selection, &state.transition, chat.compact_on_switch, state.connection)
	if check_error != nil {
		chat.storage_failed = true
		subagent_steer_refuse(state, fmt.tprintf("the model switch could not be recorded: %s", journal.error_text(check_error, context.temp_allocator)))
		return
	}
	switch status {
	case .Ready:
		subagent_steer_install(state)
	case .Pending:
	case .Refused:
		subagent_steer_refuse(state, problem if problem != "" else "the requested model does not fit the active conversation")
	}
}

// subagent_steer_install installs the fitted switch on the child's session through the same
// procedure the main session's selection uses, then makes it the member's selection. The
// selection it replaces is retired, not released: a request or summary in flight may still
// read its connection.
@(private)
subagent_steer_install :: proc(state: ^Subagent_Steer) {
	chat, member, pending := state.chat, state.member, &state.pending
	installed, _, record_error := chat_selection_install(chat, pending.selection, pending.effort, state.connection)
	if !installed {
		subagent_steer_refuse(state, "the model could not be held")
		return
	}
	// The request in flight must not continue from a selection whose record did not land.
	if record_error !=
	   nil { chat_session_record_failure(chat, "the selected model was installed but its session record could not be committed", record_error) }

	{
		sync.mutex_guard(&member.team.mutex)
		member.retired.allocator = member.allocator
		// A selection that cannot be listed is left unreleased rather than freed under a reader.
		_, _ = append(&member.retired, member.selection)
		member.selection = pending.selection
		delete(member.effort, member.allocator)
		member.effort = pending.effort
	}
	pending^ = {}
	state.transition = {}
	state.connection = member.selection.connection
}

// subagent_steer_refuse drops the switch being fitted and tells the orchestrator why it was not
// applied, as a message from the child, the way the child reaches it for anything else.
@(private)
subagent_steer_refuse :: proc(state: ^Subagent_Steer, reason: string) {
	chat, member := state.chat, state.member
	text := fmt.tprintf("Your request to switch to %s/%s was not applied: %s", state.pending.selection.provider_id, state.pending.selection.model_id, reason)
	subagent_control_destroy(&state.pending)
	state.transition = {}
	if !chat_journal_writable(chat) { return }
	chat_record(chat, {kind = .Subagent_Message, subagent = chat.session}, journal.Subagent_Message{name = member.name}, transmute([]u8)text)
	if chat_commit(chat, "the refusal of a model switch could not be recorded") { owner_wake_signal() }
}

// subagent_outcome_status names how a delegation ended, as the model reads it, from the
// outcome its subagent.completed recorded; finished is false while none is recorded.
@(private)
subagent_outcome_status :: proc(outcome: journal.Tool_Outcome, finished: bool) -> string {
	if !finished { return "running" }
	switch outcome {
	case .Success:
		return "completed"
	case .Cancelled:
		return "stopped"
	case .Unknown:
		return "interrupted"
	case .Not_Executed:
		return "never started"
	case .Tool_Failed, .Invalid_Arguments, .Denied, .Unavailable, .Transport_Failed, .Timed_Out:
		return "failed"
	}
	return "failed"
}

// subagent_outcome reads how the delegation that start opened ended, from the
// subagent.completed records of the orchestrator's session. finished is false while none
// names it. A record that cannot be read still says the delegation ended, with an unknown
// outcome.
@(private)
subagent_outcome :: proc(completions: []journal.Record, start: journal.Record) -> (outcome: journal.Tool_Outcome, finished: bool) {
	for completion in completions {
		if completion.call != start.call || completion.subagent != start.subagent { continue }
		completed: journal.Subagent_Completed
		if journal.payload_decode(completion.data, &completed, context.temp_allocator) != nil { return .Unknown, true }
		named, named_ok := journal.enum_from_name(journal.TOOL_OUTCOME_NAMES, completed.outcome)
		return named if named_ok else .Unknown, true
	}
	return .Unknown, false
}

Subagent_Child :: struct {
	acp_model:   string,
	acp_effort:  string,
	name:        string,
	program:     string,
	acp_session: string,
	after:       journal.Journal_Seq,
	start:       journal.Record,
	outcome:     journal.Tool_Outcome,
	finished:    bool,
}

// subagent_children reads this session's newest delegation for each child. The result
// and its records live in temporary memory. Owner only.
@(private)
subagent_children :: proc(store: ^journal.Journal, session: journal.Session_Id) -> ([]Subagent_Child, string) {
	filter := journal.Filter {
		session = session,
		kinds   = {.Subagent_Started},
	}
	starts, _, starts_error := journal.read_records(store, filter, 0, 0, context.temp_allocator)
	filter.kinds = {.Subagent_Completed}
	completions, _, completions_error := journal.read_records(store, filter, 0, 0, context.temp_allocator)
	if starts_error != nil || completions_error != nil { return nil, "the delegations could not be read from the journal" }

	// The newest start of a name says what the child is and how its last run began. A
	// continuation that never started leaves the child as it was.
	known := make([dynamic]Subagent_Child, context.temp_allocator)
	for record in starts {
		started: journal.Subagent_Started
		if journal.payload_decode(record.data, &started, context.temp_allocator) != nil { continue }
		entry := Subagent_Child {
			name    = started.name,
			program = started.program,
			start   = record,
			outcome = .Unknown,
		}
		ended, finished := subagent_outcome(completions, record)
		entry.outcome, entry.finished = ended, finished
		for completion in completions {
			if completion.call != record.call || completion.subagent != record.subagent { continue }
			completed: journal.Subagent_Completed
			if journal.payload_decode(completion.data, &completed, context.temp_allocator) == nil {entry.acp_model = completed.acp_model
				entry.acp_effort = completed.acp_effort
				entry.acp_session = completed.acp_session; entry.after = completed.acp_after}
		}
		never_started := finished && ended == .Not_Executed
		replaced := false
		for &candidate in known {
			if candidate.name != started.name { continue }
			replaced = true
			if !never_started {
				if entry.program != "" && entry.acp_session == "" && entry.start.subagent == candidate.start.subagent {
					entry.acp_session = candidate.acp_session
					entry.acp_model = candidate.acp_model
					entry.acp_effort = candidate.acp_effort
					entry.after = candidate.after
				}
				candidate = entry
			}
		}
		if !replaced {
			if _, err := append(&known, entry); err != nil { return nil, "the delegations could not be held" }
		}
	}
	return known[:], ""
}

// subagent_resume_plan finds the child send names among the delegations the orchestrator's
// journal records, and fills send.resume with what continuing it needs: its instruction from
// its newest start and its newest installed or turn selection. It returns the child's session, and
// has checked that the selection the call names resolves, so a refused call records nothing.
// problem, temp-allocated, says why the child cannot be continued; for a name the journal
// does not know it lists the children it does, with how each ended. send.resume stays empty on
// a problem. Owner only.
@(private)
subagent_resume_plan :: proc(chat: ^Chat_Session, team: ^Agent_Team, send: ^Agent_Send_Args) -> (child: journal.Session_Id, problem: string) {
	name := send.agent
	if !chat_journal_writable(chat) { return {}, "subagents are not available in this session" }
	known, read_problem := subagent_children(chat.store, chat.session)
	if read_problem != "" { return {}, read_problem }
	found := -1
	for candidate, index in known {
		if candidate.name == name { found = index }
	}
	if found < 0 {
		listed := make([dynamic]string, 0, len(known), context.temp_allocator)
		for candidate in known {
			ended, finished := candidate.outcome, candidate.finished
			append(&listed, fmt.tprintf("%s (%s)", candidate.name, subagent_outcome_status(ended, finished)))
		}
		joined, _ := strings.join(listed[:], ", ", context.temp_allocator)
		return {}, fmt.tprintf("no subagent named %q; the subagents of this session: %s", name, joined if len(listed) > 0 else "none")
	}
	target := known[found]
	if target.program != "" {
		if send.compact { return {}, "ACP agents manage their own context" }
		if send.provider != "" { return {}, "ACP agents choose their own provider; name only model and effort" }
	}
	ended, finished := target.outcome, target.finished
	if !finished { return {}, fmt.tprintf("%s has not finished", name) }
	if send.message == "" && !send.compact {
		return {}, fmt.tprintf("%s has finished, so a switch alone does not continue it; send a message to reopen it on the model", name)
	}
	if ended == .Not_Executed {
		return {}, fmt.tprintf("%s never started, so it has no session to continue; start a new one with agent_spawn", name)
	}

	if target.program != "" {
		if target.acp_session == "" { return {}, "the ACP agent has no recorded session id to resume; start a new one with agent_spawn" }
		send.resume = {
			name        = name,
			program     = target.program,
			acp_session = target.acp_session,
			after       = target.after,
			model_id    = target.acp_model,
			effort      = target.acp_effort,
		}
		return target.start.subagent, ""
	}
	latest, latest_found, latest_error := journal.read_latest(
		chat.store,
		{session = target.start.subagent, kinds = {.Turn_Started, .Selection_Applied}},
		context.temp_allocator,
	)
	if latest_error != nil { return {}, fmt.tprintf("the last selection of %s could not be read", name) }
	continued := Subagent_Resume {
		name        = name,
		instruction = string(target.start.body),
		compact     = send.compact,
	}
	if latest_found {
		#partial switch latest.kind {
		case .Turn_Started:
			turn: journal.Turn_Started
			if journal.payload_decode(latest.data, &turn, context.temp_allocator) == nil { continued.effort = turn.effort }
		case .Selection_Applied:
			selection: journal.Selection_Applied
			if journal.payload_decode(latest.data, &selection, context.temp_allocator) == nil { continued.effort = selection.effort }
		}
		continued.provider_id, continued.model_id = latest.provider, latest.model
	}
	// The orchestrator is the only writer of team.parent, so reading it here needs no lock.
	_, _, problem = subagent_select(
		send.provider,
		send.model,
		send.effort,
		subagent_defaults(&team.parent, continued),
		team.parent.catalog,
		context.temp_allocator,
	)
	if problem != "" { return {}, problem }
	send.resume = continued
	return target.start.subagent, ""
}

// subagent_status_format renders the children of parent, or one child's journal status.
// The text and problem live in temporary memory. Owner only; it changes no child state.
@(private)
subagent_status_format :: proc(store: ^journal.Journal, parent: journal.Session_Id, name: string, team: ^Agent_Team = nil) -> (text, problem: string) {
	children, read_problem := subagent_children(store, parent)
	if read_problem != "" { return "", read_problem }
	listed: strings.Builder
	strings.builder_init(&listed, context.temp_allocator)
	target: Subagent_Child
	found := false
	hex: [journal.SESSION_ID_HEX_LENGTH]u8
	for &child in children {
		if team != nil {
			sync.mutex_guard(&team.mutex)
			if member := subagent_find(team, child.name); member != nil && member.program.name != "" {
				cloned, clone_error := strings.clone(member.acp_session, context.temp_allocator)
				if clone_error != nil { return "", "the ACP agent's session id could not be held" }
				child.acp_session = cloned
			}
		}
		status := subagent_outcome_status(child.outcome, child.finished)
		fmt.sbprintf(&listed, "%s: %s, session %s", child.name, status, journal.session_id_to_hex(child.start.subagent, hex[:]))
		if child.acp_session != "" { fmt.sbprintf(&listed, ", ACP session %s", child.acp_session) }
		fmt.sbprintf(&listed, "\n")
		if child.name == name { target, found = child, true }
	}
	if name == "" { return strings.to_string(listed), "" }
	if !found { return "", fmt.tprintf("no subagent named %q; the subagents of this session:\n%s", name, strings.to_string(listed)) }
	child_session := target.start.subagent
	block: strings.Builder
	strings.builder_init(&block, context.temp_allocator)
	fmt.sbprintf(
		&block,
		"agent: %s\nstatus: %s\nsession: %s\n",
		name,
		subagent_outcome_status(target.outcome, target.finished),
		journal.session_id_to_hex(child_session, hex[:]),
	)
	if target.acp_session != "" { fmt.sbprintf(&block, "ACP session: %s\n", target.acp_session) }
	turn, has_turn, turn_error := journal.read_latest(store, {session = child_session, kinds = {.Turn_Started}}, context.temp_allocator)
	if turn_error != nil { return "", "the child's last turn could not be read" }
	if has_turn {
		started: journal.Turn_Started
		if journal.payload_decode(turn.data, &started, context.temp_allocator) != nil { return "", "the child's last selection could not be decoded" }
		fmt.sbprintf(&block, "provider: %s\nmodel: %s\neffort: %s\n", turn.provider, turn.model, started.effort)
	}
	latest, has_latest, latest_error := journal.read_latest(store, {session = child_session}, context.temp_allocator)
	if latest_error != nil { return "", "the child's newest journal record could not be read" }
	if has_latest {
		age_ms := max(i64(0), time.time_to_unix_nano(time.now()) / 1_000_000 - latest.time_ms)
		fmt.sbprintf(&block, "last record: %s\nage: %.3f seconds\n", journal.RECORD_KIND_NAMES[latest.kind], f64(age_ms) / 1000)
	}
	completed, has_completed, completed_error := journal.read_latest(store, {session = child_session, kinds = {.Turn_Completed}}, context.temp_allocator)
	if completed_error != nil { return "", "the child's last turn outcome could not be read" }
	if has_completed && (!has_turn || completed.turn == turn.turn) {
		outcome: journal.Turn_Completed
		if journal.payload_decode(completed.data, &outcome, context.temp_allocator) != nil { return "", "the child's last turn outcome could not be decoded" }
		fmt.sbprintf(&block, "last turn: %s\n", outcome.outcome)
		if outcome.detail != "" {
			fmt.sbprintf(&block, "last failure: %s\n", outcome.detail)
		} else if outcome.outcome == journal.TURN_OUTCOME_NAMES[.Failed] {
			rejected, has_rejected, rejection_error := journal.read_latest(
				store,
				{session = child_session, turn = completed.turn, kinds = {.Response_Rejected}},
				context.temp_allocator,
			)
			if rejection_error != nil { return "", "the child's last provider failure could not be read" }
			if has_rejected {
				failure: journal.Response_Rejected
				if journal.payload_decode(rejected.data, &failure, context.temp_allocator) !=
				   nil { return "", "the child's last provider failure could not be decoded" }
				fmt.sbprintf(
					&block,
					"last failure: %s, status %d, provider code %s: %s\n",
					failure.failure_class,
					failure.status,
					failure.provider_code,
					failure.detail,
				)
			}
		}
	}
	answer, has_answer, answer_error := journal.read_last_node(store, child_session, .Assistant, context.temp_allocator)
	if answer_error != nil { return "", "the child's last Assistant text could not be read" }
	if has_answer {
		assistant: journal.Assistant
		if journal.payload_decode(answer.data, &assistant, context.temp_allocator) != nil { return "", "the child's last Assistant text could not be decoded" }
		fmt.sbprintf(&block, "Assistant%s:\n%s\n", " (partial)" if assistant.partial else "", string(answer.body))
	}
	delivered, delivered_error := journal.last_delivered_message(store, child_session)
	if delivered_error != nil { return "", "the child's delivered messages could not be read" }
	unread, inbox_error := journal.read_inbox(store, child_session, delivered, context.temp_allocator)
	if inbox_error != nil { return "", "the child's unread messages could not be read" }
	fmt.sbprintf(&block, "unread messages: %d\n", len(unread))
	if target.finished && target.outcome != .Not_Executed && target.program == "" {
		fmt.sbprintf(&block, "resume: agent_send(%s\"agent\":%q,\"message\":\"Continue your task.\"%s)\n", "{", name, "}")
	}
	return strings.to_string(block), ""
}

// subagent_stop asks a subagent to stop. Its outcome reaches the orchestrator like any other.
// A queued subagent never starts: it is reported stopped at once.
@(require_results)
subagent_stop :: proc(team: ^Agent_Team, name: string) -> (problem: string) {
	defer owner_wake_signal()
	member: ^Subagent
	queued: bool
	{
		sync.mutex_guard(&team.mutex)
		member = subagent_find(team, name)
		if member == nil { return subagent_unknown(team, name) }
		if sync.atomic_load(&member.done) { return fmt.tprintf("%s has already finished", name) }
		queued = member.status == .Queued
		if queued { subagent_unqueue(team, member) } else { subagent_request_stop(member) }
	}
	if queued { subagent_end_unstarted(member) }
	return ""
}

// subagent_unqueue takes a queued member out of team.waiting and marks it stopped, so no
// release admits it. The caller holds team.mutex and then calls subagent_end_unstarted.
@(private)
subagent_unqueue :: proc(team: ^Agent_Team, member: ^Subagent) {
	for waiting, index in team.waiting {
		if waiting == member {
			ordered_remove(&team.waiting, index)
			break
		}
	}
	member.status = .Stopped
}

// subagent_end_unstarted reports a member that was unqueued. It had no thread and holds no
// slot, so finishing it starts nothing.
@(private)
subagent_end_unstarted :: proc(member: ^Subagent) {
	subagent_fail(member, .Stopped, "stopped before it started; not executed")
	subagent_finish(member)
}

// subagent_stop_waiting ends every queued member as stopped. It is for a team that is closing,
// where nothing queued may start.
@(private)
subagent_stop_waiting :: proc(team: ^Agent_Team) {
	for {
		member: ^Subagent
		{
			sync.mutex_guard(&team.mutex)
			if len(team.waiting) == 0 { return }
			member = team.waiting[0]
			subagent_unqueue(team, member)
		}
		subagent_end_unstarted(member)
	}
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
	names, names_error := make([dynamic]string, 0, len(team.members), context.temp_allocator)
	if names_error != nil { return fmt.tprintf("no subagent named %q is running", name) }
	for member in team.members { append(&names, member.name) }
	if len(names) == 0 { return fmt.tprintf("no subagent named %q is running; none is", name) }
	joined, join_error := strings.join(names[:], ", ", context.temp_allocator)
	if join_error != nil { return fmt.tprintf("no subagent named %q is running; the running ones could not be listed", name) }
	return fmt.tprintf("no subagent named %q is running; running: %s", name, joined)
}

// --- the orchestrator's front-end --------------------------------------------------

// chat_parent_session is the orchestrator's session id for a subagent's session, else "".
chat_parent_session :: proc(chat: ^Chat_Session) -> string {
	if chat.member == nil { return "" }
	return journal.session_id_to_hex(chat.member.parent_session, chat.member.parent_session_hex[:])
}

// chat_agents_pending reports whether an agent's report or message waits in the journal or
// a subagent still runs. It releases finished subagents first, which commits their
// reports. Owner only.
@(require_results)
chat_agents_pending :: proc(chat: ^Chat_Session) -> bool {
	if chat.team == nil { return false }
	// Running is read before the reap: a subagent that finishes between the two is still
	// counted, and its wake brings the owner back to reap it.
	running := agent_team_running(chat.team)
	reopened := agent_team_reap(chat.team, chat)
	return chat_inbox_reports_pending(chat) || running || reopened
}

// chat_agents_wait blocks until an agent's report or message waits, and reports false
// instead when no subagent runs any more or stop is requested. Owner only.
@(require_results)
chat_agents_wait :: proc(chat: ^Chat_Session, stop: ^ai.Interrupt) -> bool {
	if chat.team == nil { return false }
	for {
		seen := owner_wake_seen()
		running := agent_team_running(chat.team)
		reopened := agent_team_reap(chat.team, chat)
		if chat_inbox_reports_pending(chat) { return true }
		if !(running || reopened) || ai.interrupt_requested(stop) || ai.interrupt_requested(&process_interrupt) { return false }
		owner_wake_wait(seen, nil)
	}
}

// chat_session_accept_agent_message opens a turn that delivers what the agents sent and
// what other processes sent while no turn ran, and anything else the session accepted and
// has not delivered, before it. It reports had_message false when nothing of that kind
// waits. Input the store refused stays pending in the journal.
@(require_results)
chat_session_accept_agent_message :: proc(chat: ^Chat_Session, observer: Chat_Observer) -> (accepted: Chat_Accept, had_message: bool) {
	if !chat_inbox_reports_pending(chat) { return .Accepted, false }
	return chat_session_accept_message(chat, "", .Agent, observer), true
}
