// Package client is a minimal HTTP/1.1 client whose blocking phases are
// interruptible. Readiness and deadlines are the transport's business and are
// answered by a core:nbio event loop; the caller supplies only an interruption
// policy, so it never has to poll a descriptor itself.
//
// It stays deliberately small: streaming bodies, verified TLS, deadlines,
// cancellation, protocol upgrades, and CONNECT tunnels are the requirements. It
// follows no redirect, reuses no connection, keeps no cookie jar, retries nothing,
// and speaks no version but 1.1. Cancellation and a deadline stay distinct from a
// transport failure all the way out, because reporting one as the other says
// something false about the peer. Name resolution is the one blocking phase a
// probe does not interrupt; it is bracketed instead.
//
// stream_request performs one request and delivers the body through a callback,
// whatever the status was, since a refused response still carries the peer's own
// account of it. upgrade_request performs a request that asks the peer to take the
// connection over, and connect_request establishes a tunnel to an authority through
// a selected endpoint. Successful handoffs return an Upgraded handle for what lies
// above the HTTP exchange, keeping octets read past the response head. These calls
// acquire the calling thread's event loop for as long as they run, so a caller holds
// none across the call. An Upgraded handle is bound to no thread: one thread at a
// time uses it, and each read or write waits on that thread's own loop. The
// connection, and the TLS session under it when the URL is https, have one I/O
// owner, and that is that thread.
//
// stream_request and upgrade_request use Request.allocator for everything a call
// allocates; connect_request uses context.allocator. Each allocator owns the
// Failure detail, response fields, Upgraded handle with its connection, and reader
// buffer for that call. A Failure is released with failure_destroy and the same
// allocator. Every call reports how the transfer ended through a Transfer_Summary,
// observed once on success and on every failure path, so a caller learns where the
// request stopped without inferring it from the error.
package client
