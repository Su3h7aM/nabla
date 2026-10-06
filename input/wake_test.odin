#+build linux
#+test
#+private file
package input

import "core:os"
import "core:testing"

@(test)
test_read_events_returns_when_wake_is_signalled :: proc(t: ^testing.T) {
	reader, writer, pipe_err := os.pipe()
	testing.expect(t, pipe_err == nil, "pipe must open")
	defer _ = os.close(reader)
	defer _ = os.close(writer)
	wake, wake_err := wake_make()
	testing.expect(t, wake_err == nil, "wake must open")
	defer wake_destroy(wake)

	parser: Parser
	parser_init(&parser)
	defer parser_destroy(&parser)
	events: [dynamic]Event
	defer events_destroy(&events)

	// The tty stays silent and the timeout is infinite, so the call returns only
	// because the wake was written.
	wake_signal(wake)
	count, err := read_events(&parser, reader, &events, -1, wake)
	testing.expect(t, err == nil, "a wake is not an error")
	testing.expect_value(t, count, 0)

	wake_drain(wake)
	wake_signal(wake)
	count, err = read_events(&parser, reader, &events, -1, wake)
	testing.expect(t, err == nil && count == 0, "a drained wake can be signalled again")
}
