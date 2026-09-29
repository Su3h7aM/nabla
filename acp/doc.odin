// Package acp is the Agent Client Protocol: the JSON-RPC envelope, the
// newline-delimited framing, the payload shapes both roles exchange, and a writer
// that emits them.
//
// Both sides are described here. messages.odin names the methods a client calls, the
// notifications an agent sends, the struct each side's document decodes into, and the
// protocol version this package speaks. Nothing in the package knows about the
// harness: a session id is opaque, a prompt is content blocks, an update is a JSON
// document, and the stream the frames travel on belongs to the caller.
//
// parse_envelope reads one message into a typed Envelope whose kind says whether it
// is a request, a notification, or a response, and leaves params and result as JSON
// because their shape belongs to the method. parse_batch splits a JSON-RPC batch into
// one frame per member, so every member is held to the same per-message rules. A
// Frame_Decoder turns a byte stream into frames and imposes no size limit, since the
// protocol has none: its buffer grows to hold whatever the peer sends. A frame
// refused as empty or non-UTF-8 is dropped whole and the decoder keeps reading, so
// one bad frame does not hide the frames behind it.
//
// What the decoding side allocates, it owns, with the allocator it was given:
// destroy_envelope releases an Envelope, frame_strings_destroy releases the frames
// frame_decoder_feed cloned, and frame_decoder_destroy releases the decoder.
//
// A Writer encodes each complete frame before transferring its owned bytes to an
// unbounded FIFO. One writer thread owns the stream, so senders never wait for I/O
// and frames keep queue order. A write error closes the writer; writer_failed reports
// it and later sends fail. writer_destroy drains queued frames for the
// caller's shutdown patience, then abandons a writer thread still blocked in I/O.
// A refusal is a value instead: a frame or a message a peer's answer cannot be built
// from is reported as Frame_Error or Envelope_Error, with the sentence a client reads
// from frame_error_text or envelope_error_text.
package acp
