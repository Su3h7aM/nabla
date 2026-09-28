// Package client is a minimal HTTP/1.1 client whose blocking phases are
// interruptible. Readiness and deadlines are the transport's business and are
// answered by a core:nbio event loop; the caller supplies only an interruption
// policy, so it never has to poll a descriptor itself.
//
// It is a stopgap kept deliberately small: streaming bodies, verified TLS,
// deadlines, and cancellation are the whole requirement set, and nothing is added
// beyond them. It follows no redirect, reuses no connection, keeps no cookie jar,
// retries nothing, and speaks no version but 1.1. Cancellation and a deadline stay
// distinct from a transport failure all the way out, because reporting one as the
// other says something false about the peer. Name resolution is the one blocking
// phase a probe does not interrupt; it is bracketed instead.
//
// stream_request performs one request and delivers the body through a callback,
// whatever the status was, since a refused response still carries the peer's own
// account of it. upgrade_request performs a request that asks the peer to take the
// connection over, and returns an Upgraded handle for what lies above it, keeping
// the octets read past the response head. Both acquire the calling thread's event
// loop for as long as they run, so a caller holds none across the call. An Upgraded
// handle is bound to no thread: one thread at a time uses it, and each read or write
// waits on that thread's own loop. The connection, and the TLS session under it when
// the URL is https, have one I/O owner, and that is that thread.
//
// Request.allocator owns everything a call allocates for it: a Failure's detail, a
// response's field section, an Upgraded handle with its connection, and the reader
// buffer in between. A Failure is released with failure_destroy and the same
// allocator. Every call reports how the transfer ended through a Transfer_Summary,
// observed once on success and on every failure path, so a caller learns where the
// request stopped without inferring it from the error.
package client
