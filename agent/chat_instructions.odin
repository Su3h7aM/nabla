package agent

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

import "nabla:agent/journal"
import "nabla:agent/skills"

INSTRUCTION_MANIFEST_VERSION :: 2
SKILL_METADATA_FORMAT_VERSION :: 1

// The artifact kinds an instruction snapshot is stored under.
INSTRUCTIONS_ARTIFACT :: "instructions"
INSTRUCTION_MANIFEST_ARTIFACT :: "instruction_manifest"

Instruction_Manifest_Error :: enum {
	None,
	Allocation,
	Encode,
}

// chat_ensure_instructions settles the instructions the session runs with: the
// snapshot its latest turn recorded, or a new one rendered from the workspace. A
// new snapshot is buffered as artifacts that the next turn.started names.
@(require_results)
chat_ensure_instructions :: proc(chat: ^Chat_Session) -> bool {
	if chat.skill_instructions != "" { return true }

	if chat.client_instructions == "" {
		applied, restore_error := chat_restore_instructions(chat)
		if restore_error != nil {
			chat_session_record_failure(chat, "the instruction snapshot could not be restored", restore_error)
			return false
		}
		if applied { return true }
	}
	instructions, manifest, catalog, manifest_error := chat_build_snapshot(chat)
	if manifest_error != "" {
		chat_session_fail(chat, manifest_error)
		return false
	}
	chat.instructions_digest = journal.put_artifact(chat.store, INSTRUCTIONS_ARTIFACT, transmute([]u8)instructions)
	chat.manifest_digest = journal.put_artifact(chat.store, INSTRUCTION_MANIFEST_ARTIFACT, transmute([]u8)manifest)
	chat_skill_catalog_release(chat)
	chat.skill_catalog = catalog
	delete(chat.skill_instructions, chat.allocator)
	chat.skill_instructions = instructions
	delete(manifest, chat.allocator)
	return true
}

// chat_restore_instructions applies the snapshot named by the session's latest
// turn.started, and reports whether there was one.
@(private, require_results)
chat_restore_instructions :: proc(chat: ^Chat_Session) -> (applied: bool, error: journal.Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	filter := journal.Filter {
		session = chat.session,
		kinds   = {.Turn_Started},
	}
	record, found := journal.read_latest(chat.store, filter, context.temp_allocator) or_return
	if !found { return false, nil }
	started: journal.Turn_Started
	journal.payload_decode(
		record.data,
		&started,
		context.temp_allocator,
		corruption_journal = chat.store,
		session = record.session,
		seq = record.seq,
	) or_return
	if started.instructions == "" { return false, nil }
	instructions_digest, instructions_valid := journal.digest_from_hex(started.instructions)
	manifest_digest, manifest_valid := journal.digest_from_hex(started.manifest)
	if !instructions_valid || !manifest_valid {
		chat.store.corrupt = {record.session, record.seq}
		return false, journal.Journal_Error.Corrupt
	}
	instructions, instructions_found, instructions_error := journal.read_artifact(chat.store, instructions_digest, context.temp_allocator)
	if instructions_error != nil {
		if journal.error_is(instructions_error, .Corrupt) { chat.store.corrupt = {record.session, record.seq} }
		return false, instructions_error
	}
	manifest, manifest_found, manifest_error := journal.read_artifact(chat.store, manifest_digest, context.temp_allocator)
	if manifest_error != nil {
		if journal.error_is(manifest_error, .Corrupt) { chat.store.corrupt = {record.session, record.seq} }
		return false, manifest_error
	}
	if !instructions_found || !manifest_found {
		chat.store.corrupt = {record.session, record.seq}
		return false, journal.Journal_Error.Corrupt
	}
	if !chat_apply_snapshot(chat, string(instructions), string(manifest)) {
		chat.store.corrupt = {record.session, record.seq}
		return false, journal.Journal_Error.Corrupt
	}
	chat.instructions_digest = instructions_digest
	chat.manifest_digest = manifest_digest
	return true, nil
}

@(require_results)
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
	rendered, rendered_error := render_instructions(files, discovered, chat.client_instructions, chat.tools_enabled, chat.allocator)
	if rendered_error != nil { return "", "", {}, "local instructions could not be allocated" }
	// A role goes last, so everything before it is the prefix the orchestrator already sends.
	if chat.role_instructions != "" {
		with_role, role_error := strings.concatenate({rendered, "\n\n", chat.role_instructions}, chat.allocator)
		delete(rendered, chat.allocator)
		if role_error != nil {
			skills.catalog_destroy(&discovered, chat.allocator)
			return "", "", {}, "local instructions could not be allocated"
		}
		rendered = with_role
	}
	encoded, manifest_error := chat_encode_manifest(chat, files, discovered, rendered, chat.allocator)
	if manifest_error != .None {
		delete(rendered, chat.allocator)
		skills.catalog_destroy(&discovered, chat.allocator)
		return "", "", {}, "the instruction manifest could not be allocated"
	}
	return rendered, encoded, discovered, ""
}

// chat_encode_manifest records the snapshot a later resume applies. The roots it writes are
// the catalog's own, because every root index it also writes refers to that list.
@(require_results)
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
	// The manifest slices and the digests are scratch: the record that is returned is
	// marshalled with the allocator the caller passed.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
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

@(require_results)
snapshot_skill_make :: proc(entry: Instruction_Manifest_Skill, allocator: mem.Allocator) -> (result_value: skills.Skill, error: mem.Allocator_Error) {
	skill: skills.Skill
	complete := false
	defer if !complete {
		delete(skill.name, allocator)
		delete(skill.description, allocator)
		delete(skill.logical_path, allocator)
		delete(skill.directory, allocator)
	}
	skill.name = strings.clone(entry.name, allocator) or_return
	skill.description = strings.clone(entry.description, allocator) or_return
	skill.logical_path = strings.clone(entry.logical_path, allocator) or_return
	skill.directory = strings.clone(entry.directory, allocator) or_return
	skill.root_index = entry.root_index
	skill.metadata_digest = skill_digest_parse(entry.metadata_digest)
	complete = true
	return skill, nil
}

@(require_results)
snapshot_root_make :: proc(entry: Instruction_Manifest_Root, source: skills.Source_Kind, allocator: mem.Allocator) -> (result_value: skills.Root, error: mem.Allocator_Error) {
	root: skills.Root
	complete := false
	defer if !complete {
		delete(root.path, allocator)
		delete(root.authority, allocator)
	}
	root.path = strings.clone(entry.path, allocator) or_return
	root.authority = strings.clone(entry.authority, allocator) or_return
	root.source = source
	complete = true
	return root, nil
}

@(require_results)
snapshot_diagnostic_make :: proc(entry: Instruction_Manifest_Diagnostic, allocator: mem.Allocator) -> (result_value: skills.Diagnostic, error: mem.Allocator_Error) {
	diagnostic: skills.Diagnostic
	complete := false
	defer if !complete {
		delete(diagnostic.path, allocator)
		delete(diagnostic.detail, allocator)
		delete(diagnostic.winner, allocator)
		delete(diagnostic.loser, allocator)
	}
	diagnostic.path = strings.clone(entry.path, allocator) or_return
	diagnostic.detail = strings.clone(entry.detail, allocator) or_return
	diagnostic.winner = strings.clone(entry.winner, allocator) or_return
	diagnostic.loser = strings.clone(entry.loser, allocator) or_return
	diagnostic.kind = skills.Diagnostic_Kind(entry.kind)
	diagnostic.root_index = entry.root_index
	complete = true
	return diagnostic, nil
}

@(require_results)
chat_apply_snapshot :: proc(chat: ^Chat_Session, instructions, manifest_json: string) -> bool {
	// The manifest is parsed out of temp memory and everything the catalog keeps is cloned
	// into the session's allocator.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	// A second catalog never replaces the first: the check comes before any
	// allocation, so refusing costs nothing and leaks nothing.
	if chat.skill_catalog != nil { return false }
	manifest: Instruction_Manifest
	if json.unmarshal_string(manifest_json, &manifest, allocator = context.temp_allocator) != nil { return false }
	if manifest.version != INSTRUCTION_MANIFEST_VERSION { return false }
	if manifest.workspace != chat.workspace { return false }
	if manifest.instruction_bytes != len(instructions) { return false }
	for entry in manifest.skills {
		if !skills.skill_name_valid(entry.name) { return false }
		if entry.root_index < 0 || entry.root_index >= len(manifest.roots) { return false }
		if !skills.path_within(entry.directory, manifest.roots[entry.root_index].path) { return false }
	}
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
		skill, skill_error := snapshot_skill_make(entry, chat.allocator)
		if skill_error != nil { return false }
		catalog.skills[index] = skill
	}
	// The manifest records each root's canonical directory, which is what says whether a root
	// holds a skill. A restored root has no configured logical path.
	for entry, index in manifest.roots {
		source, source_ok := instruction_manifest_source(entry.kind)
		if !source_ok { return false }
		root, root_error := snapshot_root_make(entry, source, chat.allocator)
		if root_error != nil { return false }
		catalog.roots[index] = root
	}
	for entry, index in manifest.diagnostics {
		diagnostic, diagnostic_error := snapshot_diagnostic_make(entry, chat.allocator)
		if diagnostic_error != nil { return false }
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

instruction_manifest_source :: proc(kind: string) -> (skills.Source_Kind, bool) {
	switch kind {
	case "nabla_user":
		return .Nabla_User, true
	case "local":
		return .Local, true
	case "generic_user":
		return .Generic_User, true
	case "unknown":
		return .Unknown, true
	}
	return .Unknown, false
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

skill_hex_value :: proc(character: u8) -> u8 {
	switch character {
	case '0' ..= '9':
		return character - '0'
	case 'a' ..= 'f':
		return character - 'a' + 10
	case 'A' ..= 'F':
		return character - 'A' + 10
	}
	return 0
}
