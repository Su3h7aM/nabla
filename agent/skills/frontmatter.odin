package skills

import "core:crypto/sha2"
import "core:encoding/endian"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

Frontmatter_Value :: struct {
	text:      string,
	next_line: int,
}

parse_metadata :: proc(data: []u8, directory_name: string, allocator := context.allocator) -> (Metadata, Load_Error) {
	text := string(data)
	start := 0
	if len(text) >= 3 && text[0] == 0xef && text[1] == 0xbb && text[2] == 0xbf { start = 3 }
	first, next := frontmatter_line(text, start)
	if first != "---" { return {}, error_make(.Invalid_Metadata, 1, detail = "the first line must be ---", allocator = allocator) }

	name, description: string
	defer delete(name, allocator)
	defer delete(description, allocator)
	name_seen, description_seen := false, false
	seen := make(map[string]bool, allocator)
	defer delete(seen)
	line_number := 2
	at := next
	body_offset := -1
	for at <= len(text) {
		line, line_next := frontmatter_line(text, at)
		if line == "---" {
			body_offset = line_next
			break
		}
		if at >= SKILL_MAX_FRONTMATTER_BYTES {
			return {}, error_make(.Too_Large, line_number, detail = "frontmatter exceeds the byte limit", allocator = allocator)
		}
		trimmed := strings.trim_space(line)
		if trimmed == "" || strings.has_prefix(trimmed, "#") {
			at = line_next
			line_number += 1
			continue
		}
		if line[0] == ' ' {
			return {}, error_make(.Unsupported_Metadata, line_number, detail = "unexpected indentation", allocator = allocator)
		}
		if line[0] == '\t' {
			return {}, error_make(.Unsupported_Metadata, line_number, detail = "tabs cannot indent metadata", allocator = allocator)
		}
		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			return {}, error_make(.Unsupported_Metadata, line_number, detail = "expected a top-level key and value", allocator = allocator)
		}
		key := strings.trim_space(line[:colon])
		if !frontmatter_key_valid(key) {
			return {}, error_make(.Unsupported_Metadata, line_number, detail = "unsupported top-level key", allocator = allocator)
		}
		if seen[key] {
			return {}, error_make(.Invalid_Metadata, line_number, key, "duplicate top-level key", allocator)
		}
		seen[key] = true
		raw := strings.trim_space(line[colon + 1:])
		if key != "name" && key != "description" {
			at = line_next
			line_number += 1
			if raw == "" {
				for at < len(text) {
					nested, nested_next := frontmatter_line(text, at)
					if nested == "" || nested[0] == ' ' || nested[0] == '\t' {
						at = nested_next
						line_number += 1
						continue
					}
					break
				}
			}
			continue
		}
		if raw == "" {
			return {}, error_make(.Invalid_Metadata, line_number, key, "value is empty", allocator)
		}
		value, value_error := frontmatter_value(text, raw, line_next, line_number, allocator)
		if value_error.kind != .None { return {}, value_error }
		if key == "name" {
			name = value.text
			name_seen = true
		} else {
			description = value.text
			description_seen = true
		}
		at = value.next_line
		for scan := line_next; scan < at; {
			_, scan = frontmatter_line(text, scan)
			line_number += 1
		}
	}
	if body_offset < 0 { return {}, error_make(.Invalid_Metadata, line_number, detail = "frontmatter has no closing ---", allocator = allocator) }
	if !name_seen { return {}, error_make(.Invalid_Metadata, field = "name", detail = "required field is missing", allocator = allocator) }
	if !description_seen { return {}, error_make(.Invalid_Metadata, field = "description", detail = "required field is missing", allocator = allocator) }
	if !skill_name_valid(name) { return {}, error_make(.Invalid_Metadata, field = "name", detail = "name is not canonical", allocator = allocator) }
	if name !=
	   directory_name { return {}, error_make(.Invalid_Metadata, field = "name", detail = "name does not match the skill directory", allocator = allocator) }
	normalized, normalize_error := description_normalize(description, allocator)
	if normalize_error.kind != .None { return {}, normalize_error }
	if normalized == "" {
		delete(normalized, allocator)
		return {}, error_make(.Invalid_Metadata, field = "description", detail = "description is empty", allocator = allocator)
	}
	owned_name := strings.clone(name, allocator)
	return Metadata{name = owned_name, description = normalized, body_offset = body_offset, digest = metadata_digest(owned_name, normalized)}, {}
}

frontmatter_line :: proc(text: string, start: int) -> (string, int) {
	if start >= len(text) { return "", len(text) + 1 }
	newline := strings.index_byte(text[start:], '\n')
	if newline < 0 { return text[start:], len(text) + 1 }
	end := start + newline
	if end > start && text[end - 1] == '\r' { end -= 1 }
	return text[start:end], start + newline + 1
}

frontmatter_key_valid :: proc(key: string) -> bool {
	if key == "" { return false }
	for c in key {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-') { return false }
	}
	return true
}

skill_name_valid :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > SKILL_MAX_NAME_BYTES { return false }
	if name[0] == '-' || name[len(name) - 1] == '-' { return false }
	previous_hyphen := false
	for c in name {
		if c == '-' {
			if previous_hyphen { return false }
			previous_hyphen = true
			continue
		}
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9') { return false }
		previous_hyphen = false
	}
	return true
}

frontmatter_value :: proc(text, raw: string, next_line, line_number: int, allocator: mem.Allocator) -> (Frontmatter_Value, Load_Error) {
	if raw[0] == '\'' { return frontmatter_single_quoted(raw, next_line, line_number, allocator) }
	if raw[0] == '"' { return frontmatter_double_quoted(raw, next_line, line_number, allocator) }
	if raw == "|" || raw == "|-" || raw == "|+" || raw == ">" || raw == ">-" || raw == ">+" {
		return frontmatter_block(text, raw, next_line, line_number, allocator)
	}
	if strings.has_prefix(raw, "[") ||
	   strings.has_prefix(raw, "{") ||
	   strings.has_prefix(raw, "&") ||
	   strings.has_prefix(raw, "*") ||
	   strings.has_prefix(raw, "!") {
		return {}, error_make(.Unsupported_Metadata, line_number, detail = "unsupported YAML value", allocator = allocator)
	}
	value := raw
	for index in 1 ..< len(raw) {
		if raw[index] == '#' && (raw[index - 1] == ' ' || raw[index - 1] == '\t') {
			value = strings.trim_space(raw[:index])
			break
		}
	}
	if value == "" { return {}, error_make(.Invalid_Metadata, line_number, detail = "value is empty", allocator = allocator) }
	return Frontmatter_Value{text = strings.clone(value, allocator), next_line = next_line}, {}
}

frontmatter_single_quoted :: proc(raw: string, next_line, line_number: int, allocator: mem.Allocator) -> (Frontmatter_Value, Load_Error) {
	builder := strings.builder_make(allocator)
	defer strings.builder_destroy(&builder)
	i := 1
	closed := false
	for i < len(raw) {
		if raw[i] == '\'' {
			if i + 1 < len(raw) && raw[i + 1] == '\'' {
				strings.write_byte(&builder, '\'')
				i += 2
				continue
			}
			closed = true
			i += 1
			break
		}
		strings.write_byte(&builder, raw[i])
		i += 1
	}
	if !closed ||
	   strings.trim_space(raw[i:]) !=
		   "" { return {}, error_make(.Unsupported_Metadata, line_number, detail = "invalid single-quoted value", allocator = allocator) }
	return Frontmatter_Value{text = strings.clone(strings.to_string(builder), allocator), next_line = next_line}, {}
}

frontmatter_double_quoted :: proc(raw: string, next_line, line_number: int, allocator: mem.Allocator) -> (Frontmatter_Value, Load_Error) {
	builder := strings.builder_make(allocator)
	defer strings.builder_destroy(&builder)
	i := 1
	closed := false
	for i < len(raw) {
		c := raw[i]
		if c == '"' { closed = true; i += 1; break }
		if c != '\\' { strings.write_byte(&builder, c); i += 1; continue }
		if i + 1 >= len(raw) { break }
		i += 1
		switch raw[i] {
		case '"', '\\', '/':
			strings.write_byte(&builder, raw[i])
		case 'n':
			strings.write_byte(&builder, '\n')
		case 'r':
			strings.write_byte(&builder, '\r')
		case 't':
			strings.write_byte(&builder, '\t')
		case 'b':
			strings.write_byte(&builder, '\b')
		case 'f':
			strings.write_byte(&builder, '\f')
		case 'u':
			if i + 4 >= len(raw) { return {}, error_make(.Unsupported_Metadata, line_number, detail = "short Unicode escape", allocator = allocator) }
			value, ok := frontmatter_hex4(raw[i + 1:i + 5])
			if !ok ||
			   value >= 0xd800 &&
				   value <= 0xdfff { return {}, error_make(.Unsupported_Metadata, line_number, detail = "invalid Unicode escape", allocator = allocator) }
			strings.write_rune(&builder, rune(value))
			i += 4
		case:
			return {}, error_make(.Unsupported_Metadata, line_number, detail = "unsupported quoted escape", allocator = allocator)
		}
		i += 1
	}
	if !closed ||
	   strings.trim_space(raw[i:]) !=
		   "" { return {}, error_make(.Unsupported_Metadata, line_number, detail = "invalid double-quoted value", allocator = allocator) }
	return Frontmatter_Value{text = strings.clone(strings.to_string(builder), allocator), next_line = next_line}, {}
}

frontmatter_hex4 :: proc(text: string) -> (u32, bool) {
	if len(text) != 4 { return 0, false }
	value: u32
	for c in text {
		value *= 16
		switch {
		case c >= '0' && c <= '9':
			value += u32(c - '0')
		case c >= 'a' && c <= 'f':
			value += u32(c - 'a' + 10)
		case c >= 'A' && c <= 'F':
			value += u32(c - 'A' + 10)
		case:
			return 0, false
		}
	}
	return value, true
}

frontmatter_block :: proc(text, marker: string, next_line, line_number: int, allocator: mem.Allocator) -> (Frontmatter_Value, Load_Error) {
	folded := marker[0] == '>'
	chomp := marker[len(marker) - 1]
	builder := strings.builder_make(allocator)
	defer strings.builder_destroy(&builder)
	at := next_line
	indent := -1
	previous_blank := false
	for at < len(text) {
		line, following := frontmatter_line(text, at)
		if line == "---" { break }
		spaces := 0
		for spaces < len(line) && line[spaces] == ' ' { spaces += 1 }
		if strings.trim_space(line) != "" && spaces == 0 { break }
		if strings.trim_space(line) != "" && indent < 0 { indent = spaces }
		if strings.trim_space(line) != "" && spaces < indent {
			return {}, error_make(.Unsupported_Metadata, line_number, detail = "block scalar indentation changed", allocator = allocator)
		}
		blank := strings.trim_space(line) == ""
		if blank {
			strings.write_byte(&builder, '\n')
		} else {
			content := line[indent:]
			if folded && strings.builder_len(builder) > 0 && !previous_blank {
				strings.write_byte(&builder, ' ')
			}
			strings.write_string(&builder, content)
			if !folded { strings.write_byte(&builder, '\n') }
		}
		previous_blank = blank
		at = following
	}
	result := strings.to_string(builder)
	if chomp == '-' {
		result = strings.trim_right(result, "\n")
	} else if chomp != '+' {
		result = strings.trim_right(result, "\n")
		if result != "" { result = strings.concatenate({result, "\n"}, context.temp_allocator) }
	}
	return Frontmatter_Value{text = strings.clone(result, allocator), next_line = at}, {}
}

description_normalize :: proc(text: string, allocator: mem.Allocator) -> (string, Load_Error) {
	builder := strings.builder_make(allocator)
	defer strings.builder_destroy(&builder)
	pending_space := false
	runes := 0
	for index := 0; index < len(text); {
		r, width := utf8.decode_rune_in_string(text[index:])
		if r == utf8.RUNE_ERROR &&
		   width == 1 { return "", error_make(.Invalid_Metadata, field = "description", detail = "description is not valid UTF-8", allocator = allocator) }
		if r < 0x20 || r == 0x7f {
			if r != '\n' &&
			   r != '\r' &&
			   r !=
				   '\t' { return "", error_make(.Invalid_Metadata, field = "description", detail = "description contains a control character", allocator = allocator) }
			pending_space = strings.builder_len(builder) > 0
		} else if r == ' ' {
			pending_space = strings.builder_len(builder) > 0
		} else {
			if pending_space { strings.write_byte(&builder, ' '); pending_space = false }
			strings.write_rune(&builder, r)
			runes += 1
			if runes >
			   SKILL_MAX_DESCRIPTION_RUNES { return "", error_make(.Invalid_Metadata, field = "description", detail = "description is too long", allocator = allocator) }
		}
		index += width
	}
	return strings.clone(strings.to_string(builder), allocator), {}
}

metadata_digest :: proc(name, description: string) -> [32]u8 {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	version := [4]u8{0, 0, 0, 1}
	sha2.update(&ctx, version[:])
	length: [8]u8
	endian.unchecked_put_u64be(length[:], u64(len(name)))
	sha2.update(&ctx, length[:])
	sha2.update(&ctx, transmute([]u8)name)
	endian.unchecked_put_u64be(length[:], u64(len(description)))
	sha2.update(&ctx, length[:])
	sha2.update(&ctx, transmute([]u8)description)
	digest: [32]u8
	sha2.final(&ctx, digest[:])
	return digest
}
