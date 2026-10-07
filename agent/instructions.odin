package agent

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "nabla:agent/skills"

INSTRUCTIONS_NABLA_SKILLS_DIR :: "skills"
INSTRUCTIONS_AGENTS_DIR :: ".agents"
INSTRUCTIONS_AGENTS_FILE :: "AGENTS.md"

// SKILL_INLINE_CATALOG_BYTES is the catalog size above which the model is told to read the
// catalog through builtin_list_skills rather than receive it inline. It picks how the
// metadata is disclosed; no skill metadata is dropped either way.
SKILL_INLINE_CATALOG_BYTES :: 16 * 1024

Instruction_Source_Kind :: enum {
	Nabla_User,
	Local,
	Generic_User,
}

Instruction_Error :: enum {
	None,
	Allocation,
	Read,
}

Instruction_Root :: struct {
	kind:      Instruction_Source_Kind,
	path:      string,
	authority: string,
}

// instruction_roots lists the skill sources in priority order, highest first.
// The launch directory's own `.agents/skills` wins, then Nabla's configuration
// directory, then the generic user directory. The workspace is the only scope
// a local root may read from; nothing here depends on any repository state.
@(require_results)
instruction_roots :: proc(workspace: string, disable_project: bool, allocator := context.allocator) -> ([]Instruction_Root, mem.Allocator_Error) {
	roots, roots_error := make([dynamic]Instruction_Root, 0, 3, allocator)
	if roots_error != nil { return nil, roots_error }
	complete := false
	defer if !complete { instruction_roots_destroy(roots[:], allocator) }
	if !disable_project {
		path, join_error := filepath.join({workspace, INSTRUCTIONS_AGENTS_DIR, INSTRUCTIONS_NABLA_SKILLS_DIR}, allocator)
		if join_error != nil { return nil, join_error }
		authority, clone_error := strings.clone(workspace, allocator)
		if clone_error != nil {
			delete(path, allocator)
			return nil, clone_error
		}
		root := Instruction_Root {
			kind      = .Local,
			path      = path,
			authority = authority,
		}
		appended := append(&roots, root)
		if appended != 1 {
			if appended == 0 {
				delete(root.path, allocator)
				delete(root.authority, allocator)
			}
			return nil, .Out_Of_Memory
		}
	}
	if config_dir, config_err := xdg_directory(.Config, allocator); config_err == .None {
		defer delete(config_dir, allocator)
		path, join_error := filepath.join({config_dir, INSTRUCTIONS_NABLA_SKILLS_DIR}, allocator)
		if join_error != nil { return nil, join_error }
		root := Instruction_Root {
			kind = .Nabla_User,
			path = path,
		}
		appended := append(&roots, root)
		if appended != 1 {
			if appended == 0 { delete(root.path, allocator) }
			return nil, .Out_Of_Memory
		}
	}
	if home, home_err := os.user_home_dir(allocator); home_err == nil && home != "" {
		defer delete(home, allocator)
		path, join_error := filepath.join({home, INSTRUCTIONS_AGENTS_DIR, INSTRUCTIONS_NABLA_SKILLS_DIR}, allocator)
		if join_error != nil { return nil, join_error }
		root := Instruction_Root {
			kind = .Generic_User,
			path = path,
		}
		appended := append(&roots, root)
		if appended != 1 {
			if appended == 0 { delete(root.path, allocator) }
			return nil, .Out_Of_Memory
		}
	}
	complete = true
	return roots[:], nil
}

Agents_File :: struct {
	path:  string,
	scope: string,
	body:  string,
}

@(require_results)
agents_file_clone :: proc(path, scope, body: string, allocator: mem.Allocator) -> (result_value: Agents_File, error: mem.Allocator_Error) {
	file: Agents_File
	complete := false
	defer if !complete {
		delete(file.path, allocator)
		delete(file.scope, allocator)
		delete(file.body, allocator)
	}
	file.path = strings.clone(path, allocator) or_return
	file.scope = strings.clone(scope, allocator) or_return
	file.body = strings.clone(body, allocator) or_return
	complete = true
	return file, nil
}

agents_files_destroy :: proc(files: []Agents_File, allocator := context.allocator) {
	for &file in files {
		delete(file.path, allocator)
		delete(file.scope, allocator)
		delete(file.body, allocator)
	}
	delete(files, allocator)
}

// collect_agents_files reads the automatic instruction files: the launch
// directory's AGENTS.md first, then the personal one in the home `.agents`
// directory. Missing files are normal; an existing file that cannot be read
// completely is an error, never a silent skip.
@(require_results)
collect_agents_files :: proc(workspace: string, disable_project: bool, allocator := context.allocator) -> ([]Agents_File, string, Instruction_Error) {
	files, files_error := make([dynamic]Agents_File, 0, 2, allocator)
	if files_error != nil { return nil, "the instruction file list could not be allocated", .Allocation }
	failed := true
	defer if failed { agents_files_destroy(files[:], allocator) }
	if !disable_project {
		path, join_error := filepath.join({workspace, INSTRUCTIONS_AGENTS_FILE}, context.temp_allocator)
		if join_error != nil { return nil, "an instruction path could not be allocated", .Allocation }
		defer delete(path, context.temp_allocator)
		detail, err := instructions_add_file(&files, path, "local", allocator)
		if err != .None { return nil, detail, err }
	}
	if home, home_err := os.user_home_dir(context.temp_allocator); home_err == nil && home != "" {
		defer delete(home, context.temp_allocator)
		path, join_error := filepath.join({home, INSTRUCTIONS_AGENTS_DIR, INSTRUCTIONS_AGENTS_FILE}, context.temp_allocator)
		if join_error != nil { return nil, "an instruction path could not be allocated", .Allocation }
		defer delete(path, context.temp_allocator)
		detail, err := instructions_add_file(&files, path, "personal", allocator)
		if err != .None { return nil, detail, err }
	}
	failed = false
	return files[:], "", .None
}

@(require_results)
instructions_add_file :: proc(files: ^[dynamic]Agents_File, path, source: string, allocator: mem.Allocator) -> (detail: string, err: Instruction_Error) {
	body, status, read_detail := read_agents_file(path, context.temp_allocator)
	defer delete(body, context.temp_allocator)
	switch status {
	case .Present:
	case .Missing:
		return "", .None
	case .Unreadable:
		return read_detail, .Read
	case .Allocation:
		return read_detail, .Allocation
	}
	file, clone_error := agents_file_clone(path, source, body, allocator)
	if clone_error != nil { return "an instruction file could not be copied", .Allocation }
	appended := append(files, file)
	if appended != 1 {
		if appended == 0 { agents_files_destroy([]Agents_File{file}, allocator) }
		return "the instruction file list could not be allocated", .Allocation
	}
	return "", .None
}

Agents_File_Status :: enum {
	Present,
	Missing,
	Unreadable,
	Allocation,
}

// read_agents_file reads one automatic instruction file completely. An absent
// file, including an empty or whitespace-only placeholder, reports .Missing:
// it carries no instructions, so it must not block the session. Every other
// failure names the file, so the session error says which source is wrong. The
// returned detail text is borrowed and lives only for the call.
@(require_results)
read_agents_file :: proc(path: string, allocator := context.allocator) -> (body: string, status: Agents_File_Status, detail: string) {
	info, stat_error := os.stat(path, context.temp_allocator)
	defer os.file_info_delete(info, context.temp_allocator)
	if stat_error != nil {
		if stat_error == os.General_Error.Not_Exist { return "", .Missing, "" }
		return "", .Unreadable, fmt.aprintf("%s could not be inspected", path, allocator = context.temp_allocator)
	}
	if info.type != .Regular { return "", .Unreadable, fmt.aprintf("%s is not a regular file", path, allocator = context.temp_allocator) }
	data, read_error := os.read_entire_file(path, allocator)
	if read_error != nil { return "", .Unreadable, fmt.aprintf("%s could not be read", path, allocator = context.temp_allocator) }
	defer delete(data, allocator)
	if strings.trim_space(string(data)) == "" { return "", .Missing, "" }
	if !skills.skill_body_valid(string(data)) { return "", .Unreadable, fmt.aprintf("%s contains invalid text", path, allocator = context.temp_allocator) }
	clone_error: mem.Allocator_Error
	body, clone_error = strings.clone(string(data), allocator)
	if clone_error != nil { return "", .Allocation, "the instruction file could not be copied" }
	return body, .Present, ""
}

@(require_results)
render_instructions :: proc(
	files: []Agents_File,
	catalog: skills.Catalog,
	client_instructions: string,
	tools_enabled: bool,
	allocator := context.allocator,
) -> (
	string,
	mem.Allocator_Error,
) {
	builder, builder_error := strings.builder_make(allocator)
	if builder_error != nil { return "", builder_error }
	failed := true
	defer if failed { strings.builder_destroy(&builder) }
	if !instruction_write_string(&builder, AGENT_SYSTEM_PROMPT) { return "", .Out_Of_Memory }
	if client_instructions != "" && (!instruction_write_string(&builder, "\n\n") || !instruction_write_string(&builder, client_instructions)) {
		return "", .Out_Of_Memory
	}
	if tools_enabled {
		if !instruction_write_string(
			&builder,
			"\n\nSkills provide specialized task instructions. Load a clearly relevant skill before work that depends on it. Catalog metadata is not the complete instructions. If only a summary remains, load the skill again before relying on details.",
		) { return "", .Out_Of_Memory }
	}
	for file in files {
		if !instruction_write_string(&builder, "\n\nSource: ") ||
		   !instruction_write_string(&builder, file.path) ||
		   !instruction_write_string(&builder, " (") ||
		   !instruction_write_string(&builder, file.scope) ||
		   !instruction_write_string(&builder, ")\n") ||
		   !instruction_write_string(&builder, file.body) {
			return "", .Out_Of_Memory
		}
	}
	if tools_enabled {
		encoded, encode_error := encode_skill_catalog(catalog, context.temp_allocator)
		if encode_error != nil { return "", encode_error }
		defer delete(encoded, context.temp_allocator)
		if len(encoded) <= SKILL_INLINE_CATALOG_BYTES {
			if !instruction_write_string(&builder, "\n\nAvailable skills: ") || !instruction_write_string(&builder, encoded) { return "", .Out_Of_Memory }
			if len(catalog.skills) == 0 && !instruction_write_string(&builder, "No skills are available.") { return "", .Out_Of_Memory }
		} else if !instruction_write_string(&builder, "\n\nAvailable skills are listed through builtin_list_skills.") {
			return "", .Out_Of_Memory
		}
	}
	text := strings.to_string(builder)
	failed = false
	return text, nil
}

@(require_results)
encode_skill_catalog :: proc(catalog: skills.Catalog, allocator := context.allocator) -> (string, mem.Allocator_Error) {
	builder, builder_error := strings.builder_make(allocator)
	if builder_error != nil { return "", builder_error }
	failed := true
	defer if failed { strings.builder_destroy(&builder) }
	if !instruction_write_byte(&builder, '[') { return "", .Out_Of_Memory }
	for skill, index in catalog.skills {
		if index > 0 && !instruction_write_byte(&builder, ',') { return "", .Out_Of_Memory }
		if !instruction_write_string(&builder, `{"name":`) ||
		   !write_json_string(&builder, skill.name) ||
		   !instruction_write_string(&builder, `,"description":`) ||
		   !write_json_string(&builder, skill.description) ||
		   !instruction_write_byte(&builder, '}') {
			return "", .Out_Of_Memory
		}
	}
	if !instruction_write_byte(&builder, ']') { return "", .Out_Of_Memory }
	text := strings.to_string(builder)
	failed = false
	return text, nil
}

@(require_results)
instruction_write_string :: proc(builder: ^strings.Builder, value: string) -> bool {
	return strings.write_string(builder, value) == len(value)
}

@(require_results)
instruction_write_byte :: proc(builder: ^strings.Builder, value: byte) -> bool {
	return strings.write_byte(builder, value) == 1
}

@(require_results)
write_json_string :: proc(builder: ^strings.Builder, value: string) -> bool {
	hex := "0123456789abcdef"
	if !instruction_write_byte(builder, '"') { return false }
	for i := 0; i < len(value); {
		character := value[i]
		switch character {
		case '"', '\\':
			if !instruction_write_byte(builder, '\\') || !instruction_write_byte(builder, character) { return false }
		case '\n':
			if !instruction_write_string(builder, `\n`) { return false }
		case '\r':
			if !instruction_write_string(builder, `\r`) { return false }
		case '\t':
			if !instruction_write_string(builder, `\t`) { return false }
		case:
			if character < 0x20 {
				if !instruction_write_string(builder, `\u00`) ||
				   !instruction_write_byte(builder, hex[character >> 4]) ||
				   !instruction_write_byte(builder, hex[character & 0x0f]) { return false }
			} else if !instruction_write_byte(builder, character) { return false }
		}
		i += 1
	}
	return instruction_write_byte(builder, '"')
}

@(require_results)
instruction_skill_roots :: proc(roots: []Instruction_Root, allocator := context.allocator) -> (result_value: []skills.Root, error: mem.Allocator_Error) {
	converted := make([]skills.Root, len(roots), allocator) or_return
	complete := false
	defer if !complete {
		for root in converted {
			delete(root.logical_path, allocator)
			delete(root.authority, allocator)
		}
		delete(converted, allocator)
	}
	for root, index in roots {
		converted[index].source = instruction_source_kind(root.kind)
		converted[index].logical_path = strings.clone(root.path, allocator) or_return
		converted[index].authority = strings.clone(root.authority, allocator) or_return
	}
	complete = true
	return converted, nil
}

instruction_source_kind :: proc(kind: Instruction_Source_Kind) -> skills.Source_Kind {
	switch kind {
	case .Nabla_User:
		return .Nabla_User
	case .Local:
		return .Local
	case .Generic_User:
		return .Generic_User
	}
	return .Unknown
}

instruction_roots_destroy :: proc(roots: []Instruction_Root, allocator := context.allocator) {
	for &root in roots {
		delete(root.path, allocator)
		delete(root.authority, allocator)
	}
	delete(roots, allocator)
}
