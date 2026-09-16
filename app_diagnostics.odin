package main

import "core:fmt"
import "core:io"
import "core:strconv"
import "core:strings"
import "core:time"

import "nabla:agent"
import "nabla:agent/session"

// stdout contains JSONL only; diagnostics go to stderr.

DIAGNOSTICS_USAGE :: "nabla diagnostics <session-id> [--request N] [--level NAME] [--export DIR [--include-payloads]]"

diagnostics_main :: proc(args: []string) -> int {
	session_id := session.Session_Id("")
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
				if index >= len(args) { return diagnostics_bad_usage("--request needs a number") }
				text = args[index]
			} else if text[0] == '=' {
				text = text[1:]
			}
			number, parsed := strconv.parse_i64(text)
			if !parsed || number <= 0 { return diagnostics_bad_usage("--request needs a positive request number") }
			selector.request_no = session.Request_No(number)
		case arg == "--level" || strings.has_prefix(arg, "--level="):
			text := arg[len("--level"):]
			if text == "" {
				index += 1
				if index >= len(args) { return diagnostics_bad_usage("--level needs a level name") }
				text = args[index]
			} else if text[0] == '=' {
				text = text[1:]
			}
			level, enabled, known := agent.log_level_parse(text)
			if !known { return diagnostics_bad_usage("--level takes debug, info, warn, error, or fatal") }
			if !enabled { return diagnostics_bad_usage("--level off would visit nothing; omit it instead") }
			selector.level = level
		case arg == "--include-payloads":
			include_payloads = true
		case arg == "--export" || strings.has_prefix(arg, "--export="):
			text := arg[len("--export"):]
			if text == "" {
				index += 1
				if index >= len(args) { return diagnostics_bad_usage("--export needs a directory") }
				text = args[index]
			} else if text[0] == '=' {
				text = text[1:]
			}
			if text == "" { return diagnostics_bad_usage("--export needs a directory") }
			export_directory = text
		case strings.has_prefix(arg, "-"):
			return diagnostics_bad_usage(fmt.tprintf("unknown option %s", arg))
		case session_id == "":
			session_id = session.Session_Id(arg)
		case:
			return diagnostics_bad_usage("diagnostics reads one session")
		}
	}
	if session_id == "" { return diagnostics_bad_usage("a session id is required") }
	if !session.session_id_valid(session_id) { return diagnostics_bad_usage("that is not a session id") }

	if include_payloads && export_directory == "" {
		return diagnostics_bad_usage("--include-payloads only applies to --export")
	}

	logs_root, directory_err := agent.log_default_directory(context.temp_allocator)
	if directory_err != nil {
		fmt.eprintln("nabla: the log directory could not be resolved")
		return 1
	}

	// The records are what the writer observed; the row is what the session
	// database decided. A --request selector asks for both, so the join is
	// attempted first and its absence is reported rather than hidden.
	durable_ok := true
	if request_no, selected := selector.request_no.?; selected {
		durable_ok = diagnostics_report_request(session_id, request_no)
	}

	if export_directory != "" {
		return diagnostics_export(logs_root, session_id, export_directory, selector, include_payloads, durable_ok)
	}

	output: Diagnostics_Output
	output.writer = stdout_writer()
	summary := agent.log_read_session(logs_root, session_id, &output, diagnostics_visit, selector)
	diagnostics_report(summary)
	if !durable_ok { return 1 }
	if output.broken {
		fmt.eprintln("nabla: the output stream failed before the read was done")
		return 1
	}
	if diagnostics_incomplete(summary) { return 1 }
	if summary.records == 0 {
		fmt.eprintln("nabla: no diagnostic records matched")
		return 1
	}
	return 0
}

diagnostics_bad_usage :: proc(problem: string) -> int {
	fmt.eprintln("nabla:", problem)
	fmt.eprintln("usage:", DIAGNOSTICS_USAGE)
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

// diagnostics_request_open reads one request through a connection that cannot
// write. The session database is authoritative for the row, so this is the
// answer the record stream is read beside rather than instead of. The store is
// closed before it returns, so a reader never holds a connection open while the
// record files are scanned.
diagnostics_request_open :: proc(
	session_id: session.Session_Id,
	request_no: session.Request_No,
	allocator := context.allocator,
) -> (
	row: session.Request,
	err: session.Error,
) {
	directory, directory_err := agent.xdg_directory(.State, context.temp_allocator)
	if directory_err != .None {
		return {}, session.error_make(.Storage, "the session store directory could not be resolved")
	}

	store: session.Store
	if open_err := session.store_open_read_only(&store, directory); open_err != nil {
		return {}, open_err
	}
	defer session.store_close(&store)

	return session.request_load(&store, session_id, request_no, allocator)
}

// diagnostics_report_request prints the durable row for a --request selection on
// stderr, beside the records that go to stdout. False means the row could not be
// read, because an answer whose authoritative half is missing is not an answer.
diagnostics_report_request :: proc(session_id: session.Session_Id, request_no: session.Request_No) -> bool {
	row, load_err := diagnostics_request_open(session_id, request_no, context.temp_allocator)
	if load_err != nil {
		local := load_err
		fmt.eprintf("nabla: the stored request could not be read: %s\n", session.error_detail(&local))
		return false
	}
	defer session.request_destroy(&row, context.temp_allocator)

	diagnostics_print_request(&row)
	return true
}

// diagnostics_print_request writes the row the database is authoritative for.
// Only metadata is shown: the stored input, response, error, and configuration
// are the conversation itself, and the record stream beside this is what a caller
// reads for what the harness observed.
@(private)
diagnostics_print_request :: proc(row: ^session.Request) {
	started_buffer: [DIAGNOSTICS_TIMESTAMP_BYTES]u8
	finished_buffer: [DIAGNOSTICS_TIMESTAMP_BYTES]u8
	started := diagnostics_timestamp(row.started_at_ms, started_buffer[:])
	finished := "still running"
	if value, present := row.finished_at_ms.?; present {
		finished = diagnostics_timestamp(value, finished_buffer[:])
	}

	fmt.eprintf("nabla: request %d: %s, %s\n", i64(row.request_no), session.request_purpose_name(row.purpose), session.outcome_name(row.outcome))
	fmt.eprintf("nabla:   started %s, finished %s\n", started, finished)
	fmt.eprintf("nabla:   provider %s, api %s\n", row.provider, row.api)
	if row.model_resolved != "" && row.model_resolved != row.model_requested {
		fmt.eprintf("nabla:   model requested %s, resolved %s\n", row.model_requested, row.model_resolved)
	} else {
		fmt.eprintf("nabla:   model %s\n", row.model_requested)
	}
	fmt.eprintf("nabla:   usage %s\n", diagnostics_usage_text(row.usage))
}

// diagnostics_usage_text names each bucket and calls an unreported one
// unreported. The database stores an absent count as NULL, so reporting it as
// zero would invent a measurement the provider never made.
@(private)
diagnostics_usage_text :: proc(usage: session.Usage) -> string {
	builder := strings.builder_make(context.temp_allocator)
	names := [4]string{"input", "output", "cache read", "cache write"}
	values := [4]Maybe(i64){usage.input, usage.output, usage.cache_read, usage.cache_write}
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

diagnostics_report :: proc(summary: agent.Log_Read_Summary) {
	fmt.eprintf("nabla: %d record(s), %d run(s) scanned, %d file(s) read", summary.records, summary.runs_scanned, summary.files_read)
	if summary.cannot_read > 0 { fmt.eprintf(", %d unreadable", summary.cannot_read) }
	if summary.records_skipped > 0 { fmt.eprintf(", %d line(s) not records", summary.records_skipped) }
	if summary.records_unsupported > 0 { fmt.eprintf(", %d unsupported version(s)", summary.records_unsupported) }
	if summary.records_foreign > 0 { fmt.eprintf(", %d record(s) from another run", summary.records_foreign) }
	if summary.gaps > 0 { fmt.eprintf(", %d segment(s) removed by retention", summary.gaps) }
	if summary.partial_tails > 0 { fmt.eprintf(", %d incomplete line(s)", summary.partial_tails) }
	if summary.runs_truncated { fmt.eprint(", run scan limit reached") }
	if summary.stopped { fmt.eprint(", read stopped by visitor") }
	fmt.eprintln()
}
