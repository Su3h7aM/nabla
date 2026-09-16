package main

import "core:fmt"
import "core:io"

import "nabla:agent"
import "nabla:agent/session"

// stdout contains JSONL only; diagnostics go to stderr.

DIAGNOSTICS_USAGE :: "nabla diagnostics <session-id>"

diagnostics_main :: proc(args: []string) -> int {
	if len(args) != 1 {
		fmt.eprintln("nabla: diagnostics reads one session")
		fmt.eprintln("usage:", DIAGNOSTICS_USAGE)
		return 2
	}
	session_id := session.Session_Id(args[0])
	if !session.session_id_valid(session_id) {
		fmt.eprintln("nabla: that is not a session id")
		fmt.eprintln("usage:", DIAGNOSTICS_USAGE)
		return 2
	}

	logs_root, directory_err := agent.log_default_directory(context.temp_allocator)
	if directory_err != nil {
		fmt.eprintln("nabla: the log directory could not be resolved")
		return 1
	}

	output: Diagnostics_Output
	output.writer = stdout_writer()
	summary := agent.log_read_session(logs_root, session_id, &output, diagnostics_visit)
	diagnostics_report(summary)
	if output.broken {
		fmt.eprintln("nabla: the output stream failed before the read was done")
		return 1
	}
	if summary.cannot_read > 0 || summary.records_skipped > 0 || summary.runs_truncated || summary.stopped {
		return 1
	}
	if summary.records == 0 {
		fmt.eprintln("nabla: no diagnostic records for that session")
		return 1
	}
	return 0
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
	if summary.records_skipped > 0 { fmt.eprintf(", %d line(s) unreadable", summary.records_skipped) }
	if summary.runs_truncated { fmt.eprint(", run scan limit reached") }
	if summary.stopped { fmt.eprint(", read stopped by visitor") }
	fmt.eprintln()
}
