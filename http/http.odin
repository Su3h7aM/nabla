/*
Package http is the HTTP/1.1 message vocabulary: methods, versions, field
sections, request targets, framing values, and dates, each read and written
as RFC 9110 and RFC 9112 define them. It moves no bytes; the client that does
lives in http/client.
*/
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
	return strings.trim(s, " \t")
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
	for c in transmute([]u8)text {
		digit: int
		switch c {
		case '0' ..= '9':
			digit = int(c - '0')
		case 'a' ..= 'f':
			digit = int(c - 'a') + 10
		case 'A' ..= 'F':
			digit = int(c - 'A') + 10
		case:
			return 0, false
		}
		if size > (max(int) - digit) / 16 { return 0, false }
		size = size * 16 + digit
	}
	return size, true
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

@(rodata, private)
METHOD_STRINGS := [Method]string {
	.Get     = "GET",
	.Post    = "POST",
	.Delete  = "DELETE",
	.Patch   = "PATCH",
	.Put     = "PUT",
	.Head    = "HEAD",
	.Connect = "CONNECT",
	.Options = "OPTIONS",
	.Trace   = "TRACE",
}

method_string :: proc(m: Method) -> string {
	return METHOD_STRINGS[m]
}

// method_parse reads a method token. Methods are case-sensitive (RFC 9110 9.1).
method_parse :: proc(m: string) -> (method: Method, ok: bool) {
	for text, candidate in METHOD_STRINGS {
		if text == m { return candidate, true }
	}
	return nil, false
}

// header_parse adds one field line to headers and returns its lowercase name.
// The name and value are copied with the headers' allocator.
//
// A repeated field is combined into one comma-separated value (RFC 9110 5.3),
// except Host, which may appear once (RFC 9112 3.2), and Content-Length: RFC
// 9112 6.3 makes differing repeats an unrecoverable error, and identical
// repeats stand for the first value.
header_parse :: proc(headers: ^Headers, line: string) -> (key: string, ok: bool) {
	// RFC 9112 5: field-line = field-name ":" OWS field-value OWS, and a field name
	// is a token, so a field line cannot begin with whitespace. RFC 9112 5.2 defines
	// obs-fold as OWS CRLF RWS, and RWS is SP or HTAB, so a line beginning with
	// either is a continuation rather than a field line.
	(len(line) > 0 && line[0] != ' ' && line[0] != '\t') or_return

	colon := strings.index_byte(line, ':')
	(colon > 0) or_return
	// RFC 9112 5.1: no whitespace is allowed between the field name and colon.
	(line[colon - 1] != ' ' && line[colon - 1] != '\t') or_return

	// RFC 9112 5.1: the field line value excludes the optional whitespace that
	// may precede and follow it.
	value := trim_ows(line[colon + 1:])
	allocator := headers._kv.allocator
	name := sanitize_key(headers^, line[:colon])

	key_ptr, value_ptr, just_inserted, insert_err := map_entry(&headers._kv, name)
	if insert_err != nil {
		delete(name, allocator)
		return
	}
	if just_inserted {
		cloned, clone_err := strings.clone(value, allocator)
		if clone_err != nil {
			delete_key(&headers._kv, name)
			delete(name, allocator)
			return
		}
		value_ptr^ = cloned
		return key_ptr^, true
	}
	delete(name, allocator)

	// RFC 9112 3.2: a server responds 400 to a request with more than one Host
	// field line, so a repeated Host is never combined.
	if key_ptr^ == "host" { return }
	if key_ptr^ == "content-length" {
		return key_ptr^, content_length_values_equal(value_ptr^, value)
	}
	combined, concat_err := strings.concatenate({value_ptr^, ", ", value}, allocator)
	if concat_err != nil { return }
	delete(value_ptr^, allocator)
	value_ptr^ = combined
	return key_ptr^, true
}

// header_fold continues field key with the value of an obs-fold line.
//
// RFC 9112 5.2 defines obs-fold as OWS CRLF RWS and requires a user agent that
// receives one in a response to replace it with one or more SP octets before the
// field value is interpreted. The continuation's leading whitespace is the RWS,
// and a continuation carrying nothing adds nothing, because trailing whitespace is
// excluded from the field value. A fold that continues no field is refused.
header_fold :: proc(headers: ^Headers, key, line: string) -> bool {
	value := trim_ows(line)
	if value == "" { return true }
	previous, found := &headers._kv[key]
	if !found { return false }
	allocator := headers._kv.allocator
	continued, concat_err := strings.concatenate({previous^, " ", value}, allocator)
	if concat_err != nil { return false }
	delete(previous^, allocator)
	previous^ = continued
	return true
}

// content_length_values_equal reports whether two Content-Length field values
// name the same length. Identical is by numeric meaning: leading zeros state the
// same length. The comparison strips them instead of parsing, so no representable
// bound limits which equal values are recognized.
@(private)
content_length_values_equal :: proc(a, b: string) -> bool {
	a_digits, a_ok := decimal_meaning(a)
	b_digits, b_ok := decimal_meaning(b)
	return a_ok && b_ok && a_digits == b_digits
}

// decimal_meaning validates a nonempty all-digit field value and reports its
// numeric meaning with leading zeros removed. A zero of any width reports "0".
@(private)
decimal_meaning :: proc(value: string) -> (meaning: string, ok: bool) {
	if len(value) == 0 { return "", false }
	for c in transmute([]u8)value {
		if !is_digit(c) { return "", false }
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
