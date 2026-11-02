package main

import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"

import "nabla:agent"
import "nabla:agent/journal"

// Serve_Stream is the server's live stream of one session's turn. Assistant
// frames are appended on the owner thread as the turn reports them; tool output
// chunks are queued from any worker thread and drained into the file on the
// owner thread. The server initializes one stream and owns it for its whole
// life; a turn only opens and closes its file. Call init once before use and
// destroy once on exit.
Serve_Stream :: struct {
	allocator:  mem.Allocator, // owns path and every queued chunk text
	session:    journal.Session_Id,
	path:       string, // the turn's file; "" while disabled
	mutex:      sync.Mutex, // guards generation, open, and pending only
	generation: u64, // bumped at every turn start; an older token is stale
	open:       bool, // set while a turn may queue; late chunks are dropped
	file:       ^os.File, // the turn's truncated file, owner thread only
	store:      ^journal.Journal, // borrowed for the open turn, owner thread only
	turn:       journal.Turn_Id, // the durable turn of the open turn
	ordinal:    u32, // the ordinal of the open message
	pending:    [dynamic]Serve_Stream_Chunk, // queued tool output, oldest first
}

// Serve_Stream_Chunk is one queued tool output chunk. text is owned by the
// stream's allocator.
Serve_Stream_Chunk :: struct {
	call:        u64,
	parent_call: u64,
	text:        string,
}

// Serve_Stream_Token is one turn's immutable handle on its stream. It is never
// freed before process exit: an abandoned worker may still call back.
Serve_Stream_Token :: struct {
	generation: u64,
	stream:     ^Serve_Stream,
}

// serve_stream_init points stream at the stream file for session in directory,
// creating the directory when it is missing. A directory or path that cannot be
// resolved leaves the stream disabled: every later call is a no-op and the
// server still serves.
serve_stream_init :: proc(stream: ^Serve_Stream, directory: string, session: journal.Session_Id, allocator := context.allocator) {
	stream.allocator = allocator
	stream.session = session
	stream.pending.allocator = allocator
	if directory == "" { return }
	if agent.xdg_directory_create(directory) != .None { return }
	if path, path_error := agent.stream_path(directory, session, allocator); path_error == nil {
		stream.path = path
	}
}

// serve_stream_destroy removes the stream file and releases what init owns. The
// server calls it once on exit, after its last turn ended.
serve_stream_destroy :: proc(stream: ^Serve_Stream) {
	if stream.file != nil {
		_ = os.close(stream.file)
		stream.file = nil
	}
	serve_stream_drop(stream)
	delete(stream.path, stream.allocator)
	for chunk in stream.pending { delete(chunk.text, stream.allocator) }
	delete(stream.pending)
}

// serve_stream_drop removes the stream file, so a stale file after a crash is
// gone once the server claims the session. A missing file is already removed.
serve_stream_drop :: proc(stream: ^Serve_Stream) {
	if stream.path == "" { return }
	_ = agent.stream_remove(stream.path)
}

// serve_stream_begin truncates the stream file for the turn about to run and
// returns the observer the turn reports through. streaming is false when the
// stream is disabled or the turn's token could not be allocated; the turn then
// runs with no observer. Only the owner thread calls it.
serve_stream_begin :: proc(stream: ^Serve_Stream, store: ^journal.Journal, session: journal.Session_Id, turn: journal.Turn_Id) -> (agent.Chat_Observer, bool) {
	if sync.mutex_guard(&stream.mutex) {
		stream.generation += 1
		for chunk in stream.pending { delete(chunk.text, stream.allocator) }
		clear(&stream.pending)
		stream.open = false
		stream.store = store
		stream.session = session
		stream.turn = turn
		stream.ordinal = 0
	}
	if stream.path == "" { return {}, false }
	file, open_error := agent.stream_open_writer(stream.path)
	if open_error != nil { return {}, false }
	stream.file = file
	// The token is allocated only once the file is open, so a disabled or
	// unopened turn allocates nothing it can never free.
	token, token_error := new(Serve_Stream_Token, stream.allocator)
	if token_error != nil { return {}, false }
	token^ = {stream.generation, stream}
	if sync.mutex_guard(&stream.mutex) { stream.open = true }
	return agent.Chat_Observer {
			user_data = token,
			assistant_begin = serve_stream_assistant_begin,
			assistant_text = serve_stream_assistant_text,
			assistant_flush = serve_stream_assistant_flush,
			assistant_end = serve_stream_assistant_end,
			tool_output = serve_stream_tool_output,
		},
		true
}

// serve_stream_end drains the turn's queued tool output, closes its file, and
// removes it: followers read the committed turn from the journal from here on.
// Only the owner thread calls it.
serve_stream_end :: proc(stream: ^Serve_Stream) {
	if sync.mutex_guard(&stream.mutex) { stream.open = false }
	serve_stream_drain(stream)
	if stream.file != nil {
		_ = os.close(stream.file)
		stream.file = nil
	}
	serve_stream_drop(stream)
}

// serve_stream_observe drains queued tool output on the turn driver's pump,
// including while provider and tool jobs run. It never waits for those jobs.
serve_stream_observe :: proc(_: ^agent.Steer_Context, observer: agent.Chat_Observer) {
	serve_stream_drain((^Serve_Stream_Token)(observer.user_data).stream)
}

// serve_stream_drain appends every queued tool output chunk to the file, oldest
// first. Only the owner thread calls it; queued texts are released either way,
// so a disabled turn leaks nothing.
serve_stream_drain :: proc(stream: ^Serve_Stream) {
	chunks: [dynamic]Serve_Stream_Chunk
	chunks.allocator = stream.allocator
	if sync.mutex_guard(&stream.mutex) {
		chunks = stream.pending
		stream.pending = nil
		stream.pending.allocator = stream.allocator
	}
	defer delete(chunks)
	for chunk in chunks {
		if stream.file != nil {
			payload, encode_error := agent.stream_encode_tool_output(chunk.call, chunk.parent_call, transmute([]u8)chunk.text, context.allocator)
			if encode_error == nil {
				_ = agent.stream_append(stream.file, .Tool_Output, payload)
				delete(payload)
			}
		}
		delete(chunk.text, stream.allocator)
	}
}

// serve_stream_assistant appends one assistant frame for the open turn. Only the
// owner thread calls it. A frame that cannot be written is dropped: the stream
// is display-only and must never fail the turn.
serve_stream_assistant :: proc(stream: ^Serve_Stream, kind: agent.Stream_Kind, text: string) {
	if stream.file == nil { return }
	payload, encode_error := agent.stream_encode_assistant(u64(stream.turn), stream.ordinal, transmute([]u8)text, context.allocator)
	if encode_error != nil { return }
	defer delete(payload)
	_ = agent.stream_append(stream.file, kind, payload)
}

serve_stream_assistant_begin :: proc(user_data: rawptr) {
	token := (^Serve_Stream_Token)(user_data)
	serve_stream_drain(token.stream)
	// A retry replaces a message that committed nothing, so the count still
	// names the ordinal of the message it replaces.
	if token.stream.store != nil {
		if count, count_error := journal.count_assistant_nodes(token.stream.store, token.stream.session, token.stream.turn); count_error == nil {
			token.stream.ordinal = count
		}
	}
	serve_stream_assistant(token.stream, .Assistant_Begin, "")
}

serve_stream_assistant_text :: proc(user_data: rawptr, text: string) {
	token := (^Serve_Stream_Token)(user_data)
	serve_stream_drain(token.stream)
	serve_stream_assistant(token.stream, .Assistant_Text, text)
}

serve_stream_assistant_flush :: proc(user_data: rawptr) {
	token := (^Serve_Stream_Token)(user_data)
	serve_stream_drain(token.stream)
	serve_stream_assistant(token.stream, .Assistant_Flush, "")
}

serve_stream_assistant_end :: proc(user_data: rawptr) {
	token := (^Serve_Stream_Token)(user_data)
	serve_stream_drain(token.stream)
	serve_stream_assistant(token.stream, .Assistant_End, "")
}

// serve_stream_tool_output queues one tool output chunk for the owner thread to
// append. It runs on tool worker threads, so it only takes the queue lock and
// wakes the owner: never file I/O, and the lock spans neither. A chunk from a
// turn the stream already closed is dropped.
serve_stream_tool_output :: proc(user_data: rawptr, call, parent_call: journal.Call_Id, chunk: string) {
	token := (^Serve_Stream_Token)(user_data)
	stream := token.stream
	if sync.mutex_guard(&stream.mutex) {
		if !stream.open || token.generation != stream.generation { return }
		text, clone_error := strings.clone(chunk, stream.allocator)
		if clone_error != nil { return }
		_, append_error := append(&stream.pending, Serve_Stream_Chunk{call = u64(call), parent_call = u64(parent_call), text = text})
		if append_error != nil {
			delete(text, stream.allocator)
		}
	}
	agent.owner_wake_signal()
}
