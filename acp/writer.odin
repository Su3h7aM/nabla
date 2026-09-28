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

writer_destroy :: proc(writer: ^Writer) {
	sync.mutex_lock(&writer.mutex)
	defer sync.mutex_unlock(&writer.mutex)
	writer_batch_clear(writer)
	strings.builder_destroy(&writer.builder)
	writer.out = {}
}

writer_failed :: proc(writer: ^Writer) -> bool { return sync.atomic_load(&writer.failed) }

// writer_write_response answers one request with a result payload. The batch check
// and the write happen under one lock hold, so a response can neither slip into a
// batch that just ended nor miss one that just began.
writer_write_response :: proc(writer: ^Writer, id: Jsonrpc_Id, result: $T) -> bool {
	body, marshal_err := json.marshal(result, allocator = context.temp_allocator)
	if marshal_err != nil { return false }
	defer delete(body, context.temp_allocator)
	sync.mutex_lock(&writer.mutex)
	defer sync.mutex_unlock(&writer.mutex)
	if writer.batch_mode { return writer_batch_frame(writer, id, `"result":`, body) }
	return writer_frame(writer, id, `"result":`, body)
}

// Rpc_Error_Wire is the error document an error answer carries.
Rpc_Error_Wire :: struct {
	code:    i64 `json:"code"`,
	message: string `json:"message"`,
}

// writer_write_error answers one request with a failure.
writer_write_error :: proc(writer: ^Writer, id: Jsonrpc_Id, code: i64, message: string) -> bool {
	body, marshal_err := json.marshal(Rpc_Error_Wire{code = code, message = message}, allocator = context.temp_allocator)
	if marshal_err != nil { return false }
	defer delete(body, context.temp_allocator)
	sync.mutex_lock(&writer.mutex)
	defer sync.mutex_unlock(&writer.mutex)
	if writer.batch_mode { return writer_batch_frame(writer, id, `"error":`, body) }
	return writer_frame(writer, id, `"error":`, body)
}

// writer_write_notification sends one notification, which no one answers. It is
// always its own frame, even while a batch is being collected: a batch answer may
// only carry responses, so a notification that waited would either be dropped or
// corrupt the batch.
writer_write_notification :: proc(writer: ^Writer, method: string, params: $T) -> bool {
	body, marshal_err := json.marshal(params, allocator = context.temp_allocator)
	if marshal_err != nil { return false }
	defer delete(body, context.temp_allocator)
	if writer.out.procedure == nil { return false }
	sync.mutex_lock(&writer.mutex)
	defer sync.mutex_unlock(&writer.mutex)
	builder := &writer.builder
	strings.builder_reset(builder)
	if !writer_builder_string(builder, `{"jsonrpc":"2.0","method":`) ||
	   !writer_write_quoted(builder, method) ||
	   !writer_builder_string(builder, `,"params":`) ||
	   !writer_builder_bytes(builder, body) ||
	   !writer_builder_string(builder, "}\n") {
		sync.atomic_store(&writer.failed, true)
		return false
	}
	return writer_flush(writer, builder)
}

// writer_write_request sends one request as its own frame, which the agent answers by id.
writer_write_request :: proc(writer: ^Writer, id: i64, method: string, params: $T) -> bool {
	body, marshal_err := json.marshal(params, allocator = context.temp_allocator)
	if marshal_err != nil { return false }
	defer delete(body, context.temp_allocator)
	if writer.out.procedure == nil { return false }
	sync.mutex_lock(&writer.mutex)
	defer sync.mutex_unlock(&writer.mutex)
	builder := &writer.builder
	strings.builder_reset(builder)
	if !writer_builder_string(builder, `{"jsonrpc":"2.0","id":`) ||
	   !writer_write_id(builder, Jsonrpc_Id(id)) ||
	   !writer_builder_string(builder, `,"method":`) ||
	   !writer_write_quoted(builder, method) ||
	   !writer_builder_string(builder, `,"params":`) ||
	   !writer_builder_bytes(builder, body) ||
	   !writer_builder_string(builder, "}\n") {
		sync.atomic_store(&writer.failed, true)
		return false
	}
	return writer_flush(writer, builder)
}

// writer_frame writes one response frame. The caller holds the mutex.
@(private)
writer_frame :: proc(writer: ^Writer, id: Jsonrpc_Id, key: string, body: []byte) -> bool {
	if writer.out.procedure == nil { return false }
	builder := &writer.builder
	strings.builder_reset(builder)
	if !writer_builder_string(builder, `{"jsonrpc":"2.0","id":`) ||
	   !writer_write_id(builder, id) ||
	   !writer_builder_byte(builder, ',') ||
	   !writer_builder_string(builder, key) ||
	   !writer_builder_bytes(builder, body) ||
	   !writer_builder_string(builder, "}\n") {
		sync.atomic_store(&writer.failed, true)
		return false
	}
	return writer_flush(writer, builder)
}

writer_begin_batch :: proc(writer: ^Writer) -> bool {
	sync.mutex_lock(&writer.mutex)
	defer sync.mutex_unlock(&writer.mutex)
	if writer.batch_mode { return false }
	writer.batch_mode = true
	return true
}

writer_end_batch :: proc(writer: ^Writer) -> bool {
	sync.mutex_lock(&writer.mutex)
	defer sync.mutex_unlock(&writer.mutex)
	if !writer.batch_mode { return false }
	if len(writer.batch) == 0 {
		writer_batch_clear(writer)
		writer.batch_mode = false
		return true
	}
	builder := &writer.builder
	strings.builder_reset(builder)
	if strings.write_byte(builder, '[') != 1 {
		writer_batch_clear(writer)
		writer.batch_mode = false
		return false
	}
	for frame, index in writer.batch {
		if index > 0 && strings.write_byte(builder, ',') != 1 {
			writer_batch_clear(writer)
			writer.batch_mode = false
			return false
		}
		if !writer_builder_string(builder, frame) {
			writer_batch_clear(writer)
			writer.batch_mode = false
			return false
		}
	}
	if strings.write_string(builder, "]\n") != 2 {
		writer_batch_clear(writer)
		writer.batch_mode = false
		return false
	}
	ok := writer_flush(writer, builder)
	writer_batch_clear(writer)
	writer.batch_mode = false
	return ok
}

// writer_batch_frame queues one response inside the open batch. The caller holds the
// mutex and has checked the batch mode.
@(private)
writer_batch_frame :: proc(writer: ^Writer, id: Jsonrpc_Id, key: string, body: []byte) -> bool {
	frame_builder, builder_err := strings.builder_make(writer.allocator)
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
	owned, clone_err := strings.clone(frame, writer.allocator)
	if clone_err != nil { return false }
	appended := append(&writer.batch, owned)
	if appended != 1 {
		delete(owned, writer.allocator)
		return false
	}
	return true
}

writer_batch_clear :: proc(writer: ^Writer) {
	for frame in writer.batch { delete(frame, writer.allocator) }
	delete(writer.batch)
	writer.batch = nil
	writer.batch.allocator = writer.allocator
}

@(private)
writer_flush :: proc(writer: ^Writer, builder: ^strings.Builder) -> bool {
	frame := strings.to_string(builder^)
	written, write_err := io.write_string(writer.out, frame)
	if write_err != nil || written != len(frame) {
		sync.atomic_store(&writer.failed, true)
		return false
	}
	return true
}

@(private)
writer_builder_string :: proc(builder: ^strings.Builder, value: string) -> bool {
	return strings.write_string(builder, value) == len(value)
}

@(private)
writer_builder_bytes :: proc(builder: ^strings.Builder, value: []byte) -> bool {
	return strings.write_bytes(builder, value) == len(value)
}

@(private)
writer_builder_byte :: proc(builder: ^strings.Builder, value: byte) -> bool {
	return strings.write_byte(builder, value) == 1
}

@(private)
writer_write_id :: proc(builder: ^strings.Builder, id: Jsonrpc_Id) -> bool {
	switch value in id {
	case i64, f64:
		body, err := json.marshal(value, allocator = context.temp_allocator)
		if err != nil { return false }
		defer delete(body, context.temp_allocator)
		return writer_builder_bytes(builder, body)
	case string:
		return writer_write_quoted(builder, value)
	case Jsonrpc_Null:
		return writer_builder_string(builder, "null")
	case:
		// An id the envelope parser would have refused cannot name a request, so a
		// response to it is written as the JSON null a client can still match.
		return writer_builder_string(builder, "null")
	}
}

// writer_write_quoted writes one JSON string. It is the only place outbound text is
// escaped, so every string the writer emits is valid whatever it contains.
@(private)
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
