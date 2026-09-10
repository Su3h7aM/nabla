// A byte-to-event input package: acquisition and normalization of
// terminal input, independent of the tty package (sibling core-style
// package).
//
// Three-layer seam (the acquisition and normalization split):
// - Parser: a pure push state machine over byte slices (feed). It retains
//   state across reads, performs no I/O, and owns no descriptors. Malformed
//   input normalizes to Unknown_Input events and resynchronizes.
// - Acquisition: read_events polls the descriptor, drains available bytes
//   into the parser, and reports the produced events. The ESC ambiguity is
//   resolved with a 50 ms deadline (capped poll), or immediately when more
//   bytes are already buffered.
// - io.Reader is not the interactive seam: readiness and timeouts cannot be
//   expressed through core:io streams.
//
// Ownership: Parser is caller-owned; events are appended into a caller-owned
// dynamic array. read_events takes the byte source (the Session's os.File,
// handed over by the application); no terminal type crosses the boundary.
//
// Errors: only resource failures are errors (poll, read, allocation).
// Partial sequences, malformed bytes, and EOF are events, never errors.
// Input never configures the tty; input-mode configuration stays with the
// terminal Session.
//
// Scope: Linux only. Platform-specific code lives in *_linux.odin files
// guarded by #+build tags.
package input
