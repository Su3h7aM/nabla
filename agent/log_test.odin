#+test
package agent

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent/journal"

@(test)
test_diag_emits_and_filters :: proc(test: ^testing.T) {
	ring := new(Diag_Ring)
	defer free(ring)
	ring.lowest = .Info
	session := journal.session_id_create()
	binding := Log_Binding {
		ring = ring,
		correlation = {session = session, turn = 3, request = 6, attempt = 1, call_id = "call_1"},
	}
	context.logger = log_logger(&binding)
	log_emit({level = .Debug, category = .Agent, event = "filtered"})
	fields := [2]Log_Field{{key = "api", value = "openai"}, {key = "body_bytes", value = i64(42)}}
	log_emit({level = .Info, category = .Provider, event = "provider.encoded", fields = fields[:]})

	entry: Diag_Entry
	if !testing.expect(test, diag_pop(ring, &entry), "the event is kept") { return }
	testing.expect_value(test, entry.level, log.Level.Info)
	testing.expect_value(test, entry.category, Log_Category.Provider)
	testing.expect_value(test, entry.session, session)
	testing.expect_value(test, entry.turn, journal.Turn_Id(3))
	testing.expect_value(test, entry.request, journal.Request_Id(6))
	testing.expect_value(test, entry.attempt, 1)
	testing.expect_value(test, string(entry.text[:entry.text_length]), "provider.encoded call_id=call_1 api=openai body_bytes=42")
	testing.expect(test, !diag_pop(ring, &entry), "the debug event was filtered")
}

@(test)
test_diag_cuts_long_text :: proc(test: ^testing.T) {
	ring := new(Diag_Ring)
	defer free(ring)
	binding := Log_Binding {
		ring = ring,
	}
	context.logger = log_logger(&binding)
	long_text := strings.repeat("x", DIAG_TEXT_MAX + 1, context.temp_allocator)
	log_emit({level = .Info, category = .Agent, event = long_text})
	entry: Diag_Entry
	if !testing.expect(test, diag_pop(ring, &entry), "long text is kept") { return }
	testing.expect_value(test, entry.text_length, DIAG_TEXT_MAX)
	testing.expect_value(test, string(entry.text[:entry.text_length]), long_text[:DIAG_TEXT_MAX])
}

@(test)
test_diag_drain_records_sessions_and_drops :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, "/tmp/diag-test")
	defer chat_test_end(test, &fixture)
	ring := new(Diag_Ring)
	defer free(ring)
	claimed := fixture.chat.session
	other := journal.session_id_create()
	binding := Log_Binding {
		ring = ring,
		correlation = {session = claimed},
	}
	context.logger = log_logger(&binding)
	log_emit({level = .Info, category = .Agent, event = "claimed.event"})
	other_binding := Log_Binding {
		ring = ring,
		correlation = {session = other},
	}
	context.logger = log_logger(&other_binding)
	log_emit({level = .Warning, category = .Tool, event = "other.event"})
	for _ in 0 ..< DIAG_RING_ENTRIES - 2 { log_emit({level = .Info, category = .Tool, event = "filler"}) }
	log_emit({level = .Info, category = .Tool, event = "dropped"})
	testing.expect_value(test, ring.dropped, u64(1))
	diag_drain(ring, &fixture.store)
	_, commit_error := journal.commit(&fixture.store)
	if commit_error != nil { testing.fail_now(test, "diagnostics could not be committed") }

	claimed_records, _, claimed_error := journal.read_records(&fixture.store, {session = claimed, kinds = {.Runtime_Message}}, 0, 0, context.allocator)
	if claimed_error != nil { testing.fail_now(test, "claimed diagnostics could not be read") }
	defer journal.records_destroy(claimed_records, context.allocator)
	testing.expect_value(test, len(claimed_records), 1)
	if len(claimed_records) > 0 {
		testing.expect_value(test, claimed_records[0].session, claimed)
		testing.expect(test, strings.contains(string(claimed_records[0].data), "claimed.event"))
	}
	other_records, _, other_error := journal.read_records(&fixture.store, {session = other, named = true, kinds = {.Runtime_Message}}, 0, 0, context.allocator)
	if other_error != nil { testing.fail_now(test, "named diagnostics could not be read") }
	defer journal.records_destroy(other_records, context.allocator)
	testing.expect_value(test, len(other_records), DIAG_RING_ENTRIES - 1)
	if len(other_records) > 0 {
		testing.expect_value(test, other_records[0].session, journal.Session_Id{})
		other_hex: [journal.SESSION_ID_HEX_LENGTH]u8
		testing.expect(test, strings.contains(string(other_records[0].data), journal.session_id_to_hex(other, other_hex[:])))
		testing.expect(test, strings.contains(string(other_records[0].data), "other.event"))
	}
	dropped_records, _, dropped_error := journal.read_records(&fixture.store, {kinds = {.Runtime_Message}}, 0, 0, context.allocator)
	if dropped_error != nil { testing.fail_now(test, "drop report could not be read") }
	defer journal.records_destroy(dropped_records, context.allocator)
	testing.expect(test, strings.contains(string(dropped_records[0].data), "1 diagnostic entries were dropped"))
	testing.expect_value(test, ring.dropped, u64(0))
}

@(test)
test_core_log_reaches_ring_with_location :: proc(test: ^testing.T) {
	ring := new(Diag_Ring)
	defer free(ring)
	binding := Log_Binding {
		ring = ring,
	}
	context.logger = log_logger(&binding)
	log.info("a plain message")
	entry: Diag_Entry
	if !testing.expect(test, diag_pop(ring, &entry), "the core message is kept") { return }
	testing.expect_value(test, entry.category, Log_Category.Runtime)
	text := string(entry.text[:entry.text_length])
	testing.expect(test, strings.contains(text, "a plain message"))
	testing.expect(test, strings.contains(text, "log_test.odin:"), "the caller location is kept")
}
