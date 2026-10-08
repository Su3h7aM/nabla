#+test
package agent

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "nabla:agent/journal"
import "nabla:agent/skills"

tool_skills_catalog :: proc(test: ^testing.T, workspace: string) -> skills.Catalog {
	root, root_error := filepath.join({workspace, "skills"}, context.temp_allocator)
	if root_error != nil { testing.fail_now(test, "could not join skills root") }
	testing.expect(test, os.make_directory_all(root) == nil)
	names := []string{"pdf", "git"}
	for name in names {
		directory, directory_error := filepath.join({root, name}, context.temp_allocator)
		if directory_error != nil { testing.fail_now(test, "could not join skill directory") }
		testing.expect(test, os.make_directory_all(directory) == nil)
		primary, primary_error := filepath.join({directory, "SKILL.md"}, context.temp_allocator)
		if primary_error != nil { testing.fail_now(test, "could not join primary") }
		text := fmt.tprintf("---\nname: %s\ndescription: Work with %s\n---\n# %s\n", name, name, name)
		testing.expect(test, os.write_entire_file(primary, text) == nil)
	}
	catalog, load_error := skills.discover([]skills.Root{{source = .Generic_User, logical_path = root}})
	defer skills.load_error_destroy(&load_error, context.allocator)
	if load_error.kind != .None { testing.fail_now(test, "discovery failed") }
	return catalog
}

tool_skills_arguments :: proc(test: ^testing.T, raw: string) -> json.Object {
	value, parse_error := json.parse_string(raw, .JSON, true, context.allocator)
	if parse_error != nil { testing.fail_now(test, "arguments did not parse") }
	object, is_object := value.(json.Object)
	if !is_object { testing.fail_now(test, "arguments are not an object") }
	return object
}

@(test)
test_skills_and_skill_round_trip :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	catalog := tool_skills_catalog(test, tool_test.workspace)
	defer skills.catalog_destroy(&catalog, context.allocator)
	tool_test.fixture.chat.skill_catalog = catalog
	catalog = {}

	chat := &tool_test.fixture.chat

	list_context := Tool_Context {
		call_id   = "call_1",
		workspace = tool_test.workspace,
		allocator = context.allocator,
		skills    = chat_skill_catalog(chat),
	}
	list_arguments := tool_skills_arguments(test, `{}`)
	defer json.destroy_value(list_arguments, context.allocator)
	list_result := tool_test_execute(&list_context, TOOL_SKILLS_DEFINITION, list_arguments)
	defer tool_result_destroy(&list_result)
	testing.expect_value(test, list_result.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, len(list_result.content) > 0)
	testing.expect(test, strings.contains(list_result.content, `total_matches: 2`))
	testing.expect(test, strings.contains(list_result.content, `name: git`))
	testing.expect(test, strings.contains(list_result.content, `Work with pdf`))

	page_context := Tool_Context {
		call_id   = "call_1-page",
		workspace = tool_test.workspace,
		allocator = context.allocator,
		skills    = chat_skill_catalog(chat),
	}
	page_arguments := tool_skills_arguments(test, `{"offset":5}`)
	defer json.destroy_value(page_arguments, context.allocator)
	page_result := tool_test_execute(&page_context, TOOL_SKILLS_DEFINITION, page_arguments)
	defer tool_result_destroy(&page_result)
	testing.expect_value(test, page_result.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(page_result.content, `total_matches: 2`))
	testing.expect(test, tool_result_body(page_result.content) == "")

	unknown_context := Tool_Context {
		call_id   = "call_1-unknown",
		workspace = tool_test.workspace,
		allocator = context.allocator,
		skills    = chat_skill_catalog(chat),
	}
	unknown_arguments := tool_skills_arguments(test, `{"name":"missing"}`)
	defer json.destroy_value(unknown_arguments, context.allocator)
	unknown_result := tool_test_execute(&unknown_context, TOOL_SKILL_DEFINITION, unknown_arguments)
	defer tool_result_destroy(&unknown_result)
	testing.expect_value(test, unknown_result.outcome, journal.Tool_Outcome.Tool_Failed)

	load_context := Tool_Context {
		call_id   = "call_2",
		workspace = tool_test.workspace,
		allocator = context.allocator,
		skills    = chat_skill_catalog(chat),
	}
	load_arguments := tool_skills_arguments(test, `{"name":"pdf"}`)
	defer json.destroy_value(load_arguments, context.allocator)
	load_result := tool_test_execute(&load_context, TOOL_SKILL_DEFINITION, load_arguments)
	defer tool_result_destroy(&load_result)
	testing.expect_value(test, load_result.outcome, journal.Tool_Outcome.Success)
	testing.expect_value(test, tool_result_body(load_result.content), load_result.output.(Skill_Output).instructions)
	testing.expect(test, strings.contains(load_result.content, `# pdf`))
}
