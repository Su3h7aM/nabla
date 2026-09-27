package agent

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"

import "nabla:agent/session"

// An argument document is admitted at whatever size the model sent. The harness does not
// bound the model's own output: the model and the provider are the only parties that may,
// and a model that asked for more than the provider allows hears it from the provider that
// refused it, not from this package guessing the bound.

// TOOL_MAX_ARGS_DEPTH bounds nesting. It is checked before parsing because the
// JSON parser recurses once per level, so a deeply nested document would reach
// the stack before any later check could refuse it. It is the parser's bound, not
// a bound on what the model may say.
TOOL_MAX_ARGS_DEPTH :: 32

// TOOL_EXACT_FLOAT_INTEGER is the largest magnitude at which every integer has its own f64,
// so a whole float within it names exactly one integer and one beyond it may not.
TOOL_EXACT_FLOAT_INTEGER :: 1 << 53

// A tool argument defect. field is the JSON pointer path of the argument the
// defect is about, and expected names the constraint that was not met: the
// declared type, the accepted range, or the set of accepted fields. Both are
// owned by the error.
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
	Too_Deep,
	Number_Out_Of_Range,
}

Tool_Argument_Error :: struct {
	kind:     Tool_Argument_Error_Kind,
	field:    string, // owned
	expected: string, // owned
}

tool_argument_error :: proc(kind: Tool_Argument_Error_Kind, field := "", expected := "", allocator := context.allocator) -> Tool_Argument_Error {
	err := Tool_Argument_Error {
		kind = kind,
	}
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
	case .Too_Deep:
		return "too_deep"
	case .Number_Out_Of_Range:
		return "number_out_of_range"
	}
	return ""
}

// tool_argument_error_text renders a defect as one sentence. The same defect
// always renders the same bytes, so a recovery turn adds no wording churn to the
// cacheable prefix.
tool_argument_error_text :: proc(err: Tool_Argument_Error, allocator := context.allocator) -> string {
	switch err.kind {
	case .None:
		return ""
	case .Not_Object:
		return strings.clone("the arguments must be a JSON object", allocator)
	case .Syntax:
		return strings.clone("the arguments are not valid JSON", allocator)
	case .Duplicate_Field:
		return strings.clone("the arguments repeat a field name; a field may appear once", allocator)
	case .Unknown_Field:
		return fmt.aprintf("unknown field %q; expected %s", err.field, err.expected, allocator = allocator)
	case .Missing_Field:
		return fmt.aprintf("missing required field %q", err.field, allocator = allocator)
	case .Wrong_Type:
		return fmt.aprintf("field %q must be %s", err.field, err.expected, allocator = allocator)
	case .Invalid_Value:
		if err.expected != "" { return fmt.aprintf("field %q must be %s", err.field, err.expected, allocator = allocator) }
		return fmt.aprintf("field %q is invalid", err.field, allocator = allocator)
	case .Too_Large:
		if err.expected != "" { return fmt.aprintf("field %q must be %s", err.field, err.expected, allocator = allocator) }
		return fmt.aprintf("field %q is too large", err.field, allocator = allocator)
	case .Too_Deep:
		return fmt.aprintf("the arguments nest more than %d levels deep", TOOL_MAX_ARGS_DEPTH, allocator = allocator)
	case .Number_Out_Of_Range:
		return strings.clone("the arguments hold a number that no 64-bit integer or finite float can hold", allocator)
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
	return {kind = tool_argument_error_code(err), field = err.field, expected = err.expected}
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
	repairs:           session.Tool_Repairs,
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
tool_arguments_prepare :: proc(raw: string, allocator := context.allocator) -> (arguments: Tool_Arguments) {
	// Every way out of here either says the document is valid or names the defect that refused
	// it, so the status is never left to mean two things.
	arguments.status = .Rejected
	document := raw
	repairs: session.Tool_Repairs
	// Each repair that rewrites the text leaves its result here, released on the way out.
	rewritten: [3]string
	defer for text in rewritten { delete(text, allocator) }

	trimmed := strings.trim_space(raw)
	if trimmed == "" || trimmed == "null" {
		document = "{}"
		repairs += {.Empty_Arguments}
	}
	if escaped, changed := tool_arguments_escape_control_chars(document, allocator); changed {
		rewritten[0], document = escaped, escaped
		repairs += {.Escaped_Control_Characters}
	}
	if inner, is_string := tool_arguments_string_document(document, allocator); is_string {
		rewritten[1], document = inner, inner
		repairs += {.Double_Encoded_Object}
		// Unquoting turns an escaped newline back into a raw one, which inside the inner
		// document's own string literals is again a control byte with one reading.
		if escaped, changed := tool_arguments_escape_control_chars(document, allocator); changed {
			rewritten[2], document = escaped, escaped
			repairs += {.Escaped_Control_Characters}
		}
	}

	if admit_error := tool_arguments_admit(document, allocator); admit_error.kind != .None {
		arguments.error = admit_error
		return
	}
	value, parse_err := json.parse_string(document, .JSON, true, allocator)
	if parse_err != nil {
		// Admission guarantees the parser accepts the document, so this is unreachable in
		// practice; refusing is the only safe answer.
		json.destroy_value(value, allocator)
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
@(private)
tool_arguments_string_document :: proc(document: string, allocator: mem.Allocator) -> (inner: string, is_string: bool) {
	tokenizer := json.make_tokenizer(document, .JSON, true)
	token, token_err := json.get_token(&tokenizer)
	if token_err != nil || token.kind != .String { return "", false }
	end, end_err := json.get_token(&tokenizer)
	if (end_err != nil && end_err != .EOF) || end.kind != .EOF { return "", false }
	text, unquote_err := json.unquote_string(token, .JSON, allocator)
	if unquote_err != nil { return "", false }
	if !strings.has_prefix(strings.trim_left_space(text), "{") {
		delete(text, allocator)
		return "", false
	}
	return text, true
}

// tool_repairs_text names a set of repairs in declaration order, joined by commas.
tool_repairs_text :: proc(repairs: session.Tool_Repairs, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	for repair in repairs {
		if strings.builder_len(builder) > 0 { strings.write_string(&builder, ", ") }
		strings.write_string(&builder, session.tool_repair_name(repair))
	}
	return strings.to_string(builder)
}

// tool_arguments_admit reports the first structural defect in a proposed
// argument document. The document must be one JSON object, alone in its input,
// with no repeated field name at any depth and no nesting past the argument
// bound. A repeated field name is refused rather than resolved: the harness will
// not choose which of two values the model meant.
//
// Admission walks the tokenizer instead of calling the parser because the parser
// both accepts trailing input and leaks on some malformed documents.
tool_arguments_admit :: proc(raw: string, allocator: mem.Allocator) -> Tool_Argument_Error {
	tokenizer := json.make_tokenizer(raw, .JSON, true)
	token, token_err := json.get_token(&tokenizer)
	if tool_token_bad(token, token_err) { return tool_argument_error(.Syntax, allocator = allocator) }
	if token.kind != .Open_Brace { return tool_argument_error(.Not_Object, allocator = allocator) }
	if object_error := tool_admit_object(&tokenizer, 1, allocator); object_error.kind != .None { return object_error }

	token, token_err = json.get_token(&tokenizer)
	if (token_err != nil && token_err != .EOF) || token.kind != .EOF {
		return tool_argument_error(.Syntax, allocator = allocator)
	}
	return {}
}

// tool_token_bad reports a token that cannot be used: a tokenizer failure or an
// end of input where the document still owes structure.
@(private)
tool_token_bad :: proc(token: json.Token, err: json.Error) -> bool {
	return (err != nil && err != .EOF) || token.kind == .EOF
}

@(private)
tool_admit_object :: proc(tokenizer: ^json.Tokenizer, depth: int, allocator: mem.Allocator) -> Tool_Argument_Error {
	if depth > TOOL_MAX_ARGS_DEPTH { return tool_argument_error(.Too_Deep, allocator = allocator) }
	seen := make(map[string]bool, context.temp_allocator)
	defer delete(seen)

	comma := false
	for {
		token, token_err := json.get_token(tokenizer)
		if tool_token_bad(token, token_err) { return tool_argument_error(.Syntax, allocator = allocator) }
		if token.kind == .Close_Brace {
			if comma { return tool_argument_error(.Syntax, allocator = allocator) }
			return {}
		}
		if token.kind != .String { return tool_argument_error(.Syntax, allocator = allocator) }

		key, key_err := json.unquote_string(token, .JSON, context.temp_allocator)
		if key_err != nil { return tool_argument_error(.Syntax, allocator = allocator) }
		if seen[key] { return tool_argument_error(.Duplicate_Field, allocator = allocator) }
		seen[key] = true

		colon, colon_err := json.get_token(tokenizer)
		if tool_token_bad(colon, colon_err) || colon.kind != .Colon {
			return tool_argument_error(.Syntax, allocator = allocator)
		}
		value, value_err := json.get_token(tokenizer)
		if tool_token_bad(value, value_err) { return tool_argument_error(.Syntax, allocator = allocator) }
		if value_error := tool_admit_value(tokenizer, value, depth + 1, allocator); value_error.kind != .None { return value_error }

		separator, separator_err := json.get_token(tokenizer)
		if tool_token_bad(separator, separator_err) { return tool_argument_error(.Syntax, allocator = allocator) }
		if separator.kind == .Comma { comma = true; continue }
		if separator.kind == .Close_Brace { return {} }
		return tool_argument_error(.Syntax, allocator = allocator)
	}
}

@(private)
tool_admit_array :: proc(tokenizer: ^json.Tokenizer, depth: int, allocator: mem.Allocator) -> Tool_Argument_Error {
	if depth > TOOL_MAX_ARGS_DEPTH { return tool_argument_error(.Too_Deep, allocator = allocator) }

	comma := false
	for {
		token, token_err := json.get_token(tokenizer)
		if tool_token_bad(token, token_err) { return tool_argument_error(.Syntax, allocator = allocator) }
		if token.kind == .Close_Bracket {
			if comma { return tool_argument_error(.Syntax, allocator = allocator) }
			return {}
		}
		if value_error := tool_admit_value(tokenizer, token, depth + 1, allocator); value_error.kind != .None { return value_error }

		separator, separator_err := json.get_token(tokenizer)
		if tool_token_bad(separator, separator_err) { return tool_argument_error(.Syntax, allocator = allocator) }
		if separator.kind == .Comma { comma = true; continue }
		if separator.kind == .Close_Bracket { return {} }
		return tool_argument_error(.Syntax, allocator = allocator)
	}
}

// tool_admit_value continues from a token that has already been read, which is
// what keeps a container's element token from being read twice.
//
// A number is admitted only if the parser can hold it as written: the parser wraps an
// integer past the 64-bit range and reads an enormous float as infinity, and either would
// run the call with a number the model never sent.
@(private)
tool_admit_value :: proc(tokenizer: ^json.Tokenizer, token: json.Token, depth: int, allocator: mem.Allocator) -> Tool_Argument_Error {
	#partial switch token.kind {
	case .Open_Brace:
		return tool_admit_object(tokenizer, depth, allocator)
	case .Open_Bracket:
		return tool_admit_array(tokenizer, depth, allocator)
	case .Integer:
		if _, fits := tool_decimal_integer(token.text); !fits { return tool_argument_error(.Number_Out_Of_Range, allocator = allocator) }
		return {}
	case .Float:
		number, parsed := strconv.parse_f64(token.text)
		if !parsed || math.is_inf(number) { return tool_argument_error(.Number_Out_Of_Range, allocator = allocator) }
		return {}
	case .String, .True, .False, .Null:
		return {}
	}
	return tool_argument_error(.Syntax, allocator = allocator)
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

// --- reading fields ----------------------------------------------------------

// The field readers below are the whole of argument validation. Each one checks
// that a field is present, that it has the declared type, and that it is inside
// the declared range, and each names the constraint it enforced so the model is
// told what to change. A path of "" addresses the root object, where the field's
// own name is path enough.

@(private)
tool_field_path :: proc(path, name: string) -> string {
	if path == "" { return name }
	return fmt.aprintf("%s/%s", path, name, allocator = context.temp_allocator)
}

tool_field_string :: proc(object: json.Object, name: string, path := "", allocator := context.allocator) -> (string, Tool_Argument_Error) {
	value, present := object[name]
	if !present { return "", tool_argument_error(.Missing_Field, tool_field_path(path, name), allocator = allocator) }
	text, is_string := value.(json.String)
	if !is_string { return "", tool_argument_error(.Wrong_Type, tool_field_path(path, name), "a string", allocator = allocator) }
	return string(text), {}
}

tool_field_optional_string :: proc(object: json.Object, name: string, path := "", allocator := context.allocator) -> (string, Tool_Argument_Error) {
	value, present := object[name]
	if !present { return "", {} }
	#partial switch v in value {
	case json.Null:
		return "", {}
	case json.String:
		return string(v), {}
	}
	return "", tool_argument_error(.Wrong_Type, tool_field_path(path, name), "a string or null", allocator = allocator)
}

// The integer readers take the object's own slot, because a repaired value is written back
// into the document so the recorded arguments say what ran. The repair is added to repairs.
tool_field_int :: proc(
	object: json.Object,
	name: string,
	minimum, maximum: int,
	repairs: ^session.Tool_Repairs,
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

tool_field_optional_int :: proc(
	object: json.Object,
	name: string,
	fallback, minimum, maximum: int,
	repairs: ^session.Tool_Repairs,
	path := "",
	allocator := context.allocator,
) -> (
	int,
	Tool_Argument_Error,
) {
	object := object
	slot, present := &object[name]
	if !present { return fallback, {} }
	if _, is_null := slot.(json.Null); is_null { return fallback, {} }
	return tool_field_int_value(slot, tool_field_path(path, name), minimum, maximum, repairs, allocator)
}

@(private)
tool_field_int_value :: proc(
	slot: ^json.Value,
	path: string,
	minimum, maximum: int,
	repairs: ^session.Tool_Repairs,
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
	return number, {}
}

// tool_fields_repair_integers repairs the named integer fields of a document whose fields
// the harness does not read itself. A value with one integer reading is written back as
// that integer; any other value is left for the tool to judge.
tool_fields_repair_integers :: proc(object: json.Object, names: []string, repairs: ^session.Tool_Repairs, allocator := context.allocator) {
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
tool_integer_write_back :: proc(slot: ^json.Value, number: int, repair: Maybe(session.Tool_Repair), repairs: ^session.Tool_Repairs, allocator: mem.Allocator) {
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
@(private)
tool_integer_reading :: proc(value: json.Value) -> (number: int, repair: Maybe(session.Tool_Repair), readable: bool) {
	#partial switch v in value {
	case json.Integer:
		return int(v), nil, true
	case json.Float:
		if math.trunc(v) != v || abs(v) > TOOL_EXACT_FLOAT_INTEGER { return 0, nil, false }
		return int(v), .Integer_From_Float, true
	case json.String:
		number, readable = tool_decimal_integer(string(v))
		if !readable { return 0, nil, false }
		return number, .Integer_From_String, true
	}
	return 0, nil, false
}

// tool_decimal_integer reads text that is exactly one decimal integer: an optional leading
// minus, then digits with no leading zero. A number past the int range is not one.
@(private)
tool_decimal_integer :: proc(text: string) -> (number: int, ok: bool) {
	digits := strings.trim_prefix(text, "-")
	if digits == "" || (len(digits) > 1 && digits[0] == '0') { return 0, false }
	for digit in transmute([]u8)digits {
		if digit < '0' || digit > '9' { return 0, false }
		place := int(digit - '0')
		if number > (max(int) - place) / 10 { return 0, false }
		number = number * 10 + place
	}
	if len(digits) < len(text) { number = -number }
	return number, true
}

// tool_field_array reads a required array field and returns its elements.
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
	return array[:], {}
}

// tool_field_object reads an object that is already known to be there, naming it
// by the path the diagnostic should use.
tool_field_object :: proc(value: json.Value, path: string, allocator := context.allocator) -> (json.Object, Tool_Argument_Error) {
	object, is_object := value.(json.Object)
	if !is_object { return nil, tool_argument_error(.Wrong_Type, path, "an object", allocator = allocator) }
	return object, {}
}

// tool_fields_known refuses a field the tool does not declare. A model that
// invents a field is guessing at an interface it was not given, and accepting the
// guess silently would run something other than what it asked for.
tool_fields_known :: proc(object: json.Object, known: []string, path := "", allocator := context.allocator) -> Tool_Argument_Error {
	for name in object {
		declared := false
		for field in known {
			if name == field { declared = true; break }
		}
		if declared { continue }
		expected := tool_field_list(known, context.temp_allocator)
		defer delete(expected, context.temp_allocator)
		return tool_argument_error(.Unknown_Field, tool_field_path(path, name), expected, allocator = allocator)
	}
	return {}
}

@(private)
tool_int_expected :: proc(minimum, maximum: int, allocator: mem.Allocator) -> string {
	if maximum <= 0 { return fmt.aprintf("an integer of at least %d", minimum, allocator = allocator) }
	if minimum <= 0 { return fmt.aprintf("an integer no greater than %d", maximum, allocator = allocator) }
	return fmt.aprintf("an integer between %d and %d", minimum, maximum, allocator = allocator)
}

@(private)
tool_count_expected :: proc(minimum, maximum: int, allocator: mem.Allocator) -> string {
	if maximum <= 0 { return fmt.aprintf("at least %d items", minimum, allocator = allocator) }
	return fmt.aprintf("between %d and %d items", minimum, maximum, allocator = allocator)
}

@(private)
tool_field_list :: proc(known: []string, allocator: mem.Allocator) -> string {
	builder := strings.builder_make(allocator)
	for name, index in known {
		switch {
		case index == 0:
		case index == len(known) - 1:
			strings.write_string(&builder, " or " if len(known) == 2 else ", or ")
		case:
			strings.write_string(&builder, ", ")
		}
		strings.write_string(&builder, name)
	}
	return strings.to_string(builder)
}
