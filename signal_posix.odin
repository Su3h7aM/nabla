#+build darwin, netbsd, openbsd, freebsd
package main

import "core:os"
import "core:sys/posix"

@(private = "file")
signal_pipe_handler :: proc "c" (signal: posix.Signal) {  }

// signal_catch_pipe makes our writes to closed pipes return errors while children start with the default SIGPIPE action.
// Call once at startup, before starting any thread or child.
@(require_results)
signal_catch_pipe :: proc() -> os.Error {
	action: posix.sigaction_t
	action.sa_handler = signal_pipe_handler
	if posix.sigaction(.SIGPIPE, &action, nil) != .OK { return os.Platform_Error(posix.errno()) }
	return nil
}
