// A byte-to-event input package: acquisition and normalization of
// terminal input, independent of the term package (sibling core-style
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
//   A wake descriptor (wake_make, wake_signal, wake_drain) lets another thread or
//   a signal handler end the wait early with zero events.
// - io.Reader is not the interactive seam: readiness and timeouts cannot be
//   expressed through core:io streams.
//
// Ownership: Parser is caller-owned; events are appended into a caller-owned
// dynamic array. read_events takes the byte source (the Session's os.File,
// handed over by the application); no terminal type crosses the boundary.
//
// Keys: legacy bytes, CSI and SS3 sequences keep their xterm modifier parameter, and the kitty
// `CSI code;modifiers:kind u` form is decoded with its event kind. ESC followed by a printable
// byte, Tab, Enter or Delete is one Alt key event; a lone ESC resolves to Escape after the deadline.
// Mouse reports are SGR (DECSET 1006) and carry modifiers. A sequence whose parameters do not fit
// the parser's buffer, or that this package does not decode, is Unknown_Input.
//
// Bracketed paste (DECSET 2004) is a parser-level event: the parser collects
// the bytes between CSI 200 ~ and CSI 201 ~ and emits one Paste event carrying
// them, so a multi-line paste is never decoded into keystrokes. The terminal
// mode itself is enabled and restored by the session, not here. Paste is the
// one event that owns memory; release the event list with events_clear or
// events_destroy. A paste arrives whole and is never shortened, and one whose
// closing marker never arrives is dropped with the parser.
//
// Errors: only resource failures are errors (poll, read, allocation).
// Partial sequences, malformed bytes, and EOF are events, never errors.
// Input never configures the tty; input-mode configuration stays with the
// terminal Session.
//
// Scope: Linux only. Platform-specific code lives in *_linux.odin files
// guarded by #+build tags.
package input
