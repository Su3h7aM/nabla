#+test
package skills

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

write_skill :: proc(t: ^testing.T, root, name, description, body: string) {
	_ = t
	directory := filepath.join({root, name}, context.temp_allocator) or_else ""
	testing.expect(t, os.make_directory_all(directory) == nil)
	primary := filepath.join({directory, "SKILL.md"}, context.temp_allocator) or_else ""
	text := fmt.tprintf("---\nname: %s\ndescription: %s\n---\n%s", name, description, body)
	testing.expect(t, os.write_entire_file(primary, text) == nil)
}

@(test)
test_discover_selects_highest_priority_winner :: proc(t: ^testing.T) {
	base := fmt.aprintf("/tmp/nabla-skills-%d", os.get_pid(), allocator = context.temp_allocator)
	defer os.remove_all(base)
	generic_root := filepath.join({base, "generic"}, context.temp_allocator) or_else ""
	project_root := filepath.join({base, "project"}, context.temp_allocator) or_else ""
	nabla_root := filepath.join({base, "nabla"}, context.temp_allocator) or_else ""
	testing.expect(t, os.make_directory_all(generic_root) == nil)
	testing.expect(t, os.make_directory_all(project_root) == nil)
	testing.expect(t, os.make_directory_all(nabla_root) == nil)
	write_skill(t, generic_root, "pdf", "generic pdf", "generic")
	write_skill(t, generic_root, "git", "git work", "git")
	write_skill(t, project_root, "pdf", "project pdf", "project")
	write_skill(t, project_root, "review", "review work", "review")
	write_skill(t, nabla_root, "pdf", "nabla pdf", "nabla")
	write_skill(t, nabla_root, "database", "database work", "database")

	roots := []Root {
		{source = .Nabla_User, logical_path = nabla_root},
		{source = .Project, logical_path = project_root, authority = base},
		{source = .Generic_User, logical_path = generic_root},
	}
	catalog, load_error := discover(roots)
	defer catalog_destroy(&catalog)
	defer load_error_destroy(&load_error)
	testing.expect_value(t, load_error.kind, Error_Kind.None)
	testing.expect_value(t, len(catalog.skills), 4)
	pdf, found := find(catalog.skills, "pdf")
	testing.expect(t, found)
	testing.expect_value(t, catalog.skills[pdf].description, "nabla pdf")

}

@(test)
test_discover_rejects_same_root_duplicates :: proc(t: ^testing.T) {
	base := fmt.aprintf("/tmp/nabla-skills-duplicate-%d", os.get_pid(), allocator = context.temp_allocator)
	defer os.remove_all(base)
	root := filepath.join({base, "skills"}, context.temp_allocator) or_else ""
	testing.expect(t, os.make_directory_all(root) == nil)
	write_skill(t, root, "pdf", "first pdf", "first")
	nested := filepath.join({root, "group"}, context.temp_allocator) or_else ""
	write_skill(t, nested, "pdf", "second pdf", "second")

	catalog, load_error := discover([]Root{{source = .Generic_User, logical_path = root}})
	defer catalog_destroy(&catalog)
	defer load_error_destroy(&load_error)
	testing.expect_value(t, load_error.kind, Error_Kind.None)
	testing.expect_value(t, len(catalog.skills), 0)
}
