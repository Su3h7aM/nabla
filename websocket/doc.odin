// Package websocket is the WebSocket protocol (RFC 6455): the frame codec, and a
// connection that moves messages over whatever carries its bytes.
//
// It is a client. It masks every frame it sends, refuses a frame a server may not
// send masked, and never carries the bytes itself: a caller supplies the transport
// and so keeps its own deadline and cancellation. It offers no extension and serves
// no server role, and it opens no socket of its own: dial performs the opening
// handshake through http/client and leaves the socket and TLS session under the
// connection it returns.
//
// A Conn is what init or dial returns and destroy or abort releases, abort being for
// a path that must not wait on the peer. destroy closes the transport it was given,
// which is how a dialed connection's socket goes away; the transport, not this
// package, decides how long a read or a write may take. Every buffer is allocated
// once from the allocator init was handed, and a received payload is unmasked in the
// caller's own buffer, so a connection moves no memory while it is in use. A message
// of any size is sent as a sequence of frames, so none is refused for being large.
//
// A connection holds no lock and its transport calls block, so one thread at a time
// uses it.
//
// Failures are Error values. Protocol is a frame, or an order of frames, that the
// protocol forbids, and the connection is closed with the code the protocol names
// for it; Closed is the peer's close frame, and Abnormal_Closure is a stream that
// ended without one. Dial_Failure tells a handshake failure from a refused upgrade
// and owns its detail, released by dial_failure_destroy with the same allocator.
package websocket
