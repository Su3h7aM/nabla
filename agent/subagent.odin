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

// SUBAGENTS_MAX_RUNNING is how many subagents run at once, native and ACP together. It is a
// concurrency default, not a refusal: a background subagent started past it queues and starts
// when a running one finishes, and a blocking subagent always runs on its caller's worker.
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

// Subagent is the orchestrator's record of one subagent. Everything above reserved is fixed
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
	lock_directory:               string,
	parent_session:               journal.Session_Id,
	parent_call:                  journal.Call_Id, // the orchestrator's call that started it
	session:                      journal.Session_Id, // the child session, named when the start was recorded
	parent_session_hex:           [journal.SESSION_ID_HEX_LENGTH]u8, // read through chat_parent_session
	run:                          journal.Run_Id, // the run the subagent's own journal writes under
	disable_project_instructions: bool,
	team:                         ^Agent_Team, // the orchestrator's, which outlives every member
	allocator:                    mem.Allocator,

	// closed, guarded by team.mutex, says the subagent takes no more messages, so a message
	// is either answered by the subagent or refused to its sender. reserved counts the
	// senders that have checked closed and not yet committed their message, and
	// reservations counts every sender that ever did: the subagent closes only while none
	// is reserved and none has reserved since it last read its inbox. Both are guarded by
	// team.mutex.
	closed:                       bool,
	reserved:                     int,
	reservations:                 int,
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
	session_id:                   string,
	status:                       Subagent_Status,
	answer:                       string, // the final answer, or why there is none
	done:                         bool, // atomic; set last
}

// Agent_Team is an orchestrator's subagents. It is heap-allocated apart from its session,
// because a subagent that does not stop keeps using it.
Agent_Team :: struct {
	mutex:     sync.Mutex,
	members:   [dynamic]^Subagent,
	started:   int,
	starting:  int,
	running:   int, // slots in use: running children, which a blocking child may take past SUBAGENTS_MAX_RUNNING
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
	tools:                        Tool_Registry,
	catalog:                      Catalog_Ref,
	acp_agents:                   []ACP_Agent_Config, // borrowed from the loaded config
}

@(require_results)
agent_team_make :: proc(allocator: mem.Allocator) -> ^Agent_Team {
	team, alloc_error := new(Agent_Team, allocator)
	if alloc_error != nil { return nil }
	team.allocator = allocator
	members, members_error := make([dynamic]^Subagent, allocator)
	if members_error != nil {
		free(team, allocator)
		return nil
	}
	team.members = members
	waiting, waiting_error := make([dynamic]^Subagent, allocator)
	if waiting_error != nil {
		delete(members)
		free(team, allocator)
		return nil
	}
	team.waiting = waiting
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
	levels, levels_error := make([]string, len(chat.effort_levels), allocator)
	if levels_error != nil { return false }
	out.effort_levels = levels
	directory := chat.store.directory if chat.store != nil else ""
	locks := chat.store.locks if chat.store != nil else ""
	clone_error: mem.Allocator_Error
	out.workspace, clone_error = strings.clone(chat.workspace, allocator)
	if clone_error != nil { return false }
	out.store_directory, clone_error = strings.clone(directory, allocator)
	if clone_error != nil { return false }
	out.lock_directory, clone_error = strings.clone(locks, allocator)
	if clone_error != nil { return false }
	out.provider_id, clone_error = strings.clone(chat.provider_id, allocator)
	if clone_error != nil { return false }
	out.model_id, clone_error = strings.clone(chat.model_id, allocator)
	if clone_error != nil { return false }
	out.effort, clone_error = strings.clone(chat.effort, allocator)
	if clone_error != nil { return false }
	for level, index in chat.effort_levels {
		out.effort_levels[index], clone_error = strings.clone(level, allocator)
		if clone_error != nil { return false }
	}
	out.session = chat.session
	if chat.store != nil { out.run = chat.store.run }
	out.disable_project_instructions = chat.disable_project_instructions
	out.catalog = chat.catalog
	out.acp_agents = chat.acp_agents
	failed = false
	return true
}

// agent_parent_temp_copy copies one parent snapshot into scratch memory, so a worker thread
// can keep using it after it releases the team lock. It reports false when a field could not
// be copied.
@(private, require_results)
agent_parent_temp_copy :: proc(parent: Agent_Parent, allocator: mem.Allocator) -> (snapshot: Agent_Parent, ok: bool) {
	snapshot = parent
	clone_error: mem.Allocator_Error
	snapshot.provider_id, clone_error = strings.clone(parent.provider_id, allocator)
	if clone_error != nil { return {}, false }
	snapshot.model_id, clone_error = strings.clone(parent.model_id, allocator)
	if clone_error != nil { return {}, false }
	snapshot.effort, clone_error = strings.clone(parent.effort, allocator)
	if clone_error != nil { return {}, false }
	snapshot.workspace, clone_error = strings.clone(parent.workspace, allocator)
	if clone_error != nil { return {}, false }
	snapshot.store_directory, clone_error = strings.clone(parent.store_directory, allocator)
	if clone_error != nil { return {}, false }
	snapshot.lock_directory, clone_error = strings.clone(parent.lock_directory, allocator)
	if clone_error != nil { return {}, false }
	levels, levels_error := make([]string, len(parent.effort_levels), allocator)
	if levels_error != nil { return {}, false }
	snapshot.effort_levels = levels
	for level, index in parent.effort_levels {
		snapshot.effort_levels[index], clone_error = strings.clone(level, allocator)
		if clone_error != nil { return {}, false }
	}
	return snapshot, true
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
		if _, append_error := append(&finished, member); append_error != nil {
			// The list of finished members could not grow; they are reaped next time.
			break
		}
		ordered_remove(&team.members, index)
	}
	sync.mutex_unlock(&team.mutex)
	if chat != nil && chat.store != nil && len(finished) > 0 {
		for member in finished { subagent_record_completion(chat, member) }
		// A commit that fails records the failure on the session, which is what the next
		// turn reports; there is nothing this reap can do with it here.
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
	case .Failed, .Running, .Queued:
	}
	chat_record(
		chat,
		{kind = .Subagent_Completed, call = member.parent_call, subagent = member.session},
		journal.Subagent_Completed{outcome = journal.TOOL_OUTCOME_NAMES[outcome], detail = detail, name = member.name},
		transmute([]u8)body,
	)
}

// agent_team_destroy stops every subagent, waits for them within the stop patience, and
// releases the team. A subagent that does not stop keeps the team: both leak, and the
// session is released anyway. Each such subagent is recorded as abandoned in chat's
// journal, so the owner of that journal is the only caller.
agent_team_destroy :: proc(team: ^Agent_Team, chat: ^Chat_Session, retain := false) -> bool {
	if team == nil { return true }
	sync.mutex_lock(&team.mutex)
	team.closing = true
	for member in team.members { subagent_request_stop(member) }
	sync.mutex_unlock(&team.mutex)
	subagent_stop_waiting(team)
	owner_wake_signal()
	began := time.tick_now()
	deadline := time.tick_add(began, TOOL_JOBS_STOP_PATIENCE)
	for {
		seen := owner_wake_seen()
		// Teardown commits nothing more; recovery closes what this leaves open.
		agent_team_reap(team, nil)
		if !agent_team_running(team) { break }
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
	subagent_program_destroy(&member.program, allocator)
	tool_wake_close(&member.wake)
	delete(member.effort, allocator)
	tool_registry_destroy(&member.tools)
	delete(member.workspace, allocator)
	delete(member.store_directory, allocator)
	delete(member.lock_directory, allocator)
	delete(member.session_id, allocator)
	delete(member.answer, allocator)
	free(member, allocator)
}

// subagent_start defines one subagent from a start call and adds it to the team. It resolves
// the model, the orchestrator's by default, and the effort, one level below the orchestrator's
// by default. problem, temp-allocated, says why nothing started. Worker thread.
@(require_results)
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
	defer {
		sync.mutex_lock(&team.mutex)
		team.starting -= 1
		sync.mutex_unlock(&team.mutex)
		owner_wake_signal()
	}
	// The snapshot is copied into scratch memory while the lock is held, so the owner
	// replacing it cannot release what this start still reads.
	parent, parent_ok := agent_parent_temp_copy(team.parent, context.temp_allocator)
	sync.mutex_unlock(&team.mutex)
	if !parent_ok { return nil, "the orchestrator's selection could not be copied" }
	tools, tools_error := tool_registry_clone(&parent.tools, allocator)
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
		team                         = team,
		allocator                    = allocator,
	}
	tools = {}
	// The record's own texts are copied now that it exists, so a copy that fails releases
	// the record instead of starting a half-defined subagent.
	failed := true
	defer if failed { subagent_destroy(created) }
	clone_error: mem.Allocator_Error
	created.instruction, clone_error = strings.clone(args.instruction, allocator)
	if clone_error != nil { return nil, "the subagent could not be allocated" }
	created.prompt, clone_error = strings.clone(args.prompt, allocator)
	if clone_error != nil { return nil, "the subagent could not be allocated" }
	created.effort, clone_error = strings.clone(effort, allocator)
	if clone_error != nil { return nil, "the subagent could not be allocated" }
	created.workspace, clone_error = strings.clone(parent.workspace, allocator)
	if clone_error != nil { return nil, "the subagent could not be allocated" }
	created.store_directory, clone_error = strings.clone(parent.store_directory, allocator)
	if clone_error != nil { return nil, "the subagent could not be allocated" }
	created.lock_directory, clone_error = strings.clone(parent.lock_directory, allocator)
	if clone_error != nil { return nil, "the subagent could not be allocated" }
	if program.name != "" {
		wake, wake_error := tool_wake_open()
		if wake_error != nil {
			return nil, "the subagent's stop signal could not be created"
		}
		created.wake = wake
	}
	sync.mutex_lock(&team.mutex)
	if team.closing {
		sync.mutex_unlock(&team.mutex)
		return nil, "the orchestrator is closing; nothing started"
	}
	team.started += 1
	created.name = fmt.aprintf("agent-%d", team.started, allocator = allocator)
	if _, append_error := append(&team.members, created); append_error != nil {
		sync.mutex_unlock(&team.mutex)
		return nil, "the subagent could not be allocated"
	}
	sync.mutex_unlock(&team.mutex)
	failed = false
	member = created
	return member, ""
}

// subagent_select resolves the model and effort a native subagent runs. problem, temp-allocated,
// says why it cannot run; selection is then empty.
@(private, require_results)
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

// subagent_launch starts a background subagent on a thread of its own, or queues it when
// SUBAGENTS_MAX_RUNNING slots are in use. It returns false when the subagent neither started nor
// queued; a failed thread creation leaves the slot held, which subagent_finish releases.
// queued says the subagent waits for a slot: it may start, finish, and be released at any
// moment after, so the caller must not touch member again.
@(require_results)
subagent_launch :: proc(member: ^Subagent) -> (queued, ok: bool) {
	team := member.team
	member.stop.parent = &process_interrupt
	sync.mutex_lock(&team.mutex)
	// A closing team has already asked every member to stop, so this one starts only to end.
	if team.running >= SUBAGENTS_MAX_RUNNING && !team.closing {
		member.status = .Queued
		_, append_error := append(&team.waiting, member)
		sync.mutex_unlock(&team.mutex)
		return append_error == nil, append_error == nil
	}
	team.running += 1
	member.admitted = true
	sync.mutex_unlock(&team.mutex)
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

// subagent_finish closes the subagent's inbox, releases its slot, and marks it done, which
// wakes the orchestrator to reap it: the reap commits the outcome the orchestrator reads
// from its journal. It then starts the queued subagents the slot admits. A queued subagent
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
	sync.mutex_lock(&team.mutex)
	member.closed = true
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
	sync.mutex_unlock(&team.mutex)
	sync.atomic_store(&member.done, true)
	owner_wake_signal()
	return next
}

// Subagent_Answer keeps the text of the latest response, which is the final answer once the
// subagent's turn ends. failed says the text it holds is not all of it.
@(private)
Subagent_Answer :: struct {
	text:   [dynamic]u8,
	failed: bool,
}

@(private)
subagent_answer_restart :: proc(user_data: rawptr) {
	answer := cast(^Subagent_Answer)user_data
	clear(&answer.text)
}

@(private)
subagent_answer_text :: proc(user_data: rawptr, text: string) {
	answer := cast(^Subagent_Answer)user_data
	if _, append_error := append(&answer.text, text); append_error != nil { answer.failed = true }
}

// subagent_fail records why a subagent ended. The status is the outcome either way; a reason
// that cannot be kept leaves the status as the whole outcome.
@(private)
subagent_fail :: proc(member: ^Subagent, status: Subagent_Status, reason: string) {
	member.status = status
	delete(member.answer, member.allocator)
	clone_error: mem.Allocator_Error
	member.answer, clone_error = strings.clone(reason, member.allocator)
	if clone_error != nil { member.answer = "" }
}

// subagent_run runs the subagent's session until it answers its task and every message its
// orchestrator sent after that, and records the outcome in member. Runs on the subagent's own
// thread and reaches nothing of the orchestrator's except the team.
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
	session_text, session_error := strings.clone(journal.session_id_to_hex(session_id, session_hex[:]), allocator)
	if session_error != nil {
		subagent_fail(member, .Failed, "the subagent's session id could not be held")
		return
	}
	member.session_id = session_text

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
	agent_team_destroy(chat.team, &chat)
	chat.team = nil
	chat.member = member
	chat.stop_parent = &member.stop
	chat.disable_project_instructions = member.disable_project_instructions
	role_instructions, role_error := strings.concatenate({SUBAGENT_ROLE, "\n\n", member.instruction}, allocator)
	if role_error != nil {
		subagent_fail(member, .Failed, "the subagent's instructions could not be held")
		return
	}
	chat.role_instructions = role_instructions
	if replace_error := chat_session_replace_tools(&chat, &member.tools); replace_error != .None {
		subagent_fail(member, .Failed, "the subagent's tools could not be installed")
		return
	}
	installed, _ := chat_session_select(&chat, member.selection, member.effort)
	if !installed {
		subagent_fail(member, .Failed, "the subagent's model could not be held")
		return
	}

	answer := Subagent_Answer {
		text = make([dynamic]u8, allocator),
	}
	defer delete(answer.text)
	observer := Chat_Observer {
		user_data        = &answer,
		request_prepared = subagent_answer_restart,
		assistant_text   = subagent_answer_text,
	}
	// The task is the first message, so what the orchestrator sent while this subagent
	// waited for a slot is delivered after it, at the first settled point.
	text, origin, inbox_first := member.prompt, journal.User_Origin.Prompt, false
	for {
		accepted := chat_session_accept_message(&chat, text, origin, {}, inbox_first)
		if accepted != .Accepted {
			subagent_fail(member, .Failed, chat.last_error if chat.last_error != "" else "the task could not be recorded")
			return
		}
		if !chat_turn_drive(&chat, member.selection.connection, chat_retry_policy_default(), observer, nil, nil) {
			if chat.terminal_status == .Cancelled {
				subagent_fail(member, .Stopped, "the subagent was stopped before it finished")
			} else {
				subagent_fail(member, .Failed, chat.last_error if chat.last_error != "" else "the subagent's turn did not complete")
			}
			return
		}
		// Steering answers every message taken before the turn settled. One that arrived
		// after its last check starts the next turn, which delivers it, and the inbox closes
		// only when nothing waits.
		_, next := subagent_next_messages(member, &store, chat.delivered)
		if next == .Failed {
			subagent_fail(member, .Failed, "the subagent's inbox could not be read")
			return
		}
		if next == .Closed { break }
		text, origin, inbox_first = "", .Agent, true
	}
	// An answer that was not kept whole, or cannot be held at all, is not the answer the
	// orchestrator asked for, so the outcome says the delegation failed rather than
	// reporting a short one as a completion.
	if answer.failed {
		subagent_fail(member, .Failed, "the subagent's answer could not be recorded")
		return
	}
	answer_text, answer_error := strings.clone(string(answer.text[:]), allocator)
	if answer_error != nil {
		subagent_fail(member, .Failed, "the subagent's answer could not be recorded")
		return
	}
	member.status = .Completed
	member.answer = answer_text
}

// Subagent_Next says what a subagent does after its turn: take the messages that wait,
// finish because its inbox is closed, or fail because it could not be read.
Subagent_Next :: enum {
	Closed,
	Messages,
	Failed,
}

// subagent_next_messages returns the messages the orchestrator committed to member's inbox
// after seq after, in temp memory, or closes the inbox when there are none. A sender
// reserves the inbox before it commits its message and releases it after, and the inbox
// closes only while no sender holds it and none reserved it since the read: a message
// sent at the same moment is either returned here or refused to its sender.
@(private, require_results)
subagent_next_messages :: proc(member: ^Subagent, store: ^journal.Journal, after: journal.Journal_Seq) -> (records: []journal.Record, next: Subagent_Next) {
	team := member.team
	for {
		seen := owner_wake_seen()
		sync.mutex_lock(&team.mutex)
		if member.reserved > 0 {
			// The sender is between its check and its commit; its release wakes this wait.
			sync.mutex_unlock(&team.mutex)
			owner_wake_wait(seen, nil)
			continue
		}
		reservations := member.reservations
		sync.mutex_unlock(&team.mutex)

		read, read_error := journal.read_inbox(store, member.session, after, context.temp_allocator)
		if read_error != nil {
			sync.mutex_guard(&team.mutex)
			member.closed = true
			return nil, .Failed
		}
		if len(read) > 0 { return read, .Messages }

		sync.mutex_lock(&team.mutex)
		if member.reserved == 0 && member.reservations == reservations {
			member.closed = true
			sync.mutex_unlock(&team.mutex)
			return nil, .Closed
		}
		sync.mutex_unlock(&team.mutex)
	}
}

// subagent_find returns the running member named name. The caller holds team.mutex.
@(private)
subagent_find :: proc(team: ^Agent_Team, name: string) -> ^Subagent {
	for member in team.members {
		if member.name == name { return member }
	}
	return nil
}

// subagent_reserve holds the inbox of the subagent named name open for one message, and
// returns it. The sender records the message, commits, and calls subagent_release, so the
// subagent cannot close between the check and the commit. problem, temp-allocated, says
// why the message cannot be sent.
@(require_results)
subagent_reserve :: proc(team: ^Agent_Team, name: string) -> (member: ^Subagent, problem: string) {
	sync.mutex_guard(&team.mutex)
	member = subagent_find(team, name)
	if member == nil { return nil, subagent_unknown(team, name) }
	if member.closed { return nil, fmt.tprintf("%s has finished and takes no more messages", name) }
	member.reserved += 1
	member.reservations += 1
	return member, ""
}

// subagent_release ends a reservation after the message's commit, whether it landed or
// not, and wakes the subagent to read it.
subagent_release :: proc(member: ^Subagent) {
	{
		sync.mutex_guard(&member.team.mutex)
		member.reserved -= 1
	}
	owner_wake_signal()
}

// subagent_stop asks a subagent to stop. Its outcome reaches the orchestrator like any other.
// A queued subagent never starts: it is reported stopped at once.
@(require_results)
subagent_stop :: proc(team: ^Agent_Team, name: string) -> (problem: string) {
	defer owner_wake_signal()
	sync.mutex_lock(&team.mutex)
	member := subagent_find(team, name)
	if member == nil {
		problem = subagent_unknown(team, name)
		sync.mutex_unlock(&team.mutex)
		return problem
	}
	if member.closed {
		sync.mutex_unlock(&team.mutex)
		return fmt.tprintf("%s has already finished", name)
	}
	if member.status == .Queued {
		subagent_unqueue(team, member)
		sync.mutex_unlock(&team.mutex)
		subagent_end_unstarted(member)
		return ""
	}
	subagent_request_stop(member)
	sync.mutex_unlock(&team.mutex)
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
	member.closed = true
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
		sync.mutex_lock(&team.mutex)
		if len(team.waiting) == 0 {
			sync.mutex_unlock(&team.mutex)
			return
		}
		member := team.waiting[0]
		subagent_unqueue(team, member)
		sync.mutex_unlock(&team.mutex)
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
	agent_team_reap(chat.team, chat)
	return chat_inbox_reports_pending(chat) || running
}

// chat_agents_wait blocks until an agent's report or message waits, and reports false
// instead when no subagent runs any more or stop is requested. Owner only.
@(require_results)
chat_agents_wait :: proc(chat: ^Chat_Session, stop: ^ai.Interrupt) -> bool {
	if chat.team == nil { return false }
	for {
		seen := owner_wake_seen()
		running := agent_team_running(chat.team)
		agent_team_reap(chat.team, chat)
		if chat_inbox_reports_pending(chat) { return true }
		if !running || ai.interrupt_requested(stop) || ai.interrupt_requested(&process_interrupt) { return false }
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
