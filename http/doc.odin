// Package http is HTTP/1.1 as RFC 9110 and RFC 9112 define it: the message
// grammar, and a server that answers with it.
//
// The grammar is methods, versions, request lines, field sections, framing values,
// URLs, dates, status codes, and cookies, and every form the RFCs refuse is refused
// here rather than guessed at. http/client shares the grammar and owns the client
// side. This package holds no client, no TLS, and no name resolution of its own, and
// it knows nothing about models, sessions, or terminals: what a handler decides to
// answer is the handler's policy, and this package only frames it.
//
// A Server is bound with listen and run with serve. serve starts one thread per
// Server_Opts.thread_count, or one per core by default, and serves each connection
// on the thread that accepted it. A handler runs on that thread and is given a
// Request and a Response that live in the connection's own growing arena, which the
// request loop resets with free_all between requests: a handler must not keep either
// past its return, and a request body it never read ends the connection instead of
// being read on its behalf. server_shutdown may run on any thread, reaching each
// server thread's event loop under the server's mutex. A message refused before a
// handler saw it is answered with the status the RFCs name for it (400, 414, 431,
// 500, 501, 505), and the connection closes when the rest of the stream can no
// longer be framed.
//
// # Lifetime
//
// headers_init sets the allocator that owns a section's map and every name and value
// header_parse copies into it; headers_destroy releases a section filled that way.
// headers_set lowercases the name with that allocator and borrows the value it
// stores. The server's request_init and response_init take the connection's arena and
// are released with it. A body of unknown length is framed by response_writer_init
// and ended with io.close or io.destroy.
package http
