package mcp

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

// Connection is what a server agreed to: which revision is in force, and what it
// said it can do. Every later request is encoded and every reply decoded under it.
//
// The revision is recorded rather than reduced to a boolean because it is what a
// diagnostic should name, and because the era it belongs to is the one thing the
// request and result shapes depend on.
Connection :: struct {
	version:            Protocol_Version,
	server_name:        string,
	server_version:     string,
	instructions:       string,
	tools_supported:    bool,
	tools_list_changed: bool,
	allocator:          mem.Allocator,
}

connection_destroy :: proc(connection: ^Connection, allocator := context.allocator) {
	owner := connection.allocator
	if owner.procedure == nil { owner = allocator }
	delete(connection.server_name, owner)
	delete(connection.server_version, owner)
	delete(connection.instructions, owner)
	connection^ = {}
}

// connection_from_stateless reads a server/discover result. A list that omits this
// client's revision is refused with the revisions the server does speak, rather than
// with a boolean: the reader needs to know what to look for.
@(require_results)
connection_from_stateless :: proc(result: json.Object, allocator := context.allocator) -> (Connection, Error) {
	connection: Connection
	connection.allocator = allocator
	connection.version = .V2026_07_28
	failed := true
	defer if failed { connection_destroy(&connection, allocator) }

	kind, has_kind := result_type(result)
	if !has_kind {
		return {}, error_make(.Malformed_Message, "the discovery result carries no resultType", allocator = allocator)
	}
	if kind != RESULT_TYPE_COMPLETE {
		return {}, error_make(.Unexpected_Message, fmt.tprintf("discovery answered with result type %q", kind), allocator = allocator)
	}

	versions_value, has_versions := result["supportedVersions"]
	if !has_versions {
		return {}, error_make(.Malformed_Message, "the discovery result lists no supported versions", allocator = allocator)
	}
	versions, versions_are_array := versions_value.(json.Array)
	if !versions_are_array {
		return {}, error_make(.Malformed_Message, "the supported versions are not an array", allocator = allocator)
	}
	for value in versions {
		if _, is_string := value.(json.String); !is_string {
			return {}, error_make(.Malformed_Message, "a supported version is not a string", allocator = allocator)
		}
	}
	// The client can only speak what it implements, so a list that omits its own
	// revision is a server it cannot use. Which revisions the server does speak is
	// reported so the reader knows what to look for.
	supported := false
	for value in versions {
		if string(value.(json.String)) == VERSION_2026_07_28 {
			supported = true
			break
		}
	}
	if !supported {
		names, names_error := make([]string, len(versions), context.temp_allocator)
		if names_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
		for value, index in versions { names[index] = string(value.(json.String)) }
		listed, list_error := strings.join(names, ", ", context.temp_allocator)
		if list_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
		if len(versions) == 0 { listed = "nothing this client can read" }
		note, note_error := strings.concatenate({"the server does not support ", VERSION_2026_07_28, "; it supports ", listed}, context.temp_allocator)
		if note_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
		return {}, error_make(.Version_Unsupported, note, allocator = allocator)
	}

	if capabilities_error := connection_read_capabilities(&connection, result, allocator); capabilities_error.kind != .None {
		return {}, capabilities_error
	}
	server_name, server_version, identity_error := meta_server_info(result, allocator)
	if identity_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
	connection.server_name, connection.server_version = server_name, server_version
	failed = false
	return connection, {}
}

// connection_from_handshake reads an initialize result. It has no resultType: the
// handshake revisions predate that discriminator, and the revision in force is
// whatever the server answered with.
@(require_results)
connection_from_handshake :: proc(result: json.Object, allocator := context.allocator) -> (Connection, Error) {
	connection: Connection
	connection.allocator = allocator
	failed := true
	defer if failed { connection_destroy(&connection, allocator) }

	version_value, has_version := result["protocolVersion"]
	version_text, version_is_string := version_value.(json.String)
	if !has_version || !version_is_string {
		return {}, error_make(.Malformed_Message, "the handshake carries no protocol version", allocator = allocator)
	}
	version, known := protocol_version_from_name(string(version_text))
	if !known {
		return {}, error_make(.Version_Unsupported, fmt.tprintf("the server chose protocol revision %s, which this client does not implement", string(version_text)), allocator = allocator)
	}
	connection.version = version

	if capabilities_error := connection_read_capabilities(&connection, result, allocator); capabilities_error.kind != .None {
		return {}, capabilities_error
	}
	// The handshake revisions report identity at the top level of the result, not
	// under `_meta`, which those revisions do not use for it.
	server_name, server_version, identity_error := handshake_server_info(result, allocator)
	if identity_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
	connection.server_name, connection.server_version = server_name, server_version
	failed = false
	return connection, {}
}

@(private, require_results)
connection_read_capabilities :: proc(connection: ^Connection, result: json.Object, allocator: mem.Allocator) -> Error {
	capabilities_value, has_capabilities := result["capabilities"]
	if !has_capabilities {
		return error_make(.Malformed_Message, "the server declares no capabilities", allocator = allocator)
	}
	capabilities, capabilities_are_object := capabilities_value.(json.Object)
	if !capabilities_are_object {
		return error_make(.Malformed_Message, "the capabilities are not an object", allocator = allocator)
	}
	if tools_value, has_tools := capabilities["tools"]; has_tools {
		tools, tools_are_object := tools_value.(json.Object)
		if !tools_are_object {
			return error_make(.Malformed_Message, "the tools capability is not an object", allocator = allocator)
		}
		connection.tools_supported = true
		if changed_value, present := tools["listChanged"]; present {
			changed, changed_is_boolean := changed_value.(json.Boolean)
			if !changed_is_boolean {
				return error_make(.Malformed_Message, "the tools listChanged flag is not a boolean", allocator = allocator)
			}
			connection.tools_list_changed = bool(changed)
		}
	}
	if instructions_value, present := result["instructions"]; present {
		text, is_string := instructions_value.(json.String)
		if !is_string {
			return error_make(.Malformed_Message, "the instructions are not a string", allocator = allocator)
		}
		instructions, clone_error := strings.clone(string(text), allocator)
		if clone_error != nil { return error_make(.Out_Of_Memory, allocator = allocator) }
		connection.instructions = instructions
	}
	return {}
}

// handshake_server_info reads the identity a handshake result carries at its top
// level. The name and version are owned by allocator.
@(private, require_results)
handshake_server_info :: proc(result: json.Object, allocator: mem.Allocator) -> (name: string, version: string, err: mem.Allocator_Error) {
	value, present := result["serverInfo"]
	if !present { return "", "", nil }
	info, is_object := value.(json.Object)
	if !is_object { return "", "", nil }
	owned_name, name_error := meta_identity_field(info, "name", allocator)
	if name_error != nil { return "", "", name_error }
	owned_version, version_error := meta_identity_field(info, "version", allocator)
	if version_error != nil {
		delete(owned_name, allocator)
		return "", "", version_error
	}
	return owned_name, owned_version, nil
}
