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

	roots := instruction_roots(workspace, false)
	defer instruction_roots_destroy(roots)
	testing.expect_value(t, len(roots), 3)
	if len(roots) == 3 {
		testing.expect_value(t, roots[0].kind, Instruction_Source_Kind.Local)
		testing.expect_value(t, roots[0].authority, workspace)
		expected_local := filepath.join({workspace, ".agents", "skills"}, context.allocator) or_else ""
		testing.expect_value(t, roots[0].path, expected_local)
		testing.expect_value(t, roots[1].kind, Instruction_Source_Kind.Nabla_User)
		testing.expect_value(t, roots[2].kind, Instruction_Source_Kind.Generic_User)
	}

	disabled := instruction_roots(workspace, true)
	defer instruction_roots_destroy(disabled)
	for root in disabled { testing.expect(t, root.kind != .Local) }

	files := make([dynamic]Agents_File, 0, context.allocator)
	defer delete(files)
	append(&files, Agents_File{path = "/home/user/.agents/AGENTS.md", scope = "personal", body = "Be brief."})
	catalog: skills.Catalog
	rendered := render_instructions(files[:], catalog, true)
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

	body, err := read_agents_file(filepath.join({base, "AGENTS.md"}, context.allocator) or_else "")
	testing.expect_value(t, err, "missing")
	testing.expect_value(t, body, "")

	empty := filepath.join({base, "AGENTS.md"}, context.allocator) or_else ""
	testing.expect(t, os.write_entire_file(empty, "") == nil)
	body, err = read_agents_file(empty)
	testing.expect_value(t, err, "missing")

	testing.expect(t, os.write_entire_file(empty, "\n\n   \n") == nil)
	body, err = read_agents_file(empty)
	testing.expect_value(t, err, "missing")

	testing.expect(t, os.write_entire_file(empty, "Be concise.\n") == nil)
	body, err = read_agents_file(empty)
	testing.expect_value(t, err, "")
	testing.expect_value(t, body, "Be concise.\n")

	testing.expect(t, os.write_entire_file(empty, "broken\x00text") == nil)
	_, err = read_agents_file(empty)
	testing.expect(t, strings.contains(err, empty), err)
}
