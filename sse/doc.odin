// Package sse is Server-Sent Events framing: parsing an application/event-stream
// byte stream into events, writing events back out in the same format, and the
// POST that asks for a stream. It is a library, not part of the harness, and it
// knows nothing about sessions, models, or terminals.
//
// The behaviour follows the WHATWG HTML Standard, "Server-sent events": the
// event stream format and its interpretation algorithm. The grammar sets no size
// bound on lines or events, so the parser accumulates without one, and a
// provider may send an event of any size and it still parses.
//
// The parser is a pure state machine over bytes, with no I/O and no retained
// stream. parser_init prepares it and parser_destroy releases its buffers;
// parser_feed consumes chunks that may split anywhere, and parser_finish ends the
// stream. The parser borrows no input. A dispatched event runs through
// Event_Callback with strings that borrow parser storage and live only until the
// callback returns.
//
// A Parser is used by one thread at a time and holds no lock, so two threads may
// each run one. Failure is a runtime.Allocator_Error from the caller's allocator:
// the parser's buffers have no bound of their own, so a feed that failed leaves
// the stream where it stopped. Malformed input is not an error; the parser
// ignores, replaces, or accumulates it exactly as the standard requires.
//
// write_event builds an event into a caller's buffer, and post performs one POST
// through http/client that expects an event-stream response and delivers the body
// to a callback as it arrives. Transport policy, including the wait hook, stays
// with the caller.
package sse
