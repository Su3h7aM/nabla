package main

import "core:fmt"
import "core:io"
import "core:os"

import "nabla:agent"
import "nabla:agent/journal"

// prompt_commit writes the pending batch, and retries once when another writer
// still holds the database. The seq is the last record written.
@(require_results)
prompt_commit :: proc(store: ^journal.Journal) -> (seq: journal.Journal_Seq, error: journal.Error) {
	seq, error = journal.commit(store)
	if error != nil && journal.error_is_busy(error) {
		seq, error = journal.commit(store)
	}
	return seq, error
}

// prompt_resolve_session creates a main session in the working directory, or
// opens the resumed one. A created session is committed and its claim released,
// so the server can take it. The id is the session the caller then follows.
@(require_results)
prompt_resolve_session :: proc(store: ^journal.Journal, options: chat_cli_options) -> (id: journal.Session_Id, ok: bool) {
	workspace, workspace_error := os.get_working_directory(context.allocator)
	if workspace_error != nil || workspace == "" {
		fmt.eprintln("nabla: cannot determine working directory")
		return {}, false
	}
	defer delete(workspace)

	if !options.resume {
		created, create_error := journal.create_session(store, {workspace = workspace, role = .Main})
		if create_error != nil {
			fmt.eprintf("nabla: the session could not be created: %s\n", journal.error_text(create_error, context.temp_allocator))
			return {}, false
		}
		if _, commit_error := prompt_commit(store); commit_error != nil {
			fmt.eprintf("nabla: the session could not be committed: %s\n", journal.error_text(commit_error, context.temp_allocator))
			_ = journal.release(store)
			return {}, false
		}
		if release_error := journal.release(store); release_error != nil {
			fmt.eprintf("nabla: the session could not be released: %s\n", journal.error_text(release_error, context.temp_allocator))
			return {}, false
		}
		return created, true
	}

	filter := journal.Session_Filter {
		limit = 1,
	}
	resume_id := options.resume_id
	if resume_id == "" {
		filter.workspace = workspace
		filter.role = .Main
	} else {
		parsed, valid := journal.session_id_parse(resume_id)
		if !valid || parsed == {} {
			fmt.eprintf("nabla: %s is not a session id\n", resume_id)
			return {}, false
		}
		filter.session = parsed
	}
	summaries, list_error := journal.list_sessions(store, filter, context.allocator)
	if list_error != nil {
		fmt.eprintf("nabla: cannot list sessions: %s\n", journal.error_text(list_error, context.temp_allocator))
		return {}, false
	}
	defer journal.session_summaries_destroy(summaries)
	if len(summaries) == 0 {
		if resume_id == "" {
			fmt.eprintf("nabla: no session has run in %s; nothing to resume\n", workspace)
		} else {
			fmt.eprintf("nabla: session %s does not exist\n", resume_id)
		}
		return {}, false
	}
	if !os.is_dir(summaries[0].workspace) {
		fmt.eprintf("nabla: the session's directory is not usable: %s\n", summaries[0].workspace)
		return {}, false
	}
	return summaries[0].id, true
}

// prompt_wait_turn follows session and waits until the turn that delivers prompt
// ends, printing as a follower does. It does not take the claim.
@(require_results)
prompt_wait_turn :: proc(follow: ^Client_Follow, server: ^Client_Server, prompt: string, answer: io.Writer) -> bool {
	seq, error := client_send_input(follow, prompt, .Prompt)
	if error != nil {
		fmt.eprintf("nabla: the line was not sent: %s\n", journal.error_text(error, context.temp_allocator))
		return false
	}
	follow.cursor.input = seq
	out := Headless_Output {
		answer = answer,
		follow = &follow.cursor,
	}
	observer := headless_observer(&out)
	previous: agent.Signal_Action
	agent.chat_signal_arm(&previous)
	defer agent.chat_signal_disarm(&previous)
	for {
		seen := agent.owner_wake_seen()
		if poll_error := client_follow_poll(follow, observer); poll_error != nil {
			fmt.eprintf("nabla: cannot read the session: %s\n", journal.error_text(poll_error, context.temp_allocator))
			return false
		}
		if follow.cursor.ended { break }
		if agent.process_interrupted() {
			fmt.eprintln("nabla: interrupted while waiting for the session's turn")
			return false
		}
		status, _ := client_server_status(server)
		switch status.kind {
		case .None, .Running:
		case .Exited:
			if status.exit_code != 0 {
				fmt.eprintf("nabla: the session server exited with status %d\n", status.exit_code)
				return false
			}
		case .Signalled:
			fmt.eprintln("nabla: the session server was killed by a signal")
			return false
		case .Unknown:
			fmt.eprintln("nabla: the session server's exit status is unknown")
			return false
		}
		agent.owner_wake_wait(seen, nil)
	}
	if out.write_failed {
		fmt.eprintln("nabla: the answer could not be written")
		return false
	}
	return follow.cursor.outcome == .Completed
}

// run_prompt sends one prompt to the session server and returns the process exit
// code. It never runs the turn. When the session has no claim holder it starts
// the server; otherwise it follows the one already running.
@(require_results)
run_prompt :: proc(executable: string, options: chat_cli_options, config: string, answer: io.Writer) -> int {
	state, state_error := agent.xdg_directory(.State, context.allocator)
	if state_error != .None {
		fmt.eprintln("nabla: cannot resolve the state directory for sessions")
		return 1
	}
	defer delete(state)
	locks, replaced, locks_error := agent.session_lock_directory(context.allocator)
	if locks_error != .None {
		fmt.eprintln("nabla: cannot resolve the directory for session locks")
		return 1
	}
	defer delete(locks)
	if replaced {
		fmt.eprintf("nabla: warning: XDG_RUNTIME_DIR is not an absolute path; session locks are kept in %s\n", locks)
	}

	store, open_error := journal.open(state, locks, journal.run_id_create(), .Read_Write)
	if open_error != nil {
		fmt.eprintf("nabla: cannot open the session database: %s\n", journal.error_text(open_error, context.temp_allocator))
		return 1
	}
	defer _ = journal.close(store) // The client is leaving; a close failure changes nothing it can still do.

	session, resolved := prompt_resolve_session(store, options)
	if !resolved { return 1 }

	server, server_error := client_ensure_server(executable, session, config, os.stderr)
	if server_error.kind != .None {
		switch server_error.kind {
		case .None:
		case .Locks:
			fmt.eprintln("nabla: cannot resolve the directory for session locks")
		case .Path:
			fmt.eprintln("nabla: the session lock path could not be stored")
		case .Claim:
			fmt.eprintf("nabla: cannot tell whether the session is running: %v\n", server_error.system)
		case .Start:
			fmt.eprintf("nabla: the session server could not be started: %v\n", server_error.system)
		case .Sink:
			fmt.eprintln("nabla: the session server could not be started: /dev/null could not be opened")
		case .Waiter:
			fmt.eprintln("nabla: the session server could not be watched")
		case .Follow, .Watch:
			fmt.eprintln("nabla: cannot follow the session")
		}
		return 1
	}
	defer client_server_close(&server)
	follow, follow_error := client_follow_open(store, session)
	if follow_error.kind != .None {
		#partial switch follow_error.kind {
		case .Watch:
			fmt.eprintf("nabla: cannot watch the session: %v\n", follow_error.system)
		case .Follow:
			fmt.eprintf("nabla: cannot read the session: %s\n", journal.error_text(follow_error.journal, context.temp_allocator))
		case:
			fmt.eprintln("nabla: cannot follow the session")
		}
		return 1
	}
	defer client_follow_close(&follow)
	if options.provider_id != "" {
		if err := journal.append_command(store, journal.Select_Model{provider = options.provider_id, model = options.model_id}); err != nil {
			fmt.eprintf("nabla: the model selection was not sent: %s\n", journal.error_text(err, context.temp_allocator))
			return 1
		}
	}
	return prompt_wait_turn(&follow, &server, options.prompt, answer) ? 0 : 1
}
