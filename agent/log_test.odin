#+test
package agent

import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent/session"

// The writer is tested from the inside: a test lowers the rollover bound and
// reads the segments it wrote, because the file layout and the encoded line are
// the contract a later reader depends on.

Log_Test :: struct {
	directory: string,
	log:       Log,
}

log_test_begin :: proc(t: ^testing.T, fixture: ^Log_Test) {
	directory, directory_err := os.make_directory_temp("", "nabla-log-test-*", context.allocator)
	if directory_err != nil { testing.fail_now(t, "could not create a temporary directory") }
	fixture.directory = directory

	if open_err := log_open(&fixture.log, {directory = directory, level = .Info}); open_err != nil {
		local := open_err
		testing.fail_now(t, strings.concatenate({"log_open failed: ", log_error_detail(&local)}, context.temp_allocator))
	}
}

log_test_end :: proc(t: ^testing.T, fixture: ^Log_Test) {
	log_close(&fixture.log)
	os.remove_all(fixture.directory)
	delete(fixture.directory, context.allocator)
	fixture^ = {}
}

log_test_path :: proc(fixture: ^Log_Test, segment: u32) -> string {
	name_buffer: [32]u8
	name := log_segment_name(segment, name_buffer[:])
	path, _ := log_path_join(fixture.log.directory, name, context.temp_allocator)
	return path
}

// log_test_segment_text reads one segment into caller-owned memory, released
// with delete(text, context.allocator).
log_test_segment_text :: proc(t: ^testing.T, fixture: ^Log_Test, segment: u32) -> string {
	content, read_err := os.read_entire_file(log_test_path(fixture, segment), context.allocator)
	if read_err != nil { testing.fail_now(t, "the log segment could not be read") }
	return string(content)
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
	testing.expect_value(t, log_error_kind(log_open(&fixture.log, {directory = fixture.directory, level = .Info})), Log_Error_Kind.Invalid_State)
}

@(test)
test_log_open_without_a_directory_records_nothing :: proc(t: ^testing.T) {
	log: Log
	testing.expect(t, log_open(&log, {directory = "", level = .Info}) == nil, "a disabled writer still opens")
	testing.expect(t, !log.open, "a writer with no directory should own nothing")

	record := Log_Record {
		level    = .Error,
		category = .Runtime,
		event    = "run.started",
	}
	testing.expect_value(t, log_emit(Log_Context{log = &log}, record), Log_Emit_Result.Disabled)
	testing.expect_value(t, log_health(&log).written, u64(0))
	testing.expect(t, log_close(&log) == nil, "closing a writer that opened nothing succeeds")
}

@(test)
test_log_emit_writes_one_record :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	fields := [2]Log_Field{{key = "api", value = "openai_chat_completions"}, {key = "body_bytes", value = i64(174381)}}
	result := log_emit(
		Log_Context {
			log = &fixture.log,
			session_id = session.Session_Id("0123456789abcdef0123456789abcdef"),
			turn_no = 3,
			request_no = 6,
			attempt = 1,
			operation_id = 12,
		},
		Log_Record{level = .Info, category = .Provider, event = "provider.encoded", fields = fields[:]},
	)
	testing.expect_value(t, result, Log_Emit_Result.Written)

	text := log_test_segment_text(t, &fixture, 1)
	defer delete(text, context.allocator)
	testing.expect_value(t, strings.count(text, "\n"), 1)
	testing.expect(t, strings.has_prefix(text, "{") && strings.has_suffix(text, "}\n"), "a record is one JSON object and a newline")
	testing.expect(t, strings.contains(text, `"version":1`), "the envelope version is written")
	testing.expect(t, strings.contains(text, `"level":"info"`), "the level is written by name")
	testing.expect(t, strings.contains(text, `"category":"provider"`), "the category is written by name")
	testing.expect(t, strings.contains(text, `"event":"provider.encoded"`), "the event is written")
	testing.expect(t, strings.contains(text, `"seq":1`), "the first record carries sequence one")
	testing.expect(t, strings.contains(text, `"session_id":"0123456789abcdef0123456789abcdef"`), "a set session is written")
	testing.expect(t, strings.contains(text, `"turn_no":3`), "a set turn is written")
	testing.expect(t, strings.contains(text, `"request_no":6`), "a set request is written")
	testing.expect(t, strings.contains(text, `"attempt":1`), "a set attempt is written")
	testing.expect(t, strings.contains(text, `"operation_id":12`), "a set operation is written")
	testing.expect(t, strings.contains(text, `"body_bytes":174381`), "an integer field is unquoted")
	testing.expect(t, strings.contains(text, `"api":"openai_chat_completions"`), "a string field is quoted")
}

@(test)
test_log_emit_omits_unset_correlation :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	log_emit(Log_Context{log = &fixture.log}, Log_Record{level = .Info, category = .Agent, event = "agent.transition"})

	text := log_test_segment_text(t, &fixture, 1)
	defer delete(text, context.allocator)
	testing.expect(t, !strings.contains(text, `"session_id"`), "an absent session is omitted")
	testing.expect(t, !strings.contains(text, `"turn_no"`), "an absent turn is omitted")
	testing.expect(t, !strings.contains(text, `"request_no"`), "an absent request is omitted")
	testing.expect(t, !strings.contains(text, `"attempt"`), "an absent attempt is omitted")
	testing.expect(t, !strings.contains(text, `"operation_id"`), "an absent operation is omitted")
}

@(test)
test_log_emit_escapes_a_string_field :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	// Valid ASCII, an invalid UTF-8 byte, a quote, a backslash, and a control
	// byte: everything that must not reach the file verbatim.
	raw := [5]u8{'a', 0xFF, '"', '\\', 0x01}
	control := [1]u8{0x01}
	replacement := [3]u8{0xEF, 0xBF, 0xBD}
	fields := [1]Log_Field{{key = "detail", value = string(raw[:])}}
	result := log_emit(Log_Context{log = &fixture.log}, Log_Record{level = .Warn, category = .Provider, event = "test.escape", fields = fields[:]})
	testing.expect_value(t, result, Log_Emit_Result.Written)

	text := log_test_segment_text(t, &fixture, 1)
	defer delete(text, context.allocator)
	testing.expect_value(t, strings.count(text, "\n"), 1)
	testing.expect(t, strings.contains(text, `\"`), "a quote is escaped")
	testing.expect(t, strings.contains(text, `\\`), "a backslash is escaped")
	testing.expect(t, strings.contains(text, `\u0001`), "a control byte is escaped")
	testing.expect(t, !strings.contains(text, string(control[:])), "no raw control byte reaches the file")
	testing.expect(t, strings.contains(text, string(replacement[:])), "invalid UTF-8 becomes the replacement character")
}

@(test)
test_log_emit_filters_below_the_threshold :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	scope := Log_Context {
		log = &fixture.log,
	}
	filtered := log_emit(scope, Log_Record{level = .Debug, category = .Agent, event = "agent.transition"})
	testing.expect_value(t, filtered, Log_Emit_Result.Filtered)
	written := log_emit(scope, Log_Record{level = .Info, category = .Agent, event = "agent.transition"})
	testing.expect_value(t, written, Log_Emit_Result.Written)

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

	scope := Log_Context {
		log = &fixture.log,
	}
	no_event := log_emit(scope, Log_Record{level = .Info, category = .Agent})
	testing.expect_value(t, no_event, Log_Emit_Result.Rejected)

	no_level := log_emit(scope, Log_Record{level = .Disabled, category = .Agent, event = "agent.transition"})
	testing.expect_value(t, no_level, Log_Emit_Result.Rejected)

	reserved := [1]Log_Field{{key = "event", value = "shadowed"}}
	shadowed := log_emit(scope, Log_Record{level = .Info, category = .Agent, event = "agent.transition", fields = reserved[:]})
	testing.expect_value(t, shadowed, Log_Emit_Result.Rejected)

	duplicate := [2]Log_Field{{key = "key", value = "first"}, {key = "key", value = "second"}}
	repeated := log_emit(scope, Log_Record{level = .Info, category = .Agent, event = "agent.transition", fields = duplicate[:]})
	testing.expect_value(t, repeated, Log_Emit_Result.Rejected)

	testing.expect_value(t, log_health(&fixture.log).omitted, u64(4))
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

	large := make([]u8, LOG_MAX_RECORD_BYTES, context.allocator)
	defer delete(large, context.allocator)
	for index in 0 ..< len(large) { large[index] = 'x' }

	fields := [1]Log_Field{{key = "text", value = string(large[:])}}
	result := log_emit(Log_Context{log = &fixture.log}, Log_Record{level = .Info, category = .Agent, event = "agent.transition", fields = fields[:]})
	testing.expect_value(t, result, Log_Emit_Result.Oversized)

	text := log_test_segment_text(t, &fixture, 1)
	defer delete(text, context.allocator)
	testing.expect(t, len(text) < LOG_MAX_RECORD_BYTES, "the omission record must fit the bound")
	testing.expect(t, strings.contains(text, `"event":"log.record_omitted"`), "the omission names itself")
	testing.expect(t, strings.contains(text, `"omitted_event":"agent.transition"`), "the omission names the dropped event")
	testing.expect(t, strings.contains(text, `"omitted_fields":1`), "the omission counts the dropped fields")
	testing.expect_value(t, log_health(&fixture.log).omitted, u64(1))
	testing.expect_value(t, log_health(&fixture.log).written, u64(1))
}

@(test)
test_log_sequence_increases_with_every_record :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	scope := Log_Context {
		log = &fixture.log,
	}
	for _ in 0 ..< 3 {
		log_emit(scope, Log_Record{level = .Info, category = .Agent, event = "agent.transition"})
	}

	text := log_test_segment_text(t, &fixture, 1)
	defer delete(text, context.allocator)
	testing.expect(t, strings.contains(text, `"seq":1`), "the first record carries sequence one")
	testing.expect(t, strings.contains(text, `"seq":2`), "the second record carries sequence two")
	testing.expect(t, strings.contains(text, `"seq":3`), "the third record carries sequence three")
	testing.expect_value(t, log_health(&fixture.log).written, u64(3))
}

@(test)
test_log_rollover_keeps_a_bounded_window :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	// A lowered bound makes this a test of the window rather than of throughput.
	fixture.log.segment_bytes = 1024
	fields := [1]Log_Field{{key = "note", value = "rollover"}}
	scope := Log_Context {
		log = &fixture.log,
	}
	for _ in 0 ..< 200 {
		if fixture.log.segment > LOG_SEGMENTS_PER_RUN { break }
		log_emit(scope, Log_Record{level = .Info, category = .Agent, event = "agent.transition", fields = fields[:]})
	}
	testing.expect(t, fixture.log.segment > LOG_SEGMENTS_PER_RUN, "the run should have rolled past its window")

	kept_from := fixture.log.segment - (LOG_SEGMENTS_PER_RUN - 1)
	for segment in kept_from ..= fixture.log.segment {
		testing.expect(t, os.exists(log_test_path(&fixture, segment)), "every segment in the window should exist")
	}
	testing.expect(t, !os.exists(log_test_path(&fixture, 1)), "the oldest segment should have been deleted")
	testing.expect(t, !os.exists(log_test_path(&fixture, kept_from - 1)), "the segment before the window should have been deleted")
}

@(test)
test_log_failed_sink_stops_writing :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	scope := Log_Context {
		log = &fixture.log,
	}
	record := Log_Record {
		level    = .Info,
		category = .Agent,
		event    = "agent.transition",
	}
	testing.expect_value(t, log_emit(scope, record), Log_Emit_Result.Written)

	// The writer loses its handle, which is what a failed close leaves behind. The
	// test takes ownership of the handle before the writer is asked to write again.
	handle := fixture.log.file
	fixture.log.file = nil
	testing.expect_value(t, log_emit(scope, record), Log_Emit_Result.Failed)
	testing.expect_value(t, log_emit(scope, record), Log_Emit_Result.Failed)

	health := log_health(&fixture.log)
	testing.expect(t, health.failed, "the failure is latched")
	testing.expect_value(t, health.first_error, Log_Error_Kind.Write)
	testing.expect_value(t, health.written, u64(1))
	testing.expect_value(t, health.omitted, u64(0))
	testing.expect(t, os.close(handle) == nil, "the taken handle still closes")
}
