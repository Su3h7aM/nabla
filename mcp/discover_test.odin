#+test
package mcp

import "core:encoding/json"
import "core:testing"

// result_fixture parses a result object the way the protocol layer would have, so
// a decoder is tested against bytes rather than a value the test built.
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

@(test)
test_discover_reads_versions_capabilities_and_identity :: proc(t: ^testing.T) {
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

	discover, err := discover_decode(object, context.allocator)
	defer discover_result_destroy(&discover, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	testing.expect_value(t, len(discover.supported_versions), 2)
	testing.expect(t, discover.tools_supported)
	testing.expect(t, discover.tools_list_changed)
	testing.expect_value(t, discover.server_name, "files")
	testing.expect_value(t, discover.server_version, "2.1")
	testing.expect_value(t, discover.instructions, "prefer the narrow tool")
	testing.expect(t, discover_supports_version(discover))
}

// A server that does not list this client's revision is reported with what it does
// list, and a server without the tools capability is reported as such.
@(test)
test_discover_reports_what_a_server_cannot_do :: proc(t: ^testing.T) {
	owner, object := result_fixture(t, `{"resultType":"complete","supportedVersions":["2025-06-18"],"capabilities":{"tools":{}}}`)
	if owner == nil { return }
	defer json.destroy_value(owner, context.allocator)

	discover, err := discover_decode(object, context.allocator)
	testing.expect_value(t, err.kind, Error_Kind.None)
	testing.expect(t, !discover_supports_version(discover), "this revision should not be reported as supported")
	testing.expect_value(t, discover.supported_versions[0], "2025-06-18")
	discover_result_destroy(&discover, context.allocator)
	error_destroy(&err, context.allocator)

	json.destroy_value(owner, context.allocator)
	owner, object = result_fixture(t, `{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"resources":{}}}`)
	if owner == nil { return }
	discover, err = discover_decode(object, context.allocator)
	testing.expect_value(t, err.kind, Error_Kind.None)
	testing.expect(t, !discover.tools_supported, "the tools capability was not declared")
	discover_result_destroy(&discover, context.allocator)
	error_destroy(&err, context.allocator)
}

@(test)
test_discover_refuses_malformed_results :: proc(t: ^testing.T) {
	cases := []string {
		`{}`,
		`{"resultType":"complete","capabilities":{}}`,
		`{"resultType":"complete","supportedVersions":[],"capabilities":{}}`,
		`{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":[]}}`,
	}
	for text in cases {
		owner, object := result_fixture(t, text)
		if owner == nil { continue }
		discover, err := discover_decode(object, context.allocator)
		testing.expectf(t, err.kind != .None, "%s should be refused", text)
		discover_result_destroy(&discover, context.allocator)
		error_destroy(&err, context.allocator)
		json.destroy_value(owner, context.allocator)
	}
}
