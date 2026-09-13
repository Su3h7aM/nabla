package agent

import "core:fmt"
import "core:strings"

// A tool argument defect. field and expected are owned by the error; field names
// the argument the defect is about and is empty when the defect is not tied to
// one field, expected names the constraint the argument had to satisfy and is
// empty when no constraint is known. A defect the harness cannot describe
// precisely is reported as a syntax defect with the byte offset that was
// actually reached.
Tool_Argument_Error_Kind :: enum {
	None,
	Not_Object,
	Syntax,
	Duplicate_Field,
	Unknown_Field,
	Missing_Field,
	Wrong_Type,
	Invalid_Value,
	Too_Large,
}

Tool_Argument_Error :: struct {
	kind:     Tool_Argument_Error_Kind,
	field:    string, // owned
	expected: string, // owned
	offset:   Maybe(int),
}

tool_argument_error :: proc(kind: Tool_Argument_Error_Kind, field := "", expected := "", offset: Maybe(int) = nil, allocator := context.allocator) -> Tool_Argument_Error {
	err := Tool_Argument_Error{kind = kind, offset = offset}
	if field != "" { err.field = strings.clone(field, allocator) }
	if expected != "" { err.expected = strings.clone(expected, allocator) }
	return err
}

tool_argument_error_destroy :: proc(err: ^Tool_Argument_Error, allocator := context.allocator) {
	delete(err.field, allocator)
	delete(err.expected, allocator)
	err^ = {}
}

tool_argument_error_code :: proc(err: Tool_Argument_Error) -> string {
	switch err.kind {
	case .None:
		return ""
	case .Not_Object:
		return "not_object"
	case .Syntax:
		return "syntax"
	case .Duplicate_Field:
		return "duplicate_field"
	case .Unknown_Field:
		return "unknown_field"
	case .Missing_Field:
		return "missing_field"
	case .Wrong_Type:
		return "wrong_type"
	case .Invalid_Value:
		return "invalid_value"
	case .Too_Large:
		return "too_large"
	}
	return ""
}

// tool_argument_error_text renders the defect as one deterministic sentence. The
// same defect always renders the same bytes, so a recovery turn introduces no
// avoidable wording churn into the conversation.
tool_argument_error_text :: proc(err: Tool_Argument_Error, allocator := context.allocator) -> string {
	switch err.kind {
	case .None:
		return ""
	case .Not_Object:
		return strings.clone("the arguments must be a JSON object", allocator)
	case .Syntax:
		if offset, present := err.offset.?; present {
			return fmt.aprintf("the arguments are not valid JSON (at byte %d)", offset, allocator = allocator)
		}
		return strings.clone("the arguments are not valid JSON", allocator)
	case .Duplicate_Field:
		return fmt.aprintf(`duplicate field %q`, err.field, allocator = allocator)
	case .Unknown_Field:
		return fmt.aprintf(`unknown field %q; expected command, working_directory, or timeout_ms`, err.field, allocator = allocator)
	case .Missing_Field:
		return fmt.aprintf(`missing required field %q`, err.field, allocator = allocator)
	case .Wrong_Type:
		return fmt.aprintf(`field %q must be %s`, err.field, err.expected, allocator = allocator)
	case .Invalid_Value:
		if err.expected != "" {
			return fmt.aprintf(`field %q must be %s`, err.field, err.expected, allocator = allocator)
		}
		return fmt.aprintf(`field %q is invalid`, err.field, allocator = allocator)
	case .Too_Large:
		return fmt.aprintf("the arguments exceed %d bytes", TOOL_MAX_ARGS_BYTES, allocator = allocator)
	}
	return ""
}

// tool_arguments_escape_control_chars rewrites raw control bytes inside JSON
// string literals as their escape sequences. It accepts only input whose escape
// sequences already follow the JSON rules, so it never chooses between two
// readings of a backslash. It reports unchanged when the input needs no repair,
// and yields no repair at all when an escape is invalid or the escaped form
// would exceed the argument budget.
tool_arguments_escape_control_chars :: proc(raw: string, allocator := context.allocator) -> (repaired: string, changed: bool) {
	builder := strings.builder_make(allocator)
	defer if !changed { strings.builder_destroy(&builder) }

	in_string := false
	i := 0
	for i < len(raw) {
		c := raw[i]
		if !in_string {
			if c == '"' { in_string = true }
			strings.write_byte(&builder, c)
			i += 1
		} else if c == '\\' {
			if i + 1 >= len(raw) { return "", false }
			esc := raw[i + 1]
			if !tool_escape_valid(esc) { return "", false }
			strings.write_byte(&builder, c)
			strings.write_byte(&builder, esc)
			i += 2
			if esc == 'u' {
				if i + 4 > len(raw) { return "", false }
				for k in 0 ..< 4 {
					if !tool_hex_digit(raw[i + k]) { return "", false }
				}
				strings.write_string(&builder, raw[i:i + 4])
				i += 4
			}
		} else if c == '"' {
			in_string = false
			strings.write_byte(&builder, c)
			i += 1
		} else if c < 0x20 {
			tool_write_control_escape(&builder, c)
			changed = true
			i += 1
		} else {
			strings.write_byte(&builder, c)
			i += 1
		}
		if strings.builder_len(builder) > TOOL_MAX_ARGS_BYTES { return "", false }
	}
	if !changed { return "", false }
	return strings.to_string(builder), true
}

@(private)
tool_escape_valid :: proc(c: u8) -> bool {
	switch c {
	case '"', '\\', '/', 'b', 'f', 'n', 'r', 't', 'u':
		return true
	}
	return false
}

@(private)
tool_hex_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'
}

@(private)
tool_write_control_escape :: proc(builder: ^strings.Builder, c: u8) {
	switch c {
	case 0x08:
		strings.write_string(builder, `\b`)
		return
	case 0x09:
		strings.write_string(builder, `\t`)
		return
	case 0x0A:
		strings.write_string(builder, `\n`)
		return
	case 0x0C:
		strings.write_string(builder, `\f`)
		return
	case 0x0D:
		strings.write_string(builder, `\r`)
		return
	}
	strings.write_string(builder, `\u00`)
	strings.write_byte(builder, tool_hex_char(c >> 4))
	strings.write_byte(builder, tool_hex_char(c & 0x0F))
}

@(private)
tool_hex_char :: proc(value: u8) -> u8 {
	if value < 10 { return '0' + value }
	return 'a' + (value - 10)
}
