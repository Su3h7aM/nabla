#+test
package agent

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent/journal"
import "nabla:ai"

@(test)
test_read_attaches_an_image_and_still_refuses_other_binary_files :: proc(test: ^testing.T) {
	workspace, workspace_error := os.make_directory_temp("", "nabla-attachment-test-*", context.allocator)
	if workspace_error != nil { testing.fail_now(test, "could not create a test workspace") }
	defer delete(workspace, context.allocator)
	defer os.remove_all(workspace)

	png := transmute([]u8)string("\x89PNG\r\n\x1a\nrest of the image")
	if write_error := os.write_entire_file(fmt.tprintf("%s/pixel.png", workspace), png); write_error != nil {
		testing.fail_now(test, "could not write the image")
	}
	if write_error := os.write_entire_file(fmt.tprintf("%s/blob.bin", workspace), transmute([]u8)string("one\x00two\n")); write_error != nil {
		testing.fail_now(test, "could not write the binary file")
	}
	ctx := Tool_Context {
		call_id   = "call",
		workspace = workspace,
		allocator = context.allocator,
	}

	image := tool_read_execute(&ctx, Read_Args{path = "pixel.png"})
	defer tool_result_destroy(&image)
	testing.expect_value(test, image.outcome, journal.Tool_Outcome.Success)
	if !testing.expect_value(test, len(image.attachments), 1) { return }
	testing.expect_value(test, image.attachments[0].Media, ai.Provider_Media.PNG)
	testing.expect_value(test, image.attachments[0].Name, "pixel.png")
	testing.expect_value(test, string(image.attachments[0].Data), string(png))
	testing.expect_value(test, image.content, fmt.tprintf("ok\npath: pixel.png\nmedia_type: image/png\nbytes: %d\n", len(png)))

	binary := tool_read_execute(&ctx, Read_Args{path = "blob.bin"})
	defer tool_result_destroy(&binary)
	testing.expect_value(test, binary.outcome, journal.Tool_Outcome.Tool_Failed)
	testing.expect_value(test, len(binary.attachments), 0)
	testing.expect(test, strings.contains(binary.content, "is not a text file"), "other binary files still fail")
}

@(test)
test_accepted_prompt_with_only_an_image_reaches_the_projection :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat

	bytes := []u8{0x89, 'P', 'N', 'G', 1, 2, 3}
	attachments := []ai.Provider_Attachment{{Media = .PNG, Name = "shot.png", Data = bytes}}
	testing.expect_value(test, chat_session_accept_user(chat, "", attachments = attachments), Chat_Accept.Accepted)

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	projection := _test_projection(test, chat, &arena)
	if !testing.expect_value(test, len(projection.items), 1) { return }
	user, is_user := projection.items[0].payload.(Projected_User)
	if !testing.expect(test, is_user, "the prompt is a user item") { return }
	testing.expect_value(test, user.text, "")
	if !testing.expect_value(test, len(user.attachments), 1) { return }
	testing.expect_value(test, user.attachments[0].Media, ai.Provider_Media.PNG)
	testing.expect_value(test, user.attachments[0].Name, "shot.png")
	testing.expect_value(test, string(user.attachments[0].Data), string(bytes))
}
