package main

import "core:fmt"

import "nabla:agent"
import "nabla:agent/session"

// `nabla diagnostics <session-id>` prints the diagnostic records one session left,
// oldest run first, exactly as they were written. The records go to stdout as JSON
// Lines so a caller can pipe them into jq, and everything the command has to say
// about what it read goes to stderr, so stdout stays a clean stream.

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

	summary := agent.log_read_session(logs_root, session_id, nil, diagnostics_visit)
	diagnostics_report(summary)
	if summary.records == 0 {
		fmt.eprintln("nabla: no diagnostic records for that session")
		return 1
	}
	return 0
}

// diagnostics_visit prints one record as it was written. The run a record came from
// is a field of the record, so the visitor needs nothing else.
diagnostics_visit :: proc(user_data: rawptr, run_id: string, line: string) -> bool {
	fmt.println(line)
	return true
}

// diagnostics_report says what the read could and could not see. It describes the
// output rather than being part of it, so it goes to stderr.
diagnostics_report :: proc(summary: agent.Log_Read_Summary) {
	fmt.eprintf("nabla: %d record(s) from %d run(s), %d file(s)", summary.records, summary.runs_scanned, summary.files_read)
	if summary.files_skipped > 0 { fmt.eprintf(", %d file(s) unreadable", summary.files_skipped) }
	if summary.records_skipped > 0 { fmt.eprintf(", %d line(s) unreadable", summary.records_skipped) }
	if summary.runs_truncated { fmt.eprint(", older runs were not scanned") }
	fmt.eprintln()
}
