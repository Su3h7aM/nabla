package main

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:os"
import "core:sync"
import "core:thread"

import "nabla:agent"
import "nabla:agent/journal"
import "nabla:subprocess"

// Prompt_Server is the session server this process started, if it started one.
// It is process-global because the waiter blocks in the child's wait until that
// server exits, which is after this client has returned, and the process exit
// reclaims it. The waiter writes the exit fields, then publishes; the client
// reads them only after published is set.
Prompt_Server :: struct {
	child:     subprocess.Child,
	published: bool,
	exited:    bool,
	exit_code: int,
	waited:    bool,
}

prompt_server: Prompt_Server

// prompt_server_wait blocks until the session server exits, records how it ended,
// and wakes the client. The wake is the only thing the client's wait loop sleeps on.
prompt_server_wait :: proc(worker: ^thread.Thread) {
	context = runtime.default_context()
	server := cast(^Prompt_Server)worker.data
	exited, exit_code, waited := subprocess.child_reap(&server.child)
	server.exited = exited
	server.exit_code = exit_code
	server.waited = waited
	sync.atomic_store(&server.published, true)
	agent.owner_wake_signal()
}

// prompt_server_failed reports a session server that exited non-zero before the
// prompt was answered. An exit status of 0 lost the claim to another server and
// is not a failure. Nothing here is written to the journal.
@(require_results)
prompt_server_failed :: proc() -> bool {
	if !sync.atomic_load(&prompt_server.published) { return false }
	if prompt_server.exited && prompt_server.exit_code == 0 { return false }
	if prompt_server.exited {
		fmt.eprintf("nabla: the session server exited with status %d\n", prompt_server.exit_code)
	} else if prompt_server.waited {
		fmt.eprintln("nabla: the session server was killed by a signal")
	} else {
		fmt.eprintln("nabla: the session server's exit status is unknown")
	}
	return true
}

// prompt_start_server runs the session server as a child when no claim holder
// exists. The child is its own session, with no controlling terminal, and keeps
// running after this client exits. Its standard error is this process's.
// False means the server did not start; the reason was printed and nothing was
// written to the journal.
@(require_results)
prompt_start_server :: proc(executable, session, provider, model, config: string) -> bool {
	arguments: [10]string
	count := 0
	arguments[count] = executable
	count += 1
	arguments[count] = "--serve"
	count += 1
	arguments[count] = "--session"
	count += 1
	arguments[count] = session
	count += 1
	if provider != "" {
		arguments[count] = "--provider"
		count += 1
		arguments[count] = provider
		count += 1
		arguments[count] = "--model"
		count += 1
		arguments[count] = model
		count += 1
	}
	if config != "" {
		arguments[count] = "--config"
		count += 1
		arguments[count] = config
		count += 1
	}

	environment, environment_error := os.environ(context.allocator)
	if environment_error != nil {
		fmt.eprintf("nabla: the session server could not be started: %v\n", environment_error)
		return false
	}
	defer {
		for entry in environment { delete(entry) }
		delete(environment)
	}

	// The server's own output must not mix with the answer on standard output.
	sink := os.open("/dev/null", {.Write}) or_else nil
	if sink == nil {
		fmt.eprintln("nabla: the session server could not be started: /dev/null could not be opened")
		return false
	}
	defer _ = os.close(sink)

	child, spawn, start_error := subprocess.start({argv = arguments[:count], environment = environment, stderr = os.stderr, stdout = sink, new_session = true})
	if spawn != .Started {
		fmt.eprintf("nabla: the session server could not be started: %v\n", start_error)
		return false
	}

	prompt_server = {}
	prompt_server.child = child
	previous := agent.chat_signal_block_watched()
	worker := thread.create(prompt_server_wait, name = "nabla-prompt-server")
	agent.chat_signal_restore(previous)
	if worker == nil {
		fmt.eprintln("nabla: the session server could not be watched")
		return false
	}
	worker.data = &prompt_server
	thread.start(worker)
	return true
}

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
prompt_wait_turn :: proc(store: ^journal.Journal, session: journal.Session_Id, prompt: string, answer: io.Writer) -> bool {
	cursor, follow_error := agent.follow_start(store, session)
	if follow_error != nil {
		fmt.eprintf("nabla: cannot read the session: %s\n", journal.error_text(follow_error, context.temp_allocator))
		return false
	}

	error := journal.append_input(store, prompt, .Prompt)
	seq := store.last_seq
	if error != nil && journal.error_is_busy(error) { seq, error = journal.commit(store) }
	if error != nil {
		fmt.eprintf("nabla: the line was not sent: %s\n", journal.error_text(error, context.temp_allocator))
		return false
	}
	cursor.input = seq

	out := Headless_Output {
		answer = answer,
		follow = &cursor,
	}
	observer := headless_observer(&out)
	previous: agent.Signal_Action
	agent.chat_signal_arm(&previous)
	defer agent.chat_signal_disarm(&previous)
	for {
		seen := agent.owner_wake_seen()
		if poll_error := agent.follow_poll(store, session, &cursor, observer); poll_error != nil {
			fmt.eprintf("nabla: cannot read the session: %s\n", journal.error_text(poll_error, context.temp_allocator))
			return false
		}
		if cursor.ended { break }
		if agent.process_interrupted() {
			fmt.eprintln("nabla: interrupted while waiting for the session's turn")
			return false
		}
		if prompt_server_failed() { return false }
		agent.owner_wake_wait(seen, nil)
	}
	if out.write_failed {
		fmt.eprintln("nabla: the answer could not be written")
		return false
	}
	return cursor.outcome == .Completed
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

	lock_path, path_error := agent.session_lock_path(locks, session, context.allocator)
	if path_error != nil {
		fmt.eprintln("nabla: the session lock path could not be stored")
		return 1
	}
	defer delete(lock_path)
	held, held_error := prompt_claim_held(lock_path)
	if held_error != nil {
		fmt.eprintf("nabla: cannot tell whether the session is running: %v\n", held_error)
		return 1
	}
	if held {
		if options.provider_id != "" {
			fmt.eprintln("nabla: the running session keeps its selection")
		}
	} else {
		hex: [journal.SESSION_ID_HEX_LENGTH]u8
		session_text := journal.session_id_to_hex(session, hex[:])
		if !prompt_start_server(executable, session_text, options.provider_id, options.model_id, config) {
			return 1
		}
	}

	// The watch is armed before the first read, so a commit after that read wakes the wait.
	watch: agent.Session_Watch
	defer agent.session_watch_stop(&watch)
	if follow_error := journal.follow(store, session); follow_error != nil {
		fmt.eprintf("nabla: cannot follow the session: %s\n", journal.error_text(follow_error, context.temp_allocator))
		return 1
	}
	if _, watch_error := agent.session_watch_add(&watch, lock_path); watch_error != nil {
		fmt.eprintf("nabla: cannot watch the session: %v\n", watch_error)
		return 1
	}
	return prompt_wait_turn(store, session, options.prompt, answer) ? 0 : 1
}
