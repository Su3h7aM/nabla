package agent

import c "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import l "vendor:lua/5.4"

// Code Mode crosses one value boundary: Lua values become the JSON argument document
// every existing tool already admits, and a tool's JSON result envelope becomes a Lua
// value. This file owns that conversion so the executor does not grow a second tool
// argument or result contract.

CODE_MODE_VALUE_MAX_NODES :: 16_384

// CODE_MODE_LOG_MAX_NODES bounds the JSON form of one printed table. The log it feeds
// holds 8 KiB, so a traversal larger than that could only be discarded.
CODE_MODE_LOG_MAX_NODES :: 256

Code_Mode_Value_State :: struct {
	allocator:     mem.Allocator,
	seen:          map[rawptr]bool,
	null_identity: rawptr,
	nodes:         int,
	max_nodes:     int, // zero means CODE_MODE_VALUE_MAX_NODES
}

// code_mode_lua_request_json copies the pending request's argument into one bounded
// JSON object. A wrapper called with no argument gets an empty object, which is the
// natural default for a tool call.
//
// A wrapper takes no argument or exactly one object. A second argument and a value that
// is not a table of named arguments are both refused: each is a mistake in the script,
// and answering the call with an empty or partial object would hide it. A non-empty
// message is owned by the caller.
code_mode_lua_request_json :: proc(run: ^Lua_Run, allocator: mem.Allocator) -> (string, string) {
	if run == nil || run.thread == nil || !run.request.pending { return "", "there is no pending tool request" }
	if run.request.arg_count > 1 {
		return "", fmt.aprintf("%s takes one table of arguments, and was given %d", run.request.name, run.request.arg_count, allocator = allocator)
	}
	if run.request.args_ref == l.REFNIL || run.request.args_ref == l.NOREF {
		empty, clone_err := strings.clone("{}", allocator)
		if clone_err != nil { return "", "the empty tool arguments could not be allocated" }
		return empty, ""
	}

	_ = l.rawgeti(run.thread, l.REGISTRYINDEX, l.Integer(run.request.args_ref))
	defer l.pop(run.thread, 1)
	state := Code_Mode_Value_State {
		allocator     = allocator,
		null_identity = rawptr(run),
	}
	state.seen = make(map[rawptr]bool, allocator)
	defer delete(state.seen)
	value, message := code_mode_lua_to_json_value(run.thread, -1, &state, 0)
	if message != "" { return "", message }
	defer json.destroy_value(value, allocator)
	if _, is_object := value.(json.Object); !is_object {
		return "", fmt.aprintf("%s takes one table of named arguments", run.request.name, allocator = allocator)
	}
	encoded, encode_err := json.marshal(value, allocator = allocator)
	if encode_err != nil { return "", "the tool arguments could not be encoded" }
	return string(encoded), ""
}

@(private)
code_mode_lua_to_json_value :: proc(L: ^l.State, index: c.int, state: ^Code_Mode_Value_State, depth: int) -> (json.Value, string) {
	if depth > TOOL_MAX_ARGS_DEPTH { return {}, "the value nests more than 32 levels deep" }
	state.nodes += 1
	limit := state.max_nodes
	if limit <= 0 { limit = CODE_MODE_VALUE_MAX_NODES }
	if state.nodes > limit { return {}, "the value contains more elements than the boundary allows" }

	switch l.type(L, index) {
	case .NIL:
		return json.Value(json.Null(nil)), ""
	case .BOOLEAN:
		return json.Value(json.Boolean(l.toboolean(L, index) != false)), ""
	case .NUMBER:
		if l.isinteger(L, index) {
			ok: b32
			value := l.tointeger(L, index, &ok)
			if !ok { return {}, "a number is not a usable integer" }
			return json.Value(json.Integer(value)), ""
		}
		ok: b32
		value := l.tonumber(L, index, &ok)
		if !ok { return {}, "a number is not a usable number" }
		return json.Value(json.Float(value)), ""
	case .STRING:
		length: c.size_t
		pointer := l.tolstring(L, index, &length)
		if pointer == nil { return {}, "a string could not be read" }
		bytes := cast([^]u8)pointer
		text := string(bytes[:int(length)])
		// A JSON document is UTF-8, and an endpoint refuses one that is not. A Lua string
		// is bytes, so this is the boundary where that is decided rather than discovered
		// by the provider. A NUL is a byte like any other and survives as an escape.
		if !utf8.valid_string(text) { return {}, "a string is not valid UTF-8" }
		owned, clone_err := strings.clone(text, state.allocator)
		if clone_err != nil { return {}, "a string could not be allocated" }
		return json.Value(json.String(owned)), ""
	case .LIGHTUSERDATA:
		if state.null_identity != nil && l.touserdata(L, index) == state.null_identity {
			return json.Value(json.Null(nil)), ""
		}
		return {}, "a value of this Lua type cannot be written as JSON"
	case .TABLE:
		return code_mode_lua_table_to_json(L, index, state, depth)
	case .NONE, .FUNCTION, .USERDATA, .THREAD:
		return {}, "a value of this Lua type cannot be written as JSON"
	}
	return {}, "a value of this Lua type cannot be written as JSON"
}

@(private)
code_mode_lua_table_to_json :: proc(L: ^l.State, index: c.int, state: ^Code_Mode_Value_State, depth: int) -> (json.Value, string) {
	absolute := l.absindex(L, index)
	identity := l.topointer(L, absolute)
	if identity != nil && state.seen[identity] { return {}, "the value contains a cycle" }
	if identity != nil { state.seen[identity] = true }
	defer if identity != nil { delete_key(&state.seen, identity) }

	// A table is an array only when it is dense from 1, and an object only when every key
	// is a string. Saying which of those failed is the difference between a script author
	// fixing a sparse array and guessing at a mixed one.
	length := int(l.rawlen(L, absolute))
	count := 0
	integers := 0
	strings_seen := 0
	dense := true
	l.pushnil(L)
	for l.next(L, absolute) != 0 {
		count += 1
		if l.type(L, -2) == .NUMBER && l.isinteger(L, -2) {
			key := int(l.tointeger(L, -2))
			integers += 1
			if key < 1 || key > length { dense = false }
		} else if l.type(L, -2) == .STRING {
			strings_seen += 1
		} else {
			l.pop(L, 2)
			return {}, "a table has a key that is not a string or an array index"
		}
		l.pop(L, 1)
	}
	if integers > 0 && strings_seen > 0 { return {}, "a table mixes object fields and array indexes" }
	if strings_seen == 0 && count > 0 && !(dense && count == length) {
		return {}, "a table's array indexes are not dense from 1"
	}
	array := count > 0 && strings_seen == 0

	if array {
		values := make(json.Array, length, state.allocator)
		complete := false
		defer if !complete { json.destroy_value(json.Value(values), state.allocator) }
		for i in 1 ..= length {
			_ = l.rawgeti(L, absolute, l.Integer(i))
			value, message := code_mode_lua_to_json_value(L, -1, state, depth + 1)
			l.pop(L, 1)
			if message != "" { return {}, message }
			values[i - 1] = value
		}
		complete = true
		return json.Value(values), ""
	}

	fields := make(json.Object, count, state.allocator)
	complete := false
	defer if !complete { json.destroy_value(json.Value(fields), state.allocator) }
	l.pushnil(L)
	for l.next(L, absolute) != 0 {
		length: c.size_t
		pointer := l.tolstring(L, -2, &length)
		if pointer == nil {
			l.pop(L, 2)
			return {}, "a table key could not be read"
		}
		bytes := cast([^]u8)pointer
		key := string(bytes[:int(length)])
		if !utf8.valid_string(key) {
			l.pop(L, 2)
			return {}, "a table key is not valid UTF-8"
		}
		owned_key, clone_err := strings.clone(key, state.allocator)
		if clone_err != nil {
			l.pop(L, 2)
			return {}, "a table key could not be allocated"
		}
		value, message := code_mode_lua_to_json_value(L, -1, state, depth + 1)
		l.pop(L, 1)
		if message != "" {
			delete(owned_key, state.allocator)
			return {}, message
		}
		fields[owned_key] = value
	}
	complete = true
	return json.Value(fields), ""
}

// code_mode_lua_returned_json converts the chunk's return value into one JSON value.
// Zero values are JSON null, one is converted, and more than one is refused: a script
// has exactly one answer, and silently dropping a second one would hide the mistake.
code_mode_lua_returned_json :: proc(run: ^Lua_Run, allocator: mem.Allocator) -> (json.Value, string) {
	if run == nil || run.thread == nil || !run.terminal { return {}, "the execution has not finished" }
	switch {
	case run.returned_values == 0:
		return json.Value(json.Null(nil)), ""
	case run.returned_values > 1:
		return {}, "the chunk returned more than one value; return one table instead"
	}
	state := Code_Mode_Value_State {
		allocator     = allocator,
		null_identity = rawptr(run),
	}
	state.seen = make(map[rawptr]bool, allocator)
	defer delete(state.seen)
	return code_mode_lua_to_json_value(run.thread, c.int(-run.returned_values), &state, 0)
}

// code_mode_lua_deliver_json decodes one existing tool result envelope and pushes it
// as the pending call's single Lua result. It uses the boundary's host reserve for the
// allocation-capable C API calls.
code_mode_lua_deliver_json :: proc(run: ^Lua_Run, text: string, allocator: mem.Allocator) -> Lua_Event {
	if run == nil || run.thread == nil || !run.request.pending { return .Failed }
	value, parse_err := json.parse_string(text, .JSON, true, allocator)
	if parse_err != nil { return .Failed }
	defer json.destroy_value(value, allocator)
	code_mode_lua_host_enter(run)
	ok := code_mode_json_push(run, value, 0)
	code_mode_lua_host_leave(run)
	if !ok { return .Failed }
	return code_mode_lua_deliver(run, 1)
}

@(private)
code_mode_json_push :: proc(run: ^Lua_Run, value: json.Value, depth: int) -> bool {
	L := run.thread
	if depth > TOOL_MAX_ARGS_DEPTH { return false }
	#partial switch item in value {
	case json.Null:
		l.pushlightuserdata(L, rawptr(run))
	case json.Boolean:
		l.pushboolean(L, b32(item))
	case json.Integer:
		l.pushinteger(L, l.Integer(item))
	case json.Float:
		l.pushnumber(L, l.Number(item))
	case json.String:
		text := string(item)
		_ = l.pushlstring(L, cstring(raw_data(text)), c.size_t(len(text)))
	case json.Array:
		l.createtable(L, c.int(len(item)), 0)
		table := l.absindex(L, -1)
		for child, i in item {
			if !code_mode_json_push(run, child, depth + 1) {
				l.pop(L, 1)
				return false
			}
			l.rawseti(L, table, l.Integer(i + 1))
		}
	case json.Object:
		l.createtable(L, 0, c.int(len(item)))
		table := l.absindex(L, -1)
		for key, child in item {
			_ = l.pushlstring(L, cstring(raw_data(key)), c.size_t(len(key)))
			if !code_mode_json_push(run, child, depth + 1) {
				l.pop(L, 2)
				return false
			}
			l.rawset(L, table)
		}
	}
	return true
}
