#+test
#+private file
package session

import "core:testing"

@(test)
test_instruction_snapshot_round_trip_and_reject_second :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session := _open_claimed_session(t, &store)
	defer session_destroy(&session)

	_, present, read_err := instruction_snapshot_read(&store, session.id)
	_expect_ok(t, read_err)
	testing.expect(t, !present)

	seq, append_err := instruction_snapshot_append(
		&store,
		session.id,
		{format_version = INSTRUCTION_SNAPSHOT_VERSION, instructions = "work briefly", manifest_json = `{"version":1}`},
		2_000,
	)
	_expect_ok(t, append_err)
	testing.expect_value(t, seq, Seq(1))

	loaded, found, load_err := instruction_snapshot_read(&store, session.id)
	_expect_ok(t, load_err)
	if !testing.expect(t, found) { return }
	defer instruction_snapshot_destroy(&loaded)
	testing.expect_value(t, loaded.instructions, "work briefly")
	testing.expect_value(t, loaded.manifest_json, `{"version":1}`)
	testing.expect_value(t, loaded.seq, Seq(1))

	_, second_err := instruction_snapshot_append(
		&store,
		session.id,
		{format_version = INSTRUCTION_SNAPSHOT_VERSION, instructions = "other", manifest_json = `{"version":1}`},
		3_000,
	)
	_expect_error(t, second_err, .Invalid_Argument)

	ctx, context_err := context_load(&store, session.id)
	_expect_ok(t, context_err)
	defer context_destroy(&ctx)
	testing.expect_value(t, len(ctx.entries), 0)
}
