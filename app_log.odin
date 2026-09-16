package main

import "core:fmt"
import "core:log"
import "core:os"

import "nabla:agent"
import "nabla:agent/session"

// Diagnostics for one launch. The writer is opened before the session database and
// closed after it, so a launch that cannot open either still leaves a record of how
// far it got. None of this is required for the harness to work: a log that cannot be
// opened is reported and the launch continues without one.
//
// Dispatch is Odin's own: the binding lives in the setup, the caller installs the
// returned logger with `context.logger = ...` in the scope that owns the run, and
// every core:log call and structured record below that scope reaches this sink.

LOG_LEVEL_VARIABLE :: "NABLA_LOG_LEVEL"

// run_log_open resolves the launch's diagnostic policy, opens the writer, and
// returns the logger the caller installs. It deliberately does not install it: a
// helper cannot change its caller's context, and the binding has to live in the
// scope that owns the run.
//
// A launch whose log cannot be opened reports it once on stderr and carries on
// without one. No record is ever written to stdout or to the terminal.
run_log_open :: proc(setup: ^Run_Setup) -> log.Logger {
	options := run_log_options()
	if !options.enabled { return context.logger }

	directory, directory_err := agent.log_default_directory(setup.alloc)
	if directory_err != nil {
		fmt.eprintln("nabla: diagnostics are unavailable: the log directory could not be resolved")
		return context.logger
	}
	defer delete(directory, setup.alloc)
	options.directory = directory

	cleanup, open_err := agent.log_open(&setup.log, options, setup.alloc)
	if open_err != nil {
		local := open_err
		fmt.eprintln("nabla: diagnostics are unavailable:", agent.log_error_detail(&local))
		return context.logger
	}
	setup.log_binding = agent.Log_Binding {
		sink = &setup.log,
	}
	setup.log_cleanup = cleanup
	return agent.log_logger(&setup.log_binding)
}

// run_log_header records the run's own header and what the retention pass did. It
// runs after the caller installed the logger, so run.started is the launch's first
// record and the pass is reported immediately after it, before the store is opened.
run_log_header :: proc(setup: ^Run_Setup) {
	if !setup.log.open { return }
	fields := [3]agent.Log_Field {
		{key = "pid", value = i64(os.get_pid())},
		{key = "threshold", value = agent.log_level_name(setup.log.lowest)},
		{key = "schema_version", value = i64(session.SCHEMA_VERSION)},
	}
	agent.log_emit(agent.Log_Record{level = .Info, category = .Runtime, event = "run.started", fields = fields[:]})

	cleanup := setup.log_cleanup
	if cleanup.deleted == 0 && cleanup.failed == 0 && cleanup.unmeasured == 0 && !cleanup.scan_limited { return }
	retention := [5]agent.Log_Field {
		{key = "deleted", value = i64(cleanup.deleted)},
		{key = "freed_bytes", value = cleanup.freed_bytes},
		{key = "failed", value = i64(cleanup.failed)},
		{key = "unmeasured", value = i64(cleanup.unmeasured)},
		{key = "scan_limited", value = cleanup.scan_limited},
	}
	agent.log_emit(agent.Log_Record{level = .Info, category = .Diagnostics, event = "retention.finished", fields = retention[:]})
}

// run_log_close frames the end of the launch and releases the writer. It runs after
// the session is closed, so the record covers everything the launch did, and it
// must run while the caller is still inside the scope that installed the logger.
// The close error is returned rather than recorded, because it cannot be recorded
// in the log it closes.
run_log_close :: proc(setup: ^Run_Setup) -> agent.Log_Error {
	if !setup.log.open { return nil }
	health := agent.log_health(&setup.log)
	fields := [3]agent.Log_Field{{key = "written", value = health.written}, {key = "omitted", value = health.omitted}, {key = "failed", value = health.failed}}
	agent.log_emit(agent.Log_Record{level = .Info, category = .Runtime, event = "run.finished", fields = fields[:]})
	// Nothing is buffered, so every record that was accepted has already been
	// written; there is nothing left to flush.
	return agent.log_close(&setup.log)
}

// run_log_failure surfaces a latched sink failure once, on stderr, so a user
// learns that diagnostics stopped instead of quietly reading an incomplete file.
// It is safe to call at any work boundary and from either thread.
run_log_failure :: proc(setup: ^Run_Setup, reported: ^bool) {
	if reported^ || !setup.log.open { return }
	if !agent.log_health(&setup.log).failed { return }
	reported^ = true
	fmt.eprintln("nabla: warning: diagnostic logging stopped; the log file is incomplete")
}

// log_session_claimed records that this process took a session for writing. Every
// adoption path calls it, so a launch and an in-session switch report the same
// fact rather than only the launch path doing so. The recovery summary is recorded
// only when an earlier run actually left work to settle.
log_session_claimed :: proc(id: session.Session_Id, resumed: bool, recovery: session.Recovery) {
	if id == "" { return }
	binding: agent.Log_Binding
	context.logger = agent.log_rebind(&binding, agent.Log_Correlation{session_id = id})
	claimed := [1]agent.Log_Field{{key = "resumed", value = resumed}}
	agent.log_emit(agent.Log_Record{level = .Info, category = .Session, event = "session.claimed", fields = claimed[:]})
	if recovery.interrupted_turns > 0 || recovery.interrupted_requests > 0 || recovery.recovered_calls > 0 || recovery.unexecuted_calls > 0 {
		fields := [4]agent.Log_Field {
			{key = "interrupted_turns", value = i64(recovery.interrupted_turns)},
			{key = "interrupted_requests", value = i64(recovery.interrupted_requests)},
			{key = "recovered_calls", value = i64(recovery.recovered_calls)},
			{key = "unexecuted_calls", value = i64(recovery.unexecuted_calls)},
		}
		agent.log_emit(agent.Log_Record{level = .Info, category = .Session, event = "session.recovered", fields = fields[:]})
	}
}

// log_session_released records that this process gave a session up. It runs only
// after the claim is gone, so the record never claims more than happened.
log_session_released :: proc(id: session.Session_Id) {
	if id == "" { return }
	binding: agent.Log_Binding
	context.logger = agent.log_rebind(&binding, agent.Log_Correlation{session_id = id})
	agent.log_emit(agent.Log_Record{level = .Info, category = .Session, event = "session.released"})
}

// run_log_options reads the launch's diagnostic policy. An unusable value is
// reported once and the default is used, so a typo cannot silently choose a level
// the user did not ask for.
run_log_options :: proc() -> agent.Log_Options {
	options := agent.Log_Options {
		enabled = true,
		lowest  = .Info,
	}
	text, found := os.lookup_env(LOG_LEVEL_VARIABLE, context.temp_allocator)
	if !found { return options }

	level, enabled, known := agent.log_level_parse(text)
	if !known {
		fmt.eprintf("nabla: %s is not a log level, using info: %s\n", LOG_LEVEL_VARIABLE, text)
		return options
	}
	options.enabled = enabled
	options.lowest = level
	return options
}
