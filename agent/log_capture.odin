package agent

import "core:crypto/sha2"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"

import "nabla:agent/session"

// Payload capture is opt-in consent to store bytes a record would never carry: the
// exact request a provider was handed, the response stream it answered with, and
// the MCP traffic in between. Metadata records are not affected by it, and capture
// never overrides a disabled log.
//
// A capture consumes what it is handed, synchronously, and keeps only counts and
// digests. It writes a prefix and says so: a stored artifact may be a complete
// observation and a truncated copy at the same time, and the two facts are kept
// apart.

// LOG_CAPTURE_BYTES bounds one artifact's stored payload.
LOG_CAPTURE_BYTES :: 8 * 1024 * 1024

// LOG_CAPTURE_BYTES_PER_RUN and LOG_CAPTURES_PER_RUN bound what one run's captures
// may occupy together. Admission reserves both under the writer mutex, so a quota
// is never exceeded by a capture that is already open.
LOG_CAPTURE_BYTES_PER_RUN :: 64 * 1024 * 1024
LOG_CAPTURES_PER_RUN :: 128

LOG_CAPTURES_DIRECTORY :: "captures"
LOG_CAPTURE_ARTIFACT_DIGITS :: 6
LOG_CAPTURE_PART_SUFFIX :: ".part"
LOG_CAPTURE_BODY_SUFFIX :: ".body"
LOG_CAPTURE_SIDECAR_SUFFIX :: ".body.json"

// LOG_CAPTURE_SIDECAR_BYTES bounds the metadata sidecar, which is fixed-shape:
// counts, digests, and the correlation the capture copied at begin.
LOG_CAPTURE_SIDECAR_BYTES :: 2048

// Capture_Mode is the process's payload policy. Off is the zero value, so a zero
// Log_Options captures nothing.
Capture_Mode :: enum {
	Off,
	Payloads,
}

// Capture_Kind names what an artifact holds. Invalid is the zero value, so a zero
// Capture is never written and never mistaken for a real one.
Capture_Kind :: enum {
	Invalid,
	Provider_Request,
	Provider_Response,
	MCP_Request,
	MCP_Response,
	MCP_Stderr,
}

// Capture is one artifact being written: an open prefix, two running digests, and
// the correlation its metadata needs. It is owned by one operation, which finishes
// or aborts it exactly once.
//
// It borrows its sink for quota and for the record about itself, and it copies the
// correlation because its metadata may be written after the state it describes has
// moved on. Nothing else is retained: bytes are consumed as they arrive.
Capture :: struct {
	sink:              ^Log, // borrowed; outlives the capture
	correlation:       Log_Correlation, // copied, owned
	kind:              Capture_Kind,
	artifact:          u64,
	file:              ^os.File,
	observed_bytes:    u64,
	stored_bytes:      u64,
	observed:          sha2.Context_256,
	stored:            sha2.Context_256,
	observed_complete: bool,
	failed:            bool,
	allocator:         mem.Allocator,
	// scratch is this capture's sidecar buffer, so writing the metadata needs no
	// allocation beyond the temporary path it is renamed from.
	scratch:           [LOG_CAPTURE_SIDECAR_BYTES]u8,
}

// Capture_Summary is what one finished capture observed and stored, with both
// digests rendered. It owns nothing.
Capture_Summary :: struct {
	kind:              Capture_Kind,
	artifact:          u64,
	observed_bytes:    u64,
	stored_bytes:      u64,
	observed_sha256:   [sha2.DIGEST_SIZE_256 * 2]u8,
	stored_sha256:     [sha2.DIGEST_SIZE_256 * 2]u8,
	observed_complete: bool,
	truncated:         bool,
	failed:            bool,
}

// log_capture_open admits one artifact and opens its payload file. It reports false
// when capture is off, when the run's quota is exhausted, or when the file could
// not be created; the caller then simply does not capture, because a capture must
// never fail the work it observes.
log_capture_open :: proc(sink: ^Log, correlation: Log_Correlation, kind: Capture_Kind) -> (capture: Capture, opened: bool) {
	if sink == nil || !sink.open || kind == .Invalid { return {}, false }
	if sink.capture_mode != .Payloads { return {}, false }

	sync.mutex_lock(&sink.mutex)
	admitted := false
	artifact: u64
	switch {
	case sink.capture_count >= LOG_CAPTURES_PER_RUN:
	case sink.capture_bytes + LOG_CAPTURE_BYTES > LOG_CAPTURE_BYTES_PER_RUN:
	case:
		sink.capture_count += 1
		sink.capture_bytes += LOG_CAPTURE_BYTES
		sink.capture_sequence += 1
		artifact = sink.capture_sequence
		admitted = true
	}
	if !admitted { sink.capture_denied += 1 }
	sync.mutex_unlock(&sink.mutex)
	if !admitted { return {}, false }

	capture = Capture {
		sink        = sink,
		correlation = log_correlation_copy(correlation, sink.allocator),
		kind        = kind,
		artifact    = artifact,
		allocator   = sink.allocator,
	}
	sha2.init_256(&capture.observed)
	sha2.init_256(&capture.stored)

	directory, directory_okay := log_capture_directory(sink, capture.allocator)
	if !directory_okay {
		capture.failed = true
		return capture, true
	}
	defer delete(directory, capture.allocator)
	if make_err := os.make_directory_all(directory, LOG_DIRECTORY_PERMISSIONS); make_err != nil && make_err != .Exist {
		capture.failed = true
		return capture, true
	}

	path, path_okay := log_capture_payload_path(&capture, true, context.temp_allocator)
	if !path_okay {
		capture.failed = true
		return capture, true
	}
	file, open_err := os.open(path, {.Write, .Create, .Excl}, LOG_FILE_PERMISSIONS)
	if open_err != nil {
		capture.failed = true
		return capture, true
	}
	capture.file = file
	return capture, true
}

// log_capture_write consumes one chunk: every observed byte is counted and hashed,
// and the first bytes within the allowance are stored. Once the allowance is spent
// the capture keeps observing, so a digest always describes what was observed
// rather than only what was kept.
log_capture_write :: proc(capture: ^Capture, chunk: []u8) {
	if capture == nil || capture.failed || len(chunk) == 0 { return }
	sha2.update(&capture.observed, chunk)
	capture.observed_bytes += u64(len(chunk))

	space := i64(LOG_CAPTURE_BYTES) - i64(capture.stored_bytes)
	if space <= 0 { return }
	stored := chunk
	if i64(len(stored)) > space { stored = stored[:space] }
	if capture.file != nil {
		if write_err := log_write_all(capture.file, stored); write_err != nil {
			capture.failed = true
			return
		}
	}
	sha2.update(&capture.stored, stored)
	capture.stored_bytes += u64(len(stored))
}

// log_capture_finish closes the payload, promotes the prefix, and writes the
// metadata sidecar. It releases the artifact's quota reservation and records what
// became of the capture. Calling it on an empty capture is safe and does nothing.
log_capture_finish :: proc(capture: ^Capture, complete: bool) -> (summary: Capture_Summary) {
	if capture == nil || capture.kind == .Invalid { return {} }
	if capture.file != nil {
		if close_err := os.close(capture.file); close_err != nil { capture.failed = true }
		capture.file = nil
	}
	// A capture that never observed anything has nothing to say and no artifact to
	// leave behind, so the whole thing is withdrawn.
	if capture.observed_bytes == 0 {
		log_capture_discard(capture)
		return {}
	}
	// complete says whether the observer saw the end of what it was watching: a
	// stream that was cut short is still worth keeping, and the artifact says so.
	capture.observed_complete = complete
	part, part_okay := log_capture_payload_path(capture, true, context.temp_allocator)
	body, body_okay := log_capture_payload_path(capture, false, context.temp_allocator)
	if !part_okay || !body_okay || capture.failed {
		capture.failed = true
	} else if rename_err := os.rename(part, body); rename_err != nil {
		capture.failed = true
	}

	summary = log_capture_summary(capture)
	if !capture.failed { capture.failed = !log_capture_sidecar_write(capture, &summary) }
	summary.failed = capture.failed
	log_capture_settle(capture, &summary)
	log_capture_record(capture, summary)
	allocator := capture.allocator
	log_correlation_destroy(&capture.correlation, allocator)
	capture^ = {}
	return summary
}

// log_capture_abort withdraws an artifact that will not be finished. It removes the
// partial payload, because a prefix with no metadata is not evidence of anything.
log_capture_abort :: proc(capture: ^Capture) {
	if capture == nil || capture.kind == .Invalid { return }
	if capture.file != nil {
		if close_err := os.close(capture.file); close_err != nil { capture.failed = true }
		capture.file = nil
	}
	log_capture_discard(capture)
}

// log_capture_discard removes the partial payload, settles the quota as if nothing
// had been stored, and leaves the capture empty so it can never be settled twice.
@(private)
log_capture_discard :: proc(capture: ^Capture) {
	if path, okay := log_capture_payload_path(capture, true, context.temp_allocator); okay {
		_ = os.remove(path)
	}
	summary: Capture_Summary
	log_capture_settle(capture, &summary)
	allocator := capture.allocator
	log_correlation_destroy(&capture.correlation, allocator)
	capture^ = {}
}

// log_capture_settle replaces the reserved allowance with what was actually stored
// and gives the artifact slot back, so a run that captures little does not spend
// its whole budget on reservations.
@(private)
log_capture_settle :: proc(capture: ^Capture, summary: ^Capture_Summary) {
	sink := capture.sink
	if sink == nil { return }
	sync.mutex_lock(&sink.mutex)
	sink.capture_bytes -= LOG_CAPTURE_BYTES - i64(summary.stored_bytes)
	if sink.capture_bytes < 0 { sink.capture_bytes = 0 }
	if sink.capture_count > 0 { sink.capture_count -= 1 }
	sync.mutex_unlock(&sink.mutex)
}

// log_capture_summary renders what a capture observed and stored.
@(private)
log_capture_summary :: proc(capture: ^Capture) -> Capture_Summary {
	summary := Capture_Summary {
		kind              = capture.kind,
		artifact          = capture.artifact,
		observed_bytes    = capture.observed_bytes,
		stored_bytes      = capture.stored_bytes,
		observed_complete = capture.observed_complete,
		truncated         = capture.stored_bytes < capture.observed_bytes,
		failed            = capture.failed,
	}
	observed: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&capture.observed, observed[:])
	stored: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&capture.stored, stored[:])
	log_capture_hex(summary.observed_sha256[:], observed[:])
	log_capture_hex(summary.stored_sha256[:], stored[:])
	return summary
}

// log_capture_record writes the record that names the artifact. It uses the
// correlation captured at begin, because the operation it describes may already be
// retired by the time the bytes stop arriving, and it applies the sink's own
// threshold like any other record.
@(private)
log_capture_record :: proc(capture: ^Capture, summary: Capture_Summary) {
	sink := capture.sink
	if sink == nil { return }
	level := log.Level.Info
	event := "capture.finished"
	if summary.failed {
		level = .Warning
		event = "capture.failed"
	}
	if level < sink.lowest { return }
	fields := [7]Log_Field {
		{key = "artifact_id", value = summary.artifact},
		{key = "artifact_kind", value = log_capture_kind_name(summary.kind)},
		{key = "observed_bytes", value = summary.observed_bytes},
		{key = "stored_bytes", value = summary.stored_bytes},
		{key = "observed_complete", value = summary.observed_complete},
		{key = "truncated", value = summary.truncated},
		{key = "failed", value = summary.failed},
	}
	record := Log_Record {
		level    = level,
		category = .Diagnostics,
		event    = event,
		fields   = fields[:],
	}
	log_write(sink, capture.correlation, record)
}

// log_capture_sidecar_write writes the metadata through a temporary file and a
// rename, so a reader never sees a half-written sidecar. A sidecar without its
// payload, or a payload without its sidecar, means the process died in between;
// neither is presented as a completed capture.
@(private)
log_capture_sidecar_write :: proc(capture: ^Capture, summary: ^Capture_Summary) -> bool {
	path, okay := log_capture_sidecar_path(capture, context.temp_allocator)
	if !okay { return false }
	temporary := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	file, open_err := os.open(temporary, {.Write, .Create, .Trunc, .Excl}, LOG_FILE_PERMISSIONS)
	if open_err != nil { return false }

	line := Log_Line {
		buffer = capture.scratch[:],
	}
	log_capture_sidecar_json(&line, capture, summary)
	if line.full || line.length == 0 {
		os.close(file)
		_ = os.remove(temporary)
		return false
	}
	written_okay := true
	if write_err := log_write_all(file, line.buffer[:line.length]); write_err != nil { written_okay = false }
	if close_err := os.close(file); close_err != nil { written_okay = false }
	if !written_okay {
		_ = os.remove(temporary)
		return false
	}
	if rename_err := os.rename(temporary, path); rename_err != nil {
		_ = os.remove(temporary)
		return false
	}
	return true
}

// log_capture_sidecar_json writes the sidecar's object. The keys are the reader's,
// not the record's: a sidecar is metadata about one artifact rather than an event.
@(private)
log_capture_sidecar_json :: proc(line: ^Log_Line, capture: ^Capture, summary: ^Capture_Summary) {
	correlation := &capture.correlation
	log_line_byte(line, '{')
	log_line_bytes(line, `"version":`)
	log_line_uint(line, u64(LOG_VERSION))
	log_line_bytes(line, `,"artifact_id":`)
	log_line_uint(line, summary.artifact)
	log_line_bytes(line, `,"kind":`)
	log_line_json_string(line, log_capture_kind_name(summary.kind))
	log_line_bytes(line, `,"observed_bytes":`)
	log_line_uint(line, summary.observed_bytes)
	log_line_bytes(line, `,"stored_bytes":`)
	log_line_uint(line, summary.stored_bytes)
	log_line_bytes(line, `,"observed_sha256":`)
	log_line_json_string(line, string(summary.observed_sha256[:]))
	log_line_bytes(line, `,"stored_sha256":`)
	log_line_json_string(line, string(summary.stored_sha256[:]))
	log_line_bytes(line, `,"observed_complete":`)
	log_line_bytes(line, summary.observed_complete ? "true" : "false")
	log_line_bytes(line, `,"truncated":`)
	log_line_bytes(line, summary.truncated ? "true" : "false")
	log_line_bytes(line, `,"failed":`)
	log_line_bytes(line, summary.failed ? "true" : "false")
	if len(correlation.session_id) > 0 {
		log_line_bytes(line, `,"session_id":`)
		log_line_json_string(line, string(correlation.session_id))
	}
	if i64(correlation.turn_no) != 0 {
		log_line_bytes(line, `,"turn_no":`)
		log_line_int(line, i64(correlation.turn_no))
	}
	if i64(correlation.request_no) != 0 {
		log_line_bytes(line, `,"request_no":`)
		log_line_int(line, i64(correlation.request_no))
	}
	if correlation.attempt != 0 {
		log_line_bytes(line, `,"attempt":`)
		log_line_int(line, i64(correlation.attempt))
	}
	if correlation.operation_id != 0 {
		log_line_bytes(line, `,"operation_id":`)
		log_line_uint(line, correlation.operation_id)
	}
	if correlation.call_id != "" {
		log_line_bytes(line, `,"call_id":`)
		log_line_json_string(line, correlation.call_id)
	}
	log_line_byte(line, '}')
	log_line_byte(line, '\n')
}

// log_capture_directory is where one run's artifacts live. The result is owned by
// allocator.
@(private)
log_capture_directory :: proc(sink: ^Log, allocator: mem.Allocator) -> (string, bool) {
	return log_path_join(sink.directory, LOG_CAPTURES_DIRECTORY, allocator)
}

// log_capture_basename is the generated prefix of one artifact: its run-local
// number and its kind. No model, tool, URL, or session text appears in a path.
@(private)
log_capture_basename :: proc(capture: ^Capture, buffer: []u8) -> string {
	number := fmt.bprintf(buffer, "%0*d", LOG_CAPTURE_ARTIFACT_DIGITS, capture.artifact)
	return strings.concatenate({number, "-", log_capture_kind_name(capture.kind)}, context.temp_allocator)
}

@(private)
log_capture_payload_path :: proc(capture: ^Capture, partial: bool, allocator: mem.Allocator) -> (string, bool) {
	directory, okay := log_capture_directory(capture.sink, allocator)
	if !okay { return "", false }
	basename_buffer: [64]u8
	basename := log_capture_basename(capture, basename_buffer[:])
	suffix := LOG_CAPTURE_BODY_SUFFIX
	if partial { suffix = LOG_CAPTURE_PART_SUFFIX }
	name := strings.concatenate({basename, suffix}, allocator)
	path, join_okay := log_path_join(directory, name, allocator)
	delete(name, allocator)
	delete(directory, allocator)
	return path, join_okay
}

@(private)
log_capture_sidecar_path :: proc(capture: ^Capture, allocator: mem.Allocator) -> (string, bool) {
	directory, okay := log_capture_directory(capture.sink, allocator)
	if !okay { return "", false }
	basename_buffer: [64]u8
	basename := log_capture_basename(capture, basename_buffer[:])
	name := strings.concatenate({basename, LOG_CAPTURE_SIDECAR_SUFFIX}, allocator)
	path, join_okay := log_path_join(directory, name, allocator)
	delete(name, allocator)
	delete(directory, allocator)
	return path, join_okay
}

@(private)
log_capture_kind_name :: proc(kind: Capture_Kind) -> string {
	switch kind {
	case .Invalid:
		return "invalid"
	case .Provider_Request:
		return "request"
	case .Provider_Response:
		return "response"
	case .MCP_Request:
		return "mcp-request"
	case .MCP_Response:
		return "mcp-response"
	case .MCP_Stderr:
		return "mcp-stderr"
	}
	return "invalid"
}

@(private)
log_capture_hex :: proc(destination: []u8, digest: []u8) {
	for byte, index in digest {
		if index * 2 + 1 >= len(destination) { break }
		destination[index * 2] = log_hex_digit(byte >> 4)
		destination[index * 2 + 1] = log_hex_digit(byte & 0x0F)
	}
}

// log_correlation_copy duplicates the borrowed identifiers so a capture can hold
// them past the scope that produced them.
@(private)
log_correlation_copy :: proc(correlation: Log_Correlation, allocator: mem.Allocator) -> Log_Correlation {
	copied := correlation
	if correlation.session_id != "" {
		copied.session_id = session.Session_Id(strings.clone(string(correlation.session_id), allocator))
	}
	if correlation.call_id != "" { copied.call_id = strings.clone(correlation.call_id, allocator) }
	return copied
}

@(private)
log_correlation_destroy :: proc(correlation: ^Log_Correlation, allocator: mem.Allocator) {
	delete(string(correlation.session_id), allocator)
	delete(correlation.call_id, allocator)
	correlation^ = {}
}
