// Package dns is a stub DNS resolver: it asks the caller's nameservers for
// records and reports what they answer. It is a library, not part of the
// harness, and it knows nothing about sessions, models, or terminals.
//
// It owns the DNS mechanism and nothing else: message validation (whether a
// reply answers the query that was sent, and whether it is truncated or a Name
// Error), UDP exchange with a TCP retry when a reply does not fit a datagram,
// and the attempts-over-servers loop. The message codec, the record model, and
// the OS configuration readers live in core:net and are reused, not repeated
// here. Which servers to ask, how long to wait, when to stop, and what to do
// with an answer are the caller's policy, carried in Options and Interrupt.
//
// lookup is the entry point. It acquires the calling thread's core:nbio event
// loop for its duration and releases it before returning, so every wait is a
// blocking wait on that loop, bounded by one deadline per server attempt. The
// records it returns are owned by the caller and released with
// net.destroy_dns_records. hosts_lookup and system_nameservers read what the
// machine already knows, from the hosts file and the resolver configuration, and
// their results are owned by the caller too.
//
// A lookup runs on the calling thread and holds no other state, so two threads
// may each run one. Failure is the Error enum: Invalid_Request for caller misuse,
// No_Answer when every server was tried without a usable answer, Cancelled for
// the caller's interrupt, and No_Event_Loop when the thread's event loop could
// not be started.
package dns
