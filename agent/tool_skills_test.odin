#+test
package agent

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

import "nabla:agent/session"
import "nabla:agent/skills"

tool_skills_catalog :: proc(t: ^testing.T, workspace: string) -> skills.Catalog {
	root, root_error := filepath.join({workspace, "skills"}, context.temp_allocator)
	if root_error != nil { testing.fail_now(t, "could not join skills root") }
	testing.expect(t, os.make_directory_all(root) == nil)
	names := []string{"pdf", "git"}
	for name in names {
		directory, directory_error := filepath.join({root, name}, context.temp_allocator)
		if directory_error != nil { testing.fail_now(t, "could not join skill directory") }
		testing.expect(t, os.make_directory_all(directory) == nil)
		primary, primary_error := filepath.join({directory, "SKILL.md"}, context.temp_allocator)
		if primary_error != nil { testing.fail_now(t, "could not join primary") }
		text := fmt.tprintf("---\nname: %s\ndescription: Work with %s\n---\n# %s\n", name, name, name)
		testing.expect(t, os.write_entire_file(primary, text) == nil)
	}
	catalog, load_error := skills.discover([]skills.Root{{source = .Generic_User, logical_path = root}})
	defer skills.load_error_destroy(&load_error, context.allocator)
	if load_error.kind != .None { testing.fail_now(t, "discovery failed") }
	return catalog
}

tool_skills_arguments :: proc(t: ^testing.T, raw: string) -> json.Object {
	value, parse_error := json.parse_string(raw, .JSON, true, context.allocator)
	if parse_error != nil { testing.fail_now(t, "arguments did not parse") }
	object, is_object := value.(json.Object)
	if !is_object { testing.fail_now(t, "arguments are not an object") }
	return object
}

@(test)
test_list_and_load_skills_round_trip :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	catalog := tool_skills_catalog(t, test.workspace)
	defer skills.catalog_destroy(&catalog, context.allocator)
	test.fixture.chat.skill_catalog = catalog
	catalog = {}

	chat := &test.fixture.chat
	_ = chat

	list_ctx := Tool_Context {
		call_id   = "call_1",
		workspace = test.workspace,
		allocator = context.allocator,
		skills    = chat_skill_catalog(chat),
	}
	list_arguments := tool_skills_arguments(t, `{"query":"pdf","limit":10}`)
	defer json.destroy_value(list_arguments, context.allocator)
	list_result := tool_list_skills_execute(&list_ctx, list_arguments)
	defer tool_result_destroy(&list_result)
	testing.expect_value(t, list_result.outcome, session.Tool_Outcome.Success)
	testing.expect(t, len(list_result.content) > 0)

	load_ctx := Tool_Context {
		call_id   = "call_2",
		workspace = test.workspace,
		allocator = context.allocator,
		skills    = chat_skill_catalog(chat),
	}
	load_arguments := tool_skills_arguments(t, `{"name":"pdf"}`)
	defer json.destroy_value(load_arguments, context.allocator)
	load_result := tool_load_skill_execute(&load_ctx, load_arguments)
	defer tool_result_destroy(&load_result)
	testing.expect_value(t, load_result.outcome, session.Tool_Outcome.Success)
}
