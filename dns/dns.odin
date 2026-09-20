// Package dns is a stub DNS resolver: it asks the caller's nameservers for
// records and reports what they answer. It owns the DNS mechanism — message
// validation, UDP/TCP exchange framing, truncation fallback, and the
// attempts-over-servers policy — and nothing else. Which servers to ask, how
// long to wait, when to stop, and what to do with answers are the caller's
// policy, carried in Options.
//
// The message codec, record model, and OS configuration readers live in
// core:net and are reused, not repeated here. What core does not provide is
// truncation-aware transport selection and response validation, which is
// what this package adds.
//
// Linux is the only target, like the rest of this repository.
package dns

import "core:mem"
import "core:net"
import "core:time"

// DNS_TIMEOUT bounds one server attempt when the caller names none. It
// matches the resolv.conf, Go, and hickory defaults of five seconds.
DNS_TIMEOUT :: 5 * time.Second

// DNS_IO_SLICE bounds one blocking wait inside an attempt. Short slices keep
// interruption prompt: the interrupt is checked between slices rather than
// after a whole timeout.
DNS_IO_SLICE :: 50 * time.Millisecond

// Error is why a lookup ended. Invalid_Request is caller misuse (a bad name,
// no servers, an oversized query). No_Answer means every server was tried
// without a usable answer, including attempts that ran out their own bound.
// Cancelled is the caller's interrupt.
Error :: enum {
	None,
	Invalid_Request,
	No_Answer,
	Cancelled,
}

// Interrupt is the caller's stop policy for one lookup. The check runs
// between wait slices and answers only whether to stop now; an empty check
// never stops.
Interrupt :: struct {
	check:     proc(user_data: rawptr) -> bool,
	user_data: rawptr,
}

// interrupt_now asks the policy whether the lookup should stop.
interrupt_now :: proc(interrupt: Interrupt) -> bool {
	if interrupt.check == nil { return false }
	return interrupt.check(interrupt.user_data)
}

// Options carries caller policy for one lookup. Servers are borrowed for the
// call. A non-positive timeout selects DNS_TIMEOUT; a non-positive attempts
// selects one pass over the servers.
Options :: struct {
	servers:   []net.Endpoint,
	timeout:   time.Duration,
	attempts:  int,
	interrupt: Interrupt,
}

// attempt_timeout resolves the per-server bound for these options.
attempt_timeout :: proc(options: Options) -> time.Duration {
	if options.timeout > 0 { return options.timeout }
	return DNS_TIMEOUT
}

// attempt_rounds resolves how many passes over the servers these options ask
// for.
attempt_rounds :: proc(options: Options) -> int {
	if options.attempts > 0 { return options.attempts }
	return 1
}

// lookup asks the configured servers for records of one type and returns the
// first usable answer. Servers are tried in order, and the order is repeated
// for the configured attempts; an interruption stops the lookup at the next
// slice boundary. Returned records are owned by the caller, released with
// net.destroy_dns_records.
lookup :: proc(hostname: string, kind: net.DNS_Record_Type, options: Options, allocator: mem.Allocator) -> (records: []net.DNS_Record, err: Error) {
	if !net.validate_hostname(hostname) { return nil, .Invalid_Request }
	if len(options.servers) == 0 { return nil, .Invalid_Request }
	if interrupt_now(options.interrupt) { return nil, .Cancelled }

	id, id_ok := query_id()
	if !id_ok { return nil, .Invalid_Request }
	packet_buffer: [net.DNS_PACKET_MIN_LEN]u8
	packet, packet_err := net.make_dns_packet(packet_buffer[:], id, hostname, kind)
	if packet_err != .None { return nil, .Invalid_Request }

	timeout := attempt_timeout(options)
	for _ in 0 ..< attempt_rounds(options) {
		for server in options.servers {
			answer, outcome := query_server(server, packet, id, kind, timeout, options.interrupt, allocator)
			switch outcome {
			case .Answer:
				if len(answer) == 0 {
					net.destroy_dns_records(answer, allocator)
					continue
				}
				// An answer completed before the interrupt fired is still
				// reported as interrupted: the caller stopped waiting for it.
				if interrupt_now(options.interrupt) {
					net.destroy_dns_records(answer, allocator)
					return nil, .Cancelled
				}
				return answer, .None
			case .Name_Error:
				// The name does not exist, so no other server can answer.
				net.destroy_dns_records(answer, allocator)
				return nil, .No_Answer
			case .Cancelled:
				net.destroy_dns_records(answer, allocator)
				return nil, .Cancelled
			case .Skip, .Retry_TCP:
				net.destroy_dns_records(answer, allocator)
				if interrupt_now(options.interrupt) { return nil, .Cancelled }
			}
		}
		if interrupt_now(options.interrupt) { return nil, .Cancelled }
	}
	return nil, .No_Answer
}
