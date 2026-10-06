#+test
#+build linux
package agent

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

import "nabla:agent/journal"

SESSION_WATCH_TEST_WAIT :: 10 * time.Second

// A line a follower commits touches the session's lock file, and the watch turns that into
// an owner wake. The process runs alone, so no other test publishes a wake.
@(test)
test_a_commit_wakes_the_owner_through_the_session_watch :: proc(test: ^testing.T) {
	if !test_isolate_process(test, #procedure) { return }

	directory, directory_error := os.make_directory_temp("", "nabla-session-watch-*", context.allocator)
	if directory_error != nil { testing.fail_now(test, "could not create a temporary directory") }
	defer {
		_ = os.remove_all(directory) // The directory is abandoned; a failed removal changes nothing in a test.
		delete(directory)
	}

	runner, follower: journal.Journal
	open_error := journal.open(&runner, directory, directory, journal.run_id_create(), .Read_Write)
	if open_error != nil { testing.fail_now(test, fmt.tprintf("the runner journal did not open: %s", journal.error_text(open_error, context.temp_allocator))) }
	defer testing.expect(test, journal.close(&runner) == nil, "the runner journal should close")
	session, create_error := journal.create_session(&runner, {workspace = "/tmp/project", role = .Main})
	if create_error != nil { testing.fail_now(test, fmt.tprintf("the session was not created: %s", journal.error_text(create_error, context.temp_allocator))) }
	_, commit_error := journal.commit(&runner)
	testing.expect(test, commit_error == nil, "the session should commit")

	open_error = journal.open(&follower, directory, directory, journal.run_id_create(), .Read_Write)
	if open_error !=
	   nil { testing.fail_now(test, fmt.tprintf("the follower journal did not open: %s", journal.error_text(open_error, context.temp_allocator))) }
	defer testing.expect(test, journal.close(&follower) == nil, "the follower journal should close")
	testing.expect(test, journal.follow(&follower, session) == nil, "the session should be followed")

	hex_text: [journal.SESSION_ID_HEX_LENGTH]u8
	lock_path := fmt.tprintf("%s/%s.lock", directory, journal.session_id_to_hex(session, hex_text[:]))
	watch: Session_Watch
	defer session_watch_stop(&watch)
	id, watch_error := session_watch_add(&watch, lock_path)
	if watch_error != nil { testing.fail_now(test, fmt.tprintf("the lock file was not watched: %v", watch_error)) }
	defer session_watch_remove(&watch, id)

	seen := owner_wake_seen()
	testing.expect(test, journal.append_input(&follower, "wake the runner", .Steering) == nil, "the line should commit")
	deadline := time.tick_add(time.tick_now(), SESSION_WATCH_TEST_WAIT)
	for owner_wake_seen() == seen && time.tick_diff(time.tick_now(), deadline) > 0 { owner_wake_wait(seen, deadline) }
	testing.expect(test, owner_wake_seen() != seen, "a commit should wake the owner")
}
