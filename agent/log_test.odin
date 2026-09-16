#+test
package agent

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent/session"

// The writer is tested from the inside: a test lowers the rollover bound and
// reads the segments it wrote, because the file layout and the encoded line are
// the contract a later reader depends on.
//
// A test is a scope like any other, so it installs its own logger: the binding
// lives for the test and context.logger points at it for the rest of the body.

Log_Test :: struct {
	directory: string,
	log:       Log,
}

log_test_begin :: proc(t: ^testing.T, fixture: ^Log_Test, lowest := log.Level.Info) {
	directory, directory_err := os.make_directory_temp("", "nabla-log-test-*", context.allocator)
	if directory_err != nil { testing.fail_now(t, "could not create a temporary directory") }
	fixture.directory = directory

	_, open_err := log_open(&fixture.log, {directory = directory, enabled = true, lowest = lowest})
	if open_err != nil {
		local := open_err
		testing.fail_now(t, strings.concatenate({"log_open failed: ", log_error_detail(&local)}, context.temp_allocator))
	}
}

log_test_end :: proc(t: ^testing.T, fixture: ^Log_Test) {
	_ = log_close(&fixture.log)
	os.remove_all(fixture.directory)
	delete(fixture.directory, context.allocator)
	fixture^ = {}
}

// log_test_narrow_scope installs a nested binding for its own call, which is what
// proves a nested scope does not disturb its parent's correlation.
log_test_narrow_scope :: proc(session_id: string) {
	inner: Log_Binding
	context.logger = log_rebind(&inner, Log_Correlation{session_id = session.Session_Id(session_id), turn_no = 4})
	log_emit({level = .Info, category = .Agent, event = "agent.transition"})
}

// log_test_install points context.logger at a binding for this test scope. The
// binding is returned to the caller, which is what gives it a lifetime.
log_test_install :: proc(fixture: ^Log_Test, correlation := Log_Correlation{}) -> Log_Binding {
	return Log_Binding{sink = &fixture.log, correlation = correlation}
}

log_test_path :: proc(fixture: ^Log_Test, segment: u32) -> string {
	return log_test_directory_segment(fixture.log.directory, segment)
}

// log_test_directory_segment is the path of one segment in a run directory, which
// is what a test needs when it works with a run that is not the fixture's own.
log_test_directory_segment :: proc(directory: string, segment: u32) -> string {
	name_buffer: [32]u8
	name := log_segment_name(segment, name_buffer[:])
	path, _ := log_path_join(directory, name, context.temp_allocator)
	return path
}

// log_test_text reads one file into caller-owned memory, released with
// delete(text, context.allocator).
log_test_text :: proc(t: ^testing.T, path: string) -> string {
	content, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil { testing.fail_now(t, "the log segment could not be read") }
	return string(content)
}

// log_test_segment_text reads one segment of the fixture's run.
log_test_segment_text :: proc(t: ^testing.T, fixture: ^Log_Test, segment: u32) -> string {
	return log_test_text(t, log_test_path(fixture, segment))
}

// log_test_contains_all reports the first needle the text does not carry, so a
// failure names what is missing rather than only that something is.
log_test_expect_all :: proc(t: ^testing.T, text: string, needles: []string, what: string) {
	for needle in needles {
		testing.expectf(t, strings.contains(text, needle), "%s should contain %q", what, needle)
	}
}

@(test)
test_log_open_claims_a_private_run_directory :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	testing.expect_value(t, len(fixture.log.run_id), LOG_RUN_ID_LENGTH)
	info, stat_err := os.stat(fixture.log.directory, context.temp_allocator)
	if stat_err != nil { testing.fail_now(t, "the run directory was not created") }
	testing.expect(t, info.mode == LOG_DIRECTORY_PERMISSIONS, "the run directory should be owner-only")

	segment_info, segment_err := os.stat(log_test_path(&fixture, 1), context.temp_allocator)
	if segment_err != nil { testing.fail_now(t, "the first segment was not created") }
	testing.expect(t, segment_info.mode == LOG_FILE_PERMISSIONS, "a segment should be owner-only")

	// A writer already open cannot be opened again: that would abandon the run
	// directory it owns.
	_, reopen_err := log_open(&fixture.log, {directory = fixture.directory, enabled = true, lowest = .Info})
	testing.expect_value(t, log_error_kind(reopen_err), Log_Error_Kind.Invalid_State)
}

@(test)
test_log_open_disabled_records_nothing :: proc(t: ^testing.T) {
	log: Log
	cleanup, open_err := log_open(&log, {})
	testing.expect(t, open_err == nil, "a disabled writer still opens")
	testing.expect(t, !log.open, "a disabled writer should own nothing")
	testing.expect_value(t, cleanup.deleted, 0)

	// A binding to a writer that never opened produces the no-op logger, so the
	// emit is a no-op rather than a write somewhere.
	binding := Log_Binding {
		sink = &log,
	}
	context.logger = log_logger(&binding)
	log_emit({level = .Error, category = .Runtime, event = "run.started"})
	testing.expect_value(t, log_health(&log).written, u64(0))
	testing.expect(t, log_close(&log) == nil, "closing a writer that opened nothing succeeds")
}

@(test)
test_log_emit_writes_one_record :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	binding := log_test_install(
		&fixture,
		{session_id = session.Session_Id("0123456789abcdef0123456789abcdef"), turn_no = 3, request_no = 6, attempt = 1, operation_id = 12},
	)
	context.logger = log_logger(&binding)

	fields := [2]Log_Field{{key = "api", value = "openai_chat_completions"}, {key = "body_bytes", value = i64(174381)}}
	log_emit({level = .Info, category = .Provider, event = "provider.encoded", fields = fields[:]})

	text := log_test_segment_text(t, &fixture, 1)
	defer delete(text, context.allocator)
	testing.expect_value(t, strings.count(text, "\n"), 1)
	testing.expect(t, strings.has_prefix(text, "{") && strings.has_suffix(text, "}\n"), "a record is one JSON object and a newline")
	log_test_expect_all(
		t,
		text,
		{
			`"version":1`,
			`"level":"info"`,
			`"category":"provider"`,
			`"event":"provider.encoded"`,
			`"seq":1`,
			`"session_id":"0123456789abcdef0123456789abcdef"`,
			`"turn_no":3`,
			`"request_no":6`,
			`"attempt":1`,
			`"operation_id":12`,
			`"body_bytes":174381`,
			`"api":"openai_chat_completions"`,
		},
		"a written record",
	)
	testing.expect_value(t, log_health(&fixture.log).written, u64(1))
}

@(test)
test_log_emit_omits_unset_correlation :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	// Zero correlation is a run-level record, not a disabled one.
	binding := log_test_install(&fixture)
	context.logger = log_logger(&binding)
	log_emit({level = .Info, category = .Agent, event = "agent.transition"})

	text := log_test_segment_text(t, &fixture, 1)
	defer delete(text, context.allocator)
	for absent in ([]string{`"session_id"`, `"turn_no"`, `"request_no"`, `"attempt"`, `"operation_id"`}) {
		testing.expectf(t, !strings.contains(text, absent), "%s should be omitted when unset", absent)
	}
	testing.expect_value(t, log_health(&fixture.log).written, u64(1))
}

@(test)
test_log_emit_escapes_a_string_field :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	binding := log_test_install(&fixture)
	context.logger = log_logger(&binding)

	// Valid ASCII, an invalid UTF-8 byte, a quote, a backslash, and a control
	// byte: everything that must not reach the file verbatim.
	raw := [5]u8{'a', 0xFF, '"', '\\', 0x01}
	control := [1]u8{0x01}
	replacement := [3]u8{0xEF, 0xBF, 0xBD}
	fields := [1]Log_Field{{key = "detail", value = string(raw[:])}}
	log_emit({level = .Warning, category = .Provider, event = "test.escape", fields = fields[:]})

	text := log_test_segment_text(t, &fixture, 1)
	defer delete(text, context.allocator)
	testing.expect_value(t, strings.count(text, "\n"), 1)
	log_test_expect_all(t, text, {`\"`, `\\`, `\u0001`}, "the escaped record")
	testing.expect(t, !strings.contains(text, string(control[:])), "no raw control byte reaches the file")
	testing.expect(t, strings.contains(text, string(replacement[:])), "invalid UTF-8 becomes the replacement character")
}

// test_log_emit_rejects_illegal_utf8 covers the sequences a shape-only
// continuation check accepts: an overlong encoding, a UTF-16 surrogate half, and a
// code point past U+10FFFF. None is valid UTF-8, so none may reach the file.
@(test)
test_log_emit_rejects_illegal_utf8 :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	binding := log_test_install(&fixture)
	context.logger = log_logger(&binding)

	cases := [?]struct {
		name: string,
		raw:  []u8,
	} {
		{"overlong two-byte", []u8{0xC0, 0xAF}},
		{"overlong three-byte", []u8{0xE0, 0x80, 0xAF}},
		{"overlong four-byte", []u8{0xF0, 0x80, 0x80, 0xAF}},
		{"surrogate half", []u8{0xED, 0xA0, 0x80}},
		{"above U+10FFFF", []u8{0xF4, 0x90, 0x80, 0x80}},
		{"truncated sequence", []u8{0xE2, 0x82}},
	}
	// A valid ASCII byte on each side of each sequence shows that only the bad
	// sequence is replaced and the rest of the string survives with it.
	for probe in cases {
		raw := make([dynamic]u8, 0, len(probe.raw) + 2, context.temp_allocator)
		append(&raw, '[')
		append(&raw, ..probe.raw)
		append(&raw, ']')
		fields := [1]Log_Field{{key = "text", value = string(raw[:])}}
		log_emit({level = .Info, category = .Agent, event = "test.utf8", fields = fields[:]})
	}

	text := log_test_segment_text(t, &fixture, 1)
	defer delete(text, context.allocator)
	// Every replacement also shows on its own, so the count proves one replacement
	// per bad sequence rather than an accidental run of them.
	testing.expect_value(t, strings.count(text, `"text":"[`), len(cases))
	testing.expect_value(t, strings.count(text, `]"`), len(cases))
	for probe in cases {
		testing.expectf(t, !strings.contains(text, string(probe.raw)), "%s should not reach the file", probe.name)
	}
	replacement := [3]u8{0xEF, 0xBF, 0xBD}
	testing.expect_value(t, strings.count(text, string(replacement[:])), len(cases))
}

@(test)
test_log_emit_keeps_a_valid_replacement_character :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	binding := log_test_install(&fixture)
	context.logger = log_logger(&binding)
	valid := "\uFFFD"
	fields := [1]Log_Field{{key = "text", value = valid}}
	log_emit({level = .Info, category = .Agent, event = "test.utf8", fields = fields[:]})

	text := log_test_segment_text(t, &fixture, 1)
	defer delete(text, context.allocator)
	testing.expect(t, strings.contains(text, valid), "a valid U+FFFD is data, not an error")
}

@(test)
test_log_emit_filters_below_the_threshold :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	binding := log_test_install(&fixture)
	context.logger = log_logger(&binding)
	testing.expect(t, !log_enabled(.Debug), "a threshold question is answered from the active logger")
	log_emit({level = .Debug, category = .Agent, event = "agent.transition"})
	testing.expect(t, log_enabled(.Info), "a record at the threshold is enabled")
	log_emit({level = .Info, category = .Agent, event = "agent.transition"})

	text := log_test_segment_text(t, &fixture, 1)
	defer delete(text, context.allocator)
	testing.expect_value(t, strings.count(text, "\n"), 1)
	testing.expect_value(t, log_health(&fixture.log).written, u64(1))
	testing.expect_value(t, log_health(&fixture.log).omitted, u64(0))
}

@(test)
test_log_rejects_a_record_that_breaks_its_contract :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	binding := log_test_install(&fixture)
	context.logger = log_logger(&binding)

	log_emit({level = .Info, category = .Agent}) // no event
	log_emit({level = .Info, category = .Agent, event = "agent.transition", fields = []Log_Field{{key = "event", value = "shadowed"}}})
	log_emit(
		{level = .Info, category = .Agent, event = "agent.transition", fields = []Log_Field{{key = "key", value = "first"}, {key = "key", value = "second"}}},
	)
	// Unset is not a value: JSON null is not part of the field contract.
	log_emit({level = .Info, category = .Agent, event = "agent.transition", fields = []Log_Field{{key = "key"}}})
	// An oversized event name is refused rather than truncated, because the name is
	// an identifier rather than a payload.
	long := strings.repeat("x", LOG_MAX_TEXT_BYTES + 1, context.temp_allocator)
	log_emit({level = .Info, category = .Agent, event = long})

	testing.expect_value(t, log_health(&fixture.log).omitted, u64(5))
	testing.expect_value(t, log_health(&fixture.log).written, u64(0))
	text := log_test_segment_text(t, &fixture, 1)
	defer delete(text, context.allocator)
	testing.expect_value(t, len(text), 0)
}

@(test)
test_log_replaces_an_oversized_record_with_an_omission :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	binding := log_test_install(&fixture)
	context.logger = log_logger(&binding)

	large := strings.repeat("x", LOG_MAX_RECORD_BYTES, context.temp_allocator)
	fields := [1]Log_Field{{key = "text", value = large}}
	log_emit({level = .Info, category = .Agent, event = "agent.transition", fields = fields[:]})

	text := log_test_segment_text(t, &fixture, 1)
	defer delete(text, context.allocator)
	testing.expect(t, len(text) < LOG_MAX_RECORD_BYTES, "the omission record must fit the bound")
	log_test_expect_all(t, text, {`"event":"log.record_omitted"`, `"omitted_event":"agent.transition"`, `"omitted_fields":1`}, "the omission record")
	testing.expect_value(t, log_health(&fixture.log).omitted, u64(1))
	testing.expect_value(t, log_health(&fixture.log).written, u64(1))
}

@(test)
test_log_sequence_increases_with_every_record :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	binding := log_test_install(&fixture)
	context.logger = log_logger(&binding)
	for _ in 0 ..< 3 {
		log_emit({level = .Info, category = .Agent, event = "agent.transition"})
	}

	text := log_test_segment_text(t, &fixture, 1)
	defer delete(text, context.allocator)
	log_test_expect_all(t, text, {`"seq":1`, `"seq":2`, `"seq":3`}, "three records")
	testing.expect_value(t, log_health(&fixture.log).written, u64(3))
}

// test_log_rollover_reports_removed_segments holds the rollover to the contract a
// reader depends on: a bounded window, and a record naming the sequence range that
// left it, so a numbering gap is never mistaken for loss.
@(test)
test_log_rollover_reports_removed_segments :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	// The emit phase is its own scope: the logger is installed for it and restored
	// before anything is read, so the assertions below cannot feed records back
	// into the file they are checking.
	{
		// A lowered bound makes this a test of the window rather than of throughput.
		fixture.log.segment_bytes = 1024
		binding := log_test_install(&fixture)
		context.logger = log_logger(&binding)
		fields := [1]Log_Field{{key = "note", value = "rollover"}}
		for _ in 0 ..< 400 {
			if fixture.log.segment > LOG_SEGMENTS_PER_RUN + 1 { break }
			log_emit({level = .Info, category = .Agent, event = "agent.transition", fields = fields[:]})
		}
	}

	last := fixture.log.segment
	testing.expect(t, last > LOG_SEGMENTS_PER_RUN, "the run should have rolled past its window")
	kept_from := last - (LOG_SEGMENTS_PER_RUN - 1)
	for segment in kept_from ..= last {
		testing.expect(t, os.exists(log_test_path(&fixture, segment)), "every segment in the window should exist")
	}
	testing.expect(t, !os.exists(log_test_path(&fixture, 1)), "the oldest segment should have been deleted")

	// The newest segment carries the removal report for what left the window.
	newest := log_test_segment_text(t, &fixture, last)
	defer delete(newest, context.allocator)
	testing.expect(t, strings.contains(newest, `"event":"log.segment_removed"`), "the rollover names the removed segment")
	testing.expect(t, strings.contains(newest, `"removed":true`), "the report says the deletion succeeded")
	testing.expect(t, strings.contains(newest, `"from_seq":`), "the report names the removed range")
	testing.expect(t, strings.contains(newest, `"to_seq":`), "the report names the removed range")

	// Sequences increase in physical write order across the window, which is what
	// makes a removal report readable against the records around it.
	previous := u64(0)
	for segment in kept_from ..= last {
		text := log_test_segment_text(t, &fixture, segment)
		defer delete(text, context.allocator)
		previous = log_test_expect_rising_sequences(t, text, previous)
	}
}

// log_test_expect_rising_sequences walks the "seq" values of one segment and
// reports the last one, holding every record to a strictly increasing sequence.
log_test_expect_rising_sequences :: proc(t: ^testing.T, text: string, previous: u64) -> u64 {
	SEQUENCE_KEY :: `"seq":`
	last := previous
	rest := text
	for len(rest) > 0 {
		at := strings.index(rest, SEQUENCE_KEY)
		if at < 0 { break }
		rest = rest[at + len(SEQUENCE_KEY):]
		end := strings.index_byte(rest, ',')
		if end <= 0 { break }
		value, ok := log_parse_uint(rest[:end])
		if ok {
			testing.expectf(t, value > last, "sequence %d should follow %d", value, last)
			last = value
		}
		rest = rest[end:]
	}
	return last
}

@(test)
test_log_failed_sink_stops_writing :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	binding := log_test_install(&fixture)
	context.logger = log_logger(&binding)
	record := Log_Record {
		level    = .Info,
		category = .Agent,
		event    = "agent.transition",
	}
	log_emit(record)
	testing.expect_value(t, log_health(&fixture.log).written, u64(1))

	// The writer loses its handle, which is what a failed close leaves behind. The
	// test takes ownership of the handle before the writer is asked to write again.
	handle := fixture.log.file
	fixture.log.file = nil
	log_emit(record)
	log_emit(record)

	health := log_health(&fixture.log)
	testing.expect(t, health.failed, "the failure is latched")
	testing.expect_value(t, health.first_error, Log_Error_Kind.Write)
	testing.expect_value(t, health.written, u64(1))
	testing.expect_value(t, health.omitted, u64(0))
	testing.expect(t, os.close(handle) == nil, "the taken handle still closes")
}

// test_log_level_names_round_trip holds the wire names to the type: a name a
// reader knows is the name the writer chose, and "off" is enablement rather than a
// severity.
@(test)
test_log_level_names_round_trip :: proc(t: ^testing.T) {
	for level in ([]log.Level{.Debug, .Info, .Warning, .Error, .Fatal}) {
		name := log_level_name(level)
		parsed, enabled, known := log_level_parse(name)
		testing.expectf(t, known, "%q should parse", name)
		testing.expectf(t, enabled, "%q should enable logging", name)
		testing.expectf(t, parsed == level, "%q should round trip", name)
	}
	_, enabled, known := log_level_parse("off")
	testing.expect(t, known, "off is a known value")
	testing.expect(t, !enabled, "off disables logging")
	_, _, unknown := log_level_parse("trace")
	testing.expect(t, !unknown, "a removed level is not known")
}

@(test)
test_log_segment_names_are_parsed_not_assumed :: proc(t: ^testing.T) {
	// A run that rotates past six digits prints more of them; the reader must still
	// recover the number rather than trusting a fixed width.
	name_buffer: [32]u8
	long := log_segment_name(1_234_567, name_buffer[:])
	number, ok := log_segment_name_number(long)
	testing.expect(t, ok, "a seven-digit segment name should parse")
	testing.expect_value(t, number, u64(1_234_567))

	for rejected in ([]string{"events-1.jsonl", "events-00001x.jsonl", "events-0000001.jsonl", "other-000001.jsonl", "000001.jsonl"}) {
		_, valid := log_segment_name_number(rejected)
		testing.expectf(t, !valid, "%q is not a segment name", rejected)
	}
}

// test_log_ordinary_message_reaches_the_sink is the property that makes Odin's
// logger the mechanism: a plain core:log call, not a structured record, lands in
// the same file with its caller location.
@(test)
test_log_ordinary_message_reaches_the_sink :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	binding := log_test_install(&fixture, {session_id = session.Session_Id("0123456789abcdef0123456789abcdef")})
	context.logger = log_logger(&binding)
	log.infof("a plain message: %d", 7)

	text := log_test_segment_text(t, &fixture, 1)
	defer delete(text, context.allocator)
	log_test_expect_all(
		t,
		text,
		{
			`"event":"runtime.message"`,
			`"category":"runtime"`,
			`"message":"a plain message: 7"`,
			`"file":"`,
			`"procedure":"`,
			`"session_id":"0123456789abcdef0123456789abcdef"`,
		},
		"an ordinary message",
	)
	testing.expect(t, strings.contains(text, `"line":`), "the caller's line is recorded")
}

// test_log_structured_emit_needs_a_nabla_logger holds the boundary: a foreign
// logger is never cast, and a nil logger is never written through.
@(test)
test_log_structured_emit_needs_a_nabla_logger :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	// A foreign logger that is not this writer's adapter.
	other := log.create_multi_logger()
	defer log.destroy_multi_logger(other)
	context.logger = other
	log_emit({level = .Info, category = .Agent, event = "agent.transition"})
	testing.expect(t, context.logger.data == other.data, "the active logger is left alone")
	testing.expect_value(t, log_health(&fixture.log).written, u64(0))

	context.logger = log.nil_logger()
	log_emit({level = .Info, category = .Agent, event = "agent.transition"})
	testing.expect_value(t, log_health(&fixture.log).written, u64(0))
}

// test_log_rebind_preserves_and_narrows is the correlation rule: a nested scope
// gets its own binding, and the parent's is untouched when it returns.
@(test)
test_log_rebind_preserves_and_narrows :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	parent := log_test_install(&fixture, {session_id = session.Session_Id("0123456789abcdef0123456789abcdef")})
	context.logger = log_logger(&parent)

	log_test_narrow_scope("fedcba9876543210fedcba9876543210")

	// The parent's correlation is unchanged, which is what a nested scope returning
	// must leave behind.
	log_emit({level = .Info, category = .Agent, event = "agent.transition"})

	text := log_test_segment_text(t, &fixture, 1)
	defer delete(text, context.allocator)
	lines := strings.split(text, "\n", context.temp_allocator)
	defer delete(lines, context.temp_allocator)
	testing.expect(t, len(lines) >= 3, "both records should be written")
	testing.expect(t, strings.contains(lines[0], `"session_id":"fedcba9876543210fedcba9876543210"`), "the nested record carries the narrowed session")
	testing.expect(t, strings.contains(lines[0], `"turn_no":4`), "the nested record carries the narrowed turn")
	testing.expect(t, strings.contains(lines[1], `"session_id":"0123456789abcdef0123456789abcdef"`), "the parent keeps its session")
	testing.expect(t, !strings.contains(lines[1], `"turn_no"`), "the parent keeps its absent turn")
}
