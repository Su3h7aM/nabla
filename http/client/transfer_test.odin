#+test
#+private file
package client

import "core:mem"
import "core:testing"

// The transport's own account of a request is the one observation a caller cannot
// make for itself: a truncated stream and a request that was never written both
// surface as a transport failure. These tests cover the paths that need no peer,
// which is every path before a connection exists; the paths past it are covered
// where a real server is available.

Transfer_Log :: struct {
	calls:   int,
	summary: Transfer_Summary,
}

transfer_log_complete :: proc(user_data: rawptr, summary: Transfer_Summary) {
	log := cast(^Transfer_Log)user_data
	log.calls += 1
	log.summary = summary
}

transfer_log_options :: proc(log: ^Transfer_Log) -> Options {
	return {observer = {user_data = log, complete = transfer_log_complete}}
}

// Every kind of failure owns its own detail, so one destructor releases any of
// them, and a tracking allocator is what proves nothing else was left behind.
@(test)
test_failure_destroy_releases_any_kind :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	failure := stream_request({url = "ftp://api.example.com/v1/messages", method = .Post, allocator = allocator}, {}, nil, nil)
	// A refused URL is a failure the transport never saw, and it still owns its text.
	testing.expect_value(t, failure.kind, Failure_Kind.Invalid_URL)
	testing.expect_value(t, failure.cause, Error.None)
	testing.expect_value(t, failure.detail, "URL scheme must be http or https")
	failure_destroy(&failure, allocator)

	for _, entry in track.allocation_map {
		testing.expectf(t, false, "the failure leaked %d bytes allocated at %v", entry.size, entry.location)
	}
}

@(test)
test_transfer_reports_a_request_that_was_never_written :: proc(t: ^testing.T) {
	// A URL this client refuses is not a failed request: nothing was resolved,
	// connected, or written, and the summary says exactly that.
	for url in ([]string{"ftp://api.example.com/v1/messages", "api.example.com/v1/messages"}) {
		log: Transfer_Log
		failure := stream_request({url = url, method = .Post, allocator = context.allocator}, transfer_log_options(&log), nil, nil)

		testing.expect_value(t, failure.kind, Failure_Kind.Invalid_URL)
		testing.expect_value(t, log.calls, 1)
		testing.expect_value(t, log.summary.stopped_at, Transfer_Phase.Validate)
		testing.expect_value(t, log.summary.request_bytes_accepted, u64(0))
		testing.expect_value(t, log.summary.request_body_bytes_accepted, u64(0))
		testing.expect(t, !log.summary.request_complete, "nothing was written")
		testing.expect(t, !log.summary.response_head_received, "nothing was read")
		testing.expect(t, !log.summary.declared_body_bytes_present, "an absent head declares nothing")
		failure_destroy(&failure, context.allocator)
	}

	// An empty host is refused at the same boundary, with the same account.
	log: Transfer_Log
	failure := stream_request({url = "https:///v1/messages", method = .Post, allocator = context.allocator}, transfer_log_options(&log), nil, nil)
	defer failure_destroy(&failure, context.allocator)
	testing.expect_value(t, failure.kind, Failure_Kind.Invalid_URL)
	testing.expect_value(t, log.summary.stopped_at, Transfer_Phase.Validate)
}

@(test)
test_a_zero_observer_is_no_observer :: proc(t: ^testing.T) {
	// Observing is opt-in, so a caller that wants none pays nothing and a zero
	// observer must not be reached through a nil callback.
	failure := stream_request({url = "ftp://api.example.com", method = .Post, allocator = context.allocator}, {}, nil, nil)
	defer failure_destroy(&failure, context.allocator)
	testing.expect_value(t, failure.kind, Failure_Kind.Invalid_URL)
}
