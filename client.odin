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
	store:     ^journal.Journal,
	session:   journal.Session_Id,
	cursor:    agent.Follow,
	watch:     ^agent.Session_Watch,
	// offset is the next unread byte of the session's stream file.
	offset:    i64,
	// delivered is how far each assistant message has been shown from the stream.
	// open means begin was reported and end has not been.
	delivered: map[Client_Stream_Key]Client_Stream_Message,
}

Client_Stream_Key :: struct {
	turn:    journal.Turn_Id,
	ordinal: u32,
}

Client_Stream_Message :: struct {
	delivered: int,
	open:      bool,
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
	streams, streams_error := agent.stream_directory(context.allocator)
	if streams_error != .None {
		agent.session_watch_stop(watch)
		free(watch)
		return {}, {kind = .Path}
	}
	defer delete(streams)
	if agent.xdg_directory_create(streams) != .None {
		agent.session_watch_stop(watch)
		free(watch)
		return {}, {kind = .Path}
	}
	hex: [journal.SESSION_ID_HEX_LENGTH]u8
	if _, directory_error := agent.session_watch_add_directory(watch, streams, journal.session_id_to_hex(session, hex[:])); directory_error != nil {
		agent.session_watch_stop(watch)
		free(watch)
		return {}, {kind = .Watch, system = directory_error}
	}
	cursor, follow_error := agent.follow_start(store, session)
	if follow_error != nil {
		agent.session_watch_stop(watch)
		free(watch)
		return {}, {kind = .Follow, journal = follow_error}
	}
	delivered := make(map[Client_Stream_Key]Client_Stream_Message, context.allocator)
	return {store = store, session = session, cursor = cursor, watch = watch, delivered = delivered}, {}
}

// client_follow_poll shows what the followed session has produced since the last poll.
// Stream frames are applied first, through the same observer callbacks a runner's front-end
// gets for live text: assistant begin, text, flush, and end, and tool_output. A missing or
// removed stream file is no stream. A file shorter than the offset already read is a new
// file, and reading starts over at its beginning. Journal records follow the frames. An
// assistant message is matched by its place in the turn and by prefix: text the stream
// already showed is not shown again, and only the suffix of the committed text is
// delivered, or the whole text when nothing was streamed. The stream text of a message is
// never shown twice. A begin for a message that already has a counter closes that attempt
// and starts another, as a dropped attempt does, and resets the counter. tool_output is
// progress only; the tool_result committed for the call stays the complete result and
// replaces that progress.
client_follow_poll :: proc(follow: ^Client_Follow, observer: agent.Chat_Observer) -> journal.Error {
	client_follow_drain(follow, observer)
	show := Client_Follow_Show {
		follow   = follow,
		observer = observer,
	}
	follow.cursor.assistant_message = client_follow_assistant
	follow.cursor.assistant_message_data = &show
	defer {
		follow.cursor.assistant_message = nil
		follow.cursor.assistant_message_data = nil
	}
	return agent.follow_poll(follow.store, follow.session, &follow.cursor, observer)
}
client_follow_close :: proc(follow: ^Client_Follow) {
	if follow.watch != nil {
		agent.session_watch_stop(follow.watch)
		free(follow.watch)
	}
	delete(follow.delivered)
	follow^ = {}
}
client_send_input :: proc(follow: ^Client_Follow, text: string, origin: journal.User_Origin) -> (seq: journal.Journal_Seq, error: journal.Error) {
	error = journal.append_input(follow.store, text, origin)
	seq = follow.store.last_seq
	if error != nil && journal.error_is_busy(error) { seq, error = journal.commit(follow.store) }
	return
}

Client_Follow_Show :: struct {
	follow:   ^Client_Follow,
	observer: agent.Chat_Observer,
}

@(private)
client_follow_assistant :: proc(user_data: rawptr, turn: journal.Turn_Id, ordinal: u32, text: string) -> bool {
	show := cast(^Client_Follow_Show)user_data
	key := Client_Stream_Key{turn, ordinal}
	message, had := show.follow.delivered[key]
	if !had {
		if text != "" {
			client_show_begin(show.observer)
			client_show_text(show.observer, text)
			client_show_end(show.observer)
		}
		return true
	}
	shown := message.delivered
	if shown > len(text) { shown = len(text) }
	suffix := text[shown:]
	if suffix != "" {
		if !message.open { client_show_begin(show.observer) }
		client_show_text(show.observer, suffix)
		message.open = true
	}
	if message.open { client_show_end(show.observer) }
	delete_key(&show.follow.delivered, key)
	return true
}

@(private)
client_follow_drain :: proc(follow: ^Client_Follow, observer: agent.Chat_Observer) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	directory, directory_error := agent.stream_directory(context.temp_allocator)
	if directory_error != .None { return }
	path, path_error := agent.stream_path(directory, follow.session, context.temp_allocator)
	if path_error != nil { return }
	reader, exists, open_error := agent.stream_reader_open(path)
	if open_error != nil || !exists { return }
	defer agent.stream_reader_close(&reader)
	length, length_error := agent.stream_reader_length(&reader)
	if length_error != nil { return }
	if length < follow.offset { follow.offset = 0 }
	for {
		kind, payload, next, found, read_error := agent.stream_reader_read(&reader, follow.offset)
		if read_error != nil || !found {
			delete(payload)
			return
		}
		client_follow_frame(follow, observer, kind, payload)
		delete(payload)
		follow.offset = next
	}
}

@(private)
client_follow_frame :: proc(follow: ^Client_Follow, observer: agent.Chat_Observer, kind: agent.Stream_Kind, payload: []u8) {
	switch kind {
	case .Assistant_Begin, .Assistant_Text, .Assistant_Flush, .Assistant_End:
		turn_id, ordinal, text, ok := agent.stream_decode_assistant(payload)
		if !ok || turn_id > u64(max(u32)) { return }
		client_follow_assistant_frame(follow, observer, kind, journal.Turn_Id(u32(turn_id)), ordinal, transmute(string)text)
	case .Tool_Output:
		call, parent, chunk, ok := agent.stream_decode_tool_output(payload)
		if !ok || observer.tool_output == nil { return }
		observer.tool_output(observer.user_data, journal.Call_Id(call), journal.Call_Id(parent), transmute(string)chunk)
	}
}

@(private)
client_follow_assistant_frame :: proc(
	follow: ^Client_Follow,
	observer: agent.Chat_Observer,
	kind: agent.Stream_Kind,
	turn: journal.Turn_Id,
	ordinal: u32,
	text: string,
) {
	key := Client_Stream_Key{turn, ordinal}
	message := follow.delivered[key]
	switch kind {
	case .Assistant_Begin:
		if message.open { client_show_end(observer) }
		message.delivered = 0
		message.open = true
		client_show_begin(observer)
	case .Assistant_Text:
		if !message.open {
			client_show_begin(observer)
			message.open = true
		}
		client_show_text(observer, text)
		message.delivered += len(text)
	case .Assistant_Flush:
		if observer.assistant_flush != nil { observer.assistant_flush(observer.user_data) }
		return
	case .Assistant_End:
		if !message.open { return }
		client_show_end(observer)
		message.open = false
	case .Tool_Output:
		return
	}
	follow.delivered[key] = message
}

@(private)
client_show_begin :: proc(observer: agent.Chat_Observer) {
	if observer.assistant_begin != nil { observer.assistant_begin(observer.user_data) }
}

@(private)
client_show_text :: proc(observer: agent.Chat_Observer, text: string) {
	if text != "" && observer.assistant_text != nil { observer.assistant_text(observer.user_data, text) }
}

@(private)
client_show_end :: proc(observer: agent.Chat_Observer) {
	if observer.assistant_end != nil { observer.assistant_end(observer.user_data) }
}
