#+test
#+private file
package acp

import "core:encoding/json"
import "core:testing"

// Every kind must survive decode and encode unchanged, with its shared fields and the payload of a kind this package does not know.
@(test)
test_content_blocks_round_trip_every_kind :: proc(t: ^testing.T) {
	documents := [?]string {
		`{"type":"text","text":"hi","_meta":{"a":1},"annotations":{"priority":0.5}}`,
		`{"type":"image","data":"aW1n","mimeType":"image/png","uri":"file:///a.png"}`,
		`{"type":"audio","data":"YXVk","mimeType":"audio/wav"}`,
		`{"type":"resource_link","uri":"file:///a.odin","name":"a.odin","mimeType":"text/x-odin","title":"A","description":"d","size":0,"icons":[{"src":"file:///i.svg","mimeType":"image/svg+xml","sizes":["any"],"theme":"dark"}]}`,
		`{"type":"resource","resource":{"uri":"file:///a.txt","mimeType":"text/plain","text":"body"}}`,
		`{"type":"resource","annotations":{},"resource":{"uri":"file:///a.bin","blob":"YWJj","_meta":{"k":"v"}}}`,
		`{"type":"_vendor","payload":[1,2]}`,
	}
	defer free_all(context.temp_allocator)
	for document in documents {
		value, parse_error := json.parse_string(document, .JSON, true, context.allocator)
		if !testing.expect_value(t, parse_error, nil) { continue }
		defer json.destroy_value(value, context.allocator)

		block, decode_error := content_block_decode(value, context.allocator)
		if !testing.expect_value(t, decode_error, Params_Error.None) { continue }
		defer content_block_destroy(block, context.allocator)
		encoded, encode_error := content_block_encode(block, context.temp_allocator)
		testing.expect_value(t, encode_error, nil)

		options := json.Marshal_Options {
			sort_maps_by_key = true,
		}
		want, want_error := json.marshal(value, options, context.temp_allocator)
		got, got_error := json.marshal(encoded, options, context.temp_allocator)
		testing.expect_value(t, want_error, nil)
		testing.expect_value(t, got_error, nil)
		testing.expect_value(t, string(got), string(want))

		switch kind in block.variant {
		case Content_Resource_Link:
			size, has_size := kind.size.?
			testing.expect(t, has_size)
			testing.expect_value(t, size, 0)
			if testing.expect_value(t, len(kind.icons), 1) {
				testing.expect_value(t, kind.icons[0].sizes[0], "any")
				testing.expect_value(t, kind.icons[0].theme, "dark")
			}
		case Content_Resource:
			if kind.resource.uri == "file:///a.bin" {
				blob, is_blob := kind.resource.variant.(Resource_Blob)
				testing.expect(t, is_blob)
				testing.expect_value(t, blob.blob, "YWJj")
			}
		case Content_Other:
			testing.expect_value(t, kind.type, "_vendor")
		case Content_Text, Content_Image, Content_Audio:
		case nil:
			testing.expect(t, false)
		}
	}
}

@(test)
test_content_block_decode_refuses_mismatched_shapes :: proc(t: ^testing.T) {
	documents := [?]string {
		`"text"`,
		`{"text":"no type"}`,
		`{"type":"text"}`,
		`{"type":"text","text":1}`,
		`{"type":"image","text":"x"}`,
		`{"type":"resource","resource":{"uri":"file:///a"}}`,
		`{"type":"resource","resource":"file:///a"}`,
		`{"type":"resource_link","uri":"file:///a","icons":[{"theme":"dark"}]}`,
	}
	for document in documents {
		value, parse_error := json.parse_string(document, .JSON, true, context.allocator)
		if !testing.expect_value(t, parse_error, nil) { continue }
		defer json.destroy_value(value, context.allocator)
		block, decode_error := content_block_decode(value, context.allocator)
		testing.expectf(t, decode_error == .Invalid, "%s was accepted", document)
		content_block_destroy(block, context.allocator)
	}
}

@(test)
test_prompt_params_decode_reads_content_blocks_and_tolerates_extra_fields :: proc(t: ^testing.T) {
	value, parse_error := json.parse_string(
		`{"sessionId":"s","prompt":[{"type":"text","text":"hi","_meta":{},"extra":true},{"type":"resource_link","uri":"file:///a.odin","name":"a.odin"}],"extra":1}`,
		.JSON,
		true,
		context.allocator,
	)
	defer json.destroy_value(value, context.allocator)
	testing.expect_value(t, parse_error, nil)

	params: Session_Prompt_Params
	testing.expect_value(t, session_prompt_params_decode(value, &params), Params_Error.None)
	defer {
		for block in params.prompt { content_block_destroy(block) }
		delete(params.prompt)
	}
	testing.expect_value(t, params.session_id, "s")
	if !testing.expect_value(t, len(params.prompt), 2) { return }
	text, is_text := params.prompt[0].variant.(Content_Text)
	testing.expect(t, is_text)
	testing.expect_value(t, text.text, "hi")
	link, is_link := params.prompt[1].variant.(Content_Resource_Link)
	testing.expect(t, is_link)
	testing.expect_value(t, link.uri, "file:///a.odin")
}

// The two versions of initialize name the client differently, so each request document
// decodes into its own type and encodes back to its own field names.
@(test)
test_initialize_params_decode_and_encode_per_version :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	v1_value, v1_error := json.parse_string(
		`{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":false},"terminal":true},"clientInfo":{"name":"c","version":"1"}}`,
		.JSON,
		true,
		context.allocator,
	)
	testing.expect_value(t, v1_error, nil)
	defer json.destroy_value(v1_value, context.allocator)
	v1: V1_Initialize_Params
	testing.expect_value(t, params_decode(v1_value, &v1, context.temp_allocator), Params_Error.None)
	capabilities, has_capabilities := v1.client_capabilities.?
	testing.expect(t, has_capabilities)
	testing.expect(t, capabilities.fs.read_text_file)
	testing.expect(t, capabilities.terminal)
	info, has_info := v1.client_info.?
	testing.expect(t, has_info)
	testing.expect_value(t, info.name, "c")

	v2_value, v2_error := json.parse_string(
		`{"protocolVersion":2,"capabilities":{"auth":{"terminal":true}},"info":{"name":"c","version":"2"}}`,
		.JSON,
		true,
		context.allocator,
	)
	testing.expect_value(t, v2_error, nil)
	defer json.destroy_value(v2_value, context.allocator)
	v2: V2_Initialize_Params
	testing.expect_value(t, params_decode(v2_value, &v2, context.temp_allocator), Params_Error.None)
	auth, has_auth := v2.capabilities.auth.?
	testing.expect(t, has_auth)
	testing.expect(t, auth.terminal)
	testing.expect_value(t, v2.info.version, "2")

	v1_wire, v1_marshal_error := json.marshal(v1, allocator = context.temp_allocator)
	testing.expect_value(t, v1_marshal_error, nil)
	testing.expect_value(
		t,
		string(v1_wire),
		`{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":false},"terminal":true},"clientInfo":{"name":"c","version":"1"}}`,
	)

	bad_value, bad_error := json.parse_string(`{"protocolVersion":1,"clientInfo":"c"}`, .JSON, true, context.allocator)
	testing.expect_value(t, bad_error, nil)
	defer json.destroy_value(bad_value, context.allocator)
	bad: V1_Initialize_Params
	testing.expect_value(t, params_decode(bad_value, &bad, context.temp_allocator), Params_Error.Invalid)
}

// Every option kind must survive decode and encode, in the spelling of the version it is encoded for.
@(test)
test_config_options_round_trip_every_kind_in_both_versions :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// The v1 spelling of the ids, then the v2 spelling, of the same four options.
	documents := [?]string {
		`[{"_meta":{"a":1},"id":"model","name":"Model","category":"model","description":"d","type":"select","currentValue":"a","options":[{"value":"a","name":"A","description":"first"},{"_meta":{},"value":"b","name":"B"}]},{"id":"grouped","name":"G","type":"select","currentValue":"x","options":[{"group":"g1","name":"One","options":[{"value":"x","name":"X"}]}]},{"id":"mute","name":"Mute","type":"boolean","currentValue":true},{"id":"mine","type":"_future","payload":[1]}]`,
		`[{"_meta":{"a":1},"configId":"model","name":"Model","category":"model","description":"d","type":"select","currentValue":"a","options":[{"value":"a","name":"A","description":"first"},{"_meta":{},"value":"b","name":"B"}]},{"configId":"grouped","name":"G","type":"select","currentValue":"x","options":[{"groupId":"g1","name":"One","options":[{"value":"x","name":"X"}]}]},{"configId":"mute","name":"Mute","type":"boolean","currentValue":true},{"configId":"mine","type":"_future","payload":[1]}]`,
	}
	for document, index in documents {
		version := index + 1
		value, parse_error := json.parse_string(document, .JSON, true, context.allocator)
		if !testing.expect_value(t, parse_error, nil) { continue }
		defer json.destroy_value(value, context.allocator)
		options, decode_error := config_options_decode(value, context.allocator)
		if !testing.expect_value(t, decode_error, Params_Error.None) { continue }
		defer config_options_destroy(options, context.allocator)
		if !testing.expect_value(t, len(options), 4) { continue }

		select, is_select := options[0].variant.(Config_Select)
		testing.expect(t, is_select)
		testing.expect_value(t, options[0].id, "model")
		testing.expect_value(t, select.current_value, "a")
		choices, is_flat := select.options.([]Config_Value)
		testing.expect(t, is_flat)
		testing.expect_value(t, len(choices), 2)
		grouped, is_grouped := options[1].variant.(Config_Select)
		testing.expect(t, is_grouped)
		groups, has_groups := grouped.options.([]Config_Group)
		testing.expect(t, has_groups)
		testing.expect_value(t, groups[0].id, "g1")
		boolean, is_boolean := options[2].variant.(Config_Boolean)
		testing.expect(t, is_boolean)
		testing.expect(t, boolean.current_value)
		other, is_other := options[3].variant.(Config_Other)
		testing.expect(t, is_other)
		testing.expect_value(t, other.type, "_future")

		encoded, encode_error := config_options_encode(options, version, context.temp_allocator)
		testing.expect_value(t, encode_error, nil)
		sorted := json.Marshal_Options {
			sort_maps_by_key = true,
		}
		want, want_error := json.marshal(value, sorted, context.temp_allocator)
		got, got_error := json.marshal(encoded, sorted, context.temp_allocator)
		testing.expect_value(t, want_error, nil)
		testing.expect_value(t, got_error, nil)
		testing.expect_value(t, string(got), string(want))
	}
}

@(test)
test_config_option_decode_refuses_mismatched_shapes :: proc(t: ^testing.T) {
	documents := [?]string {
		`"select"`,
		`{"id":"a"}`,
		`{"type":"select","currentValue":"a","options":[]}`,
		`{"id":"a","type":"select","options":[]}`,
		`{"id":"a","type":"select","currentValue":"a"}`,
		`{"id":"a","type":"select","currentValue":"a","options":[{"name":"no value"}]}`,
		`{"id":"a","type":"select","currentValue":"a","options":[{"value":"a"},{"group":"g","options":[]}]}`,
		`{"id":"a","type":"boolean","currentValue":"yes"}`,
	}
	for document in documents {
		value, parse_error := json.parse_string(document, .JSON, true, context.allocator)
		if !testing.expect_value(t, parse_error, nil) { continue }
		defer json.destroy_value(value, context.allocator)
		option, decode_error := config_option_decode(value, context.allocator)
		testing.expectf(t, decode_error == .Invalid, "%s was accepted", document)
		config_option_destroy(option, context.allocator)
	}
}

// A set_config_option value is an id, a bool, or a kind this package does not know; version 1 reads an unknown kind with a
// string payload as an id, and each version writes its own request.
@(test)
test_set_config_option_params_decode_and_encode_per_version :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Case :: struct {
		document: string,
		version:  int,
		want:     string,
	}
	cases := [?]Case {
		{`{"sessionId":"s","configId":"c","value":"a"}`, 1, `{"sessionId":"s","configId":"c","value":"a"}`},
		{`{"sessionId":"s","configId":"c","type":"id","value":"a"}`, 2, `{"sessionId":"s","configId":"c","type":"id","value":"a"}`},
		{`{"sessionId":"s","configId":"c","type":"boolean","value":true}`, 2, `{"sessionId":"s","configId":"c","type":"boolean","value":true}`},
		{`{"sessionId":"s","configId":"c","type":"_x","value":{"k":1}}`, 2, `{"sessionId":"s","configId":"c","type":"_x","value":{"k":1}}`},
		{`{"sessionId":"s","configId":"c","type":"_x","value":"a"}`, 1, `{"sessionId":"s","configId":"c","value":"a"}`},
		{`{"sessionId":"s","configId":"c","type":"_x","value":"a"}`, 2, `{"sessionId":"s","configId":"c","type":"_x","value":"a"}`},
	}
	for entry in cases {
		value, parse_error := json.parse_string(entry.document, .JSON, true, context.allocator)
		if !testing.expect_value(t, parse_error, nil) { continue }
		defer json.destroy_value(value, context.allocator)
		params: Session_Set_Config_Option_Params
		testing.expect_value(t, session_set_config_option_params_decode(value, entry.version, &params), Params_Error.None)
		request := session_set_config_option_request(params, entry.version)
		wire, marshal_error := json.marshal(request, {sort_maps_by_key = true}, context.temp_allocator)
		testing.expect_value(t, marshal_error, nil)
		testing.expect_value(t, string(wire), entry.want)
	}
	for document in ([?]string{`{"sessionId":"s","configId":"c"}`, `{"sessionId":"s","configId":"c","value":1}`, `{"sessionId":"s","configId":"c","type":"boolean","value":"x"}`, `{"configId":"c","value":"a"}`}) {
		value, parse_error := json.parse_string(document, .JSON, true, context.allocator)
		if !testing.expect_value(t, parse_error, nil) { continue }
		defer json.destroy_value(value, context.allocator)
		params: Session_Set_Config_Option_Params
		testing.expectf(t, session_set_config_option_params_decode(value, 2, &params) == .Invalid, "%s was accepted", document)
	}
}
