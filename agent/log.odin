package agent

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:time"

import "nabla:agent/journal"

// Diagnostics go through context.logger into a Diag_Ring: a fixed array of
// entries with inline text. Any thread may emit; an emit never allocates and never
// waits on I/O, and a full ring counts what it drops. Owners drain the ring into
// runtime.message records of their journal, so diagnostics live in the journal
// beside the facts they explain.

DIAG_RING_ENTRIES :: 512
DIAG_TEXT_MAX :: 512

// Log_Category names the part of the harness an entry came from.
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

LOG_CATEGORY_NAMES := [Log_Category]string {
	.Runtime     = "runtime",
	.Session     = "session",
	.Agent       = "agent",
	.Provider    = "provider",
	.Transport   = "transport",
	.Tool        = "tool",
	.MCP         = "mcp",
	.Storage     = "storage",
	.Diagnostics = "diagnostics",
}

// Log_Value is the closed set of scalar types a field may carry.
Log_Value :: union {
	bool,
	i64,
	u64,
	string,
}

// Log_Field is one named scalar, borrowed for the duration of the emit call.
Log_Field :: struct {
	key:   string,
	value: Log_Value,
}

// Log_Record is one event, borrowed for the duration of the emit call.
Log_Record :: struct {
	level:    log.Level,
	category: Log_Category,
	event:    string,
	fields:   []Log_Field,
}

// Log_Correlation is what an entry is emitted against. Zero fields are absent. The
// call id is borrowed for the emit call.
Log_Correlation :: struct {
	session: journal.Session_Id,
	turn:    journal.Turn_Id,
	request: journal.Request_Id,
	attempt: int,
	call_id: string,
}

// Diag_Entry is one emitted entry, copied whole into the ring.
Diag_Entry :: struct {
	time_ms:     i64,
	level:       log.Level,
	category:    Log_Category,
	thread:      int,
	session:     journal.Session_Id,
	turn:        journal.Turn_Id,
	request:     journal.Request_Id,
	attempt:     int,
	text_length: int,
	text:        [DIAG_TEXT_MAX]u8,
}

// Diag_Ring holds entries between their emit and an owner's drain. It must not
// move once a logger points at it. The zero value accepts every level.
Diag_Ring :: struct {
	mutex:   sync.Mutex,
	lowest:  log.Level,
	entries: [DIAG_RING_ENTRIES]Diag_Entry,
	first:   int,
	count:   int,
	dropped: u64,
}

// Log_Binding is the data a context.logger carries: the ring and the correlation.
// It lives at a caller-owned address that outlives every logger pointing at it.
Log_Binding :: struct {
	ring:        ^Diag_Ring,
	correlation: Log_Correlation,
}

// log_logger is the logger for binding; a binding without a ring logs nothing.
log_logger :: proc(binding: ^Log_Binding) -> log.Logger {
	if binding == nil || binding.ring == nil { return log.nil_logger() }
	return log.Logger{procedure = log_procedure, data = rawptr(binding), lowest_level = binding.ring.lowest}
}

// log_rebind fills binding from the installed logger with a new correlation and
// returns a logger borrowing it. Without a harness logger the active one is
// returned unchanged.
log_rebind :: proc(binding: ^Log_Binding, correlation: Log_Correlation) -> log.Logger {
	active := context.logger
	if active.procedure != log_procedure { return active }
	source := cast(^Log_Binding)active.data
	binding^ = Log_Binding {
		ring        = source.ring,
		correlation = correlation,
	}
	return log.Logger{procedure = log_procedure, data = rawptr(binding), lowest_level = active.lowest_level, options = active.options}
}

// log_active_ring is the ring the installed logger writes to, or nil.
log_active_ring :: proc() -> ^Diag_Ring {
	logger := context.logger
	if logger.procedure != log_procedure { return nil }
	return (cast(^Log_Binding)logger.data).ring
}

// log_enabled reports whether an entry at level would be kept, for a producer that
// must do measurable work before it can emit.
@(require_results)
log_enabled :: proc(level: log.Level) -> bool {
	logger := context.logger
	return logger.procedure == log_procedure && level >= logger.lowest_level
}

// log_procedure receives ordinary core:log calls. The text is kept with the
// caller's location.
@(private)
log_procedure :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	binding := cast(^Log_Binding)data
	if binding.ring == nil { return }
	entry := diag_entry_make(binding.correlation, level, .Runtime)
	writer := Diag_Text {
		entry = &entry,
	}
	diag_text_write(&writer, text)
	diag_text_write(&writer, " (")
	diag_text_write(&writer, location.file_path)
	diag_text_write(&writer, ":")
	buffer: [24]u8
	diag_text_write(&writer, strconv.write_int(buffer[:], i64(location.line), 10))
	diag_text_write(&writer, ")")
	diag_push(binding.ring, &entry)
}

// log_emit records one typed event against the installed logger's correlation.
// The entry's text is the event name followed by key=value fields.
log_emit :: proc(record: Log_Record) {
	logger := context.logger
	if logger.procedure != log_procedure || record.level < logger.lowest_level { return }
	binding := cast(^Log_Binding)logger.data
	if binding.ring == nil { return }
	entry := diag_entry_make(binding.correlation, record.level, record.category)
	writer := Diag_Text {
		entry = &entry,
	}
	diag_text_write(&writer, record.event)
	if binding.correlation.call_id != "" {
		diag_text_write(&writer, " call_id=")
		diag_text_write(&writer, binding.correlation.call_id)
	}
	for field in record.fields {
		diag_text_write(&writer, " ")
		diag_text_write(&writer, field.key)
		diag_text_write(&writer, "=")
		buffer: [24]u8
		switch value in field.value {
		case bool:
			diag_text_write(&writer, "true" if value else "false")
		case i64:
			diag_text_write(&writer, strconv.write_int(buffer[:], value, 10))
		case u64:
			diag_text_write(&writer, strconv.write_uint(buffer[:], value, 10))
		case string:
			diag_text_write(&writer, value)
		}
	}
	diag_push(binding.ring, &entry)
}

@(private)
diag_entry_make :: proc(correlation: Log_Correlation, level: log.Level, category: Log_Category) -> Diag_Entry {
	return Diag_Entry {
		time_ms = time.to_unix_nanoseconds(time.now()) / i64(time.Millisecond),
		level = level,
		category = category,
		thread = os.get_current_thread_id(),
		session = correlation.session,
		turn = correlation.turn,
		request = correlation.request,
		attempt = correlation.attempt,
	}
}

// Diag_Text appends to an entry's inline text and drops what does not fit.
@(private)
Diag_Text :: struct {
	entry: ^Diag_Entry,
}

@(private)
diag_text_write :: proc(writer: ^Diag_Text, text: string) {
	entry := writer.entry
	length := min(len(text), DIAG_TEXT_MAX - entry.text_length)
	copy(entry.text[entry.text_length:], text[:length])
	entry.text_length += length
}

// diag_push copies entry into the ring, or counts it dropped when the ring is full.
@(private)
diag_push :: proc(ring: ^Diag_Ring, entry: ^Diag_Entry) {
	sync.mutex_lock(&ring.mutex)
	defer sync.mutex_unlock(&ring.mutex)
	if ring.count == DIAG_RING_ENTRIES {
		ring.dropped += 1
		return
	}
	ring.entries[(ring.first + ring.count) % DIAG_RING_ENTRIES] = entry^
	ring.count += 1
}

// diag_pop takes the oldest entry, if any.
@(require_results)
diag_pop :: proc(ring: ^Diag_Ring, entry: ^Diag_Entry) -> bool {
	sync.mutex_lock(&ring.mutex)
	defer sync.mutex_unlock(&ring.mutex)
	if ring.count == 0 { return false }
	entry^ = ring.entries[ring.first]
	ring.first = (ring.first + 1) % DIAG_RING_ENTRIES
	ring.count -= 1
	return true
}

// diag_drain appends every waiting entry to store as a runtime.message record,
// buffered for the caller's next commit. An entry of another session is recorded
// without a session column and names its session in the payload. Owner thread only.
diag_drain :: proc(ring: ^Diag_Ring, store: ^journal.Journal) {
	if ring == nil || store == nil || !store.open || store.read_only { return }
	sync.mutex_lock(&ring.mutex)
	dropped := ring.dropped
	ring.dropped = 0
	sync.mutex_unlock(&ring.mutex)
	if dropped > 0 {
		text := fmt.tprintf("%d diagnostic entries were dropped because the ring was full", dropped)
		journal.append_record(store, {kind = .Runtime_Message}, journal.Runtime_Message{level = "warn", category = "diagnostics", text = text})
	}
	entry: Diag_Entry
	for diag_pop(ring, &entry) {
		header := journal.Record {
			kind    = .Runtime_Message,
			turn    = entry.turn,
			request = entry.request,
			attempt = journal.Attempt_No(entry.attempt),
		}
		message := journal.Runtime_Message {
			level    = log_level_name(entry.level),
			category = LOG_CATEGORY_NAMES[entry.category],
			thread   = entry.thread,
			time_ms  = entry.time_ms,
			text     = string(entry.text[:entry.text_length]),
		}
		hex_text: [journal.SESSION_ID_HEX_LENGTH]u8
		if entry.session == store.claimed {
			header.session = entry.session
		} else if entry.session != {} {
			message.session = journal.session_id_to_hex(entry.session, hex_text[:])
		}
		journal.append_record(store, header, message)
	}
}

// log_level_name is the name a level is written and configured by.
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

// log_level_parse reads a level name; "off" disables diagnostics.
@(require_results)
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
