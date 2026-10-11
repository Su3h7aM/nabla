#+build !linux
package mcp

import "core:io"
import "core:os"

@(private, require_results)
stdio_set_nonblocking :: proc(file: ^os.File) -> os.Error {
	return io.Error.Unsupported
}
