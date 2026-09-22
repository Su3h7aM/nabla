#+test
#+private file
package main

import "core:testing"

import "nabla:acp"
import "nabla:agent"

// acp_prompt_text renders what a client sent as the one message the harness records. A
// bug here loses the user's words or refuses content the agent announced support for, so
// the cases are the content kinds the initialize answer claims.
@(test)
test_prompt_text_renders_blocks_and_refuses_unsupported_content :: proc(t: ^testing.T) {
	blocks := []acp.Content_Block {
		{type = acp.CONTENT_TEXT, text = "explain this"},
		{type = acp.CONTENT_RESOURCE_LINK, uri = "file:///tmp/example.odin"},
		{type = acp.CONTENT_RESOURCE, resource = {uri = "file:///tmp/inlined.txt", text = "inlined text"}},
		{type = acp.CONTENT_TEXT, text = "and this"},
	}
	text, reason, ok := acp_prompt_text(blocks, context.temp_allocator)
	testing.expectf(t, ok, "the prompt was refused: %s", reason)
	testing.expect_value(t, text, "explain this\n\n/tmp/example.odin\n\ninlined text\n\nand this")

	// Content the agent does not accept is refused rather than dropped: a client must be
	// told that part of what it sent never reached the model.
	unsupported := []acp.Content_Block{{type = acp.CONTENT_IMAGE}}
	_, image_reason, image_ok := acp_prompt_text(unsupported, context.temp_allocator)
	testing.expect(t, !image_ok)
	testing.expect(t, image_reason != "")

	empty, _, empty_ok := acp_prompt_text(nil, context.temp_allocator)
	testing.expect(t, empty_ok)
	testing.expect_value(t, empty, "")
}

// acp_tool_title and acp_tool_kind are what a client shows for a call: the tool and the
// file or command it concerns, and what kind of work it is. Both read the harness's own
// names and hints, so the cases are the tools this harness ships.
@(test)
test_tool_presentation_uses_the_tools_own_names_and_hints :: proc(t: ^testing.T) {
	// An empty session has an empty registry, which is the case for a call replayed
	// before the tool inventory is rebuilt.
	chat: agent.Chat_Session
	testing.expect_value(t, acp_tool_kind(&chat, agent.TOOL_READ_NAME), acp.Tool_Kind.Read)
	testing.expect_value(t, acp_tool_kind(&chat, agent.TOOL_WRITE_NAME), acp.Tool_Kind.Edit)
	testing.expect_value(t, acp_tool_kind(&chat, agent.TOOL_EDIT_NAME), acp.Tool_Kind.Edit)
	testing.expect_value(t, acp_tool_kind(&chat, agent.TOOL_SHELL_NAME), acp.Tool_Kind.Execute)
	testing.expect_value(t, acp_tool_kind(&chat, agent.TOOL_CODE_NAME), acp.Tool_Kind.Execute)
	testing.expect_value(t, acp_tool_kind(&chat, "some_mcp_tool"), acp.Tool_Kind.Other)

	testing.expect_value(t, acp_tool_title(agent.TOOL_READ_NAME, `{"path":"/tmp/example.odin"}`), "builtin_read /tmp/example.odin")
	testing.expect_value(t, acp_tool_title(agent.TOOL_SHELL_NAME, `{"command":"ls -la"}`), "builtin_shell ls -la")
	// Arguments that are not an object, or that name no file or command, leave the tool
	// name as the title rather than inventing one.
	testing.expect_value(t, acp_tool_title(agent.TOOL_READ_NAME, `{}`), "builtin_read")
	testing.expect_value(t, acp_tool_title(agent.TOOL_READ_NAME, `not json`), "builtin_read")
}
