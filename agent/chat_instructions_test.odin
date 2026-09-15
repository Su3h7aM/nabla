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
