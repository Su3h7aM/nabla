package mcp

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

// MAX_SUPPORTED_VERSIONS bounds the version list a stateless server may report. The
// list is short by nature, so a longer one is a malformed reply rather than a large
// one.
MAX_SUPPORTED_VERSIONS :: 64

// MAX_VERSION_BYTES bounds one version string. Versions are dates.
MAX_VERSION_BYTES :: 64

// MAX_INSTRUCTIONS_BYTES bounds the natural-language guidance a server offers. It is
// bounded because it is text a peer chose the size of, and it is never used as
// instructions: session guidance comes from the user's own configuration.
MAX_INSTRUCTIONS_BYTES :: 8 * 1024

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

// connection_from_stateless reads a server/discover result. The revision list is
// kept whole rather than reduced to whether this client's appears in it, because a
// server that speaks another revision should be reported with what it does speak.
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
	if len(versions) == 0 || len(versions) > MAX_SUPPORTED_VERSIONS {
		return {}, error_make(.Malformed_Message, "the supported version list is empty or too long", allocator = allocator)
	}
	// The client can only speak what it implements, so a list that omits its own
	// revision is a server it cannot use. Which revisions the server does speak is
	// reported so the reader knows what to look for.
	advertised := make([dynamic]string, 0, len(versions), allocator)
	defer delete(advertised)
	supported := false
	for value in versions {
		text, is_string := value.(json.String)
		if !is_string {
			return {}, error_make(.Malformed_Message, "a supported version is not a string", allocator = allocator)
		}
		name := mcp_clone_bounded(string(text), MAX_VERSION_BYTES, allocator)
		if name == VERSION_2026_07_28 { supported = true }
		append(&advertised, name)
	}
	if !supported {
		message := fmt.tprintf("the server does not support %s; it supports %s", VERSION_2026_07_28, version_list_text(advertised[:], context.temp_allocator))
		for name in advertised { delete(name, allocator) }
		return {}, error_make(.Version_Unsupported, message, allocator = allocator)
	}
	for name in advertised { delete(name, allocator) }

	if capabilities_error := connection_read_capabilities(&connection, result, allocator); capabilities_error.kind != .None {
		return {}, capabilities_error
	}
	connection.server_name, connection.server_version = meta_server_info(result, allocator)
	failed = false
	return connection, {}
}

// connection_from_handshake reads an initialize result. It has no resultType: the
// handshake revisions predate that discriminator, and the revision in force is
// whatever the server answered with.
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
	connection.server_name, connection.server_version = handshake_server_info(result, allocator)
	failed = false
	return connection, {}
}

@(private)
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
		connection.instructions = mcp_clone_bounded(string(text), MAX_INSTRUCTIONS_BYTES, allocator)
	}
	return {}
}

// handshake_server_info reads the identity a handshake result carries at its top
// level.
@(private)
handshake_server_info :: proc(result: json.Object, allocator: mem.Allocator) -> (name: string, version: string) {
	value, present := result["serverInfo"]
	if !present { return "", "" }
	info, is_object := value.(json.Object)
	if !is_object { return "", "" }
	return meta_identity_field(info, "name", allocator), meta_identity_field(info, "version", allocator)
}

// version_list_text joins advertised revisions for a diagnostic. It is bounded by
// the list it was given, which is already bounded.
@(private)
version_list_text :: proc(versions: []string, allocator: mem.Allocator) -> string {
	if len(versions) == 0 { return "nothing this client can read" }
	builder := strings.builder_make(allocator)
	defer strings.builder_destroy(&builder)
	for version, index in versions {
		if index > 0 { strings.write_string(&builder, ", ") }
		strings.write_string(&builder, version)
	}
	return strings.to_string(builder)
}
