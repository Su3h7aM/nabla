#+test
package agent

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "nabla:agent/skills"

// Roots come back in priority order, highest first, and the local root is
// scoped to the workspace itself: discovery never looks above the launch
// directory, whatever the directory happens to be.
@(test)
test_instruction_roots_order_and_rendering :: proc(t: ^testing.T) {
	base, base_error := os.make_directory_temp("", "nabla-instructions-*", context.allocator)
	if base_error != nil { testing.fail_now(t, "could not create a temporary directory") }
	defer os.remove_all(base)
	defer delete(base, context.allocator)
	workspace, workspace_error := filepath.join({base, "work"}, context.allocator)
	if workspace_error != nil { testing.fail_now(t, "could not join workspace") }
	defer delete(workspace, context.allocator)
	testing.expect(t, os.make_directory_all(workspace) == nil)

	roots, roots_error := instruction_roots(workspace, false)
	if roots_error != nil { testing.fail_now(t, "instruction roots could not be allocated") }
	defer instruction_roots_destroy(roots)
	testing.expect_value(t, len(roots), 3)
	if len(roots) == 3 {
		testing.expect_value(t, roots[0].kind, Instruction_Source_Kind.Local)
		testing.expect_value(t, roots[0].authority, workspace)
		expected_local := filepath.join({workspace, ".agents", "skills"}, context.allocator) or_else ""
		defer delete(expected_local, context.allocator)
		testing.expect_value(t, roots[0].path, expected_local)
		testing.expect_value(t, roots[1].kind, Instruction_Source_Kind.Nabla_User)
		testing.expect_value(t, roots[2].kind, Instruction_Source_Kind.Generic_User)
	}

	disabled, disabled_error := instruction_roots(workspace, true)
	if disabled_error != nil { testing.fail_now(t, "disabled instruction roots could not be allocated") }
	defer instruction_roots_destroy(disabled)
	for root in disabled { testing.expect(t, root.kind != .Local) }

	files := make([dynamic]Agents_File, 0, context.allocator)
	defer delete(files)
	append(&files, Agents_File{path = "/home/user/.agents/AGENTS.md", scope = "personal", body = "Be brief."})
	catalog: skills.Catalog
	rendered, rendered_error := render_instructions(files[:], catalog, "", true)
	if rendered_error != nil { testing.fail_now(t, "instructions could not be rendered") }
	defer delete(rendered, context.allocator)
	testing.expect(t, len(rendered) > len(AGENT_SYSTEM_PROMPT))
	testing.expect(t, strings.contains(rendered, "Be brief."))
	testing.expect(t, strings.contains(rendered, "No skills are available."))
}

// An absent, empty, or whitespace-only AGENTS.md carries no instructions and is
// equivalent to a missing file; every real failure names the file.
@(test)
test_read_agents_file_treats_empty_as_missing :: proc(t: ^testing.T) {
	base, base_error := os.make_directory_temp("", "nabla-agents-read-*", context.allocator)
	if base_error != nil { testing.fail_now(t, "could not create a temporary directory") }
	defer os.remove_all(base)
	defer delete(base, context.allocator)

	// The joined path is owned by the test, and every successful read is
	// owned too: each is deleted before the next read reuses the variable.
	path := filepath.join({base, "AGENTS.md"}, context.allocator) or_else ""
	defer delete(path, context.allocator)

	body, err, err_kind := read_agents_file(path)
	testing.expect_value(t, err_kind, Instruction_Error.None)
	testing.expect_value(t, err, "missing")
	testing.expect_value(t, body, "")
	delete(body, context.allocator)

	testing.expect(t, os.write_entire_file(path, "") == nil)
	body, err, err_kind = read_agents_file(path)
	testing.expect_value(t, err, "missing")
	delete(body, context.allocator)

	testing.expect(t, os.write_entire_file(path, "\n\n   \n") == nil)
	body, err, err_kind = read_agents_file(path)
	testing.expect_value(t, err, "missing")
	delete(body, context.allocator)

	testing.expect(t, os.write_entire_file(path, "Be concise.\n") == nil)
	body, err, err_kind = read_agents_file(path)
	testing.expect_value(t, err, "")
	testing.expect_value(t, body, "Be concise.\n")
	delete(body, context.allocator)

	testing.expect(t, os.write_entire_file(path, "broken\x00text") == nil)
	body, err, err_kind = read_agents_file(path)
	defer delete(body, context.allocator)
	testing.expect(t, strings.contains(err, path), err)
}
