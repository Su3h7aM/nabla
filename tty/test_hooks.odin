#+build linux
package tty

// Test-only fault injection. Built exclusively by the PTY lifecycle
// executable with -define:NABLA_TTY_TEST_HOOKS=true (scripts/test);
// without the define none of this exists in the compilation, so the public
// surface is untouched. The hooks let the suite exercise teardown-retry and
// zero-progress write behavior that real ttys cannot produce
// deterministically. This file is deliberately NOT #+private: the hook
// procedures must be exported for the lifecycle executable, while the state
// they flip stays package-private for session_linux.odin to observe.
when #config(NABLA_TTY_TEST_HOOKS, false) {
	_test_fail_teardown_once: bool
	_test_zero_write_once: bool
	_test_fail_close_once: bool

	// Terminal_Test_Fail_Next_Teardown makes the next close fail with a
	// synthetic EIO before any compensation, leaving every transition flag
	// intact so the retry exercises the full teardown.
	Terminal_Test_Fail_Next_Teardown :: proc() {
		_test_fail_teardown_once = true
	}

	// Terminal_Test_Zero_Write_Next makes the next write loop report zero
	// progress with bytes pending (the narrow Partial_Write contract).
	Terminal_Test_Zero_Write_Next :: proc() {
		_test_zero_write_once = true
	}

	// Terminal_Test_Fail_Close_Next makes the next descriptor close report
	// a synthetic EIO after the real close has run, exercising the
	// report-and-settle path of the one-shot descriptor-close step.
	Terminal_Test_Fail_Close_Next :: proc() {
		_test_fail_close_once = true
	}
}
