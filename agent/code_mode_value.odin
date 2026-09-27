package agent

import "base:runtime"
import c "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import lua "vendor:lua/5.4"

import "nabla:agent/session"

// Code Mode crosses its value boundary here. One checked conversion turns a Lua value into
// the document the harness carries, and the same value is written back as the Lua literal a
// model reads, so what a script may hand to a tool is what it may return.

// CODE_MODE_VALUE_MAX_NODES bounds one conversion. It is not a bound on what a script may
// hold, only on what one call converts at a time.
CODE_MODE_VALUE_MAX_NODES :: 16_384

// CODE_MODE_LOG_MAX_NODES bounds the literal form of one printed value. The log it feeds
// holds 8 KiB, so a traversal larger than that could only be discarded.
CODE_MODE_LOG_MAX_NODES :: 256

// CODE_MODE_VALUE_PATH_MAX_BYTES bounds the path a refusal names. A deeper value keeps the
// prefix of its path that fits, so a refusal stays one short sentence.
CODE_MODE_VALUE_PATH_MAX_BYTES :: 96

// Code_Mode_Value_Walk carries the state of one walk over a Lua value. seen holds the
// tables the walk is inside, which is how a cycle is caught; path names where the walk is,
// so a refusal can say which part of a value is wrong; nodes counts what it has visited.
Code_Mode_Value_Walk :: struct {
	allocator:         mem.Allocator,
	seen:              map[rawptr]bool,
	null_identity:     rawptr,
	nodes:             int,
	max_nodes:         int, // zero means CODE_MODE_VALUE_MAX_NODES
	path:              [CODE_MODE_VALUE_PATH_MAX_BYTES]u8,
	path_length:       int,
	allocation_failed: bool,
}

// code_mode_lua_request_arguments converts the pending tool request into the arguments the
// harness admits: the script's table is checked once, and the document that comes out is both
// what the call runs with and what the record keeps. A wrapper called with no argument gets
// an empty object, which is the natural default for a tool call; a second argument, or a
// value that is not a table of named arguments, is refused rather than guessed at. A
// non-empty message is owned by allocator, and the arguments it describes are not.
code_mode_lua_request_arguments :: proc(run: ^Lua_Run, allocator: mem.Allocator) -> (arguments: Tool_Arguments, message: string) {
	if run == nil || run.thread == nil || !run.request.pending { return {}, "there is no pending tool request" }
	if run.request.arg_count > 1 {
		return {}, fmt.aprintf("%s takes one table of arguments, and was given %d", run.request.name, run.request.arg_count, allocator = allocator)
	}

	value := json.Value(json.Object(nil))
	if run.request.args_ref != lua.REFNIL && run.request.args_ref != lua.NOREF {
		_ = lua.rawgeti(run.thread, lua.REGISTRYINDEX, lua.Integer(run.request.args_ref))
		defer lua.pop(run.thread, 1)
		walk := Code_Mode_Value_Walk {
			allocator     = allocator,
			null_identity = rawptr(run),
		}
		walk.seen = make(map[rawptr]bool, allocator)
		defer delete(walk.seen)
		converted, defect := code_mode_lua_to_json_value(run.thread, -1, &walk, 0)
		if defect != "" { return {}, defect }
		if _, is_object := converted.(json.Object); !is_object {
			json.destroy_value(converted, allocator)
			return {}, fmt.aprintf("%s takes one table of named arguments", run.request.name, allocator = allocator)
		}
		value = converted
	}

	text, encode_error := json.marshal(value, allocator = allocator)
	if encode_error != nil {
		json.destroy_value(value, allocator)
		return {}, "the tool arguments could not be encoded"
	}
	return Tool_Arguments{status = .Valid, value = value, effective = string(text)}, ""
}

// code_mode_lua_to_json_value converts one Lua value into the document the harness carries.
// A value the conversion cannot express is refused with the reason and the path where it was
// found. A non-empty message is owned by the walk's allocator.
code_mode_lua_to_json_value :: proc(state: ^lua.State, index: c.int, walk: ^Code_Mode_Value_Walk, depth: int) -> (json.Value, string) {
	if depth > TOOL_MAX_ARGS_DEPTH {
		return {}, code_mode_value_defect(walk, "value", fmt.tprintf("nests more than %d levels deep", TOOL_MAX_ARGS_DEPTH), walk.allocator)
	}
	walk.nodes += 1
	limit := walk.max_nodes
	if limit <= 0 { limit = CODE_MODE_VALUE_MAX_NODES }
	if walk.nodes > limit {
		return {}, fmt.aprintf("the value contains more than %d elements", limit, allocator = walk.allocator)
	}

	switch lua.type(state, index) {
	case .NIL:
		return json.Value(json.Null(nil)), ""
	case .BOOLEAN:
		return json.Value(json.Boolean(lua.toboolean(state, index) != false)), ""
	case .NUMBER:
		if lua.isinteger(state, index) {
			usable: b32
			number := lua.tointeger(state, index, &usable)
			if !usable { return {}, code_mode_value_defect(walk, "number", "is not an integer Lua can hold", walk.allocator) }
			return json.Value(json.Integer(number)), ""
		}
		usable: b32
		number := lua.tonumber(state, index, &usable)
		if !usable { return {}, code_mode_value_defect(walk, "number", "cannot be read", walk.allocator) }
		// A document carries finite numbers only, and a value with no exact form is not one a
		// script can hand over or read back.
		if math.is_nan(f64(number)) || math.is_inf(f64(number)) {
			return {}, code_mode_value_defect(walk, "number", "is not finite", walk.allocator)
		}
		return json.Value(json.Float(number)), ""
	case .STRING:
		length: c.size_t
		pointer := lua.tolstring(state, index, &length)
		if pointer == nil { return {}, code_mode_value_defect(walk, "string", "could not be read", walk.allocator) }
		text := string((cast([^]u8)pointer)[:int(length)])
		// A document is UTF-8, and an endpoint refuses one that is not. A Lua string is bytes,
		// so this is the boundary where that is decided rather than discovered by a provider.
		// A NUL is a byte like any other and survives as an escape.
		if !utf8.valid_string(text) { return {}, code_mode_value_defect(walk, "string", "is not valid UTF-8", walk.allocator) }
		copied, clone_error := strings.clone(text, walk.allocator)
		if clone_error != nil {
			walk.allocation_failed = true
			return {}, code_mode_value_defect(walk, "string", "could not be allocated", walk.allocator)
		}
		return json.Value(json.String(copied)), ""
	case .LIGHTUSERDATA:
		if walk.null_identity != nil && lua.touserdata(state, index) == walk.null_identity {
			return json.Value(json.Null(nil)), ""
		}
		return {}, code_mode_value_defect(walk, "light userdata", "cannot be converted", walk.allocator)
	case .TABLE:
		return code_mode_lua_table_to_json(state, index, walk, depth)
	case .NONE:
		return {}, code_mode_value_defect(walk, "value", "is not on the stack", walk.allocator)
	case .FUNCTION, .USERDATA, .THREAD:
		return {}, code_mode_value_defect(walk, string(lua.typename(state, lua.type(state, index))), "cannot be converted", walk.allocator)
	}
	return {}, code_mode_value_defect(walk, "value", "cannot be converted", walk.allocator)
}

// code_mode_lua_table_to_json decides what a table is and converts it as that. A table is an
// array only when it is dense from 1, and an object only when every key is a string; an empty
// table is an object, because a call with no arguments is the common case and an empty array
// is not.
@(private)
code_mode_lua_table_to_json :: proc(state: ^lua.State, index: c.int, walk: ^Code_Mode_Value_Walk, depth: int) -> (json.Value, string) {
	table := lua.absindex(state, index)
	identity := lua.topointer(state, table)
	if identity != nil && walk.seen[identity] {
		return {}, code_mode_value_defect(walk, "value", "contains a cycle", walk.allocator)
	}
	if identity != nil { walk.seen[identity] = true }
	defer if identity != nil { delete_key(&walk.seen, identity) }

	length := int(lua.rawlen(state, table))
	count := 0
	indexes := 0
	names := 0
	dense := true
	lua.pushnil(state)
	for lua.next(state, table) != 0 {
		count += 1
		#partial switch lua.type(state, -2) {
		case .NUMBER:
			if !lua.isinteger(state, -2) {
				lua.pop(state, 2)
				return {}, code_mode_value_defect(walk, "table", "has a key that is not a string or an array index", walk.allocator)
			}
			key := int(lua.tointeger(state, -2))
			indexes += 1
			if key < 1 || key > length { dense = false }
		case .STRING:
			names += 1
		case:
			lua.pop(state, 2)
			return {}, code_mode_value_defect(walk, "table", "has a key that is not a string or an array index", walk.allocator)
		}
		lua.pop(state, 1)
	}
	// Which shape failed is the difference between a script author fixing a sparse array and
	// guessing at a mixed table.
	if indexes > 0 && names > 0 {
		return {}, code_mode_value_defect(walk, "table", "mixes object fields and array indexes", walk.allocator)
	}
	if names == 0 && count > 0 && !(dense && count == length) {
		return {}, code_mode_value_defect(walk, "array", "is not dense from 1", walk.allocator)
	}
	// An empty table is an object: a call with no arguments is the common case, and an empty
	// array is not.
	if names == 0 && count > 0 { return code_mode_lua_array_to_json(state, table, length, walk, depth) }
	return code_mode_lua_object_to_json(state, table, count, walk, depth)
}

@(private)
code_mode_lua_array_to_json :: proc(state: ^lua.State, table: c.int, length: int, walk: ^Code_Mode_Value_Walk, depth: int) -> (json.Value, string) {
	values, allocation_error := make(json.Array, length, walk.allocator)
	if allocation_error != nil {
		walk.allocation_failed = true
		return {}, fmt.aprintf("the array could not be allocated", allocator = walk.allocator)
	}
	complete := false
	defer if !complete { json.destroy_value(json.Value(values), walk.allocator) }
	for index in 1 ..= length {
		_ = lua.rawgeti(state, table, lua.Integer(index))
		entered := code_mode_value_index_enter(walk, index)
		value, defect := code_mode_lua_to_json_value(state, -1, walk, depth + 1)
		code_mode_value_path_leave(walk, entered)
		lua.pop(state, 1)
		if defect != "" { return {}, defect }
		values[index - 1] = value
	}
	complete = true
	return json.Value(values), ""
}

@(private)
code_mode_lua_object_to_json :: proc(state: ^lua.State, table: c.int, count: int, walk: ^Code_Mode_Value_Walk, depth: int) -> (json.Value, string) {
	fields, allocation_error := make(json.Object, count, walk.allocator)
	if allocation_error != nil {
		walk.allocation_failed = true
		return {}, fmt.aprintf("the table could not be allocated", allocator = walk.allocator)
	}
	complete := false
	defer if !complete { json.destroy_value(json.Value(fields), walk.allocator) }
	lua.pushnil(state)
	for lua.next(state, table) != 0 {
		length: c.size_t
		pointer := lua.tolstring(state, -2, &length)
		if pointer == nil {
			lua.pop(state, 2)
			return {}, code_mode_value_defect(walk, "key", "could not be read", walk.allocator)
		}
		name := string((cast([^]u8)pointer)[:int(length)])
		if !utf8.valid_string(name) {
			lua.pop(state, 2)
			return {}, code_mode_value_defect(walk, "key", "is not valid UTF-8", walk.allocator)
		}
		owned, clone_error := strings.clone(name, walk.allocator)
		if clone_error != nil {
			lua.pop(state, 2)
			walk.allocation_failed = true
			return {}, code_mode_value_defect(walk, "key", "could not be allocated", walk.allocator)
		}
		separator, field := code_mode_value_field_enter(walk, name)
		value, defect := code_mode_lua_to_json_value(state, -1, walk, depth + 1)
		code_mode_value_field_leave(walk, separator, field)
		lua.pop(state, 1)
		if defect != "" {
			delete(owned, walk.allocator)
			return {}, defect
		}
		fields[owned] = value
	}
	complete = true
	return json.Value(fields), ""
}

// code_mode_lua_returned_literal writes the chunk's return value as the Lua literal a model
// that writes Lua reads. No value is nil, one value is written, and more than one is refused:
// a script has exactly one answer, and silently dropping a second one would hide the mistake.
// The literal is owned by allocator; a diagnostic other than .None says why there is none.
code_mode_lua_returned_literal :: proc(run: ^Lua_Run, allocator: mem.Allocator) -> (literal: string, message: string, diagnostic: Code_Mode_Diagnostic) {
	if run == nil || run.thread == nil || !run.terminal {
		return "", "the execution has not finished", .Invalid_Value
	}
	switch {
	case run.returned_values == 0:
		nothing, clone_error := strings.clone("nil", allocator)
		if clone_error != nil { return "", "the returned value could not be written", .Out_Of_Memory }
		return nothing, "", .None
	case run.returned_values > 1:
		return "", "the chunk returned more than one value; return one table instead", .Invalid_Value
	}

	walk := Code_Mode_Value_Walk {
		allocator     = allocator,
		null_identity = rawptr(run),
	}
	walk.seen = make(map[rawptr]bool, allocator)
	defer delete(walk.seen)
	value, defect := code_mode_lua_to_json_value(run.thread, c.int(-run.returned_values), &walk, 0)
	if defect != "" {
		if walk.allocation_failed { return "", defect, .Out_Of_Memory }
		return "", defect, .Invalid_Value
	}
	defer json.destroy_value(value, allocator)

	builder := strings.builder_make(allocator)
	failed := true
	defer if failed { strings.builder_destroy(&builder) }
	_, write_error := code_mode_write_value_literal(&builder, value)
	if write_error != nil { return "", "the returned value could not be written", .Out_Of_Memory }
	literal = strings.to_string(builder)
	failed = false
	return
}

// code_mode_write_value_literal writes one converted value as the Lua source that builds it.
// Object fields are written in name order, so the same value is always the same text.
code_mode_write_value_literal :: proc(builder: ^strings.Builder, value: json.Value) -> (written: int, err: mem.Allocator_Error) #optional_allocator_error {
	start := len(builder.buf)
	switch item in value {
	case json.Null:
		render_text(builder, "json.null") or_return
	case json.Boolean:
		render_text(builder, "true" if item else "false") or_return
	case json.Integer:
		render_integer(builder, i64(item)) or_return
	case json.Float:
		code_mode_write_number(builder, f64(item)) or_return
	case json.String:
		render_quoted(builder, string(item)) or_return
	case json.Array:
		render_text(builder, "{") or_return
		for child, index in item {
			if index > 0 { render_text(builder, ", ") or_return }
			code_mode_write_value_literal(builder, child) or_return
		}
		render_text(builder, "}") or_return
	case json.Object:
		names := make([dynamic]string, context.temp_allocator)
		defer delete(names)
		for name in item { append(&names, name) }
		slice.sort(names[:])
		render_text(builder, "{") or_return
		for name, index in names {
			if index > 0 { render_text(builder, ", ") or_return }
			if code_mode_identifier(name) {
				render_text(builder, name) or_return
			} else {
				render_byte(builder, '[') or_return
				render_quoted(builder, name) or_return
				render_byte(builder, ']') or_return
			}
			render_text(builder, " = ") or_return
			code_mode_write_value_literal(builder, item[name]) or_return
		}
		render_text(builder, "}") or_return
	}
	written = len(builder.buf) - start
	return
}

// code_mode_write_number writes a finite number so Lua reads back the same value: the shortest
// exact digits, and a fraction mark when the digits alone would read as an integer.
@(private)
code_mode_write_number :: proc(builder: ^strings.Builder, value: f64) -> (written: int, err: mem.Allocator_Error) #optional_allocator_error {
	buffer: [32]u8
	digits := strconv.write_float(buffer[:], value, 'g', -1, 64)
	if digits[0] == '+' { digits = digits[1:] }
	render_text(builder, digits) or_return
	if strings.index_any(digits, ".en") < 0 { render_text(builder, ".0") or_return }
	return
}

// code_mode_identifier reports whether a name can be written as a bare field name.
@(private)
code_mode_identifier :: proc(name: string) -> bool {
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

// code_mode_value_defect names what is wrong and, when the walk is inside a value, where:
// "the table at items[2] mixes object fields and array indexes". The message is owned by
// allocator.
@(private)
code_mode_value_defect :: proc(walk: ^Code_Mode_Value_Walk, subject, defect: string, allocator: mem.Allocator) -> string {
	if walk.path_length == 0 { return fmt.aprintf("the %s %s", subject, defect, allocator = allocator) }
	return fmt.aprintf("the %s at %s %s", subject, string(walk.path[:walk.path_length]), defect, allocator = allocator)
}

// code_mode_value_path_enter appends one step of the path and returns how much of it fit. A
// path that has reached its bound keeps the steps it already has, so a refusal names a prefix
// of the way in rather than nothing.
@(private)
code_mode_value_path_enter :: proc(walk: ^Code_Mode_Value_Walk, step: string) -> int {
	room := len(walk.path) - walk.path_length
	if room <= 0 { return 0 }
	written := min(room, len(step))
	copy(walk.path[walk.path_length:], step[:written])
	walk.path_length += written
	return written
}

@(private)
code_mode_value_path_leave :: proc(walk: ^Code_Mode_Value_Walk, written: int) {
	walk.path_length -= written
}

// code_mode_value_field_enter and code_mode_value_field_leave bracket one object field, so the
// path reads as `nested.name` rather than as two steps.
@(private)
code_mode_value_field_enter :: proc(walk: ^Code_Mode_Value_Walk, name: string) -> (separator, field: int) {
	separator = code_mode_value_path_enter(walk, "." if walk.path_length > 0 else "")
	field = code_mode_value_path_enter(walk, name)
	return
}

@(private)
code_mode_value_field_leave :: proc(walk: ^Code_Mode_Value_Walk, separator, field: int) {
	code_mode_value_path_leave(walk, field)
	code_mode_value_path_leave(walk, separator)
}

@(private)
code_mode_value_index_enter :: proc(walk: ^Code_Mode_Value_Walk, index: int) -> int {
	buffer: [32]u8
	return code_mode_value_path_enter(walk, fmt.bprintf(buffer[:], "[%d]", index))
}

// code_mode_lua_push_result pushes a committed result on the coroutine stack as the table a
// script's tool call returns: its outcome, its message, and its typed output. The table is the
// pending call's answer once the run is resumed with one value.
code_mode_lua_push_result :: proc(run: ^Lua_Run, result: ^Tool_Result) {
	state := run.thread
	lua.createtable(state, 0, 3)
	outcome := session.tool_outcome_name(result.outcome)
	_ = lua.pushlstring(state, cstring(raw_data(outcome)), c.size_t(len(outcome)))
	lua.setfield(state, -2, "outcome")
	_ = lua.pushlstring(state, cstring(raw_data(result.message)), c.size_t(len(result.message)))
	lua.setfield(state, -2, "message")
	if result.output != nil {
		code_mode_push_value(run, reflect.get_union_variant(result.output), "")
		lua.setfield(state, -2, "output")
	}
}

// code_mode_push_value pushes a typed value as the Lua value with the same shape: a struct
// becomes a table keyed by its field names, a slice an array, an absent Maybe nil. A string
// field tagged lua:"json" holds JSON from a peer and is pushed decoded.
@(private)
code_mode_push_value :: proc(run: ^Lua_Run, value: any, tag: reflect.Struct_Tag) {
	state := run.thread
	#partial switch v in runtime.type_info_base(type_info_of(value.id)).variant {
	case runtime.Type_Info_String:
		text := (^string)(value.data)^
		if format, _ := reflect.struct_tag_lookup(tag, "lua"); format == "json" {
			if decoded, err := json.parse_string(text, .JSON, true, context.temp_allocator); err == nil && text != "" {
				if code_mode_json_push(run, decoded, 0) { return }
			}
			lua.pushnil(state)
			return
		}
		_ = lua.pushlstring(state, cstring(raw_data(text)), c.size_t(len(text)))
	case runtime.Type_Info_Integer:
		number, _ := reflect.as_i64(value)
		lua.pushinteger(state, lua.Integer(number))
	case runtime.Type_Info_Boolean:
		flag, _ := reflect.as_bool(value)
		lua.pushboolean(state, b32(flag))
	case runtime.Type_Info_Union:
		variant := reflect.get_union_variant(value)
		if variant.id == nil { lua.pushnil(state); return }
		code_mode_push_value(run, variant, tag)
	case runtime.Type_Info_Slice:
		count := reflect.length(value)
		lua.createtable(state, c.int(count), 0)
		for i in 0 ..< count {
			code_mode_push_value(run, reflect.index(value, i), "")
			lua.rawseti(state, -2, lua.Integer(i + 1))
		}
	case runtime.Type_Info_Struct:
		lua.createtable(state, 0, c.int(v.field_count))
		for i in 0 ..< int(v.field_count) {
			name := v.names[i]
			_ = lua.pushlstring(state, cstring(raw_data(name)), c.size_t(len(name)))
			field := any{rawptr(uintptr(value.data) + v.offsets[i]), v.types[i].id}
			code_mode_push_value(run, field, reflect.Struct_Tag(v.tags[i]))
			lua.rawset(state, -3)
		}
	case:
		lua.pushnil(state)
	}
}

@(private)
code_mode_json_push :: proc(run: ^Lua_Run, value: json.Value, depth: int) -> bool {
	state := run.thread
	if depth > TOOL_MAX_ARGS_DEPTH { return false }
	#partial switch item in value {
	case json.Null:
		lua.pushlightuserdata(state, rawptr(run))
	case json.Boolean:
		lua.pushboolean(state, b32(item))
	case json.Integer:
		lua.pushinteger(state, lua.Integer(item))
	case json.Float:
		lua.pushnumber(state, lua.Number(item))
	case json.String:
		text := string(item)
		_ = lua.pushlstring(state, cstring(raw_data(text)), c.size_t(len(text)))
	case json.Array:
		lua.createtable(state, c.int(len(item)), 0)
		table := lua.absindex(state, -1)
		for child, i in item {
			if !code_mode_json_push(run, child, depth + 1) {
				lua.pop(state, 1)
				return false
			}
			lua.rawseti(state, table, lua.Integer(i + 1))
		}
	case json.Object:
		lua.createtable(state, 0, c.int(len(item)))
		table := lua.absindex(state, -1)
		for key, child in item {
			_ = lua.pushlstring(state, cstring(raw_data(key)), c.size_t(len(key)))
			if !code_mode_json_push(run, child, depth + 1) {
				lua.pop(state, 2)
				return false
			}
			lua.rawset(state, table)
		}
	}
	return true
}
