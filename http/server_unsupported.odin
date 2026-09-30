#+build !linux
package http

import "core:io"
import "core:os"

@(private, require_results)
interrupt_notify_install :: proc(notify: ^os.File) -> os.Error {
	return io.Error.Unsupported
}
