package mcp

import "core:encoding/json"
import "core:fmt"
import "core:mem"

// MAX_SUPPORTED_VERSIONS bounds the version list a server may report. The list is
// short by nature, so a longer one is a malformed reply rather than a large one.
MAX_SUPPORTED_VERSIONS :: 64

// MAX_VERSION_BYTES bounds one version string. Versions are dates.
MAX_VERSION_BYTES :: 64

// MAX_INSTRUCTIONS_BYTES bounds the natural-language guidance a server offers.
// It is bounded because it is text a peer chose the size of, and it is never used
// as instructions: session guidance comes from the user's own configuration.
MAX_INSTRUCTIONS_BYTES :: 8 * 1024

// Discover_Result is what server/discover reported. Every string is owned by the
// allocator it was read with.
//
// supported_versions is kept whole rather than reduced to whether this client's
// version appears in it, because a server that does not support this revision
// should be reported with the versions it does support.
Discover_Result :: struct {
	supported_versions: []string,
	server_name:        string,
	server_version:     string,
	instructions:       string,
	tools_supported:    bool,
	tools_list_changed: bool,
	allocator:          mem.Allocator,
}

discover_result_destroy :: proc(discover: ^Discover_Result, allocator := context.allocator) {
	owner := discover.allocator
	if owner.procedure == nil { owner = allocator }
	for version in discover.supported_versions { delete(version, owner) }
	delete(discover.supported_versions, owner)
	delete(discover.server_name, owner)
	delete(discover.server_version, owner)
	delete(discover.instructions, owner)
	discover^ = {}
}

// discover_supports_version reports whether the server listed this client's
// revision. A server that did not is not usable, because the semantics of every
// other request would be unknown.
discover_supports_version :: proc(discover: Discover_Result) -> bool {
	for version in discover.supported_versions {
		if version == PROTOCOL_VERSION { return true }
	}
	return false
}

// discover_decode reads a server/discover result. It reports what the server said
// and refuses only what cannot be read: whether this client can use the server is
// the caller's decision, made from the reported facts.
discover_decode :: proc(result: json.Object, allocator := context.allocator) -> (Discover_Result, Error) {
	// The accumulator is a local rather than the named return value: a deferred
	// cleanup runs after the return value is assigned, so a named one would be
	// freed after it had already been overwritten with the zero value.
	discover: Discover_Result
	discover.allocator = allocator
	failed := true
	defer if failed { discover_result_destroy(&discover, allocator) }

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
	// The count is known, so the slice is allocated once. Entries are filled by
	// index, which leaves the ones after a refused version empty: the deferred
	// cleanup releases the whole slice, and releasing an empty string is a no-op.
	discover.supported_versions = make([]string, len(versions), allocator)
	for value, index in versions {
		text, is_string := value.(json.String)
		if !is_string {
			return {}, error_make(.Malformed_Message, "a supported version is not a string", allocator = allocator)
		}
		discover.supported_versions[index] = mcp_clone_bounded(string(text), MAX_VERSION_BYTES, allocator)
	}

	capabilities_value, has_capabilities := result["capabilities"]
	if !has_capabilities {
		return {}, error_make(.Malformed_Message, "the discovery result declares no capabilities", allocator = allocator)
	}
	capabilities, capabilities_are_object := capabilities_value.(json.Object)
	if !capabilities_are_object {
		return {}, error_make(.Malformed_Message, "the capabilities are not an object", allocator = allocator)
	}
	if tools_value, has_tools := capabilities["tools"]; has_tools {
		tools, tools_are_object := tools_value.(json.Object)
		if !tools_are_object {
			return {}, error_make(.Malformed_Message, "the tools capability is not an object", allocator = allocator)
		}
		discover.tools_supported = true
		if changed_value, present := tools["listChanged"]; present {
			changed, changed_is_boolean := changed_value.(json.Boolean)
			if !changed_is_boolean {
				return {}, error_make(.Malformed_Message, "the tools listChanged flag is not a boolean", allocator = allocator)
			}
			discover.tools_list_changed = bool(changed)
		}
	}

	if instructions_value, present := result["instructions"]; present {
		text, is_string := instructions_value.(json.String)
		if !is_string {
			return {}, error_make(.Malformed_Message, "the discovery instructions are not a string", allocator = allocator)
		}
		discover.instructions = mcp_clone_bounded(string(text), MAX_INSTRUCTIONS_BYTES, allocator)
	}

	discover.server_name, discover.server_version = meta_server_info(result, allocator)
	failed = false
	return discover, {}
}

// discover_params_make builds the params for a discovery request. The request
// carries nothing beyond the per-request protocol metadata.
discover_params_make :: proc(allocator := context.allocator) -> json.Object {
	return request_params_make(0, allocator)
}
