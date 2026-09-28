package main

import "core:crypto/sha2"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "nabla:agent"
import "nabla:agent/journal"

EXPORT_MANIFEST_NAME :: "manifest.json"
EXPORT_SESSION_NAME :: "session.jsonl"
EXPORT_REQUEST_NAME :: "request.json"
EXPORT_BYTES :: 32 * 1024 * 1024
EXPORT_PAGE_RECORDS :: 256
EXPORT_DIRECTORY_PERMISSIONS :: os.Permissions{.Read_User, .Write_User, .Execute_User}
EXPORT_FILE_PERMISSIONS :: os.Permissions{.Read_User, .Write_User}

Export_Manifest :: struct {
	version:          int `json:"version"`,
	session_id:       string `json:"session_id"`,
	created_unix_ns:  i64 `json:"created_unix_ns"`,
	level_floor:      string `json:"level_floor"`,
	request_no:       int `json:"request_no"`,
	request_joined:   bool `json:"request_joined"`,
	include_payloads: bool `json:"include_payloads"`,
	files:            []Export_File `json:"files"`,
	omissions:        []string `json:"omissions"`,
}

Export_Request :: struct {
	version:                    int `json:"version"`,
	session_id:                 string `json:"session_id"`,
	request_no:                 int `json:"request_no"`,
	turn_no_present:            bool `json:"turn_no_present"`,
	turn_no:                    int `json:"turn_no"`,
	purpose:                    string `json:"purpose"`,
	started_at_ms:              i64 `json:"started_at_ms"`,
	finished_at_ms_present:     bool `json:"finished_at_ms_present"`,
	finished_at_ms:             i64 `json:"finished_at_ms"`,
	outcome:                    string `json:"outcome"`,
	attempts:                   int `json:"attempts"`,
	finish:                     string `json:"finish"`,
	provider:                   string `json:"provider"`,
	model_requested:            string `json:"model_requested"`,
	model_resolved:             string `json:"model_resolved"`,
	api:                        string `json:"api"`,
	input_tokens_present:       bool `json:"input_tokens_present"`,
	input_tokens:               i64 `json:"input_tokens"`,
	output_tokens_present:      bool `json:"output_tokens_present"`,
	output_tokens:              i64 `json:"output_tokens"`,
	cache_read_tokens_present:  bool `json:"cache_read_tokens_present"`,
	cache_read_tokens:          i64 `json:"cache_read_tokens"`,
	cache_write_tokens_present: bool `json:"cache_write_tokens_present"`,
	cache_write_tokens:         i64 `json:"cache_write_tokens"`,
}

Export_File :: struct {
	path:      string `json:"path"`,
	bytes:     int `json:"bytes"`,
	sha256:    string `json:"sha256"`,
	truncated: bool `json:"truncated"`,
}

Export_Journal_Record :: struct {
	seq:      i64 `json:"seq"`,
	time_ms:  i64 `json:"time_ms"`,
	kind:     string `json:"kind"`,
	turn:     int `json:"turn"`,
	request:  int `json:"request"`,
	attempt:  int `json:"attempt"`,
	call:     int `json:"call"`,
	provider: string `json:"provider"`,
	model:    string `json:"model"`,
	data:     json.Value `json:"data"`,
	body:     string `json:"body,omitempty"`,
}

Export_Stream :: struct {
	file: ^os.File,
	hash: ^sha2.Context_256,
}

@(private)
export_stream_write :: proc(data: rawptr, mode: io.Stream_Mode, bytes: []byte, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
	if mode != .Write { return 0, .Unsupported }
	stream := cast(^Export_Stream)data
	written, write_error := os.write(stream.file, bytes)
	if written > 0 { sha2.update(stream.hash, bytes[:written]) }
	if write_error != nil { return i64(written), .Closed }
	return i64(written), nil
}

// diagnostics_stream writes filter's records to writer as JSON lines, oldest first,
// and stops before the line that would pass budget; a zero budget is no cap.
// runtime.message records below level are left out.
diagnostics_stream :: proc(
	store: ^journal.Journal,
	filter: journal.Filter,
	level: log.Level,
	writer: io.Writer,
	include_payloads: bool,
	budget: int,
) -> (
	bytes: int,
	records_written: int,
	okay: bool,
) {
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil { return }
	defer virtual.arena_destroy(&scratch)
	scratch_allocator := virtual.arena_allocator(&scratch)

	last: journal.Journal_Seq
	for {
		records, next, read_error := journal.read_records(store, filter, last, EXPORT_PAGE_RECORDS, context.allocator)
		if read_error != nil { return }
		defer journal.records_destroy(records, context.allocator)
		for &record in records {
			free_all(scratch_allocator)
			line, kept, line_okay := diagnostics_record_line(&record, level, include_payloads, scratch_allocator)
			if !line_okay { return }
			if !kept { continue }
			if budget > 0 && bytes + len(line) + 1 > budget { return bytes, records_written, true }
			if written, write_error := io.write(writer, line); write_error != nil || written != len(line) { return }
			if written, write_error := io.write_string(writer, "\n"); write_error != nil || written != 1 { return }
			bytes += len(line) + 1
			records_written += 1
		}
		if next == last { return bytes, records_written, true }
		last = next
	}
}

// diagnostics_record_line encodes one record as a JSON line in allocator. kept is
// false for a runtime.message below level.
@(private)
diagnostics_record_line :: proc(
	record: ^journal.Record,
	level: log.Level,
	include_payloads: bool,
	allocator: mem.Allocator,
) -> (
	line: []u8,
	kept: bool,
	okay: bool,
) {
	if record.kind == .Runtime_Message {
		message: journal.Runtime_Message
		if journal.payload_decode(record.data, &message, allocator) != nil { return }
		message_level, enabled, known := agent.log_level_parse(message.level)
		if known && enabled && message_level < level { return nil, false, true }
	}
	value: json.Value
	if json.unmarshal_string(record.data, &value, allocator = allocator) != nil { return }
	entry := Export_Journal_Record {
		seq      = i64(record.seq),
		time_ms  = record.time_ms,
		kind     = journal.RECORD_KIND_NAMES[record.kind],
		turn     = int(record.turn),
		request  = int(record.request),
		attempt  = int(record.attempt),
		call     = int(record.call),
		provider = record.provider,
		model    = record.model,
		data     = value,
	}
	if include_payloads { entry.body = string(record.body) }
	encode_error: json.Marshal_Error
	line, encode_error = json.marshal(entry, allocator = allocator)
	return line, true, encode_error == nil
}

diagnostics_export :: proc(
	store: ^journal.Journal,
	session_text, destination: string,
	filter: journal.Filter,
	level: log.Level,
	include_payloads, join_okay: bool,
	stderr: io.Writer,
) -> int {
	if make_error := os.make_directory(destination, EXPORT_DIRECTORY_PERMISSIONS); make_error != nil {
		fmt.wprintf(stderr, "nabla: the export directory could not be created: %s\n", os.error_string(make_error))
		return 1
	}
	files, allocation_error := make([dynamic]Export_File, 0, 3, context.allocator)
	if allocation_error != nil { return 1 }
	defer export_files_destroy(&files)
	omissions, omission_error := make([dynamic]string, 0, 1, context.allocator)
	if omission_error != nil { return 1 }
	defer {
		for omission in omissions { delete(omission, context.allocator) }
		delete(omissions)
	}
	if filter.request != 0 &&
	   !diagnostics_export_request(store, &files, &omissions, destination, session_text, filter.session, filter.request, join_okay) { return 1 }
	path, joined := export_join(destination, EXPORT_SESSION_NAME, context.allocator)
	if !joined { return 1 }
	defer delete(path, context.allocator)
	file, hash, opened := export_open(path, context.allocator)
	if !opened { return 1 }
	stream := Export_Stream {
		file = file,
		hash = hash,
	}
	bytes, count, stream_okay := diagnostics_stream(store, filter, level, {procedure = export_stream_write, data = &stream}, include_payloads, EXPORT_BYTES)
	if !export_close(&files, EXPORT_SESSION_NAME, file, hash, bytes, bytes >= EXPORT_BYTES, context.allocator) || !stream_okay { return 1 }
	manifest := Export_Manifest {
		version          = 1,
		session_id       = session_text,
		created_unix_ns  = time.time_to_unix_nano(time.now()),
		level_floor      = agent.log_level_name(level),
		request_no       = int(filter.request),
		request_joined   = filter.request == 0 || join_okay,
		include_payloads = include_payloads,
		files            = files[:],
		omissions        = omissions[:],
	}
	if !diagnostics_export_manifest(destination, &manifest) { return 1 }
	fmt.wprintf(stderr, "nabla: exported %d record(s) into %s\n", count, destination)
	return join_okay ? 0 : 1
}

@(private)
diagnostics_export_manifest :: proc(destination: string, manifest: ^Export_Manifest) -> bool {
	path, joined := export_join(destination, EXPORT_MANIFEST_NAME, context.allocator)
	if !joined { return false }
	defer delete(path, context.allocator)
	data, encode_error := json.marshal(manifest^, {pretty = true, sort_maps_by_key = true}, context.allocator)
	if encode_error != nil { return false }
	defer delete(data, context.allocator)
	file, hash, opened := export_open(path, context.allocator)
	if !opened { return false }
	okay := export_write(file, data, hash)
	return export_close(nil, EXPORT_MANIFEST_NAME, file, hash, len(data), false, context.allocator) && okay
}

@(private)
export_open :: proc(path: string, allocator: mem.Allocator) -> (file: ^os.File, hash: ^sha2.Context_256, okay: bool) {
	handle, open_error := os.open(path, {.Write, .Create, .Excl}, EXPORT_FILE_PERMISSIONS)
	if open_error != nil { return nil, nil, false }
	state, allocation_error := new(sha2.Context_256, allocator)
	if allocation_error != nil { _ = os.close(handle); return nil, nil, false }
	sha2.init_256(state)
	return handle, state, true
}

@(private)
export_close :: proc(
	files: ^[dynamic]Export_File,
	relative: string,
	file: ^os.File,
	hash: ^sha2.Context_256,
	bytes: int,
	truncated: bool,
	allocator: mem.Allocator,
) -> bool {
	close_error := os.close(file)
	if close_error != nil { free(hash, allocator); return false }
	if files == nil { free(hash, allocator); return true }
	entry := Export_File {
		bytes     = bytes,
		truncated = truncated,
	}
	clone_error: mem.Allocator_Error
	entry.path, clone_error = strings.clone(relative, allocator)
	if clone_error != nil { free(hash, allocator); return false }
	digest: journal.Digest
	sha2.final(hash, digest[:])
	text: [journal.DIGEST_HEX_LENGTH]u8
	entry.sha256, clone_error = strings.clone(journal.digest_to_hex(digest, text[:]), allocator)
	free(hash, allocator)
	if clone_error != nil { delete(entry.path, allocator); return false }
	if append(files, entry) != 1 { delete(entry.path, allocator); delete(entry.sha256, allocator); return false }
	return true
}

@(private)
export_write :: proc(file: ^os.File, bytes: []u8, hash: ^sha2.Context_256) -> bool {
	remaining := bytes
	for len(remaining) > 0 {
		written, write_error := os.write(file, remaining)
		if write_error != nil || written <= 0 { return false }
		sha2.update(hash, remaining[:written])
		remaining = remaining[written:]
	}
	return true
}

@(private)
export_join :: proc(directory, name: string, allocator: mem.Allocator) -> (string, bool) {
	path, join_error := filepath.join([]string{directory, name}, allocator)
	return path, join_error == nil
}

@(private)
export_note :: proc(omissions: ^[dynamic]string, text: string) {
	note, clone_error := strings.clone(text, context.allocator)
	if clone_error != nil { return }
	if append(omissions, note) != 1 { delete(note, context.allocator) }
}

@(private)
export_files_destroy :: proc(files: ^[dynamic]Export_File) {
	for file in files { delete(file.path, context.allocator); delete(file.sha256, context.allocator) }
	delete(files^)
}

diagnostics_export_request :: proc(
	store: ^journal.Journal,
	files: ^[dynamic]Export_File,
	omissions: ^[dynamic]string,
	destination, session_text: string,
	session_id: journal.Session_Id,
	request_no: journal.Request_Id,
	join_okay: bool,
) -> bool {
	if !join_okay { export_note(omissions, "the session database did not report this request, so request.json is absent"); return true }
	row, load_error := diagnostics_request_open(store, session_id, request_no, context.allocator)
	if load_error != nil { export_note(omissions, "the stored request could not be read"); return true }
	defer diagnostics_request_destroy(&row, context.allocator)
	payload := export_request_from(&row, session_text)
	data, encode_error := json.marshal(payload, {pretty = true, sort_maps_by_key = true}, context.allocator)
	if encode_error != nil { return false }
	defer delete(data, context.allocator)
	path, joined := export_join(destination, EXPORT_REQUEST_NAME, context.allocator)
	if !joined { return false }
	defer delete(path, context.allocator)
	file, hash, opened := export_open(path, context.allocator)
	if !opened { return false }
	okay := export_write(file, data, hash)
	return export_close(files, EXPORT_REQUEST_NAME, file, hash, len(data), false, context.allocator) && okay
}

@(private)
export_request_from :: proc(row: ^Diagnostics_Request, session_text: string) -> Export_Request {
	payload := Export_Request {
		version         = 1,
		session_id      = session_text,
		request_no      = int(row.request),
		purpose         = row.purpose,
		started_at_ms   = row.started_ms,
		outcome         = row.outcome,
		attempts        = row.attempts,
		finish          = row.finish,
		provider        = row.provider,
		model_requested = row.model_requested,
		model_resolved  = row.model_resolved,
		api             = row.api,
	}
	if row.turn != 0 { payload.turn_no_present = true; payload.turn_no = int(row.turn) }
	if row.finished_ms != 0 { payload.finished_at_ms_present = true; payload.finished_at_ms = row.finished_ms }
	payload.input_tokens_present, payload.input_tokens = export_usage_bucket(row.input_tokens)
	payload.output_tokens_present, payload.output_tokens = export_usage_bucket(row.output_tokens)
	payload.cache_read_tokens_present, payload.cache_read_tokens = export_usage_bucket(row.cache_read_tokens)
	payload.cache_write_tokens_present, payload.cache_write_tokens = export_usage_bucket(row.cache_write_tokens)
	return payload
}

@(private)
export_usage_bucket :: proc(value: Maybe(i64)) -> (bool, i64) {
	count, present := value.?
	return present, count
}
