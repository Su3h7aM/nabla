package skills

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

SKILL_MAX_DEPTH :: 32
SKILL_MAX_DIRECTORIES :: 16384
SKILL_MAX_CATALOG_ENTRIES :: 4096
SKILL_MAX_DIAGNOSTICS :: 4096

Diagnostic_Kind :: enum {
	Unknown,
	Unreadable_Root,
	Traversal_Limit,
	Alias,
	Shadowed,
	Ambiguous,
	Invalid,
	Unsupported,
}

Diagnostic :: struct {
	kind:       Diagnostic_Kind,
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
	depth:   int,
}

discover :: proc(roots: []Root, allocator := context.allocator) -> (catalog: Catalog, load_error: Load_Error) {
	scratch := context.temp_allocator
	resolved := make([dynamic]Root, 0, len(roots), scratch)
	seen := make([dynamic]string, 0, len(roots), scratch)
	candidates := make([dynamic]Candidate, 0, 64, scratch)
	if len(roots) > 0 && (resolved == nil || seen == nil) || candidates == nil {
		catalog_destroy(&catalog, allocator)
		load_error = error_make(.Allocation, allocator = allocator)
		return
	}

	for root, index in roots {
		canonical, canonical_error := canonical_root(root, scratch)
		if canonical_error.kind != .None {
			record_diagnostic(&catalog, Diagnostic{.Unreadable_Root, index, root.logical_path, 0, "", canonical_error.detail, "", ""}, scratch, allocator)
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
			record_diagnostic(&catalog, Diagnostic{.Alias, index, canonical, 0, "", "same directory as another source root", "", ""}, scratch, allocator)
			continue
		}
		append(&seen, canonical)
		append(&resolved, Root{source = root.source, logical_path = root.logical_path, path = canonical, authority = root.authority})
	}

	failed_root := false
	for root, resolved_index in resolved {
		ok := discover_root(roots, resolved_index, root, &catalog, &candidates, scratch, allocator)
		if !ok { failed_root = true }
	}
	if failed_root {
		release_candidates(candidates[:], scratch)
		catalog_destroy(&catalog, allocator)
		load_error = error_make(.Unreadable, detail = "incomplete root scan produced no catalog", allocator = allocator)
		return
	}
	if !select_candidates(candidates[:], &catalog, scratch, allocator) {
		release_candidates(candidates[:], scratch)
		catalog_destroy(&catalog, allocator)
		load_error = error_make(.Allocation, allocator = allocator)
		return
	}
	catalog.roots = clone_roots(resolved[:], allocator)
	return
}

canonical_root :: proc(root: Root, allocator: mem.Allocator) -> (string, Load_Error) {
	canonical, canonical_error := os.get_absolute_path(root.logical_path, allocator)
	if canonical_error != nil { return "", error_make(.Unreadable, detail = string(os.error_string(canonical_error)), allocator = allocator) }
	if root.source == .Project && !path_within(canonical, root.authority) {
		delete(canonical, allocator)
		return "", error_make(.Outside_Authority, detail = "outside the project boundary", allocator = allocator)
	}
	return canonical, {}
}

discover_root :: proc(
	all_roots: []Root,
	root_pos: int,
	root: Root,
	catalog: ^Catalog,
	candidates: ^[dynamic]Candidate,
	scratch, allocator: mem.Allocator,
) -> bool {
	_ = all_roots
	entries, entries_error := os.read_directory_by_path(root.path, -1, scratch)
	if entries_error != nil {
		if entries_error == os.General_Error.Not_Exist { return true }
		record_diagnostic(
			catalog,
			Diagnostic{.Unreadable_Root, root_pos, root.path, 0, "", string(os.error_string(entries_error)), "", ""},
			scratch,
			allocator,
		)
		return false
	}
	defer {
		for &entry in entries { os.file_info_delete(entry, scratch) }
		delete(entries, scratch)
	}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.fullpath < b.fullpath })
	stack := make([dynamic]Walk_Frame, 0, 16, scratch)
	for &entry in entries {
		if entry.name == "." || entry.name == ".." { continue }
		joined, join_error := filepath.join({root.path, entry.name}, scratch)
		if join_error != nil { return false }
		defer delete(joined, scratch)
		path := strings.clone(joined, scratch)
		name := strings.clone(entry.name, scratch)
		append(&stack, Walk_Frame{path = path, logical = name})
	}
	visited := make(map[string]bool, context.temp_allocator)
	count := 0
	for len(stack) > 0 {
		frame := stack[len(stack) - 1]
		ordered_remove(&stack, len(stack) - 1)
		defer delete(frame.path, scratch)
		defer delete(frame.logical, scratch)
		count += 1
		if frame.path in visited {
			record_diagnostic(catalog, Diagnostic{.Traversal_Limit, root_pos, frame.logical, 0, "", "directory cycle detected", "", ""}, scratch, allocator)
			return false
		}
		visited[frame.path] = true
		if count > SKILL_MAX_DIRECTORIES {
			record_diagnostic(
				catalog,
				Diagnostic{.Traversal_Limit, root_pos, root.path, 0, "", "visited directory budget exhausted", "", ""},
				scratch,
				allocator,
			)
			return false
		}
		if !walk_directory(root_pos, root, frame, catalog, candidates, &stack, scratch, allocator) { return false }
	}
	return true
}

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
	if frame.depth > SKILL_MAX_DEPTH {
		record_diagnostic(
			catalog,
			Diagnostic{.Traversal_Limit, root_pos, frame.logical, 0, "", "directory depth budget exhausted", "", ""},
			scratch,
			allocator,
		)
		return true
	}
	primary, primary_error := filepath.join({frame.path, "SKILL.md"}, scratch)
	if primary_error != nil { return false }
	defer delete(primary, scratch)
	if link, link_error := os.lstat(primary, scratch); link_error == nil {
		defer os.file_info_delete(link, scratch)
		if link.type != .Regular {
			record_file_diagnostic(catalog, root_pos, frame.logical, scratch, allocator, .Unsupported, "SKILL.md is not a regular file")
			return true
		}
	}
	if info, stat_error := os.stat(primary, scratch); stat_error == nil {
		defer os.file_info_delete(info, scratch)
		if info.type != .Regular {
			record_file_diagnostic(catalog, root_pos, frame.logical, scratch, allocator, .Unsupported, "SKILL.md is not a regular file")
			return true
		}
		read_candidate(root_pos, root, frame, info.fullpath, catalog, candidates, scratch, allocator)
		return true
	} else if stat_error != os.General_Error.Not_Exist {
		record_file_diagnostic(catalog, root_pos, frame.logical, scratch, allocator, .Invalid, string(os.error_string(stat_error)))
		return true
	}
	entries, entries_error := os.read_directory_by_path(frame.path, -1, scratch)
	if entries_error != nil {
		record_file_diagnostic(catalog, root_pos, frame.logical, scratch, allocator, .Invalid, string(os.error_string(entries_error)))
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
		path := strings.clone(joined, scratch)
		name := strings.clone(logical, scratch)
		append(stack, Walk_Frame{path = path, logical = name, depth = frame.depth + 1})
	}
	return true
}

read_candidate :: proc(
	root_pos: int,
	root: Root,
	frame: Walk_Frame,
	canonical_primary: string,
	catalog: ^Catalog,
	candidates: ^[dynamic]Candidate,
	scratch, allocator: mem.Allocator,
) {
	basename := filepath.base(frame.logical)
	info, info_error := os.stat(canonical_primary, scratch)
	if info_error != nil {
		record_file_diagnostic(catalog, root_pos, frame.logical, scratch, allocator, .Invalid, string(os.error_string(info_error)))
		return
	}
	defer os.file_info_delete(info, scratch)
	if info.size > SKILL_MAX_FILE_BYTES {
		record_file_diagnostic(catalog, root_pos, frame.logical, scratch, allocator, .Invalid, "SKILL.md exceeds the byte limit")
		return
	}
	data, read_error := os.read_entire_file(canonical_primary, scratch)
	if read_error != nil {
		record_file_diagnostic(catalog, root_pos, frame.logical, scratch, allocator, .Invalid, string(os.error_string(read_error)))
		return
	}
	defer delete(data, scratch)
	front := data
	if len(front) > SKILL_MAX_FRONTMATTER_BYTES { front = front[:SKILL_MAX_FRONTMATTER_BYTES] }
	metadata, metadata_error := parse_metadata(front, basename, scratch)
	defer metadata_destroy(&metadata, scratch)
	defer load_error_destroy(&metadata_error, scratch)
	if metadata_error.kind != .None {
		kind := Diagnostic_Kind.Invalid
		if metadata_error.kind == .Unsupported_Metadata { kind = .Unsupported }
		record_file_diagnostic(catalog, root_pos, frame.logical, scratch, allocator, kind, metadata_error.detail)
		return
	}
	directory, directory_error := filepath.join({root.path, frame.logical}, scratch)
	if directory_error != nil { return }
	defer delete(directory, scratch)
	logical_primary, logical_error := filepath.join({frame.logical, "SKILL.md"}, scratch)
	if logical_error != nil { return }
	defer delete(logical_primary, scratch)
	candidate := Candidate {
		name        = strings.clone(metadata.name, scratch),
		description = strings.clone(metadata.description, scratch),
		root_pos    = root_pos,
		logical     = strings.clone(logical_primary, scratch),
		canonical   = strings.clone(directory, scratch),
		digest      = metadata.digest,
		valid       = true,
	}
	append(candidates, candidate)
}

select_candidates :: proc(candidates: []Candidate, catalog: ^Catalog, scratch, allocator: mem.Allocator) -> bool {
	ordered := slice.clone(candidates, scratch)
	slice.sort_by(ordered, proc(a, b: Candidate) -> bool {
		if a.root_pos != b.root_pos { return a.root_pos < b.root_pos }
		return a.logical < b.logical
	})
	selected := make([dynamic]Skill, 0, len(ordered), scratch)
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
				scratch,
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
			record_diagnostic(catalog, Diagnostic{.Shadowed, candidate.root_pos, candidate.logical, 0, "", "", winner, candidate.logical}, scratch, allocator)
			continue
		}
		append(
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
	}
	slice.sort_by(selected[:], proc(a, b: Skill) -> bool { return a.name < b.name })
	if len(selected) > SKILL_MAX_CATALOG_ENTRIES { return false }
	owned := make([]Skill, len(selected), allocator)
	for skill, index in selected {
		owned[index] = Skill {
			name            = strings.clone(skill.name, allocator),
			description     = strings.clone(skill.description, allocator),
			logical_path    = strings.clone(skill.logical_path, allocator),
			directory       = strings.clone(skill.directory, allocator),
			root_index      = skill.root_index,
			metadata_digest = skill.metadata_digest,
		}
	}
	catalog.skills = owned
	return true
}

clone_roots :: proc(roots: []Root, allocator: mem.Allocator) -> []Root {
	owned := make([]Root, len(roots), allocator)
	for root, index in roots {
		owned[index] = Root {
			source       = root.source,
			logical_path = strings.clone(root.logical_path, allocator),
			path         = strings.clone(root.path, allocator),
			authority    = strings.clone(root.authority, allocator),
		}
	}
	return owned
}

release_candidates :: proc(candidates: []Candidate, allocator: mem.Allocator) {
	for candidate in candidates {
		delete(candidate.name, allocator)
		delete(candidate.description, allocator)
		delete(candidate.logical, allocator)
		delete(candidate.canonical, allocator)
	}
}

record_file_diagnostic :: proc(catalog: ^Catalog, root_pos: int, logical: string, scratch, allocator: mem.Allocator, kind: Diagnostic_Kind, detail: string) {
	record_diagnostic(catalog, Diagnostic{kind, root_pos, logical, 0, "", detail, "", ""}, scratch, allocator)
}

record_diagnostic :: proc(catalog: ^Catalog, diagnostic: Diagnostic, scratch, allocator: mem.Allocator) {
	_ = scratch
	if len(catalog.diagnostics) >= SKILL_MAX_DIAGNOSTICS {
		catalog.omitted += 1
		return
	}
	owned := Diagnostic {
		kind       = diagnostic.kind,
		root_index = diagnostic.root_index,
		path       = strings.clone(diagnostic.path, allocator),
		line       = diagnostic.line,
		field      = strings.clone(diagnostic.field, allocator),
		detail     = strings.clone(diagnostic.detail, allocator),
		winner     = strings.clone(diagnostic.winner, allocator),
		loser      = strings.clone(diagnostic.loser, allocator),
	}
	grown := make([]Diagnostic, len(catalog.diagnostics) + 1, allocator)
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
