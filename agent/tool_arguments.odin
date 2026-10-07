package agent

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"

// An argument document is admitted at whatever size the model sent. The harness does not
// bound the model's own output: the model and the provider are the only parties that may,
// and a model that asked for more than the provider allows hears it from the provider that
// refused it, not from this package guessing the bound.

// TOOL_EXACT_FLOAT_INTEGER is the largest magnitude at which every integer has its own f64,
// so a whole float within it names exactly one integer and one beyond it may not.
TOOL_EXACT_FLOAT_INTEGER :: 1 << 53

// Tool_Repair is one change of representation the harness made to a proposed call so it
// could be read. A call's repairs are recorded as a set beside the arguments it actually ran
// with, so a reader can tell a repaired call from an untouched one without diffing the
// proposal. An empty set means nothing was changed.
Tool_Repair :: enum {
	// A raw control byte inside a string literal was written as its escape.
	Escaped_Control_Characters,
	// Empty or null arguments were read as the empty object.
	Empty_Arguments,
	// The arguments were a JSON string holding one object, which was read as that object.
	Double_Encoded_Object,
	// An integer field held a string of exactly one integer in decimal.
	Integer_From_String,
	// An integer field held a number with no fractional part.
	Integer_From_Float,
	// A comma after the last value of an object or array was dropped.
	Trailing_Comma,
}

Tool_Repairs :: bit_set[Tool_Repair]

TOOL_REPAIR_NAMES := [Tool_Repair]string {
	.Escaped_Control_Characters = "escaped_control_characters",
	.Empty_Arguments            = "empty_arguments",
	.Double_Encoded_Object      = "double_encoded_object",
	.Integer_From_String        = "integer_from_string",
	.Integer_From_Float         = "integer_from_float",
	.Trailing_Comma             = "trailing_comma",
}

Tool_Argument_Error_Kind :: enum {
	Not_Object,
	Syntax,
	Duplicate_Field,
	Unknown_Field,
	Missing_Field,
	Wrong_Type,
	Invalid_Value,
	Too_Large,
	Number_Out_Of_Range,
	Out_Of_Memory,
}

@(private)
tool_argument_error_codes := [Tool_Argument_Error_Kind]string {
	.Not_Object          = "not_object",
	.Syntax              = "syntax",
	.Duplicate_Field     = "duplicate_field",
	.Unknown_Field       = "unknown_field",
	.Missing_Field       = "missing_field",
	.Wrong_Type          = "wrong_type",
	.Invalid_Value       = "invalid_value",
	.Too_Large           = "too_large",
	.Number_Out_Of_Range = "number_out_of_range",
	.Out_Of_Memory       = "out_of_memory",
}

// Tool_Argument_Defect is what is wrong with one argument document. field is the JSON
// pointer path of the argument the defect is about, and expected names the constraint that
// was not met: the declared type, the accepted range, or the set of accepted fields. Both
// are owned by the defect.
Tool_Argument_Defect :: struct {
	kind:     Tool_Argument_Error_Kind,
	field:    string, // owned
	expected: string, // owned
	// line and column place a defect found in the document text, both counting from 1.
	// Zero means the defect is about a field's value rather than a place in the text.
	line:     int,
	column:   int,
}

// Tool_Argument_Error is nil when the arguments are sound, so a reader can use or_return.
Tool_Argument_Error :: union {
	Tool_Argument_Defect,
}

// tool_argument_error builds one defect. A defect whose own text cannot be copied becomes
// Out_Of_Memory, because a message that names an empty field would read as a real defect.
@(require_results)
tool_argument_error :: proc(kind: Tool_Argument_Error_Kind, field := "", expected := "", allocator := context.allocator) -> Tool_Argument_Error {
	defect := Tool_Argument_Defect {
		kind = kind,
	}
	clone_error: mem.Allocator_Error
	if field != "" { defect.field, clone_error = strings.clone(field, allocator) }
	if clone_error == nil && expected != "" { defect.expected, clone_error = strings.clone(expected, allocator) }
	if clone_error != nil {
		delete(defect.field, allocator)
		return Tool_Argument_Defect{kind = .Out_Of_Memory}
	}
	return defect
}

tool_argument_error_destroy :: proc(err: ^Tool_Argument_Error, allocator := context.allocator) {
	if defect, failed := err.?; failed {
		delete(defect.field, allocator)
		delete(defect.expected, allocator)
	}
	err^ = nil
}

tool_argument_error_code :: proc(err: Tool_Argument_Error) -> string {
	defect, failed := err.?
	if !failed { return "" }
	return tool_argument_error_codes[defect.kind]
}

// tool_argument_error_text renders a defect as one sentence, owned by allocator, ending with
// where the defect is when it was found in the document text. The same defect always renders
// the same bytes, so a recovery turn adds no wording churn to the cacheable prefix. It
// reports an allocator error when the sentence could not be copied.
@(require_results)
tool_argument_error_text :: proc(err: Tool_Argument_Error, allocator := context.allocator) -> (string, mem.Allocator_Error) {
	defect, failed := err.?
	if !failed { return "", nil }
	sentence := tool_argument_error_sentence(defect)
	if defect.line == 0 { return strings.clone(sentence, allocator) }
	return fmt.aprintf("%s, at line %d column %d", sentence, defect.line, defect.column, allocator = allocator), nil
}

// tool_argument_error_sentence says what a defect is. The text is temporary.
@(private, require_results)
tool_argument_error_sentence :: proc(err: Tool_Argument_Defect) -> string {
	switch err.kind {
	case .Not_Object:
		return "the arguments must be a JSON object"
	case .Syntax:
		return "the arguments are not valid JSON"
	case .Duplicate_Field:
		return fmt.tprintf("field %q appears twice in one object; a field may appear once", err.field)
	case .Unknown_Field:
		return fmt.tprintf("unknown field %q; expected %s", err.field, err.expected)
	case .Missing_Field:
		return fmt.tprintf("missing required field %q", err.field)
	case .Wrong_Type:
		return fmt.tprintf("field %q must be %s", err.field, err.expected)
	case .Invalid_Value:
		if err.expected != "" { return fmt.tprintf("field %q must be %s", err.field, err.expected) }
		return fmt.tprintf("field %q is invalid", err.field)
	case .Too_Large:
		if err.expected != "" { return fmt.tprintf("field %q must be %s", err.field, err.expected) }
		return fmt.tprintf("field %q is too large", err.field)
	case .Number_Out_Of_Range:
		return "the arguments hold a number that no 64-bit integer or finite float can hold"
	case .Out_Of_Memory:
		return "the harness ran out of memory while describing what is wrong with the arguments"
	}
	return ""
}

// Argument_Failure is the output of a refusal: which argument was wrong and what was
// expected of it. Its strings borrow the error it describes, so it lives only as long
// as that error does.
Argument_Failure :: struct {
	kind:     string,
	field:    string,
	expected: string,
}

tool_argument_failure :: proc(err: Tool_Argument_Error) -> Argument_Failure {
	defect := err.? or_else {}
	return {kind = tool_argument_error_code(err), field = defect.field, expected = defect.expected}
}

// --- admitting a document ----------------------------------------------------

Tool_Arguments_Status :: enum {
	// None is the zero value: no admission has been attempted yet, which is what a job that
	// arrives with its own document reads as.
	None,
	Rejected,
	Valid,
}

// Tool_Arguments is the outcome of admitting one proposed argument document.
// value owns the parsed object, effective owns the bytes the call runs with, repairs
// names every change of representation made to reach them, and error owns the refusal
// when the status is Rejected.
Tool_Arguments :: struct {
	status:            Tool_Arguments_Status,
	value:             json.Value,
	effective:         string,
	repairs:           Tool_Repairs,
	error:             Tool_Argument_Error,
	allocation_failed: bool,
}

tool_arguments_destroy :: proc(arguments: ^Tool_Arguments, allocator := context.allocator) {
	json.destroy_value(arguments.value, allocator)
	delete(arguments.effective, allocator)
	tool_argument_error_destroy(&arguments.error, allocator)
	arguments^ = {}
}

// tool_arguments_prepare admits a proposed argument document and reads it in full before
// anything runs. A document is repaired only where it has exactly one reading: empty or null
// arguments are the empty object, a raw control byte inside a string literal is its escape,
// and a JSON string whose content is one object is that object. No value is ever invented,
// and a document that still does not admit is refused with its own defect.
@(require_results)
tool_arguments_prepare :: proc(raw: string, allocator := context.allocator) -> (arguments: Tool_Arguments) {
	// Every way out of here either says the document is valid or names the defect that refused
	// it, so the status is never left to mean two things.
	arguments.status = .Rejected
	document := raw
	repairs: Tool_Repairs
	// Each repair that rewrites the text leaves its result here, released on the way out.
	rewritten: [4]string
	defer for text in rewritten { delete(text, allocator) }

	trimmed := strings.trim_space(raw)
	if trimmed == "" || trimmed == "null" {
		document = "{}"
		repairs += {.Empty_Arguments}
	}
	escaped, changed, escape_error := tool_arguments_escape_control_chars(document, allocator)
	if escape_error != nil {
		arguments.allocation_failed = true
		return
	}
	if changed {
		rewritten[0], document = escaped, escaped
		repairs += {.Escaped_Control_Characters}
	}
	inner, is_string, unquote_error := tool_arguments_string_document(document, allocator)
	if unquote_error != nil {
		arguments.allocation_failed = true
		return
	}
	if is_string {
		rewritten[1], document = inner, inner
		repairs += {.Double_Encoded_Object}
		// Unquoting turns an escaped newline back into a raw one, which inside the inner
		// document's own string literals is again a control byte with one reading.
		escaped, changed, escape_error = tool_arguments_escape_control_chars(document, allocator)
		if escape_error != nil {
			arguments.allocation_failed = true
			return
		}
		if changed {
			rewritten[2], document = escaped, escaped
			repairs += {.Escaped_Control_Characters}
		}
	}
	blanked, blanked_any, blank_error := tool_arguments_blank_trailing_commas(document, allocator)
	if blank_error != nil {
		arguments.allocation_failed = true
		return
	}
	if blanked_any {
		rewritten[3], document = blanked, blanked
		repairs += {.Trailing_Comma}
	}

	if admit_error := tool_arguments_admit(document, allocator); admit_error != nil {
		arguments.error = admit_error
		return
	}
	value, parse_err := json.parse_string(document, .JSON, true, allocator)
	if parse_err != nil {
		json.destroy_value(value, allocator)
		if parse_err == .Out_Of_Memory {
			arguments.allocation_failed = true
			return
		}
		// Admission guarantees the parser accepts the document, so no other failure is
		// reachable; refusing is the only safe answer.
		arguments.error = tool_argument_error(.Syntax, allocator = allocator)
		return
	}
	effective, clone_err := strings.clone(document, allocator)
	if clone_err != nil {
		json.destroy_value(value, allocator)
		arguments.allocation_failed = true
		return
	}
	arguments.status = .Valid
	arguments.value = value
	arguments.effective = effective
	arguments.repairs = repairs
	return
}

// tool_arguments_string_document returns the content of a document that is one JSON string
// holding what begins as an object, owned by allocator. Any other document is not one.
@(private, require_results)
tool_arguments_string_document :: proc(document: string, allocator: mem.Allocator) -> (inner: string, is_string: bool, err: mem.Allocator_Error) {
	tokenizer := json.make_tokenizer(document, .JSON, true)
	token, token_err := json.get_token(&tokenizer)
	if token_err != nil || token.kind != .String { return "", false, nil }
	end, end_err := json.get_token(&tokenizer)
	if (end_err != nil && end_err != .EOF) || end.kind != .EOF { return "", false, nil }
	text, unquote_err := json.unquote_string(token, .JSON, allocator)
	if unquote_err == .Out_Of_Memory { return "", false, .Out_Of_Memory }
	if unquote_err != nil { return "", false, nil }
	if !strings.has_prefix(strings.trim_left_space(text), "{") {
		delete(text, allocator)
		return "", false, nil
	}
	return text, true, nil
}

// tool_repairs_text names a set of repairs in declaration order, joined by commas, owned by
// allocator. It reports an allocator error when the text could not be written whole.
@(require_results)
tool_repairs_text :: proc(repairs: Tool_Repairs, allocator := context.allocator) -> (string, mem.Allocator_Error) {
	builder, builder_error := strings.builder_make(allocator)
	if builder_error != nil { return "", builder_error }
	transferred := false
	defer if !transferred { strings.builder_destroy(&builder) }
	for repair in repairs {
		if strings.builder_len(builder) > 0 && strings.write_string(&builder, ", ") != len(", ") { return "", .Out_Of_Memory }
		name := TOOL_REPAIR_NAMES[repair]
		if strings.write_string(&builder, name) != len(name) { return "", .Out_Of_Memory }
	}
	transferred = true
	return strings.to_string(builder), nil
}

// tool_arguments_admit reports the first structural defect in a proposed argument document,
// which must be one JSON object that tool_json_admit admits.
@(require_results)
tool_arguments_admit :: proc(raw: string, allocator: mem.Allocator) -> Tool_Argument_Error {
	if !strings.has_prefix(strings.trim_left_space(raw), "{") { return tool_argument_error(.Not_Object, allocator = allocator) }
	return tool_json_admit(raw, allocator)
}

// tool_json_admit reports the first defect in a JSON document of any kind: one value alone
// in its input, no repeated field name, and no number the parser cannot hold. A document it
// admits parses to exactly what it says. A repeated field name is refused rather than
// resolved, because the harness will not choose which of two values was meant. Every defect
// it reports carries the position of the token at fault.
//
// Admission walks the tokenizer instead of calling the parser because the parser accepts
// trailing input, keeps one of two repeated fields, and leaks on some malformed documents.
@(require_results)
tool_json_admit :: proc(text: string, allocator: mem.Allocator) -> Tool_Argument_Error {
	tokenizer := json.make_tokenizer(text, .JSON, true)
	token, token_err := json.get_token(&tokenizer)
	if tool_token_bad(token, token_err) { return tool_document_error(.Syntax, tokenizer.data, token) }
	if value_error := tool_admit_value(&tokenizer, token, allocator); value_error != nil { return value_error }

	token, token_err = json.get_token(&tokenizer)
	if (token_err != nil && token_err != .EOF) || token.kind != .EOF { return tool_document_error(.Syntax, tokenizer.data, token) }
	return nil
}

// tool_document_error is a defect found at a token of text, placed by its line and column
// counted from 1. The column is counted here from the token's byte offset, because the
// tokenizer counts it from 0 on the first line and from 1 on every other.
@(private)
tool_document_error :: proc(kind: Tool_Argument_Error_Kind, text: string, at: json.Token) -> Tool_Argument_Defect {
	offset := min(at.offset, len(text))
	line_start := strings.last_index_byte(text[:offset], '\n') + 1
	return {kind = kind, line = strings.count(text[:line_start], "\n") + 1, column = offset - line_start + 1}
}

// tool_token_bad reports a token that cannot be used: a tokenizer failure or an
// end of input where the document still owes structure.
@(private)
tool_token_bad :: proc(token: json.Token, err: json.Error) -> bool {
	return (err != nil && err != .EOF) || token.kind == .EOF
}

@(private, require_results)
tool_admit_object :: proc(tokenizer: ^json.Tokenizer, allocator: mem.Allocator) -> Tool_Argument_Error {
	seen := make(map[string]bool, context.temp_allocator)
	defer delete(seen)

	comma := false
	for {
		token, token_err := json.get_token(tokenizer)
		if tool_token_bad(token, token_err) { return tool_document_error(.Syntax, tokenizer.data, token) }
		if token.kind == .Close_Brace {
			if comma { return tool_document_error(.Syntax, tokenizer.data, token) }
			return nil
		}
		if token.kind != .String { return tool_document_error(.Syntax, tokenizer.data, token) }

		key, key_err := json.unquote_string(token, .JSON, context.temp_allocator)
		if key_err != nil { return tool_document_error(.Syntax, tokenizer.data, token) }
		if seen[key] {
			duplicate := tool_document_error(.Duplicate_Field, tokenizer.data, token)
			key_error: mem.Allocator_Error
			duplicate.field, key_error = strings.clone(key, allocator)
			if key_error != nil { return Tool_Argument_Defect{kind = .Out_Of_Memory} }
			return duplicate
		}
		seen[key] = true

		colon, colon_err := json.get_token(tokenizer)
		if tool_token_bad(colon, colon_err) || colon.kind != .Colon { return tool_document_error(.Syntax, tokenizer.data, colon) }
		value, value_err := json.get_token(tokenizer)
		if tool_token_bad(value, value_err) { return tool_document_error(.Syntax, tokenizer.data, value) }
		if value_error := tool_admit_value(tokenizer, value, allocator); value_error != nil { return value_error }

		separator, separator_err := json.get_token(tokenizer)
		if tool_token_bad(separator, separator_err) { return tool_document_error(.Syntax, tokenizer.data, separator) }
		if separator.kind == .Comma {
			comma = true
			continue
		}
		if separator.kind == .Close_Brace { return nil }
		return tool_document_error(.Syntax, tokenizer.data, separator)
	}
}

@(private, require_results)
tool_admit_array :: proc(tokenizer: ^json.Tokenizer, allocator: mem.Allocator) -> Tool_Argument_Error {
	comma := false
	for {
		token, token_err := json.get_token(tokenizer)
		if tool_token_bad(token, token_err) { return tool_document_error(.Syntax, tokenizer.data, token) }
		if token.kind == .Close_Bracket {
			if comma { return tool_document_error(.Syntax, tokenizer.data, token) }
			return nil
		}
		if value_error := tool_admit_value(tokenizer, token, allocator); value_error != nil { return value_error }

		separator, separator_err := json.get_token(tokenizer)
		if tool_token_bad(separator, separator_err) { return tool_document_error(.Syntax, tokenizer.data, separator) }
		if separator.kind == .Comma {
			comma = true
			continue
		}
		if separator.kind == .Close_Bracket { return nil }
		return tool_document_error(.Syntax, tokenizer.data, separator)
	}
}

// tool_admit_value continues from a token that has already been read, which is
// what keeps a container's element token from being read twice.
//
// A number is admitted only if the parser can hold it as written: the parser wraps an
// integer past the 64-bit range and reads an enormous float as infinity, and either would
// run the call with a number the model never sent.
@(private, require_results)
tool_admit_value :: proc(tokenizer: ^json.Tokenizer, token: json.Token, allocator: mem.Allocator) -> Tool_Argument_Error {
	#partial switch token.kind {
	case .Open_Brace, .Open_Bracket:
		if token.kind == .Open_Brace { return tool_admit_object(tokenizer, allocator) }
		return tool_admit_array(tokenizer, allocator)
	case .Integer:
		if _, fits := tool_decimal_integer(token.text); !fits { return tool_document_error(.Number_Out_Of_Range, tokenizer.data, token) }
		return nil
	case .Float:
		number, parsed := strconv.parse_f64(token.text)
		if !parsed || math.is_inf(number) { return tool_document_error(.Number_Out_Of_Range, tokenizer.data, token) }
		return nil
	case .String, .True, .False, .Null:
		return nil
	}
	return tool_document_error(.Syntax, tokenizer.data, token)
}

// tool_arguments_escape_control_chars rewrites raw control bytes inside JSON string literals
// as their escape sequences, owned by allocator. It accepts only input whose escape
// sequences already follow the JSON rules, so it never chooses between two readings of a
// backslash. changed is false when the input needs no repair or has an invalid escape.
@(private, require_results)
tool_arguments_escape_control_chars :: proc(raw: string, allocator: mem.Allocator) -> (repaired: string, changed: bool, err: mem.Allocator_Error) {
	size, escapes, valid := tool_escape_walk(raw, nil)
	if !valid || escapes == 0 { return "", false, nil }
	output := make([]u8, size, allocator) or_return
	written, _, written_valid := tool_escape_walk(raw, output)
	assert(written == size && written_valid, "escaping a text writes the size it measured")
	return string(output), true, nil
}

// tool_escape_walk measures raw with every control byte inside a string literal escaped,
// and writes that form into output when output is not nil. output must hold size bytes.
// valid is false when an escape sequence in raw breaks the JSON rules.
@(private, require_results)
tool_escape_walk :: proc(raw: string, output: []u8) -> (size: int, escapes: int, valid: bool) {
	in_string := false
	index := 0
	for index < len(raw) {
		current := raw[index]
		span := raw[index:index + 1]
		switch {
		case !in_string:
			in_string = current == '"'
		case current == '"':
			in_string = false
		case current == '\\':
			if index + 1 >= len(raw) || !tool_escape_valid(raw[index + 1]) { return 0, 0, false }
			span = raw[index:index + 2]
			if raw[index + 1] == 'u' {
				if index + 6 > len(raw) { return 0, 0, false }
				for digit in transmute([]u8)raw[index + 2:index + 6] {
					if !tool_hex_digit(digit) { return 0, 0, false }
				}
				span = raw[index:index + 6]
			}
		case current < 0x20:
			escape, length := tool_control_escape(current)
			if output != nil { copy(output[size:], escape[:length]) }
			size += length
			escapes += 1
			index += 1
			continue
		}
		if output != nil { copy(output[size:], span) }
		size += len(span)
		index += len(span)
	}
	return size, escapes, true
}

@(private, require_results)
tool_escape_valid :: proc(c: u8) -> bool {
	switch c {
	case '"', '\\', '/', 'b', 'f', 'n', 'r', 't', 'u':
		return true
	}
	return false
}

@(private, require_results)
tool_hex_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'
}

// tool_arguments_blank_trailing_commas writes a space over every comma that follows a value
// and is followed only by whitespace and the bracket closing its object or array, outside
// string literals, in a copy owned by allocator. A space keeps every other byte where it
// was, so a defect found later is placed in the text as the model sent it. A comma after
// another comma or after an opening bracket is left, because it has no one reading.
@(private, require_results)
tool_arguments_blank_trailing_commas :: proc(raw: string, allocator: mem.Allocator) -> (repaired: string, changed: bool, err: mem.Allocator_Error) {
	output: []u8
	in_string, escaped := false, false
	previous: u8
	for current, index in transmute([]u8)raw {
		if in_string {
			switch {
			case escaped:
				escaped = false
			case current == '\\':
				escaped = true
			case current == '"':
				in_string = false
				previous = current
			}
			continue
		}
		switch current {
		case ' ', '\t', '\n', '\r':
			continue
		case '"':
			in_string = true
		case ',':
			ends_value := previous != 0 && previous != ',' && previous != '{' && previous != '[' && previous != ':'
			rest := strings.trim_left(raw[index + 1:], " \t\n\r")
			closes := strings.has_prefix(rest, "}") || strings.has_prefix(rest, "]")
			if ends_value && closes {
				if output == nil { output = transmute([]u8)(strings.clone(raw, allocator) or_return) }
				output[index] = ' '
				continue
			}
		}
		previous = current
	}
	if output == nil { return "", false, nil }
	return string(output), true, nil
}

// tool_control_escape is the JSON escape of one control byte: its short form where JSON has
// one, and \u00XX otherwise.
@(private)
tool_control_escape :: proc(control: u8) -> (escape: [6]u8, length: int) {
	hex_digits := "0123456789abcdef"
	escape[0] = '\\'
	switch control {
	case 0x08:
		escape[1] = 'b'
	case 0x09:
		escape[1] = 't'
	case 0x0A:
		escape[1] = 'n'
	case 0x0C:
		escape[1] = 'f'
	case 0x0D:
		escape[1] = 'r'
	case:
		escape[1], escape[2], escape[3] = 'u', '0', '0'
		escape[4], escape[5] = hex_digits[control >> 4], hex_digits[control & 0x0F]
		return escape, 6
	}
	return escape, 2
}

// --- reading fields ----------------------------------------------------------

// The field readers below are the whole of argument validation. Each one checks
// that a field is present, that it has the declared type, and that it is inside
// the declared range, and each names the constraint it enforced so the model is
// told what to change. A path of "" addresses the root object, where the field's
// own name is path enough.

@(private, require_results)
tool_field_path :: proc(path, name: string) -> string {
	if path == "" { return name }
	return fmt.aprintf("%s/%s", path, name, allocator = context.temp_allocator)
}

@(require_results)
tool_field_string :: proc(object: json.Object, name: string, path := "", allocator := context.allocator) -> (string, Tool_Argument_Error) {
	value, present := object[name]
	if !present { return "", tool_argument_error(.Missing_Field, tool_field_path(path, name), allocator = allocator) }
	text, is_string := value.(json.String)
	if !is_string { return "", tool_argument_error(.Wrong_Type, tool_field_path(path, name), "a string", allocator = allocator) }
	return string(text), nil
}

@(require_results)
tool_field_optional_string :: proc(object: json.Object, name: string, path := "", allocator := context.allocator) -> (string, Tool_Argument_Error) {
	value, present := object[name]
	if !present { return "", nil }
	#partial switch item in value {
	case json.Null:
		return "", nil
	case json.String:
		return string(item), nil
	}
	return "", tool_argument_error(.Wrong_Type, tool_field_path(path, name), "a string or null", allocator = allocator)
}

@(require_results)
tool_field_optional_bool :: proc(object: json.Object, name: string, path := "", allocator := context.allocator) -> (bool, Tool_Argument_Error) {
	value, present := object[name]
	if !present { return false, nil }
	#partial switch item in value {
	case json.Null:
		return false, nil
	case json.Boolean:
		return bool(item), nil
	}
	return false, tool_argument_error(.Wrong_Type, tool_field_path(path, name), "a boolean or null", allocator = allocator)
}

// The integer readers take the object's own slot, because a repaired value is written back
// into the document so the recorded arguments say what ran. The repair is added to repairs.
@(require_results)
tool_field_int :: proc(
	object: json.Object,
	name: string,
	minimum, maximum: int,
	repairs: ^Tool_Repairs,
	path := "",
	allocator := context.allocator,
) -> (
	int,
	Tool_Argument_Error,
) {
	object := object
	slot, present := &object[name]
	if !present { return 0, tool_argument_error(.Missing_Field, tool_field_path(path, name), allocator = allocator) }
	return tool_field_int_value(slot, tool_field_path(path, name), minimum, maximum, repairs, allocator)
}

@(require_results)
tool_field_optional_int :: proc(
	object: json.Object,
	name: string,
	fallback, minimum, maximum: int,
	repairs: ^Tool_Repairs,
	path := "",
	allocator := context.allocator,
) -> (
	int,
	Tool_Argument_Error,
) {
	object := object
	slot, present := &object[name]
	if !present { return fallback, nil }
	if _, is_null := slot.(json.Null); is_null { return fallback, nil }
	return tool_field_int_value(slot, tool_field_path(path, name), minimum, maximum, repairs, allocator)
}
@(require_results)
tool_fields_page :: proc(
	object: json.Object,
	offset_fallback, offset_minimum, limit_fallback: int,
	repairs: ^Tool_Repairs,
	path := "",
	allocator := context.allocator,
) -> (
	offset, limit: int,
	err: Tool_Argument_Error,
) {
	object := object
	offset = tool_field_optional_int(object, "offset", offset_fallback, offset_minimum, TOOL_PAGE_MAX_VALUE, repairs, path, allocator) or_return
	limit = tool_field_optional_int(object, "limit", limit_fallback, 1, TOOL_PAGE_MAX_VALUE, repairs, path, allocator) or_return
	return offset, limit, nil
}

@(private, require_results)
tool_field_int_value :: proc(
	slot: ^json.Value,
	path: string,
	minimum, maximum: int,
	repairs: ^Tool_Repairs,
	allocator: mem.Allocator,
) -> (
	int,
	Tool_Argument_Error,
) {
	expected := tool_int_expected(minimum, maximum, allocator)
	defer delete(expected, allocator)
	number, repair, readable := tool_integer_reading(slot^)
	if !readable { return 0, tool_argument_error(.Wrong_Type, path, expected, allocator = allocator) }
	if number < minimum || number > maximum {
		return 0, tool_argument_error(.Invalid_Value, path, expected, allocator = allocator)
	}
	tool_integer_write_back(slot, number, repair, repairs, allocator)
	return number, nil
}

// tool_fields_repair_integers repairs the named integer fields of a document whose fields
// the harness does not read itself. A value with one integer reading is written back as
// that integer; any other value is left for the tool to judge.
tool_fields_repair_integers :: proc(object: json.Object, names: []string, repairs: ^Tool_Repairs, allocator := context.allocator) {
	object := object
	for name in names {
		slot, present := &object[name]
		if !present { continue }
		number, repair, readable := tool_integer_reading(slot^)
		if readable { tool_integer_write_back(slot, number, repair, repairs, allocator) }
	}
}

// tool_integer_write_back replaces a value read as an integer with that integer when
// reading it was a repair, so the document says what the call runs with.
@(private)
tool_integer_write_back :: proc(slot: ^json.Value, number: int, repair: Maybe(Tool_Repair), repairs: ^Tool_Repairs, allocator: mem.Allocator) {
	repair, repaired := repair.?
	if !repaired { return }
	json.destroy_value(slot^, allocator)
	slot^ = json.Integer(number)
	repairs^ += {repair}
}

// tool_integer_reading reads a value as the one integer it names: an integer, a whole number
// small enough to name one integer, or a string holding exactly one integer in decimal with
// no sign other than a leading minus, no leading zero, and nothing around it. repair names
// the change when the value was not already an integer.
@(private, require_results)
tool_integer_reading :: proc(value: json.Value) -> (number: int, repair: Maybe(Tool_Repair), readable: bool) {
	#partial switch item in value {
	case json.Integer:
		return int(item), nil, true
	case json.Float:
		if math.trunc(item) != item || abs(item) > TOOL_EXACT_FLOAT_INTEGER { return 0, nil, false }
		return int(item), .Integer_From_Float, true
	case json.String:
		number, readable = tool_decimal_integer(string(item))
		if !readable { return 0, nil, false }
		return number, .Integer_From_String, true
	}
	return 0, nil, false
}

// tool_decimal_integer reads text that is exactly one decimal integer: an optional leading
// minus, then digits with no leading zero. A number past the int range is not one.
// The magnitude is accumulated negatively, because min(int) has no positive twin.
@(private, require_results)
tool_decimal_integer :: proc(text: string) -> (number: int, ok: bool) {
	digits := strings.trim_prefix(text, "-")
	if digits == "" || (len(digits) > 1 && digits[0] == '0') { return 0, false }
	for digit in transmute([]u8)digits {
		if digit < '0' || digit > '9' { return 0, false }
		place := int(digit - '0')
		if number < (min(int) + place) / 10 { return 0, false }
		number = number * 10 - place
	}
	if len(digits) == len(text) {
		if number == min(int) { return 0, false }
		number = -number
	}
	return number, true
}

// tool_field_array reads a required array field and returns its elements.
@(require_results)
tool_field_array :: proc(
	object: json.Object,
	name: string,
	minimum, maximum: int,
	path := "",
	allocator := context.allocator,
) -> (
	[]json.Value,
	Tool_Argument_Error,
) {
	value, present := object[name]
	field := tool_field_path(path, name)
	if !present { return nil, tool_argument_error(.Missing_Field, field, allocator = allocator) }
	array, is_array := value.(json.Array)
	if !is_array { return nil, tool_argument_error(.Wrong_Type, field, "an array", allocator = allocator) }
	if len(array) < minimum || len(array) > maximum {
		expected := tool_count_expected(minimum, maximum, allocator)
		defer delete(expected, allocator)
		return nil, tool_argument_error(.Invalid_Value, field, expected, allocator = allocator)
	}
	return array[:], nil
}

// tool_field_object reads an object that is already known to be there, naming it
// by the path the diagnostic should use.
@(require_results)
tool_field_object :: proc(value: json.Value, path: string, allocator := context.allocator) -> (json.Object, Tool_Argument_Error) {
	object, is_object := value.(json.Object)
	if !is_object { return nil, tool_argument_error(.Wrong_Type, path, "an object", allocator = allocator) }
	return object, nil
}

// tool_fields_known refuses a field the tool does not declare. A model that
// invents a field is guessing at an interface it was not given, and accepting the
// guess silently would run something other than what it asked for.
@(require_results)
tool_fields_known :: proc(object: json.Object, known: []string, path := "", allocator := context.allocator) -> Tool_Argument_Error {
	for name in object {
		declared := false
		for field in known {
			if name == field {
				declared = true
				break
			}
		}
		if declared { continue }
		expected, expected_error := tool_field_list(known, context.temp_allocator)
		defer delete(expected, context.temp_allocator)
		if expected_error != nil { return Tool_Argument_Defect{kind = .Out_Of_Memory} }
		return tool_argument_error(.Unknown_Field, tool_field_path(path, name), expected, allocator = allocator)
	}
	return {}
}

@(private, require_results)
tool_int_expected :: proc(minimum, maximum: int, allocator: mem.Allocator) -> string {
	if maximum <= 0 { return fmt.aprintf("an integer of at least %d", minimum, allocator = allocator) }
	if minimum <= 0 { return fmt.aprintf("an integer no greater than %d", maximum, allocator = allocator) }
	return fmt.aprintf("an integer between %d and %d", minimum, maximum, allocator = allocator)
}

@(private, require_results)
tool_count_expected :: proc(minimum, maximum: int, allocator: mem.Allocator) -> string {
	if maximum <= 0 { return fmt.aprintf("at least %d items", minimum, allocator = allocator) }
	return fmt.aprintf("between %d and %d items", minimum, maximum, allocator = allocator)
}

// tool_field_list names the declared fields as one English list, owned by allocator. It
// reports an allocator error when the list could not be written whole.
@(private, require_results)
tool_field_list :: proc(known: []string, allocator: mem.Allocator) -> (string, mem.Allocator_Error) {
	builder, builder_error := strings.builder_make(allocator)
	if builder_error != nil { return "", builder_error }
	transferred := false
	defer if !transferred { strings.builder_destroy(&builder) }
	for name, index in known {
		switch {
		case index == 0:
		case index == len(known) - 1:
			separator := " or " if len(known) == 2 else ", or "
			if strings.write_string(&builder, separator) != len(separator) { return "", .Out_Of_Memory }
		case:
			if strings.write_string(&builder, ", ") != 2 { return "", .Out_Of_Memory }
		}
		if strings.write_string(&builder, name) != len(name) { return "", .Out_Of_Memory }
	}
	transferred = true
	return strings.to_string(builder), nil
}
