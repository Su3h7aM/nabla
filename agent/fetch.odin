package agent

import "core:mem"

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
	limit:    int,
}

fetch_collect :: proc(user_data: rawptr, chunk: []u8) {
	body := cast(^Fetch_Body)user_data
	if len(body.bytes) + len(chunk) > body.limit {
		body.overflow = true
		return
	}
	append(&body.bytes, ..chunk)
}

// fetch_body_finish hands the accumulated body to the caller as an exactly-sized
// slice and releases the accumulator. The accumulator's capacity is never shared
// with the result: a slice carries no capacity, so a shorter view of a larger
// allocation could not be freed correctly.
fetch_body_finish :: proc(body: ^Fetch_Body, allocator: mem.Allocator) -> ([]u8, bool) {
	defer delete(body.bytes)
	if body.overflow || len(body.bytes) == 0 { return nil, false }
	result := make([]u8, len(body.bytes), allocator)
	copy(result, body.bytes[:])
	return result, true
}

// fetch_probe stops a request once its deadline passes, so a peer that accepts
// the connection and then stalls cannot hold up the harness.
fetch_probe :: proc(user_data: rawptr) -> client.Wait_Status {
	deadline := cast(^ai.Deadline)user_data
	if deadline != nil && ai.deadline_expired(deadline^) { return .Timed_Out }
	return .Ready
}
