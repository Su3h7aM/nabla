package agent

import "core:fmt"
import "core:mem"
import "core:os"
import "core:sync"
import "core:time"
import "nabla:ai"
import "nabla:http/client"

// Shared plumbing for the two stages that read a response body over the network.

// Fetch_Body accumulates a response body. failed records an append that did not
// land, so a short body is reported as a failure.
Fetch_Body :: struct {
	bytes:  [dynamic]u8,
	failed: bool,
}

fetch_collect :: proc(body: ^Fetch_Body, chunk: []u8) {
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

// fetch_get performs one request and returns its body in an exactly-sized slice owned by
// allocator, or false when the request failed or the body is empty. The request ends early
// when cancel, if not nil, becomes true, or when timeout passes.
@(require_results)
fetch_get :: proc(request: client.Request, timeout: time.Duration, cancel: ^bool, allocator: mem.Allocator) -> ([]u8, bool) {
	body: Fetch_Body
	body.bytes.allocator = allocator
	control := Fetch_Control {
		deadline = ai.deadline_in(timeout),
		cancel   = cancel,
	}
	failure := client.stream_request(request, {probe = {check = fetch_control_probe, user_data = &control}}, &body, fetch_collect)
	if failure.kind != .None {
		delete(body.bytes)
		return nil, false
	}
	return fetch_body_finish(&body, allocator)
}

// fetch_cache_fresh reports whether the cached file at path is younger than max_age. A
// missing file, an unreadable timestamp, and a timestamp ahead of the clock are all stale, so
// a damaged cache is replaced rather than trusted.
@(require_results)
fetch_cache_fresh :: proc(path: string, now: time.Time, max_age: time.Duration) -> bool {
	modified, err := os.modification_time_by_path(path)
	if err != nil { return false }
	age := time.diff(modified, now)
	return age >= 0 && age < max_age
}

// fetch_cache_read returns a cached body when one is present and not empty. The result is
// owned by the caller.
@(require_results)
fetch_cache_read :: proc(path: string, allocator: mem.Allocator) -> ([]u8, bool) {
	body, read_err := os.read_entire_file(path, allocator)
	if read_err == nil && len(body) > 0 { return body, true }
	if body != nil { delete(body, allocator) }
	return nil, false
}

// fetch_cache_write publishes body through a temporary file in the same directory and renames
// it into place, so the visible cache is always complete and a write that fails or is
// interrupted leaves the previous one untouched. The temporary name carries the process id,
// so two concurrent refreshes cannot write to the same file; the rename is what publishes.
@(require_results)
fetch_cache_write :: proc(path: string, body: []u8) -> bool {
	temporary := fmt.tprintf("%s.%d.tmp", path, os.get_pid())
	if os.write_entire_file(temporary, body) != nil { return false }
	if os.rename(temporary, path) != nil {
		// A temporary file that cannot be removed is left behind; only the cache matters.
		_ = os.remove(temporary)
		return false
	}
	return true
}
