package acp

import "core:encoding/json"
import "core:io"
import "core:mem"
import "core:strings"
import "core:sync"

// Writer writes framed JSON-RPC messages to one stream. It owns the framing (one
// message per line, the same shape the decoder reads) and the serialization: a turn
// publishes session updates from the thread that runs it while another thread answers
// requests, so a frame a client reads must be whole whatever two threads do at once.
//
// A write error latches. A client that stopped reading will not read the next frame
// either, so there is nothing to retry and the caller stops the run.
Writer :: struct {
	out:        io.Writer,
	allocator:  mem.Allocator,
	mutex:      sync.Mutex,
	builder:    strings.Builder,
	failed:     bool, // atomic; written by whoever writes, read by whoever asks
	batch_mode: bool,
	batch:      [dynamic]string,
}

writer_init :: proc(out: io.Writer, allocator := context.allocator) -> (Writer, mem.Allocator_Error) {
	builder, err := strings.builder_make(allocator)
	if err != nil { return {}, err }
	result := Writer {
		out       = out,
		allocator = allocator,
		builder   = builder,
	}
	result.batch.allocator = allocator
	return result, nil
}

writer_destroy :: proc(w: ^Writer) {
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	writer_batch_clear(w)
	strings.builder_destroy(&w.builder)
	w.out = {}
}

writer_failed :: proc(w: ^Writer) -> bool { return sync.atomic_load(&w.failed) }

// writer_write_response answers one request with a result payload. The batch check
// and the write happen under one lock hold, so a response can neither slip into a
// batch that just ended nor miss one that just began.
writer_write_response :: proc(w: ^Writer, id: Jsonrpc_Id, result: $T) -> bool {
	body, marshal_err := json.marshal(result, allocator = context.temp_allocator)
	if marshal_err != nil { return false }
	defer delete(body, context.temp_allocator)
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	if w.batch_mode { return writer_batch_frame(w, id, `"result":`, body) }
	return writer_frame(w, id, `"result":`, body)
}

// Rpc_Error_Wire is the error document an error answer carries.
Rpc_Error_Wire :: struct {
	code:    i64 `json:"code"`,
	message: string `json:"message"`,
}

// writer_write_error answers one request with a failure.
writer_write_error :: proc(w: ^Writer, id: Jsonrpc_Id, code: i64, message: string) -> bool {
	body, marshal_err := json.marshal(Rpc_Error_Wire{code = code, message = message}, allocator = context.temp_allocator)
	if marshal_err != nil { return false }
	defer delete(body, context.temp_allocator)
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	if w.batch_mode { return writer_batch_frame(w, id, `"error":`, body) }
	return writer_frame(w, id, `"error":`, body)
}

// writer_write_notification sends one notification, which no one answers. It is
// always its own frame, even while a batch is being collected: a batch answer may
// only carry responses, so a notification that waited would either be dropped or
// corrupt the batch.
writer_write_notification :: proc(w: ^Writer, method: string, params: $T) -> bool {
	body, marshal_err := json.marshal(params, allocator = context.temp_allocator)
	if marshal_err != nil { return false }
	defer delete(body, context.temp_allocator)
	if w.out.procedure == nil { return false }
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	b := &w.builder
	strings.builder_reset(b)
	if !writer_builder_string(b, `{"jsonrpc":"2.0","method":`) ||
	   !writer_write_quoted(b, method) ||
	   !writer_builder_string(b, `,"params":`) ||
	   !writer_builder_bytes(b, body) ||
	   !writer_builder_string(b, "}\n") {
		sync.atomic_store(&w.failed, true)
		return false
	}
	return writer_flush(w, b)
}

// writer_frame writes one response frame. The caller holds the mutex.
@(private)
writer_frame :: proc(w: ^Writer, id: Jsonrpc_Id, key: string, body: []byte) -> bool {
	if w.out.procedure == nil { return false }
	b := &w.builder
	strings.builder_reset(b)
	if !writer_builder_string(b, `{"jsonrpc":"2.0","id":`) ||
	   !writer_write_id(b, id) ||
	   !writer_builder_byte(b, ',') ||
	   !writer_builder_string(b, key) ||
	   !writer_builder_bytes(b, body) ||
	   !writer_builder_string(b, "}\n") {
		sync.atomic_store(&w.failed, true)
		return false
	}
	return writer_flush(w, b)
}

writer_begin_batch :: proc(w: ^Writer) -> bool {
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	if w.batch_mode { return false }
	w.batch_mode = true
	return true
}

writer_end_batch :: proc(w: ^Writer) -> bool {
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	if !w.batch_mode { return false }
	if len(w.batch) == 0 {
		writer_batch_clear(w)
		w.batch_mode = false
		return true
	}
	b := &w.builder
	strings.builder_reset(b)
	if strings.write_byte(b, '[') != 1 {
		writer_batch_clear(w)
		w.batch_mode = false
		return false
	}
	for frame, index in w.batch {
		if index > 0 && strings.write_byte(b, ',') != 1 {
			writer_batch_clear(w)
			w.batch_mode = false
			return false
		}
		if !writer_builder_string(b, frame) {
			writer_batch_clear(w)
			w.batch_mode = false
			return false
		}
	}
	if strings.write_string(b, "]\n") != 2 {
		writer_batch_clear(w)
		w.batch_mode = false
		return false
	}
	ok := writer_flush(w, b)
	writer_batch_clear(w)
	w.batch_mode = false
	return ok
}

// writer_batch_frame queues one response inside the open batch. The caller holds the
// mutex and has checked the batch mode.
@(private)
writer_batch_frame :: proc(w: ^Writer, id: Jsonrpc_Id, key: string, body: []byte) -> bool {
	frame_builder, builder_err := strings.builder_make(w.allocator)
	if builder_err != nil { return false }
	defer strings.builder_destroy(&frame_builder)
	if !writer_builder_string(&frame_builder, `{"jsonrpc":"2.0","id":`) ||
	   !writer_write_id(&frame_builder, id) ||
	   !writer_builder_byte(&frame_builder, ',') ||
	   !writer_builder_string(&frame_builder, key) ||
	   !writer_builder_bytes(&frame_builder, body) ||
	   !writer_builder_string(&frame_builder, "}") {
		return false
	}
	frame := strings.to_string(frame_builder)
	owned, clone_err := strings.clone(frame, w.allocator)
	if clone_err != nil { return false }
	appended := append(&w.batch, owned)
	if appended != 1 {
		delete(owned, w.allocator)
		return false
	}
	return true
}

writer_batch_clear :: proc(w: ^Writer) {
	for frame in w.batch { delete(frame, w.allocator) }
	delete(w.batch)
	w.batch = nil
	w.batch.allocator = w.allocator
}

// builder is the writer's own scratch and no two frames can interleave.
@(private)
writer_flush :: proc(w: ^Writer, b: ^strings.Builder) -> bool {
	frame := strings.to_string(b^)
	n, write_err := io.write_string(w.out, frame)
	if write_err != nil || n != len(frame) {
		sync.atomic_store(&w.failed, true)
		return false
	}
	return true
}

@(private)
writer_builder_string :: proc(b: ^strings.Builder, value: string) -> bool {
	return strings.write_string(b, value) == len(value)
}

@(private)
writer_builder_bytes :: proc(b: ^strings.Builder, value: []byte) -> bool {
	return strings.write_bytes(b, value) == len(value)
}

@(private)
writer_builder_byte :: proc(b: ^strings.Builder, value: byte) -> bool {
	return strings.write_byte(b, value) == 1
}

@(private)
writer_write_id :: proc(b: ^strings.Builder, id: Jsonrpc_Id) -> bool {
	switch value in id {
	case i64, f64:
		body, err := json.marshal(value, allocator = context.temp_allocator)
		if err != nil { return false }
		defer delete(body, context.temp_allocator)
		return writer_builder_bytes(b, body)
	case string:
		return writer_write_quoted(b, value)
	case Jsonrpc_Null:
		return writer_builder_string(b, "null")
	case:
		// An id the envelope parser would have refused cannot name a request, so a
		// response to it is written as the JSON null a client can still match.
		return writer_builder_string(b, "null")
	}
}

// writer_write_quoted writes one JSON string. It is the only place outbound text is
// escaped, so every string the writer emits is valid whatever it contains.
@(private)
writer_write_quoted :: proc(b: ^strings.Builder, value: string) -> bool {
	if !writer_builder_byte(b, '"') { return false }
	for i := 0; i < len(value); i += 1 {
		c := value[i]
		switch c {
		case '"':
			if !writer_builder_string(b, `\"`) { return false }
		case '\\':
			if !writer_builder_string(b, `\\`) { return false }
		case '\n':
			if !writer_builder_string(b, `\n`) { return false }
		case '\r':
			if !writer_builder_string(b, `\r`) { return false }
		case '\t':
			if !writer_builder_string(b, `\t`) { return false }
		case '\b':
			if !writer_builder_string(b, `\b`) { return false }
		case '\f':
			if !writer_builder_string(b, `\f`) { return false }
		case:
			if c < 0x20 {
				if !writer_builder_string(b, `\u00`) ||
				   !writer_builder_byte(b, writer_hex_digit(c >> 4)) ||
				   !writer_builder_byte(b, writer_hex_digit(c & 0x0F)) { return false }
			} else if !writer_builder_byte(b, c) {
				return false
			}
		}
	}
	return writer_builder_byte(b, '"')
}

@(private)
writer_hex_digit :: proc(value: byte) -> byte {
	if value < 10 { return '0' + value }
	return 'a' + (value - 10)
}
