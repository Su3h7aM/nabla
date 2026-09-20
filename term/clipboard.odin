package term

import "base:runtime"
import "core:encoding/base64"
import "core:fmt"
import "core:terminal/ansi"

// clipboard_set puts text on the terminal's clipboard through the OSC 52
// sequence (ansi.CLIPBOARD, base64-encoded), which is how a program that owns
// the mouse can still hand text to the terminal's own selection.
//
// The copy itself belongs to the terminal: a terminal that does not implement
// OSC 52, or that has clipboard writes disabled, ignores the sequence, and the
// write still reports the bytes it took. From here the two are
// indistinguishable, so `committed` is what this program wrote, not what the
// terminal kept.
//
// The sequence is one allocation, released before returning; unlike present,
// there is no caller scratch, because a copy is a user gesture rather than a
// per-frame write.
@(require_results)
clipboard_set :: proc(session: ^Session, text: string, allocator := context.allocator) -> (committed: int, err: Error) {
	if session == nil || !session.opened {
		return 0, General_Error.Not_Open
	}
	if text == "" {
		return 0, nil
	}
	sequence, sequence_err := _clipboard_sequence(text, allocator)
	if sequence_err != nil {
		return 0, sequence_err
	}
	defer delete(sequence, allocator)
	return _session_clipboard(session, transmute([]byte)sequence)
}

// _clipboard_sequence builds the OSC 52 write: the introducer, the clipboard
// selector, the base64 payload, and the terminator. BEL terminates it because
// that is the form terminals have accepted longest; ST is equivalent but older
// emulators recognise only one of the two.
@(require_results)
_clipboard_sequence :: proc(text: string, allocator: runtime.Allocator) -> (sequence: string, err: Error) {
	encoded, encode_err := base64.encode(transmute([]byte)text, allocator = allocator)
	if encode_err != nil {
		return "", encode_err
	}
	defer delete(encoded, allocator)
	return fmt.aprintf("%s%s;c;%s%s", ansi.OSC, ansi.CLIPBOARD, encoded, ansi.BEL, allocator = allocator), nil
}
