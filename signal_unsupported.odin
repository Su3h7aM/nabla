#+build !linux
#+build !darwin
#+build !netbsd
#+build !openbsd
#+build !freebsd
package main

import "core:os"

@(require_results)
signal_catch_pipe :: proc() -> os.Error {
	return nil
}
