package http

import "base:runtime"

import "core:io"
import "core:strings"

// url_resolve resolves reference against base according to RFC 3986 section 5.
// The caller owns the returned string and releases it with delete and allocator.
// Empty query and fragment delimiters are preserved. Neither input is validated.
@(require_results)
url_resolve :: proc(base, reference: string, allocator := context.allocator) -> (resolved: string, err: runtime.Allocator_Error) {
	base_parts := reference_parse(base)
	parts := reference_parse(reference)
	path: string
	merged_path: string
	defer delete(merged_path, allocator)
	if _, has_scheme := parts.scheme.?; has_scheme {
		path = parts.path
	} else {
		parts.scheme = base_parts.scheme
		if _, has_authority := parts.authority.?; has_authority {
			path = parts.path
		} else {
			parts.authority = base_parts.authority
			if parts.path == "" {
				parts.path = base_parts.path
				if _, has_query := parts.query.?; !has_query { parts.query = base_parts.query }
			} else if strings.has_prefix(parts.path, "/") {
				path = parts.path
			} else {
				prefix := base_parts.path
				if _, base_has_authority := base_parts.authority.?; base_has_authority && prefix == "" {
					prefix = "/"
				} else if slash := strings.last_index_byte(prefix, '/'); slash >= 0 {
					prefix = prefix[:slash + 1]
				} else {
					prefix = ""
				}
				merged_path = strings.concatenate({prefix, parts.path}, allocator) or_return
				path = merged_path
			}
		}
	}
	builder := strings.builder_make(allocator) or_return
	defer strings.builder_destroy(&builder)
	if scheme, present := parts.scheme.?; present {
		if !reference_write(&builder, scheme, ":") { return "", .Out_Of_Memory }
	}
	if authority, present := parts.authority.?; present {
		if !reference_write(&builder, "//", authority) { return "", .Out_Of_Memory }
	}
	if path != "" {
		if !reference_path_write(&builder, path) { return "", .Out_Of_Memory }
	} else if !reference_write(&builder, parts.path) {
		return "", .Out_Of_Memory
	}
	if query, present := parts.query.?; present {
		if !reference_write(&builder, "?", query) { return "", .Out_Of_Memory }
	}
	if fragment, present := parts.fragment.?; present {
		if !reference_write(&builder, "#", fragment) { return "", .Out_Of_Memory }
	}
	return strings.clone(strings.to_string(builder), allocator)
}

@(private)
Reference :: struct {
	scheme:    Maybe(string),
	authority: Maybe(string),
	path:      string,
	query:     Maybe(string),
	fragment:  Maybe(string),
}

@(private)
reference_parse :: proc(raw: string) -> (parts: Reference) {
	rest := raw
	if index := strings.index_byte(rest, '#'); index >= 0 {
		parts.fragment = rest[index + 1:]
		rest = rest[:index]
	}
	if index := strings.index_byte(rest, '?'); index >= 0 {
		parts.query = rest[index + 1:]
		rest = rest[:index]
	}
	if colon := strings.index_byte(rest, ':'); colon > 0 {
		valid := true
		for character, i in rest[:colon] {
			letter := character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z'
			valid &&= letter || i > 0 && (character >= '0' && character <= '9' || character == '+' || character == '-' || character == '.')
		}
		if valid {
			parts.scheme = rest[:colon]
			rest = rest[colon + 1:]
		}
	}
	if strings.has_prefix(rest, "//") {
		rest = rest[2:]
		end := strings.index_byte(rest, '/')
		if end < 0 { end = len(rest) }
		parts.authority = rest[:end]
		rest = rest[end:]
	}
	parts.path = rest
	return
}

@(private)
@(require_results)
reference_write :: proc(builder: ^strings.Builder, parts: ..string) -> bool {
	for part in parts {
		if strings.write_string(builder, part) != len(part) { return false }
	}
	return true
}

// reference_path_write implements the remove_dot_segments algorithm in RFC 3986 5.2.4.
@(private)
@(require_results)
reference_path_write :: proc(builder: ^strings.Builder, path: string) -> bool {
	start := len(builder.buf)
	rest := path
	for rest != "" {
		switch {
		case strings.has_prefix(rest, "../"):
			rest = rest[3:]
		case strings.has_prefix(rest, "./"):
			rest = rest[2:]
		case strings.has_prefix(rest, "/./"):
			rest = rest[2:]
		case rest == "/.":
			rest = "/"
		case strings.has_prefix(rest, "/../"), rest == "/..":
			rest = rest[3:] if len(rest) > 3 else "/"
			output := string(builder.buf[start:])
			slash := strings.last_index_byte(output, '/')
			if resize_err := resize(&builder.buf, start + max(slash, 0)); resize_err != nil { return false }
		case rest == ".", rest == "..":
			rest = ""
		case:
			from := 1 if rest[0] == '/' else 0
			end := strings.index_byte(rest[from:], '/')
			end = end + from if end >= 0 else len(rest)
			if !reference_write(builder, rest[:end]) { return false }
			rest = rest[end:]
		}
	}
	return true
}

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
	rest := raw

	if index := strings.index_byte(rest, '#'); index >= 0 {
		url.fragment = rest[index + 1:]
		rest = rest[:index]
	}
	if index := strings.index_byte(rest, '?'); index >= 0 {
		url.query = rest[index + 1:]
		rest = rest[:index]
	}
	if index := strings.index(rest, "://"); index >= 0 {
		url.scheme = rest[:index]
		rest = rest[index + 3:]
	}
	if index := strings.index_byte(rest, '/'); index >= 0 {
		url.host = rest[:index]
		url.path = rest[index:]
	} else {
		url.host = rest
	}
	return
}

// request_path_write writes the origin-form request target of a URL.
@(require_results)
request_path_write :: proc(writer: io.Writer, target: URL) -> io.Error {
	io.write_string(writer, target.path if target.path != "" else "/") or_return
	if target.query != "" {
		io.write_byte(writer, '?') or_return
		io.write_string(writer, target.query) or_return
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
