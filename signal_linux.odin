#+build linux
package main

import "core:os"
import "core:sys/linux"

@(private = "file")
signal_pipe_handler :: proc "c" (signal: linux.Signal) {  }

// signal_catch_pipe makes our writes to closed pipes return errors while children start with the default SIGPIPE action.
// Call once at startup, before starting any thread or child.
@(require_results)
signal_catch_pipe :: proc() -> os.Error {
	action := linux.Sig_Action {
		handler = signal_pipe_handler,
	}
	if errno := linux.rt_sigaction(.SIGPIPE, &action, nil); errno != .NONE { return os.Platform_Error(errno) }
	return nil
}
