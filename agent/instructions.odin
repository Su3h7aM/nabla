package agent

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
	Project,
	Generic_User,
}

Instruction_Root :: struct {
	kind:      Instruction_Source_Kind,
	path:      string,
	authority: string,
}

instruction_roots :: proc(workspace: string, project_boundary: string, disable_project: bool, allocator := context.allocator) -> []Instruction_Root {
	roots := make([dynamic]Instruction_Root, 0, 4, allocator)
	if config_dir, config_err := xdg_directory(.Config, allocator); config_err == .None {
		defer delete(config_dir, allocator)
		if path, join_err := filepath.join({config_dir, INSTRUCTIONS_NABLA_SKILLS_DIR}, allocator); join_err == nil {
			append(&roots, Instruction_Root{kind = .Nabla_User, path = path})
		} else {
			delete(config_dir, allocator)
		}
	}
	if !disable_project && project_boundary != "" && project_boundary != workspace {
		append(
			&roots,
			Instruction_Root{kind = .Project, path = strings.clone(project_boundary, allocator), authority = strings.clone(project_boundary, allocator)},
		)
	}
	if !disable_project {
		append(&roots, Instruction_Root{kind = .Project, path = strings.clone(workspace, allocator), authority = strings.clone(project_boundary, allocator)})
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

collect_agents_files :: proc(workspace: string, boundary: string, disable_project: bool, allocator := context.allocator) -> ([]Agents_File, string) {
	files := make([dynamic]Agents_File, 0, 4, allocator)
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
				return nil, read_err
			}
		}
	}
	if !disable_project {
		chain := agents_chain(workspace, boundary, context.temp_allocator)
		defer {
			for path in chain { delete(path, context.temp_allocator) }
			delete(chain, context.temp_allocator)
		}
		for directory in chain {
			if path, join_err := filepath.join({directory, INSTRUCTIONS_AGENTS_FILE}, context.temp_allocator); join_err == nil {
				defer delete(path, context.temp_allocator)
				if body, read_err := read_agents_file(path, context.temp_allocator); read_err == "" {
					defer delete(body, context.temp_allocator)
					append(
						&files,
						Agents_File{path = strings.clone(path, allocator), scope = strings.clone(directory, allocator), body = strings.clone(body, allocator)},
					)
				} else if read_err != "missing" {
					return nil, read_err
				}
			}
		}
	}
	return files[:], ""
}

agents_chain :: proc(workspace: string, boundary: string, allocator := context.allocator) -> []string {
	chain := make([dynamic]string, 0, 8, allocator)
	current := strings.clone(boundary != "" ? boundary : workspace, allocator)
	for {
		append(&chain, strings.clone(current, allocator))
		if current == workspace { break }
		if !strings.has_prefix(workspace, current) || (len(workspace) > len(current) && workspace[len(current)] != '/') { break }
		relative := workspace[len(current):]
		if strings.has_prefix(relative, "/") { relative = relative[1:] }
		separator := strings.index_byte(relative, '/')
		next := workspace
		if separator >= 0 { next = strings.concatenate({current, "/", relative[:separator]}, allocator) } else { next = strings.clone(workspace, allocator) }
		delete(current, allocator)
		current = next
	}
	return chain[:]
}

read_agents_file :: proc(path: string, allocator := context.allocator) -> (string, string) {
	info, stat_error := os.stat(path, context.temp_allocator)
	defer os.file_info_delete(info, context.temp_allocator)
	if stat_error != nil {
		if stat_error == os.General_Error.Not_Exist { return "", "missing" }
		return "", "unreadable"
	}
	if info.type != .Regular { return "", "not a file" }
	if info.size > INSTRUCTIONS_MAX_FILE_BYTES { return "", "too large" }
	data, read_error := os.read_entire_file(path, allocator)
	if read_error != nil { return "", "unreadable" }
	defer delete(data, allocator)
	if !skills.skill_body_valid(string(data)) { return "", "invalid text" }
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

project_boundary :: proc(workspace: string, allocator := context.allocator) -> string {
	current := strings.clone(workspace, allocator)
	for {
		git, git_error := filepath.join({current, ".git"}, context.temp_allocator)
		if git_error == nil {
			defer delete(git, context.temp_allocator)
			if os.exists(git) { return current }
		}
		jj, jj_error := filepath.join({current, ".jj"}, context.temp_allocator)
		if jj_error == nil {
			defer delete(jj, context.temp_allocator)
			if os.is_dir(jj) {
				delete(current, allocator)
				return strings.clone(jj[:len(jj) - len("/.jj")], allocator)
			}
		}
		parent := filepath.dir(current)
		if parent == current { return current }
		next := strings.clone(parent, allocator)
		delete(current, allocator)
		current = next
	}
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
	case .Project:
		return .Project
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
