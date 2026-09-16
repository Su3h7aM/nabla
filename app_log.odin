package main

import "core:fmt"
import "core:os"

import "nabla:agent"
import "nabla:agent/session"

// Diagnostics for one launch. The writer is opened before the session database and
// closed after it, so a launch that cannot open either still leaves a record of how
// far it got. None of this is required for the harness to work: a log that cannot be
// opened is reported and the launch continues without one.

LOG_LEVEL_VARIABLE :: "NABLA_LOG_LEVEL"

// run_log_open resolves the launch's diagnostic policy, opens the writer, and
// records the run's own header.
run_log_open :: proc(setup: ^Run_Setup) {
	options := run_log_options()
	if options.level == .Disabled { return }

	directory, directory_err := agent.log_default_directory(context.temp_allocator)
	if directory_err != nil {
		fmt.eprintln("nabla: diagnostics are unavailable: the log directory could not be resolved")
		return
	}
	options.directory = directory

	if open_err := agent.log_open(&setup.log, options); open_err != nil {
		local := open_err
		fmt.eprintln("nabla: diagnostics are unavailable:", agent.log_error_detail(&local))
		return
	}

	fields := [3]agent.Log_Field {
		{key = "pid", value = i64(os.get_pid())},
		{key = "threshold", value = agent.log_level_name(options.level)},
		{key = "schema_version", value = i64(session.SCHEMA_VERSION)},
	}
	agent.log_emit(agent.Log_Context{log = &setup.log}, agent.Log_Record{level = .Info, category = .Runtime, event = "run.started", fields = fields[:]})
}

// run_log_close frames the end of the launch and releases the writer. It runs after
// the session is closed, so the record covers everything the launch did.
run_log_close :: proc(setup: ^Run_Setup) {
	health := agent.log_health(&setup.log)
	fields := [3]agent.Log_Field{{key = "written", value = health.written}, {key = "omitted", value = health.omitted}, {key = "failed", value = health.failed}}
	agent.log_emit(agent.Log_Context{log = &setup.log}, agent.Log_Record{level = .Info, category = .Runtime, event = "run.finished", fields = fields[:]})
	// A failure to close cannot be recorded in the log it closes. Nothing is
	// buffered, so every record that was accepted has already been written.
	_ = agent.log_close(&setup.log)
}

// run_log_options reads the launch's diagnostic policy. An unusable value is
// reported once and the default is used, so a typo cannot silently choose a level
// the user did not ask for.
run_log_options :: proc() -> agent.Log_Options {
	options := agent.Log_Options {
		level = .Info,
	}
	text, found := os.lookup_env(LOG_LEVEL_VARIABLE, context.temp_allocator)
	if !found { return options }

	level, known := agent.log_level_parse(text)
	if !known {
		fmt.eprintf("nabla: %s is not a log level, using info: %s\n", LOG_LEVEL_VARIABLE, text)
		return options
	}
	options.level = level
	return options
}
