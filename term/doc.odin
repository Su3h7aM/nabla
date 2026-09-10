// Terminal session and presentation for interactive command-line programs.
//
// This package is the monorepo home of the enhanced core:terminal: a copy of
// Odin's built-in terminal package (capability detection, color depth, ansi
// constants) extended with terminal session and full-frame presentation
// functionality. It is designed as if submitting a PR to the Odin repository
// — API, naming, organization, and style follow the core conventions.
//
// The package is named `term` rather than `terminal` so that it can be imported
// by a package under `odin test`: Odin requires package names to be unique per
// compilation, and core:testing transitively imports core:terminal
// (testing/reporting.odin, runner.odin, signal_handler_libc.odin). `term` is
// also short enough to prefix every call, and unlike `tty` it never shadows a
// local: `tty` is the conventional name for a terminal file handle and this
// package is called from code that holds one.
//
// The suites in this package are nevertheless written against a package-local
// assertion harness (test_support.odin: a `T` context, `expect`, and a
// `run_tests` entry) rather than core:testing's `@(test)` declarations, so they
// run through the external harnesses in tests/tty_tests, tests/tui_tests, and
// tests/widgets_tests, all invoked by scripts/test. `odin test ./term` would
// compile the package and report success while executing nothing. The ansi
// subpackage is not imported here and its package name collides with
// core:terminal/ansi whenever core:testing is linked; the escape sequences are
// written as literals instead.
//
// The package computes and serializes terminal output and nothing else. It
// performs no layout, no text flow, no visual composition, and no input
// decoding (input lives in the sibling core:input package). It imports only
// core packages.
//
// Structure (core:os-shaped): session.odin holds the portable surface —
// Session { allocator, impl: Session_Impl, opened }, mirroring core:os's
// File/File_Impl split — and session_linux.odin is the platform file
// (the session extension's equivalent of terminal_posix.odin for the copied
// base), guarded by #+build linux + #+private, implementing the platform
// operations as direct procs (_session_open, _session_close, ...). The
// copied base keeps its own platform split (posix, windows, js, wasi stub)
// so the package remains multi-platform in shape. Every other extension file
// (present, errors, profile, viewport, color, style, cell, frame_buffer) is
// portable; targets without a backend compile the same public surface and
// return a typed General_Error.Unsupported from session operations
// (session_unsupported.odin, errors_unsupported.odin).
//
// Ownership and lifetime:
// - Session is a caller-owned handle. open allocates it with the caller's
//   allocator, stores that allocator in the session, and takes ownership of
//   the /dev/tty descriptor and terminal configuration (termios, file
//   flags, SIGWINCH disposition, alternate screen, cursor visibility).
//   close restores every entered transition and, on success, frees the
//   Session with its stored allocator — the caller never calls free on the
//   handle, and the pointer is dead after the one successful close.
//   close is retryable until it succeeds: a teardown failure reports the
//   first cause and leaves the session allocated in its current state for a
//   later retry; the descriptor close is one-shot (core:os consumes the
//   handle), so a failure there is reported and the next close settles the
//   session; close(nil) is a documented no-op. One active Session per
//   process: a second open fails with .Already_Open (file-scoped guard in
//   session_linux.odin, the raw_console @(private="file") pattern).
// - Input mode is explicit: Options.input_mode is Input_Mode, where
//   .Unchanged (the zero value) leaves the input configuration alone and
//   .Raw is the only mode that changes the input termios (clears
//   echo/canonical/signals, sets the descriptor nonblocking for the
//   drain-until-EAGAIN input path).
// - Frame_Buffer and Cell are pure data produced by the renderer and
//   consumed by present/encode. Their cell slices are borrowed for the call
//   duration only; the package never retains them.
// - Cursor_Intent is per-Frame input and is never retained by the Session.
//
// Viewport and resize:
// - viewport(session) is the authoritative cell size and the only public
//   resize contract: the caller compares it with the previous value once per
//   iteration, and a change invalidates width-dependent text measurements,
//   supplies the new root extent to layout, and forces a complete redraw.
//   There is no public resize-pending/signal API; a private SIGWINCH flag
//   remains an implementation optimization only.
// - Viewport has no pixel field in the v1 surface.
//
// Restoration guarantees:
// - close always attempts every applicable teardown transition even after
//   an earlier failure, and reports the first cause (the write path's own
//   error or the Platform_Error from the failed syscall). A transition flag
//   is cleared only when its compensation succeeded; on failure the Session
//   is left in its current state (descriptor and un-compensated transitions
//   intact, save the one-shot descriptor close itself) so close can be
//   retried. Control sequences and frames share one
//   write path that retries EINTR, waits for POLLOUT on EAGAIN (the tty is
//   O_NONBLOCK), and completes short writes, so a transient failure cannot
//   leave a sequence half-applied.
// - An atexit termios safety net is registered at open (raw mode only) as a
//   best-effort fallback for abnormal exits. SIGKILL, power loss, and
//   unhandled crashes are outside the guarantee.
// - A failed present leaves terminal contents and cursor state unspecified
//   until the next successful full frame: a hard write failure may occur
//   after a prefix has reached the terminal, and bytes already consumed
//   cannot be undone. There is no transactional acceptance. The caller
//   recovers with a later successful full frame or by closing the session;
//   every present re-establishes the Presentation Baseline (viewport origin
//   + base style) before any output.
//
// Frame validation and encoding:
// - present/encode validate the whole frame before a single byte is written:
//   dimensions and logical cell count (Invalid_Frame_Data), width (v1 is
//   width-1 only; any other width is .Unsupported), grapheme safety
//   (Invalid_Cell), and cursor bounds (Invalid_Cursor).
// - A non-empty Cell.grapheme must be valid UTF-8 and contain no C0
//   controls, C1 controls, or DEL — ESC included — so a cell can never
//   inject terminal control into the output stream.
// - The bottom-right physical cell is always reserved: the serializer never
//   writes it, because writing the corner can trigger autowrap scroll on
//   some terminals. Placing the cursor there is allowed.
// - The output path is caller-owned and reusable: encoded_size reports the
//   exact required byte count, encode serializes into the caller's scratch
//   (returning .Presentation_Workspace_Too_Small without writing a usable
//   prefix when the scratch is too small), and present preflights, encodes,
//   and writes one buffered sequence, returning the committed byte count.
//   Nothing allocates or retains output.
// - Zero-sized frames are deterministic no-ops (success, zero bytes) unless
//   the cursor intent is invalid.
//
// Color:
// - Color emission is depth-aware: authored colors reduce deterministically
//   to the profile's color depth — TrueColor as authored, 256-color via the
//   xterm cube (6x6x6), 16/8-color via the nearest ANSI palette entry
//   (ECMA-48 SGR 30-37/40-47, 90-97/100-107), and .None drops colors
//   entirely (the SGR reset still runs). profile_default() derives the depth
//   from the environment (NO_COLOR / COLORTERM / TERM); an explicit
//   Target_Profile passed to present/encode wins.
//
// Errors:
// - Error is the union of General_Error, io.Error, runtime.Allocator_Error,
//   and Platform_Error (per-platform, via the *_linux.odin indirection).
//   General_Error holds semantic states only (Not_Open, Already_Open,
//   Invalid_Frame_Data, Invalid_Cell, Invalid_Cursor, Unsupported,
//   Presentation_Workspace_Too_Small, Partial_Write, ...); syscall, ioctl,
//   termios, fcntl, poll, and nonzero-error write failures preserve their
//   underlying io.Error/Platform_Error cause. Partial_Write has one narrow
//   meaning: a write returned zero while bytes were pending, so there is no
//   errno to preserve. Recoverable failures are returned; only internal
//   invariant violations panic.
//
// Tests: the in-package suite exercises real, tty-free logic — encode bytes
// (fixture-driven, like the layout package's fixtures), validation, the
// env-based default profile, and the write loop (backpressure, EPIPE cause
// preservation). Session lifecycle against a real controlling terminal runs
// in tests/tty_lifecycle (single-threaded executable: allocator
// ownership, close-retry, resize, zero-progress Partial_Write, EINTR), and
// scripts/test runs the demo and dashboard under a PTY to a clean EOF exit.
//
// Scope: the public surface exists on every supported target; Linux is the
// first real backend (session_linux.odin), and other targets return typed
// .Unsupported from session operations. The copied core:terminal base keeps
// its own platform split (posix, windows, js, wasi stub).
package term
