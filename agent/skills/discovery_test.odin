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

// Priority follows the product order: the launch directory's own skills win,
// then Nabla's configuration, then the generic user directory.
@(test)
test_discover_selects_highest_priority_winner :: proc(t: ^testing.T) {
	base := fmt.aprintf("/tmp/nabla-skills-%d", os.get_pid(), allocator = context.temp_allocator)
	defer os.remove_all(base)
	generic_root := filepath.join({base, "generic"}, context.temp_allocator) or_else ""
	local_root := filepath.join({base, "local"}, context.temp_allocator) or_else ""
	nabla_root := filepath.join({base, "nabla"}, context.temp_allocator) or_else ""
	testing.expect(t, os.make_directory_all(generic_root) == nil)
	testing.expect(t, os.make_directory_all(local_root) == nil)
	testing.expect(t, os.make_directory_all(nabla_root) == nil)
	write_skill(t, generic_root, "pdf", "generic pdf", "generic")
	write_skill(t, generic_root, "git", "git work", "git")
	write_skill(t, local_root, "pdf", "local pdf", "local")
	write_skill(t, local_root, "review", "review work", "review")
	write_skill(t, nabla_root, "pdf", "nabla pdf", "nabla")
	write_skill(t, nabla_root, "database", "database work", "database")

	roots := []Root {
		{source = .Local, logical_path = local_root, authority = base},
		{source = .Nabla_User, logical_path = nabla_root},
		{source = .Generic_User, logical_path = generic_root},
	}
	catalog, load_error := discover(roots)
	defer catalog_destroy(&catalog)
	defer load_error_destroy(&load_error)
	testing.expect_value(t, load_error.kind, Error_Kind.None)
	testing.expect_value(t, len(catalog.skills), 4)
	pdf, found := find(catalog.skills, "pdf")
	testing.expect(t, found)
	testing.expect_value(t, catalog.skills[pdf].description, "local pdf")

}

// A root whose scan fails is discarded whole: its candidates never select, and
// a valid candidate in another root keeps its win. Here the failed root is a
// regular file, which a directory read refuses.
@(test)
test_discover_discards_a_failed_root_without_losing_the_others :: proc(t: ^testing.T) {
	base := fmt.aprintf("/tmp/nabla-skills-failed-%d", os.get_pid(), allocator = context.temp_allocator)
	defer os.remove_all(base)
	good := filepath.join({base, "good"}, context.temp_allocator) or_else ""
	testing.expect(t, os.make_directory_all(good) == nil)
	write_skill(t, good, "pdf", "good pdf", "good")
	blocked := filepath.join({base, "blocked"}, context.temp_allocator) or_else ""
	testing.expect(t, os.write_entire_file(blocked, "not a directory") == nil)

	catalog, load_error := discover([]Root{{source = .Generic_User, logical_path = blocked}, {source = .Nabla_User, logical_path = good}})
	defer catalog_destroy(&catalog)
	defer load_error_destroy(&load_error)
	testing.expect_value(t, load_error.kind, Error_Kind.None)
	testing.expect_value(t, len(catalog.skills), 1)
	if len(catalog.skills) == 1 {
		testing.expect_value(t, catalog.skills[0].name, "pdf")
	}
	unreadable := false
	for diagnostic in catalog.diagnostics {
		if diagnostic.kind == .Unreadable_Root { unreadable = true }
	}
	testing.expect(t, unreadable, "the failed root must carry its diagnostic")
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

// Every index a catalog carries names Catalog.roots, the roots it kept. A rejected root
// therefore shifts nothing: a skill that was found in the last input root still names the
// root it came from. Indexing the input roots instead would name a root the skill does not
// belong to, and loading through it reads a root the skill is not under.
@(test)
test_discover_indexes_the_roots_it_kept :: proc(t: ^testing.T) {
	base := fmt.aprintf("/tmp/nabla-skills-kept-%d", os.get_pid(), allocator = context.temp_allocator)
	defer os.remove_all(base)
	absent_local := filepath.join({base, "absent"}, context.temp_allocator) or_else ""
	generic_root := filepath.join({base, "generic"}, context.temp_allocator) or_else ""
	testing.expect(t, os.make_directory_all(generic_root) == nil)
	write_skill(t, generic_root, "pdf", "generic pdf", "generic")

	catalog, load_error := discover(
		[]Root{{source = .Local, logical_path = absent_local, authority = base}, {source = .Generic_User, logical_path = generic_root}},
	)
	defer catalog_destroy(&catalog)
	defer load_error_destroy(&load_error)
	testing.expect_value(t, load_error.kind, Error_Kind.None)
	testing.expect_value(t, len(catalog.roots), 1)
	if len(catalog.skills) != 1 { testing.fail_now(t, "the skill in the root that exists was not catalogued") }
	skill := catalog.skills[0]
	testing.expect_value(t, skill.root_index, 0)

	// The index is what a load is handed, so it has to name the root the skill is under.
	root := catalog.roots[skill.root_index]
	testing.expect_value(t, root.source, Source_Kind.Generic_User)
	loaded, load_failure := load(skill, root, {})
	defer loaded_destroy(&loaded)
	defer load_error_destroy(&load_failure)
	testing.expect_value(t, load_failure.kind, Error_Kind.None)
	testing.expect_value(t, loaded.body, "generic")
}
