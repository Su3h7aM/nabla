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
	// The harness routes by itself, with no user configuration: the rendered
	// instructions name the concrete skill tools and the file-work routing.
	testing.expect(t, strings.contains(rendered, "skills tool"))
	testing.expect(t, strings.contains(rendered, "skill tool"))
	testing.expect(t, strings.contains(rendered, "codemode"))
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

	body, status, detail := read_agents_file(path)
	testing.expect_value(t, status, Agents_File_Status.Missing)
	testing.expect_value(t, detail, "")
	testing.expect_value(t, body, "")
	delete(body, context.allocator)

	testing.expect(t, os.write_entire_file(path, "") == nil)
	body, status, detail = read_agents_file(path)
	testing.expect_value(t, status, Agents_File_Status.Missing)
	testing.expect_value(t, detail, "")
	delete(body, context.allocator)

	testing.expect(t, os.write_entire_file(path, "\n\n   \n") == nil)
	body, status, detail = read_agents_file(path)
	testing.expect_value(t, status, Agents_File_Status.Missing)
	testing.expect_value(t, detail, "")
	delete(body, context.allocator)

	testing.expect(t, os.write_entire_file(path, "Be concise.\n") == nil)
	body, status, detail = read_agents_file(path)
	testing.expect_value(t, status, Agents_File_Status.Present)
	testing.expect_value(t, detail, "")
	testing.expect_value(t, body, "Be concise.\n")
	delete(body, context.allocator)

	testing.expect(t, os.write_entire_file(path, "broken\x00text") == nil)
	body, status, detail = read_agents_file(path)
	defer delete(body, context.allocator)
	testing.expect_value(t, status, Agents_File_Status.Unreadable)
	testing.expect(t, strings.contains(detail, path), detail)
}

// An instruction file larger than any fixed byte limit a reader might impose is read whole.
@(test)
test_read_agents_file_reads_a_large_file_whole :: proc(t: ^testing.T) {
	base, base_error := os.make_directory_temp("", "nabla-agents-large-*", context.allocator)
	if base_error != nil { testing.fail_now(t, "could not create a temporary directory") }
	defer os.remove_all(base)
	defer delete(base, context.allocator)
	path := filepath.join({base, "AGENTS.md"}, context.allocator) or_else ""
	defer delete(path, context.allocator)
	instructions := strings.repeat("a", 512 * 1024, context.temp_allocator)
	testing.expect(t, os.write_entire_file_from_string(path, instructions) == nil)

	body, status, detail := read_agents_file(path)
	defer delete(body, context.allocator)
	testing.expect_value(t, status, Agents_File_Status.Present)
	testing.expect_value(t, detail, "")
	testing.expect_value(t, len(body), 512 * 1024)
}

// A touch inside a subdirectory delivers its instruction file as a trailing
// message exactly once: re-touches without a change repeat nothing, an edit
// redelivers, and a removal is forgotten so a recreation delivers again. The
// workspace root file is never a candidate, and touches outside the workspace
// record nothing.
@(test)
test_touch_record_and_take_roundtrip :: proc(t: ^testing.T) {
	base, base_error := os.make_directory_temp("", "nabla-touch-roundtrip-*", context.allocator)
	if base_error != nil { testing.fail_now(t, "could not create a temporary directory") }
	defer os.remove_all(base)
	defer delete(base, context.allocator)
	workspace, workspace_error := filepath.join({base, "work"}, context.allocator)
	if workspace_error != nil { testing.fail_now(t, "could not join workspace") }
	defer delete(workspace, context.allocator)
	testing.expect(t, os.make_directory_all(workspace) == nil)

	chat := Chat_Session {
		workspace = workspace,
		allocator = context.allocator,
	}
	chat.instruction_touches.allocator = context.allocator
	chat.instruction_touches.paths.allocator = context.allocator
	defer {
		for remaining in chat.instruction_touches.paths { delete(remaining, context.allocator) }
		delete(chat.instruction_touches.paths)
	}
	ctx := Tool_Context {
		workspace    = workspace,
		allocator    = context.allocator,
		instructions = &chat.instruction_touches,
	}
	instructions_record_touch(&ctx, "pkg/a.go")
	testing.expect_value(t, len(chat.instruction_touches.paths), 1)
	taken := instruction_touches_take(&chat.instruction_touches)
	testing.expect_value(t, len(taken), 1)
	testing.expect_value(t, len(chat.instruction_touches.paths), 0)
	for path in taken { delete(path, context.allocator) }
	delete(taken, context.allocator)
}

@(test)
test_dynamic_instructions_deliver_once_and_track_changes :: proc(t: ^testing.T) {
	base, base_error := os.make_directory_temp("", "nabla-dynamic-instructions-*", context.allocator)
	if base_error != nil { testing.fail_now(t, "could not create a temporary directory") }
	defer os.remove_all(base)
	defer delete(base, context.allocator)
	workspace, workspace_error := filepath.join({base, "work"}, context.allocator)
	if workspace_error != nil { testing.fail_now(t, "could not join workspace") }
	defer delete(workspace, context.allocator)
	pkg, pkg_error := filepath.join({workspace, "pkg"}, context.allocator)
	if pkg_error != nil { testing.fail_now(t, "could not join package") }
	defer delete(pkg, context.allocator)
	testing.expect(t, os.make_directory_all(pkg) == nil)
	pkg_file, pkg_file_error := filepath.join({pkg, "AGENTS.md"}, context.allocator)
	if pkg_file_error != nil { testing.fail_now(t, "could not join package file") }
	defer delete(pkg_file, context.allocator)
	root_file, root_file_error := filepath.join({workspace, "AGENTS.md"}, context.allocator)
	if root_file_error != nil { testing.fail_now(t, "could not join root file") }
	defer delete(root_file, context.allocator)
	testing.expect(t, os.write_entire_file_from_string(pkg_file, "Follow the package rules.\n") == nil)
	testing.expect(t, os.write_entire_file_from_string(root_file, "Follow the root rules.\n") == nil)

	chat := Chat_Session {
		workspace = workspace,
		allocator = context.allocator,
	}
	chat.instruction_touches.allocator = context.allocator
	chat.instruction_touches.paths.allocator = context.allocator
	chat.delivered_instructions.allocator = context.allocator
	defer {
		for delivered in chat.delivered_instructions { delete(delivered.path, context.allocator) }
		delete(chat.delivered_instructions)
		taken := instruction_touches_take(&chat.instruction_touches)
		if len(taken) > 0 {
			for path in taken { delete(path, context.allocator) }
			delete(taken, context.allocator)
		}
	}
	ctx := Tool_Context {
		workspace    = workspace,
		allocator    = context.allocator,
		instructions = &chat.instruction_touches,
	}

	instructions_record_touch(&ctx, "pkg/a.go")
	first := chat_consume_dynamic_instructions(&chat, context.allocator)
	defer delete(first, context.allocator)
	testing.expect(t, strings.contains(first, "Follow the package rules."))
	testing.expect(t, strings.contains(first, pkg_file))
	testing.expect(t, !strings.contains(first, "Follow the root rules."))

	second := chat_consume_dynamic_instructions(&chat, context.allocator)
	defer delete(second, context.allocator)
	testing.expect_value(t, second, "")

	instructions_record_touch(&ctx, "pkg/b.go")
	third := chat_consume_dynamic_instructions(&chat, context.allocator)
	defer delete(third, context.allocator)
	testing.expect_value(t, third, "")

	instructions_record_touch(&ctx, "root.go")
	fourth := chat_consume_dynamic_instructions(&chat, context.allocator)
	defer delete(fourth, context.allocator)
	testing.expect_value(t, fourth, "")

	outside := Tool_Context {
		workspace    = workspace,
		allocator    = context.allocator,
		instructions = &chat.instruction_touches,
	}
	instructions_record_touch(&outside, "/etc/hostname")
	fifth := chat_consume_dynamic_instructions(&chat, context.allocator)
	defer delete(fifth, context.allocator)
	testing.expect_value(t, fifth, "")

	testing.expect(t, os.write_entire_file_from_string(pkg_file, "Follow the changed package rules.\n") == nil)
	instructions_record_touch(&ctx, "pkg/c.go")
	sixth := chat_consume_dynamic_instructions(&chat, context.allocator)
	defer delete(sixth, context.allocator)
	testing.expect(t, strings.contains(sixth, "Follow the changed package rules."))

	testing.expect(t, os.remove(pkg_file) == nil)
	instructions_record_touch(&ctx, "pkg/d.go")
	seventh := chat_consume_dynamic_instructions(&chat, context.allocator)
	defer delete(seventh, context.allocator)
	testing.expect_value(t, seventh, "")

	testing.expect(t, os.write_entire_file_from_string(pkg_file, "Follow the recreated package rules.\n") == nil)
	instructions_record_touch(&ctx, "pkg/e.go")
	eighth := chat_consume_dynamic_instructions(&chat, context.allocator)
	defer delete(eighth, context.allocator)
	testing.expect(t, strings.contains(eighth, "Follow the recreated package rules."))
}
