package agent

import "core:fmt"
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

Instruction_Root :: struct {
	kind:      Instruction_Source_Kind,
	path:      string,
	authority: string,
}

// instruction_roots lists the skill sources in priority order, highest first.
// The launch directory's own `.agents/skills` wins, then Nabla's configuration
// directory, then the generic user directory. The workspace is the only scope
// a local root may read from; nothing here depends on any repository state.
instruction_roots :: proc(workspace: string, disable_project: bool, allocator := context.allocator) -> []Instruction_Root {
	roots := make([dynamic]Instruction_Root, 0, 3, allocator)
	if !disable_project {
		if path, join_err := filepath.join({workspace, INSTRUCTIONS_AGENTS_DIR, INSTRUCTIONS_NABLA_SKILLS_DIR}, allocator); join_err == nil {
			append(&roots, Instruction_Root{kind = .Local, path = path, authority = strings.clone(workspace, allocator)})
		}
	}
	if config_dir, config_err := xdg_directory(.Config, allocator); config_err == .None {
		defer delete(config_dir, allocator)
		if path, join_err := filepath.join({config_dir, INSTRUCTIONS_NABLA_SKILLS_DIR}, allocator); join_err == nil {
			append(&roots, Instruction_Root{kind = .Nabla_User, path = path})
		}
	}
	if home, home_err := os.user_home_dir(allocator); home_err == nil && home != "" {
		defer delete(home, allocator)
		if path, join_error := filepath.join({home, INSTRUCTIONS_AGENTS_DIR, INSTRUCTIONS_NABLA_SKILLS_DIR}, allocator); join_error == nil {
			append(&roots, Instruction_Root{kind = .Generic_User, path = path})
		}
	}
	return roots[:]
}

Agents_File :: struct {
	path:  string,
	scope: string,
	body:  string,
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
collect_agents_files :: proc(workspace: string, disable_project: bool, allocator := context.allocator) -> ([]Agents_File, string) {
	files := make([dynamic]Agents_File, 0, 2, allocator)
	if !disable_project {
		if path, join_err := filepath.join({workspace, INSTRUCTIONS_AGENTS_FILE}, context.temp_allocator); join_err == nil {
			defer delete(path, context.temp_allocator)
			if body, read_err := read_agents_file(path, context.temp_allocator); read_err == "" {
				defer delete(body, context.temp_allocator)
				append(
					&files,
					Agents_File{path = strings.clone(path, allocator), scope = strings.clone("local", allocator), body = strings.clone(body, allocator)},
				)
			} else if read_err != "missing" {
				agents_files_destroy(files[:], allocator)
				return nil, read_err
			}
		}
	}
	if home, home_err := os.user_home_dir(context.temp_allocator); home_err == nil && home != "" {
		defer delete(home, context.temp_allocator)
		if path, join_err := filepath.join({home, INSTRUCTIONS_AGENTS_DIR, INSTRUCTIONS_AGENTS_FILE}, context.temp_allocator); join_err == nil {
			defer delete(path, context.temp_allocator)
			if body, read_err := read_agents_file(path, context.temp_allocator); read_err == "" {
				defer delete(body, context.temp_allocator)
				append(
					&files,
					Agents_File{path = strings.clone(path, allocator), scope = strings.clone("personal", allocator), body = strings.clone(body, allocator)},
				)
			} else if read_err != "missing" {
				agents_files_destroy(files[:], allocator)
				return nil, read_err
			}
		}
	}
	return files[:], ""
}

// read_agents_file reads one automatic instruction file completely. An absent
// file, including an empty or whitespace-only placeholder, reports "missing":
// it carries no instructions, so it must not block the session. Every other
// failure names the file, so the session error says which source is wrong. The
// returned error text is borrowed and lives only for the call.
read_agents_file :: proc(path: string, allocator := context.allocator) -> (string, string) {
	info, stat_error := os.stat(path, context.temp_allocator)
	defer os.file_info_delete(info, context.temp_allocator)
	if stat_error != nil {
		if stat_error == os.General_Error.Not_Exist { return "", "missing" }
		return "", fmt.aprintf("%s could not be inspected", path, allocator = context.temp_allocator)
	}
	if info.type != .Regular { return "", fmt.aprintf("%s is not a regular file", path, allocator = context.temp_allocator) }
	if info.size > INSTRUCTIONS_MAX_FILE_BYTES { return "", fmt.aprintf("%s exceeds the byte limit", path, allocator = context.temp_allocator) }
	data, read_error := os.read_entire_file(path, allocator)
	if read_error != nil { return "", fmt.aprintf("%s could not be read", path, allocator = context.temp_allocator) }
	defer delete(data, allocator)
	if strings.trim_space(string(data)) == "" { return "", "missing" }
	if !skills.skill_body_valid(string(data)) { return "", fmt.aprintf("%s contains invalid text", path, allocator = context.temp_allocator) }
	return strings.clone(string(data), allocator), ""
}

render_instructions :: proc(files: []Agents_File, catalog: skills.Catalog, tools_enabled: bool, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, AGENT_SYSTEM_PROMPT)
	if tools_enabled {
		strings.write_string(
			&builder,
			"\n\nSkills provide specialized task instructions. Load a clearly relevant skill before work that depends on it. Catalog metadata is not the complete instructions. If only a summary remains, load the skill again before relying on details.",
		)
	}
	for file in files {
		strings.write_string(&builder, "\n\nSource: ")
		strings.write_string(&builder, file.path)
		strings.write_string(&builder, " (")
		strings.write_string(&builder, file.scope)
		strings.write_string(&builder, ")\n")
		strings.write_string(&builder, file.body)
	}
	if tools_enabled {
		encoded := encode_skill_catalog(catalog, context.temp_allocator)
		defer delete(encoded, context.temp_allocator)
		if len(encoded) <= SKILL_INLINE_CATALOG_BYTES {
			strings.write_string(&builder, "\n\nAvailable skills: ")
			strings.write_string(&builder, encoded)
			if len(catalog.skills) == 0 { strings.write_string(&builder, "No skills are available.") }
		} else {
			strings.write_string(&builder, "\n\nAvailable skills are listed through list_skills.")
		}
	}
	return strings.to_string(builder)
}

encode_skill_catalog :: proc(catalog: skills.Catalog, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	strings.write_byte(&builder, '[')
	for skill, index in catalog.skills {
		if index > 0 { strings.write_byte(&builder, ',') }
		strings.write_string(&builder, `{"name":`)
		write_json_string(&builder, skill.name)
		strings.write_string(&builder, `,"description":`)
		write_json_string(&builder, skill.description)
		strings.write_byte(&builder, '}')
	}
	strings.write_byte(&builder, ']')
	return strings.to_string(builder)
}

write_json_string :: proc(builder: ^strings.Builder, value: string) {
	hex := "0123456789abcdef"
	strings.write_byte(builder, '"')
	for i := 0; i < len(value); {
		c := value[i]
		switch c {
		case '"', '\\':
			strings.write_byte(builder, '\\')
			strings.write_byte(builder, c)
		case '\n':
			strings.write_string(builder, `\n`)
		case '\r':
			strings.write_string(builder, `\r`)
		case '\t':
			strings.write_string(builder, `\t`)
		case:
			if c <
			   0x20 { strings.write_string(builder, `\u00`); strings.write_byte(builder, hex[c >> 4]); strings.write_byte(builder, hex[c & 0x0f]) } else { strings.write_byte(builder, c) }
		}
		i += 1
	}
	strings.write_byte(builder, '"')
}

instruction_skill_roots :: proc(roots: []Instruction_Root, allocator := context.allocator) -> []skills.Root {
	converted := make([]skills.Root, len(roots), allocator)
	for root, index in roots {
		converted[index] = skills.Root {
			source       = instruction_source_kind(root.kind),
			logical_path = strings.clone(root.path, allocator),
			authority    = strings.clone(root.authority, allocator),
		}
	}
	return converted
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
