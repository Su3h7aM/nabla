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

// Write_Error is why a frame was not queued. Closed covers a nil writer, a
// missing stream, a closed or closing writer, and batch misuse. Encode is an
// envelope json.marshal cannot represent. Allocation is any storage the frame
// needed that could not be obtained.
Write_Error :: enum {
	None,
	Closed,
	Encode,
	Allocation,
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
	worker := thread.create(writer_run, name = "acp-writer")
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

// writer_failed reports whether a response could not be queued or I/O failed.
writer_failed :: proc(writer: ^Writer) -> bool {
	state := writer.state
	if state == nil { return true }
	sync.mutex_guard(&state.mutex)
	return state.failed
}

@(private)
writer_latch_failure_locked :: proc(state: ^Writer_State) {
	state.failed = true
	state.closed = true
	state.closing = true
	sync.cond_broadcast(&state.ready)
}

@(private)
writer_latch_failure :: proc(state: ^Writer_State) {
	sync.mutex_guard(&state.mutex)
	writer_latch_failure_locked(state)
}

// write_encode_error classifies a failed envelope marshal. Only a failure is
// classified: a data error is an envelope json cannot represent, and a stream
// error is storage it could not obtain.
@(private)
write_encode_error :: proc(err: json.Marshal_Error) -> Write_Error {
	if _, is_data := err.(json.Marshal_Data_Error); is_data { return .Encode }
	return .Allocation
}

// write_normalize_id maps an explicit JSON null id to an absent one. Marshal
// writes a null struct as {}, so only nil reaches the envelope as null.
@(private)
write_normalize_id :: proc(id: JSONRPC_Id) -> JSONRPC_Id {
	if _, is_null := id.(JSONRPC_Null); is_null { return nil }
	return id
}

// Response_Envelope is one result answer. The fields stay in wire order:
// json.marshal writes them as declared.
@(private)
Response_Envelope :: struct($R: typeid) {
	jsonrpc: string `json:"jsonrpc"`,
	id:      JSONRPC_Id `json:"id"`,
	result:  R `json:"result"`,
}

// Error_Envelope is one error answer, in the same field order.
@(private)
Error_Envelope :: struct {
	jsonrpc: string `json:"jsonrpc"`,
	id:      JSONRPC_Id `json:"id"`,
	error:   RPC_Error_Wire `json:"error"`,
}

// Notification_Envelope is one notification, in the same field order.
@(private)
Notification_Envelope :: struct($P: typeid) {
	jsonrpc: string `json:"jsonrpc"`,
	method:  string `json:"method"`,
	params:  P `json:"params"`,
}

// Request_Envelope is one request, in the same field order.
@(private)
Request_Envelope :: struct($P: typeid) {
	jsonrpc: string `json:"jsonrpc"`,
	id:      JSONRPC_Id `json:"id"`,
	method:  string `json:"method"`,
	params:  P `json:"params"`,
}

// write_submit marshals one envelope and queues its frame with a newline. A
// response joins the open batch and latches the writer closed when anything is
// lost, since its peer would wait for the answer forever; a notification or
// request is always its own frame and is only reported.
@(private, require_results)
write_submit :: proc(writer: ^Writer, envelope: $E, response: bool) -> Write_Error {
	state := writer.state
	if state == nil { return .Closed }
	body, marshal_error := json.marshal(envelope, {sort_maps_by_key = true}, allocator = context.temp_allocator)
	if marshal_error != nil {
		err := write_encode_error(marshal_error)
		if response { writer_latch_failure(state) }
		return err
	}
	defer delete(body, context.temp_allocator)
	if frame_error := write_submit_bytes(state, body, response); frame_error != .None {
		if response { writer_latch_failure(state) }
		return frame_error
	}
	return .None
}

// write_submit_bytes queues one marshaled frame with its newline, joining the
// open batch for a response. The queued copy is owned by the writer's
// allocator; a queueing failure releases it.
@(private, require_results)
write_submit_bytes :: proc(state: ^Writer_State, body: []byte, response: bool) -> Write_Error {
	builder, builder_error := strings.builder_make(state.allocator)
	if builder_error != nil { return .Allocation }
	if strings.write_bytes(&builder, body) != len(body) || strings.write_byte(&builder, '\n') != 1 {
		strings.builder_destroy(&builder)
		return .Allocation
	}
	frame := strings.to_string(builder)
	transferred := false
	defer if !transferred { delete(frame, state.allocator) }
	sync.mutex_guard(&state.mutex)
	if state.out.procedure == nil || state.closed || state.closing { return .Closed }
	if response && state.batch_mode {
		if append(&state.batch, frame) != 1 { return .Allocation }
		transferred = true
		return .None
	}
	if append(&state.queue, frame) != 1 { return .Allocation }
	transferred = true
	sync.cond_signal(&state.ready)
	return .None
}

// write_response serializes a result and transfers its complete frame to the
// writer thread. .None means queued, not written.
@(require_results)
write_response :: proc(writer: ^Writer, id: JSONRPC_Id, result: $T) -> Write_Error {
	return write_submit(writer, Response_Envelope(T){jsonrpc = "2.0", id = write_normalize_id(id), result = result}, true)
}

// RPC_Error_Wire is the error document an error answer carries.
RPC_Error_Wire :: struct {
	code:    i64 `json:"code"`,
	message: string `json:"message"`,
}

// write_error serializes an error and transfers its complete frame to the
// writer thread. .None means queued, not written.
@(require_results)
write_error :: proc(writer: ^Writer, id: JSONRPC_Id, code: i64, message: string) -> Write_Error {
	return write_submit(writer, Error_Envelope{jsonrpc = "2.0", id = write_normalize_id(id), error = RPC_Error_Wire{code = code, message = message}}, true)
}

// write_notification serializes a notification and transfers its complete
// frame to the writer thread. Notifications stay their own frame during a
// batch. .None means queued, not written.
@(require_results)
write_notification :: proc(writer: ^Writer, method: string, params: $T) -> Write_Error {
	return write_submit(writer, Notification_Envelope(T){jsonrpc = "2.0", method = method, params = params}, false)
}

// write_request serializes a request and transfers its complete frame to the
// writer thread. .None means queued, not written.
@(require_results)
write_request :: proc(writer: ^Writer, id: JSONRPC_Id, method: string, params: $T) -> Write_Error {
	return write_submit(writer, Request_Envelope(T){jsonrpc = "2.0", id = write_normalize_id(id), method = method, params = params}, false)
}

@(require_results)
writer_begin_batch :: proc(writer: ^Writer) -> Write_Error {
	state := writer.state
	if state == nil { return .Closed }
	sync.mutex_guard(&state.mutex)
	if state.closed || state.closing || state.batch_mode { return .Closed }
	state.batch_mode = true
	return .None
}

// writer_end_batch joins the batched responses into one array frame and queues
// it, leaving notifications as their own frames. A batch holds responses, so
// losing it latches the writer closed like any lost response, and the batch is
// discarded either way.
@(require_results)
writer_end_batch :: proc(writer: ^Writer) -> Write_Error {
	state := writer.state
	if state == nil { return .Closed }
	sync.mutex_guard(&state.mutex)
	if !state.batch_mode { return .Closed }
	if state.closed || state.closing { return writer_batch_fail_locked(state, .Closed) }
	if len(state.batch) == 0 {
		writer_batch_clear_locked(state)
		state.batch_mode = false
		return .None
	}
	builder, builder_error := strings.builder_make(state.allocator)
	if builder_error != nil { return writer_batch_fail_locked(state, .Allocation) }
	built := strings.write_byte(&builder, '[') == 1
	for frame, index in state.batch {
		if !built { break }
		if index > 0 { built = strings.write_byte(&builder, ',') == 1 }
		// Every queued frame ends in a newline, which the array members omit.
		if built { built = strings.write_string(&builder, frame[:len(frame) - 1]) == len(frame) - 1 }
	}
	if built { built = strings.write_string(&builder, "]\n") == len("]\n") }
	if !built {
		strings.builder_destroy(&builder)
		return writer_batch_fail_locked(state, .Allocation)
	}
	batch_frame, clone_error := strings.clone(strings.to_string(builder), state.allocator)
	strings.builder_destroy(&builder)
	if clone_error != nil { return writer_batch_fail_locked(state, .Allocation) }
	if append(&state.queue, batch_frame) != 1 {
		delete(batch_frame, state.allocator)
		return writer_batch_fail_locked(state, .Allocation)
	}
	writer_batch_clear_locked(state)
	state.batch_mode = false
	sync.cond_signal(&state.ready)
	return .None
}

// writer_batch_fail_locked discards the batch, leaves batch mode, and latches
// the writer closed for the responses the peer will never receive.
@(private)
writer_batch_fail_locked :: proc(state: ^Writer_State, err: Write_Error) -> Write_Error {
	writer_batch_clear_locked(state)
	state.batch_mode = false
	writer_latch_failure_locked(state)
	return err
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
		written, stream_error := io.write_string(state.out, frame)
		delete(frame, state.allocator)
		free_all(context.temp_allocator)
		if stream_error != nil || written != frame_length {
			sync.mutex_guard(&state.mutex)
			state.closed = true
			state.failed = true
			state.closing = true
			writer_queue_clear_locked(state)
			writer_batch_clear_locked(state)
			state.batch_mode = false
			state.finished = true
			sync.cond_broadcast(&state.ready)
			return
		}
	}
}
