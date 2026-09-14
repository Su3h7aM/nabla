#+test
package skills

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
test_load_returns_complete_body_and_rejects_stale_metadata :: proc(t: ^testing.T) {
	root_path := fmt.aprintf("/tmp/nabla-skill-load-%d", os.get_pid(), allocator = context.temp_allocator)
	skill_path := filepath.join({root_path, "pdf"}, context.temp_allocator) or_else ""
	primary_path := filepath.join({skill_path, "SKILL.md"}, context.temp_allocator) or_else ""
	defer os.remove_all(root_path)
	testing.expect(t, os.make_directory(root_path) == nil)
	testing.expect(t, os.make_directory(skill_path) == nil)
	file_text := "---\nname: pdf\ndescription: Work with PDFs\n---\n\n# PDF\n\nRead references/forms.md.\n"
	testing.expect(t, os.write_entire_file(primary_path, file_text) == nil)
	metadata, metadata_error := parse_metadata(transmute([]u8)file_text, "pdf")
	defer metadata_destroy(&metadata)
	defer load_error_destroy(&metadata_error)
	testing.expect_value(t, metadata_error.kind, Error_Kind.None)

	skill := Skill {
		name            = "pdf",
		description     = metadata.description,
		logical_path    = primary_path,
		directory       = skill_path,
		root_index      = 0,
		metadata_digest = metadata.digest,
	}
	root := Root {
		source = .Generic_User,
		path   = root_path,
	}
	loaded, load_error := load(skill, root, {})
	defer loaded_destroy(&loaded)
	defer load_error_destroy(&load_error)
	testing.expect_value(t, load_error.kind, Error_Kind.None)
	testing.expect_value(t, loaded.body, "\n# PDF\n\nRead references/forms.md.\n")

	changed := "---\nname: pdf\ndescription: Changed\n---\nbody\n"
	testing.expect(t, os.write_entire_file(primary_path, changed) == nil)
	stale, stale_error := load(skill, root, {})
	defer loaded_destroy(&stale)
	defer load_error_destroy(&stale_error)
	testing.expect_value(t, stale_error.kind, Error_Kind.Stale_Metadata)
}

@(test)
test_load_rejects_invalid_or_empty_body :: proc(t: ^testing.T) {
	root_path := fmt.aprintf("/tmp/nabla-skill-empty-%d", os.get_pid(), allocator = context.temp_allocator)
	skill_path := filepath.join({root_path, "empty"}, context.temp_allocator) or_else ""
	primary_path := filepath.join({skill_path, "SKILL.md"}, context.temp_allocator) or_else ""
	defer os.remove_all(root_path)
	testing.expect(t, os.make_directory(root_path) == nil)
	testing.expect(t, os.make_directory(skill_path) == nil)
	file_text := "---\nname: empty\ndescription: Empty body\n---\n \t\n"
	testing.expect(t, os.write_entire_file(primary_path, file_text) == nil)
	metadata, metadata_error := parse_metadata(transmute([]u8)file_text, "empty")
	defer metadata_destroy(&metadata)
	defer load_error_destroy(&metadata_error)
	skill := Skill {
		name            = "empty",
		logical_path    = primary_path,
		directory       = skill_path,
		root_index      = 0,
		metadata_digest = metadata.digest,
	}
	loaded, load_error := load(skill, Root{source = .Generic_User}, {})
	defer loaded_destroy(&loaded)
	defer load_error_destroy(&load_error)
	testing.expect_value(t, load_error.kind, Error_Kind.Invalid_Text)
}

@(test)
test_find_uses_sorted_catalog :: proc(t: ^testing.T) {
	skills := []Skill{{name = "database"}, {name = "git"}, {name = "pdf"}}
	index, ok := find(skills, "git")
	testing.expect(t, ok)
	testing.expect_value(t, index, 1)
	index, ok = find(skills, "missing")
	testing.expect(t, !ok)
	testing.expect_value(t, index, 2)
}
