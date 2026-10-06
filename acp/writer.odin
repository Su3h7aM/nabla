package acp

import "base:runtime"
import "core:encoding/json"
import "core:io"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// Writer is an asynchronous framed writer. Its state is heap-owned so a writer
// thread that does not retire can be abandoned without borrowing the Writer value.
Writer :: struct {
	state: ^Writer_State,
}

@(private)
Writer_State :: struct {
	out:        io.Writer,
	allocator:  mem.Allocator,
	mutex:      sync.Mutex,
	ready:      sync.Cond,
	queue:      [dynamic]string,
	head:       int,
	worker:     ^thread.Thread,
	batch:      [dynamic]string,
	batch_mode: bool,
	closing:    bool,
	closed:     bool,
	failed:     bool,
	finished:   bool,
}

// Writer_Init_Thread_Error names a failure to create the writer's owner thread.
Writer_Init_Thread_Error :: enum {
	None,
	Thread_Create_Failed,
}

// Writer_Init_Error is an allocation failure or a writer-thread creation failure.
Writer_Init_Error :: union #shared_nil {
	mem.Allocator_Error,
	Writer_Init_Thread_Error,
}

// writer_init starts the thread that exclusively writes to out. Writer state and queued
// frames use allocator; allocator and out must remain valid until writer_destroy succeeds.
// The returned error is an allocation or thread creation failure.
@(require_results)
writer_init :: proc(out: io.Writer, allocator := context.allocator) -> (Writer, Writer_Init_Error) {
	state, state_error := new(Writer_State, allocator)
	if state_error != nil { return {}, state_error }
	state.out = out
	state.allocator = allocator
	state.queue.allocator = allocator
	state.batch.allocator = allocator

	previous_allocator := context.allocator
	context.allocator = allocator
	worker := thread.create(writer_run, name = "nabla-acp-writer")
	context.allocator = previous_allocator
	if worker == nil {
		free(state, allocator)
		return {}, Writer_Init_Thread_Error.Thread_Create_Failed
	}
	state.worker = worker
	worker.data = state
	thread.start(worker)
	return Writer{state = state}, nil
}

// writer_destroy closes admission, drains queued frames, and waits at most patience for
// the owner thread. It returns true after releasing state and the thread handle. On
// timeout it returns false and leaves both allocated because the thread may still be
// inside out.Write; the caller must keep out and its data valid until process exit.
@(require_results)
writer_destroy :: proc(writer: ^Writer, patience: time.Duration) -> bool {
	state := writer.state
	if state == nil { return true }

	// A failed or empty batch must not keep shutdown from draining queued frames.
	_ = writer_end_batch(writer)

	sync.mutex_lock(&state.mutex)
	state.closing = true
	sync.cond_broadcast(&state.ready)
	deadline := time.tick_add(time.tick_now(), patience)
	for !state.finished {
		remaining := time.tick_diff(time.tick_now(), deadline)
		if remaining <= 0 { break }
		_ = sync.cond_wait_with_timeout(&state.ready, &state.mutex, remaining)
	}
	finished := state.finished
	worker := state.worker
	sync.mutex_unlock(&state.mutex)
	if !finished { return false }

	thread.destroy(worker)
	writer_state_destroy(state)
	free(state, state.allocator)
	writer.state = nil
	return true
}

// writer_failed reports whether an I/O error closed the output stream.
writer_failed :: proc(writer: ^Writer) -> bool {
	state := writer.state
	if state == nil { return true }
	sync.mutex_lock(&state.mutex)
	failed := state.failed
	sync.mutex_unlock(&state.mutex)
	return failed
}

// writer_submit_value serializes value and transfers its complete response frame to
// the writer thread. True means queued, not written.
@(private, require_results)
writer_submit_value :: proc(writer: ^Writer, id: JSONRPC_Id, key: string, value: $T) -> bool {
	state := writer.state
	if state == nil { return false }
	body, marshal_error := json.marshal(value, allocator = context.temp_allocator)
	if marshal_error != nil { return false }
	defer delete(body, context.temp_allocator)
	frame, encoded := writer_encode_frame(state, id, key, body)
	if !encoded { return false }
	return writer_submit_frame(state, frame, true)
}

// writer_write_response serializes a result before transferring its complete frame to
// the writer thread. True means queued, not written.
@(require_results)
writer_write_response :: proc(writer: ^Writer, id: JSONRPC_Id, result: $T) -> bool {
	return writer_submit_value(writer, id, `"result":`, result)
}

// RPC_Error_Wire is the error document an error answer carries.
RPC_Error_Wire :: struct {
	code:    i64 `json:"code"`,
	message: string `json:"message"`,
}

// writer_write_error serializes an error before transferring its complete frame to the
// writer thread. True means queued, not written.
@(require_results)
writer_write_error :: proc(writer: ^Writer, id: JSONRPC_Id, code: i64, message: string) -> bool {
	return writer_submit_value(writer, id, `"error":`, RPC_Error_Wire{code = code, message = message})
}

// writer_write_notification serializes a notification before transferring its complete
// frame to the writer thread. Notifications remain separate frames during a batch.
@(require_results)
writer_write_notification :: proc(writer: ^Writer, method: string, params: $T) -> bool {
	state := writer.state
	if state == nil || state.out.procedure == nil { return false }
	body, marshal_error := json.marshal(params, allocator = context.temp_allocator)
	if marshal_error != nil { return false }
	defer delete(body, context.temp_allocator)
	frame, encoded := writer_encode_notification(state, method, body)
	if !encoded { return false }
	return writer_submit_frame(state, frame, false)
}

// writer_write_request serializes a request before transferring its complete frame to the
// writer thread. True means queued, not written.
@(require_results)
writer_write_request :: proc(writer: ^Writer, id: i64, method: string, params: $T) -> bool {
	state := writer.state
	if state == nil || state.out.procedure == nil { return false }
	body, marshal_error := json.marshal(params, allocator = context.temp_allocator)
	if marshal_error != nil { return false }
	defer delete(body, context.temp_allocator)
	frame, encoded := writer_encode_request(state, id, method, body)
	if !encoded { return false }
	return writer_submit_frame(state, frame, false)
}

@(private, require_results)
writer_encode_frame :: proc(state: ^Writer_State, id: JSONRPC_Id, key: string, body: []byte) -> (string, bool) {
	builder, builder_error := strings.builder_make(state.allocator)
	if builder_error != nil { return "", false }
	if !writer_builder_string(&builder, `{"jsonrpc":"2.0","id":`) ||
	   !writer_write_id(&builder, id) ||
	   !writer_builder_byte(&builder, ',') ||
	   !writer_builder_string(&builder, key) ||
	   !writer_builder_bytes(&builder, body) ||
	   !writer_builder_string(&builder, "}\n") {
		strings.builder_destroy(&builder)
		return "", false
	}
	return strings.to_string(builder), true
}

@(private, require_results)
writer_encode_notification :: proc(state: ^Writer_State, method: string, body: []byte) -> (string, bool) {
	builder, builder_error := strings.builder_make(state.allocator)
	if builder_error != nil { return "", false }
	if !writer_builder_string(&builder, `{"jsonrpc":"2.0","method":`) ||
	   !writer_write_quoted(&builder, method) ||
	   !writer_builder_string(&builder, `,"params":`) ||
	   !writer_builder_bytes(&builder, body) ||
	   !writer_builder_string(&builder, "}\n") {
		strings.builder_destroy(&builder)
		return "", false
	}
	return strings.to_string(builder), true
}

@(private, require_results)
writer_encode_request :: proc(state: ^Writer_State, id: i64, method: string, body: []byte) -> (string, bool) {
	builder, builder_error := strings.builder_make(state.allocator)
	if builder_error != nil { return "", false }
	if !writer_builder_string(&builder, `{"jsonrpc":"2.0","id":`) ||
	   !writer_write_id(&builder, JSONRPC_Id(id)) ||
	   !writer_builder_string(&builder, `,"method":`) ||
	   !writer_write_quoted(&builder, method) ||
	   !writer_builder_string(&builder, `,"params":`) ||
	   !writer_builder_bytes(&builder, body) ||
	   !writer_builder_string(&builder, "}\n") {
		strings.builder_destroy(&builder)
		return "", false
	}
	return strings.to_string(builder), true
}

// writer_submit_frame takes ownership of frame on both success and failure.
@(private, require_results)
writer_submit_frame :: proc(state: ^Writer_State, frame: string, response: bool) -> bool {
	transferred := false
	defer if !transferred { delete(frame, state.allocator) }
	sync.mutex_lock(&state.mutex)
	defer sync.mutex_unlock(&state.mutex)
	if state.out.procedure == nil || state.closed || state.closing { return false }
	if response && state.batch_mode {
		if append(&state.batch, frame) != 1 { return false }
		transferred = true
		return true
	}
	if append(&state.queue, frame) != 1 { return false }
	transferred = true
	sync.cond_signal(&state.ready)
	return true
}

@(require_results)
writer_begin_batch :: proc(writer: ^Writer) -> bool {
	state := writer.state
	if state == nil { return false }
	sync.mutex_lock(&state.mutex)
	defer sync.mutex_unlock(&state.mutex)
	if state.closed || state.closing || state.batch_mode { return false }
	state.batch_mode = true
	return true
}

@(require_results)
writer_end_batch :: proc(writer: ^Writer) -> bool {
	state := writer.state
	if state == nil { return false }
	sync.mutex_lock(&state.mutex)
	defer sync.mutex_unlock(&state.mutex)
	if !state.batch_mode { return false }
	if state.closed || state.closing {
		writer_batch_clear_locked(state)
		state.batch_mode = false
		return false
	}
	if len(state.batch) == 0 {
		writer_batch_clear_locked(state)
		state.batch_mode = false
		return true
	}

	builder, builder_error := strings.builder_make(state.allocator)
	if builder_error != nil {
		writer_batch_clear_locked(state)
		state.batch_mode = false
		return false
	}
	defer strings.builder_destroy(&builder)
	if strings.write_byte(&builder, '[') != 1 {
		writer_batch_clear_locked(state)
		state.batch_mode = false
		return false
	}
	for frame, index in state.batch {
		if index > 0 && strings.write_byte(&builder, ',') != 1 {
			writer_batch_clear_locked(state)
			state.batch_mode = false
			return false
		}
		if !writer_builder_string(&builder, frame[:len(frame) - 1]) {
			writer_batch_clear_locked(state)
			state.batch_mode = false
			return false
		}
	}
	if !writer_builder_string(&builder, "]\n") {
		writer_batch_clear_locked(state)
		state.batch_mode = false
		return false
	}
	batch_frame, clone_error := strings.clone(strings.to_string(builder), state.allocator)
	writer_batch_clear_locked(state)
	state.batch_mode = false
	if clone_error != nil { return false }
	if append(&state.queue, batch_frame) != 1 {
		delete(batch_frame, state.allocator)
		return false
	}
	sync.cond_signal(&state.ready)
	return true
}

@(private)
writer_batch_clear_locked :: proc(state: ^Writer_State) {
	for frame in state.batch { delete(frame, state.allocator) }
	delete(state.batch)
	state.batch = nil
	state.batch.allocator = state.allocator
}

@(private)
writer_queue_clear_locked :: proc(state: ^Writer_State) {
	for index := state.head; index < len(state.queue); index += 1 {
		delete(state.queue[index], state.allocator)
	}
	delete(state.queue)
	state.queue = nil
	state.queue.allocator = state.allocator
	state.head = 0
}

@(private)
writer_state_destroy :: proc(state: ^Writer_State) {
	writer_batch_clear_locked(state)
	writer_queue_clear_locked(state)
	state.out = {}
	state.worker = nil
}

@(private)
writer_run :: proc(thread_handle: ^thread.Thread) {
	state := cast(^Writer_State)thread_handle.data
	context.allocator = state.allocator
	context.logger = runtime.default_logger()
	for {
		sync.mutex_lock(&state.mutex)
		for state.head == len(state.queue) && !state.closing {
			sync.cond_wait(&state.ready, &state.mutex)
		}
		if state.head == len(state.queue) {
			state.finished = true
			sync.cond_broadcast(&state.ready)
			sync.mutex_unlock(&state.mutex)
			return
		}
		frame := state.queue[state.head]
		state.queue[state.head] = ""
		state.head += 1
		// A drained queue keeps its capacity for the next burst of frames.
		if state.head == len(state.queue) {
			clear(&state.queue)
			state.head = 0
		}
		sync.mutex_unlock(&state.mutex)

		frame_length := len(frame)
		written, write_error := io.write_string(state.out, frame)
		delete(frame, state.allocator)
		free_all(context.temp_allocator)
		if write_error != nil || written != frame_length {
			sync.mutex_lock(&state.mutex)
			state.closed = true
			state.failed = true
			state.closing = true
			writer_queue_clear_locked(state)
			writer_batch_clear_locked(state)
			state.batch_mode = false
			state.finished = true
			sync.cond_broadcast(&state.ready)
			sync.mutex_unlock(&state.mutex)
			return
		}
	}
}

@(private, require_results)
writer_builder_string :: proc(builder: ^strings.Builder, value: string) -> bool {
	return strings.write_string(builder, value) == len(value)
}

@(private, require_results)
writer_builder_bytes :: proc(builder: ^strings.Builder, value: []byte) -> bool {
	return strings.write_bytes(builder, value) == len(value)
}

@(private, require_results)
writer_builder_byte :: proc(builder: ^strings.Builder, value: byte) -> bool {
	return strings.write_byte(builder, value) == 1
}

@(private, require_results)
writer_write_id :: proc(builder: ^strings.Builder, id: JSONRPC_Id) -> bool {
	switch value in id {
	case i64, f64:
		body, err := json.marshal(value, allocator = context.temp_allocator)
		if err != nil { return false }
		defer delete(body, context.temp_allocator)
		return writer_builder_bytes(builder, body)
	case string:
		return writer_write_quoted(builder, value)
	case JSONRPC_Null:
		return writer_builder_string(builder, "null")
	case:
		// An id the envelope parser would have refused cannot name a request, so a
		// response to it is written as the JSON null a client can still match.
		return writer_builder_string(builder, "null")
	}
}

// writer_write_quoted writes one JSON string. It is the only place outbound text is
// escaped, so every string the writer emits is valid whatever it contains.
@(private, require_results)
writer_write_quoted :: proc(builder: ^strings.Builder, value: string) -> bool {
	if !writer_builder_byte(builder, '"') { return false }
	for i := 0; i < len(value); i += 1 {
		character := value[i]
		switch character {
		case '"':
			if !writer_builder_string(builder, `\"`) { return false }
		case '\\':
			if !writer_builder_string(builder, `\\`) { return false }
		case '\n':
			if !writer_builder_string(builder, `\n`) { return false }
		case '\r':
			if !writer_builder_string(builder, `\r`) { return false }
		case '\t':
			if !writer_builder_string(builder, `\t`) { return false }
		case '\b':
			if !writer_builder_string(builder, `\b`) { return false }
		case '\f':
			if !writer_builder_string(builder, `\f`) { return false }
		case:
			if character < 0x20 {
				if !writer_builder_string(builder, `\u00`) ||
				   !writer_builder_byte(builder, writer_hex_digit(character >> 4)) ||
				   !writer_builder_byte(builder, writer_hex_digit(character & 0x0F)) { return false }
			} else if !writer_builder_byte(builder, character) {
				return false
			}
		}
	}
	return writer_builder_byte(builder, '"')
}

@(private)
writer_hex_digit :: proc(value: byte) -> byte {
	if value < 10 { return '0' + value }
	return 'a' + (value - 10)
}
