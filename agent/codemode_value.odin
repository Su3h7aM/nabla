package agent

import "base:runtime"
import c "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import lua "vendor:lua/5.4"

import "nabla:agent/journal"

// Code Mode crosses its value boundary here. One walk over a Lua value writes it as text: a
// Lua literal for what the model reads, or JSON where JSON is the format, which is a tool
// call's arguments and `json.encode`. Both accept the same values, so what a script may hand
// to a tool is what it may return.

Codemode_Notation :: enum {
	Lua,
	JSON,
}

// CODEMODE_MAX_VALUE_DEPTH is the maximum nesting accepted while converting Lua and JSON values.
CODEMODE_MAX_VALUE_DEPTH :: 32

// Codemode_Path_Step is one step the walk took: the field name it entered, or the array
// position when index is positive.
@(private)
Codemode_Path_Step :: struct {
	name:  string,
	index: int,
}

// Codemode_Walk is one conversion. inside holds the tables the walk is in, which is how a
// cycle is caught. path names where the walk is, one step per table it entered, so it
// cannot hold more steps than the depth guard allows; a refusal keeps the path it failed
// at, together with what it refused and why.
@(private)
Codemode_Walk :: struct {
	run:           ^Lua_Run,
	state:         ^lua.State,
	notation:      Codemode_Notation,
	builder:       strings.Builder,
	inside:        [CODEMODE_MAX_VALUE_DEPTH + 1]rawptr,
	path:          [CODEMODE_MAX_VALUE_DEPTH + 1]Codemode_Path_Step,
	path_count:    int,
	failure_count: int,
	subject:       string,
	problem:       string,
	out_of_memory: bool,
}

// codemode_lua_convert writes the value at index in notation. The text, or the message that
// says what was refused and where, is owned by allocator; out_of_memory says the refusal
// was a lack of memory rather than the value. A value of any size converts; a table nested
// more than CODEMODE_MAX_VALUE_DEPTH deep, a cycle, and a value that is not data are refused.
@(require_results)
codemode_lua_convert :: proc(
	run: ^Lua_Run,
	state: ^lua.State,
	index: i32,
	notation: Codemode_Notation,
	allocator := context.allocator,
) -> (
	text: string,
	message: string,
	out_of_memory: bool,
) {
	context.allocator = allocator
	builder, builder_error := strings.builder_make(allocator)
	if builder_error != nil { return "", codemode_value_allocation_message(allocator), true }
	walk := Codemode_Walk {
		run      = run,
		state    = state,
		notation = notation,
		builder  = builder,
	}
	if codemode_walk_value(&walk, lua.absindex(state, index), 0) { return strings.to_string(walk.builder), "", false }
	strings.builder_destroy(&walk.builder)
	refusal, refusal_error := codemode_walk_message(&walk, allocator)
	if refusal_error != nil { return "", fmt.aprintf("the %s %s", walk.subject, walk.problem), true }
	return "", refusal, walk.out_of_memory
}

// codemode_walk_text writes one part of a refusal message. A builder write that holds fewer
// bytes than it was given ran out of memory, so the whole message is refused rather than
// handed over with a part of it missing.
@(private)
codemode_walk_text :: proc(builder: ^strings.Builder, text: string) -> (written: int, err: runtime.Allocator_Error) #optional_allocator_error {
	if text == "" { return }
	written = strings.write_string(builder, text)
	if written != len(text) { err = .Out_Of_Memory }
	return
}

// codemode_walk_message says what the walk refused, where it refused it, and why. The text
// is owned by allocator.
@(private, require_results)
codemode_walk_message :: proc(walk: ^Codemode_Walk, allocator: runtime.Allocator) -> (text: string, err: runtime.Allocator_Error) {
	builder, builder_error := strings.builder_make(allocator)
	if builder_error != nil { return "", builder_error }
	transferred := false
	defer if !transferred { strings.builder_destroy(&builder) }
	codemode_walk_text(&builder, "the ") or_return
	codemode_walk_text(&builder, walk.subject) or_return
	if walk.failure_count > 0 {
		codemode_walk_text(&builder, " at ") or_return
		for step, position in walk.path[:walk.failure_count] {
			if step.index > 0 {
				fmt.sbprintf(&builder, "[%d]", step.index)
				continue
			}
			if position > 0 { codemode_walk_text(&builder, ".") or_return }
			codemode_walk_text(&builder, step.name) or_return
		}
	}
	codemode_walk_text(&builder, " ") or_return
	codemode_walk_text(&builder, walk.problem) or_return
	transferred = true
	return strings.to_string(builder), nil
}

// codemode_value_allocation_message is what the value boundary tells a caller when it had no
// memory to write the text it was asked for. The caller's allocator owns the message, so the
// caller releases it the way it releases a converted value.
@(private, require_results)
codemode_value_allocation_message :: proc(allocator: runtime.Allocator) -> string {
	return fmt.aprintf("the value could not be written: out of memory", allocator = allocator)
}

// codemode_lua_request_arguments writes the pending request's table as the JSON arguments
// document the child call is admitted from, exactly like a provider's. A call with no table
// gets an empty object. The text, or the message that refuses it, is owned by the run's
// allocator.
@(require_results)
codemode_lua_request_arguments :: proc(run: ^Lua_Run) -> (text: string, message: string) {
	context.allocator = run.allocator
	if run.request.args_ref == lua.NOREF {
		empty, empty_error := strings.clone("{}")
		if empty_error != nil { return "", fmt.aprintf("the call's arguments could not be allocated: out of memory", allocator = run.allocator) }
		return empty, ""
	}
	lua.rawgeti(run.thread, lua.REGISTRYINDEX, lua.Integer(run.request.args_ref))
	defer lua.pop(run.thread, 1)
	text, message, _ = codemode_lua_convert(run, run.thread, -1, .JSON)
	if message != "" { return }
	if strings.has_prefix(text, "[") {
		delete(text)
		return "", fmt.aprintf("%s takes a table of named arguments, and was given an array", run.request.name)
	}
	return
}

// codemode_lua_returned_literal writes the chunk's return value as a Lua literal. No value
// is nil, and more than one is refused: a script has one answer, and dropping a second would
// hide the mistake. The literal or the message is owned by the run's allocator.
@(require_results)
codemode_lua_returned_literal :: proc(run: ^Lua_Run) -> (literal: string, message: string, diagnostic: Codemode_Diagnostic) {
	context.allocator = run.allocator
	switch {
	case run.returned_values == 0:
		none, none_error := strings.clone("nil")
		if none_error != nil { return "", codemode_value_allocation_message(run.allocator), .Out_Of_Memory }
		return none, "", .None
	case run.returned_values > 1:
		refusal, refusal_error := strings.clone("the chunk returned more than one value; return one table instead")
		if refusal_error != nil { return "", codemode_value_allocation_message(run.allocator), .Out_Of_Memory }
		return "", refusal, .Invalid_Value
	}
	out_of_memory: bool
	literal, message, out_of_memory = codemode_lua_convert(run, run.thread, -1, .Lua)
	if message == "" { return literal, "", .None }
	return "", message, out_of_memory ? .Out_Of_Memory : .Invalid_Value
}

// --- the walk ------------------------------------------------------------------

@(private, require_results)
codemode_walk_fail :: proc(walk: ^Codemode_Walk, subject, problem: string) -> bool {
	walk.subject = subject
	walk.problem = problem
	walk.failure_count = walk.path_count
	return false
}

@(private, require_results)
codemode_walk_write :: proc(walk: ^Codemode_Walk, text: string) -> bool {
	if strings.write_string(&walk.builder, text) == len(text) { return true }
	walk.out_of_memory = true
	return codemode_walk_fail(walk, "value", "could not be written: out of memory")
}

@(private, require_results)
codemode_walk_value :: proc(walk: ^Codemode_Walk, index: c.int, depth: int) -> bool {
	state := walk.state
	switch lua.type(state, index) {
	case .NIL:
		return codemode_walk_write(walk, walk.notation == .Lua ? "nil" : "null")
	case .BOOLEAN:
		return codemode_walk_write(walk, lua.toboolean(state, index) ? "true" : "false")
	case .NUMBER:
		return codemode_walk_number(walk, index)
	case .STRING:
		text, _ := codemode_lua_stack_string(state, index)
		if !utf8.valid_string(text) { return codemode_walk_fail(walk, "string", "is not valid UTF-8") }
		return codemode_walk_quoted(walk, text)
	case .LIGHTUSERDATA:
		if lua.touserdata(state, index) != rawptr(walk.run) { return codemode_walk_fail(walk, "light userdata", "cannot be converted") }
		return codemode_walk_write(walk, walk.notation == .Lua ? "json.null" : "null")
	case .TABLE:
		return codemode_walk_table(walk, index, depth)
	case .NONE:
		return codemode_walk_fail(walk, "value", "is missing")
	case .FUNCTION, .USERDATA, .THREAD:
		return codemode_walk_fail(walk, string(lua.typename(state, lua.type(state, index))), "cannot be converted")
	}
	return codemode_walk_fail(walk, "value", "cannot be converted")
}

// codemode_walk_number writes a finite number so it reads back as the same value: an
// integer as its digits, and a float as its shortest exact digits with a fraction mark
// when the digits alone would read as an integer.
@(private, require_results)
codemode_walk_number :: proc(walk: ^Codemode_Walk, index: c.int) -> bool {
	buffer: [32]u8
	if lua.isinteger(walk.state, index) {
		return codemode_walk_write(walk, strconv.write_int(buffer[:], i64(lua.tointeger(walk.state, index)), 10))
	}
	number := f64(lua.tonumber(walk.state, index))
	if math.is_nan(number) || math.is_inf(number) { return codemode_walk_fail(walk, "number", "is not finite") }
	digits := strconv.write_float(buffer[:], number, 'g', -1, 64)
	if digits[0] == '+' { digits = digits[1:] }
	codemode_walk_write(walk, digits) or_return
	if strings.index_any(digits, ".e") < 0 { return codemode_walk_write(walk, ".0") }
	return true
}

// codemode_walk_quoted writes valid UTF-8 text as a string literal of the notation. Both
// keep every character but the quote, the backslash, and control bytes as they are.
@(private, require_results)
codemode_walk_quoted :: proc(walk: ^Codemode_Walk, text: string) -> bool {
	if walk.notation == .Lua {
		if _, err := render_quoted(&walk.builder, text); err != nil {
			walk.out_of_memory = true
			return codemode_walk_fail(walk, "string", "could not be written: out of memory")
		}
		return true
	}
	hex := "0123456789abcdef"
	codemode_walk_write(walk, `"`) or_return
	start := 0
	for index in 0 ..< len(text) {
		character := text[index]
		if character >= 0x20 && character != '"' && character != '\\' { continue }
		codemode_walk_write(walk, text[start:index]) or_return
		start = index + 1
		switch character {
		case '"':
			codemode_walk_write(walk, `\"`) or_return
		case '\\':
			codemode_walk_write(walk, `\\`) or_return
		case '\n':
			codemode_walk_write(walk, `\n`) or_return
		case '\r':
			codemode_walk_write(walk, `\r`) or_return
		case '\t':
			codemode_walk_write(walk, `\t`) or_return
		case:
			escape := [6]u8{'\\', 'u', '0', '0', hex[character >> 4], hex[character & 0x0F]}
			codemode_walk_write(walk, string(escape[:])) or_return
		}
	}
	codemode_walk_write(walk, text[start:]) or_return
	return codemode_walk_write(walk, `"`)
}

// codemode_walk_table decides what a table is and writes it as that. A table is an array
// only when it is dense from 1, and an object only when every key is a string; an empty table
// is an object, because a call with no arguments is the common case. Access is raw, so no
// metamethod runs.
@(private, require_results)
codemode_walk_table :: proc(walk: ^Codemode_Walk, table: c.int, depth: int) -> bool {
	state := walk.state
	// The problem is kept past this frame, so it is static text; the bound it names is CODEMODE_MAX_VALUE_DEPTH.
	if depth > CODEMODE_MAX_VALUE_DEPTH { return codemode_walk_fail(walk, "table", "nests more than 32 levels deep") }
	identity := lua.topointer(state, table)
	if slice.contains(walk.inside[:depth], identity) { return codemode_walk_fail(walk, "table", "contains itself") }
	walk.inside[depth] = identity

	length := int(lua.rawlen(state, table))
	count, names := 0, 0
	lua.pushnil(state)
	for lua.next(state, table) != 0 {
		lua.pop(state, 1)
		count += 1
		#partial switch lua.type(state, -1) {
		case .STRING:
			names += 1
		case .NUMBER:
			if !lua.isinteger(state, -1) {
				lua.pop(state, 1)
				return codemode_walk_fail(walk, "table", "has a key that is not a string or an array index")
			}
			key := lua.tointeger(state, -1)
			if key >= 1 && int(key) <= length { continue }
			lua.pop(state, 1)
			return codemode_walk_fail(walk, "array", "is not dense from 1")
		case:
			lua.pop(state, 1)
			return codemode_walk_fail(walk, "table", "has a key that is not a string or an array index")
		}
	}
	if names > 0 && names < count { return codemode_walk_fail(walk, "table", "mixes named fields and array indexes") }
	if names == 0 && count > 0 {
		if count != length { return codemode_walk_fail(walk, "array", "is not dense from 1") }
		return codemode_walk_array(walk, table, length, depth)
	}
	return codemode_walk_object(walk, table, count, depth)
}

@(private, require_results)
codemode_walk_array :: proc(walk: ^Codemode_Walk, table: c.int, length, depth: int) -> bool {
	lua_notation := walk.notation == .Lua
	codemode_walk_write(walk, lua_notation ? "{" : "[") or_return
	for position in 1 ..= length {
		if position > 1 { codemode_walk_write(walk, lua_notation ? ", " : ",") or_return }
		mark := walk.path_count
		codemode_walk_enter(walk, Codemode_Path_Step{index = position})
		lua.rawgeti(walk.state, table, lua.Integer(position))
		written := codemode_walk_value(walk, lua.gettop(walk.state), depth + 1)
		lua.pop(walk.state, 1)
		if !written { return false }
		codemode_walk_leave(walk, mark)
	}
	return codemode_walk_write(walk, lua_notation ? "}" : "]")
}

// codemode_walk_object writes fields in name order, so the same value is always the same
// text. The names are borrowed from the table, which holds them for the whole walk.
@(private, require_results)
codemode_walk_object :: proc(walk: ^Codemode_Walk, table: c.int, count, depth: int) -> bool {
	state := walk.state
	names, names_error := make([]string, count)
	if names_error != nil {
		walk.out_of_memory = true
		return codemode_walk_fail(walk, "table", "could not be written: out of memory")
	}
	defer delete(names)
	position := 0
	lua.pushnil(state)
	for lua.next(state, table) != 0 {
		lua.pop(state, 1)
		// codemode_walk_table admitted this table only because every key of it is a string.
		names[position], _ = codemode_lua_stack_string(state, -1)
		position += 1
	}
	slice.sort(names)

	lua_notation := walk.notation == .Lua
	codemode_walk_write(walk, "{") or_return
	for name, index in names {
		if index > 0 { codemode_walk_write(walk, lua_notation ? ", " : ",") or_return }
		if !utf8.valid_string(name) { return codemode_walk_fail(walk, "field name", "is not valid UTF-8") }
		if lua_notation && codemode_identifier(name) {
			codemode_walk_write(walk, name) or_return
		} else {
			if lua_notation { codemode_walk_write(walk, "[") or_return }
			codemode_walk_quoted(walk, name) or_return
			if lua_notation { codemode_walk_write(walk, "]") or_return }
		}
		codemode_walk_write(walk, lua_notation ? " = " : ":") or_return

		mark := walk.path_count
		codemode_walk_enter(walk, Codemode_Path_Step{name = name})
		codemode_lua_push_string(state, name)
		lua.rawget(state, table)
		written := codemode_walk_value(walk, lua.gettop(state), depth + 1)
		lua.pop(state, 1)
		if !written { return false }
		codemode_walk_leave(walk, mark)
	}
	return codemode_walk_write(walk, "}")
}

// codemode_walk_enter records the step the walk is entering. The depth guard bounds the
// nesting, so the path always has room for it; the check only keeps the write in bounds.
@(private)
codemode_walk_enter :: proc(walk: ^Codemode_Walk, step: Codemode_Path_Step) {
	if walk.path_count == len(walk.path) { return }
	walk.path[walk.path_count] = step
	walk.path_count += 1
}

// codemode_walk_leave drops every step entered since mark.
@(private)
codemode_walk_leave :: proc(walk: ^Codemode_Walk, mark: int) {
	walk.path_count = mark
}

// codemode_identifier reports whether a name can be written as a bare field name.
@(private, require_results)
codemode_identifier :: proc(name: string) -> bool {
	if !tool_name_valid(name) { return false }
	switch name {
	case "and",
	     "break",
	     "do",
	     "else",
	     "elseif",
	     "end",
	     "false",
	     "for",
	     "function",
	     "goto",
	     "if",
	     "in",
	     "local",
	     "nil",
	     "not",
	     "or",
	     "repeat",
	     "return",
	     "then",
	     "true",
	     "until",
	     "while":
		return false
	}
	return true
}

// --- json.encode and json.decode -------------------------------------------------

@(private)
codemode_lua_json_encode :: proc "c" (state: ^lua.State) -> c.int {
	run := codemode_lua_run(state)
	context = codemode_lua_context(run)
	temp := virtual.arena_temp_begin(&run.scratch)
	lua.settop(state, 1)
	text, message, _ := codemode_lua_convert(run, state, 1, .JSON, allocator = context.temp_allocator)
	if message != "" {
		refusal, refusal_error := strings.concatenate({"json.encode refused ", message}, context.temp_allocator)
		if refusal_error != nil { return codemode_lua_raise(state, "json.encode refused the value: out of memory", temp) }
		return codemode_lua_raise(state, refusal, temp)
	}
	codemode_lua_push_string(state, text)
	virtual.arena_temp_end(temp)
	return 1
}

@(private)
codemode_lua_json_decode :: proc "c" (state: ^lua.State) -> c.int {
	run := codemode_lua_run(state)
	context = codemode_lua_context(run)
	length: c.size_t
	pointer := lua.L_checkstring(state, 1, &length)
	temp := virtual.arena_temp_begin(&run.scratch)
	text := string((cast([^]u8)pointer)[:length])
	if defect, refused := tool_json_admit(text, context.temp_allocator).?; refused {
		reason := codemode_json_defect_text(defect)
		return codemode_lua_raise(state, fmt.tprintf("json.decode refused the text: %s, at line %d column %d", reason, defect.line, defect.column), temp)
	}
	value, parse_error := json.parse_string(text, .JSON, true, context.temp_allocator)
	if parse_error != nil { return codemode_lua_raise(state, "json.decode refused the text: it is not valid JSON", temp) }
	if !codemode_json_push(run, state, value, 0) {
		return codemode_lua_raise(state, fmt.tprintf("json.decode refused a document nested more than %d levels deep", CODEMODE_MAX_VALUE_DEPTH), temp)
	}
	virtual.arena_temp_end(temp)
	return 1
}

// codemode_json_defect_text says what makes a text unreadable as JSON. The text is temporary.
@(private, require_results)
codemode_json_defect_text :: proc(defect: Tool_Argument_Defect) -> string {
	#partial switch defect.kind {
	case .Duplicate_Field:
		return fmt.tprintf("field %q appears twice in one object", defect.field)
	case .Number_Out_Of_Range:
		return "it holds a number that no 64-bit integer or finite float can hold"
	}
	return "it is not valid JSON"
}

// codemode_json_push pushes a JSON document as the Lua value with the same shape. JSON null
// becomes json.null. It reports false, with nothing pushed, for a document nested too deeply.
@(private, require_results)
codemode_json_push :: proc(run: ^Lua_Run, state: ^lua.State, value: json.Value, depth: int) -> bool {
	if depth > CODEMODE_MAX_VALUE_DEPTH { return false }
	switch item in value {
	case json.Null:
		lua.pushlightuserdata(state, run)
	case json.Boolean:
		lua.pushboolean(state, b32(item))
	case json.Integer:
		lua.pushinteger(state, lua.Integer(item))
	case json.Float:
		lua.pushnumber(state, lua.Number(item))
	case json.String:
		codemode_lua_push_string(state, item)
	case json.Array:
		lua.createtable(state, c.int(len(item)), 0)
		for child, index in item {
			if !codemode_json_push(run, state, child, depth + 1) {
				lua.pop(state, 1)
				return false
			}
			lua.rawseti(state, -2, lua.Integer(index + 1))
		}
	case json.Object:
		lua.createtable(state, 0, c.int(len(item)))
		for key, child in item {
			codemode_lua_push_string(state, key)
			if !codemode_json_push(run, state, child, depth + 1) {
				lua.pop(state, 2)
				return false
			}
			lua.rawset(state, -3)
		}
	}
	return true
}

// --- tool results ----------------------------------------------------------------

// codemode_lua_keep_result holds a committed child result under its handle until the script
// waits for it: a table of the outcome, the message, and the typed output. The table is
// built in protected mode, so a lack of memory is reported rather than aborting the process.
@(require_results)
codemode_lua_keep_result :: proc(run: ^Lua_Run, handle: int, result: ^Tool_Result) -> (kept: bool) {
	state := run.state
	lua.pushcfunction(state, codemode_lua_keep_body)
	lua.pushlightuserdata(state, result)
	lua.pushinteger(state, lua.Integer(handle))
	kept = lua.pcall(state, 2, 0, 0) == c.int(lua.Status.OK)
	if !kept { lua.pop(state, 1) }
	virtual.arena_free_all(&run.scratch)
	return
}

@(private)
codemode_lua_keep_body :: proc "c" (state: ^lua.State) -> c.int {
	run := codemode_lua_run(state)
	context = codemode_lua_context(run)
	result := cast(^Tool_Result)lua.touserdata(state, 1)
	handle := lua.tointeger(state, 2)
	lua.rawgeti(state, lua.REGISTRYINDEX, lua.Integer(run.results_ref))
	lua.createtable(state, 0, 3)
	codemode_lua_push_string(state, journal.TOOL_OUTCOME_NAMES[result.outcome])
	lua.setfield(state, -2, "outcome")
	codemode_lua_push_string(state, result.message)
	lua.setfield(state, -2, "message")
	if result.output != nil {
		codemode_push_value(run, state, reflect.get_union_variant(result.output), "")
		lua.setfield(state, -2, "output")
	}
	lua.rawseti(state, -2, handle)
	return 0
}

// codemode_push_value pushes a typed value as the Lua value with the same shape: a struct
// becomes a table keyed by its field names, a slice an array, an absent Maybe nil. A string
// field tagged lua:"json" holds JSON from a peer and is pushed decoded. It allocates only
// from the temporary allocator, which the caller resets.
@(private)
codemode_push_value :: proc(run: ^Lua_Run, state: ^lua.State, value: any, tag: reflect.Struct_Tag) {
	#partial switch info in runtime.type_info_base(type_info_of(value.id)).variant {
	case runtime.Type_Info_String:
		text := (^string)(value.data)^
		if format, _ := reflect.struct_tag_lookup(tag, "lua"); format == "json" {
			decoded, parse_error := json.parse_string(text, .JSON, true, context.temp_allocator)
			if parse_error != nil || text == "" || !codemode_json_push(run, state, decoded, 0) { lua.pushnil(state) }
			return
		}
		codemode_lua_push_string(state, text)
	case runtime.Type_Info_Integer:
		number, _ := reflect.as_i64(value)
		lua.pushinteger(state, lua.Integer(number))
	case runtime.Type_Info_Boolean:
		flag, _ := reflect.as_bool(value)
		lua.pushboolean(state, b32(flag))
	case runtime.Type_Info_Union:
		variant := reflect.get_union_variant(value)
		if variant.id == nil {
			lua.pushnil(state)
			return
		}
		codemode_push_value(run, state, variant, tag)
	case runtime.Type_Info_Slice:
		count := reflect.length(value)
		lua.createtable(state, c.int(count), 0)
		for index in 0 ..< count {
			codemode_push_value(run, state, reflect.index(value, index), "")
			lua.rawseti(state, -2, lua.Integer(index + 1))
		}
	case runtime.Type_Info_Struct:
		lua.createtable(state, 0, c.int(info.field_count))
		for index in 0 ..< int(info.field_count) {
			codemode_lua_push_string(state, info.names[index])
			field := any{rawptr(uintptr(value.data) + info.offsets[index]), info.types[index].id}
			codemode_push_value(run, state, field, reflect.Struct_Tag(info.tags[index]))
			lua.rawset(state, -3)
		}
	case:
		lua.pushnil(state)
	}
}
