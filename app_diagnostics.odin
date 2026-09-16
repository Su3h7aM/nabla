package main

import "core:fmt"
import "core:io"
import "core:strconv"
import "core:strings"

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
	if export_directory != "" {
		return diagnostics_export(logs_root, session_id, export_directory, selector, include_payloads)
	}

	output: Diagnostics_Output
	output.writer = stdout_writer()
	summary := agent.log_read_session(logs_root, session_id, &output, diagnostics_visit, selector)
	diagnostics_report(summary)
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
