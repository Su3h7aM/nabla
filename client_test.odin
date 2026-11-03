#+test
#+private file
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent"
import "nabla:agent/journal"

// Client_Stream_Log is the observer text a follow poll showed, in order.
Client_Stream_Log :: struct {
	events: [dynamic]string,
}

client_stream_log_add :: proc(user_data: rawptr, event: string) {
	log := cast(^Client_Stream_Log)user_data
	append(&log.events, strings.clone(event))
}

client_stream_log_begin :: proc(user_data: rawptr) {
	client_stream_log_add(user_data, "begin")
}

client_stream_log_text :: proc(user_data: rawptr, text: string) {
	client_stream_log_add(user_data, fmt.tprintf("text:%s", text))
}

client_stream_log_flush :: proc(user_data: rawptr) {
	client_stream_log_add(user_data, "flush")
}

client_stream_log_end :: proc(user_data: rawptr) {
	client_stream_log_add(user_data, "end")
}

client_stream_log_observer :: proc(log: ^Client_Stream_Log) -> agent.Chat_Observer {
	return {
		user_data = log,
		assistant_begin = client_stream_log_begin,
		assistant_text = client_stream_log_text,
		assistant_flush = client_stream_log_flush,
		assistant_end = client_stream_log_end,
	}
}

client_stream_log_destroy :: proc(log: ^Client_Stream_Log) {
	for event in log.events { delete(event) }
	delete(log.events)
}

client_stream_expect :: proc(test: ^testing.T, log: ^Client_Stream_Log, want: []string) {
	if !testing.expect_value(test, len(log.events), len(want)) { return }
	for event, index in want {
		testing.expect_value(test, log.events[index], event)
	}
	for event in log.events { delete(event) }
	clear(&log.events)
}

client_test_frame :: proc(test: ^testing.T, file: ^os.File, kind: agent.Stream_Kind, ordinal: u32, text: string) {
	payload, encode_error := agent.stream_encode_assistant(1, ordinal, transmute([]u8)text)
	if encode_error != nil { testing.fail_now(test, "the frame could not be encoded") }
	defer delete(payload)
	if agent.stream_append(file, kind, payload) != nil { testing.fail_now(test, "the frame could not be written") }
}

// A streamed prefix is shown as it arrives, a retried begin closes that attempt, and the
// committed text is completed once: the suffix of a partial stream, and nothing more when
// the stream already showed the whole message.
@(test)
test_a_follower_shows_streamed_assistant_text_once :: proc(test: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "nabla-client-stream-*", context.allocator)
	if directory_error != nil { testing.fail_now(test, "could not create a temporary directory") }
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	store, open_error := journal.open(directory, directory, journal.run_id_create(), .Read_Write)
	if open_error != nil { testing.fail_now(test, "the journal did not open") }
	defer testing.expect(test, journal.close(store) == nil, "the journal should close")
	session, create_error := journal.create_session(store, {workspace = directory, role = .Main})
	if create_error != nil { testing.fail_now(test, "the session was not created") }
	if _, commit_error := journal.commit(store); commit_error != nil { testing.fail_now(test, "the session did not commit") }

	cursor, start_error := agent.follow_start(store, session)
	if start_error != nil { testing.fail_now(test, "the follow did not start") }
	delivered := make(map[Client_Stream_Key]Client_Stream_Message, context.allocator)
	follow := Client_Follow {
		store     = store,
		session   = session,
		cursor    = cursor,
		delivered = delivered,
	}
	defer client_follow_close(&follow)

	streams, streams_error := agent.stream_directory(context.allocator)
	if streams_error != .None { testing.fail_now(test, "the streams directory was not resolved") }
	defer delete(streams)
	if agent.xdg_directory_create(streams) != .None { testing.fail_now(test, "the streams directory was not created") }
	path, path_error := agent.stream_path(streams, session, context.allocator)
	if path_error != nil { testing.fail_now(test, "the stream path was not made") }
	defer {
		_ = agent.stream_remove(path)
		delete(path)
	}
	file, file_error := agent.stream_open_writer(path)
	if file_error != nil { testing.fail_now(test, "the stream file did not open") }
	defer _ = os.close(file)

	client_test_frame(test, file, .Assistant_Begin, 0, "")
	client_test_frame(test, file, .Assistant_Text, 0, "Hel")
	client_test_frame(test, file, .Assistant_Begin, 0, "")
	client_test_frame(test, file, .Assistant_Text, 0, "Wo")
	client_test_frame(test, file, .Assistant_Flush, 0, "")

	log: Client_Stream_Log
	defer client_stream_log_destroy(&log)
	observer := client_stream_log_observer(&log)
	if client_follow_poll(&follow, observer) != nil { testing.fail_now(test, "the stream poll failed") }
	client_stream_expect(test, &log, {"begin", "text:Hel", "end", "begin", "text:Wo", "flush"})

	_ = journal.append_node(
		store,
		{session = session, branch = journal.INITIAL_BRANCH, kind = .Assistant, turn = 1},
		journal.Assistant{request = 1},
		transmute([]u8)string("World"),
	)
	if _, commit_error := journal.commit(store); commit_error != nil { testing.fail_now(test, "the assistant record did not commit") }
	if client_follow_poll(&follow, observer) != nil { testing.fail_now(test, "the journal poll failed") }
	client_stream_expect(test, &log, {"text:rld", "end"})

	client_test_frame(test, file, .Assistant_Begin, 1, "")
	client_test_frame(test, file, .Assistant_Text, 1, "done")
	client_test_frame(test, file, .Assistant_End, 1, "")
	_ = journal.append_node(
		store,
		{session = session, branch = journal.INITIAL_BRANCH, kind = .Assistant, turn = 1},
		journal.Assistant{request = 1},
		transmute([]u8)string("done"),
	)
	if _, commit_error := journal.commit(store); commit_error != nil { testing.fail_now(test, "the second assistant record did not commit") }
	if client_follow_poll(&follow, observer) != nil { testing.fail_now(test, "the second poll failed") }
	client_stream_expect(test, &log, {"begin", "text:done", "end"})
}
