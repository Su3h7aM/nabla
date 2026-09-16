package agent

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"

import "nabla:agent/session"

// A Log is one process run's diagnostic stream: JSON Lines records written
// synchronously under a mutex, one file per segment inside a private run
// directory. It records what the harness observed at named boundaries, which
// request was prepared, what was encoded, where a failure happened. It is not
// durable like the session database and never authoritative over it.
//
// The log owns its run directory, its segment file, and its run id. Everything a
// record borrows is consumed by the emit call and never retained, so a caller can
// record a string that lives on context.temp_allocator.
//
// The zero Log is closed and writes nothing, which is what a run with logging
// disabled keeps. Dispatch goes through Odin's own logger: log_logger in
// log_bridge.odin installs this writer into context.logger, so ordinary
// core:log calls and typed log_emit records reach the same sink.

LOG_VERSION :: 1

// LOG_MAX_RECORD_BYTES bounds one encoded record, newline included. A record
// that does not fit is replaced by a compact record that names the one that was
// dropped, so a producer mistake cannot turn a log line into unbounded memory.
LOG_MAX_RECORD_BYTES :: 64 * 1024

// LOG_MAX_TEXT_BYTES caps one string before escaping. It applies to field values,
// field keys, event names, and correlation identifiers: a record is a statement,
// not a place to dump a payload.
LOG_MAX_TEXT_BYTES :: 4 * 1024

// LOG_MAX_FIELDS bounds how many caller fields one record may carry, which bounds
// duplicate-key validation before encoding starts.
LOG_MAX_FIELDS :: 64

// LOG_SEGMENT_BYTES is how large one segment may grow before the next begins.
LOG_SEGMENT_BYTES :: 8 * 1024 * 1024

// LOG_SEGMENTS_PER_RUN is how many segments a run keeps. Starting the next one
// deletes the oldest, so a long run holds a bounded window of its own history
// rather than every record it ever wrote.
LOG_SEGMENTS_PER_RUN :: 4

// LOG_ROLLOVER_RESERVE is the room kept in a segment for the record that reports
// a removed segment, so the report never has to displace the record that caused
// the rollover.
LOG_ROLLOVER_RESERVE :: 512

LOG_RUN_ID_LENGTH :: 32

// LOG_RUN_ID_ATTEMPTS bounds how many run ids are tried before giving up. A
// collision needs two processes to draw the same 128 bits, so the loop exists to
// make the failure bounded rather than to expect it.
LOG_RUN_ID_ATTEMPTS :: 8

LOG_MAX_DETAIL :: 160

// LOG_RUNS_DIRECTORY is the directory inside the log root that holds one
// directory per run. LOG_DIRECTORY_NAME is the log root's own name.
LOG_RUNS_DIRECTORY :: "runs"
LOG_DIRECTORY_NAME :: "logs"
LOG_SEGMENT_PREFIX :: "events-"
LOG_SEGMENT_SUFFIX :: ".jsonl"
LOG_SEGMENT_DIGITS :: 6

// The log directory is private, and so is every file in it: a record can describe
// the user's work.
LOG_DIRECTORY_PERMISSIONS :: os.Permissions{.Read_User, .Write_User, .Execute_User}
LOG_FILE_PERMISSIONS :: os.Permissions{.Read_User, .Write_User}

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

// Log_Options is one run's diagnostic policy. A zero value opens nothing, which
// is what a disabled run keeps. Severity is Odin's own logger level, and
// enablement is a separate fact so "off" is not one of the severities.
Log_Options :: struct {
	directory: string,
	enabled:   bool,
	lowest:    log.Level,
}

// Log_Value is the closed set of scalar types a field may carry. It grows when a
// producer needs a type that is not here; a nested object, a raw JSON fragment,
// or a byte blob belongs in a payload capture, or nowhere in a record. The zero
// value is nil, which is not a field: a producer always sets its value.
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
	level:    log.Level,
	category: Log_Category,
	event:    string,
	fields:   []Log_Field,
}

// Log_Correlation is the correlation a record is emitted against. Every identity
// in it already exists in the harness, so the log keeps no second copy of
// anything it cannot read from the session itself. Identifiers are borrowed for
// one synchronous scope. A zero correlation is a run-level record, not a
// disabled log.
Log_Correlation :: struct {
	session_id:   session.Session_Id,
	turn_no:      session.Turn_No,
	request_no:   session.Request_No,
	attempt:      int,
	operation_id: u64,
	call_id:      string,
}

// Log_Binding is the data a context.logger carries: the sink to write to and the
// correlation to write against. It lives at a caller-owned address that outlives
// every log.Logger value pointing at it. It owns nothing and needs no release.
//
// A binding copied from an ambient logger through log_rebind is a snapshot: a
// nested scope gets its own, and mutating one never disturbs its parent.
Log_Binding :: struct {
	sink:        ^Log,
	correlation: Log_Correlation,
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
	// The run directory, a segment file, or a lock could not be created.
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
	// retention_failed counts runs a cleanup pass could not remove or measure.
	// retention_limited is set when the pass stopped at its scan bound, which
	// means the global targets were not evaluated over every run.
	retention_failed:     u64,
	retention_limited:    bool,
}

// Log_Cleanup_Summary is what one retention pass did. It is returned from
// log_open rather than written by it, because root emits it once the run's logger
// is installed, after run.started.
Log_Cleanup_Summary :: struct {
	deleted:      int,
	freed_bytes:  i64,
	failed:       int,
	unmeasured:   int,
	scan_limited: bool,
}

// Log_Segment_Range is one closed segment's sequence span, kept so the record
// that reports its removal can name the range a reader would otherwise see as a
// gap. The writer holds a small fixed ring of these, never an index that grows.
@(private)
Log_Segment_Range :: struct {
	number: u32,
	first:  u64,
	last:   u64,
	valid:  bool,
}

// Log is one open writer. It lives at a stable address: every binding borrows its
// address, and it holds a mutex and a scratch buffer that must not be copied
// after it is opened.
Log :: struct {
	allocator:             mem.Allocator,

	// directory and run_id are owned by allocator.
	directory:             string,
	run_id:                string,
	open:                  bool,
	lowest:                log.Level,
	file:                  ^os.File,
	// lease is held for the writer's whole life; it is what tells a later cleanup
	// that this run is not its to remove.
	lease:                 Log_Lock,
	segment:               u32,
	// segment_bytes is the rollover bound; a test may lower it, and nothing else
	// changes it, so the default is the only bound a run sees.
	segment_bytes:         int,
	segment_bytes_written: int,
	segment_records:       int,
	segment_first_seq:     u64,
	closed:                [LOG_SEGMENTS_PER_RUN]Log_Segment_Range,
	closed_next:           int,
	sequence:              u64,
	start_tick:            time.Tick,
	mutex:                 sync.Mutex,
	// scratch is the encoding buffer. It is writer-owned so an emit never
	// allocates, and it is only touched under mutex. rollover_scratch is separate
	// because a rollover happens after the caller's record is already encoded:
	// sharing one buffer would overwrite the record with the removal report.
	scratch:               [LOG_MAX_RECORD_BYTES]u8,
	rollover_scratch:      [LOG_ROLLOVER_RESERVE]u8,
	health:                Log_Health,
}

// log_open creates the run directory under options.directory and opens its first
// segment. A disabled writer opens nothing and succeeds, which is what a run with
// diagnostics turned off wants; every emit then writes nothing. A failed open
// leaves nothing behind.
//
// The returned summary reports what the retention pass did. The caller records it
// after installing the run's logger, so run.started stays the first record of a
// launch even when the pass collected something.
log_open :: proc(log: ^Log, options: Log_Options, allocator := context.allocator) -> (cleanup: Log_Cleanup_Summary, err: Log_Error) {
	if log.open { return {}, log_error(.Invalid_State, "the log is already open") }
	if !options.enabled || options.directory == "" { return {}, nil }

	runs_directory, runs_okay := log_path_join(options.directory, LOG_RUNS_DIRECTORY, allocator)
	if !runs_okay { return {}, log_error(.Allocation, "the runs directory path could not be built") }
	defer delete(runs_directory, allocator)
	// The runs directory is shared by every launch, so it is created as a parent
	// rather than claimed. An existing one is expected.
	if make_err := os.make_directory_all(runs_directory, LOG_DIRECTORY_PERMISSIONS); make_err != nil && make_err != .Exist {
		return {}, log_error(.Create, "the logs directory could not be created")
	}

	cleanup_path, cleanup_okay := log_path_join(options.directory, LOG_CLEANUP_LOCK_NAME, allocator)
	if !cleanup_okay { return {}, log_error(.Allocation, "the cleanup lock path could not be built") }
	defer delete(cleanup_path, allocator)
	// The cleanup lock is held while this run is created and while closed runs are
	// removed, so a cleaner can never meet a run directory that has no lease yet.
	// It is taken blocking because it is only ever held for one bounded pass.
	cleanup_lock, cleanup_err := log_lock_acquire(cleanup_path, true)
	if cleanup_err != nil { return {}, cleanup_err }
	defer log_lock_release(&cleanup_lock)

	succeeded := false
	defer if !succeeded {
		log_lock_release(&log.lease)
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
	log.lowest = options.lowest
	log.segment_bytes = LOG_SEGMENT_BYTES
	if claim_err := log_run_directory_claim(log, runs_directory); claim_err != nil { return {}, claim_err }

	log.start_tick = time.tick_now()
	if segment_err := log_segment_create(log, 1); segment_err != nil { return {}, segment_err }

	log.open = true
	succeeded = true

	// Closed runs are removed now, under the cleanup lock. The pass is reported
	// by the caller rather than here: the run's logger is not installed yet, and
	// run.started is the first record of the launch.
	cleanup = log_cleanup(options.directory, allocator)
	log.health.retention_failed = u64(cleanup.failed + cleanup.unmeasured)
	log.health.retention_limited = cleanup.scan_limited
	return cleanup, nil
}

// log_default_directory is where this application keeps its logs: the logs
// directory inside the state directory the XDG specification resolves. The result
// is owned by allocator.
log_default_directory :: proc(allocator := context.allocator) -> (string, Log_Error) {
	state_directory, state_err := xdg_directory(.State, allocator)
	if state_err != .None { return "", log_error(.Invalid_Argument, "the state directory could not be resolved") }
	defer delete(state_directory, allocator)
	directory, okay := log_path_join(state_directory, LOG_DIRECTORY_NAME, allocator)
	if !okay { return "", log_error(.Allocation, "the log directory path could not be built") }
	return directory, nil
}

// log_run_directory_claim creates a fresh run directory under runs_directory and
// takes its lease. The lease is what keeps a later cleanup from removing a run
// that is still alive, so a directory that cannot be leased is removed rather than
// left behind unleased.
@(private)
log_run_directory_claim :: proc(log: ^Log, runs_directory: string) -> Log_Error {
	allocator := log.allocator
	for _ in 0 ..< LOG_RUN_ID_ATTEMPTS {
		delete(log.run_id, allocator)
		log.run_id = log_run_id_create(allocator)
		if log.run_id == "" { return log_error(.Allocation, "a run id could not be created") }

		directory, directory_okay := log_path_join(runs_directory, log.run_id, allocator)
		if !directory_okay { return log_error(.Allocation, "the run directory path could not be built") }
		if make_err := os.make_directory(directory, LOG_DIRECTORY_PERMISSIONS); make_err != nil {
			delete(directory, allocator)
			// A collision means the id is taken, which is what the loop is for.
			if make_err != .Exist { return log_error(.Create, "the run directory could not be created") }
			continue
		}

		lease, lease_err := log_run_directory_lease(log, directory)
		if lease_err != nil {
			os.remove_all(directory)
			delete(directory, allocator)
			return lease_err
		}
		log.lease = lease
		log.directory = directory
		return nil
	}
	return log_error(.Create, "the run directory could not be created")
}

@(private)
log_run_directory_lease :: proc(log: ^Log, directory: string) -> (Log_Lock, Log_Error) {
	lease_path, lease_okay := log_path_join(directory, LOG_LEASE_NAME, log.allocator)
	if !lease_okay { return {}, log_error(.Allocation, "the lease path could not be built") }
	defer delete(lease_path, log.allocator)
	return log_lock_acquire(lease_path, false)
}

// log_close closes the current segment and releases the run directory and run
// id. Closing a writer that was never opened, or one that is already closed, is
// a no-op. No producer may call the writer after this returns.
log_close :: proc(log: ^Log) -> Log_Error {
	if log == nil || !log.open { return nil }

	result: Log_Error
	if log.file != nil {
		if close_err := os.close(log.file); close_err != nil {
			result = log_error(.Write, "the log segment could not be closed")
		}
		log.file = nil
	}
	// The lease goes last: until it is dropped, a cleanup cannot remove what this
	// writer still owns.
	log_lock_release(&log.lease)
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

// log_emit writes one typed record against the correlation of the active Nabla
// logger. It is the structured entry point: ordinary text goes through core:log
// and arrives at log_procedure instead.
//
// It never fails the caller: a broken sink is latched in the writer's health, and
// every later emit reports nothing new. A record that breaks its contract is
// counted as omitted, and one that does not fit becomes a compact omission
// record that names it.
log_emit :: proc(record: Log_Record) {
	logger := context.logger
	if logger.procedure != log_procedure { return }
	if record.level < logger.lowest_level { return }
	binding := cast(^Log_Binding)logger.data
	if binding == nil || binding.sink == nil { return }
	log_write(binding.sink, binding.correlation, record)
}

// log_write is the sink. It filters nothing: the caller already applied the
// threshold, and the writer's own metadata does not go through a filter at all.
@(private)
log_write :: proc(sink: ^Log, correlation: Log_Correlation, record: Log_Record) {
	log := sink
	if log == nil || !log.open { return }

	sync.mutex_lock(&log.mutex)
	defer sync.mutex_unlock(&log.mutex)

	if log.health.failed { return }
	if reason := log_record_reject(correlation, record); reason != .None {
		log.health.omitted += 1
		return
	}

	// The sequence is provisional until a rollover has had its say: a rollover that
	// reports a removed segment takes a sequence of its own first, so the record it
	// triggered stays after it in the file.
	sequence := log.sequence + 1
	length := log_encode(log, correlation, record, sequence, log.scratch[:])
	if length == 0 {
		// An oversized record is replaced by one that names it, so the omission
		// is visible in the stream rather than only in the writer's counters.
		log.health.omitted += 1
		length = log_encode_omitted(log, correlation, record, sequence, log.scratch[:])
		if length == 0 { return }
	}

	rolled_okay, rolled := log_roll_if_needed(log, length)
	if !rolled_okay {
		log.health.failed = true
		log.health.first_error = .Write
		return
	}
	if rolled {
		sequence = log.sequence + 1
		length = log_encode(log, correlation, record, sequence, log.scratch[:])
		if length == 0 {
			length = log_encode_omitted(log, correlation, record, sequence, log.scratch[:])
			if length == 0 { return }
		}
	}

	if write_err := log_write_all(log.file, log.scratch[:length]); write_err != nil {
		platform_error, is_platform := write_err.(os.Platform_Error)
		if !is_platform { platform_error = .NONE }
		log.health.failed = true
		log.health.first_error = .Write
		log.health.first_platform_error = i32(platform_error)
		return
	}

	log.sequence = sequence
	log_segment_account(log, sequence, length)
	log.health.written += 1
}

// log_segment_account records that one record landed in the current segment.
@(private)
log_segment_account :: proc(log: ^Log, sequence: u64, length: int) {
	if log.segment_records == 0 { log.segment_first_seq = sequence }
	log.segment_records += 1
	log.segment_bytes_written += length
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

// log_line_json_string writes one JSON string. Bytes that do not encode a single
// Unicode scalar value are replaced with U+FFFD, rather than being copied
// through, so every line in the file is valid UTF-8 and valid JSON.
//
// The decoder is the standard library's: hand-rolled continuation checks accept
// overlong encodings, surrogate halves, and values above U+10FFFF, none of which
// are valid UTF-8.
@(private)
log_line_json_string :: proc(line: ^Log_Line, text: string) {
	replacement := [3]u8{0xEF, 0xBF, 0xBD}

	log_line_byte(line, '"')
	rest := text
	for len(rest) > 0 {
		if line.full { break }
		r := rune(rest[0])
		width := 1
		if r >= utf8.RUNE_SELF {
			r, width = utf8.decode_rune_in_string(rest)
		}
		if width == 1 && r == utf8.RUNE_ERROR && rest[0] >= utf8.RUNE_SELF {
			// One invalid byte. Advancing by one keeps the rest of the string
			// examined, so a later valid sequence is not lost with it.
			log_line_bytes(line, string(replacement[:]))
			rest = rest[1:]
			continue
		}
		switch {
		case r == '"':
			log_line_bytes(line, `\"`)
		case r == '\\':
			log_line_bytes(line, `\\`)
		case r == '\n':
			log_line_bytes(line, `\n`)
		case r == '\r':
			log_line_bytes(line, `\r`)
		case r == '\t':
			log_line_bytes(line, `\t`)
		case r == '\b':
			log_line_bytes(line, `\b`)
		case r == '\f':
			log_line_bytes(line, `\f`)
		case r < 0x20:
			// A control byte has no short escape, so it is written as \u00XX.
			log_line_bytes(line, `\u00`)
			log_line_byte(line, log_hex_digit(u8(r) >> 4))
			log_line_byte(line, log_hex_digit(u8(r) & 0x0F))
		case:
			log_line_bytes(line, rest[:width])
		}
		rest = rest[width:]
	}
	log_line_byte(line, '"')
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

// log_level_name is the name a level is written and configured by. The values are
// part of the record format, so they never change even though the type is Odin's.
log_level_name :: proc(level: log.Level) -> string {
	switch level {
	case .Debug:
		return "debug"
	case .Info:
		return "info"
	case .Warning:
		return "warn"
	case .Error:
		return "error"
	case .Fatal:
		return "fatal"
	}
	return "info"
}

// log_level_parse reads a level name. It accepts exactly what log_level_name
// writes, plus "off", which disables the writer rather than selecting a severity.
log_level_parse :: proc(name: string) -> (level: log.Level, enabled: bool, known: bool) {
	switch name {
	case "off":
		return .Info, false, true
	case "error":
		return .Error, true, true
	case "warn":
		return .Warning, true, true
	case "info":
		return .Info, true, true
	case "debug":
		return .Debug, true, true
	case "fatal":
		return .Fatal, true, true
	}
	return .Info, false, false
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

// Log_Reject is why a record is not encodable. None means it is. Rejected records
// are dropped and counted; Oversized ones get the compact omission record instead.
@(private)
Log_Reject :: enum {
	None,
	Rejected,
	Oversized,
}

// log_record_reject checks the part of the contract an encoder cannot enforce.
// The envelope keys are reserved: a field that repeats one, or repeats another
// field, would make the line ambiguous for a reader.
@(private)
log_record_reject :: proc(correlation: Log_Correlation, record: Log_Record) -> Log_Reject {
	if record.event == "" { return .Rejected }
	if len(record.event) > LOG_MAX_TEXT_BYTES { return .Rejected }
	if len(record.fields) > LOG_MAX_FIELDS { return .Rejected }
	if len(correlation.session_id) > LOG_MAX_TEXT_BYTES { return .Rejected }
	if len(correlation.call_id) > LOG_MAX_TEXT_BYTES { return .Rejected }
	oversized := false
	for field, index in record.fields {
		if field.key == "" || log_key_reserved(field.key) { return .Rejected }
		if len(field.key) > LOG_MAX_TEXT_BYTES { return .Rejected }
		for earlier in record.fields[:index] {
			if earlier.key == field.key { return .Rejected }
		}
		switch value in field.value {
		case bool, i64, u64:
		case string:
			// A string over the cap is a well-formed record the writer refuses to
			// store whole, so it becomes an omission rather than a rejection.
			if len(value) > LOG_MAX_TEXT_BYTES { oversized = true }
		case:
			// An unset value is not a field. JSON null is not part of the contract.
			return .Rejected
		}
	}
	return oversized ? .Oversized : .None
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
	     "operation_id",
	     "call_id":
		return true
	}
	return false
}

// log_encode writes one complete line, newline included, and returns its length.
// A zero length means the record did not fit the buffer.
@(private)
log_encode :: proc(log: ^Log, correlation: Log_Correlation, record: Log_Record, sequence: u64, buffer: []u8) -> int {
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
	if len(correlation.session_id) > 0 {
		log_line_bytes(&line, `,"session_id":`)
		log_line_json_string(&line, string(correlation.session_id))
	}
	if i64(correlation.turn_no) != 0 {
		log_line_bytes(&line, `,"turn_no":`)
		log_line_int(&line, i64(correlation.turn_no))
	}
	if i64(correlation.request_no) != 0 {
		log_line_bytes(&line, `,"request_no":`)
		log_line_int(&line, i64(correlation.request_no))
	}
	if correlation.attempt != 0 {
		log_line_bytes(&line, `,"attempt":`)
		log_line_int(&line, i64(correlation.attempt))
	}
	if correlation.operation_id != 0 {
		log_line_bytes(&line, `,"operation_id":`)
		log_line_uint(&line, correlation.operation_id)
	}
	if correlation.call_id != "" {
		log_line_bytes(&line, `,"call_id":`)
		log_line_json_string(&line, correlation.call_id)
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
log_encode_omitted :: proc(log: ^Log, correlation: Log_Correlation, record: Log_Record, sequence: u64, buffer: []u8) -> int {
	fields := [2]Log_Field{{key = "omitted_event", value = log_bounded_text(record.event)}, {key = "omitted_fields", value = i64(len(record.fields))}}
	omitted := Log_Record {
		level    = record.level,
		category = record.category,
		event    = "log.record_omitted",
		fields   = fields[:],
	}
	return log_encode(log, correlation, omitted, sequence, buffer)
}

// log_bounded_text trims a value to the scalar cap so the fallback record itself
// fits. It is used only for text that was already rejected as oversized.
@(private)
log_bounded_text :: proc(text: string) -> string {
	if len(text) <= LOG_MAX_TEXT_BYTES { return text }
	return text[:LOG_MAX_TEXT_BYTES]
}

// --- segment files -----------------------------------------------------------

// log_segment_create closes the current segment and opens number in its place. A
// new run calls it with one; a rollover calls it with the next number.
@(private)
log_segment_create :: proc(log: ^Log, number: u32) -> Log_Error {
	if log.file != nil {
		close_err := os.close(log.file)
		log.file = nil
		if close_err != nil { return log_error(.Write, "the previous log segment could not be closed") }
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
	log.segment_records = 0
	log.segment_first_seq = 0
	return nil
}

// log_roll_if_needed starts the next segment when the record about to be written
// would cross the rollover bound, keeping room for the removal report. rolled
// reports that a new segment was opened, which means a sequence may have been
// spent on the removal report. okay is false only when the next segment could not
// be created.
@(private)
log_roll_if_needed :: proc(log: ^Log, record_bytes: int) -> (okay: bool, rolled: bool) {
	if log.segment_bytes_written == 0 { return true, false }
	if log.segment_bytes_written + record_bytes + LOG_ROLLOVER_RESERVE <= log.segment_bytes { return true, false }

	closed_number := log.segment
	if log.segment_records > 0 {
		log_remember_closed(log, closed_number, log.segment_first_seq, log.sequence)
	}
	next := closed_number + 1
	if err := log_segment_create(log, next); err != nil { return false, false }
	return true, log_report_removed(log, next)
}

// log_report_removed writes the record that names the segment the window is about
// to drop, and then drops it. The record is about a segment that no longer exists
// once the deletion succeeds, so it carries the removed sequence range: a reader
// that sees a numbering gap can tell retention from loss.
//
// It is written through the writer itself, not through log_emit, so it is never
// filtered and never re-enters the rollover logic. It reports whether it wrote
// anything, which is what tells the caller that a sequence was spent.
@(private)
log_report_removed :: proc(log: ^Log, next: u32) -> bool {
	if next <= LOG_SEGMENTS_PER_RUN { return false }
	drop := next - LOG_SEGMENTS_PER_RUN
	range, found := log_take_closed(log, drop)
	if !found { return false }

	name_buffer: [32]u8
	name := log_segment_name(drop, name_buffer[:])
	path, okay := log_path_join(log.directory, name, log.allocator)
	if !okay { return false }

	removed := false
	if remove_err := os.remove(path); remove_err == nil {
		removed = true
	} else if remove_err != os.General_Error.Not_Exist {
		log.health.retention_failed += 1
	}
	delete(path, log.allocator)

	log.sequence += 1
	fields := [4]Log_Field {
		{key = "segment", value = i64(range.number)},
		{key = "from_seq", value = range.first},
		{key = "to_seq", value = range.last},
		{key = "removed", value = removed},
	}
	record := Log_Record {
		level    = .Info,
		category = .Diagnostics,
		event    = "log.segment_removed",
		fields   = fields[:],
	}
	length := log_encode(log, Log_Correlation{}, record, log.sequence, log.rollover_scratch[:])
	if length == 0 { return false }
	if write_err := log_write_all(log.file, log.rollover_scratch[:length]); write_err != nil {
		platform_error, is_platform := write_err.(os.Platform_Error)
		if !is_platform { platform_error = .NONE }
		log.health.failed = true
		log.health.first_error = .Write
		log.health.first_platform_error = i32(platform_error)
		return false
	}
	log_segment_account(log, log.sequence, length)
	return true
}

// log_remember_closed records one closed segment's sequence span in the writer's
// fixed ring, so a later rollover can name what it removes.
@(private)
log_remember_closed :: proc(log: ^Log, number: u32, first, last: u64) {
	log.closed[log.closed_next] = Log_Segment_Range {
		number = number,
		first  = first,
		last   = last,
		valid  = true,
	}
	log.closed_next = (log.closed_next + 1) % LOG_SEGMENTS_PER_RUN
}

// log_take_closed returns and clears the remembered span of one segment number.
@(private)
log_take_closed :: proc(log: ^Log, number: u32) -> (Log_Segment_Range, bool) {
	for &entry in log.closed {
		if entry.valid && entry.number == number {
			found := entry
			entry = {}
			return found, true
		}
	}
	return {}, false
}

// log_segment_name writes the file name of one segment. Six digits keep the names
// sorting in creation order far past the segments a run can hold; a longer number
// simply prints its extra digits, and the reader parses the number rather than
// assuming the width.
@(private)
log_segment_name :: proc(number: u32, buffer: []u8) -> string {
	return fmt.bprintf(buffer, "%s%06d%s", LOG_SEGMENT_PREFIX, number, LOG_SEGMENT_SUFFIX)
}

// log_segment_name_number parses the number a writer-produced segment name
// carries. It reports false for anything that is not one, so a directory entry a
// peer left there is never treated as a segment.
log_segment_name_number :: proc(name: string) -> (number: u64, ok: bool) {
	if !strings.has_prefix(name, LOG_SEGMENT_PREFIX) { return 0, false }
	if !strings.has_suffix(name, LOG_SEGMENT_SUFFIX) { return 0, false }
	digits := name[len(LOG_SEGMENT_PREFIX):len(name) - len(LOG_SEGMENT_SUFFIX)]
	if len(digits) < LOG_SEGMENT_DIGITS { return 0, false }
	if len(digits) > 1 && digits[0] == '0' && len(digits) != LOG_SEGMENT_DIGITS { return 0, false }
	for index in 0 ..< len(digits) {
		if digits[index] < '0' || digits[index] > '9' { return 0, false }
	}
	value, parse_ok := log_parse_uint(digits)
	if !parse_ok { return 0, false }
	return value, true
}

@(private)
log_parse_uint :: proc(digits: string) -> (u64, bool) {
	value: u64
	for index in 0 ..< len(digits) {
		digit := u64(digits[index] - '0')
		if value > (max(u64) - digit) / 10 { return 0, false }
		value = value * 10 + digit
	}
	return value, true
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

// log_run_id_create draws 128 bits from the operating system's entropy source. A
// run id is a directory name and a record field, so a guessable one would let a
// peer predict where records land. It returns "" when entropy is unavailable,
// which disables diagnostics rather than falling back to a weaker identity.
@(private)
log_run_id_create :: proc(allocator: mem.Allocator) -> string {
	random: [16]u8
	file, open_err := os.open("/dev/urandom")
	if open_err != nil { return "" }
	defer os.close(file)
	read := 0
	for read < len(random) {
		count, read_err := os.read(file, random[read:])
		if read_err != nil || count <= 0 { return "" }
		read += count
	}
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
