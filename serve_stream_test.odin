#+test
package main

import "core:fmt"
import "core:os"
import "core:testing"

import "nabla:agent"
import "nabla:agent/journal"

// test_serve_stream_turn_lifecycle drives one turn's stream through its
// public calls: the turn start truncates the file, assistant and tool frames
// land in order with the ordinal the journal count gives, and the turn end
// removes the file.
@(test)
test_serve_stream_turn_lifecycle :: proc(test: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "nabla-serve-stream-*", context.allocator)
	if directory_error != nil { testing.fail_now(test, "could not create a temporary directory") }
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	store, open_error := journal.open(directory, directory, journal.run_id_create(), .Read_Write, context.allocator)
	if open_error != nil { testing.fail_now(test, "could not open a journal") }
	defer {
		close_error := journal.close(store)
		testing.expect(test, close_error == nil, "closing the journal failed")
	}
	session, session_error := journal.create_session(store, {workspace = "/tmp/project", role = .Main})
	if session_error != nil { testing.fail_now(test, "could not create a session") }
	serve_stream_test_commit_node(test, store, session, 1, "first")

	streams := fmt.tprintf("%s/streams", directory)
	stream: Serve_Stream
	serve_stream_init(&stream, streams, session, context.allocator)
	defer serve_stream_destroy(&stream)
	if stream.path == "" { testing.fail_now(test, "the stream has no path") }
	if write_error := os.write_entire_file(stream.path, "stale bytes"); write_error != nil { testing.fail_now(test, "could not stage a stale file") }

	observer, streaming := serve_stream_begin(&stream, store, session, 1)
	if !testing.expect(test, streaming, "the stream should open") { return }
	if observer.user_data == nil { testing.fail_now(test, "the observer has no token") }
	observer.assistant_begin(observer.user_data)
	observer.assistant_text(observer.user_data, "second ")
	observer.tool_output(observer.user_data, 3, 0, "live")
	observer.assistant_text(observer.user_data, "answer")
	observer.assistant_end(observer.user_data)
	// The response commit lands between messages, so the next one takes a new ordinal.
	serve_stream_test_commit_node(test, store, session, 1, "second")
	observer.assistant_begin(observer.user_data)
	observer.assistant_text(observer.user_data, "third")
	observer.assistant_end(observer.user_data)

	expected := [?]struct {
		kind:    agent.Stream_Kind,
		turn:    u64,
		ordinal: u32,
		text:    string,
	} {
		{.Assistant_Begin, 1, 1, ""},
		{.Assistant_Text, 1, 1, "second "},
		{.Assistant_Text, 1, 1, "answer"},
		{.Assistant_End, 1, 1, ""},
		{.Assistant_Begin, 1, 2, ""},
		{.Assistant_Text, 1, 2, "third"},
		{.Assistant_End, 1, 2, ""},
	}
	offset := i64(0)
	assistant_seen := 0
	for want in expected {
		// The tool frame sits between the second message's first text and its
		// continuation; it is read where the order puts it.
		if assistant_seen == 2 {
			tool_kind, tool_payload, after_tool, tool_found, tool_error := agent.stream_read(stream.path, offset)
			if tool_error != nil || !tool_found { testing.fail_now(test, "could not read the tool frame") }
			defer delete(tool_payload)
			call, parent_call, chunk, tool_ok := agent.stream_decode_tool_output(tool_payload)
			testing.expect(test, tool_ok && tool_kind == .Tool_Output && call == 3 && parent_call == 0 && string(chunk) == "live")
			offset = after_tool
		}
		kind, payload, next, found, read_error := agent.stream_read(stream.path, offset)
		if read_error != nil || !found { testing.fail_now(test, "could not read an assistant frame") }
		defer delete(payload)
		turn, ordinal, text, ok := agent.stream_decode_assistant(payload)
		testing.expect(test, ok && kind == want.kind && turn == want.turn && ordinal == want.ordinal && string(text) == want.text)
		offset = next
		assistant_seen += 1
	}
	serve_stream_end(&stream)
	_, missing, _, missing_found, missing_error := agent.stream_read(stream.path, 0)
	delete(missing)
	testing.expect(test, missing_error == nil && !missing_found, "the turn end must remove the stream file")
	// The turn's token lives until no worker can still call back; the test runs
	// no worker, so it releases its own token where the leak checker can see it.
	free((^Serve_Stream_Token)(observer.user_data), context.allocator)
}

@(private)
serve_stream_test_commit_node :: proc(test: ^testing.T, store: ^journal.Journal, session: journal.Session_Id, turn: journal.Turn_Id, text: string) {
	if journal.append_node(
		   store,
		   {session = session, branch = journal.INITIAL_BRANCH, kind = .Assistant, turn = turn},
		   journal.Assistant{request = 1},
		   transmute([]u8)text,
	   ) ==
	   0 {
		testing.fail_now(test, "could not buffer an assistant node")
	}
	if _, commit_error := journal.commit(store); commit_error != nil { testing.fail_now(test, "could not commit the journal") }
}
