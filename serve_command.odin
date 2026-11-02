#+build linux
package main

import "core:fmt"
import "core:strings"
import "core:sync"

import "nabla:agent"
import "nabla:agent/journal"
import "nabla:ai"

// The commands clients append. A client that follows a session appends one
// `user.command` record and reads `command.applied` to learn what became of it; the
// server applies the pending ones at its own boundaries. Nothing else crosses
// between the two processes.

// Serve_Command_Result is what an application of one command produced.
Serve_Command_Result :: enum {
	Applied,
	Refused,
}

// Serve_Command_Phase is where the owner is when it looks at the pending commands. A
// boundary is the idle point between turns or a request boundary, where anything may
// apply. A step is any point inside a turn, where only a command that changes nothing
// already in flight applies; the rest waits for the next boundary.
Serve_Command_Phase :: enum {
	Boundary,
	Step,
}

// serve_commands_apply applies the pending commands of the session that may apply now,
// in seq order, and appends the `command.applied` that ends each. It runs on the thread
// that owns the session.
serve_commands_apply :: proc(app: ^App, phase: Serve_Command_Phase) {
	chat := &app.setup.session
	if chat.store == nil || chat.storage_failed { return }
	records, read_error := journal.read_pending_commands(chat.store, chat.session, context.temp_allocator)
	if read_error != nil {
		fmt.eprintln("nabla: cannot read the session's commands:", journal.error_text(read_error, context.temp_allocator))
		return
	}
	for record in records {
		payload: journal.User_Command
		command: journal.Command
		known := false
		if journal.payload_decode(record.data, &payload, context.temp_allocator) == nil {
			command, known = journal.command_decode(payload)
		}
		if !known {
			journal.append_command_applied(chat.store, chat.session, record.seq, .Refused, "the command did not name a command this harness runs")
			continue
		}
		// A command that changes the selection applies only where the interactive
		// harness applies it: between turns, or at the boundary of the next request.
		if phase == .Step && serve_command_changes_selection(command) { continue }
		result, reason := serve_command_apply(app, command)
		outcome := journal.Command_Outcome.Applied if result == .Applied else journal.Command_Outcome.Refused
		journal.append_command_applied(chat.store, chat.session, record.seq, outcome, reason)
	}
}

// serve_command_changes_selection reports whether applying command edits the session's
// selection, which a step inside a turn must not do under its own request in flight.
@(require_results)
serve_command_changes_selection :: proc(command: journal.Command) -> bool {
	switch _ in command {
	case journal.Select_Model, journal.Set_Effort:
		return true
	case journal.Cancel_Turn, journal.Compact:
		return false
	}
	return false
}

// serve_command_apply runs one command the way the interactive front-end runs the same
// action. A reason is what a refusal says happened, in temp memory.
serve_command_apply :: proc(app: ^App, command: journal.Command) -> (result: Serve_Command_Result, reason: string) {
	chat := &app.setup.session
	switch value in command {
	case journal.Cancel_Turn:
		// A turn the server runs is stopped through the same control the interactive
		// harness uses; with nothing running there is nothing to stop.
		if chat.state == .Idle { return .Refused, "no turn was running" }
		agent.turn_control_stop(&app.run.control)
		return .Applied, ""
	case journal.Select_Model:
		chat.catalog = app_catalog_ref(app)
		if warning := app_tools_refresh(app); warning != "" { agent.chat_runtime_message(chat, .Warning, warning) }
		if !serve_selection_request(app, value.provider, value.model) {
			return .Refused, "the model selection could not be stored"
		}
		if app_selection_service(app) { return .Applied, "" }
		// A target that must compact before it fits is applied by the service at the
		// next boundary; the request was taken, so the command is answered as applied.
		if app.run.pending_target != nil { return .Applied, "" }
		problem := setup_error_text(app)
		if problem == "" { problem = "the requested model was refused" }
		return .Refused, problem
	case journal.Set_Effort:
		level := value.level
		if level == "default" { level = "" }
		if !agent.chat_session_set_effort(chat, level) {
			return .Refused, fmt.tprintf("effort %s is not allowed for this model", value.level)
		}
		record_error := agent.chat_selection_record(chat, app.setup.api, app.setup.provider_id, app.setup.model_id, chat.effort)
		if record_error != nil {
			chat.storage_failed = true
			return .Refused, "the effort was applied but the session selection could not be recorded"
		}
		return .Applied, ""
	case journal.Compact:
		if !agent.chat_command_compact(chat, run_observer(app), app.run.connection) {
			if chat.storage_failed { return .Refused, agent.chat_session_last_error(chat) }
			return .Refused, "compaction is not available"
		}
		return .Applied, ""
	}
	return .Refused, "the command did not name a command this harness runs"
}

// serve_selection_request makes provider and model the selection the session installs,
// the way a front-end asks for one: the choice waits in run state for the service that
// resolves and fits it.
serve_selection_request :: proc(app: ^App, provider, model: string) -> bool {
	provider_id, provider_error := strings.clone(provider, app.run.alloc)
	model_id, model_error := strings.clone(model, app.run.alloc)
	if provider_error != nil || model_error != nil {
		delete(provider_id, app.run.alloc)
		delete(model_id, app.run.alloc)
		return false
	}
	previous: Maybe(Pending_Selection)
	if sync.mutex_guard(&app.run.mu) {
		previous = app.run.pending
		app.run.pending = Pending_Selection {
			provider = provider_id,
			model    = model_id,
		}
	}
	pending_selection_clear(&previous, app.run.alloc)
	return true
}

// serve_commands_pending reports whether the session holds a command that no
// `command.applied` answers yet. The server must not idle past such a command, and the
// watch wakes it because the record is another process's commit. A read failure counts as
// none; the step that applies commands reports it.
@(require_results)
serve_commands_pending :: proc(app: ^App) -> bool {
	chat := &app.setup.session
	if chat.store == nil || chat.storage_failed { return false }
	records, read_error := journal.read_pending_commands(chat.store, chat.session, context.temp_allocator)
	return read_error == nil && len(records) > 0
}

// serve_steer_context is the running turn's input from the journal: both hooks apply the
// pending commands, so a cancel reaches the turn and a selection reaches its next
// request, exactly where the interactive harness applies them.
serve_steer_context :: proc(app: ^App) -> agent.Steer_Context {
	return {observe = serve_command_observe, apply = serve_command_apply_boundary, apply_data = app}
}

serve_command_observe :: proc(steer: ^agent.Steer_Context, observer: agent.Chat_Observer) {
	serve_commands_apply(cast(^App)steer.apply_data, .Step)
}

serve_command_apply_boundary :: proc(steer: ^agent.Steer_Context) -> ai.Provider_Connection {
	app := cast(^App)steer.apply_data
	serve_commands_apply(app, .Boundary)
	sync.mutex_guard(&app.run.mu)
	return app.run.connection
}
