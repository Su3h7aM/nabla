package session

import "core:math/rand"
import "core:strings"
import "core:time"

// Session_Id identifies one session: 128 random bits printed as 32 lowercase
// hexadecimal characters. The value carries no time and no ordering; sorting or
// dating a session comes from its header, never from its id.
Session_Id :: distinct string

// Turn_No, Request_No, and Seq are per-session counters. Each is a distinct
// type so one cannot be passed where another is expected.
Turn_No :: distinct i64
Request_No :: distinct i64
Seq :: distinct i64

SESSION_ID_LENGTH :: 32

// SESSION_LIST_DEFAULT_LIMIT is how many sessions session_list returns when the
// caller asks for no particular number.
SESSION_LIST_DEFAULT_LIMIT :: 50

// SESSION_LIST_MAX_LIMIT bounds one page, so a caller that asks for everything
// still gets an amount the front-end can render.
SESSION_LIST_MAX_LIMIT :: 500

// Session is one session's header. Every string is owned by the caller's
// allocator and released by session_destroy.
Session :: struct {
	id:             Session_Id, // owned
	created_at_ms:  i64,
	updated_at_ms:  i64,
	workspace:      string, // owned; the directory the session ran in
	title:          string, // owned; "" until the user or the harness names it
	provider:       string, // owned; the last provider used, "" when none
	model:          string, // owned; the last model used, "" when none
	archived_at_ms: Maybe(i64),
}

session_destroy :: proc(session: ^Session, allocator := context.allocator) {
	if session == nil { return }
	delete(string(session.id), allocator)
	delete(session.workspace, allocator)
	delete(session.title, allocator)
	delete(session.provider, allocator)
	delete(session.model, allocator)
	session^ = {}
}

// sessions_destroy releases a list returned by session_list.
sessions_destroy :: proc(sessions: []Session, allocator := context.allocator) {
	for &session in sessions { session_destroy(&session, allocator) }
	delete(sessions, allocator)
}

// Create_Options describes a new session. workspace is required; the rest may
// be empty and be filled in later.
Create_Options :: struct {
	workspace: string,
	title:     string,
	provider:  string,
	model:     string,
}

// Session_Cursor is where a session listing stopped. id is borrowed and only
// needs to live for the call.
Session_Cursor :: struct {
	updated_at_ms: i64,
	id:            Session_Id,
}

// List_Options filters and pages session_list. The zero value lists unarchived
// sessions from every workspace, newest activity first.
List_Options :: struct {
	// workspace, when not empty, lists only sessions that ran in that directory.
	workspace:        string,

	// include_archived lists archived sessions alongside the active ones.
	include_archived: bool,

	// used_only lists only sessions that hold work: one that has opened a turn,
	// made a request, or recorded an entry. A session is recorded by its first
	// prompt, so this is what a bare resume asks for, and it also passes over a row
	// whose first turn failed to land.
	used_only:        bool,

	// limit bounds one page. Zero uses SESSION_LIST_DEFAULT_LIMIT; a value above
	// SESSION_LIST_MAX_LIMIT is clamped.
	limit:            int,

	// after continues a previous listing. The listing is a live view: a session
	// whose activity changes between pages can move, so a page is not a snapshot.
	after:            Maybe(Session_Cursor),
}

// now_ms is the wall clock the store records with. Taking it in one place keeps
// every writer in a turn on the same clock.
now_ms :: proc() -> i64 {
	return time.time_to_unix_nano(time.now()) / 1_000_000
}

// session_id_create returns a fresh random session id allocated with allocator.
// A duplicate would need a 128-bit collision, so no uniqueness check is made.
session_id_create :: proc(allocator := context.allocator) -> Session_Id {
	random: [16]u8
	if rand.read(random[:]) != len(random) { return "" }
	text: [SESSION_ID_LENGTH]u8
	for byte, i in random {
		text[i * 2] = HEX_DIGITS[byte >> 4]
		text[i * 2 + 1] = HEX_DIGITS[byte & 0x0f]
	}
	return Session_Id(strings.clone(string(text[:]), allocator))
}

@(private)
HEX_DIGITS := "0123456789abcdef"

// session_id_valid reports whether id has the shape session_id_create produces,
// so a path built from it cannot escape the lock directory.
session_id_valid :: proc(id: Session_Id) -> bool {
	if len(id) != SESSION_ID_LENGTH { return false }
	for i in 0 ..< len(id) {
		switch id[i] {
		case '0' ..= '9', 'a' ..= 'f':
		case:
			return false
		}
	}
	return true
}
