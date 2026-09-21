#+test
#+private file
package main

import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "nabla:agent"

// The watcher is the only record of a front-end that stopped running, so its decision and
// its report are what the tests hold: a stall that is reported too eagerly is noise, and a
// report that never reaches the log is the silence the watcher exists to end.

// --- the stall decision -------------------------------------------------------

@(test)
test_watchdog_verdict_reports_only_a_still_count :: proc(t: ^testing.T) {
	// A loop that entered a phase recently is working.
	testing.expect_value(t, watchdog_verdict(0, 0, false), Watchdog_Verdict.Wait)
	testing.expect_value(t, watchdog_verdict(WATCHDOG_STALL - time.Millisecond, 0, false), Watchdog_Verdict.Wait)
	testing.expect_value(t, watchdog_verdict(WATCHDOG_STALL, 0, false), Watchdog_Verdict.Report)
}

@(test)
test_watchdog_verdict_closes_and_reopens_a_stall :: proc(t: ^testing.T) {
	// A reported stall repeats only once the interval has passed, so one stuck loop
	// does not fill the log with the same report.
	testing.expect_value(t, watchdog_verdict(WATCHDOG_STALL * 2, 0, true), Watchdog_Verdict.Wait)
	testing.expect_value(t, watchdog_verdict(WATCHDOG_STALL * 2, WATCHDOG_REPEAT, true), Watchdog_Verdict.Report)

	// A count that moved again ends the stall it reported, so the next still count is
	// a new one rather than a repetition of the last.
	testing.expect_value(t, watchdog_verdict(0, WATCHDOG_REPEAT, true), Watchdog_Verdict.Resumed)
	testing.expect_value(t, watchdog_verdict(WATCHDOG_STALL - time.Millisecond, 0, true), Watchdog_Verdict.Resumed)
}

// --- the thread dump ----------------------------------------------------------

@(test)
test_watchdog_thread_field_reads_past_the_command_name :: proc(t: ^testing.T) {
	// The command name is parenthesized and may itself contain spaces and parentheses,
	// so the state is the first field after the last one.
	line := `4242 (a (thread) name) S 1 4242 4242 0 -1 4194304 100 0 0 0 12 34`
	testing.expect_value(t, watchdog_thread_field(line, 1), "S")
	testing.expect_value(t, watchdog_thread_field(line, 2), "1")
	testing.expect_value(t, watchdog_thread_field(line, 12), "12")
	testing.expect_value(t, watchdog_thread_field(line, 13), "34")
	testing.expect_value(t, watchdog_thread_field(line, 14), "")
	testing.expect_value(t, watchdog_thread_field("", 1), "")
	testing.expect_value(t, watchdog_thread_field("1 (no state)", 1), "")
}

// --- the report ---------------------------------------------------------------

// A stalled front-end leaves the phase it stopped in, what the process was doing, and one
// record per thread. The last of those is the whole point: it says where a thread that
// never returned is waiting.
@(test)
test_watchdog_report_writes_the_stall_and_the_threads :: proc(t: ^testing.T) {
	test: Log_Fixture
	log_fixture_open(t, &test)
	defer log_fixture_close(t, &test)

	watchdog: Watchdog
	watchdog.binding = test.binding
	context.logger = test.logger
	sync.atomic_store(&watchdog.stage, u64(Ui_Stage.Drawing))
	watchdog_report(&watchdog, 20 * time.Second)
	// A record reaches the file when it is written, so closing first only proves the
	// reader is looking at everything the run produced.
	_ = agent.log_close(&test.sink)

	records := log_fixture_records(&test)
	if len(records) == 0 { testing.fail_now(t, "the report reached no log file") }
	testing.expectf(t, strings.contains(records, `"event":"ui.stalled"`), "no stall record: %s", records)
	testing.expectf(t, strings.contains(records, `"stage":"drawing"`), "the stall does not name the phase: %s", records)
	testing.expectf(t, strings.contains(records, `"viewport_ok":true`), "the stall does not report the terminal: %s", records)
	testing.expectf(t, strings.contains(records, `"event":"runtime.thread"`), "no thread was reported: %s", records)
	testing.expectf(t, strings.contains(records, `"waiting_on"`), "a thread record carries no wait: %s", records)
}

// A watcher that starts is a watcher that stops: the front-end joins it before it closes
// the log, so a watcher must not outlive the sink it writes to.
@(test)
test_watchdog_start_and_stop_own_the_thread :: proc(t: ^testing.T) {
	test: Log_Fixture
	log_fixture_open(t, &test)
	defer log_fixture_close(t, &test)

	app := App{}
	app.setup.log_binding = test.binding
	context.logger = test.logger
	if !testing.expect(t, watchdog_start(&app), "the watcher should start") { return }
	if app.watchdog.worker == nil { testing.fail_now(t, "the watcher thread was not recorded") }

	// Every phase the loop enters moves the count the watcher times.
	watchdog_stage(&app, .Waiting)
	watchdog_stage(&app, .Drawing)
	testing.expect_value(t, sync.atomic_load(&app.watchdog.beat), u64(2))
	testing.expect_value(t, Ui_Stage(sync.atomic_load(&app.watchdog.stage)), Ui_Stage.Drawing)
	watchdog_observe(&app, true, false)
	testing.expect(t, sync.atomic_load(&app.watchdog.busy), "a running turn should be published")
	testing.expect(t, !sync.atomic_load(&app.watchdog.viewport_ok), "an unreported size should be published")

	testing.expect(t, watchdog_stop(&app), "the watcher should retire")
	testing.expect(t, app.watchdog.worker == nil, "the watcher should be joined and released")
}
