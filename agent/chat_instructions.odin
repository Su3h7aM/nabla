package agent

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

import "nabla:agent/session"
import "nabla:agent/skills"

INSTRUCTION_MANIFEST_VERSION :: 2
SKILL_METADATA_FORMAT_VERSION :: 1

Instruction_Manifest_Error :: enum {
	None,
	Allocation,
	Encode,
}

chat_ensure_instructions :: proc(chat: ^Chat_Session) -> bool {
	if chat.skill_instructions != "" { return true }

	snapshot, present, read_error := session.instruction_snapshot_read(chat.store, chat.id, chat.allocator)
	if read_error == nil && present {
		defer session.instruction_snapshot_destroy(&snapshot, chat.allocator)
		if !chat_apply_snapshot(chat, snapshot.instructions, snapshot.manifest_json) {
			chat_session_record_failure(chat, "the instruction snapshot is invalid", session.error_make(.Corrupt, ""))
			return false
		}
		chat.skill_snapshot_seq = snapshot.seq
		return true
	} else if read_error != nil {
		chat_session_record_failure(chat, "the instruction snapshot could not be read", read_error)
		return false
	}
	instructions, manifest, catalog, manifest_error := chat_build_snapshot(chat)
	if manifest_error != "" {
		chat_session_record_failure(chat, manifest_error, session.error_make(.Storage, ""))
		return false
	}
	seq, append_error := session.instruction_snapshot_append(
		chat.store,
		chat.id,
		{format_version = session.INSTRUCTION_SNAPSHOT_VERSION, instructions = instructions, manifest_json = manifest},
		session.now_ms(),
	)
	if append_error != nil {
		delete(instructions, chat.allocator)
		delete(manifest, chat.allocator)
		skills.catalog_destroy(&catalog, chat.allocator)
		chat_session_record_failure(chat, "the instruction snapshot could not be recorded", append_error)
		return false
	}
	if existing, has_catalog := &chat.skill_catalog.?; has_catalog { skills.catalog_destroy(existing, chat.allocator) }
	chat.skill_catalog = catalog
	delete(chat.skill_instructions, chat.allocator)
	chat.skill_instructions = instructions
	delete(manifest, chat.allocator)
	chat.skill_snapshot_seq = seq
	return true
}

chat_build_snapshot :: proc(chat: ^Chat_Session) -> (instructions, manifest: string, catalog: skills.Catalog, error_text: string) {
	files, files_error, files_kind := collect_agents_files(chat.workspace, chat.disable_project_instructions, chat.allocator)
	if files_kind == .Allocation { return "", "", {}, "local instructions could not be allocated" }
	if files_kind == .Read {
		return "", "", {}, fmt.tprintf("local instructions could not be read: %s", files_error)
	}
	defer agents_files_destroy(files, chat.allocator)
	roots, roots_error := instruction_roots(chat.workspace, chat.disable_project_instructions, chat.allocator)
	if roots_error != nil { return "", "", {}, "instruction roots could not be allocated" }
	defer instruction_roots_destroy(roots, chat.allocator)
	skill_roots, skill_roots_error := instruction_skill_roots(roots, chat.allocator)
	if skill_roots_error != nil { return "", "", {}, "instruction roots could not be copied" }
	defer {
		for &root in skill_roots {
			delete(root.logical_path, chat.allocator)
			delete(root.authority, chat.allocator)
		}
		delete(skill_roots, chat.allocator)
	}
	discovered, discover_error := skills.discover(skill_roots, chat.allocator)
	defer skills.load_error_destroy(&discover_error, chat.allocator)
	if discover_error.kind != .None {
		return "", "", {}, "skill discovery failed"
	}
	rendered, rendered_error := render_instructions(files, discovered, chat.tools_enabled, chat.allocator)
	if rendered_error != nil { return "", "", {}, "local instructions could not be allocated" }
	if len(rendered) > INSTRUCTIONS_MAX_BYTES {
		delete(rendered, chat.allocator)
		skills.catalog_destroy(&discovered, chat.allocator)
		return "", "", {}, "initial instructions exceed the byte limit"
	}
	encoded, manifest_error := chat_encode_manifest(chat, files, discovered, rendered, chat.allocator)
	if manifest_error != .None {
		delete(rendered, chat.allocator)
		skills.catalog_destroy(&discovered, chat.allocator)
		return "", "", {}, "the instruction manifest could not be allocated"
	}
	if len(encoded) > SKILL_MAX_MANIFEST_BYTES {
		delete(rendered, chat.allocator)
		delete(encoded, chat.allocator)
		skills.catalog_destroy(&discovered, chat.allocator)
		return "", "", {}, "the instruction manifest exceeds the byte limit"
	}
	return rendered, encoded, discovered, ""
}

// chat_encode_manifest records the snapshot a later resume applies. The roots it writes are
// the catalog's own, because every root index it also writes refers to that list.
chat_encode_manifest :: proc(
	chat: ^Chat_Session,
	files: []Agents_File,
	catalog: skills.Catalog,
	rendered: string,
	allocator := context.allocator,
) -> (
	string,
	Instruction_Manifest_Error,
) {
	scratch := context.temp_allocator
	inline_catalog, inline_error := encode_skill_catalog(catalog, scratch)
	if inline_error != nil { return "", .Allocation }
	roots, roots_error := make([]Instruction_Manifest_Root, len(catalog.roots), scratch)
	if roots_error != nil { return "", .Allocation }
	agents, agents_error := make([]Instruction_Manifest_File, len(files), scratch)
	if agents_error != nil { return "", .Allocation }
	skills_data, skills_error := make([]Instruction_Manifest_Skill, len(catalog.skills), scratch)
	if skills_error != nil { return "", .Allocation }
	diagnostics, diagnostics_error := make([]Instruction_Manifest_Diagnostic, len(catalog.diagnostics), scratch)
	if diagnostics_error != nil { return "", .Allocation }
	manifest := Instruction_Manifest {
		version                  = INSTRUCTION_MANIFEST_VERSION,
		workspace                = chat.workspace,
		disable_project          = chat.disable_project_instructions,
		tools_enabled            = chat.tools_enabled,
		metadata_format          = SKILL_METADATA_FORMAT_VERSION,
		instruction_bytes        = len(rendered),
		roots                    = roots,
		agents                   = agents,
		skills                   = skills_data,
		diagnostics              = diagnostics,
		omitted_diagnostics      = catalog.omitted,
		inline_catalog_truncated = len(inline_catalog) > SKILL_INLINE_CATALOG_BYTES,
	}
	for root, index in catalog.roots {
		manifest.roots[index] = Instruction_Manifest_Root {
			kind      = instruction_manifest_kind(root.source),
			path      = root.path,
			authority = root.authority,
		}
	}
	for file, index in files {
		manifest.agents[index] = Instruction_Manifest_File {
			path  = file.path,
			scope = file.scope,
			bytes = len(file.body),
		}
	}
	for skill, index in catalog.skills {
		digest, digest_error := skill_digest_text(skill.metadata_digest, scratch)
		if digest_error != nil { return "", .Allocation }
		manifest.skills[index] = Instruction_Manifest_Skill {
			name            = skill.name,
			description     = skill.description,
			logical_path    = skill.logical_path,
			directory       = skill.directory,
			root_index      = skill.root_index,
			metadata_digest = digest,
		}
	}
	for diagnostic, index in catalog.diagnostics {
		manifest.diagnostics[index] = Instruction_Manifest_Diagnostic {
			kind       = uint(diagnostic.kind),
			root_index = diagnostic.root_index,
			path       = diagnostic.path,
			detail     = diagnostic.detail,
			winner     = diagnostic.winner,
			loser      = diagnostic.loser,
		}
	}
	encoded, marshal_error := json.marshal(manifest, allocator = allocator)
	if marshal_error != nil { return "", .Encode }
	return string(encoded), .None
}

Instruction_Manifest :: struct {
	version:                  int `json:"version"`,
	workspace:                string `json:"workspace"`,
	disable_project:          bool `json:"disable_project"`,
	tools_enabled:            bool `json:"tools_enabled"`,
	metadata_format:          int `json:"metadata_format"`,
	instruction_bytes:        int `json:"instruction_bytes"`,
	roots:                    []Instruction_Manifest_Root `json:"roots"`,
	agents:                   []Instruction_Manifest_File `json:"agents"`,
	skills:                   []Instruction_Manifest_Skill `json:"skills"`,
	diagnostics:              []Instruction_Manifest_Diagnostic `json:"diagnostics"`,
	omitted_diagnostics:      int `json:"omitted_diagnostics"`,
	inline_catalog_truncated: bool `json:"inline_catalog_truncated"`,
}

Instruction_Manifest_Root :: struct {
	kind:      string `json:"kind"`,
	path:      string `json:"path"`,
	authority: string `json:"authority"`,
}

Instruction_Manifest_File :: struct {
	path:  string `json:"path"`,
	scope: string `json:"scope"`,
	bytes: int `json:"bytes"`,
}

Instruction_Manifest_Skill :: struct {
	name:            string `json:"name"`,
	description:     string `json:"description"`,
	logical_path:    string `json:"logical_path"`,
	directory:       string `json:"directory"`,
	root_index:      int `json:"root_index"`,
	metadata_digest: string `json:"metadata_digest"`,
}

Instruction_Manifest_Diagnostic :: struct {
	kind:       uint `json:"kind"`,
	root_index: int `json:"root_index"`,
	path:       string `json:"path"`,
	detail:     string `json:"detail"`,
	winner:     string `json:"winner"`,
	loser:      string `json:"loser"`,
}

instruction_manifest_kind :: proc(kind: skills.Source_Kind) -> string {
	switch kind {
	case .Nabla_User:
		return "nabla_user"
	case .Local:
		return "local"
	case .Generic_User:
		return "generic_user"
	case .Unknown:
	}
	return "unknown"
}

snapshot_skill_make :: proc(entry: Instruction_Manifest_Skill, allocator: mem.Allocator) -> (skills.Skill, bool) {
	skill: skills.Skill
	clone_error: mem.Allocator_Error
	skill.name, clone_error = strings.clone(entry.name, allocator)
	if clone_error != nil { return {}, false }
	skill.description, clone_error = strings.clone(entry.description, allocator)
	if clone_error != nil { delete(skill.name, allocator); return {}, false }
	skill.logical_path, clone_error = strings.clone(entry.logical_path, allocator)
	if clone_error != nil { delete(skill.name, allocator); delete(skill.description, allocator); return {}, false }
	skill.directory, clone_error = strings.clone(entry.directory, allocator)
	if clone_error != nil { delete(skill.name, allocator); delete(skill.description, allocator); delete(skill.logical_path, allocator); return {}, false }
	skill.root_index = entry.root_index
	skill.metadata_digest = skill_digest_parse(entry.metadata_digest)
	return skill, true
}

snapshot_root_make :: proc(entry: Instruction_Manifest_Root, allocator: mem.Allocator) -> (skills.Root, bool) {
	root: skills.Root
	path, path_error := strings.clone(entry.path, allocator)
	if path_error != nil { return {}, false }
	authority, authority_error := strings.clone(entry.authority, allocator)
	if authority_error != nil { delete(path, allocator); return {}, false }
	root = skills.Root {
		source    = instruction_manifest_source(entry.kind),
		path      = path,
		authority = authority,
	}
	return root, true
}

snapshot_diagnostic_make :: proc(entry: Instruction_Manifest_Diagnostic, allocator: mem.Allocator) -> (skills.Diagnostic, bool) {
	diagnostic: skills.Diagnostic
	path, path_error := strings.clone(entry.path, allocator)
	if path_error != nil { return {}, false }
	detail, detail_error := strings.clone(entry.detail, allocator)
	if detail_error != nil { delete(path, allocator); return {}, false }
	winner, winner_error := strings.clone(entry.winner, allocator)
	if winner_error != nil { delete(path, allocator); delete(detail, allocator); return {}, false }
	loser, loser_error := strings.clone(entry.loser, allocator)
	if loser_error != nil { delete(path, allocator); delete(detail, allocator); delete(winner, allocator); return {}, false }
	diagnostic = skills.Diagnostic {
		kind       = skills.Diagnostic_Kind(entry.kind),
		root_index = entry.root_index,
		path       = path,
		detail     = detail,
		winner     = winner,
		loser      = loser,
	}
	return diagnostic, true
}

chat_apply_snapshot :: proc(chat: ^Chat_Session, instructions, manifest_json: string) -> bool {
	// A second catalog never replaces the first: the check comes before any
	// allocation, so refusing costs nothing and leaks nothing.
	if chat.skill_catalog != nil { return false }
	manifest: Instruction_Manifest
	if json.unmarshal_string(manifest_json, &manifest, allocator = context.temp_allocator) != nil { return false }
	// Version 1 differed from the current manifest only by a removed repository
	// boundary field and the source-kind name "project"; both are inert, so old
	// snapshots keep applying instead of stranding their sessions.
	if manifest.version > INSTRUCTION_MANIFEST_VERSION { return false }
	if manifest.workspace != chat.workspace { return false }
	if manifest.instruction_bytes != len(instructions) { return false }
	catalog: skills.Catalog
	// A corrupt entry or allocation failure must not strand what earlier entries cloned.
	applied := false
	defer if !applied { skills.catalog_destroy(&catalog, chat.allocator) }
	catalog_skills, skills_error := make([]skills.Skill, len(manifest.skills), chat.allocator)
	if skills_error != nil { return false }
	catalog.skills = catalog_skills
	catalog_roots, roots_error := make([]skills.Root, len(manifest.roots), chat.allocator)
	if roots_error != nil { return false }
	catalog.roots = catalog_roots
	catalog_diagnostics, diagnostics_error := make([]skills.Diagnostic, len(manifest.diagnostics), chat.allocator)
	if diagnostics_error != nil { return false }
	catalog.diagnostics = catalog_diagnostics
	for entry, index in manifest.skills {
		if !skills.skill_name_valid(entry.name) { return false }
		skill, skill_ok := snapshot_skill_make(entry, chat.allocator)
		if !skill_ok { return false }
		catalog.skills[index] = skill
	}
	// The manifest records each root's canonical directory, which is what says whether a root
	// holds a skill. A restored root has no configured logical path.
	for entry, index in manifest.roots {
		root, root_ok := snapshot_root_make(entry, chat.allocator)
		if !root_ok { return false }
		catalog.roots[index] = root
	}
	chat_rebind_skill_roots(&catalog)
	for entry, index in manifest.diagnostics {
		diagnostic, diagnostic_ok := snapshot_diagnostic_make(entry, chat.allocator)
		if !diagnostic_ok { return false }
		catalog.diagnostics[index] = diagnostic
	}
	catalog.omitted = manifest.omitted_diagnostics
	owned_instructions, instructions_error := strings.clone(instructions, chat.allocator)
	if instructions_error != nil { return false }
	chat.skill_catalog = catalog
	delete(chat.skill_instructions, chat.allocator)
	chat.skill_instructions = owned_instructions
	applied = true
	return true
}

// chat_rebind_skill_roots puts each restored skill back on the root that holds it. A
// snapshot written before the manifest recorded the catalog's own roots lists the launch's
// configured roots instead, so a root_index can name a different one: the pairing decides
// whether a local skill may be read and which origin is reported, and a skill paired with a
// root it is not in is refused as outside that root's scope. The directory each skill was
// found in is the evidence that places it, and a skill no recorded root holds keeps its
// pairing, so its load still fails by name rather than reading through a guessed root.
chat_rebind_skill_roots :: proc(catalog: ^skills.Catalog) {
	for &skill in catalog.skills {
		if chat_skill_root_holds(skill, catalog.roots) { continue }
		for root, index in catalog.roots {
			if root.path != "" && skills.path_within(skill.directory, root.path) {
				skill.root_index = index
				break
			}
		}
	}
}

// chat_skill_root_holds reports whether the recorded pairing places a skill in its root.
chat_skill_root_holds :: proc(skill: skills.Skill, roots: []skills.Root) -> bool {
	if skill.root_index < 0 || skill.root_index >= len(roots) { return false }
	return skills.path_within(skill.directory, roots[skill.root_index].path)
}

instruction_manifest_source :: proc(kind: string) -> skills.Source_Kind {
	switch kind {
	case "nabla_user":
		return .Nabla_User
	case "local", "project":
		return .Local
	case "generic_user":
		return .Generic_User
	}
	return .Unknown
}

skill_digest_parse :: proc(text: string) -> [32]u8 {
	digest: [32]u8
	if len(text) != 64 { return digest }
	for index in 0 ..< 32 {
		high := skill_hex_value(text[index * 2])
		low := skill_hex_value(text[index * 2 + 1])
		digest[index] = high << 4 | low
	}
	return digest
}

skill_hex_value :: proc(c: u8) -> u8 {
	switch c {
	case '0' ..= '9':
		return c - '0'
	case 'a' ..= 'f':
		return c - 'a' + 10
	case 'A' ..= 'F':
		return c - 'A' + 10
	}
	return 0
}
