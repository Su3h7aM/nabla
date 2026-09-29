package main

import "core:fmt"
import "core:log"
import "core:os"

import "nabla:agent"
import "nabla:agent/journal"

// Diagnostics for one launch go into a ring the setup owns, and reach the journal
// when an owner drains it: every commit of the running session, each worker item,
// and the launch's end. The caller installs the returned logger with
// `context.logger = ...` in the scope that owns the run.

LOG_LEVEL_VARIABLE :: "NABLA_LOG_LEVEL"

// run_log_open makes the launch's ring and returns the logger the caller installs.
// A launch with diagnostics off keeps the logger it has.
run_log_open :: proc(setup: ^Run_Setup) -> log.Logger {
	lowest, enabled := run_log_level()
	if !enabled { return context.logger }
	ring, ring_error := new(agent.Diag_Ring, setup.alloc)
	if ring_error != nil {
		fmt.eprintln("nabla: diagnostics are unavailable: the ring could not be allocated")
		return context.logger
	}
	ring.lowest = lowest
	setup.log_binding = agent.Log_Binding {
		ring = ring,
	}
	return agent.log_logger(&setup.log_binding)
}

// run_log_flush commits what the ring holds into the running session's journal.
// Owner thread only. A failed commit latches in the journal, where the session's
// next commit reports it.
run_log_flush :: proc(setup: ^Run_Setup) {
	if setup.store == nil { return }
	agent.diag_drain(setup.log_binding.ring, setup.store)
	_, _ = journal.commit(setup.store)
}

// run_log_close flushes the ring and releases it. It runs before the store closes.
// Entries emitted afterwards are discarded.
run_log_close :: proc(setup: ^Run_Setup) {
	ring := setup.log_binding.ring
	if ring == nil { return }
	run_log_flush(setup)
	setup.log_binding.ring = nil
	free(ring, setup.alloc)
}

// run_log_level reads the launch's threshold. An unusable value is reported once
// and info is used, so a typo cannot silently choose a level the user did not ask for.
@(require_results)
run_log_level :: proc() -> (lowest: log.Level, enabled: bool) {
	text, found := os.lookup_env(LOG_LEVEL_VARIABLE, context.temp_allocator)
	if !found { return .Info, true }
	level, level_enabled, known := agent.log_level_parse(text)
	if !known {
		fmt.eprintf("nabla: %s is not a log level, using info: %s\n", LOG_LEVEL_VARIABLE, text)
		return .Info, true
	}
	return level, level_enabled
}
