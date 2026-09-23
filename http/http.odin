package http

import "base:runtime"

import "core:io"
import "core:slice"
import "core:strings"
import "core:sync"

Requestline_Error :: enum {
	None,
	Method_Not_Implemented,
	Not_Enough_Fields,
	Invalid_Version_Format,
}

Requestline :: struct {
	method:  Method,
	target:  union {
		string,
		URL,
	},
	version: Version,
}

// A request-line begins with a method token, followed by a single space
// (SP), the request-target, another single space (SP), the protocol
// version, and ends with CRLF.
//
// This allocates a clone of the target, because this is intended to be used with a scanner,
// which has a buffer that changes every read.
requestline_parse :: proc(s: string, allocator := context.temp_allocator) -> (line: Requestline, err: Requestline_Error) {
	s := s

	next_space := strings.index_byte(s, ' ')
	if next_space == -1 { return line, .Not_Enough_Fields }

	ok: bool
	line.method, ok = method_parse(s[:next_space])
	if !ok { return line, .Method_Not_Implemented }
	s = s[next_space + 1:]

	next_space = strings.index_byte(s, ' ')
	if next_space == -1 { return line, .Not_Enough_Fields }

	line.target = strings.clone(s[:next_space], allocator)
	s = s[len(line.target.(string)) + 1:]

	line.version, ok = version_parse(s)
	if !ok { return line, .Invalid_Version_Format }

	return
}

requestline_write :: proc(w: io.Writer, rline: Requestline) -> io.Error {
	// odinfmt:disable
	io.write_string(w, method_string(rline.method)) or_return // <METHOD>
	io.write_byte(w, ' ')                           or_return // <METHOD> <SP>

	switch t in rline.target {
	case string: io.write_string(w, t)              or_return // <METHOD> <SP> <TARGET>
	case URL:    request_path_write(w, t)           or_return // <METHOD> <SP> <TARGET>
	}

	io.write_byte(w, ' ')                           or_return // <METHOD> <SP> <TARGET> <SP>
	version_write(w, rline.version)                 or_return // <METHOD> <SP> <TARGET> <SP> <VERSION>
	io.write_string(w, "\r\n")                      or_return // <METHOD> <SP> <TARGET> <SP> <VERSION> <CRLF>
	// odinfmt:enable

	return nil
}

Version :: struct {
	major: u8,
	minor: u8,
}

// version_parse reads the HTTP-version field of a start-line. It accepts the
// eight-octet form and, for lenience, the six-octet "HTTP/1" whose minor version
// is implicit. Every digit must actually be a digit: reading a non-digit as a
// number would turn a malformed field into a plausible version.
//
// RFC 9112 2.3: HTTP-version = HTTP-name "/" DIGIT "." DIGIT, where HTTP-name is
// the case-sensitive string "HTTP".
version_parse :: proc(s: string) -> (version: Version, ok: bool) {
	switch len(s) {
	case 8:
		(s[6] == '.') or_return
		(is_digit(s[7])) or_return
		version.minor = s[7] - '0'
		fallthrough
	case 6:
		(s[:5] == "HTTP/") or_return
		(is_digit(s[5])) or_return
		version.major = s[5] - '0'
	case:
		return
	}
	ok = true
	return
}

@(private = "package")
is_digit :: #force_inline proc(c: byte) -> bool {
	return c >= '0' && c <= '9'
}

// trim_ows strips optional whitespace, which is SP and HTAB only.
//
// RFC 9110 5.6.3: OWS = *( SP / HTAB ). It is narrower than
// strings.trim_space, which also removes VT, FF, CR and LF -- bytes the field
// value grammar does not admit in the first place.
trim_ows :: proc(s: string) -> string {
	start := 0
	for start < len(s) && (s[start] == ' ' || s[start] == '\t') { start += 1 }
	end := len(s)
	for end > start && (s[end - 1] == ' ' || s[end - 1] == '\t') { end -= 1 }
	return s[start:end]
}

// content_length_parse reads a Content-Length as RFC 9112 6.3 defines it:
// one or more decimal digits. A sign, whitespace, or an empty value is invalid
// framing rather than a negative or padded body size. The arithmetic is checked
// before multiplying so an unrepresentable value cannot become a truncated
// count.
content_length_parse :: proc(value: string) -> (size: int, ok: bool) {
	(len(value) > 0) or_return
	size = 0
	for character in value {
		if character < '0' || character > '9' { return 0, false }
		digit := int(character - '0')
		if size > (max(int) - digit) / 10 { return 0, false }
		size = size * 10 + digit
	}
	ok = true
	return
}

// chunk_size_parse reads a chunk-size as RFC 9112 7.1 defines it: one or more
// hexadecimal digits. A general number parser is the wrong tool here: it reads
// a sign prefix the grammar does not admit, so "+5" would parse as a size.
// Surrounding BWS is stripped; anything else, including an empty value or one
// the machine cannot represent, is invalid framing rather than a size.
chunk_size_parse :: proc(value: string) -> (size: int, ok: bool) {
	text := trim_ows(value)
	(len(text) > 0) or_return
	size = 0
	for i := 0; i < len(text); i += 1 {
		digit := 0
		switch text[i] {
		case '0' ..= '9':
			digit = int(text[i] - '0')
		case 'a' ..= 'f':
			digit = int(text[i] - 'a') + 10
		case 'A' ..= 'F':
			digit = int(text[i] - 'A') + 10
		case:
			return 0, false
		}
		if size > (max(int) - digit) / 16 { return 0, false }
		size = size * 16 + digit
	}
	ok = true
	return
}

version_write :: proc(w: io.Writer, v: Version) -> io.Error {
	io.write_string(w, "HTTP/") or_return
	io.write_rune(w, '0' + rune(v.major)) or_return
	if v.minor > 0 {
		io.write_rune(w, '.')
		io.write_rune(w, '0' + rune(v.minor))
	}

	return nil
}

version_string :: proc(v: Version, allocator := context.allocator) -> string {
	buf := make([]byte, 8, allocator)

	b: strings.Builder
	b.buf = slice.into_dynamic(buf)

	version_write(strings.to_writer(&b), v)

	return strings.to_string(b)
}

Method :: enum {
	Get,
	Post,
	Delete,
	Patch,
	Put,
	Head,
	Connect,
	Options,
	Trace,
}

_method_strings := [?]string{"GET", "POST", "DELETE", "PATCH", "PUT", "HEAD", "CONNECT", "OPTIONS", "TRACE"}

method_string :: proc(m: Method) -> string #no_bounds_check {
	if m < .Get || m > .Trace { return "" }
	return _method_strings[m]
}

method_parse :: proc(m: string) -> (method: Method, ok: bool) #no_bounds_check {
	// PERF: I assume this is faster than a map with this amount of items.

	for r in Method {
		if _method_strings[r] == m {
			return r, true
		}
	}

	return nil, false
}

// Parses the header and adds it to the headers if valid. The given string is copied.
header_parse :: proc(headers: ^Headers, line: string, allocator := context.temp_allocator) -> (key: string, ok: bool) {
	// RFC 9112 5: field-line = field-name ":" OWS field-value OWS, and a field name
	// is a token, so a field line cannot begin with whitespace. RFC 9112 5.2 defines
	// obs-fold as OWS CRLF RWS, and RWS is SP or HTAB, so a line beginning with
	// either is a continuation rather than a field line.
	(len(line) > 0 && line[0] != ' ' && line[0] != '\t') or_return

	colon := strings.index_byte(line, ':')
	(colon > 0) or_return

	// There must not be a space before the colon.
	(line[colon - 1] != ' ') or_return

	// TODO/PERF: only actually relevant/needed if the key is one of these.
	has_host := headers_has_unsafe(headers^, "host")
	cl, has_cl := headers_get_unsafe(headers^, "content-length")

	// RFC 9112 5.1: the field line value excludes the optional whitespace that
	// may precede and follow it, and OWS is SP and HTAB only.
	value := trim_ows(line[colon + 1:])
	tmp_key := sanitize_key(headers^, line[:colon])
	defer if !ok { delete(tmp_key, allocator) }

	// RFC 7230 5.4: Server MUST respond with 400 to any request
	// with multiple "Host" header fields.
	if tmp_key == "host" && has_host {
		return
	}

	// RFC 9112 6.3: a message received without Transfer-Encoding and with
	// either multiple Content-Length field lines having differing
	// field values or a single Content-Length field line having an
	// invalid value is invalid, and the recipient MUST treat it as an
	// unrecoverable error. Repeated values are identical only by numeric
	// meaning, so leading zeros do not differ; the first value stands and
	// no comma list is formed, which keeps a non-list field a single value.
	if tmp_key == "content-length" && has_cl {
		if !content_length_values_equal(cl, value) {
			return
		}
		delete(tmp_key, allocator)
		key_ptr, _, _ := headers_entry_unsafe(headers, "content-length")
		key = key_ptr^
		ok = true
		return
	}

	// RFC 9110 5.3: A recipient MAY combine multiple field lines within a field section
	// that have the same field name into one field line, without changing
	// the semantics of the message, by appending each subsequent field line
	// value to the initial field line value in order, separated by a comma
	// (",") and optional whitespace (OWS, defined in Section 5.6.3). For
	// consistency, use comma SP.
	key_ptr, value_ptr, just_inserted := headers_entry_unsafe(headers, tmp_key)
	if just_inserted {
		value = strings.clone(value, allocator)
	} else {
		value = strings.concatenate({value_ptr^, ", ", value}, allocator)
		delete(tmp_key, allocator)
		delete(value_ptr^, allocator)
	}
	key = key_ptr^
	value_ptr^ = value

	ok = true
	return
}

// content_length_values_equal reports whether two Content-Length field values
// name the same length. RFC 9112 6.3 permits repeats only when identical, and
// identical is by numeric meaning: leading zeros state the same length. The
// comparison strips them instead of parsing, so no representable bound limits
// which equal values are recognized.
@(private)
content_length_values_equal :: proc(a, b: string) -> bool {
	a_digits, a_ok := decimal_meaning(a)
	b_digits, b_ok := decimal_meaning(b)
	if !a_ok || !b_ok { return false }
	return a_digits == b_digits
}

// decimal_meaning validates a nonempty all-digit field value and reports its
// numeric meaning with leading zeros removed. A zero of any width reports
// "0", so widths of zero compare equal.
@(private)
decimal_meaning :: proc(value: string) -> (meaning: string, ok: bool) {
	if len(value) == 0 { return "", false }
	for c in value {
		if c < '0' || c > '9' { return "", false }
	}
	stripped := strings.trim_left(value, "0")
	if stripped == "" { return "0", true }
	return stripped, true
}

// Returns if this is a valid trailer header.
//
// RFC 7230 4.1.2:
// A sender MUST NOT generate a trailer that contains a field necessary
// for message framing (e.g., Transfer-Encoding and Content-Length),
// routing (e.g., Host), request modifiers (e.g., controls and
// conditionals in Section 5 of [RFC7231]), authentication (e.g., see
// [RFC7235] and [RFC6265]), response control data (e.g., see Section
// 7.1 of [RFC7231]), or determining how to process the payload (e.g.,
// Content-Encoding, Content-Type, Content-Range, and Trailer).
header_allowed_trailer :: proc(key: string) -> bool {
	// odinfmt:disable
	return (
		// Message framing:
		key != "transfer-encoding" &&
		key != "content-length" &&
		// Routing:
		key != "host" &&
		// Request modifiers:
		key != "if-match" &&
		key != "if-none-match" &&
		key != "if-modified-since" &&
		key != "if-unmodified-since" &&
		key != "if-range" &&
		// Authentication:
		key != "www-authenticate" &&
		key != "authorization" &&
		key != "proxy-authenticate" &&
		key != "proxy-authorization" &&
		key != "cookie" &&
		key != "set-cookie" &&
		// Control data:
		key != "age" &&
		key != "cache-control" &&
		key != "expires" &&
		key != "date" &&
		key != "location" &&
		key != "retry-after" &&
		key != "vary" &&
		key != "warning" &&
		// How to process:
		key != "content-encoding" &&
		key != "content-type" &&
		key != "content-range" &&
		key != "trailer")
	// odinfmt:enable
}

request_path_write :: proc(w: io.Writer, target: URL) -> io.Error {
	// TODO: maybe net.percent_encode.

	if target.path == "" {
		io.write_byte(w, '/') or_return
	} else {
		io.write_string(w, target.path) or_return
	}

	if len(target.query) > 0 {
		io.write_byte(w, '?') or_return
		io.write_string(w, target.query) or_return
	}

	return nil
}

request_path :: proc(target: URL, allocator := context.allocator) -> (rq_path: string) {
	res := strings.builder_make(0, len(target.path), allocator)
	request_path_write(strings.to_writer(&res), target)
	return strings.to_string(res)
}

_dynamic_unwritten :: proc(d: [dynamic]$E) -> []E {
	return (cast([^]E)raw_data(d))[len(d):cap(d)]
}

_dynamic_add_len :: proc(d: ^[dynamic]$E, len: int) {
	(transmute(^runtime.Raw_Dynamic_Array)d).len += len
}

@(private)
write_escaped_newlines :: proc(w: io.Writer, v: string) -> io.Error {
	for c in v {
		if c == '\n' {
			io.write_string(w, "\\n") or_return
		} else {
			io.write_rune(w, c) or_return
		}
	}
	return nil
}

@(private)
Atomic :: struct($T: typeid) {
	raw: T,
}

@(private)
atomic_store :: #force_inline proc(a: ^Atomic($T), val: T) {
	sync.atomic_store(&a.raw, val)
}

@(private)
atomic_load :: #force_inline proc(a: ^Atomic($T)) -> T {
	return sync.atomic_load(&a.raw)
}
