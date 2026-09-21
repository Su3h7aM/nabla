package agent

import "core:encoding/json"
import "core:fmt"
import "core:strings"

import "nabla:agent/session"
import "nabla:agent/skills"

INSTRUCTION_MANIFEST_VERSION :: 2
SKILL_METADATA_FORMAT_VERSION :: 1

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
	files, files_error := collect_agents_files(chat.workspace, chat.disable_project_instructions, chat.allocator)
	if files_error != "" {
		return "", "", {}, fmt.tprintf("local instructions could not be read: %s", files_error)
	}
	defer agents_files_destroy(files, chat.allocator)
	roots := instruction_roots(chat.workspace, chat.disable_project_instructions, chat.allocator)
	defer instruction_roots_destroy(roots, chat.allocator)
	skill_roots := instruction_skill_roots(roots, chat.allocator)
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
	rendered := render_instructions(files, discovered, chat.tools_enabled, chat.allocator)
	if len(rendered) > INSTRUCTIONS_MAX_BYTES {
		delete(rendered, chat.allocator)
		skills.catalog_destroy(&discovered, chat.allocator)
		return "", "", {}, "initial instructions exceed the byte limit"
	}
	encoded := chat_encode_manifest(chat, files, discovered, rendered, chat.allocator)
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
chat_encode_manifest :: proc(chat: ^Chat_Session, files: []Agents_File, catalog: skills.Catalog, rendered: string, allocator := context.allocator) -> string {
	scratch := context.temp_allocator
	inline_catalog := encode_skill_catalog(catalog, scratch)
	manifest := Instruction_Manifest {
		version                  = INSTRUCTION_MANIFEST_VERSION,
		workspace                = chat.workspace,
		disable_project          = chat.disable_project_instructions,
		tools_enabled            = chat.tools_enabled,
		metadata_format          = SKILL_METADATA_FORMAT_VERSION,
		instruction_bytes        = len(rendered),
		roots                    = make([]Instruction_Manifest_Root, len(catalog.roots), scratch),
		agents                   = make([]Instruction_Manifest_File, len(files), scratch),
		skills                   = make([]Instruction_Manifest_Skill, len(catalog.skills), scratch),
		diagnostics              = make([]Instruction_Manifest_Diagnostic, len(catalog.diagnostics), scratch),
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
		manifest.skills[index] = Instruction_Manifest_Skill {
			name            = skill.name,
			description     = skill.description,
			logical_path    = skill.logical_path,
			directory       = skill.directory,
			root_index      = skill.root_index,
			metadata_digest = skill_digest_text(skill.metadata_digest, scratch),
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
	if marshal_error != nil { return "" }
	return string(encoded)
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
	catalog.skills = make([]skills.Skill, len(manifest.skills), chat.allocator)
	catalog.roots = make([]skills.Root, len(manifest.roots), chat.allocator)
	catalog.diagnostics = make([]skills.Diagnostic, len(manifest.diagnostics), chat.allocator)
	// A corrupt entry below must not strand what the earlier entries cloned.
	applied := false
	defer if !applied { skills.catalog_destroy(&catalog, chat.allocator) }
	for entry, index in manifest.skills {
		if !skills.skill_name_valid(entry.name) { return false }
		catalog.skills[index] = skills.Skill {
			name            = strings.clone(entry.name, chat.allocator),
			description     = strings.clone(entry.description, chat.allocator),
			logical_path    = strings.clone(entry.logical_path, chat.allocator),
			directory       = strings.clone(entry.directory, chat.allocator),
			root_index      = entry.root_index,
			metadata_digest = skill_digest_parse(entry.metadata_digest),
		}
	}
	// The manifest records each root's canonical directory, which is what says whether a root
	// holds a skill. A restored root has no configured logical path.
	for entry, index in manifest.roots {
		catalog.roots[index] = skills.Root {
			source    = instruction_manifest_source(entry.kind),
			path      = strings.clone(entry.path, chat.allocator),
			authority = strings.clone(entry.authority, chat.allocator),
		}
	}
	chat_rebind_skill_roots(&catalog)
	for entry, index in manifest.diagnostics {
		catalog.diagnostics[index] = skills.Diagnostic {
			kind       = skills.Diagnostic_Kind(entry.kind),
			root_index = entry.root_index,
			path       = strings.clone(entry.path, chat.allocator),
			detail     = strings.clone(entry.detail, chat.allocator),
			winner     = strings.clone(entry.winner, chat.allocator),
			loser      = strings.clone(entry.loser, chat.allocator),
		}
	}
	catalog.omitted = manifest.omitted_diagnostics
	chat.skill_catalog = catalog
	delete(chat.skill_instructions, chat.allocator)
	chat.skill_instructions = strings.clone(instructions, chat.allocator)
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
