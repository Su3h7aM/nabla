package main

import "base:runtime"
import "core:os"
import "core:sync"
import "core:thread"

import "nabla:agent"
import "nabla:agent/journal"
import "nabla:subprocess"

Client_Error_Kind :: enum {
	None,
	Locks,
	Path,
	Claim,
	Start,
	Sink,
	Waiter,
	Follow,
	Watch,
}
Client_Error :: struct {
	kind:    Client_Error_Kind,
	system:  os.Error,
	journal: journal.Error,
}
Client_Server_State :: struct {
	child:     subprocess.Child,
	published: bool,
	exited:    bool,
	exit_code: int,
	waited:    bool,
	worker:    ^thread.Thread,
}
Client_Server :: struct {
	state: ^Client_Server_State,
}
Client_Server_Kind :: enum {
	None,
	Running,
	Exited,
	Signalled,
	Unknown,
}
Client_Server_Status :: struct {
	kind:      Client_Server_Kind,
	exit_code: int,
}

client_server_wait :: proc(worker: ^thread.Thread) {
	context = runtime.default_context()
	state := cast(^Client_Server_State)worker.data
	state.exited, state.exit_code, state.waited = subprocess.child_reap(&state.child)
	if state.child.reaped { subprocess.child_close(&state.child) }
	sync.atomic_store(&state.published, true)
	agent.owner_wake_signal()
}

client_server_status :: proc(server: ^Client_Server) -> (status: Client_Server_Status, error: Client_Error) {
	state := server.state
	if state == nil { return {}, {} }
	if !sync.atomic_load(&state.published) { return {.Running, 0}, {} }
	if state.exited { return {.Exited, state.exit_code}, {} }
	if state.waited { return {.Signalled, 0}, {} }
	return {.Unknown, 0}, {}
}

// client_server_close reclaims a finished waiter. A waiter still blocked on its child is
// abandoned, because the server is allowed to outlive the client and threads are not killed.
client_server_close :: proc(server: ^Client_Server) {
	state := server.state
	server.state = nil
	if state == nil || !sync.atomic_load(&state.published) { return }
	thread.destroy(state.worker)
	free(state)
}

client_lock_path :: proc(session: journal.Session_Id) -> (path: string, error: Client_Error) {
	locks, _, locks_error := agent.session_lock_directory(context.allocator)
	if locks_error != .None { return "", {kind = .Locks} }
	defer delete(locks)
	lock_path, path_error := agent.session_lock_path(locks, session, context.allocator)
	if path_error != nil { return "", {kind = .Path} }
	return lock_path, {}
}

client_ensure_server :: proc(
	executable: string,
	session: journal.Session_Id,
	provider, model, config: string,
) -> (
	server: Client_Server,
	error: Client_Error,
) {
	lock_path, path_error := client_lock_path(session)
	if path_error.kind != .None { return {}, path_error }
	defer delete(lock_path)
	held, held_error := client_claim_held(lock_path)
	if held_error != nil { return {}, {kind = .Claim, system = held_error} }
	if held { return {}, {} }
	hex: [journal.SESSION_ID_HEX_LENGTH]u8
	session_text := journal.session_id_to_hex(session, hex[:])
	arguments: [10]string
	count := 0
	arguments[count] = executable
	count += 1
	arguments[count] = "--serve"
	count += 1
	arguments[count] = "--session"
	count += 1
	arguments[count] = session_text
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
		return {}, Client_Error{kind = .Start, system = environment_error}
	}
	defer {
		for entry in environment { delete(entry) }
		delete(environment)
	}

	// The server's own output must not mix with the answer on standard output.
	sink := os.open("/dev/null", {.Write}) or_else nil
	if sink == nil {
		return {}, Client_Error{kind = .Sink}
	}
	defer _ = os.close(sink)

	child, spawn, start_error := subprocess.start({argv = arguments[:count], environment = environment, stderr = os.stderr, stdout = sink, new_session = true})
	if spawn != .Started {
		return {}, Client_Error{kind = .Start, system = start_error}
	}
	state := new(Client_Server_State)
	state.child = child
	previous := agent.chat_signal_block_watched()
	worker := thread.create(client_server_wait, name = "nabla-client-server")
	agent.chat_signal_restore(previous)
	if worker == nil { free(state); return {}, {kind = .Waiter} }
	state.worker = worker
	worker.data = state
	thread.start(worker)
	return {state}, {}
}

Client_Follow :: struct {
	store:   ^journal.Journal,
	session: journal.Session_Id,
	cursor:  agent.Follow,
	watch:   ^agent.Session_Watch,
}

client_follow_open :: proc(store: ^journal.Journal, session: journal.Session_Id) -> (follow: Client_Follow, error: Client_Error) {
	lock_path, path_error := client_lock_path(session)
	if path_error.kind != .None { return {}, path_error }
	defer delete(lock_path)
	if follow_error := journal.follow(store, session); follow_error != nil { return {}, {kind = .Follow, journal = follow_error} }
	watch := new(agent.Session_Watch)
	if _, watch_error := agent.session_watch_add(watch, lock_path); watch_error != nil {
		agent.session_watch_stop(watch)
		free(watch)
		return {}, {kind = .Watch, system = watch_error}
	}
	cursor, follow_error := agent.follow_start(store, session)
	if follow_error != nil {
		agent.session_watch_stop(watch)
		free(watch)
		return {}, {kind = .Follow, journal = follow_error}
	}
	return {store, session, cursor, watch}, {}
}

client_follow_poll :: proc(follow: ^Client_Follow, observer: agent.Chat_Observer) -> journal.Error {
	return agent.follow_poll(follow.store, follow.session, &follow.cursor, observer)
}
client_follow_close :: proc(follow: ^Client_Follow) {
	if follow.watch != nil { agent.session_watch_stop(follow.watch); free(follow.watch) }
	follow^ = {}
}
client_send_input :: proc(follow: ^Client_Follow, text: string, origin: journal.User_Origin) -> (seq: journal.Journal_Seq, error: journal.Error) {
	error = journal.append_input(follow.store, text, origin)
	seq = follow.store.last_seq
	if error != nil && journal.error_is_busy(error) { seq, error = journal.commit(follow.store) }
	return
}
