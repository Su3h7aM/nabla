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
	out:     io.Writer,
	mutex:   sync.Mutex,
	builder: strings.Builder,
	failed:  bool, // atomic; written by whoever writes, read by whoever asks
}

writer_init :: proc(out: io.Writer, allocator := context.allocator) -> (Writer, mem.Allocator_Error) {
	builder, err := strings.builder_make(allocator)
	if err != nil { return {}, err }
	return Writer{out = out, builder = builder}, nil
}

writer_destroy :: proc(w: ^Writer) {
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	strings.builder_destroy(&w.builder)
	w.out = {}
}

writer_failed :: proc(w: ^Writer) -> bool { return sync.atomic_load(&w.failed) }

// writer_write_response answers one request with a result payload.
writer_write_response :: proc(w: ^Writer, id: Jsonrpc_Id, result: $T) -> bool {
	body, marshal_err := json.marshal(result, allocator = context.temp_allocator)
	if marshal_err != nil { return false }
	defer delete(body, context.temp_allocator)
	return writer_frame(w, id, `"result":`, body)
}

// Rpc_Error_Wire is the error object of a failed request.
Rpc_Error_Wire :: struct {
	code:    i64 `json:"code"`,
	message: string `json:"message"`,
}

// writer_write_error answers one request with a failure.
writer_write_error :: proc(w: ^Writer, id: Jsonrpc_Id, code: i64, message: string) -> bool {
	body, marshal_err := json.marshal(Rpc_Error_Wire{code = code, message = message}, allocator = context.temp_allocator)
	if marshal_err != nil { return false }
	defer delete(body, context.temp_allocator)
	return writer_frame(w, id, `"error":`, body)
}

// writer_write_notification sends one notification, which no one answers.
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

@(private)
writer_frame :: proc(w: ^Writer, id: Jsonrpc_Id, key: string, body: []byte) -> bool {
	if w.out.procedure == nil { return false }
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
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

// writer_flush writes the frame the builder holds. The caller holds the lock, so the
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
