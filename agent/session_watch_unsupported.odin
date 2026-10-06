#+build !linux
package agent

import "core:io"
import "core:os"

// Targets without inotify cannot watch a session's lock file, so a shared session is never
// woken by another process.

Session_Watch_Id :: distinct i32

Session_Watch :: struct {}

session_watch_add :: proc(watch: ^Session_Watch, lock_path: string) -> (id: Session_Watch_Id, error: os.Error) {
	return 0, io.Error.Unsupported
}

session_watch_remove :: proc(watch: ^Session_Watch, id: Session_Watch_Id) {  }

session_watch_stop :: proc(watch: ^Session_Watch) {  }
