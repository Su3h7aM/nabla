#+test
package agent

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "nabla:agent/skills"

@(test)
test_client_system_prompt_is_kept_out_of_history_and_rendered_as_instructions :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, "/tmp")
	defer chat_test_end(t, &fixture)
	if !testing.expect(t, chat_session_set_client_instructions(&fixture.chat, "client standing context")) { return }
	testing.expect_value(t, fixture.chat.client_instructions, "client standing context")
	if !testing.expect(t, chat_ensure_instructions(&fixture.chat)) { return }
	testing.expect(t, strings.contains(fixture.chat.skill_instructions, "client standing context"))
}

// A snapshot written by an older build must still apply: resume reads it
// instead of rediscovering, so an unreadable snapshot would strand the session.
@(test)
test_a_v1_instruction_snapshot_still_applies :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, "/tmp")
	defer chat_test_end(t, &fixture)

	// Version 1 carried a repository boundary field and "project" root kinds;
	// both are inert for the applied catalog.
	manifest :=
		`{"version":1,"workspace":"/tmp","boundary":"/tmp","disable_project":false,` +
		`"tools_enabled":true,"metadata_format":1,"instruction_bytes":13,` +
		`"roots":[{"kind":"project","path":"/tmp/.agents/skills","authority":"/tmp"}],` +
		`"agents":[],"skills":[{"name":"pdf","description":"pdf work",` +
		`"logical_path":"/tmp/.agents/skills/pdf/SKILL.md","directory":"/tmp/.agents/skills/pdf",` +
		`"root_index":0,"metadata_digest":"0000000000000000000000000000000000000000000000000000000000000000"}],` +
		`"diagnostics":[],"omitted_diagnostics":0,"inline_catalog_truncated":false}`
	if !testing.expect(t, chat_apply_snapshot(&fixture.chat, "instructions!", manifest)) {
		return
	}
	testing.expect_value(t, fixture.chat.skill_instructions, "instructions!")
	catalog, has_catalog := &fixture.chat.skill_catalog.?
	if !testing.expect(t, has_catalog) { return }
	testing.expect_value(t, len(catalog.skills), 1)
	if len(catalog.skills) == 1 {
		testing.expect_value(t, catalog.skills[0].name, "pdf")
		testing.expect_value(t, catalog.roots[0].source, skills.Source_Kind.Local)
	}
}

// A corrupt snapshot applies nothing: the session keeps no catalog, and the
// entries cloned before the corrupt one are released rather than stranded.
@(test)
test_a_corrupt_instruction_snapshot_applies_nothing :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, "/tmp")
	defer chat_test_end(t, &fixture)

	manifest :=
		`{"version":2,"workspace":"/tmp","disable_project":false,` +
		`"tools_enabled":true,"metadata_format":1,"instruction_bytes":13,` +
		`"roots":[{"kind":"local","path":"/tmp/.agents/skills","authority":"/tmp"}],` +
		`"agents":[],"skills":[{"name":"pdf","description":"pdf work",` +
		`"logical_path":"/tmp/.agents/skills/pdf/SKILL.md","directory":"/tmp/.agents/skills/pdf",` +
		`"root_index":0,"metadata_digest":"0000000000000000000000000000000000000000000000000000000000000000"},` +
		`{"name":"bad name","description":"never installed",` +
		`"logical_path":"/tmp/.agents/skills/bad/SKILL.md","directory":"/tmp/.agents/skills/bad",` +
		`"root_index":0,"metadata_digest":"0000000000000000000000000000000000000000000000000000000000000000"}],` +
		`"diagnostics":[],"omitted_diagnostics":0,"inline_catalog_truncated":false}`
	testing.expect(t, !chat_apply_snapshot(&fixture.chat, "instructions!", manifest))
	_, has_catalog := &fixture.chat.skill_catalog.?
	testing.expect(t, !has_catalog, "a corrupt snapshot installs no catalog")
}

// A snapshot never replaces an installed catalog: the second apply is refused
// before allocating, so the first catalog stays intact.
@(test)
test_an_instruction_snapshot_never_replaces_a_catalog :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, "/tmp")
	defer chat_test_end(t, &fixture)

	manifest :=
		`{"version":2,"workspace":"/tmp","disable_project":false,` +
		`"tools_enabled":true,"metadata_format":1,"instruction_bytes":13,` +
		`"roots":[{"kind":"local","path":"/tmp/.agents/skills","authority":"/tmp"}],` +
		`"agents":[],"skills":[],"diagnostics":[],` +
		`"omitted_diagnostics":0,"inline_catalog_truncated":false}`
	if !testing.expect(t, chat_apply_snapshot(&fixture.chat, "instructions!", manifest)) { return }
	testing.expect(t, !chat_apply_snapshot(&fixture.chat, "instructions!", manifest))
	testing.expect_value(t, fixture.chat.skill_instructions, "instructions!")
}

// A snapshot the harness wrote is applied to the catalog it describes. The roots it records
// are the catalog's own, because a skill's root_index is an index into that list: a resume
// that paired a skill with a root discovery had discarded refused the skill as outside its
// root, which is exactly how every global skill looked on a resumed session.
@(test)
test_a_written_snapshot_restores_the_root_each_skill_came_from :: proc(t: ^testing.T) {
	workspace, workspace_error := os.make_directory_temp("", "nabla-snapshot-workspace-*", context.allocator)
	if workspace_error != nil { testing.fail_now(t, "the workspace could not be created") }
	defer {
		os.remove_all(workspace)
		delete(workspace, context.allocator)
	}
	// The workspace has no skills of its own and the skill lives outside it, which is the
	// shape that leaves the catalog with fewer roots than the launch configured.
	global, global_error := os.make_directory_temp("", "nabla-snapshot-global-*", context.allocator)
	if global_error != nil { testing.fail_now(t, "the user root could not be created") }
	defer {
		os.remove_all(global)
		delete(global, context.allocator)
	}
	chat_instructions_test_skill(t, global, "pdf")

	absent, absent_error := filepath.join({workspace, ".agents", "skills"}, context.allocator)
	if absent_error != nil { testing.fail_now(t, "the local root path could not be built") }
	defer delete(absent, context.allocator)
	catalog, discover_error := skills.discover(
		[]skills.Root{{source = .Local, logical_path = absent, authority = workspace}, {source = .Generic_User, logical_path = global}},
		context.allocator,
	)
	defer skills.catalog_destroy(&catalog, context.allocator)
	defer skills.load_error_destroy(&discover_error, context.allocator)
	if discover_error.kind != .None { testing.fail_now(t, "discovery failed") }
	if len(catalog.skills) != 1 { testing.fail_now(t, "the user skill was not catalogued") }

	writer: Chat_Test
	chat_test_begin(t, &writer, workspace)
	defer chat_test_end(t, &writer)
	rendered := "instructions!"
	manifest, manifest_error := chat_encode_manifest(&writer.chat, nil, catalog, rendered, context.allocator)
	if manifest_error != .None { testing.fail_now(t, "the manifest could not be encoded") }
	defer delete(manifest, context.allocator)
	if len(manifest) == 0 { testing.fail_now(t, "the manifest could not be encoded") }

	reader: Chat_Test
	chat_test_begin(t, &reader, workspace)
	defer chat_test_end(t, &reader)
	if !testing.expect(t, chat_apply_snapshot(&reader.chat, rendered, manifest)) { return }
	restored, has_catalog := &reader.chat.skill_catalog.?
	if !testing.expect(t, has_catalog, "the snapshot installed no catalog") { return }
	if len(restored.skills) != 1 { testing.fail_now(t, "the restored catalog lost the skill") }

	// The restored catalog has to hand a load the same root the skill was found under, or
	// the skill is unreachable for the rest of the session.
	skill := restored.skills[0]
	root := restored.roots[skill.root_index]
	testing.expect_value(t, root.source, skills.Source_Kind.Generic_User)
	loaded, load_error := skills.load(skill, root, {}, context.allocator)
	defer skills.loaded_destroy(&loaded, context.allocator)
	defer skills.load_error_destroy(&load_error, context.allocator)
	testing.expect_value(t, load_error.kind, skills.Error_Kind.None)
	testing.expect(t, len(loaded.body) > 0, "the restored skill has no body")
}

// A snapshot written before the manifest recorded the catalog's own roots names the launch's
// configured roots, so its skills can point at a root that does not hold them. Applying it
// has to place each skill on the root it is in: the pairing decides whether a local skill may
// be read, and which origin the model is told it came from.
@(test)
test_a_snapshot_the_old_writer_recorded_is_repaired :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, "/tmp")
	defer chat_test_end(t, &fixture)

	manifest :=
		`{"version":2,"workspace":"/tmp","disable_project":false,` +
		`"tools_enabled":true,"metadata_format":1,"instruction_bytes":13,` +
		`"roots":[{"kind":"local","path":"/tmp/.agents/skills","authority":"/tmp"},` +
		`{"kind":"generic_user","path":"/tmp/home/.agents/skills","authority":""}],` +
		`"agents":[],"skills":[{"name":"unslop","description":"cut the tells",` +
		`"logical_path":"/tmp/home/.agents/skills/unslop/SKILL.md",` +
		`"directory":"/tmp/home/.agents/skills/unslop",` +
		`"root_index":0,"metadata_digest":"0000000000000000000000000000000000000000000000000000000000000000"}],` +
		`"diagnostics":[],"omitted_diagnostics":0,"inline_catalog_truncated":false}`
	if !testing.expect(t, chat_apply_snapshot(&fixture.chat, "instructions!", manifest)) { return }
	catalog, has_catalog := &fixture.chat.skill_catalog.?
	if !testing.expect(t, has_catalog, "the snapshot installed no catalog") { return }
	if len(catalog.skills) != 1 { testing.fail_now(t, "the restored catalog lost the skill") }

	skill := catalog.skills[0]
	if !testing.expect(t, skill.root_index == 1, "the skill kept a root that does not hold it") { return }
	testing.expect_value(t, skill_source_label(catalog, skill), "generic user")
}

// chat_instructions_test_skill installs one valid skill in a root, so a test can discover
// a catalog that holds it.
chat_instructions_test_skill :: proc(t: ^testing.T, root, name: string) {
	directory := filepath.join({root, name}, context.temp_allocator) or_else ""
	if !testing.expect(t, os.make_directory_all(directory) == nil) { return }
	primary := filepath.join({directory, "SKILL.md"}, context.temp_allocator) or_else ""
	text := fmt.tprintf("---\nname: %s\ndescription: work with %s\n---\nbody\n", name, name)
	if !testing.expect(t, os.write_entire_file_from_string(primary, text) == nil) { return }
}
