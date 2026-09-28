// Package tls is a TLS 1.3 client: the record layer, the key schedule, and the
// handshake that reach a peer over a byte stream. It is a library, not part of
// the harness, and it knows nothing about HTTP, sessions, models, or terminals.
//
// It performs no I/O of its own and holds no clock. A caller supplies a
// Transport, the read and write calls that move bytes, and a Config, the trust
// anchors a chain may end at and the allocator every allocation uses. How bytes
// move, how long a wait may take, and how cancellation is reported stay with the
// caller, which is the only side that knows why a wait ended.
//
// init allocates a Conn and its buffers once, and destroy releases them, so a
// live connection moves no memory. handshake takes it through one TLS 1.3
// handshake, verifying the peer's chain against the roots and its identity
// against the name it was reached by. read and write then carry application
// data, and close sends the close_notify alert. Roots and Certificate_Chain own
// the DER they were decoded from and are released with roots_destroy and
// certificate_chain_destroy.
//
// A Conn is used by one thread at a time; it holds no lock. Failure is the Error
// enum, which names the caller's own transport failure, a record or handshake
// the peer sent that is not acceptable, or the alert the peer raised. write
// reports the bytes the record layer accepted, which is not evidence the peer
// has them.
package tls
