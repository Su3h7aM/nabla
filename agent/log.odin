package agent

import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"

import "nabla:agent/session"

// A Log is one process run's diagnostic stream: JSON Lines records written
// synchronously under a mutex, one file per segment inside a private run
// directory. It records what the harness observed at named boundaries, which
// request was prepared, what was encoded, where a failure happened. It is not
// durable like the session database and never authoritative over it.
//
// The log owns its run directory, its segment file, and its run id. Everything a
// Record or Log_Context borrows is consumed by the emit call and never retained,
// so a caller can record a string that lives on context.temp_allocator.
//
// The zero Log is closed and writes nothing, which is what a run with logging
// disabled keeps.

LOG_VERSION :: 1

// LOG_MAX_RECORD_BYTES bounds one encoded record, newline included. A record
// that does not fit is replaced by a compact record that names the one that was
// dropped, so a producer mistake cannot turn a log line into unbounded memory.
LOG_MAX_RECORD_BYTES :: 64 * 1024

// LOG_SEGMENT_BYTES is how large one segment may grow before the next begins.
LOG_SEGMENT_BYTES :: 8 * 1024 * 1024

// LOG_SEGMENTS_PER_RUN is how many segments a run keeps. Starting the next one
// deletes the oldest, so a long run holds a bounded window of its own history
// rather than every record it ever wrote.
LOG_SEGMENTS_PER_RUN :: 4

LOG_RUN_ID_LENGTH :: 32

// LOG_RUN_ID_ATTEMPTS bounds how many run ids are tried before giving up. A
// collision needs two processes to draw the same 128 bits, so the loop exists to
// make the failure bounded rather than to expect it.
LOG_RUN_ID_ATTEMPTS :: 8

LOG_MAX_DETAIL :: 160

LOG_RUNS_DIRECTORY :: "runs"
LOG_SEGMENT_PREFIX :: "events-"
LOG_SEGMENT_SUFFIX :: ".jsonl"

// The log directory is private, and so is every file in it: a record can describe
// the user's work.
LOG_DIRECTORY_PERMISSIONS :: os.Permissions{.Read_User, .Write_User, .Execute_User}
LOG_FILE_PERMISSIONS :: os.Permissions{.Read_User, .Write_User}

// Log_Level orders severity. Disabled is the zero value, so a zero Log_Options
// records nothing rather than everything.
Log_Level :: enum u8 {
	Disabled,
	Error,
	Warn,
	Info,
	Debug,
	Trace,
}

// Log_Category names the part of the harness a record came from. The set is
// closed so a record cannot carry a category that no reader knows.
Log_Category :: enum {
	Runtime,
	Session,
	Agent,
	Provider,
	Transport,
	Tool,
	MCP,
	Storage,
	Diagnostics,
}

// Log_Value is the closed set of scalar types a field may carry. It grows when a
// producer needs a type that is not here; a nested object, a raw JSON fragment,
// or a byte blob belongs in a payload capture, or nowhere in a record.
Log_Value :: union {
	bool,
	i64,
	u64,
	string,
}

// Log_Field is one named scalar. The key is a producer-owned literal, and the
// value is borrowed for the duration of the emit call.
Log_Field :: struct {
	key:   string,
	value: Log_Value,
}

// Log_Record is one event. Fields are borrowed for the duration of the emit call
// and never retained.
Log_Record :: struct {
	level:    Log_Level,
	category: Log_Category,
	event:    string,
	fields:   []Log_Field,
}

// Log_Context is the correlation a record is emitted against. Every identity in
// it already exists in the harness, so the log keeps no second copy of anything
// it cannot read from the session itself. A zero context writes nothing.
Log_Context :: struct {
	log:          ^Log,
	session_id:   session.Session_Id,
	turn_no:      session.Turn_No,
	request_no:   session.Request_No,
	attempt:      int,
	operation_id: u64,
}

// Log_Emit_Result says what became of one record. A caller that only records an
// event can ignore it; a caller that needs to know whether its evidence landed
// can check. Disabled is the zero value: a zero result describes a zero scope,
// which writes nothing.
//
// Disabled     there is no open writer
// Filtered     the level is below the writer's threshold
// Oversized    the record did not fit and a compact omission record was written instead
// Rejected     the record broke its contract and nothing was written
// Written      the record was written
// Failed       the sink has failed; nothing more will be written
Log_Emit_Result :: enum {
	Disabled,
	Filtered,
	Oversized,
	Rejected,
	Written,
	Failed,
}

// Log_Options describes one run's log. directory is the log root; the writer
// creates the private run directory inside it.
Log_Options :: struct {
	directory: string,
	level:     Log_Level,
}

// Log_Error_Kind classifies a fallible log operation. The zero value is success,
// so a Log_Error composes with or_return, or_else, and or_break.
Log_Error_Kind :: enum {
	None,
	// The arguments do not describe a valid operation, or the writer is in the
	// wrong state for it.
	Invalid_Argument,
	// The writer is already open and cannot be opened twice.
	Invalid_State,
	// A path, a run id, or an error detail could not be allocated.
	Allocation,
	// The run directory or a segment file could not be created.
	Create,
	// A segment could not be written or closed.
	Write,
}

// Log_Failure is what a Log_Error carries: a classification and a bounded
// detail. It owns nothing and outlives the writer that produced it.
Log_Failure :: struct {
	kind:       Log_Error_Kind,
	detail_len: int,
	detail:     [LOG_MAX_DETAIL]u8,
}

// Log_Error is what every fallible procedure in this file returns. Its zero
// value is nil, which is success.
Log_Error :: union {
	Log_Failure,
}

log_error :: proc(kind: Log_Error_Kind, detail: string) -> Log_Error {
	failure := Log_Failure {
		kind = kind,
	}
	length := min(len(detail), LOG_MAX_DETAIL)
	copy(failure.detail[:length], detail[:length])
	failure.detail_len = length
	return failure
}

// log_error_kind returns the classification of err, or .None when err is nil.
log_error_kind :: proc(err: Log_Error) -> Log_Error_Kind {
	failure, is_failure := err.(Log_Failure)
	if !is_failure { return .None }
	return failure.kind
}

// log_error_detail returns the diagnostic text of err, or "" when err is nil.
// The result aliases err, so err has to be addressable and outlive the call.
log_error_detail :: proc(err: ^Log_Error) -> string {
	if err^ == nil { return "" }
	failure := &err^.(Log_Failure)
	return string(failure.detail[:failure.detail_len])
}

// Log_Health is what the writer latched about itself. written and omitted count
// records, not bytes. first_error and first_platform_error describe the failure
// that stopped the sink, and are only meaningful while failed is true.
Log_Health :: struct {
	failed:               bool,
	first_error:          Log_Error_Kind,
	first_platform_error: i32,
	written:              u64,
	omitted:              u64,
}

// Log is one open writer. It lives at a stable address: every producer borrows
// its address, and it holds a mutex and a scratch buffer that must not be copied
// after it is opened.
Log :: struct {
	allocator:             mem.Allocator,

	// directory and run_id are owned by allocator.
	directory:             string,
	run_id:                string,
	open:                  bool,
	level:                 Log_Level,
	file:                  ^os.File,
	segment:               u32,
	// segment_bytes is the rollover bound; a test may lower it, and nothing else
	// changes it, so the default is the only bound a run sees.
	segment_bytes:         int,
	segment_bytes_written: int,
	sequence:              u64,
	start_tick:            time.Tick,
	start_time_ns:         i64,
	mutex:                 sync.Mutex,
	// scratch is the encoding buffer. It is writer-owned so an emit never
	// allocates, and it is only touched under mutex.
	scratch:               [LOG_MAX_RECORD_BYTES]u8,
	health:                Log_Health,
}

// log_open creates the run directory under options.directory and opens its first
// segment. An empty directory or a Disabled level opens nothing and succeeds:
// the caller then has a writer that records nothing, which is what a run with
// logging turned off wants. A failed open leaves nothing behind.
log_open :: proc(log: ^Log, options: Log_Options, allocator := context.allocator) -> Log_Error {
	if log.open { return log_error(.Invalid_State, "the log is already open") }
	if options.directory == "" || options.level == .Disabled { return nil }

	runs_directory, okay := log_path_join(options.directory, LOG_RUNS_DIRECTORY, allocator)
	if !okay { return log_error(.Allocation, "the runs directory path could not be built") }
	defer delete(runs_directory, allocator)

	// The runs directory is shared by every launch, so it is created as a parent
	// rather than claimed. An existing one is expected.
	if make_err := os.make_directory_all(runs_directory, LOG_DIRECTORY_PERMISSIONS); make_err != nil && make_err != .Exist {
		return log_error(.Create, "the logs directory could not be created")
	}

	succeeded := false
	defer if !succeeded {
		if log.file != nil {
			os.close(log.file)
			log.file = nil
		}
		// The run directory is this call's to remove until it succeeds.
		if log.directory != "" {
			os.remove_all(log.directory)
			delete(log.directory, log.allocator)
		}
		delete(log.run_id, log.allocator)
		log^ = {}
	}

	log.allocator = allocator
	log.level = options.level
	log.segment_bytes = LOG_SEGMENT_BYTES

	// The run directory is claimed exclusively, so two runs cannot write into one
	// another's directory. A collision draws a fresh id rather than adopting what
	// is already there.
	for _ in 0 ..< LOG_RUN_ID_ATTEMPTS {
		delete(log.run_id, allocator)
		log.run_id = log_run_id_create(allocator)
		if log.run_id == "" { break }
		candidate, candidate_okay := log_path_join(runs_directory, log.run_id, allocator)
		if !candidate_okay { break }
		make_err := os.make_directory(candidate, LOG_DIRECTORY_PERMISSIONS)
		if make_err == nil {
			log.directory = candidate
			break
		}
		delete(candidate, allocator)
		if make_err != .Exist { break }
	}
	if log.directory == "" { return log_error(.Create, "the run directory could not be created") }

	log.start_tick = time.tick_now()
	log.start_time_ns = time.time_to_unix_nano(time.now())
	if err := log_segment_create(log, 1); err != nil { return err }

	log.open = true
	succeeded = true
	return nil
}

// log_close closes the current segment and releases the run directory and run
// id. Closing a writer that was never opened, or one that is already closed, is
// a no-op.
log_close :: proc(log: ^Log) -> Log_Error {
	if log == nil || !log.open { return nil }

	result: Log_Error
	if log.file != nil {
		if close_err := os.close(log.file); close_err != nil {
			result = log_error(.Write, "the log segment could not be closed")
		}
	}
	allocator := log.allocator
	delete(log.directory, allocator)
	delete(log.run_id, allocator)
	log^ = {}
	return result
}

// log_health returns what the writer latched, which is how a caller learns that
// diagnostics stopped without every emit having to check.
log_health :: proc(log: ^Log) -> Log_Health {
	if log == nil { return {} }
	sync.mutex_lock(&log.mutex)
	defer sync.mutex_unlock(&log.mutex)
	return log.health
}

// log_emit writes one record. It never fails the caller: a broken sink is
// latched in the writer's health, and every later emit reports Failed without
// touching the file again.
log_emit :: proc(scope: Log_Context, record: Log_Record) -> Log_Emit_Result {
	log := scope.log
	if log == nil || !log.open { return .Disabled }
	if !log_records(log.level, record.level) { return .Filtered }

	sync.mutex_lock(&log.mutex)
	defer sync.mutex_unlock(&log.mutex)

	if log.health.failed { return .Failed }
	if !log_record_valid(record) {
		log.health.omitted += 1
		return .Rejected
	}

	log.sequence += 1
	length := log_encode(log, scope, record, log.sequence, log.scratch[:])
	result := Log_Emit_Result.Written
	if length == 0 {
		// An oversized record is replaced by one that names it, so the omission
		// is visible in the stream rather than only in the writer's counters.
		log.health.omitted += 1
		length = log_encode_omitted(log, scope, record, log.sequence, log.scratch[:])
		result = .Oversized
		if length == 0 { return .Rejected }
	}

	if !log_segment_ready(log, length) {
		log.health.failed = true
		log.health.first_error = .Create
		return .Failed
	}
	if write_err := log_write_all(log.file, log.scratch[:length]); write_err != nil {
		platform_error, is_platform := write_err.(os.Platform_Error)
		if !is_platform { platform_error = .NONE }
		log.health.failed = true
		log.health.first_error = .Write
		log.health.first_platform_error = i32(platform_error)
		return .Failed
	}

	log.segment_bytes_written += length
	log.health.written += 1
	return result
}

// --- encoding ----------------------------------------------------------------

// Log_Line is the fixed output buffer an encoder writes into. Once full is set
// every later write is dropped, so an encoder can run to completion and be told
// afterwards, by a zero length, that the record did not fit.
@(private)
Log_Line :: struct {
	buffer: []u8,
	length: int,
	full:   bool,
}

@(private)
log_line_byte :: proc(line: ^Log_Line, byte: u8) {
	if line.full { return }
	if line.length >= len(line.buffer) {
		line.full = true
		return
	}
	line.buffer[line.length] = byte
	line.length += 1
}

@(private)
log_line_bytes :: proc(line: ^Log_Line, bytes: string) {
	if line.full { return }
	source := transmute([]u8)bytes
	take := min(len(source), len(line.buffer) - line.length)
	copy(line.buffer[line.length:], source[:take])
	line.length += take
	if take < len(source) { line.full = true }
}

@(private)
log_line_int :: proc(line: ^Log_Line, value: i64) {
	// The longest i64 is 20 characters, so the buffer cannot be overrun and
	// bprintf cannot reach its builder's allocator.
	text: [24]u8
	log_line_bytes(line, fmt.bprintf(text[:], "%d", value))
}

@(private)
log_line_uint :: proc(line: ^Log_Line, value: u64) {
	// The longest u64 is 20 characters, for the same reason as log_line_int.
	text: [24]u8
	log_line_bytes(line, fmt.bprintf(text[:], "%d", value))
}

// log_line_json_string writes one JSON string, escaping what JSON requires and
// replacing a byte sequence that is not valid UTF-8 with U+FFFD rather than
// emitting a line no parser accepts.
@(private)
log_line_json_string :: proc(line: ^Log_Line, text: string) {
	replacement := [3]u8{0xEF, 0xBF, 0xBD}

	log_line_byte(line, '"')
	index := 0
	for index < len(text) {
		byte := text[index]
		switch {
		case byte == '"':
			log_line_bytes(line, `\"`)
			index += 1
		case byte == '\\':
			log_line_bytes(line, `\\`)
			index += 1
		case byte == '\n':
			log_line_bytes(line, `\n`)
			index += 1
		case byte == '\r':
			log_line_bytes(line, `\r`)
			index += 1
		case byte == '\t':
			log_line_bytes(line, `\t`)
			index += 1
		case byte == '\b':
			log_line_bytes(line, `\b`)
			index += 1
		case byte == '\f':
			log_line_bytes(line, `\f`)
			index += 1
		case byte < 0x20:
			// A control byte has no short escape, so it is written as \u00XX.
			log_line_bytes(line, `\u00`)
			log_line_byte(line, log_hex_digit(byte >> 4))
			log_line_byte(line, log_hex_digit(byte & 0x0F))
			index += 1
		case byte < 0x80:
			log_line_byte(line, byte)
			index += 1
		case:
			width := log_utf8_width(byte)
			if width == 0 || !log_utf8_valid_at(text, index, width) {
				log_line_bytes(line, string(replacement[:]))
				index += 1
				continue
			}
			log_line_bytes(line, text[index:index + width])
			index += width
		}
	}
	log_line_byte(line, '"')
}

// log_utf8_width is how many bytes the sequence a lead byte begins occupies, or
// zero when the byte cannot begin one. The shape is checked, not the standard it
// encodes: an overlong sequence is copied through rather than replaced, because a
// record is not where a producer's text gets repaired.
@(private)
log_utf8_width :: proc(lead: u8) -> int {
	switch {
	case lead < 0x80:
		return 1
	case lead >= 0xC2 && lead <= 0xDF:
		return 2
	case lead >= 0xE0 && lead <= 0xEF:
		return 3
	case lead >= 0xF0 && lead <= 0xF4:
		return 4
	}
	return 0
}

@(private)
log_utf8_valid_at :: proc(text: string, index, width: int) -> bool {
	if index + width > len(text) { return false }
	for offset in 1 ..< width {
		if text[index + offset] & 0xC0 != 0x80 { return false }
	}
	return true
}

@(private)
log_line_value :: proc(line: ^Log_Line, value: Log_Value) {
	switch scalar in value {
	case bool:
		log_line_bytes(line, scalar ? "true" : "false")
	case i64:
		log_line_int(line, scalar)
	case u64:
		log_line_uint(line, scalar)
	case string:
		log_line_json_string(line, scalar)
	}
}

@(private)
log_level_name :: proc(level: Log_Level) -> string {
	switch level {
	case .Disabled:
		return "disabled"
	case .Error:
		return "error"
	case .Warn:
		return "warn"
	case .Info:
		return "info"
	case .Debug:
		return "debug"
	case .Trace:
		return "trace"
	}
	return "disabled"
}

@(private)
log_category_name :: proc(category: Log_Category) -> string {
	switch category {
	case .Runtime:
		return "runtime"
	case .Session:
		return "session"
	case .Agent:
		return "agent"
	case .Provider:
		return "provider"
	case .Transport:
		return "transport"
	case .Tool:
		return "tool"
	case .MCP:
		return "mcp"
	case .Storage:
		return "storage"
	case .Diagnostics:
		return "diagnostics"
	}
	return "diagnostics"
}

// log_records reports whether a record at level is at or above the threshold.
@(private)
log_records :: proc(threshold, level: Log_Level) -> bool {
	return int(level) <= int(threshold)
}

// log_record_valid reports whether a record can be encoded at all. The envelope
// keys are reserved: a field that repeats one, or repeats another field, would
// make the line ambiguous for a reader.
@(private)
log_record_valid :: proc(record: Log_Record) -> bool {
	if record.level == .Disabled || record.event == "" { return false }
	for field, index in record.fields {
		if field.key == "" || log_key_reserved(field.key) { return false }
		for earlier in record.fields[:index] {
			if earlier.key == field.key { return false }
		}
	}
	return true
}

@(private)
log_key_reserved :: proc(key: string) -> bool {
	switch key {
	case "version",
	     "run_id",
	     "seq",
	     "time_unix_ns",
	     "elapsed_ns",
	     "thread_id",
	     "level",
	     "category",
	     "event",
	     "session_id",
	     "turn_no",
	     "request_no",
	     "attempt",
	     "operation_id":
		return true
	}
	return false
}

// log_encode writes one complete line, newline included, and returns its length.
// A zero length means the record did not fit the buffer.
@(private)
log_encode :: proc(log: ^Log, scope: Log_Context, record: Log_Record, sequence: u64, buffer: []u8) -> int {
	line := Log_Line {
		buffer = buffer,
	}
	log_line_byte(&line, '{')
	log_line_bytes(&line, `"version":`)
	log_line_uint(&line, u64(LOG_VERSION))
	log_line_bytes(&line, `,"run_id":`)
	log_line_json_string(&line, log.run_id)
	log_line_bytes(&line, `,"seq":`)
	log_line_uint(&line, sequence)
	log_line_bytes(&line, `,"time_unix_ns":`)
	log_line_int(&line, time.time_to_unix_nano(time.now()))
	log_line_bytes(&line, `,"elapsed_ns":`)
	log_line_int(&line, time.duration_nanoseconds(time.tick_since(log.start_tick)))
	log_line_bytes(&line, `,"thread_id":`)
	log_line_int(&line, i64(os.get_current_thread_id()))
	log_line_bytes(&line, `,"level":`)
	log_line_json_string(&line, log_level_name(record.level))
	log_line_bytes(&line, `,"category":`)
	log_line_json_string(&line, log_category_name(record.category))
	log_line_bytes(&line, `,"event":`)
	log_line_json_string(&line, record.event)
	if len(scope.session_id) > 0 {
		log_line_bytes(&line, `,"session_id":`)
		log_line_json_string(&line, string(scope.session_id))
	}
	if i64(scope.turn_no) != 0 {
		log_line_bytes(&line, `,"turn_no":`)
		log_line_int(&line, i64(scope.turn_no))
	}
	if i64(scope.request_no) != 0 {
		log_line_bytes(&line, `,"request_no":`)
		log_line_int(&line, i64(scope.request_no))
	}
	if scope.attempt != 0 {
		log_line_bytes(&line, `,"attempt":`)
		log_line_int(&line, i64(scope.attempt))
	}
	if scope.operation_id != 0 {
		log_line_bytes(&line, `,"operation_id":`)
		log_line_uint(&line, scope.operation_id)
	}
	for field in record.fields {
		log_line_byte(&line, ',')
		log_line_json_string(&line, field.key)
		log_line_byte(&line, ':')
		log_line_value(&line, field.value)
	}
	log_line_byte(&line, '}')
	log_line_byte(&line, '\n')
	if line.full { return 0 }
	return line.length
}

// log_encode_omitted writes the record that stands in for one that did not fit.
// It names the dropped event and how many fields it carried, which is what a
// reader needs to know that evidence is missing and what it was about.
@(private)
log_encode_omitted :: proc(log: ^Log, scope: Log_Context, record: Log_Record, sequence: u64, buffer: []u8) -> int {
	fields := [2]Log_Field{{key = "omitted_event", value = record.event}, {key = "omitted_fields", value = i64(len(record.fields))}}
	omitted := Log_Record {
		level    = record.level,
		category = record.category,
		event    = "log.record_omitted",
		fields   = fields[:],
	}
	return log_encode(log, scope, omitted, sequence, buffer)
}

// --- segment files -----------------------------------------------------------

// log_segment_create closes the current segment and opens number in its place. A
// new run calls it with one; a rollover calls it with the next number.
@(private)
log_segment_create :: proc(log: ^Log, number: u32) -> Log_Error {
	if log.file != nil {
		os.close(log.file)
		log.file = nil
	}
	name_buffer: [32]u8
	name := log_segment_name(number, name_buffer[:])
	path, okay := log_path_join(log.directory, name, log.allocator)
	if !okay { return log_error(.Allocation, "a log segment path could not be built") }
	defer delete(path, log.allocator)

	file, open_err := os.open(path, {.Write, .Create, .Excl}, LOG_FILE_PERMISSIONS)
	if open_err != nil { return log_error(.Create, "a log segment could not be created") }
	log.file = file
	log.segment = number
	log.segment_bytes_written = 0
	return nil
}

// log_segment_ready starts the next segment when the record about to be written
// would cross the rollover bound. The oldest segment is deleted only after the
// new one is open, so a failure to delete costs disk rather than leaving a hole
// in the numbering a reader would have no way to explain.
@(private)
log_segment_ready :: proc(log: ^Log, record_bytes: int) -> bool {
	if log.segment_bytes_written == 0 || log.segment_bytes_written + record_bytes <= log.segment_bytes {
		return true
	}
	next := log.segment + 1
	if err := log_segment_create(log, next); err != nil { return false }

	if next > LOG_SEGMENTS_PER_RUN {
		name_buffer: [32]u8
		name := log_segment_name(next - LOG_SEGMENTS_PER_RUN, name_buffer[:])
		if path, okay := log_path_join(log.directory, name, log.allocator); okay {
			// Best effort: a segment that cannot be removed is a retention
			// problem, never a reason to stop recording.
			os.remove(path)
			delete(path, log.allocator)
		}
	}
	return true
}

// log_segment_name writes the file name of one segment. Six digits keep the
// names sorting in creation order for far more segments than a run can hold.
@(private)
log_segment_name :: proc(number: u32, buffer: []u8) -> string {
	return fmt.bprintf(buffer, "%s%06d%s", LOG_SEGMENT_PREFIX, number, LOG_SEGMENT_SUFFIX)
}

@(private)
log_write_all :: proc(file: ^os.File, bytes: []u8) -> os.Error {
	remaining := bytes
	for len(remaining) > 0 {
		written, write_err := os.write(file, remaining)
		if write_err != nil {
			// The harness installs its signal handler without SA_RESTART, so an
			// interrupted write is expected rather than exceptional.
			if platform_error, is_platform := write_err.(os.Platform_Error); is_platform && platform_error == .EINTR {
				continue
			}
			return write_err
		}
		if written <= 0 { return os.General_Error.Broken_Pipe }
		remaining = remaining[written:]
	}
	return nil
}

@(private)
log_path_join :: proc(directory, name: string, allocator: mem.Allocator) -> (string, bool) {
	path, join_err := filepath.join([]string{directory, name}, allocator)
	if join_err != nil { return "", false }
	return path, true
}

@(private)
log_run_id_create :: proc(allocator: mem.Allocator) -> string {
	random: [16]u8
	if rand.read(random[:]) != len(random) { return "" }
	text: [LOG_RUN_ID_LENGTH]u8
	for byte, index in random {
		text[index * 2] = log_hex_digit(byte >> 4)
		text[index * 2 + 1] = log_hex_digit(byte & 0x0F)
	}
	return strings.clone(string(text[:]), allocator)
}

// log_hex_digit is the lowercase hexadecimal character of a nibble. It is
// arithmetic rather than a table because a string constant cannot be indexed by
// a runtime value.
@(private)
log_hex_digit :: proc(value: u8) -> u8 {
	return value < 10 ? '0' + value : 'a' + (value - 10)
}
