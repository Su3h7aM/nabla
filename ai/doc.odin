// Package ai is a client for the model APIs a provider serves: the OpenAI Chat
// Completions, OpenAI Responses, and Anthropic Messages families over HTTP, plus a
// WebSocket transport for Responses.
//
// It is a library, not part of the harness. It imports the protocol libraries it is
// written on and no harness type, and it knows nothing about turns, sessions, retries,
// catalogs, journals, or terminals. Its vocabulary is one request, one attempt, and the
// events the endpoint sent; a caller decides whether a failure is sent again, what a
// model may be asked for, and what a response means.
//
// # One request, one attempt
//
// Provider_Request describes a request in its API family's own terms. Every optional
// field carries a presence flag, so an absent value stays distinct from a present zero,
// and Provider_Validate_Request refuses a request this package will not send.
//
// Provider_Encode_Request writes the request body as bytes. Provider_Request_Freeze
// validates and encodes once, returning those bytes as a Provider_Encoded_Request, so a
// caller that may send the same bytes more than once holds them: a retry then sends what
// the first attempt would have sent rather than a fresh encoding assumed to be equal.
//
// Provider_Request_Operation_Controlled performs one attempt: it encodes, sends, and
// decodes the response stream, delivering each event through a Provider_Event_Callback.
// Provider_Request_Operation_Encoded does the same from bytes that were frozen earlier.
// An attempt applies no policy of its own beyond the Interrupt and Deadline it is handed.
// Every event a callback receives is released when the callback returns, so a caller
// copies what it keeps, and at most one terminal event arrives: an error, or the
// completion once the transport has finished cleanly.
//
// # Encoding cache
//
// A conversation carries most of the previous request again, so Provider_Encode_Cache
// keeps the bytes already written for each text that has not changed. The caller owns the
// cache and a zero cache holds nothing; Provider_Encode_Cache_Destroy releases it, and one
// cache is walked by one encode at a time. It is an accelerator and never a source of
// truth: bytes are reused only for the text they were written for, so a body encoded with
// a cache is byte for byte the body encoded without one. The buffer the cache holds is
// also the buffer every request through it is written into.
//
// # Decoding
//
// Provider_Stream_Start, Provider_Consume_SSE_Data, Provider_Consume_Event_JSON,
// Provider_Stream_Drain, Provider_Stream_Finish, and Provider_Stream_Destroy decode a
// stream for a caller that owns the transport itself, which includes the WebSocket path.
// A stream owns the events it staged until they are drained, and a drained event belongs
// to whoever received it and is released with Provider_Event_Destroy.
//
// # Failures
//
// A failed attempt returns a Provider_Operation_Error. Its kind is what this attempt did,
// its delivery says how far a model send observably
// progressed, and its Provider_Failure_Class is the provider's own meaning for the
// refusal, read from what the provider said and what the transport observed. A refusal
// this package recognizes but cannot name stays Unknown rather than becoming retryable by
// accident, and an attempt that failed locally carries no provider class at all. Its
// provider_code, provider_request_id, and detail are owned by the caller and released with
// Provider_Operation_Error_Destroy.
//
// # Threads
//
// An attempt runs on the thread that calls it and blocks there, and its callbacks run on
// that same thread. Interrupt is a one-way token any thread may request, chained to a
// wider token, and Deadline is a monotonic bound; both are read while a request runs, and
// an accepted cancellation makes the attempt report Cancelled. A Provider_WebSocket_Session
// keeps one connection across sequential requests, used by one operation at a time; it
// replaces a socket the peer closed while it sat idle and sends that request again, which
// it does only when none of the response had arrived on it.
package ai
