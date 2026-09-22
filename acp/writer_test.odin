#+test
#+private file
package acp

import "core:bytes"
import "core:encoding/json"
import "core:io"
import "core:testing"

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

@(test)
test_writer_frames_response_error_and_notification :: proc(t: ^testing.T) {
	buffer: bytes.Buffer
	bytes.buffer_init_allocator(&buffer, 0, 0, context.allocator)
	defer bytes.buffer_destroy(&buffer)
	writer := writer_init(test_writer_stream(&buffer))
	defer writer_destroy(&writer)

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

	want :=
		`{"jsonrpc":"2.0","id":7,"result":{"sessionId":"sess_1"}}` +
		"\n" +
		`{"jsonrpc":"2.0","id":"req-1","error":{"code":-32602,"message":"no such session"}}` +
		"\n" +
		`{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_1","update":{"sessionUpdate":"tool_call","toolCallId":"call_1","title":"read src/main.odin","kind":"read","status":"pending"}}}` +
		"\n"
	testing.expect_value(t, bytes.buffer_to_string(&buffer), want)
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
	testing.expect(t, params_decode(value, &params))
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
