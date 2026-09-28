#+test
package main

import "core:log"
import "core:strings"
import "core:testing"

import "nabla:agent"

// The test installs fixture.logger in its own scope; the fixture owns the ring.
Log_Fixture :: struct {
	ring:    ^agent.Diag_Ring,
	binding: agent.Log_Binding,
	logger:  log.Logger,
}

log_fixture_open :: proc(t: ^testing.T, fixture: ^Log_Fixture) {
	ring, allocation_error := new(agent.Diag_Ring, context.allocator)
	if allocation_error != nil { testing.fail_now(t, "the diagnostic ring could not be allocated") }
	fixture.ring = ring
	fixture.binding = agent.Log_Binding {
		ring = ring,
	}
	fixture.logger = agent.log_logger(&fixture.binding)
}

log_fixture_close :: proc(fixture: ^Log_Fixture) {
	free(fixture.ring, context.allocator)
}

log_fixture_records :: proc(fixture: ^Log_Fixture) -> string {
	builder := strings.builder_make(context.temp_allocator)
	entry: agent.Diag_Entry
	for agent.diag_pop(fixture.ring, &entry) {
		strings.write_string(&builder, string(entry.text[:entry.text_length]))
		strings.write_byte(&builder, '\n')
	}
	return strings.to_string(builder)
}
