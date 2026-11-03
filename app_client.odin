#+build linux
package main

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"

import "nabla:agent"
import "nabla:agent/journal"

// session_client_open resolves start and records a fresh session, without taking its
// claim. The server runs the session; this process only follows it. The message is
// owned by setup.alloc.
@(require_results)
session_client_open :: proc(setup: ^Run_Setup, start: Session_Start, launch_workspace: string) -> (opened: Opened_Session, message: string, ok: bool) {
	allocator := setup.alloc
	defer if !ok { opened_session_destroy(&opened, allocator) }

	open_error: journal.Error
	opened.store, open_error = session_store_open(setup)
	if open_error != nil { return {}, session_error_message("cannot open the session database", open_error, allocator), false }

	requested := start
	if requested == nil { requested = Start_Fresh{} }
	switch id in requested {
	case Start_Fresh:
		created, create_error := journal.create_session(opened.store, {workspace = launch_workspace, role = .Main})
		if create_error != nil { return opened, session_error_message("cannot create the session", create_error, allocator), false }
		for {
			_, commit_error := journal.commit(opened.store)
			if commit_error == nil { break }
			if !journal.error_is_busy(commit_error) {
				return opened, session_error_message("cannot save the session", commit_error, allocator), false
			}
		}
		if release_error := journal.release(opened.store); release_error != nil {
			return opened, session_error_message("cannot release the session for the server", release_error, allocator), false
		}
		workspace, workspace_error := strings.clone(launch_workspace, allocator)
		if workspace_error != nil { return opened, fmt.aprintf("the new session's directory could not be stored", allocator = allocator), false }
		opened.id = created
		opened.workspace = workspace
		opened.branch = journal.INITIAL_BRANCH
		return opened, "", true
	case Start_Resume_Latest:
		resume_message, resumed := session_client_resume(setup, &opened, {workspace = launch_workspace, role = .Main, limit = 1}, "", launch_workspace)
		if !resumed { return opened, resume_message, false }
		return opened, "", true
	case Start_Resume_Id:
		resume_id := string(id)
		parsed, valid := journal.session_id_parse(resume_id)
		if !valid || parsed == {} { return opened, fmt.aprintf("%s is not a session id", resume_id, allocator = allocator), false }
		resume_message, resumed := session_client_resume(setup, &opened, {session = parsed, limit = 1}, resume_id, launch_workspace)
		if !resumed { return opened, resume_message, false }
		return opened, "", true
	}
	return opened, fmt.aprintf("the session could not be opened", allocator = allocator), false
}

// session_client_resume fills opened from the one session filter names. The message is
// owned by setup.alloc. A failure leaves opened for the caller's destroy.
@(require_results)
session_client_resume :: proc(
	setup: ^Run_Setup,
	opened: ^Opened_Session,
	filter: journal.Session_Filter,
	resume_id, launch_workspace: string,
) -> (
	message: string,
	ok: bool,
) {
	allocator := setup.alloc
	summaries, list_error := journal.list_sessions(opened.store, filter, allocator)
	if list_error != nil { return session_error_message("cannot list sessions", list_error, allocator), false }
	defer journal.session_summaries_destroy(summaries, allocator)
	if len(summaries) == 0 {
		if resume_id == "" {
			return fmt.aprintf("no session has run in %s; nothing to resume", launch_workspace, allocator = allocator), false
		}
		return fmt.aprintf("session %s does not exist", resume_id, allocator = allocator), false
	}
	summary := &summaries[0]
	if !os.is_dir(summary.workspace) {
		return fmt.aprintf("the session's directory is not usable: %s", summary.workspace, allocator = allocator), false
	}
	if setup.follow_client.session == summary.id || (setup.store != nil && (setup.store.claimed == summary.id || setup.store.followed == summary.id)) {
		return fmt.aprintf("the session is already open here", allocator = allocator), false
	}

	opened.id = summary.id
	workspace, workspace_error := strings.clone(summary.workspace, allocator)
	if workspace_error != nil { return fmt.aprintf("the session's directory could not be stored", allocator = allocator), false }
	opened.workspace = workspace
	branch, head, head_error := journal.session_head(opened.store, opened.id)
	if head_error != nil { return session_error_message("cannot read the session", head_error, allocator), false }
	opened.branch, opened.head = branch, head
	if select_message, selected := session_client_selection(opened, allocator); !selected { return select_message, false }
	delivered, delivered_error := journal.last_delivered_message(opened.store, opened.id)
	if delivered_error != nil { return session_error_message("cannot read the session", delivered_error, allocator), false }
	waiting, waiting_error := journal.read_inbox(opened.store, opened.id, delivered, allocator)
	if waiting_error != nil { return session_error_message("cannot read the session", waiting_error, allocator), false }
	opened.pending = waiting
	return "", true
}

@(require_results)
session_client_selection :: proc(opened: ^Opened_Session, allocator: mem.Allocator) -> (message: string, ok: bool) {
	selection_record, selection_found, read_error := journal.read_latest(opened.store, {session = opened.id, kinds = {.Selection_Applied}}, allocator)
	if read_error != nil { return session_error_message("cannot read the session selection", read_error, allocator), false }
	if !selection_found {
		latest, found, turn_error := journal.read_latest(opened.store, {session = opened.id, kinds = {.Turn_Started}}, allocator)
		if turn_error != nil { return session_error_message("cannot read the session", turn_error, allocator), false }
		defer journal.record_destroy(&latest, allocator)
		if !found { return "", true }
		return session_client_names(opened, latest.provider, latest.model, "", allocator)
	}
	defer journal.record_destroy(&selection_record, allocator)
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	selection: journal.Selection_Applied
	if decode_error := journal.payload_decode(
		selection_record.data,
		&selection,
		context.temp_allocator,
		corruption_journal = opened.store,
		session = selection_record.session,
		seq = selection_record.seq,
	); decode_error != nil {
		return session_error_message("cannot read the session selection", decode_error, allocator), false
	}
	return session_client_names(opened, selection.provider, selection.model, selection.effort, allocator)
}

@(require_results)
session_client_names :: proc(opened: ^Opened_Session, provider, model, effort: string, allocator: mem.Allocator) -> (message: string, ok: bool) {
	owned_provider, provider_error := strings.clone(provider, allocator)
	owned_model, model_error := strings.clone(model, allocator)
	owned_effort, effort_error := strings.clone(effort, allocator)
	if provider_error != nil || model_error != nil || effort_error != nil {
		delete(owned_provider, allocator)
		delete(owned_model, allocator)
		delete(owned_effort, allocator)
		return fmt.aprintf("the session's model could not be stored", allocator = allocator), false
	}
	opened.provider = owned_provider
	opened.model = owned_model
	opened.effort = owned_effort
	return "", true
}

@(require_results)
session_client_prepare :: proc(setup: ^Run_Setup, opened: ^Opened_Session) -> (Client_Follow, agent.Chat_Session, string) {
	follow, follow_error := client_follow_open(opened.store, opened.id)
	if follow_error.kind == .Watch {
		// The lock file is not there yet, so there is nothing to watch. The follow
		// still reads the journal; a later server creates the file.
		cursor, cursor_error := agent.follow_start(opened.store, opened.id)
		if cursor_error != nil {
			opened_session_destroy(opened, setup.alloc)
			return {}, {}, "the session could not be followed"
		}
		follow = {
			store   = opened.store,
			session = opened.id,
			cursor  = cursor,
		}
	} else if follow_error.kind != .None {
		opened_session_destroy(opened, setup.alloc)
		return {}, {}, "the session could not be followed"
	}
	new_session, tool_error := agent.chat_session_init(
		opened.store,
		opened.id,
		opened.branch,
		opened.head,
		opened.workspace,
		setup.alloc,
		setup.harness_options.web_search,
	)
	if tool_error.kind != .None {
		client_follow_close(&follow)
		opened_session_destroy(opened, setup.alloc)
		return {}, {}, "the tool registry could not be allocated"
	}
	return follow, new_session, ""
}

// session_client_install makes opened the running session and follows it. It does not
// claim the session and does not start the server. A problem, static text, leaves the
// running session intact.
@(require_results)
session_client_install :: proc(setup: ^Run_Setup, opened: ^Opened_Session) -> (problem: string) {
	follow, new_session, prepare_problem := session_client_prepare(setup, opened)
	if prepare_problem != "" { return prepare_problem }

	client_follow_close(&setup.follow_client)
	if setup.store != nil {
		agent.chat_session_destroy(&setup.session)
		setup.workers_abandoned = setup.workers_abandoned || setup.session.workers_retained
	}
	if setup.store != opened.store { _ = session_store_close(setup.store) }
	delete(setup.workspace, setup.alloc)
	delete(setup.resumed_provider, setup.alloc)
	delete(setup.resumed_model, setup.alloc)
	delete(setup.resumed_effort, setup.alloc)
	setup.store = opened.store
	setup.run_open = false
	setup.workspace = opened.workspace
	setup.resumed_provider = opened.provider
	setup.resumed_model = opened.model
	setup.resumed_effort = opened.effort
	journal.records_destroy(setup.follow_pending, setup.alloc)
	setup.follow_pending = opened.pending
	setup.follow_client = follow
	setup.follow = follow.cursor
	setup.commands_seen = follow.cursor.last
	setup.follow_input_busy = false
	opened^ = {}
	setup.session = new_session
	agent.chat_session_apply_harness(&setup.session, setup.harness_options)
	return ""
}

// session_client_attach is the launch's open: the session exists before the first
// prompt, and this process does not claim it.
@(require_results)
session_client_attach :: proc(setup: ^Run_Setup, workspace: string, start: Session_Start, stderr: io.Writer) -> bool {
	directory, directory_error := agent.xdg_directory(.State, setup.alloc)
	if directory_error != .None {
		fmt.wprintln(stderr, "nabla: cannot resolve the state directory for sessions")
		return false
	}
	setup.journal_directory = directory
	locks, replaced, locks_error := agent.session_lock_directory(setup.alloc)
	if locks_error != .None {
		fmt.wprintln(stderr, "nabla: cannot resolve the directory for session locks")
		return false
	}
	if replaced {
		fmt.wprintf(stderr, "nabla: warning: XDG_RUNTIME_DIR is not an absolute path; session locks are kept in %s\n", locks)
	}
	setup.lock_directory = locks
	setup.run = journal.run_id_create()

	opened, message, ok := session_client_open(setup, start, workspace)
	if !ok {
		fmt.wprintln(stderr, "nabla:", message)
		delete(message, setup.alloc)
		return false
	}
	if problem := session_client_install(setup, &opened); problem != "" {
		fmt.wprintln(stderr, "nabla:", problem)
		return false
	}
	return true
}

// session_client_switch replaces the running session with a followed one. It does not
// start the server; the worker does that after a switch it accepted.
@(require_results)
session_client_switch :: proc(app: ^App, start: Session_Start) -> bool {
	setup := &app.setup
	opened, message, ok := session_client_open(setup, start, setup.workspace)
	if !ok {
		snap_append(app, .Error, message)
		delete(message, setup.alloc)
		return false
	}
	if problem := session_client_install(setup, &opened); problem != "" {
		snap_append(app, .Error, problem)
		return false
	}
	selection_intent_clear(app)
	if setup.resumed_provider != "" && setup.resumed_model != "" {
		_ = selection_apply_direct(app, setup.resumed_provider, setup.resumed_model, setup.resumed_effort)
	}
	return true
}

// session_client_ensure starts the session server when nothing holds the claim.
session_client_ensure :: proc(app: ^App) {
	setup := &app.setup
	client_server_close(&setup.server)
	server, error := client_ensure_server(setup.harness_options.nabla_executable, setup.session.session, setup.harness_options.nabla_config)
	if error.kind != .None {
		snap_append(app, .Error, "the session server could not be started")
		return
	}
	setup.server = server
}

// app_client_service is one idle step of a client: send a cancel or a compaction the
// front-end asked for, show what the server committed, and deliver steering that a
// request boundary can take. True means the display changed.
@(require_results)
app_client_service :: proc(app: ^App, observer: agent.Chat_Observer) -> bool {
	if app.setup.follow_client.store == nil || runtime_stopping(app) { return false }
	changed := app_follow_flush(app)
	if sync.atomic_exchange(&app.run.cancel_requested, false) {
		_ = app_command_send(app, journal.Cancel_Turn{})
		changed = true
	}
	if sync.atomic_exchange(&app.run.compact_pending, false) {
		_ = app_command_send(app, journal.Compact{})
		changed = true
	}
	if app_client_poll(app, observer) { changed = true }
	if app_client_refusals(app) { changed = true }
	if app_client_steer(app, observer) { changed = true }
	return changed
}

// app_client_prompt appends one prompt for the followed session and shows it once the
// commit lands. A busy database keeps the record pending for the next flush.
app_client_prompt :: proc(app: ^App, text: string, observer: agent.Chat_Observer) {
	_, error := client_send_input(&app.setup.follow_client, text, .Prompt)
	app.setup.follow_input_busy = error != nil && journal.error_is_busy(error)
	if error != nil {
		if app.setup.follow_input_busy {
			snap_append(app, .Warning, "the session database is busy; the line is pending and has not been sent")
		} else {
			snap_append(app, .Error, fmt.tprintf("the line was not sent: %s", journal.error_text(error, context.temp_allocator)))
		}
		return
	}
	_ = app_client_poll(app, observer)
}

@(require_results)
app_client_poll :: proc(app: ^App, observer: agent.Chat_Observer) -> bool {
	follow := &app.setup.follow_client
	before := follow.cursor
	if error := client_follow_poll(follow, observer); error != nil {
		snap_append(app, .Error, fmt.tprintf("cannot read the session: %s", journal.error_text(error, context.temp_allocator)))
	}
	app.setup.follow = follow.cursor
	app.setup.session.last_estimate = follow.cursor.estimate
	if follow.cursor.window > 0 { app.setup.session.capacity.window = follow.cursor.window }
	changed := follow.cursor != before
	if client_selection_adopt(app) { changed = true }
	return changed
}

// client_selection_adopt copies the followed session's latest selection.applied into
// the setup and the session the footer, /status, and the model menu read. The server
// already installed that selection; this process only shows it. False means the
// selection was unchanged or could not be read.
@(require_results)
client_selection_adopt :: proc(app: ^App) -> bool {
	store := app.setup.follow_client.store
	session := app.setup.follow_client.session
	if store == nil || session == {} { return false }
	record, found, read_error := journal.read_latest(store, {session = session, kinds = {.Selection_Applied}}, context.temp_allocator)
	if read_error != nil || !found { return false }
	defer journal.record_destroy(&record, context.temp_allocator)
	applied: journal.Selection_Applied
	if journal.payload_decode(record.data, &applied, context.temp_allocator) != nil { return false }
	chat := &app.setup.session
	if app.setup.provider_id == applied.provider &&
	   app.setup.model_id == applied.model &&
	   chat.provider_id == applied.provider &&
	   chat.model_id == applied.model &&
	   chat.effort == applied.effort {
		return false
	}
	provider, provider_error := strings.clone(applied.provider, app.setup.alloc)
	model, model_error := strings.clone(applied.model, app.setup.alloc)
	chat_provider, chat_provider_error := strings.clone(applied.provider, chat.allocator)
	chat_model, chat_model_error := strings.clone(applied.model, chat.allocator)
	effort, effort_error := strings.clone(applied.effort, chat.allocator)
	if provider_error != nil || model_error != nil || chat_provider_error != nil || chat_model_error != nil || effort_error != nil {
		delete(provider, app.setup.alloc)
		delete(model, app.setup.alloc)
		delete(chat_provider, chat.allocator)
		delete(chat_model, chat.allocator)
		delete(effort, chat.allocator)
		return false
	}
	delete(app.setup.provider_id, app.setup.alloc)
	app.setup.provider_id = provider
	delete(app.setup.model_id, app.setup.alloc)
	app.setup.model_id = model
	delete(chat.provider_id, chat.allocator)
	chat.provider_id = chat_provider
	delete(chat.model_id, chat.allocator)
	chat.model_id = chat_model
	delete(chat.effort, chat.allocator)
	chat.effort = effort
	return true
}

// app_client_refusals shows a command the server refused. The reason is the notice.
@(require_results)
app_client_refusals :: proc(app: ^App) -> bool {
	store := app.setup.follow_client.store
	records, _, error := journal.read_records(
		store,
		{session = app.setup.follow_client.session, kinds = {.Command_Applied}},
		app.setup.commands_seen,
		0,
		context.temp_allocator,
	)
	if error != nil { return false }
	shown := false
	for &record in records {
		if record.seq > app.setup.commands_seen { app.setup.commands_seen = record.seq }
		applied: journal.Command_Applied
		payload, has_payload := record.payload.?
		if !has_payload { continue }
		value, is_applied := payload.(journal.Command_Applied)
		if !is_applied { continue }
		applied = value
		if applied.outcome == journal.COMMAND_OUTCOME_NAMES[.Refused] && applied.reason != "" {
			snap_append(app, .Notice, applied.reason)
			shown = true
		}
	}
	return shown
}

// app_client_steer sends the ready steering lines once a request boundary was seen
// and the turn is still running. A turn that ended in the same poll keeps the lines
// for the front-end, which sends them as the next prompt.
@(require_results)
app_client_steer :: proc(app: ^App, observer: agent.Chat_Observer) -> bool {
	if !app.setup.follow.working || !app.run.steer_boundary { return false }
	app.run.steer_boundary = false
	taken, taken_ok := agent.steer_take_ready(&app.run.steer)
	if !taken_ok {
		snap_append(app, .Warning, "input queued during that turn could not be sent")
		return false
	}
	if len(taken) == 0 {
		agent.steer_taken_destroy(&app.run.steer, taken)
		return false
	}
	sent := 0
	for line in taken {
		_, error := client_send_input(&app.setup.follow_client, line, .Steering)
		if error == nil {
			sent += 1
			continue
		}
		app.setup.follow_input_busy = journal.error_is_busy(error)
		detail := "the session database is busy; the line stays queued" if app.setup.follow_input_busy else journal.error_text(error, context.temp_allocator)
		snap_append(app, .Warning, fmt.tprintf("a steering line was not sent: %s", detail))
		break
	}
	if sent == len(taken) {
		agent.steer_taken_destroy(&app.run.steer, taken)
		_ = app_client_poll(app, observer)
		return true
	}
	rest, rest_error := make([dynamic]string, len(taken) - sent, app.run.steer.allocator)
	if rest_error != nil {
		agent.steer_taken_destroy(&app.run.steer, taken)
		snap_append(app, .Warning, "a steering line could not be kept")
		return true
	}
	copy(rest[:], taken[sent:])
	for line in taken[:sent] { delete(line, app.run.steer.allocator) }
	delete(taken)
	if !agent.steer_requeue(&app.run.steer, rest) { snap_append(app, .Warning, "a steering line could not be kept") }
	return true
}

// app_command_send appends one command for the followed session. The server applies
// it and records command.applied.
@(require_results)
app_command_send :: proc(app: ^App, command: journal.Command) -> bool {
	store := app.setup.follow_client.store
	if store == nil || store.followed == {} {
		snap_append(app, .Notice, "no session is being followed")
		return false
	}
	error := journal.append_command(store, command)
	if error != nil && journal.error_is_busy(error) { _, error = journal.commit(store) }
	app.setup.follow_input_busy = error != nil && journal.error_is_busy(error)
	if error == nil { return true }
	if app.setup.follow_input_busy {
		snap_append(app, .Warning, "the session database is busy; the command is pending and has not been sent")
	} else {
		snap_append(app, .Error, fmt.tprintf("the command was not sent: %s", journal.error_text(error, context.temp_allocator)))
	}
	return false
}
