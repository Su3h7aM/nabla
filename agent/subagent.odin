package agent

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
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
SUBAGENT_ROLE :: "You are a subagent. An orchestrator agent started you for one task, stated in the first message, and it reads only your final answer. You do not see the orchestrator's conversation: the task message and what your tools find are all you have.\n\nStay inside the task. Do what it asks and return what it asks for; do not fix, refactor, or investigate beyond it, even when you notice something nearby, and mention such things in one line of your answer instead. Work with your tools until the task is done, then answer concisely with exactly what the task asked you to return: findings, decisions, and exact paths, line numbers, and identifiers. Do not narrate your process or paste file contents the task did not ask for.\n\nThe orchestrator may message you while you work. Its messages start with \"orchestrator says\" and override the original task where they conflict. Use agent with action message, leaving agent out, to reach the orchestrator before you finish when information you need is missing or ambiguous, when the task rests on a wrong premise, or when you find something it should act on now. Ask rather than guess on a decision that would change the result. After sending, keep working on what does not depend on the reply; the reply arrives as a message between your steps. If nothing is left that you can do without it, finish with an answer that states what you found and what is missing. You cannot start subagents or reach other subagents; the orchestrator relays between you when needed.\n\nYou share the workspace with the orchestrator and possibly other subagents working at the same time. Edit only the files your task covers. Do not revert, reformat, or overwrite changes you did not make, and do not run commands that discard work you did not do, such as resetting version control, checking out files, or deleting files you did not create. If a change you did not make is in your way, or your task needs a file outside its scope, ask the orchestrator with agent action message instead of acting."

// Subagent is the orchestrator's record of one running or just finished subagent. Its inputs
// are owned by allocator, and its Job lifecycle belongs to the orchestrator. The subagent's
// worker writes the outcome fields and publishes; the orchestrator reads them only after it
// sees publication, and then frees the record, retiring the worker first, or runs
// the same record again when a message arrived too late for the run that just ended.
Subagent :: struct {
	worker:          Job,
	name:            string,
	instruction:     string,
	prompt:          string,
	program:         Subagent_Program, // the native or configured ACP program
	effort:          string,
	workspace:       string,
	store_directory: string,
	lock_directory:  string,
	parent_session:  journal.Session_Id,
	parent_call:     journal.Call_Id, // the orchestrator's call that started it
	session:         journal.Session_Id, // the child session, named when the start was recorded
	run:             journal.Run_Id, // the run the subagent's own journal writes under
	background:      bool, // delivers its outcome to the orchestrator's inbox rather than as a call's result
	resumed:         bool, // the client resumes its existing ACP session
	compact:         bool, // a resumed child compacts its context first; with no prompt it ends once the summary is installed
	team:            ^Agent_Team, // the orchestrator's, which outlives every member
	allocator:       mem.Allocator,
	// configuration and installed model, effort, and consumed inbox sequence are guarded by team.mutex.
	configuration:   ACP_Configure,
	admitted:        bool, // holds one of team.running's slots; guarded by team.mutex
	ready:           bool, // its slot was handed over; the owner must launch it; guarded by team.mutex
	tabled:          bool, // team.members holds it; shared reclaim waits until it leaves the table
	// stop ends the subagent's work. It chains to the call that waits for it, or to the
	// process interrupt for a background subagent.
	stop:            ai.Interrupt,
	// wake retains notifications from the ACP readers and stop requests.
	wake:            sync.Sema,
	acp_after:       journal.Journal_Seq,
	acp_session:     string, // the ACP agent's own session id; "" for a native subagent, whose session is session
	status:          Subagent_Status,
	cause:           string, // why the subagent did not complete; "" once it completed
	answer:          string, // its last streamed answer, partial when it failed or was stopped mid-answer
	finished:        bool, // atomic; blocking or unstarted members only, which have no launched Job
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
	retained:  bool, // owner-only: a child Job was abandoned, so the team stays allocated
	allocator: mem.Allocator,
	// parent is what a start copies from the orchestrator. The owner writes it under mutex
	// when it admits a start.
	parent:    Agent_Parent,
}

Agent_Parent :: struct {
	session:               journal.Session_Id,
	run:                   journal.Run_Id,
	workspace:             string,
	store_directory:       string,
	lock_directory:        string,
	provider_id:           string,
	model_id:              string,
	effort:                string,
	effort_levels:         []string,
	subagents_max_running: int, // zero means SUBAGENTS_MAX_RUNNING
	nabla_executable:      string,
	nabla_config:          string,
	catalog:               Catalog_Ref,
	acp_agents:            []ACP_Agent_Config, // borrowed from the loaded config
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
	delete(parent.nabla_executable, allocator)
	delete(parent.nabla_config, allocator)
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

	source := Agent_Parent {
		nabla_executable = chat.nabla_executable,
		nabla_config     = chat.nabla_config,
		workspace        = chat.workspace,
		store_directory  = chat.store.directory if chat.store != nil else "",
		lock_directory   = chat.store.locks if chat.store != nil else "",
		provider_id      = chat.provider_id,
		model_id         = chat.model_id,
		effort           = chat.effort,
		effort_levels    = chat.effort_levels[:],
	}
	if agent_parent_clone_strings(source, out, allocator) != nil { return false }
	out.session = chat.session
	if chat.store != nil { out.run = chat.store.run }

	out.subagents_max_running = chat.subagents_max_running
	out.catalog = chat.catalog
	out.acp_agents = chat.acp_agents
	failed = false
	return true
}

@(private, require_results)
agent_parent_clone_strings :: proc(parent: Agent_Parent, out: ^Agent_Parent, allocator: mem.Allocator) -> mem.Allocator_Error {
	out.nabla_executable = strings.clone(parent.nabla_executable, allocator) or_return
	out.nabla_config = strings.clone(parent.nabla_config, allocator) or_return
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

// agent_team_launch_ready launches the queued members that a finishing child handed a slot.
// Both member and waiting tables keep admission order. Owner only; thread creation is outside
// the mutex, so a child finishing its own slot never waits on it.
@(private)
agent_team_launch_ready :: proc(team: ^Agent_Team) {
	for {
		member: ^Subagent
		{
			sync.mutex_guard(&team.mutex)
			for pending in team.members {
				if !pending.ready { continue }
				pending.ready = false
				member = pending
				break
			}
		}
		if member == nil { return }
		if team.closing {
			subagent_end_unstarted(member)
			continue
		}
		if !job_launch(&member.worker) {
			subagent_fail(member, .Failed, "its thread could not be created")
			subagent_finish(member)
		}
	}
}

// agent_team_reap launches ready members, then releases every finished subagent and, given the orchestrator's
// session, commits each one's subagent.completed there first. A background child that
// completed while a parent message waits unread is run again before its completion is recorded.
// A pending configure first commits the old completion, then opens another delegation.
// Abandoned clients leave the table but remain allocated until shared reclaim.
// Owner only.
agent_team_reap :: proc(team: ^Agent_Team, chat: ^Chat_Session) -> (reopened: bool) {
	if team == nil { return false }
	agent_team_launch_ready(team)
	finished: [dynamic]^Subagent
	finished.allocator = context.temp_allocator
	{
		sync.mutex_guard(&team.mutex)
		for index := 0; index < len(team.members); {
			member := team.members[index]
			if !subagent_finished(member) {
				index += 1
				continue
			}
			if _, append_error := append(&finished, member); append_error != nil {
				// The list of finished members could not grow; they are reaped next time.
				break
			}
			member.tabled = false
			ordered_remove(&team.members, index)
		}
	}
	if chat != nil && chat.store != nil {
		for index := 0; index < len(finished); {
			member := finished[index]
			pending := false
			{
				sync.mutex_guard(&team.mutex)
				pending = member.configuration.switching || member.configuration.compact
			}
			if pending && member.worker.phase != .Abandoned {
				subagent_record_completion(chat, member)
				if chat_commit(chat, "the subagent's outcome before configuration could not be recorded") {
					if problem := acp_resume_configure(chat, member); problem != "" { chat_runtime_message(chat, .Error, problem) }
				}
				ordered_remove(&finished, index)
				if member.worker.thread != nil { job_retire(&member.worker) }
				subagent_destroy(member)
				reopened = true
				continue
			}
			if acp_resume_pending(chat, member) {
				ordered_remove(&finished, index)
				reopened = true
				continue
			}
			index += 1
		}
		if len(finished) > 0 {
			for member in finished {
				if member.worker.phase != .Abandoned { subagent_record_completion(chat, member) }
			}
			// A commit that fails records the failure on the session, which is what the next
			// turn reports; there is nothing this reap can do with it here.
			_ = chat_commit(chat, "a subagent's outcome could not be recorded")
		}
	}
	for member in finished {
		if member.worker.phase == .Abandoned { continue }
		if member.worker.thread != nil { job_retire(&member.worker) }
		subagent_destroy(member)
	}
	return reopened
}

// acp_resume_pending runs member again, on the same record, when it completed in the
// background while a parent message waits unread: it arrived after the run's last read.
// It reports whether it reopened the child. A failed, stopped, blocking, or abandoned child
// is not reopened; its message stays in the journal for its next resume. Owner only.
@(private, require_results)
acp_resume_pending :: proc(chat: ^Chat_Session, member: ^Subagent) -> bool {
	if member.status != .Completed || !member.background || member.worker.phase == .Abandoned { return false }
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	delivered := member.acp_after

	waiting, read_error := acp_inbox(chat.store, member, delivered, context.temp_allocator)
	if read_error != nil || len(waiting) == 0 { return false }
	team := member.team
	{
		sync.mutex_guard(&team.mutex)
		if _, append_error := append(&team.members, member); append_error != nil { return false }
		member.tabled = true
	}
	if member.worker.thread != nil { job_retire(&member.worker) }
	delete(member.answer, member.allocator)
	member.answer = ""
	delete(member.prompt, member.allocator)
	member.prompt = ""
	member.resumed = true
	member.stop = {}
	member.status = .Running
	sync.atomic_store(&member.finished, false)
	if _, launched := subagent_launch(member); !launched {
		subagent_fail(member, .Failed, "its thread could not be created")
		subagent_finish(member)
	}
	return true
}

// acp_resume_configure starts a new delegation for the accepted configure after the old outcome is committed.
@(private, require_results)
acp_resume_configure :: proc(chat: ^Chat_Session, previous: ^Subagent) -> string {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	configuration := previous.configuration
	update := Agent_Message_Args {
		action  = .Configure,
		agent   = previous.name,
		model   = configuration.model,
		effort  = configuration.effort,
		compact = configuration.compact,
	}
	session, problem := subagent_resume_plan(chat, previous.team, &update)
	if problem != "" { return problem }
	chat_record(
		chat,
		{kind = .Subagent_Started, call = configuration.call, subagent = session},
		journal.Subagent_Started {
			name = previous.name,
			program = update.resume.program,
			model = configuration.model,
			effort = configuration.effort,
			background = true,
		},
		transmute([]u8)update.resume.instruction,
	)
	if !chat_commit(chat, "the continued configuration could not be recorded") { return "the subagent configuration continuation was not started" }
	start := Agent_Start_Args {
		instruction = update.resume.instruction,
		acp_agent   = update.resume.program,
	}
	if start.acp_agent != "" { start.model, start.effort = update.resume.model_id, update.resume.effort }
	member, start_problem := subagent_start(previous.team, start, configuration.call, session, previous.allocator, update.resume)
	if member == nil {
		chat_record(
			chat,
			{kind = .Subagent_Completed, call = configuration.call, subagent = session},
			journal.Subagent_Completed{outcome = journal.TOOL_OUTCOME_NAMES[.Tool_Failed], detail = start_problem},
		)
		_ = chat_commit(chat, "the configuration startup failure could not be recorded")
		return start_problem
	}
	member.compact = false
	member.configuration = configuration
	previous.configuration = {}
	if _, launched := subagent_launch(member); !launched {
		subagent_fail(member, .Failed, "its configuration thread could not be created")
		subagent_finish(member)
		return "the subagent configuration thread could not be created"
	}
	return ""
}

// subagent_record_completion buffers the subagent.completed that closes a member's
// delegation: the outcome, the cause in detail, and its last streamed answer
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
			acp_effort = member.effort,
		},
		transmute([]u8)member.answer,
	)
}

// agent_team_destroy closes admission, requests every stop, and waits the worker stop patience.
// Abandoned child Jobs keep the team allocated but are tracked by chat.abandoned. It returns
// false when untracked workers still reach the team or its bindings. Owner only.
agent_team_destroy :: proc(team: ^Agent_Team, chat: ^Chat_Session, retain := false) -> bool {
	if team == nil { return true }
	retain := retain
	began := time.tick_now()
	deadline := time.tick_add(began, TOOL_JOBS_STOP_PATIENCE)
	{
		sync.mutex_guard(&team.mutex)
		team.closing = true
		for member in team.members {
			subagent_request_stop(member)
			job_note_stop(&member.worker, true, began)
		}
	}
	subagent_stop_waiting(team)
	owner_wake_signal()
	for {
		seen := owner_wake_seen()
		// Teardown commits no completions; recovery closes what it leaves open.
		agent_team_reap(team, nil)
		member: ^Subagent
		starting: bool
		member_index: int
		{
			sync.mutex_guard(&team.mutex)
			starting = team.starting > 0
			if len(team.members) > 0 { member = team.members[0] }
			for pending, index in team.members {
				if pending.worker.thread != nil {
					member = pending
					member_index = index
					break
				}
			}
		}
		if member == nil && !starting { break }
		if member != nil && member.worker.thread != nil {
			worker := &member.worker
			job_note_stop(worker, true, time.tick_now())
			if job_wait_published(worker, job_stop_deadline(worker)) { continue }
			if !job_overdue(worker, time.tick_now()) { continue }
			listed := len(chat.abandoned)
			job_abandon(chat, worker)
			if len(chat.abandoned) == listed { retain = true }
			{
				sync.mutex_guard(&team.mutex)
				ordered_remove(&team.members, member_index)
				member.tabled = false
			}
			team.retained = true
			continue
		}
		// A blocking child borrows its caller's worker, and a start may not yet have a
		// member at all. Neither has a Job of its own to wait for or abandon.
		if time.tick_diff(time.tick_now(), deadline) <= 0 {
			for pending in team.members {
				if subagent_finished(pending) { continue }
				chat_record_job_abandoned(chat, {call = pending.parent_call, subagent = pending.session}, .Subagent, time.tick_since(began))
			}
			return false
		}
		owner_wake_wait(seen, deadline)
	}
	if retain { return false }
	if team.retained { return true }
	delete(team.members)
	delete(team.waiting)
	agent_parent_destroy(&team.parent, team.allocator)
	free(team, team.allocator)
	return true
}

// subagent_finished reports publication for a launched Job, or completion of a blocking or
// unstarted member that has no worker of its own. Owner only.
@(private, require_results)
subagent_finished :: proc(member: ^Subagent) -> bool {
	if member.worker.thread != nil { return job_published(&member.worker) }
	return sync.atomic_load(&member.finished)
}

// agent_team_running reports whether a subagent the team started is not yet released. Owner only.
@(require_results)
agent_team_running :: proc(team: ^Agent_Team) -> bool {
	if team == nil { return false }
	sync.mutex_guard(&team.mutex)
	if team.starting > 0 { return true }
	for member in team.members {
		if !subagent_finished(member) { return true }
	}
	return false
}

subagent_destroy :: proc(member: ^Subagent) {
	allocator := member.allocator
	delete(member.name, allocator)
	delete(member.instruction, allocator)
	delete(member.prompt, allocator)
	acp_configure_destroy(&member.configuration)
	subagent_program_destroy(&member.program, allocator)
	delete(member.effort, allocator)

	delete(member.workspace, allocator)
	delete(member.store_directory, allocator)
	delete(member.lock_directory, allocator)
	delete(member.acp_session, allocator)
	delete(member.cause, allocator)
	delete(member.answer, allocator)
	free(member, allocator)
}

// subagent_name is the id the orchestrator's model knows the child by: it names the
// start call, so the same call has the same name in every process. The result is
// allocated with allocator.
@(require_results)
subagent_name :: proc(call: journal.Call_Id, allocator: mem.Allocator) -> string {
	return fmt.aprintf("agent-%d", call, allocator = allocator)
}

// background_job_name returns the stable call-based id of a background tool, allocated with allocator.
@(require_results)
background_job_name :: proc(call: journal.Call_Id, allocator: mem.Allocator) -> string {
	return fmt.aprintf("job-%d", call, allocator = allocator)
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
// allocator must outlive retained process workers: use a general heap allocator, not an arena
// or pool. A stuck ACP transport may allocate and free through it after member reclaim.
// Worker thread or owner.
@(require_results)
subagent_start :: proc(
	team: ^Agent_Team,
	args: Agent_Start_Args,
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
		// The snapshot is copied under the lock so the owner cannot release its strings during the copy.
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

	program: Subagent_Program
	effort := args.effort
	program, effort, problem = acp_program(args, &parent, resume, allocator)
	if problem != "" { return nil, problem }

	created := new(Subagent, allocator)
	if created == nil {

		subagent_program_destroy(&program, allocator)
		return nil, "the subagent could not be allocated"
	}
	created^ = {
		worker = {kind = .Subagent, run = acp_worker_run, allocator = allocator, record = {call = call, subagent = session}},
		program = program,
		parent_session = parent.session,
		parent_call = call,
		session = session,
		run = parent.run,
		background = !args.wait,
		resumed = resume.name != "",
		compact = resume.compact,
		team = team,
		allocator = allocator,
	}
	// The record's own texts are copied now that it exists, so a copy that fails releases
	// the record instead of starting a half-defined subagent.
	failed := true
	defer if failed { subagent_destroy(created) }
	if subagent_clone_strings(created, args, parent, effort, resume.name, call, allocator) != nil {
		return nil, "the subagent could not be allocated"
	}
	created.acp_session = strings.clone(resume.acp_session, allocator) or_else ""
	if resume.acp_session != "" && created.acp_session == "" { return nil, "the agent's session id could not be held" }
	created.acp_after = resume.after

	{
		sync.mutex_guard(&team.mutex)
		if team.closing { return nil, "the orchestrator is closing; nothing started" }
		if _, append_error := append(&team.members, created); append_error != nil {
			return nil, "the subagent could not be allocated"
		}
		created.tabled = true
	}
	failed = false
	member = created
	return member, ""
}

@(private, require_results)
subagent_clone_strings :: proc(
	created: ^Subagent,
	args: Agent_Start_Args,
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

// subagent_launch starts a background subagent on a thread of its own, or queues it when
// the configured number of slots are in use. It returns false when the subagent neither started
// nor queued; a failed thread creation leaves the slot held, which subagent_finish releases.
// queued says the subagent waits for a slot: it may start, finish, and be released at any
// moment after, so the caller must not touch member again. Owner only.
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
	return false, job_launch(&member.worker)
}

// subagent_take_slot counts a blocking subagent among the running ones, past the bound if need
// be, until subagent_finish releases it.
@(private)
subagent_take_slot :: proc(member: ^Subagent) {
	sync.mutex_guard(&member.team.mutex)
	member.team.running += 1
	member.admitted = true
}

// acp_worker_run runs the child and hands its slot to the queue before job_main publishes.
@(private)
acp_worker_run :: proc(worker: ^Job) {
	member := container_of(worker, Subagent, "worker")
	subagent_acp_run(member)
	subagent_conclude(member)
}

// subagent_finish concludes a blocking or unstarted member, which has no launched Job.
// Nothing touches the member after the finished store.
subagent_finish :: proc(member: ^Subagent) {
	subagent_conclude(member)
	sync.atomic_store(&member.finished, true)
	owner_wake_signal()
}

// subagent_conclude hands the slot to the oldest queued member and wakes the owner to
// launch it. It touches only the team-mutex-protected scheduling state, never the Job.
@(private)
subagent_conclude :: proc(member: ^Subagent) {
	team := member.team
	{
		sync.mutex_guard(&team.mutex)
		if member.admitted {
			member.admitted = false
			team.running -= 1
			if len(team.waiting) > 0 && !team.closing {
				next := team.waiting[0]
				ordered_remove(&team.waiting, 0)
				next.status = .Running
				next.admitted = true
				next.ready = true
				team.running += 1
			}
		}
	}
	owner_wake_signal()
}

// SUBAGENT_NO_CAUSE is what the orchestrator reads when a child failed and its session kept
// no account of why.
SUBAGENT_NO_CAUSE :: "the subagent ended without recording why"

// subagent_fail records why a subagent ended. The status is the outcome either way; a reason
// that cannot be kept leaves the status as the whole outcome. An empty reason becomes
// SUBAGENT_NO_CAUSE, so a failure always reaches the orchestrator with a cause.
@(private)
subagent_fail :: proc(member: ^Subagent, status: Subagent_Status, reason: string) {
	sync.mutex_guard(&member.team.mutex)
	member.status = status
	delete(member.cause, member.allocator)
	member.cause = strings.clone(reason if reason != "" else SUBAGENT_NO_CAUSE, member.allocator) or_else ""
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
	started: journal.Subagent_Started
	if journal.payload_decode(start.data, &started, context.temp_allocator) != nil { return "the subagent definition could not be read" }
	name, name_error := strings.clone(started.name, chat.allocator)
	if name_error != nil || name == "" { return "the subagent name could not be held" }
	installed := false
	defer if !installed { delete(name, chat.allocator) }
	instructions, instructions_error := strings.concatenate({SUBAGENT_ROLE, "\n\n", string(start.body)}, chat.allocator)
	if instructions_error != nil { return "the subagent's instructions could not be held" }
	defer if !installed { delete(instructions, chat.allocator) }
	tools, tools_error := tool_registry_clone(base, chat.allocator)
	if tools_error.kind != .None { return "the subagent's tools could not be copied" }
	defer if !installed { tool_registry_destroy(&tools) }
	previous_role := chat.role
	chat.role = .Subagent
	if chat_session_replace_tools(chat, &tools) != .None {
		chat.role = previous_role
		return "the subagent's tools could not be installed"
	}
	chat.parent_session = summaries[0].parent_session
	delete(chat.subagent_name, chat.allocator)
	chat.subagent_name = name
	delete(chat.role_instructions, chat.allocator)
	chat.role_instructions = instructions
	installed = true
	agent_team_destroy(chat.team, chat)
	chat.team = nil
	return ""
}

// subagent_find returns the running member named name. The caller holds team.mutex.
@(private)
subagent_find :: proc(team: ^Agent_Team, name: string) -> ^Subagent {
	for member in team.members {
		if member.name == name { return member }
	}
	return nil
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
			if journal.payload_decode(completion.data, &completed, context.temp_allocator) == nil {
				entry.acp_model = completed.acp_model
				entry.acp_effort = completed.acp_effort
				entry.acp_session = completed.acp_session
				entry.after = completed.acp_after
			}
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

// subagent_resume_plan finds the child update names among the delegations the orchestrator's
// journal records, and fills update.resume with what continuing it needs: its instruction from
// its newest start and its newest installed or turn selection. It returns the child's session, and
// has checked that the selection the call names resolves, so a refused call records nothing.
// problem, temp-allocated, says why the child cannot be continued; for a name the journal
// does not know it lists the children it does, with how each ended. update.resume stays empty on
// a problem. Owner only.
@(private)
subagent_resume_plan :: proc(chat: ^Chat_Session, team: ^Agent_Team, update: ^Agent_Message_Args) -> (child: journal.Session_Id, problem: string) {
	name := update.agent
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

	ended, finished := target.outcome, target.finished
	if !finished { return {}, fmt.tprintf("%s has not finished", name) }
	if ended == .Not_Executed {
		return {}, fmt.tprintf("%s never started, so it has no session to continue; start a new one with agent action start", name)
	}

	if target.program != "" {
		if target.acp_session == "" { return {}, "the ACP agent has no recorded session id to resume; start a new one with agent action start" }
		update.resume = {
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
		after       = target.after,
		compact     = update.compact,
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
	_, _, problem = acp_native_model(update.provider, update.model, update.effort, &team.parent, continued)
	if problem != "" { return {}, problem }
	update.resume = continued
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
			if member := subagent_find(team, child.name); member != nil {
				child.after = member.acp_after
				if !subagent_native(member) {
					cloned, clone_error := strings.clone(member.acp_session, context.temp_allocator)
					if clone_error != nil { return "", "the ACP agent's session id could not be held" }
					child.acp_session = cloned
				}
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
	recipient := Subagent {
		parent_session = parent,
		session        = child_session,
	}
	unread, inbox_error := acp_inbox(store, &recipient, target.after, context.temp_allocator)
	if inbox_error != nil { return "", "the child's unread messages could not be read" }
	fmt.sbprintf(&block, "unread messages: %d\n", len(unread))
	if target.finished && target.outcome != .Not_Executed && target.program == "" {
		fmt.sbprintf(&block, "resume: agent(%s\"action\":\"message\",\"agent\":%q,\"message\":\"Continue your task.\"%s)\n", "{", name, "}")
	}
	return strings.to_string(block), ""
}

// subagent_stop asks a subagent to stop. Its outcome reaches the orchestrator like any other.
// A queued subagent never starts: it is reported stopped at once. Owner only.
@(require_results)
subagent_stop :: proc(team: ^Agent_Team, name: string) -> (problem: string) {
	defer owner_wake_signal()
	member: ^Subagent
	queued: bool
	{
		sync.mutex_guard(&team.mutex)
		member = subagent_find(team, name)
		if member == nil { return subagent_unknown(team, name) }
		if subagent_finished(member) { return fmt.tprintf("%s has already finished", name) }
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

// subagent_request_stop asks a subagent to stop and wakes it. Owner only, with team.mutex held.
@(private)
subagent_request_stop :: proc(member: ^Subagent) {
	ai.interrupt_request(&member.stop)
	sync.sema_post(&member.wake)
	job_note_stop(&member.worker, true, time.tick_now())
}

// subagent_wake_call_stop wakes a blocking subagent whose parent call was interrupted.
@(private)
subagent_wake_call_stop :: proc(team: ^Agent_Team, interrupt: ^ai.Interrupt) {
	if team == nil { return }
	sync.mutex_guard(&team.mutex)
	for member in team.members {
		if !member.background && member.stop.parent == interrupt { sync.sema_post(&member.wake) }
	}
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
	if chat.parent_session == {} { return "" }
	return journal.session_id_to_hex(chat.parent_session, chat.parent_session_hex[:])
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
