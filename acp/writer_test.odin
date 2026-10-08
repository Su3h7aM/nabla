#+test
#+private file
package acp

import "core:bytes"
import "core:encoding/json"
import "core:io"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// test_writer_stream adapts a bytes.Buffer to the stream the writer writes to, so a
// test reads the exact frames a client would.
test_writer_stream :: proc(buffer: ^bytes.Buffer) -> io.Stream {
	return io.Stream {
		data = buffer,
		procedure = proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
			switch mode {
			case .Write:
				written, write_err := bytes.buffer_write(cast(^bytes.Buffer)data, p)
				return i64(written), write_err
			case .Query:
				return i64(io.Stream_Mode_Set{.Write}), nil
			case .Close, .Flush, .Destroy:
				return 0, nil
			case .Read, .Seek, .Read_At, .Write_At, .Size:
				return 0, .Unsupported
			}
			return 0, .Unsupported
		},
	}
}

test_writer_finish :: proc(t: ^testing.T, writer: ^Writer) {
	if !writer_destroy(writer, time.Second) {
		testing.fail_now(t, "the writer did not drain its frames")
	}
}

test_writer_cleanup :: proc(writer: ^Writer) {
	_ = writer_destroy(writer, time.Second)
}

Test_Writer_Stall :: struct {
	mutex:   sync.Mutex,
	cond:    sync.Cond,
	entered: bool,
	release: bool,
	buffer:  bytes.Buffer,
}

test_writer_stalled_stream :: proc(state: ^Test_Writer_Stall) -> io.Stream {
	return io.Stream {
		data = state,
		procedure = proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
			state := cast(^Test_Writer_Stall)data
			switch mode {
			case .Write:
				sync.mutex_lock(&state.mutex)
				state.entered = true
				sync.cond_broadcast(&state.cond)
				for !state.release { sync.cond_wait(&state.cond, &state.mutex) }
				written, write_error := bytes.buffer_write(&state.buffer, p)
				sync.mutex_unlock(&state.mutex)
				return i64(written), write_error
			case .Query:
				return i64(io.Stream_Mode_Set{.Write}), nil
			case .Close, .Flush, .Destroy:
				return 0, nil
			case .Read, .Seek, .Read_At, .Write_At, .Size:
				return 0, .Unsupported
			}
			return 0, .Unsupported
		},
	}
}

test_writer_wait_for_stall :: proc(t: ^testing.T, state: ^Test_Writer_Stall) {
	sync.mutex_lock(&state.mutex)
	deadline := time.tick_add(time.tick_now(), time.Second)
	for !state.entered {
		remaining := time.tick_diff(time.tick_now(), deadline)
		if remaining <= 0 { break }
		_ = sync.cond_wait_with_timeout(&state.cond, &state.mutex, remaining)
	}
	entered := state.entered
	sync.mutex_unlock(&state.mutex)
	testing.expect(t, entered, "the writer did not enter its blocked output call")
}

Test_Writer_Send :: struct {
	writer: ^Writer,
	mutex:  sync.Mutex,
	cond:   sync.Cond,
	done:   bool,
	sent:   bool,
}

test_writer_send_notification :: proc(thread_handle: ^thread.Thread) {
	send := cast(^Test_Writer_Send)thread_handle.data
	send.sent = writer_write_notification(
		send.writer,
		"session/update",
		Session_Notification(Session_Info_Update){session_id = "s", update = Session_Info_Update{session_update = UPDATE_SESSION_INFO, title = "second"}},
	)
	sync.mutex_lock(&send.mutex)
	send.done = true
	sync.cond_broadcast(&send.cond)
	sync.mutex_unlock(&send.mutex)
}

@(test)
test_writer_senders_do_not_wait_for_stalled_output_and_keep_order :: proc(t: ^testing.T) {
	state: Test_Writer_Stall
	bytes.buffer_init_allocator(&state.buffer, 0, 0, context.allocator)
	defer bytes.buffer_destroy(&state.buffer)
	writer, writer_error := writer_init(test_writer_stalled_stream(&state))
	if writer_error != nil { testing.fail_now(t, "the writer could not be created") }
	defer test_writer_cleanup(&writer)
	defer {
		sync.mutex_lock(&state.mutex)
		state.release = true
		sync.cond_broadcast(&state.cond)
		sync.mutex_unlock(&state.mutex)
	}

	testing.expect(
		t,
		writer_write_notification(
			&writer,
			"session/update",
			Session_Notification(Session_Info_Update){session_id = "s", update = Session_Info_Update{session_update = UPDATE_SESSION_INFO, title = "first"}},
		),
	)
	test_writer_wait_for_stall(t, &state)

	send := Test_Writer_Send {
		writer = &writer,
	}
	sender := thread.create(test_writer_send_notification, name = "nabla-test-acp-sender")
	if sender == nil { testing.fail_now(t, "the sender thread could not be created") }
	sender.data = &send
	thread.start(sender)
	sync.mutex_lock(&send.mutex)
	deadline := time.tick_add(time.tick_now(), 200 * time.Millisecond)
	for !send.done {
		remaining := time.tick_diff(time.tick_now(), deadline)
		if remaining <= 0 { break }
		_ = sync.cond_wait_with_timeout(&send.cond, &send.mutex, remaining)
	}
	sent_while_stalled := send.done && send.sent
	sync.mutex_unlock(&send.mutex)

	sync.mutex_lock(&state.mutex)
	state.release = true
	sync.cond_broadcast(&state.cond)
	sync.mutex_unlock(&state.mutex)
	thread.join(sender)
	thread.destroy(sender)
	testing.expect(t, sent_while_stalled, "a sender waited for the stalled writer")
	test_writer_finish(t, &writer)

	frames := bytes.buffer_to_string(&state.buffer)
	first := strings.index(frames, `"title":"first"`)
	second := strings.index(frames, `"title":"second"`)
	testing.expect(t, first >= 0 && second > first, "the writer did not preserve enqueue order")
}

@(test)
test_writer_shutdown_abandons_a_stalled_output_within_patience :: proc(t: ^testing.T) {
	state: Test_Writer_Stall
	bytes.buffer_init_allocator(&state.buffer, 0, 0, context.allocator)
	defer bytes.buffer_destroy(&state.buffer)
	writer, writer_error := writer_init(test_writer_stalled_stream(&state))
	if writer_error != nil { testing.fail_now(t, "the writer could not be created") }
	defer test_writer_cleanup(&writer)
	defer {
		sync.mutex_lock(&state.mutex)
		state.release = true
		sync.cond_broadcast(&state.cond)
		sync.mutex_unlock(&state.mutex)
	}

	testing.expect(
		t,
		writer_write_notification(
			&writer,
			"session/update",
			Session_Notification(Session_Info_Update){session_id = "s", update = Session_Info_Update{session_update = UPDATE_SESSION_INFO, title = "queued"}},
		),
	)
	test_writer_wait_for_stall(t, &state)
	patience := 25 * time.Millisecond
	started := time.tick_now()
	retired := writer_destroy(&writer, patience)
	elapsed := time.tick_diff(started, time.tick_now())
	testing.expect(t, !retired, "a blocked write must be abandoned")
	testing.expect(t, elapsed < patience + 250 * time.Millisecond, "shutdown exceeded the writer patience")

	sync.mutex_lock(&state.mutex)
	state.release = true
	sync.cond_broadcast(&state.cond)
	sync.mutex_unlock(&state.mutex)
	testing.expect(t, writer_destroy(&writer, time.Second), "the released writer should retire")
}

@(test)
test_writer_frames_response_error_and_notification :: proc(t: ^testing.T) {
	buffer: bytes.Buffer
	bytes.buffer_init_allocator(&buffer, 0, 0, context.allocator)
	defer bytes.buffer_destroy(&buffer)
	writer, writer_err := writer_init(test_writer_stream(&buffer))
	if writer_err != nil { testing.fail_now(t, "the writer could not be created") }
	defer test_writer_cleanup(&writer)

	testing.expect(t, writer_write_response(&writer, i64(7), Session_New_Result{session_id = "sess_1"}))
	testing.expect(t, writer_write_error(&writer, "req-1", ERROR_INVALID_PARAMS, "no such session"))
	update := Tool_Call {
		session_update = UPDATE_TOOL_CALL,
		tool_call_id   = "call_1",
		title          = "read src/main.odin",
		kind           = tool_kind_name(.Read),
		status         = tool_status_name(.Pending),
	}
	testing.expect(t, writer_write_notification(&writer, NOTIFICATION_SESSION_UPDATE, Session_Notification(Tool_Call){session_id = "sess_1", update = update}))
	test_writer_finish(t, &writer)

	want :=
		`{"jsonrpc":"2.0","id":7,"result":{"sessionId":"sess_1","models":{"currentModelId":"","availableModels":[]}}}` +
		"\n" +
		`{"jsonrpc":"2.0","id":"req-1","error":{"code":-32602,"message":"no such session"}}` +
		"\n" +
		`{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_1","update":{"sessionUpdate":"tool_call","toolCallId":"call_1","title":"read src/main.odin","kind":"read","status":"pending"}}}` +
		"\n"
	testing.expect_value(t, bytes.buffer_to_string(&buffer), want)
}

@(test)
test_writer_includes_buzz_model_metadata :: proc(t: ^testing.T) {
	buffer: bytes.Buffer
	bytes.buffer_init_allocator(&buffer, 0, 0, context.allocator)
	defer bytes.buffer_destroy(&buffer)
	writer, writer_err := writer_init(test_writer_stream(&buffer))
	if writer_err != nil { testing.fail_now(t, "the writer could not be created") }
	defer test_writer_cleanup(&writer)

	models := []Model_Info{{model_id = "test-model", name = "Test Model"}}
	state := Models_State {
		current_model_id = "test-model",
		available_models = models,
	}
	config := []V1_Config_Option {
		{
			id = "model",
			name = "Model",
			category = "model",
			type = "select",
			current_value = "test-model",
			options = []Config_Value{{value = "test-model", name = "Test Model"}},
		},
	}
	result := Session_New_Result {
		session_id     = "sess_models",
		config_options = config,
		models         = state,
	}
	testing.expect(t, writer_write_response(&writer, i64(8), result))
	test_writer_finish(t, &writer)
	frame := bytes.buffer_to_string(&buffer)
	testing.expect(
		t,
		strings.contains(
			frame,
			`"configOptions":[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"test-model","options":[{"value":"test-model","name":"Test Model"}]}`,
		),
	)
	testing.expect(t, strings.contains(frame, `"value":"test-model"`))
	testing.expect(t, strings.contains(frame, `"models":{"currentModelId":"test-model","availableModels":[{"modelId":"test-model","name":"Test Model"}]}`))
}

@(test)
test_writer_batches_responses_and_keeps_notifications_as_own_frames :: proc(t: ^testing.T) {
	buffer: bytes.Buffer
	bytes.buffer_init_allocator(&buffer, 0, 0, context.allocator)
	defer bytes.buffer_destroy(&buffer)
	writer, writer_err := writer_init(test_writer_stream(&buffer))
	if writer_err != nil { testing.fail_now(t, "the writer could not be created") }
	defer test_writer_cleanup(&writer)

	testing.expect(t, writer_begin_batch(&writer))
	testing.expect(t, writer_write_response(&writer, i64(1), Session_New_Result{session_id = "sess_1"}))
	testing.expect(t, writer_write_error(&writer, "two", ERROR_INVALID_PARAMS, "bad request"))
	testing.expect(
		t,
		writer_write_notification(
			&writer,
			"session/update",
			Session_Notification(Session_Info_Update) {
				session_id = "sess_1",
				update = Session_Info_Update{session_update = "session_info_update", title = "kept"},
			},
		),
	)
	testing.expect(t, writer_end_batch(&writer))

	testing.expect(t, writer_begin_batch(&writer))
	testing.expect(t, writer_write_response(&writer, i64(3), Empty_Result{}))
	testing.expect(t, writer_end_batch(&writer))
	test_writer_finish(t, &writer)

	want :=
		`{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_1","update":{"sessionUpdate":"session_info_update","title":"kept"}}}` +
		"\n" +
		`[{"jsonrpc":"2.0","id":1,"result":{"sessionId":"sess_1","models":{"currentModelId":"","availableModels":[]}}},{"jsonrpc":"2.0","id":"two","error":{"code":-32602,"message":"bad request"}}]` +
		"\n" +
		`[{"jsonrpc":"2.0","id":3,"result":{}}]` +
		"\n"
	testing.expect_value(t, bytes.buffer_to_string(&buffer), want)
}

@(test)
test_writer_frames_a_request :: proc(t: ^testing.T) {
	buffer: bytes.Buffer
	bytes.buffer_init_allocator(&buffer, 0, 0, context.allocator)
	defer bytes.buffer_destroy(&buffer)
	writer, writer_err := writer_init(test_writer_stream(&buffer))
	if writer_err != nil { testing.fail_now(t, "the writer could not be created") }
	defer test_writer_cleanup(&writer)

	params := Session_Prompt_Params {
		session_id = "s",
		prompt     = {{type = "text", text = "hi"}},
	}
	testing.expect(t, writer_write_request(&writer, 7, METHOD_SESSION_PROMPT, params))
	test_writer_finish(t, &writer)

	want :=
		`{"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{"sessionId":"s","prompt":[{"type":"text","text":"hi","uri":"","resource":{"uri":"","text":""}}]}}` +
		"\n"
	testing.expect_value(t, bytes.buffer_to_string(&buffer), want)
}

@(test)
test_v2_initialize_result_uses_v2_capability_shape :: proc(t: ^testing.T) {
	buffer: bytes.Buffer
	bytes.buffer_init_allocator(&buffer, 0, 0, context.allocator)
	defer bytes.buffer_destroy(&buffer)
	writer, writer_err := writer_init(test_writer_stream(&buffer))
	if writer_err != nil { testing.fail_now(t, "the writer could not be created") }
	defer test_writer_cleanup(&writer)

	result := V2_Initialize_Result {
		protocol_version = PROTOCOL_VERSION_V2,
		info = {name = "nabla", title = "Nabla", version = "0.1.0"},
		capabilities = {session = {prompt = {image = V2_Support{}, embedded_context = {}}, mcp = {stdio = {}}}},
		auth_methods = {},
	}
	testing.expect(t, writer_write_response(&writer, i64(2), result))
	test_writer_finish(t, &writer)
	frame := bytes.buffer_to_string(&buffer)
	testing.expect(t, strings.contains(frame, `"protocolVersion":2`))
	testing.expect(t, strings.contains(frame, `"capabilities":{"session":{"prompt":{"image":{},"embeddedContext":{}},"mcp":{"stdio":{}}}}`))
	testing.expect(t, strings.contains(frame, `"info":{"name":"nabla","title":"Nabla","version":"0.1.0"}`))
}

@(test)
test_v2_resume_params_read_replay_cursor :: proc(t: ^testing.T) {
	value, parse_err := json.parse_string(
		`{"sessionId":"0123456789abcdef0123456789abcdef","cwd":"/workspace","replayFrom":{"type":"start"}}`,
		.JSON,
		true,
		context.allocator,
	)
	defer json.destroy_value(value, context.allocator)
	testing.expect(t, parse_err == nil)
	params: Session_Resume_Params
	testing.expect_value(t, params_decode(value, &params), Params_Error.None)
	defer {
		delete(params.session_id)
		delete(params.cwd)
		delete(params.mcp_servers)
		delete(params.additional_directories)
		delete(params.system_prompt)
		delete(params.meta.session_title)
	}
	cursor, present := params.replay_from.?
	testing.expect(t, present)
	testing.expect_value(t, cursor.type, "start")
	delete(cursor.type)
}

@(test)
test_params_decode_reads_content_blocks_and_tolerates_extra_fields :: proc(t: ^testing.T) {
	value, parse_err := json.parse_string(
		`{"sessionId":"s","prompt":[{"type":"text","text":"hi","_meta":{}},{"type":"resource_link","uri":"file:///a.odin","name":"a.odin"}],"extra":1}`,
		.JSON,
		true,
		context.allocator,
	)
	defer json.destroy_value(value, context.allocator)
	testing.expect(t, parse_err == nil)

	params: Session_Prompt_Params
	testing.expect_value(t, params_decode(value, &params), Params_Error.None)
	defer {
		delete(params.session_id)
		for block in params.prompt {
			delete(block.type)
			delete(block.text)
			delete(block.uri)
		}
		delete(params.prompt)
	}
	testing.expect_value(t, params.session_id, "s")
	testing.expect_value(t, len(params.prompt), 2)
	testing.expect_value(t, params.prompt[0].type, CONTENT_TEXT)
	testing.expect_value(t, params.prompt[0].text, "hi")
	testing.expect_value(t, params.prompt[1].type, CONTENT_RESOURCE_LINK)
	testing.expect_value(t, params.prompt[1].uri, "file:///a.odin")
}
