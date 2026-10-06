// Package subprocess starts a child program in its own process group and stops it again.
//
// It is a library, not part of the harness. It imports only `core:` and knows nothing about what
// the child is for. The caller makes the child's pipes with `core:os`, hands the child's ends to
// `start`, and keeps its own ends. A started child is watched through a descriptor that becomes
// readable when it exits, so one `poll` can wait for the child and its pipes together.
//
// The child leads a new process group, so `terminate_group` reaches the whole tree the child
// started: SIGTERM, a grace period, then SIGKILL. `core:os.process_start` cannot do this, because
// it has no pre-exec hook and a group made by the parent after exec fails with EACCES.
//
// Only Linux has a backend. Other targets report every start as unsupported.
package subprocess
