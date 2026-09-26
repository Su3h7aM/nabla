package http

import "base:runtime"

import "core:io"
import "core:strings"

// URL is a split view of a URL. Every field is a slice of raw.
URL :: struct {
	raw:      string,
	scheme:   string,
	host:     string,
	path:     string,
	query:    string,
	fragment: string,
}

// url_parse splits a URL into its components without validating them.
//
// RFC 3986 3.5: the fragment begins at the first "#", and 3.4: the query at the
// first "?" before it. Both may hold ":" and "/", so they are cut before the
// authority is looked for.
url_parse :: proc(raw: string) -> (url: URL) {
	url.raw = raw
	s := raw

	if i := strings.index_byte(s, '#'); i >= 0 {
		url.fragment = s[i + 1:]
		s = s[:i]
	}
	if i := strings.index_byte(s, '?'); i >= 0 {
		url.query = s[i + 1:]
		s = s[:i]
	}
	if i := strings.index(s, "://"); i >= 0 {
		url.scheme = s[:i]
		s = s[i + 3:]
	}
	if i := strings.index_byte(s, '/'); i >= 0 {
		url.host = s[:i]
		url.path = s[i:]
	} else {
		url.host = s
	}
	return
}

// request_path_write writes the origin-form request target of a URL.
request_path_write :: proc(w: io.Writer, target: URL) -> io.Error {
	io.write_string(w, target.path if target.path != "" else "/") or_return
	if target.query != "" {
		io.write_byte(w, '?') or_return
		io.write_string(w, target.query) or_return
	}
	return nil
}

// request_path returns the origin-form request target of a URL, owned by the
// caller: its path, "/" when the path is empty, and its query. RFC 9112 3.2.1.
// The fragment is never part of a request target.
request_path :: proc(target: URL, allocator := context.allocator) -> (string, runtime.Allocator_Error) #optional_allocator_error {
	path := target.path if target.path != "" else "/"
	if target.query == "" { return strings.clone(path, allocator) }
	return strings.concatenate({path, "?", target.query}, allocator)
}
