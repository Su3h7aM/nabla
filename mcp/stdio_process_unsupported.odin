#+build !linux
package mcp

import "core:io"
import "core:os"

@(private)
Stdio_Signal_State :: struct {}

@(private, require_results)
stdio_sigpipe_ignore :: proc(previous: ^Stdio_Signal_State) -> os.Error {
	return io.Error.Unsupported
}

@(private)
stdio_sigpipe_restore :: proc(previous: ^Stdio_Signal_State) {  }

@(private, require_results)
stdio_set_nonblocking :: proc(file: ^os.File) -> os.Error {
	return io.Error.Unsupported
}
