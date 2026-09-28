package skills

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Diagnostic_Kind :: enum {
	Unknown,
	Unreadable_Root,
	Alias,
	Shadowed,
	Ambiguous,
	Invalid,
	Unsupported,
}

// DIAGNOSTIC_NO_ROOT is the root_index of a diagnostic about a root that never entered the
// catalog. No index in Catalog.roots names that root, and its path is what says which one it
// was; naming index 0 would name a different root.
DIAGNOSTIC_NO_ROOT :: -1

Diagnostic :: struct {
	kind:       Diagnostic_Kind,
	// root_index indexes Catalog.roots, the roots that were entered. A diagnostic
	// about a root that was not carries DIAGNOSTIC_NO_ROOT.
	root_index: int,
	path:       string,
	line:       int,
	field:      string,
	detail:     string,
	winner:     string,
	loser:      string,
}

Catalog :: struct {
	roots:       []Root,
	skills:      []Skill,
	diagnostics: []Diagnostic,
	omitted:     int,
}

Candidate :: struct {
	name:        string,
	description: string,
	root_pos:    int,
	logical:     string,
	canonical:   string,
	digest:      [32]u8,
	valid:       bool,
}

Walk_Frame :: struct {
	path:    string,
	logical: string,
}

// Directory_Id identifies a directory on its file system. Every path that reaches the same
// directory resolves to the same pair, which is what ends a symlink cycle.
Directory_Id :: struct {
	device: u64,
	inode:  u128,
}

// directory_id reports the identity of the directory path resolves to, following symlinks. It
// reports false for a path that is not a directory or cannot be inspected; the walk handles
// that path as it did before. The allocation the stat makes is released before it returns.
@(require_results)
directory_id :: proc(path: string, scratch: mem.Allocator) -> (Directory_Id, bool) {
	info, stat_error := os.stat(path, scratch)
	if stat_error != nil { return {}, false }
	defer os.file_info_delete(info, scratch)
	if info.type != .Directory { return {}, false }
	return Directory_Id{device = info.device, inode = info.inode}, true
}

@(require_results)
discover :: proc(roots: []Root, allocator := context.allocator) -> (catalog: Catalog, load_error: Load_Error) {
	scratch := context.temp_allocator
	resolved, resolved_error := make([dynamic]Root, 0, len(roots), scratch)
	seen, seen_error := make([dynamic]string, 0, len(roots), scratch)
	candidates, candidates_error := make([dynamic]Candidate, 0, 64, scratch)
	if resolved_error != nil || seen_error != nil || candidates_error != nil {
		load_error = discover_failed(&catalog, allocator)
		return
	}

	for root, _ in roots {
		canonical, canonical_error := canonical_root(root, scratch)
		if canonical_error.kind != .None {
			record_diagnostic(&catalog, Diagnostic{.Unreadable_Root, DIAGNOSTIC_NO_ROOT, root.logical_path, 0, "", canonical_error.detail, "", ""}, allocator)
			load_error_destroy(&canonical_error, scratch)
			continue
		}
		defer delete(canonical, scratch)
		duplicate := false
		for existing in seen {
			if existing == canonical {
				duplicate = true
				break
			}
		}
		if duplicate {
			record_diagnostic(&catalog, Diagnostic{.Alias, DIAGNOSTIC_NO_ROOT, canonical, 0, "", "same directory as another source root", "", ""}, allocator)
			continue
		}
		if _, append_error := append(&seen, canonical); append_error != nil {
			load_error = discover_failed(&catalog, allocator)
			return
		}
		if _, append_error := append(&resolved, Root{source = root.source, logical_path = root.logical_path, path = canonical, authority = root.authority});
		   append_error != nil {
			load_error = discover_failed(&catalog, allocator)
			return
		}
	}

	// A root whose scan fails is discarded whole, per the discovery contract:
	// its candidates never reach selection, and a valid candidate in another
	// root keeps its win. The diagnostic the scan recorded says why.
	for root, resolved_index in resolved {
		before := len(candidates)
		if !discover_root(resolved_index, root, &catalog, &candidates, scratch, allocator) {
			for index := len(candidates) - 1; index >= before; index -= 1 {
				release_candidate(&candidates[index], scratch)
				ordered_remove(&candidates, index)
			}
		}
	}
	if !select_candidates(candidates[:], &catalog, scratch, allocator) {
		load_error = discover_failed(&catalog, allocator)
		release_candidates(candidates[:], scratch)
		return
	}
	owned_roots, roots_held := clone_roots(resolved[:], allocator)
	if !roots_held {
		load_error = discover_failed(&catalog, allocator)
		release_candidates(candidates[:], scratch)
		return
	}
	catalog.roots = owned_roots
	return
}

// discover_failed ends a discovery that could not build its catalog: what it recorded so
// far is released, and the reason is that an allocation did not fit.
@(private, require_results)
discover_failed :: proc(catalog: ^Catalog, allocator: mem.Allocator) -> Load_Error {
	catalog_destroy(catalog, allocator)
	return error_make(.Allocation, allocator = allocator)
}

@(require_results)
canonical_root :: proc(root: Root, allocator: mem.Allocator) -> (string, Load_Error) {
	canonical, canonical_error := os.get_absolute_path(root.logical_path, allocator)
	if canonical_error != nil { return "", error_make(.Unreadable, detail = string(os.error_string(canonical_error)), allocator = allocator) }
	if root.source == .Local && !path_within(canonical, root.authority) {
		delete(canonical, allocator)
		return "", error_make(.Outside_Authority, detail = "outside the workspace scope", allocator = allocator)
	}
	return canonical, {}
}

@(require_results)
discover_root :: proc(root_pos: int, root: Root, catalog: ^Catalog, candidates: ^[dynamic]Candidate, scratch, allocator: mem.Allocator) -> bool {
	entries, entries_error := os.read_directory_by_path(root.path, -1, scratch)
	if entries_error != nil {
		if entries_error == os.General_Error.Not_Exist { return true }
		record_diagnostic(catalog, Diagnostic{.Unreadable_Root, root_pos, root.path, 0, "", string(os.error_string(entries_error)), "", ""}, allocator)
		return false
	}
	defer {
		for &entry in entries { os.file_info_delete(entry, scratch) }
		delete(entries, scratch)
	}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.fullpath < b.fullpath })
	stack, stack_error := make([dynamic]Walk_Frame, 0, 16, scratch)
	if stack_error != nil { return false }
	for &entry in entries {
		if entry.name == "." || entry.name == ".." { continue }
		joined, join_error := filepath.join({root.path, entry.name}, scratch)
		if join_error != nil { return false }
		defer delete(joined, scratch)
		path, path_error := strings.clone(joined, scratch)
		if path_error != nil { return false }
		name, name_error := strings.clone(entry.name, scratch)
		if name_error != nil {
			delete(path, scratch)
			return false
		}
		if _, append_error := append(&stack, Walk_Frame{path = path, logical = name}); append_error != nil {
			delete(path, scratch)
			delete(name, scratch)
			return false
		}
	}
	// Every directory is entered once per device and inode, the root included, so a symlink
	// that leads back into a directory the walk already read ends there instead of looping.
	visited := make(map[Directory_Id]bool, scratch)
	if root_id, root_is_directory := directory_id(root.path, scratch); root_is_directory { visited[root_id] = true }
	for len(stack) > 0 {
		frame := stack[len(stack) - 1]
		ordered_remove(&stack, len(stack) - 1)
		defer delete(frame.path, scratch)
		defer delete(frame.logical, scratch)
		if id, is_directory := directory_id(frame.path, scratch); is_directory {
			if id in visited { continue }
			visited[id] = true
		}
		if !walk_directory(root_pos, root, frame, catalog, candidates, &stack, scratch, allocator) { return false }
	}
	return true
}

@(require_results)
walk_directory :: proc(
	root_pos: int,
	root: Root,
	frame: Walk_Frame,
	catalog: ^Catalog,
	candidates: ^[dynamic]Candidate,
	stack: ^[dynamic]Walk_Frame,
	scratch: mem.Allocator,
	allocator: mem.Allocator,
) -> bool {
	primary, primary_error := filepath.join({frame.path, "SKILL.md"}, scratch)
	if primary_error != nil { return false }
	defer delete(primary, scratch)
	if link, link_error := os.lstat(primary, scratch); link_error == nil {
		defer os.file_info_delete(link, scratch)
		if link.type != .Regular {
			record_file_diagnostic(catalog, root_pos, frame.logical, allocator, .Unsupported, "SKILL.md is not a regular file")
			return true
		}
	}
	if info, stat_error := os.stat(primary, scratch); stat_error == nil {
		defer os.file_info_delete(info, scratch)
		if info.type != .Regular {
			record_file_diagnostic(catalog, root_pos, frame.logical, allocator, .Unsupported, "SKILL.md is not a regular file")
			return true
		}
		return read_candidate(root_pos, root, frame, info.fullpath, catalog, candidates, scratch, allocator)
	} else if stat_error != os.General_Error.Not_Exist {
		record_file_diagnostic(catalog, root_pos, frame.logical, allocator, .Invalid, string(os.error_string(stat_error)))
		return true
	}
	entries, entries_error := os.read_directory_by_path(frame.path, -1, scratch)
	if entries_error != nil {
		record_file_diagnostic(catalog, root_pos, frame.logical, allocator, .Invalid, string(os.error_string(entries_error)))
		return true
	}
	defer {
		for &entry in entries { os.file_info_delete(entry, scratch) }
		delete(entries, scratch)
	}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.fullpath < b.fullpath })
	for &entry in entries {
		if entry.name == ".git" || entry.name == ".jj" || entry.name == ".hg" || entry.name == ".svn" || entry.name == "node_modules" { continue }
		joined, join_error := filepath.join({frame.path, entry.name}, scratch)
		if join_error != nil { return false }
		defer delete(joined, scratch)
		logical, logical_error := filepath.join({frame.logical, entry.name}, scratch)
		if logical_error != nil { return false }
		defer delete(logical, scratch)
		path, path_error := strings.clone(joined, scratch)
		if path_error != nil { return false }
		name, name_error := strings.clone(logical, scratch)
		if name_error != nil {
			delete(path, scratch)
			return false
		}
		if _, append_error := append(stack, Walk_Frame{path = path, logical = name}); append_error != nil {
			delete(path, scratch)
			delete(name, scratch)
			return false
		}
	}
	return true
}

// read_candidate records the skill a SKILL.md declares, or the diagnostic that says why it is
// not one. It reports false when the candidate could not be built, which fails the whole root
// scan rather than leaving a skill out of the catalog.
@(require_results)
read_candidate :: proc(
	root_pos: int,
	root: Root,
	frame: Walk_Frame,
	canonical_primary: string,
	catalog: ^Catalog,
	candidates: ^[dynamic]Candidate,
	scratch, allocator: mem.Allocator,
) -> bool {
	basename := filepath.base(frame.logical)
	data, read_error := os.read_entire_file(canonical_primary, scratch)
	if read_error != nil {
		record_file_diagnostic(catalog, root_pos, frame.logical, allocator, .Invalid, string(os.error_string(read_error)))
		return true
	}
	defer delete(data, scratch)
	metadata, metadata_error := parse_metadata(data, basename, scratch)
	defer metadata_destroy(&metadata, scratch)
	defer load_error_destroy(&metadata_error, scratch)
	if metadata_error.kind != .None {
		kind := Diagnostic_Kind.Invalid
		if metadata_error.kind == .Unsupported_Metadata { kind = .Unsupported }
		record_file_diagnostic(catalog, root_pos, frame.logical, allocator, kind, metadata_error.detail)
		return true
	}
	directory, directory_error := filepath.join({root.path, frame.logical}, scratch)
	if directory_error != nil { return false }
	defer delete(directory, scratch)
	logical_primary, logical_error := filepath.join({frame.logical, "SKILL.md"}, scratch)
	if logical_error != nil { return false }
	defer delete(logical_primary, scratch)
	candidate: Candidate
	candidate.root_pos = root_pos
	candidate.digest = metadata.digest
	candidate.valid = true
	clone_error: mem.Allocator_Error
	candidate.name, clone_error = strings.clone(metadata.name, scratch)
	if clone_error != nil { return false }
	candidate.description, clone_error = strings.clone(metadata.description, scratch)
	if clone_error != nil {
		release_candidate(&candidate, scratch)
		return false
	}
	candidate.logical, clone_error = strings.clone(logical_primary, scratch)
	if clone_error != nil {
		release_candidate(&candidate, scratch)
		return false
	}
	candidate.canonical, clone_error = strings.clone(directory, scratch)
	if clone_error != nil {
		release_candidate(&candidate, scratch)
		return false
	}
	if _, append_error := append(candidates, candidate); append_error != nil {
		release_candidate(&candidate, scratch)
		return false
	}
	return true
}

@(require_results)
select_candidates :: proc(candidates: []Candidate, catalog: ^Catalog, scratch, allocator: mem.Allocator) -> bool {
	ordered, ordered_error := slice.clone(candidates, scratch)
	if ordered_error != nil { return false }
	slice.sort_by(ordered, proc(a, b: Candidate) -> bool {
		if a.root_pos != b.root_pos { return a.root_pos < b.root_pos }
		return a.logical < b.logical
	})
	selected, selected_error := make([dynamic]Skill, 0, len(ordered), scratch)
	if selected_error != nil { return false }
	for candidate in ordered {
		duplicate := false
		for other in ordered {
			if other.root_pos == candidate.root_pos && other.name == candidate.name && other.logical != candidate.logical {
				duplicate = true
				break
			}
		}
		if duplicate {
			record_diagnostic(
				catalog,
				Diagnostic{.Ambiguous, candidate.root_pos, candidate.logical, 0, "", "duplicate skill name in one root", "", ""},
				allocator,
			)
			continue
		}
		winner := ""
		for existing in selected {
			if existing.name == candidate.name {
				winner = existing.logical_path
				break
			}
		}
		if winner != "" {
			record_diagnostic(catalog, Diagnostic{.Shadowed, candidate.root_pos, candidate.logical, 0, "", "", winner, candidate.logical}, allocator)
			continue
		}
		_, append_error := append(
			&selected,
			Skill {
				name = candidate.name,
				description = candidate.description,
				logical_path = candidate.logical,
				directory = candidate.canonical,
				root_index = candidate.root_pos,
				metadata_digest = candidate.digest,
			},
		)
		if append_error != nil { return false }
	}
	slice.sort_by(selected[:], proc(a, b: Skill) -> bool { return a.name < b.name })
	owned, owned_error := make([]Skill, len(selected), allocator)
	if owned_error != nil { return false }
	for skill, index in selected {
		copied, copied_ok := skill_clone(skill, allocator)
		if !copied_ok {
			for &built in owned[:index] { skill_destroy(&built, allocator) }
			delete(owned, allocator)
			return false
		}
		owned[index] = copied
	}
	catalog.skills = owned
	return true
}

// skill_clone copies one selected skill into the catalog's allocator. It reports false when a
// field could not be copied, in which case it releases what it copied.
@(require_results)
skill_clone :: proc(skill: Skill, allocator: mem.Allocator) -> (owned: Skill, ok: bool) {
	owned = skill
	clone_error: mem.Allocator_Error
	owned.name, clone_error = strings.clone(skill.name, allocator)
	if clone_error != nil { return {}, false }
	owned.description, clone_error = strings.clone(skill.description, allocator)
	if clone_error != nil {
		skill_destroy(&owned, allocator)
		return {}, false
	}
	owned.logical_path, clone_error = strings.clone(skill.logical_path, allocator)
	if clone_error != nil {
		skill_destroy(&owned, allocator)
		return {}, false
	}
	owned.directory, clone_error = strings.clone(skill.directory, allocator)
	if clone_error != nil {
		skill_destroy(&owned, allocator)
		return {}, false
	}
	return owned, true
}

// root_clone copies one root into the catalog's allocator. It reports false when a field
// could not be copied, in which case it releases what it copied.
@(require_results)
root_clone :: proc(root: Root, allocator: mem.Allocator) -> (owned: Root, ok: bool) {
	owned.source = root.source
	clone_error: mem.Allocator_Error
	owned.logical_path, clone_error = strings.clone(root.logical_path, allocator)
	if clone_error != nil { return {}, false }
	owned.path, clone_error = strings.clone(root.path, allocator)
	if clone_error != nil {
		root_destroy(&owned, allocator)
		return {}, false
	}
	owned.authority, clone_error = strings.clone(root.authority, allocator)
	if clone_error != nil {
		root_destroy(&owned, allocator)
		return {}, false
	}
	return owned, true
}

@(require_results)
clone_roots :: proc(roots: []Root, allocator: mem.Allocator) -> ([]Root, bool) {
	owned, owned_error := make([]Root, len(roots), allocator)
	if owned_error != nil { return nil, false }
	for root, index in roots {
		copied, copied_ok := root_clone(root, allocator)
		if !copied_ok {
			for &built in owned[:index] { root_destroy(&built, allocator) }
			delete(owned, allocator)
			return nil, false
		}
		owned[index] = copied
	}
	return owned, true
}

release_candidate :: proc(candidate: ^Candidate, allocator: mem.Allocator) {
	delete(candidate.name, allocator)
	delete(candidate.description, allocator)
	delete(candidate.logical, allocator)
	delete(candidate.canonical, allocator)
	candidate^ = {}
}

release_candidates :: proc(candidates: []Candidate, allocator: mem.Allocator) {
	for &candidate in candidates {
		release_candidate(&candidate, allocator)
	}
}

record_file_diagnostic :: proc(catalog: ^Catalog, root_pos: int, logical: string, allocator: mem.Allocator, kind: Diagnostic_Kind, detail: string) {
	record_diagnostic(catalog, Diagnostic{kind, root_pos, logical, 0, "", detail, "", ""}, allocator)
}

record_diagnostic :: proc(catalog: ^Catalog, diagnostic: Diagnostic, allocator: mem.Allocator) {
	owned := Diagnostic {
		kind       = diagnostic.kind,
		root_index = diagnostic.root_index,
		line       = diagnostic.line,
	}
	clone_error: mem.Allocator_Error
	owned.path, clone_error = strings.clone(diagnostic.path, allocator)
	if clone_error != nil {
		catalog.omitted += 1
		return
	}
	owned.field, clone_error = strings.clone(diagnostic.field, allocator)
	if clone_error != nil {
		diagnostic_destroy(&owned, allocator)
		catalog.omitted += 1
		return
	}
	owned.detail, clone_error = strings.clone(diagnostic.detail, allocator)
	if clone_error != nil {
		diagnostic_destroy(&owned, allocator)
		catalog.omitted += 1
		return
	}
	owned.winner, clone_error = strings.clone(diagnostic.winner, allocator)
	if clone_error != nil {
		diagnostic_destroy(&owned, allocator)
		catalog.omitted += 1
		return
	}
	owned.loser, clone_error = strings.clone(diagnostic.loser, allocator)
	if clone_error != nil {
		diagnostic_destroy(&owned, allocator)
		catalog.omitted += 1
		return
	}
	grown, grow_error := make([]Diagnostic, len(catalog.diagnostics) + 1, allocator)
	if grow_error != nil {
		diagnostic_destroy(&owned, allocator)
		catalog.omitted += 1
		return
	}
	copy(grown, catalog.diagnostics)
	grown[len(catalog.diagnostics)] = owned
	delete(catalog.diagnostics, allocator)
	catalog.diagnostics = grown
}

diagnostic_destroy :: proc(diagnostic: ^Diagnostic, allocator := context.allocator) {
	if diagnostic == nil { return }
	delete(diagnostic.path, allocator)
	delete(diagnostic.field, allocator)
	delete(diagnostic.detail, allocator)
	delete(diagnostic.winner, allocator)
	delete(diagnostic.loser, allocator)
	diagnostic^ = {}
}

skill_destroy :: proc(skill: ^Skill, allocator := context.allocator) {
	if skill == nil { return }
	delete(skill.name, allocator)
	delete(skill.description, allocator)
	delete(skill.logical_path, allocator)
	delete(skill.directory, allocator)
	skill^ = {}
}

root_destroy :: proc(root: ^Root, allocator := context.allocator) {
	if root == nil { return }
	delete(root.logical_path, allocator)
	delete(root.path, allocator)
	delete(root.authority, allocator)
	root^ = {}
}

catalog_destroy :: proc(catalog: ^Catalog, allocator := context.allocator) {
	if catalog == nil { return }
	for &root in catalog.roots { root_destroy(&root, allocator) }
	delete(catalog.roots, allocator)
	for &skill in catalog.skills { skill_destroy(&skill, allocator) }
	delete(catalog.skills, allocator)
	for &diagnostic in catalog.diagnostics { diagnostic_destroy(&diagnostic, allocator) }
	delete(catalog.diagnostics, allocator)
	catalog^ = {}
}
