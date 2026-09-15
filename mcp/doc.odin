// Package mcp is a client for the Model Context Protocol, protocol version
// 2026-07-28.
//
// It is a library, not part of the harness. It imports nothing from `agent`,
// `ai`, or the presentation stack, and it knows nothing about sessions, models,
// or terminals. The adapter in `agent` maps what this package discovers into the
// same tool contract the native tools already use.
//
// The protocol revision is stateless. There is no initialization handshake and
// no protocol session: every request declares the version and the client's
// capabilities in `params._meta`, and `server/discover` reports what the server
// supports instead of negotiating it.
//
// What a transport reports is delivery, not execution. A request that was never
// written and one whose reply was lost are different facts, and only this package
// can tell them apart, so Error.delivery states which happened. The caller
// decides what that means: the harness never reissues an ambiguous `tools/call`,
// because the server may already have performed it.
//
// Message shapes are decoded into concrete types rather than into a generic RPC
// value. Only the operations the harness needs are implemented, and one that is
// not implemented is refused with a diagnostic instead of being half-handled.
package mcp
