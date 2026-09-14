#+test
package agent

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "nabla:agent/skills"

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
	boundary := project_boundary(workspace)
	defer delete(boundary, context.allocator)
	roots := instruction_roots(workspace, boundary, false)
	defer instruction_roots_destroy(roots)
	testing.expect(t, len(roots) >= 2)
	testing.expect_value(t, roots[0].kind, Instruction_Source_Kind.Nabla_User)

	disabled := instruction_roots(workspace, boundary, true)
	defer instruction_roots_destroy(disabled)
	for root in disabled { testing.expect(t, root.kind != .Project) }

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
