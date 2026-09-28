package main

import "core:crypto/sha2"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "nabla:agent"
import "nabla:agent/journal"

// The export writes one session's evidence into a directory of its own, with a
// manifest that says what was written, what was left out, and why. Metadata is the
// default: payload artifacts are copied only when the caller asks for them, because
// they are exactly the bytes a record refuses to carry.
//
// The destination is created exclusively and every file in it is new, so a
// half-finished export is visibly half finished rather than mistakable for a
// complete one.

EXPORT_MANIFEST_NAME :: "manifest.json"
EXPORT_SESSION_NAME :: "session.jsonl"
EXPORT_REQUEST_NAME :: "request.json"
EXPORT_RUN_EVENTS_NAME :: "events.jsonl"
EXPORT_RUNS_DIRECTORY :: "runs"
EXPORT_CAPTURES_DIRECTORY :: "captures"

// EXPORT_BYTES bounds one export. It is a total across every file, so a large
// session yields a bounded bundle with an explicit note rather than an open-ended
// copy.
EXPORT_BYTES :: 32 * 1024 * 1024

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

// Export_Request summarizes one request from journal records. Every optional fact carries its
// own presence flag, because JSON cannot tell a reader that did not write the
// file whether an absent number was unreported or zero.
//
// The stored input, response, error, and configuration are absent from request.json.
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

// Export_State is what the reader's visitor fills while the session's records are
// copied: the bytes written, the runs that contributed them, and what the budget
// refused.
Export_State :: struct {
	file:         ^os.File,
	hash:         ^sha2.Context_256,
	bytes:        int,
	written_okay: bool,
	runs:         [dynamic]string, // owned; the runs that contributed a record
	truncated:    bool,
}

diagnostics_export :: proc(
	logs_root: string,
	session_text: string,
	session_id: journal.Session_Id,
	destination: string,
	selector: agent.Log_Read_Selector,
	include_payloads: bool,
	join_okay: bool,
	stderr: io.Writer,
) -> int {
	if destination == "" {
		fmt.wprintln(stderr, "nabla: --export needs a directory")
		return 2
	}
	// Exclusive creation: an export never writes into a directory that already holds
	// something, so a previous bundle cannot be silently mixed with this one.
	if make_err := os.make_directory(destination, EXPORT_DIRECTORY_PERMISSIONS); make_err != nil {
		fmt.wprintf(stderr, "nabla: the export directory could not be created: %s\n", os.error_string(make_err))
		return 1
	}

	files, files_error := make([dynamic]Export_File, 0, 8, context.allocator)
	if files_error != nil {
		fmt.wprintln(stderr, "nabla: the export file table could not be allocated")
		return 1
	}
	defer export_files_destroy(&files)
	omissions, omissions_error := make([dynamic]string, 0, 8, context.allocator)
	if omissions_error != nil {
		fmt.wprintln(stderr, "nabla: the export omission table could not be allocated")
		return 1
	}
	defer {
		for omission in omissions { delete(omission, context.allocator) }
		delete(omissions)
	}

	state := Export_State {
		written_okay = true,
	}
	// The durable row is written first, because it is the file that says what the
	// session decided rather than what one process observed.
	if request_no, selected := selector.request_no.?; selected {
		if !diagnostics_export_request(&files, &omissions, destination, session_text, session_id, journal.Request_Id(request_no), join_okay) {
			state.written_okay = false
		}
	}

	summary := diagnostics_export_session(&files, &state, logs_root, destination, session_text, session_id, selector, include_payloads, stderr)
	if !state.written_okay { return 1 }
	defer {
		for run_id in state.runs { delete(run_id, context.allocator) }
		delete(state.runs)
	}

	budget := EXPORT_BYTES - state.bytes
	for run_id in state.runs {
		if !diagnostics_export_run(&files, &omissions, &budget, logs_root, destination, run_id, include_payloads) {
			state.written_okay = false
		}
	}
	if !state.written_okay { return 1 }
	if state.truncated {
		export_note(&omissions, "the session stream was cut off at the export budget")
	}

	export_note_reader_omissions(&omissions, summary)
	manifest := Export_Manifest {
		version          = 1,
		session_id       = session_text,
		created_unix_ns  = time.time_to_unix_nano(time.now()),
		level_floor      = agent.log_level_name(selector.level),
		request_no       = export_request_number(selector),
		request_joined   = export_request_joined(selector, join_okay),
		include_payloads = include_payloads,
		files            = files[:],
		omissions        = omissions[:],
	}
	joined_okay := diagnostics_export_manifest(destination, &manifest, &files, stderr)
	if !joined_okay { return 1 }
	// A --request whose durable half is missing is an incomplete answer, so the
	// bundle is written, says so, and the command fails.
	if !export_request_joined(selector, join_okay) { return 1 }

	fmt.wprintf(stderr, "nabla: exported %d record(s) from %d run(s) into %s\n", summary.records, len(state.runs), destination)
	if len(omissions) > 0 { fmt.wprintf(stderr, "nabla: %d omission(s) recorded in the manifest\n", len(omissions)) }
	return 0
}

// diagnostics_export_session writes the journal records and collects diagnostic run ids.
@(private)
diagnostics_export_session :: proc(
	files: ^[dynamic]Export_File,
	state: ^Export_State,
	logs_root: string,
	destination: string,
	session_text: string,
	session_id: journal.Session_Id,
	selector: agent.Log_Read_Selector,
	include_payloads: bool,
	stderr: io.Writer,
) -> agent.Log_Read_Summary {
	path, joined := export_join(destination, EXPORT_SESSION_NAME, context.allocator)
	if !joined {
		state.written_okay = false
		return {}
	}
	defer delete(path, context.allocator)
	file, hash, open_okay := export_open(path, context.allocator)
	if !open_okay {
		fmt.wprintln(stderr, "nabla: the session file could not be created")
		state.written_okay = false
		return {}
	}
	state.file = file
	state.hash = hash
	summary := agent.log_read_session(logs_root, session_text, state, diagnostics_export_visit, selector)
	journal_directory, directory_error := agent.xdg_directory(.State, context.temp_allocator)
	if directory_error != .None {
		state.written_okay = false
	} else {
		store: journal.Journal
		if open_error := journal.open(&store, journal_directory, journal.run_id_create(), .Read_Only, context.allocator); open_error != nil {
			state.written_okay = false
		} else {
			last: journal.Journal_Seq
			for state.written_okay {
				records, next, read_error := journal.read_records(&store, {session = session_id}, last, 256, context.allocator)
				if read_error != nil { state.written_okay = false; break }
				for &record in records {
					if !diagnostics_export_journal_record(state, &record, include_payloads) { state.written_okay = false; break }
				}
				journal.records_destroy(records, context.allocator)
				if next == last { break }
				last = next
			}
			if journal.close(&store) != nil { state.written_okay = false }
		}
	}
	if !export_close(files, EXPORT_SESSION_NAME, file, hash, state.bytes, state.truncated, context.allocator) {
		state.written_okay = false
	}
	return summary
}

@(private)
diagnostics_export_journal_record :: proc(state: ^Export_State, record: ^journal.Record, include_payloads: bool) -> bool {
	if state.truncated { return true }
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil { return false }
	defer virtual.arena_destroy(&scratch)
	value: json.Value
	if json.unmarshal_string(record.data, &value, allocator = virtual.arena_allocator(&scratch)) != nil { return false }
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
	encoded, encode_error := json.marshal(entry, allocator = context.allocator)
	if encode_error != nil { return false }
	defer delete(encoded, context.allocator)
	if state.truncated { return true }
	if state.bytes + len(encoded) + 1 > EXPORT_BYTES { state.truncated = true; return true }
	if !export_write(state.file, encoded, state.hash) { return false }
	if !export_write(state.file, []u8{'\n'}, state.hash) { return false }
	state.bytes += len(encoded) + 1
	return true
}

// The log scan collects run ids for the separate run files.
@(private)
diagnostics_export_visit :: proc(user_data: rawptr, run_id: string, line: string) -> bool {
	state := cast(^Export_State)user_data
	if !export_note_run(state, run_id) {
		state.written_okay = false
		return false
	}
	return true
}

@(private)
export_note_run :: proc(state: ^Export_State, run_id: string) -> bool {
	for existing in state.runs {
		if existing == run_id { return true }
	}
	name, clone_error := strings.clone(run_id, context.allocator)
	if clone_error != nil { return false }
	appended := append(&state.runs, name)
	if appended != 1 {
		if appended == 0 { delete(name, context.allocator) }
		return false
	}
	return true
}

// diagnostics_export_run copies one run's segments and, when asked, its captures.
// Each segment is read up to the size it had when the read began, so an active
// writer's new tail is not copied half-written.
@(private)
diagnostics_export_run :: proc(
	files: ^[dynamic]Export_File,
	omissions: ^[dynamic]string,
	budget: ^int,
	logs_root: string,
	destination: string,
	run_id: string,
	include_payloads: bool,
) -> bool {
	runs_directory, runs_joined := export_join(logs_root, agent.LOG_RUNS_DIRECTORY, context.temp_allocator)
	if !runs_joined { return false }
	run_directory, run_joined := export_join(runs_directory, run_id, context.temp_allocator)
	if !run_joined { return false }

	relative := strings.concatenate({EXPORT_RUNS_DIRECTORY, "/", run_id}, context.allocator)
	defer delete(relative, context.allocator)
	target_directory, target_joined := export_join(destination, relative, context.allocator)
	if !target_joined { return false }
	defer delete(target_directory, context.allocator)
	if make_err := os.make_directory_all(target_directory, EXPORT_DIRECTORY_PERMISSIONS); make_err != nil && make_err != .Exist {
		export_note(omissions, fmt.tprintf("run %s could not be written: %s", run_id, os.error_string(make_err)))
		return false
	}

	segments, unreadable, listed := agent.log_run_segments(run_directory, context.allocator)
	if !listed {
		export_note(omissions, fmt.tprintf("run %s could not be read", run_id))
		return false
	}
	defer agent.log_run_segments_destroy(&segments, context.allocator)
	if unreadable > 0 {
		export_note(omissions, fmt.tprintf("run %s has %d entry that is not a readable segment", run_id, unreadable))
	}

	path, path_joined := export_join(target_directory, EXPORT_RUN_EVENTS_NAME, context.allocator)
	if !path_joined { return false }
	defer delete(path, context.allocator)
	file, hash, open_okay := export_open(path, context.allocator)
	if !open_okay {
		export_note(omissions, fmt.tprintf("run %s could not be written", run_id))
		return false
	}

	written := 0
	read := 0
	truncated := false
	for segment in segments {
		if budget^ - written <= 0 {
			truncated = true
			break
		}
		segment_path, segment_joined := export_join(run_directory, segment.name, context.temp_allocator)
		if !segment_joined { continue }
		content, read_okay := agent.log_read_segment_bytes(segment_path, budget^ - written, context.allocator)
		if !read_okay {
			export_note(omissions, fmt.tprintf("run %s: %s could not be read", run_id, segment.name))
			continue
		}
		if !export_write(file, content, hash) {
			delete(content, context.allocator)
			return false
		}
		written += len(content)
		read += 1
		delete(content, context.allocator)
	}

	relative_file := strings.concatenate({relative, "/", EXPORT_RUN_EVENTS_NAME}, context.allocator)
	defer delete(relative_file, context.allocator)
	if !export_close(files, relative_file, file, hash, written, truncated, context.allocator) { return false }
	budget^ -= written
	if truncated {
		export_note(omissions, fmt.tprintf("run %s was cut off at the export budget", run_id))
	}
	if read < len(segments) && !truncated {
		export_note(omissions, fmt.tprintf("run %s has segments that were not copied", run_id))
	}

	if include_payloads {
		return diagnostics_export_captures(files, omissions, budget, run_directory, destination, relative)
	}
	if export_has_captures(run_directory) {
		export_note(omissions, fmt.tprintf("run %s holds payload captures that were not included", run_id))
	}
	return true
}

// diagnostics_export_captures copies a run's artifacts verbatim. The metadata
// sidecars go with them, because a payload without its counts and digests cannot say
// how complete it is.
@(private)
diagnostics_export_captures :: proc(
	files: ^[dynamic]Export_File,
	omissions: ^[dynamic]string,
	budget: ^int,
	run_directory: string,
	destination: string,
	relative_run: string,
) -> bool {
	captures_directory, joined := export_join(run_directory, EXPORT_CAPTURES_DIRECTORY, context.temp_allocator)
	if !joined { return true }
	entries, list_err := os.read_all_directory_by_path(captures_directory, context.temp_allocator)
	if list_err != nil { return true }

	export_directory, export_joined := export_join(destination, relative_run, context.allocator)
	if !export_joined { return false }
	defer delete(export_directory, context.allocator)
	captures_target, captures_joined := export_join(export_directory, EXPORT_CAPTURES_DIRECTORY, context.allocator)
	if !captures_joined { return false }
	defer delete(captures_target, context.allocator)
	if make_err := os.make_directory_all(captures_target, EXPORT_DIRECTORY_PERMISSIONS); make_err != nil && make_err != .Exist {
		export_note(omissions, "the capture directory could not be written")
		return false
	}

	copied := 0
	for entry in entries {
		if entry.type != .Regular { continue }
		if budget^ <= 0 {
			export_note(omissions, "payload captures were cut off at the export budget")
			break
		}
		source, source_joined := export_join(captures_directory, entry.name, context.temp_allocator)
		if !source_joined { continue }
		content, read_okay := agent.log_read_segment_bytes(source, budget^, context.allocator)
		if !read_okay {
			export_note(omissions, fmt.tprintf("artifact %s could not be read", entry.name))
			continue
		}
		target, target_joined := export_join(captures_target, entry.name, context.allocator)
		if !target_joined {
			delete(content, context.allocator)
			continue
		}
		file, hash, open_okay := export_open(target, context.allocator)
		if !open_okay {
			export_note(omissions, fmt.tprintf("artifact %s could not be written", entry.name))
			delete(target, context.allocator)
			delete(content, context.allocator)
			continue
		}
		if !export_write(file, content, hash) {
			delete(target, context.allocator)
			delete(content, context.allocator)
			return false
		}
		relative := strings.concatenate({relative_run, "/", EXPORT_CAPTURES_DIRECTORY, "/", entry.name}, context.allocator)
		okay := export_close(files, relative, file, hash, len(content), false, context.allocator)
		delete(relative, context.allocator)
		budget^ -= len(content)
		copied += 1
		delete(target, context.allocator)
		delete(content, context.allocator)
		if !okay { return false }
	}
	if copied == 0 { export_note(omissions, "payload capture was requested but no artifact was found") }
	return true
}

@(private)
export_has_captures :: proc(run_directory: string) -> bool {
	captures_directory, joined := export_join(run_directory, EXPORT_CAPTURES_DIRECTORY, context.temp_allocator)
	if !joined { return false }
	entries, list_err := os.read_all_directory_by_path(captures_directory, context.temp_allocator)
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	return list_err == nil && len(entries) > 0
}

// diagnostics_export_manifest writes the manifest last: it describes files that must
// already exist, so a manifest without them would be a claim about nothing.
@(private)
diagnostics_export_manifest :: proc(destination: string, manifest: ^Export_Manifest, files: ^[dynamic]Export_File, stderr: io.Writer) -> bool {
	path, joined := export_join(destination, EXPORT_MANIFEST_NAME, context.allocator)
	if !joined { return false }
	defer delete(path, context.allocator)
	data, marshal_err := json.marshal(manifest^, {pretty = true, sort_maps_by_key = true}, context.allocator)
	if marshal_err != nil {
		fmt.wprintln(stderr, "nabla: the manifest could not be encoded")
		return false
	}
	defer delete(data, context.allocator)
	file, hash, open_okay := export_open(path, context.allocator)
	if !open_okay {
		fmt.wprintln(stderr, "nabla: the manifest could not be created")
		return false
	}
	if !export_write(file, data, hash) { return false }
	return export_close(files, EXPORT_MANIFEST_NAME, file, hash, len(data), false, context.allocator)
}

// --- file helpers -------------------------------------------------------------

// export_open creates one export file exclusively with owner-only permissions. An
// existing file is never overwritten: an export writes where nothing was.
@(private)
export_open :: proc(path: string, allocator: mem.Allocator) -> (file: ^os.File, hash: ^sha2.Context_256, okay: bool) {
	handle, open_err := os.open(path, {.Write, .Create, .Excl}, EXPORT_FILE_PERMISSIONS)
	if open_err != nil { return nil, nil, false }
	state, state_error := new(sha2.Context_256, allocator)
	if state_error != nil {
		os.close(handle)
		return nil, nil, false
	}
	sha2.init_256(state)
	return handle, state, true
}

// export_close finishes one file: it closes it, renders its digest, and records what
// was written so the manifest can describe it.
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
	okay := true
	if close_err := os.close(file); close_err != nil { okay = false }
	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.final(hash, digest[:])
	text: [sha2.DIGEST_SIZE_256 * 2]u8
	export_hex(text[:], digest[:])
	entry := Export_File {
		bytes     = bytes,
		truncated = truncated,
	}
	clone_error: mem.Allocator_Error
	entry.path, clone_error = strings.clone(relative, allocator)
	if clone_error != nil { okay = false }
	if okay {
		entry.sha256, clone_error = strings.clone(string(text[:]), allocator)
		if clone_error != nil {
			delete(entry.path, allocator)
			entry.path = ""
			okay = false
		}
	}
	if okay {
		appended := append(files, entry)
		if appended != 1 {
			if appended == 0 {
				delete(entry.path, allocator)
				delete(entry.sha256, allocator)
			}
			okay = false
		}
	}
	free(hash, allocator)
	return okay
}

@(private)
export_write :: proc(file: ^os.File, bytes: []u8, hash: ^sha2.Context_256) -> bool {
	remaining := bytes
	for len(remaining) > 0 {
		written, write_err := os.write(file, remaining)
		if write_err != nil { return false }
		if written <= 0 { return false }
		remaining = remaining[written:]
	}
	sha2.update(hash, bytes)
	return true
}

@(private)
export_hex :: proc(destination: []u8, bytes: []u8) {
	for byte, index in bytes {
		if index * 2 + 1 >= len(destination) { break }
		destination[index * 2] = export_hex_digit(byte >> 4)
		destination[index * 2 + 1] = export_hex_digit(byte & 0x0F)
	}
}

@(private)
export_hex_digit :: proc(value: u8) -> u8 {
	return value < 10 ? '0' + value : 'a' + (value - 10)
}

// export_join builds a path the way the diagnostics code does, so an export path is
// one definition rather than two.
@(private)
export_join :: proc(directory, name: string, allocator: mem.Allocator) -> (string, bool) {
	path, join_err := filepath.join([]string{directory, name}, allocator)
	if join_err != nil { return "", false }
	return path, true
}

@(private)
export_note :: proc(omissions: ^[dynamic]string, text: string) {
	note, clone_error := strings.clone(text, context.allocator)
	if clone_error != nil { return }
	appended := append(omissions, note)
	if appended != 1 && appended == 0 { delete(note, context.allocator) }
}

@(private)
export_files_destroy :: proc(files: ^[dynamic]Export_File) {
	for file in files {
		delete(file.path, context.allocator)
		delete(file.sha256, context.allocator)
	}
	delete(files^)
}

// export_note_reader_omissions turns what the reader could not do into manifest
// entries, so an incomplete bundle says which evidence is missing and why.
@(private)
export_note_reader_omissions :: proc(omissions: ^[dynamic]string, summary: agent.Log_Read_Summary) {
	if summary.cannot_read > 0 {
		export_note(omissions, fmt.tprintf("%d run(s) or file(s) could not be read", summary.cannot_read))
	}
	if summary.records_skipped > 0 {
		export_note(omissions, fmt.tprintf("%d line(s) were not records", summary.records_skipped))
	}
	if summary.records_unsupported > 0 {
		export_note(omissions, fmt.tprintf("%d record(s) use a format version this build does not implement", summary.records_unsupported))
	}
	if summary.records_foreign > 0 {
		export_note(omissions, fmt.tprintf("%d record(s) did not match the run directory they were found in", summary.records_foreign))
	}
	if summary.partial_tails > 0 {
		export_note(omissions, fmt.tprintf("%d final line(s) were never completed", summary.partial_tails))
	}
	if summary.gaps > 0 {
		export_note(omissions, fmt.tprintf("%d segment(s) were removed by retention before this export", summary.gaps))
	}
	if summary.runs_truncated {
		export_note(omissions, "the run scan limit was reached, so older runs may be absent")
	}
	if summary.stopped {
		export_note(omissions, "the read stopped before every record was copied")
	}
}

@(private)
export_request_number :: proc(selector: agent.Log_Read_Selector) -> int {
	request_no, present := selector.request_no.?
	if !present { return 0 }
	return int(request_no)
}

// export_request_joined reports whether the --request bundle holds the durable
// half it was asked for. A selector that named no request has nothing to join,
// so the flag is only meaningful when one was selected.
@(private)
export_request_joined :: proc(selector: agent.Log_Read_Selector, join_okay: bool) -> bool {
	_, selected := selector.request_no.?
	return !selected || join_okay
}

// diagnostics_export_request writes the journal summary for a --request export.
diagnostics_export_request :: proc(
	files: ^[dynamic]Export_File,
	omissions: ^[dynamic]string,
	destination: string,
	session_text: string,
	session_id: journal.Session_Id,
	request_no: journal.Request_Id,
	join_okay: bool,
) -> bool {
	if !join_okay {
		export_note(omissions, "the session database did not report this request, so request.json is absent")
		return true
	}

	row, load_err := diagnostics_request_open(session_id, request_no, context.allocator)
	if load_err != nil {
		export_note(omissions, fmt.tprintf("the stored request could not be read: %s", journal.error_text(load_err, context.temp_allocator)))
		return true
	}
	defer diagnostics_request_destroy(&row, context.allocator)

	payload := export_request_from(&row, session_text)
	data, marshal_err := json.marshal(payload, {pretty = true, sort_maps_by_key = true}, context.allocator)
	if marshal_err != nil {
		export_note(omissions, "request.json could not be encoded")
		return true
	}
	defer delete(data, context.allocator)

	path, joined := export_join(destination, EXPORT_REQUEST_NAME, context.allocator)
	if !joined { return false }
	defer delete(path, context.allocator)
	file, hash, open_okay := export_open(path, context.allocator)
	if !open_okay {
		export_note(omissions, "request.json could not be created")
		return true
	}
	if !export_write(file, data, hash) { return false }
	return export_close(files, EXPORT_REQUEST_NAME, file, hash, len(data), false, context.allocator)
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
	if turn_no := row.turn; turn_no != 0 {
		payload.turn_no_present = true
		payload.turn_no = int(turn_no)
	}
	if finished_at_ms := row.finished_ms; finished_at_ms != 0 {
		payload.finished_at_ms_present = true
		payload.finished_at_ms = finished_at_ms
	}
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
