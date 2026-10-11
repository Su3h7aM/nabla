package web

import "base:runtime"
import "core:bytes"
import "core:compress"
import "core:compress/gzip"
import "core:compress/zlib"
import "core:encoding/entity"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

import "nabla:html"

// content_decode reverses the content codings in the response. state owns the
// current body with its allocator; a decoded body replaces and frees it only
// after decoding succeeds. On failure the current body remains owned by state.
@(private)
@(require_results)
content_decode :: proc(state: ^Exchange) -> Error {
	if len(state.body) == 0 { return {} }
	codings := strings.trim_space(state.content_coding)
	for codings != "" {
		separator := strings.last_index_byte(codings, ',')
		coding := codings
		if separator >= 0 {
			coding = codings[separator + 1:]
			codings = codings[:separator]
		} else {
			codings = ""
		}
		coding = strings.trim_space(coding)
		if coding == "" || strings.equal_fold(coding, "identity") { continue }
		is_gzip := strings.equal_fold(coding, "gzip") || strings.equal_fold(coding, "x-gzip")
		if !is_gzip && !strings.equal_fold(coding, "deflate") {
			return {kind = .Unsupported_Content, detail = "the response uses a content coding this package does not decode"}
		}
		decoded: bytes.Buffer
		decoded.buf.allocator = state.body.allocator
		defer bytes.buffer_destroy(&decoded)
		decode_error: compress.Error
		if is_gzip {
			decode_error = gzip.load(state.body[:], &decoded, allocator = state.body.allocator)
		} else {
			context.allocator = state.body.allocator
			decode_error = zlib.inflate(state.body[:], &decoded)
		}
		if decode_error != nil {
			if _, allocation_failed := decode_error.(runtime.Allocator_Error); allocation_failed { return OUT_OF_MEMORY }
			if general, present := decode_error.(compress.General_Error); present && general == .Output_Too_Short { return content_decode_limit() }
			if gzip_error, present := decode_error.(compress.GZIP_Error);
			   present && gzip_error == .Output_Exceeds_COMPRESS_OUTPUT_ALLOCATE_MAX { return content_decode_limit() }
			return {kind = .Invalid_Response, detail = "the gzip body is corrupt" if is_gzip else "the deflate body is corrupt"}
		}
		delete(state.body)
		state.body = decoded.buf
		decoded.buf = nil
	}
	return {}
}

@(private)
content_decode_limit :: proc() -> Error {
	return {
		kind = .Invalid_Response,
		detail = fmt.tprintf("core:compress could not allocate decompressed output within its %d-byte limit", compress.COMPRESS_OUTPUT_ALLOCATE_MAX),
	}
}

// markup_strip returns source as plain text: tags dropped and character
// references decoded. It borrows source when there is nothing to remove, and
// otherwise allocates from scratch memory. Brave marks matched terms with
// <strong> and escapes quotes as references.
@(private)
@(require_results)
markup_strip :: proc(source: string) -> (text: string, err: runtime.Allocator_Error) {
	if !strings.contains_any(source, "<&") { return source, nil }
	builder := strings.builder_make(context.temp_allocator) or_return
	tokenizer: html.Tokenizer
	html.init(&tokenizer, source)
	for token in html.next(&tokenizer) {
		if token.kind == .Text && !entities_write(&builder, token.text) { return "", .Out_Of_Memory }
	}
	return strings.to_string(builder), nil
}

// ENTITY_MAX is the longest HTML named reference body, "CounterClockwiseContourIntegral".
@(private)
ENTITY_MAX :: 31

// percent_decode_write writes text with its %XX escapes decoded. A malformed
// escape is kept as written.
@(private)
@(require_results)
percent_decode_write :: proc(builder: ^strings.Builder, text: string) -> bool {
	for i := 0; i < len(text); i += 1 {
		if text[i] == '%' && i + 2 < len(text) {
			high, high_ok := hex_value(text[i + 1])
			low, low_ok := hex_value(text[i + 2])
			if high_ok && low_ok {
				if strings.write_byte(builder, high << 4 | low) != 1 { return false }
				i += 2
				continue
			}
		}
		if strings.write_byte(builder, text[i]) != 1 { return false }
	}
	return true
}

@(private)
hex_value :: proc(digit: u8) -> (value: u8, ok: bool) {
	switch digit {
	case '0' ..= '9':
		return digit - '0', true
	case 'a' ..= 'f':
		return digit - 'a' + 10, true
	case 'A' ..= 'F':
		return digit - 'A' + 10, true
	}
	return 0, false
}

// entities_write writes text with its character references decoded. A reference
// that does not decode is kept as written.
@(private)
@(require_results)
entities_write :: proc(builder: ^strings.Builder, text: string) -> bool {
	rest := text
	for len(rest) > 0 {
		ampersand := strings.index_byte(rest, '&')
		if ampersand < 0 { return write(builder, rest) }
		if !write(builder, rest[:ampersand]) { return false }
		rest = rest[ampersand:]
		semicolon := strings.index_byte(rest, ';')
		if semicolon > 1 && semicolon <= ENTITY_MAX + 1 {
			if decoded, count, ok := entity.xml_decode_entity(rest[1:semicolon]); ok {
				for i in 0 ..< count {
					bytes, size := utf8.encode_rune(decoded[i])
					if !write(builder, string(bytes[:size])) { return false }
				}
				rest = rest[semicolon + 1:]
				continue
			}
		}
		if !write(builder, "&") { return false }
		rest = rest[1:]
	}
	return true
}
