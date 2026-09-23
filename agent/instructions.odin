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
INSTRUCTIONS_MAX_TOTAL_BYTES :: 1 * 1024 * 1024
INSTRUCTIONS_MAX_FILE_BYTES :: 256 * 1024
INSTRUCTIONS_MAX_BYTES :: 2 * 1024 * 1024
SKILL_INLINE_CATALOG_BYTES :: 16 * 1024
SKILL_MAX_MANIFEST_BYTES :: 32 * 1024 * 1024

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

agents_file_clone :: proc(path, scope, body: string, allocator: mem.Allocator) -> (Agents_File, mem.Allocator_Error) {
	file: Agents_File
	clone_error: mem.Allocator_Error
	file.path, clone_error = strings.clone(path, allocator)
	if clone_error != nil { return {}, clone_error }
	file.scope, clone_error = strings.clone(scope, allocator)
	if clone_error != nil {
		delete(file.path, allocator)
		return {}, clone_error
	}
	file.body, clone_error = strings.clone(body, allocator)
	if clone_error != nil {
		delete(file.path, allocator)
		delete(file.scope, allocator)
		return {}, clone_error
	}
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
collect_agents_files :: proc(workspace: string, disable_project: bool, allocator := context.allocator) -> ([]Agents_File, string, Instruction_Error) {
	files, files_error := make([dynamic]Agents_File, 0, 2, allocator)
	if files_error != nil { return nil, "the instruction file list could not be allocated", .Allocation }
	failed := true
	defer if failed { agents_files_destroy(files[:], allocator) }
	if !disable_project {
		path, join_error := filepath.join({workspace, INSTRUCTIONS_AGENTS_FILE}, context.temp_allocator)
		if join_error != nil { return nil, "an instruction path could not be allocated", .Allocation }
		defer delete(path, context.temp_allocator)
		body, read_error, read_kind := read_agents_file(path, context.temp_allocator)
		defer delete(body, context.temp_allocator)
		if read_kind == .None && read_error == "" {
			file, clone_error := agents_file_clone(path, "local", body, allocator)
			if clone_error != nil { return nil, "an instruction file could not be copied", .Allocation }
			appended := append(&files, file)
			if appended != 1 {
				if appended == 0 { agents_files_destroy([]Agents_File{file}, allocator) }
				return nil, "the instruction file list could not be allocated", .Allocation
			}
		} else if read_kind == .Read {
			return nil, read_error, .Read
		}
	}
	if home, home_err := os.user_home_dir(context.temp_allocator); home_err == nil && home != "" {
		defer delete(home, context.temp_allocator)
		path, join_error := filepath.join({home, INSTRUCTIONS_AGENTS_DIR, INSTRUCTIONS_AGENTS_FILE}, context.temp_allocator)
		if join_error != nil { return nil, "an instruction path could not be allocated", .Allocation }
		defer delete(path, context.temp_allocator)
		body, read_error, read_kind := read_agents_file(path, context.temp_allocator)
		defer delete(body, context.temp_allocator)
		if read_kind == .None && read_error == "" {
			file, clone_error := agents_file_clone(path, "personal", body, allocator)
			if clone_error != nil { return nil, "an instruction file could not be copied", .Allocation }
			appended := append(&files, file)
			if appended != 1 {
				if appended == 0 { agents_files_destroy([]Agents_File{file}, allocator) }
				return nil, "the instruction file list could not be allocated", .Allocation
			}
		} else if read_kind == .Read {
			return nil, read_error, .Read
		}
	}
	failed = false
	return files[:], "", .None
}

// read_agents_file reads one automatic instruction file completely. An absent
// file, including an empty or whitespace-only placeholder, reports "missing":
// it carries no instructions, so it must not block the session. Every other
// failure names the file, so the session error says which source is wrong. The
// returned error text is borrowed and lives only for the call.
read_agents_file :: proc(path: string, allocator := context.allocator) -> (string, string, Instruction_Error) {
	info, stat_error := os.stat(path, context.temp_allocator)
	defer os.file_info_delete(info, context.temp_allocator)
	if stat_error != nil {
		if stat_error == os.General_Error.Not_Exist { return "", "missing", .None }
		return "", fmt.aprintf("%s could not be inspected", path, allocator = context.temp_allocator), .Read
	}
	if info.type != .Regular { return "", fmt.aprintf("%s is not a regular file", path, allocator = context.temp_allocator), .Read }
	if info.size > INSTRUCTIONS_MAX_FILE_BYTES { return "", fmt.aprintf("%s exceeds the byte limit", path, allocator = context.temp_allocator), .Read }
	data, read_error := os.read_entire_file(path, allocator)
	if read_error != nil { return "", fmt.aprintf("%s could not be read", path, allocator = context.temp_allocator), .Read }
	defer delete(data, allocator)
	if strings.trim_space(string(data)) == "" { return "", "missing", .None }
	if !skills.skill_body_valid(string(data)) { return "", fmt.aprintf("%s contains invalid text", path, allocator = context.temp_allocator), .Read }
	body, clone_error := strings.clone(string(data), allocator)
	if clone_error != nil { return "", "the instruction file could not be copied", .Allocation }
	return body, "", .None
}

render_instructions :: proc(
	files: []Agents_File,
	catalog: skills.Catalog,
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

instruction_write_string :: proc(builder: ^strings.Builder, value: string) -> bool {
	return strings.write_string(builder, value) == len(value)
}

instruction_write_byte :: proc(builder: ^strings.Builder, value: byte) -> bool {
	return strings.write_byte(builder, value) == 1
}

write_json_string :: proc(builder: ^strings.Builder, value: string) -> bool {
	hex := "0123456789abcdef"
	if !instruction_write_byte(builder, '"') { return false }
	for i := 0; i < len(value); {
		c := value[i]
		switch c {
		case '"', '\\':
			if !instruction_write_byte(builder, '\\') || !instruction_write_byte(builder, c) { return false }
		case '\n':
			if !instruction_write_string(builder, `\n`) { return false }
		case '\r':
			if !instruction_write_string(builder, `\r`) { return false }
		case '\t':
			if !instruction_write_string(builder, `\t`) { return false }
		case:
			if c < 0x20 {
				if !instruction_write_string(builder, `\u00`) ||
				   !instruction_write_byte(builder, hex[c >> 4]) ||
				   !instruction_write_byte(builder, hex[c & 0x0f]) { return false }
			} else if !instruction_write_byte(builder, c) { return false }
		}
		i += 1
	}
	return instruction_write_byte(builder, '"')
}

instruction_skill_roots :: proc(roots: []Instruction_Root, allocator := context.allocator) -> ([]skills.Root, mem.Allocator_Error) {
	converted, converted_error := make([]skills.Root, len(roots), allocator)
	if converted_error != nil { return nil, converted_error }
	for root, index in roots {
		logical_path, path_error := strings.clone(root.path, allocator)
		if path_error != nil {
			for &owned in converted[:index] {
				delete(owned.logical_path, allocator)
				delete(owned.authority, allocator)
			}
			delete(converted, allocator)
			return nil, path_error
		}
		authority, authority_error := strings.clone(root.authority, allocator)
		if authority_error != nil {
			delete(logical_path, allocator)
			for &owned in converted[:index] {
				delete(owned.logical_path, allocator)
				delete(owned.authority, allocator)
			}
			delete(converted, allocator)
			return nil, authority_error
		}
		converted[index] = skills.Root {
			source       = instruction_source_kind(root.kind),
			logical_path = logical_path,
			authority    = authority,
		}
	}
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
