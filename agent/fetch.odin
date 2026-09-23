package agent

import "core:mem"
import "core:sync"
import "nabla:ai"
import "nabla:http/client"

// Shared plumbing for the two stages that read a body over the network: the
// provider's own model listing and the models.dev catalog. Both accumulate a
// bounded response under a deadline, so that policy lives here once; the stages
// differ only in URL, credentials, and what they do with the bytes.

// Fetch_Body accumulates a response body and remembers whether the size bound was
// exceeded, which is what turns an oversized response into a failure rather than
// a short body.
Fetch_Body :: struct {
	bytes:    [dynamic]u8,
	overflow: bool,
	failed:   bool,
	limit:    int,
}

fetch_collect :: proc(user_data: rawptr, chunk: []u8) {
	body := cast(^Fetch_Body)user_data
	if body.failed { return }
	if len(body.bytes) + len(chunk) > body.limit {
		body.overflow = true
		return
	}
	written := append(&body.bytes, ..chunk)
	if written != len(chunk) { body.failed = true }
}

// fetch_body_finish hands the accumulated body to the caller as an exactly-sized
// slice and releases the accumulator. The accumulator's capacity is never shared
// with the result: a slice carries no capacity, so a shorter view of a larger
// allocation could not be freed correctly.
fetch_body_finish :: proc(body: ^Fetch_Body, allocator: mem.Allocator) -> ([]u8, bool) {
	defer delete(body.bytes)
	if body.failed || body.overflow || len(body.bytes) == 0 { return nil, false }
	result, alloc_err := make([]u8, len(body.bytes), allocator)
	if alloc_err != nil { return nil, false }
	copy(result, body.bytes[:])
	return result, true
}

Fetch_Control :: struct {
	deadline: ai.Deadline,
	cancel:   ^bool,
}

fetch_control_probe :: proc(user_data: rawptr) -> client.Wait_Status {
	control := cast(^Fetch_Control)user_data
	if control.cancel != nil && sync.atomic_load(control.cancel) { return .Cancelled }
	if ai.deadline_expired(control.deadline) { return .Timed_Out }
	return .Ready
}

// fetch_probe stops a request once its deadline passes, so a peer that accepts
// the connection and then stalls cannot hold up the harness.
fetch_probe :: proc(user_data: rawptr) -> client.Wait_Status {
	deadline := cast(^ai.Deadline)user_data
	if deadline != nil && ai.deadline_expired(deadline^) { return .Timed_Out }
	return .Ready
}
