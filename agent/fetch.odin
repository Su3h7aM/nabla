package agent

import "core:mem"
import "core:sync"
import "nabla:ai"
import "nabla:http/client"

// Shared plumbing for the two stages that read a response body over the network.

// Fetch_Body accumulates a response body. failed records an append that did not
// land, so a short body is reported as a failure.
Fetch_Body :: struct {
	bytes:  [dynamic]u8,
	failed: bool,
}

fetch_collect :: proc(user_data: rawptr, chunk: []u8) {
	body := cast(^Fetch_Body)user_data
	if body.failed { return }
	written, append_error := append(&body.bytes, ..chunk)
	if append_error != nil || written != len(chunk) { body.failed = true }
}

// fetch_body_finish copies the accumulated body into an exactly-sized slice and
// releases the accumulator. The result is owned by the caller.
@(require_results)
fetch_body_finish :: proc(body: ^Fetch_Body, allocator: mem.Allocator) -> ([]u8, bool) {
	defer delete(body.bytes)
	if body.failed || len(body.bytes) == 0 { return nil, false }
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
