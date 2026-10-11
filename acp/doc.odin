// Package acp is the Agent Client Protocol: the JSON-RPC envelope, the
// newline-delimited framing, the payload shapes both roles exchange, and a writer
// that emits them.
//
// Both sides are described here, and only what ACP defines. messages.odin names the methods a client calls, the
// notifications an agent sends, the struct each side's document decodes into, and the
// protocol version this package speaks. Nothing in the package knows about the
// harness: a session id is opaque, a prompt is content blocks, an update is a JSON
// document, and the stream the frames travel on belongs to the caller.
// An implementation's own keys, such as a session title in a request's `_meta`, stay with the
// caller, so `_meta` on a session request is a json.Value.
//
// parse_envelope reads one message into a typed Envelope whose kind says whether it
// is a request, a notification, or a response, and leaves params and result as JSON
// because their shape belongs to the method. parse_batch splits a JSON-RPC batch into
// one frame per member, so every member is held to the same per-message rules. A
// stream is read as frames with a bufio.Scanner that frame_scanner_init prepares: it
// splits at newlines with frame_split, so bytes after the last newline are a message
// the peer never finished, and it imposes no size limit, since the protocol has none:
// its buffer grows to hold whatever the peer sends. A token borrows the scanner's
// buffer until the next scan. frame_check refuses a frame as empty or non-UTF-8; the
// caller drops it whole and scans on, so one bad frame does not hide the frames behind it.
//
// What the decoding side allocates, it owns, with the allocator it was given:
// destroy_envelope releases an Envelope, frame_strings_destroy releases a list of
// frames such as parse_batch returns, and the caller's bufio.scanner_destroy releases
// the scanner's buffer.
//
// A Writer encodes each complete frame before transferring its owned bytes to an
// unbounded FIFO. One writer thread owns the stream, so senders never wait for I/O
// and frames keep queue order. The write_* sends return a Write_Error instead of a
// boolean: a lost response closes the writer, since its peer would wait for the
// answer forever, while a lost notification or request is only reported.
// writer_failed reports the closure and later sends fail. writer_destroy drains
// queued frames for the
// caller's shutdown patience, then abandons a writer thread still blocked in I/O.
// A method whose name starts with an underscore is an extension: an unknown extension request
// is answered with ERROR_METHOD_NOT_FOUND like any other unknown request, and an unknown
// notification is ignored. Every wire struct carries the `_meta` the specification gives its
// object as a json.Value, nil when absent.
// A refusal is a value instead: a frame or a message a peer's answer cannot be built
// from is reported as Frame_Error or Envelope_Error, with the sentence a client reads
// from frame_error_text or envelope_error_text.
package acp
