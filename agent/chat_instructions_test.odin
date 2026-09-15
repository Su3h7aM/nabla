#+test
package agent

import "core:testing"

import "nabla:agent/skills"

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
