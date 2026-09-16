#+test
package mcp

import "core:encoding/json"
import "core:strings"
import "core:testing"

// result_fixture parses a result object the way the protocol layer would have, so a
// decoder is tested against bytes rather than a value the test built.
@(private)
result_fixture :: proc(t: ^testing.T, text: string) -> (owner: json.Value, object: json.Object) {
	value, parse_err := json.parse_string(text, .JSON, true, context.allocator)
	if !testing.expectf(t, parse_err == nil, "the fixture should parse: %v", parse_err) { return nil, nil }
	nested, is_object := value.(json.Object)
	if !testing.expect(t, is_object, "the fixture should be an object") {
		json.destroy_value(value, context.allocator)
		return nil, nil
	}
	return value, nested
}

// --- the stateless revision ---------------------------------------------------

@(test)
test_stateless_connection_reads_capabilities_and_identity :: proc(t: ^testing.T) {
	text := `{
		"resultType": "complete",
		"supportedVersions": ["2025-11-25", "2026-07-28"],
		"capabilities": {"tools": {"listChanged": true}, "resources": {}},
		"instructions": "prefer the narrow tool",
		"_meta": {"io.modelcontextprotocol/serverInfo": {"name": "files", "version": "2.1"}}
	}`
	owner, object := result_fixture(t, text)
	if owner == nil { return }
	defer json.destroy_value(owner, context.allocator)

	connection, err := connection_from_stateless(object, context.allocator)
	defer connection_destroy(&connection, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	testing.expect_value(t, connection.version, Protocol_Version.V2026_07_28)
	testing.expect(t, connection.tools_supported)
	testing.expect(t, connection.tools_list_changed)
	testing.expect_value(t, connection.server_name, "files")
	testing.expect_value(t, connection.server_version, "2.1")
	testing.expect_value(t, connection.instructions, "prefer the narrow tool")
}

// A server that answers the probe but does not list this client's revision is
// refused, and the refusal names what it does list so the reader knows what to look
// for.
@(test)
test_stateless_connection_refuses_a_missing_revision :: proc(t: ^testing.T) {
	owner, object := result_fixture(t, `{"resultType":"complete","supportedVersions":["2025-06-18"],"capabilities":{"tools":{}}}`)
	if owner == nil { return }
	defer json.destroy_value(owner, context.allocator)

	connection, err := connection_from_stateless(object, context.allocator)
	defer connection_destroy(&connection, context.allocator)
	defer error_destroy(&err, context.allocator)
	testing.expect_value(t, err.kind, Error_Kind.Version_Unsupported)
	testing.expect(t, strings.contains(err.message, "2025-06-18"), "the refusal names the advertised revisions")
}

@(test)
test_stateless_connection_reports_a_server_without_tools :: proc(t: ^testing.T) {
	owner, object := result_fixture(t, `{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"resources":{}}}`)
	if owner == nil { return }
	defer json.destroy_value(owner, context.allocator)

	connection, err := connection_from_stateless(object, context.allocator)
	defer connection_destroy(&connection, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }
	testing.expect(t, !connection.tools_supported, "the tools capability was not declared")
}

@(test)
test_stateless_connection_refuses_malformed_results :: proc(t: ^testing.T) {
	cases := []string {
		`{}`,
		`{"resultType":"input_required","supportedVersions":["2026-07-28"],"capabilities":{}}`,
		`{"resultType":"complete","capabilities":{}}`,
		`{"resultType":"complete","supportedVersions":[],"capabilities":{}}`,
		`{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":[]}}`,
	}
	for text in cases {
		owner, object := result_fixture(t, text)
		if owner == nil { continue }
		connection, err := connection_from_stateless(object, context.allocator)
		testing.expectf(t, err.kind != .None, "%s should be refused", text)
		connection_destroy(&connection, context.allocator)
		error_destroy(&err, context.allocator)
		json.destroy_value(owner, context.allocator)
	}
}

// --- the handshake revisions --------------------------------------------------

// A handshake result carries no resultType and reports identity at its top level,
// which is the shape those revisions define.
@(test)
test_handshake_connection_reads_the_negotiated_revision :: proc(t: ^testing.T) {
	text := `{
		"protocolVersion": "2025-11-25",
		"capabilities": {"tools": {"listChanged": false}},
		"serverInfo": {"name": "fff", "version": "0.10.6"},
		"instructions": "a file finder"
	}`
	owner, object := result_fixture(t, text)
	if owner == nil { return }
	defer json.destroy_value(owner, context.allocator)

	connection, err := connection_from_handshake(object, context.allocator)
	defer connection_destroy(&connection, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	testing.expect_value(t, connection.version, Protocol_Version.V2025_11_25)
	testing.expect(t, connection.tools_supported)
	testing.expect_value(t, connection.server_name, "fff")
	testing.expect_value(t, connection.server_version, "0.10.6")
	testing.expect_value(t, connection.instructions, "a file finder")
}

@(test)
test_handshake_connection_reads_the_older_revision :: proc(t: ^testing.T) {
	owner, object := result_fixture(t, `{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"s","version":"1"}}`)
	if owner == nil { return }
	defer json.destroy_value(owner, context.allocator)

	connection, err := connection_from_handshake(object, context.allocator)
	defer connection_destroy(&connection, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }
	testing.expect_value(t, connection.version, Protocol_Version.V2025_06_18)
}

// A revision this client does not implement is refused by name: the reader needs to
// know what the server chose.
@(test)
test_handshake_connection_refuses_an_unimplemented_revision :: proc(t: ^testing.T) {
	owner, object := result_fixture(t, `{"protocolVersion":"2024-11-05","capabilities":{"tools":{}}}`)
	if owner == nil { return }
	defer json.destroy_value(owner, context.allocator)

	connection, err := connection_from_handshake(object, context.allocator)
	defer connection_destroy(&connection, context.allocator)
	defer error_destroy(&err, context.allocator)
	testing.expect_value(t, err.kind, Error_Kind.Version_Unsupported)
	testing.expect(t, strings.contains(err.message, "2024-11-05"), "the refusal names the chosen revision")
}

@(test)
test_handshake_connection_refuses_malformed_results :: proc(t: ^testing.T) {
	cases := []string {
		`{}`,
		`{"protocolVersion":"2025-11-25"}`,
		`{"protocolVersion":"2025-11-25","capabilities":[]}`,
		`{"protocolVersion":"2025-11-25","capabilities":{"tools":{"listChanged":"yes"}}}`,
	}
	for text in cases {
		owner, object := result_fixture(t, text)
		if owner == nil { continue }
		connection, err := connection_from_handshake(object, context.allocator)
		testing.expectf(t, err.kind != .None, "%s should be refused", text)
		connection_destroy(&connection, context.allocator)
		error_destroy(&err, context.allocator)
		json.destroy_value(owner, context.allocator)
	}
}

// The era is the one branch point the request and result shapes depend on.
@(test)
test_era_is_what_the_shapes_depend_on :: proc(t: ^testing.T) {
	testing.expect_value(t, protocol_version_era(.V2026_07_28), Protocol_Era.Stateless)
	testing.expect_value(t, protocol_version_era(.V2025_11_25), Protocol_Era.Handshake)
	testing.expect_value(t, protocol_version_era(.V2025_06_18), Protocol_Era.Handshake)
	testing.expect(t, protocol_version_inlines_server_requests(.V2026_07_28), "only the stateless revision inlines them")
	testing.expect(t, !protocol_version_inlines_server_requests(.V2025_11_25))
	testing.expect(t, !protocol_version_inlines_server_requests(.V2025_06_18))
}
