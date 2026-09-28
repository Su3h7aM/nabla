/*
Package http is HTTP/1.1 as RFC 9110 and RFC 9112 define it: the message
grammar (methods, versions, request lines, field sections, framing values,
URLs, dates, status codes, cookies) and a server that runs on core:nbio. The
client lives in http/client and shares this grammar.
*/
package http

import "base:runtime"

import "core:io"
import "core:strings"
import "core:sync"

Requestline_Error :: enum {
	None,
	Method_Not_Implemented,
	Not_Enough_Fields,
	Invalid_Version_Format,
	// Allocation is the request target failing to be copied out of the line.
	Allocation,
}

Requestline :: struct {
	method:  Method,
	target:  union {
		string,
		URL,
	},
	version: Version,
}

// requestline_parse reads a request-line (RFC 9112 3): a method token, SP, a
// non-empty request-target, SP, and the protocol version. The target is cloned,
// because the line is a view into a buffer that changes on the next read.
@(require_results)
requestline_parse :: proc(text: string, allocator := context.temp_allocator) -> (line: Requestline, err: Requestline_Error) {
	method_end := strings.index_byte(text, ' ')
	if method_end <= 0 { return line, .Not_Enough_Fields }
	rest := text[method_end + 1:]
	target_end := strings.index_byte(rest, ' ')
	if target_end <= 0 { return line, .Not_Enough_Fields }

	ok: bool
	line.version, ok = version_parse(rest[target_end + 1:])
	if !ok { return line, .Invalid_Version_Format }
	line.method, ok = method_parse(text[:method_end])
	if !ok { return line, .Method_Not_Implemented }
	target, clone_err := strings.clone(rest[:target_end], allocator)
	if clone_err != nil { return line, .Allocation }
	line.target = target
	return line, .None
}

@(require_results)
requestline_write :: proc(writer: io.Writer, line: Requestline) -> io.Error {
	io.write_string(writer, method_string(line.method)) or_return
	io.write_byte(writer, ' ') or_return
	switch target in line.target {
	case string:
		io.write_string(writer, target) or_return
	case URL:
		request_path_write(writer, target) or_return
	}
	io.write_byte(writer, ' ') or_return
	version_write(writer, line.version) or_return
	io.write_string(writer, "\r\n") or_return
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
@(require_results)
version_parse :: proc(text: string) -> (version: Version, ok: bool) {
	switch len(text) {
	case 8:
		(text[6] == '.') or_return
		(is_digit(text[7])) or_return
		version.minor = text[7] - '0'
		fallthrough
	case 6:
		(text[:5] == "HTTP/") or_return
		(is_digit(text[5])) or_return
		version.major = text[5] - '0'
	case:
		return
	}
	ok = true
	return
}

// version_write writes the eight-octet HTTP-version (RFC 9112 2.3).
@(require_results)
version_write :: proc(writer: io.Writer, version: Version) -> io.Error {
	octets := [8]byte{'H', 'T', 'T', 'P', '/', '0' + version.major, '.', '0' + version.minor}
	_, err := io.write(writer, octets[:])
	return err
}

version_string :: proc(version: Version, allocator := context.allocator) -> (string, runtime.Allocator_Error) #optional_allocator_error {
	octets := [8]byte{'H', 'T', 'T', 'P', '/', '0' + version.major, '.', '0' + version.minor}
	return strings.clone(string(octets[:]), allocator)
}

@(private = "package", require_results)
is_digit :: #force_inline proc(character: byte) -> bool {
	return character >= '0' && character <= '9'
}

// is_tchar reports whether a byte may appear in a token (RFC 9110 5.6.2).
@(require_results)
is_tchar :: proc(character: byte) -> bool {
	switch character {
	case '0' ..= '9', 'a' ..= 'z', 'A' ..= 'Z':
		return true
	case '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
		return true
	}
	return false
}

// token_valid reports whether text is a token: one or more tchars.
@(require_results)
token_valid :: proc(text: string) -> bool {
	if text == "" { return false }
	for i in 0 ..< len(text) {
		if !is_tchar(text[i]) { return false }
	}
	return true
}

// trim_ows strips optional whitespace, which is SP and HTAB only.
//
// RFC 9110 5.6.3: OWS = *( SP / HTAB ). It is narrower than
// strings.trim_space, which also removes VT, FF, CR and LF -- bytes the field
// value grammar does not admit in the first place.
trim_ows :: proc(text: string) -> string {
	return strings.trim(text, " \t")
}

// list_has_token reports whether a comma-separated field value lists token,
// compared case-insensitively, as Connection and Transfer-Encoding options are
// (RFC 9110 5.6.1, 7.6.1).
@(require_results)
list_has_token :: proc(value, token: string) -> bool {
	rest := value
	for element in strings.split_iterator(&rest, ",") {
		if strings.equal_fold(trim_ows(element), token) { return true }
	}
	return false
}

// final_transfer_coding_is_chunked reports whether the last coding of a
// Transfer-Encoding field is chunked. The final coding decides the framing, not
// the presence of the name anywhere in the list, and coding names are
// case-insensitive (RFC 9112 6.1 and 7).
@(require_results)
final_transfer_coding_is_chunked :: proc(value: string) -> bool {
	last := value
	if comma := strings.last_index_byte(value, ','); comma >= 0 { last = value[comma + 1:] }
	return strings.equal_fold(trim_ows(last), "chunked")
}

// content_length_parse reads a Content-Length field value: one or more decimal
// digits. RFC 9112 6.3 item 5 also allows a comma-separated list when every
// member is valid and identical, in which case the message is framed by that
// single value. A sign, differing members, or a value the machine cannot
// represent is invalid framing rather than a body size.
@(require_results)
content_length_parse :: proc(value: string) -> (length: int, ok: bool) {
	length = -1
	rest := value
	for part in strings.split_iterator(&rest, ",") {
		// RFC 9110 5.6.1.2: a recipient ignores empty list elements.
		text := trim_ows(part)
		if text == "" { continue }
		number := 0
		for character in transmute([]u8)text {
			if !is_digit(character) { return 0, false }
			digit := int(character - '0')
			if number > (max(int) - digit) / 10 { return 0, false }
			number = number * 10 + digit
		}
		if length >= 0 && length != number { return 0, false }
		length = number
	}
	if length < 0 { return 0, false }
	return length, true
}

// chunk_size_parse reads a chunk-size as RFC 9112 7.1 defines it: one or more
// hexadecimal digits. A general number parser is the wrong tool here: it reads
// a sign prefix the grammar does not admit, so "+5" would parse as a size.
// Surrounding BWS is stripped; anything else, including an empty value or one
// the machine cannot represent, is invalid framing rather than a size.
@(require_results)
chunk_size_parse :: proc(value: string) -> (size: int, ok: bool) {
	text := trim_ows(value)
	(len(text) > 0) or_return
	for character in transmute([]u8)text {
		digit: int
		switch character {
		case '0' ..= '9':
			digit = int(character - '0')
		case 'a' ..= 'f':
			digit = int(character - 'a') + 10
		case 'A' ..= 'F':
			digit = int(character - 'A') + 10
		case:
			return 0, false
		}
		if size > (max(int) - digit) / 16 { return 0, false }
		size = size * 16 + digit
	}
	return size, true
}

// chunk_line_parse reads a chunk-size line: the size and its chunk-ext
// sequence. RFC 9112 7.1.1: a recipient ignores unrecognized extensions, but
// the sequence still has to parse, so a line that is not a chunk ends the body
// in failure rather than in a body framed by a guess.
@(require_results)
chunk_line_parse :: proc(line: string) -> (size: int, ok: bool) {
	size_text, extensions := line, ""
	if semi := strings.index_byte(line, ';'); semi >= 0 {
		size_text, extensions = line[:semi], line[semi:]
	}
	size = chunk_size_parse(size_text) or_return
	chunk_extensions_valid(extensions) or_return
	return size, true
}

// chunk_extensions_valid reports whether text is a chunk-ext sequence:
// *( BWS ";" BWS chunk-ext-name [ BWS "=" BWS chunk-ext-val ] ), where a value
// is a token or a quoted-string (RFC 9112 7.1.1). Empty text is valid.
@(require_results)
chunk_extensions_valid :: proc(text: string) -> bool {
	rest := text
	for {
		rest = trim_ows(rest)
		if rest == "" { return true }
		if rest[0] != ';' { return false }
		rest = trim_ows(rest[1:])
		width := token_width(rest)
		if width == 0 { return false }
		rest = trim_ows(rest[width:])
		if len(rest) > 0 && rest[0] == '=' {
			rest = trim_ows(rest[1:])
			value_width := token_width(rest) if rest == "" || rest[0] != '"' else quoted_string_width(rest)
			if value_width == 0 { return false }
			rest = rest[value_width:]
		}
	}
}

// token_width measures the token at the start of text.
@(private)
token_width :: proc(text: string) -> int {
	width := 0
	for width < len(text) && is_tchar(text[width]) { width += 1 }
	return width
}

// quoted_string_width measures the quoted-string at the start of text, and is
// zero when there is none (RFC 9110 5.6.4).
@(private)
quoted_string_width :: proc(text: string) -> int {
	if text == "" || text[0] != '"' { return 0 }
	for i := 1; i < len(text); i += 1 {
		character := text[i]
		switch {
		case character == '"':
			return i + 1
		case character == '\\':
			// quoted-pair = "\" ( HTAB / SP / VCHAR / obs-text )
			i += 1
			if i >= len(text) { return 0 }
			escaped := text[i]
			if escaped != '\t' && escaped != ' ' && escaped < 0x21 || escaped == 0x7F { return 0 }
		case character == '\t' ||
		     character == ' ' ||
		     character == 0x21 ||
		     (character >= 0x23 && character <= 0x5B) ||
		     (character >= 0x5D && character <= 0x7E) ||
		     character >= 0x80:
		// qdtext
		case:
			return 0
		}
	}
	return 0
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

method_string :: proc(method: Method) -> string {
	return METHOD_STRINGS[method]
}

// method_parse reads a method token. Methods are case-sensitive (RFC 9110 9.1).
@(require_results)
method_parse :: proc(text: string) -> (method: Method, ok: bool) {
	for name, candidate in METHOD_STRINGS {
		if name == text { return candidate, true }
	}
	return nil, false
}

// header_parse adds one field line to headers and returns its lowercase name.
// The name and value are copied with the headers' allocator.
//
// The field name must be a token (RFC 9110 5.1). A CR, LF, or NUL in the value
// is replaced with SP, as RFC 9110 5.5 lets a recipient do instead of rejecting
// the message. A repeated field is combined into one comma-separated value
// (RFC 9110 5.3), except Host, which may appear once (RFC 9112 3.2), and
// Content-Length: RFC 9112 6.3 makes differing repeats an unrecoverable error,
// and identical repeats stand for the first value.
@(require_results)
header_parse :: proc(headers: ^Headers, line: string) -> (key: string, ok: bool) {
	colon := strings.index_byte(line, ':')
	(colon > 0) or_return
	// RFC 9112 5.1: no whitespace is allowed between the field name and colon,
	// and a line beginning with whitespace is an obs-fold (RFC 9112 5.2); a token
	// holds neither.
	token_valid(line[:colon]) or_return

	// RFC 9112 5.1: the field line value excludes the optional whitespace that
	// may precede and follow it.
	value := trim_ows(line[colon + 1:])
	allocator := headers_allocator(headers^)
	name, name_err := sanitize_key(headers^, line[:colon])
	// A field line that could not be named is one this section cannot carry.
	if name_err != nil { return "", false }

	key_ptr, value_ptr, just_inserted, insert_err := map_entry(&headers._kv, name)
	if insert_err != nil {
		delete(name, allocator)
		return
	}
	if just_inserted {
		cloned, clone_err := field_value_clone(value, allocator)
		if clone_err != nil {
			delete_key(&headers._kv, name)
			delete(name, allocator)
			return
		}
		value_ptr^ = cloned
		return key_ptr^, true
	}
	delete(name, allocator)

	if key_ptr^ == "host" { return }
	if key_ptr^ == "content-length" {
		return key_ptr^, content_length_values_equal(value_ptr^, value)
	}
	combined, concat_err := strings.concatenate({value_ptr^, ", ", value}, allocator)
	if concat_err != nil { return }
	field_value_sanitize(combined)
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
@(require_results)
header_fold :: proc(headers: ^Headers, key, line: string) -> bool {
	value := trim_ows(line)
	if value == "" { return true }
	previous, found := &headers._kv[key]
	if !found { return false }
	allocator := headers._kv.allocator
	continued, concat_err := strings.concatenate({previous^, " ", value}, allocator)
	if concat_err != nil { return false }
	field_value_sanitize(continued)
	delete(previous^, allocator)
	previous^ = continued
	return true
}

@(private, require_results)
field_value_clone :: proc(value: string, allocator: runtime.Allocator) -> (cloned: string, err: runtime.Allocator_Error) {
	cloned = strings.clone(value, allocator) or_return
	field_value_sanitize(cloned)
	return cloned, nil
}

// field_value_sanitize replaces each CR, LF, and NUL with SP (RFC 9110 5.5).
@(private)
field_value_sanitize :: proc(value: string) {
	bytes := transmute([]u8)value
	for &character in bytes {
		if character == '\r' || character == '\n' || character == 0 { character = ' ' }
	}
}

// content_length_values_equal reports whether two Content-Length field values
// name the same length. Identical is by numeric meaning: leading zeros state the
// same length. The comparison strips them instead of parsing, so no representable
// bound limits which equal values are recognized.
@(private, require_results)
content_length_values_equal :: proc(left, right: string) -> bool {
	left_digits, left_ok := decimal_meaning(left)
	right_digits, right_ok := decimal_meaning(right)
	return left_ok && right_ok && left_digits == right_digits
}

// decimal_meaning validates a nonempty all-digit field value and reports its
// numeric meaning with leading zeros removed. A zero of any width reports "0".
@(private, require_results)
decimal_meaning :: proc(value: string) -> (meaning: string, ok: bool) {
	if len(value) == 0 { return "", false }
	for character in transmute([]u8)value {
		if !is_digit(character) { return "", false }
	}
	stripped := strings.trim_left(value, "0")
	if stripped == "" { return "0", true }
	return stripped, true
}

// header_allowed_trailer reports whether a field may be taken from a trailer
// section. RFC 9110 6.5.1: a sender must not put a field in a trailer that is
// needed for framing, routing, request modifiers, authentication, response
// control data, or deciding how to process the content, and a recipient
// ignores such a field.
@(require_results)
header_allowed_trailer :: proc(key: string) -> bool {
	switch key {
	case "transfer-encoding",
	     "content-length",
	     "host",
	     "if-match",
	     "if-none-match",
	     "if-modified-since",
	     "if-unmodified-since",
	     "if-range",
	     "www-authenticate",
	     "authorization",
	     "proxy-authenticate",
	     "proxy-authorization",
	     "cookie",
	     "set-cookie",
	     "age",
	     "cache-control",
	     "expires",
	     "date",
	     "location",
	     "retry-after",
	     "vary",
	     "warning",
	     "content-encoding",
	     "content-type",
	     "content-range",
	     "trailer":
		return false
	}
	return true
}

_dynamic_unwritten :: proc(array: [dynamic]$E) -> []E {
	return (cast([^]E)raw_data(array))[len(array):cap(array)]
}

_dynamic_add_len :: proc(array: ^[dynamic]$E, length: int) {
	(transmute(^runtime.Raw_Dynamic_Array)array).len += length
}

@(private, require_results)
write_escaped_newlines :: proc(writer: io.Writer, text: string) -> io.Error {
	for character in text {
		if character == '\n' {
			io.write_string(writer, "\\n") or_return
		} else {
			io.write_rune(writer, character) or_return
		}
	}
	return nil
}

@(private)
Atomic :: struct($T: typeid) {
	raw: T,
}

@(private)
atomic_store :: #force_inline proc(target: ^Atomic($T), value: T) {
	sync.atomic_store(&target.raw, value)
}

@(private)
atomic_load :: #force_inline proc(target: ^Atomic($T)) -> T {
	return sync.atomic_load(&target.raw)
}
