package main

import "core:fmt"
import "core:io"
import "core:mem"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "core:time"

import "nabla:agent"
import "nabla:agent/journal"

// stdout contains JSONL only; diagnostics go to stderr.

DIAGNOSTICS_USAGE :: "nabla diagnostics <session-id> [--request N] [--level NAME] [--export DIR [--include-payloads]]"

diagnostics_main :: proc(args: []string, stdout, stderr: io.Writer) -> int {
	session_text := ""
	selector: agent.Log_Read_Selector
	export_directory := ""
	include_payloads := false
	for index := 0; index < len(args); index += 1 {
		arg := args[index]
		switch {
		case arg == "--request" || strings.has_prefix(arg, "--request="):
			text := arg[len("--request"):]
			if text == "" {
				index += 1
				if index >= len(args) { return diagnostics_bad_usage("--request needs a number", stderr) }
				text = args[index]
			} else if text[0] == '=' {
				text = text[1:]
			}
			number, parsed := strconv.parse_i64(text)
			if !parsed || number <= 0 { return diagnostics_bad_usage("--request needs a positive request number", stderr) }
			selector.request_no = number
		case arg == "--level" || strings.has_prefix(arg, "--level="):
			text := arg[len("--level"):]
			if text == "" {
				index += 1
				if index >= len(args) { return diagnostics_bad_usage("--level needs a level name", stderr) }
				text = args[index]
			} else if text[0] == '=' {
				text = text[1:]
			}
			level, enabled, known := agent.log_level_parse(text)
			if !known { return diagnostics_bad_usage("--level takes debug, info, warn, error, or fatal", stderr) }
			if !enabled { return diagnostics_bad_usage("--level off would visit nothing; omit it instead", stderr) }
			selector.level = level
		case arg == "--include-payloads":
			include_payloads = true
		case arg == "--export" || strings.has_prefix(arg, "--export="):
			text := arg[len("--export"):]
			if text == "" {
				index += 1
				if index >= len(args) { return diagnostics_bad_usage("--export needs a directory", stderr) }
				text = args[index]
			} else if text[0] == '=' {
				text = text[1:]
			}
			if text == "" { return diagnostics_bad_usage("--export needs a directory", stderr) }
			export_directory = text
		case strings.has_prefix(arg, "-"):
			return diagnostics_bad_usage(fmt.tprintf("unknown option %s", arg), stderr)
		case session_text == "":
			session_text = arg
		case:
			return diagnostics_bad_usage("diagnostics reads one session", stderr)
		}
	}
	if session_text == "" { return diagnostics_bad_usage("a session id is required", stderr) }
	session_id, valid := journal.session_id_parse(session_text)
	if !valid { return diagnostics_bad_usage("that is not a session id", stderr) }

	if include_payloads && export_directory == "" {
		return diagnostics_bad_usage("--include-payloads only applies to --export", stderr)
	}

	logs_root, directory_err := agent.log_default_directory(context.temp_allocator)
	if directory_err != nil {
		fmt.wprintln(stderr, "nabla: the log directory could not be resolved")
		return 1
	}

	durable_ok := true
	if request_no, selected := selector.request_no.?; selected {
		durable_ok = diagnostics_report_request(session_id, journal.Request_Id(request_no), stderr)
	}

	if export_directory != "" {
		return diagnostics_export(logs_root, session_text, session_id, export_directory, selector, include_payloads, durable_ok, stderr)
	}

	output: Diagnostics_Output
	output.writer = stdout
	summary := agent.log_read_session(logs_root, session_text, &output, diagnostics_visit, selector)
	diagnostics_report(summary, stderr)
	if !durable_ok { return 1 }
	if output.broken {
		fmt.wprintln(stderr, "nabla: the output stream failed before the read was done")
		return 1
	}
	if diagnostics_incomplete(summary) { return 1 }
	if summary.records == 0 {
		fmt.wprintln(stderr, "nabla: no diagnostic records matched")
		return 1
	}
	return 0
}

diagnostics_bad_usage :: proc(problem: string, stderr: io.Writer) -> int {
	fmt.wprintln(stderr, "nabla:", problem)
	fmt.wprintln(stderr, "usage:", DIAGNOSTICS_USAGE)
	return 2
}

// diagnostics_incomplete reports whether the read could not be trusted to be
// complete: unreadable evidence, uninterpretable records, or a stopped visitor.
diagnostics_incomplete :: proc(summary: agent.Log_Read_Summary) -> bool {
	return(
		summary.cannot_read > 0 ||
		summary.records_skipped > 0 ||
		summary.records_unsupported > 0 ||
		summary.records_foreign > 0 ||
		summary.partial_tails > 0 ||
		summary.runs_truncated ||
		summary.stopped \
	)
}

Diagnostics_Output :: struct {
	writer: io.Writer,
	broken: bool,
}

// user_data points to the Diagnostics_Output borrowed by log_read_session.
diagnostics_visit :: proc(user_data: rawptr, run_id: string, line: string) -> bool {
	output := cast(^Diagnostics_Output)user_data
	parts := [2]string{line, "\n"}
	for part in parts {
		written, write_error := io.write_string(output.writer, part)
		if write_error != nil || written != len(part) {
			output.broken = true
			return false
		}
	}
	return true
}

// --- the durable half of --request ------------------------------------------

DIAGNOSTICS_TIMESTAMP_BYTES :: 32

Diagnostics_Request :: struct {
	request:            journal.Request_Id,
	turn:               journal.Turn_Id,
	purpose:            string,
	attempts:           int,
	started_ms:         i64,
	finished_ms:        i64,
	outcome:            string,
	provider:           string,
	model_requested:    string,
	model_resolved:     string,
	api:                string,
	finish:             string,
	input_tokens:       Maybe(i64),
	output_tokens:      Maybe(i64),
	cache_read_tokens:  Maybe(i64),
	cache_write_tokens: Maybe(i64),
}

diagnostics_request_destroy :: proc(request: ^Diagnostics_Request, allocator: mem.Allocator) {
	delete(request.purpose, allocator)
	delete(request.provider, allocator)
	delete(request.model_requested, allocator)
	delete(request.model_resolved, allocator)
	delete(request.api, allocator)
	delete(request.finish, allocator)
	request^ = {}
}

// The returned summary owns its strings in allocator.
diagnostics_request_open :: proc(
	session_id: journal.Session_Id,
	request_no: journal.Request_Id,
	allocator := context.allocator,
) -> (
	request: Diagnostics_Request,
	error: journal.Error,
) {
	directory, directory_err := agent.xdg_directory(.State, context.temp_allocator)
	if directory_err != .None {
		return {}, journal.Journal_Error.Storage_Failed
	}
	store: journal.Journal
	journal.open(&store, directory, journal.run_id_create(), .Read_Only, allocator) or_return
	defer {
		if close_error := journal.close(&store); close_error != nil && error == nil { error = close_error }
	}
	kinds: bit_set[journal.Record_Kind;u128] = {.Request_Sent, .Response_Committed, .Response_Rejected, .Request_Interrupted, .Compaction_Completed}
	records, _, read_error := journal.read_records(&store, {session = session_id, request = request_no, kinds = kinds}, 0, 0, allocator)
	if read_error != nil { return {}, read_error }
	defer journal.records_destroy(records, allocator)
	if len(records) == 0 { return {}, journal.Journal_Error.Not_Found }
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil { return {}, journal.Journal_Error.Storage_Failed }
	defer virtual.arena_destroy(&scratch)
	scratch_allocator := virtual.arena_allocator(&scratch)
	request.request = request_no
	request.outcome = "open"
	defer if error != nil { diagnostics_request_destroy(&request, allocator) }
	for record in records {
		if request.turn == 0 { request.turn = record.turn }
		#partial switch record.kind {
		case .Request_Sent:
			payload: journal.Request_Sent
			journal.payload_decode(record.data, &payload, scratch_allocator) or_return
			request.attempts += 1
			request.outcome = "open"
			request.finished_ms = 0
			if request.started_ms == 0 { request.started_ms = record.time_ms }
			delete(request.purpose, allocator)
			delete(request.api, allocator)
			delete(request.model_requested, allocator)
			delete(request.provider, allocator)
			request.purpose = strings.clone(payload.purpose, allocator) or_return
			request.api = strings.clone(payload.api, allocator) or_return
			request.model_requested = strings.clone(payload.model_requested, allocator) or_return
			request.provider = strings.clone(record.provider, allocator) or_return
		case .Response_Committed, .Compaction_Completed:
			payload: journal.Response_Committed
			journal.payload_decode(record.data, &payload, scratch_allocator) or_return
			request.outcome = "completed"
			request.finished_ms = record.time_ms
			delete(request.finish, allocator)
			delete(request.model_resolved, allocator)
			request.finish = strings.clone(payload.finish, allocator) or_return
			request.model_resolved = strings.clone(payload.model_resolved, allocator) or_return
			request.input_tokens = payload.input_tokens
			request.output_tokens = payload.output_tokens
			request.cache_read_tokens = payload.cache_read_tokens
			request.cache_write_tokens = payload.cache_write_tokens
		case .Response_Rejected:
			payload: journal.Response_Rejected
			journal.payload_decode(record.data, &payload, scratch_allocator) or_return
			request.outcome = "rejected"
			request.finished_ms = record.time_ms
		case .Request_Interrupted:
			payload: journal.Request_Interrupted
			journal.payload_decode(record.data, &payload, scratch_allocator) or_return
			request.outcome = "interrupted"
			request.finished_ms = record.time_ms
		}
	}
	return request, nil
}

// diagnostics_report_request prints journal facts beside diagnostic logs on stdout.
diagnostics_report_request :: proc(session_id: journal.Session_Id, request_no: journal.Request_Id, stderr: io.Writer) -> bool {
	row, load_err := diagnostics_request_open(session_id, request_no, context.allocator)
	if load_err != nil {
		fmt.wprintf(stderr, "nabla: the stored request could not be read: %s\n", journal.error_text(load_err, context.temp_allocator))
		return false
	}
	defer diagnostics_request_destroy(&row, context.allocator)

	diagnostics_print_request(&row, stderr)
	return true
}

// diagnostics_print_request writes metadata without response bodies.
@(private)
diagnostics_print_request :: proc(row: ^Diagnostics_Request, stderr: io.Writer) {
	started_buffer: [DIAGNOSTICS_TIMESTAMP_BYTES]u8
	finished_buffer: [DIAGNOSTICS_TIMESTAMP_BYTES]u8
	started := diagnostics_timestamp(row.started_ms, started_buffer[:])
	finished := "still running"
	if row.finished_ms != 0 { finished = diagnostics_timestamp(row.finished_ms, finished_buffer[:]) }

	fmt.wprintf(stderr, "nabla: request %d: %s, %s (%d attempt(s))\n", i64(row.request), row.purpose, row.outcome, row.attempts)
	fmt.wprintf(stderr, "nabla:   started %s, finished %s\n", started, finished)
	fmt.wprintf(stderr, "nabla:   provider %s, api %s\n", row.provider, row.api)
	if row.model_resolved != "" && row.model_resolved != row.model_requested {
		fmt.wprintf(stderr, "nabla:   model requested %s, resolved %s\n", row.model_requested, row.model_resolved)
	} else {
		fmt.wprintf(stderr, "nabla:   model %s\n", row.model_requested)
	}
	if row.finish != "" { fmt.wprintf(stderr, "nabla:   finish %s\n", row.finish) }
	fmt.wprintf(stderr, "nabla:   usage %s\n", diagnostics_usage_text(row))
}

// Absent token counts are unreported rather than zero.
@(private)
diagnostics_usage_text :: proc(usage: ^Diagnostics_Request) -> string {
	builder, builder_error := strings.builder_make(context.temp_allocator)
	if builder_error != nil { return "usage unavailable" }
	names := [4]string{"input", "output", "cache read", "cache write"}
	values := [4]Maybe(i64){usage.input_tokens, usage.output_tokens, usage.cache_read_tokens, usage.cache_write_tokens}
	for value, index in values {
		if index > 0 { fmt.sbprintf(&builder, ", ") }
		if count, present := value.?; present {
			fmt.sbprintf(&builder, "%s %d", names[index], count)
		} else {
			fmt.sbprintf(&builder, "%s unreported", names[index])
		}
	}
	return strings.to_string(builder)
}

// diagnostics_timestamp renders a stored millisecond timestamp in UTC. A
// timestamp that is absent or out of range is reported as unknown rather than
// printed as a wrong date.
@(private)
diagnostics_timestamp :: proc(at_ms: i64, buffer: []u8) -> string {
	if at_ms <= 0 { return "unknown" }
	instant := time.unix(at_ms / 1000, (at_ms % 1000) * 1_000_000)
	datetime, okay := time.time_to_datetime(instant)
	if !okay { return "unknown" }
	return fmt.bprintf(buffer, "%04d-%02d-%02dT%02d:%02d:%02dZ", datetime.year, datetime.month, datetime.day, datetime.hour, datetime.minute, datetime.second)
}

diagnostics_report :: proc(summary: agent.Log_Read_Summary, stderr: io.Writer) {
	fmt.wprintf(stderr, "nabla: %d record(s), %d run(s) scanned, %d file(s) read", summary.records, summary.runs_scanned, summary.files_read)
	if summary.cannot_read > 0 { fmt.wprintf(stderr, ", %d unreadable", summary.cannot_read) }
	if summary.records_skipped > 0 { fmt.wprintf(stderr, ", %d line(s) not records", summary.records_skipped) }
	if summary.records_unsupported > 0 { fmt.wprintf(stderr, ", %d unsupported version(s)", summary.records_unsupported) }
	if summary.records_foreign > 0 { fmt.wprintf(stderr, ", %d record(s) from another run", summary.records_foreign) }
	if summary.gaps > 0 { fmt.wprintf(stderr, ", %d segment(s) removed by retention", summary.gaps) }
	if summary.partial_tails > 0 { fmt.wprintf(stderr, ", %d incomplete line(s)", summary.partial_tails) }
	if summary.runs_truncated { fmt.wprint(stderr, ", run scan limit reached") }
	if summary.stopped { fmt.wprint(stderr, ", read stopped by visitor") }
	fmt.wprintln(stderr)
}
