package agent

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

import "nabla:agent/skills"

INSTRUCTIONS_NABLA_SKILLS_DIR :: "skills"
INSTRUCTIONS_AGENTS_DIR :: ".agents"
INSTRUCTIONS_AGENTS_FILE :: "AGENTS.md"

// SKILL_INLINE_CATALOG_BYTES is the catalog size above which the model is told to read the
// catalog through skills rather than receive it inline. It picks how the
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

// --- dynamic package instructions --------------------------------------------
//
// The workspace root file and the personal one enter the cached prefix
// snapshot at session start. A subdirectory file must not move that prefix,
// so it travels as a trailing message of the next request instead. Workers
// record the workspace paths their tools reached, with no I/O, through the
// borrowed pointer in their Tool_Context; the owner resolves the files from
// that record when building the next request.

// Instruction_Touches is the session-owned record of workspace paths the
// agent's tools reached. The mutex is never held across I/O: workers hold it
// only to store one cloned path, and the owner swaps the list out before
// reading anything. Safe from any thread.
Instruction_Touches :: struct {
	mutex:     sync.Mutex,
	paths:     [dynamic]string, // owned absolute paths, with duplicates
	allocator: mem.Allocator,
}

// Delivered_Instruction is a subdirectory instruction file already sent, with
// the size and modification time it had then. A request carries each file
// once, and again only after it changes. Owner thread only.
Delivered_Instruction :: struct {
	path:     string, // owned
	size:     i64,
	mod_time: time.Time,
}

// instructions_record_touch counts the agent's touch of path (a read, edit, or
// write that succeeded) toward subdirectory instruction discovery. The stored
// entry is the touched file's directory. Lexical only, so it does no I/O, and
// every failure is ignored: discovery is best effort, never a tool failure.
// Safe from any thread.
instructions_record_touch :: proc(ctx: ^Tool_Context, path: string) {
	instruction_touches_add(ctx, path, false)
}

// instructions_record_touch_dir counts the agent's touch of a directory
// itself: a find or grep root, or a shell working directory. Safe from any
// thread.
instructions_record_touch_dir :: proc(ctx: ^Tool_Context, path: string) {
	instruction_touches_add(ctx, path, true)
}

@(private)
instruction_touches_add :: proc(ctx: ^Tool_Context, path: string, is_dir: bool) {
	touches := ctx.instructions
	if touches == nil { return }
	absolute, abs_error := search_path_resolve(ctx.workspace, path, ctx.allocator)
	if abs_error != nil { return }
	defer delete(absolute, ctx.allocator)
	root, root_error := filepath.clean(ctx.workspace, ctx.allocator)
	if root_error != nil { return }
	defer delete(root, ctx.allocator)
	// filepath.dir is os.dir: a borrowed view into its input, never owned.
	// The entry is cloned so every free below releases owned memory.
	view := absolute if is_dir else filepath.dir(absolute)
	dir, dir_error := strings.clone(view, ctx.allocator)
	if dir_error != nil { return }
	defer delete(dir, ctx.allocator)
	// The workspace root file is already in the prefix snapshot, so the root
	// itself, and anything outside the workspace, records nothing.
	if dir == root || !instructions_path_inside(root, dir) { return }
	sync.guard(&touches.mutex)
	owned, clone_error := strings.clone(dir, touches.allocator)
	if clone_error != nil { return }
	if append(&touches.paths, owned) != 1 {
		delete(owned, touches.allocator)
		return
	}
}

@(private)
instructions_path_inside :: proc(root, path: string) -> bool {
	if len(path) <= len(root) { return false }
	if !strings.has_prefix(path, root) { return false }
	return path[len(root)] == '/' || strings.has_suffix(root, "/")
}

// instruction_touches_take swaps the recorded paths out, leaving an empty
// list behind. The caller owns the returned slice and every path in it, with
// touches.allocator, and frees both. Owner side of the handoff; workers keep
// appending to the fresh list while the owner resolves the taken one.
@(private)
instruction_touches_take :: proc(touches: ^Instruction_Touches) -> []string {
	sync.guard(&touches.mutex)
	taken := touches.paths[:]
	touches.paths = {}
	touches.paths.allocator = touches.allocator
	return taken
}

// chat_consume_dynamic_instructions resolves subdirectory instruction files
// from the touches workers recorded and renders the ones this session has not
// seen, or that changed since, as a trailing message for the next request.
// Each file is delivered once; an edit redelivers it, and a removed file is
// forgotten so a later recreation delivers again. A failure on one file skips
// that file only, and a file that cannot be rendered stays undelivered, so
// the next request tries it again. Infallible by design: discovery must never
// fail a request. The returned text is owned by allocator. Owner thread only.
@(require_results)
chat_consume_dynamic_instructions :: proc(chat: ^Chat_Session, allocator: mem.Allocator) -> string {
	alloc := chat.instruction_touches.allocator
	taken := instruction_touches_take(&chat.instruction_touches)
	defer {
		if len(taken) > 0 {
			for path in taken { delete(path, alloc) }
			delete(taken, alloc)
		}
	}
	if chat.disable_project_instructions || len(taken) == 0 { return "" }
	root, root_error := filepath.clean(chat.workspace, allocator)
	if root_error != nil { return "" }
	defer delete(root, allocator)
	candidates, candidates_error := make([dynamic]string, 0, allocator)
	if candidates_error != nil { return "" }
	// Candidates are joined strings owned here; the delivered map holds its
	// own clones, so every candidate is released below.
	defer {
		for candidate in candidates { delete(candidate, allocator) }
		delete(candidates)
	}
	for touched in taken {
		instructions_add_candidates(&candidates, root, touched, allocator)
	}
	if len(candidates) == 0 { return "" }
	// Shallow files first, so general package instructions read before specific
	// ones; the tiebreak keeps the order deterministic.
	slice.sort_by(candidates[:], proc(a, b: string) -> bool {
		if len(a) != len(b) { return len(a) < len(b) }
		return a < b
	})
	builder, builder_error := strings.builder_make(allocator)
	if builder_error != nil { return "" }
	// to_string hands the buffer to the returned text, so the builder is
	// destroyed only when nothing is returned, as in render_instructions.
	succeeded := false
	defer if !succeeded { strings.builder_destroy(&builder) }
	delivered_any := false
	for candidate in candidates {
		if instructions_render_if_fresh(chat, &builder, candidate, allocator) {
			delivered_any = true
		}
	}
	if !delivered_any { return "" }
	succeeded = true
	return strings.to_string(builder)
}

// instructions_add_candidates appends the instruction files on the ancestor
// chain of touched, nearest its directory first, skipping duplicates. The
// workspace root itself is never a candidate: its file is already in the
// prefix snapshot. Owned by allocator, through candidates.
@(private)
instructions_add_candidates :: proc(candidates: ^[dynamic]string, root, touched: string, allocator: mem.Allocator) {
	owned := false
	dir := touched
	defer if owned { delete(dir, allocator) }
	for instructions_path_inside(root, dir) {
		candidate, join_error := filepath.join({dir, INSTRUCTIONS_AGENTS_FILE}, allocator)
		if join_error == nil {
			duplicate := false
			for existing in candidates { if existing == candidate { duplicate = true; break } }
			if duplicate {
				delete(candidate, allocator)
			} else if append(candidates, candidate) != 1 {
				delete(candidate, allocator)
				return
			}
		}
		// filepath.dir is os.dir: a borrowed view, so the parent is cloned
		// before the directory it views into is released.
		parent, parent_error := strings.clone(filepath.dir(dir), allocator)
		if parent_error != nil { return }
		if owned { delete(dir, allocator) }
		dir = parent
		owned = true
	}
}

// instructions_render_if_fresh appends candidate to builder when this session
// has not seen it, or when it changed since, and records what was sent. It
// reports whether anything was appended. A missing or unreadable file is
// forgotten, and a file that cannot be rendered stays undelivered.
@(private)
instructions_render_if_fresh :: proc(chat: ^Chat_Session, builder: ^strings.Builder, candidate: string, allocator: mem.Allocator) -> bool {
	info, stat_error := os.stat(candidate, context.temp_allocator)
	if stat_error != nil {
		os.file_info_delete(info, context.temp_allocator)
		instructions_forget_delivered(chat, candidate)
		return false
	}
	is_file := info.type == .Regular
	size := info.size
	mod_time := info.modification_time
	os.file_info_delete(info, context.temp_allocator)
	if !is_file {
		instructions_forget_delivered(chat, candidate)
		return false
	}
	for delivered in chat.delivered_instructions {
		if delivered.path == candidate {
			if delivered.size == size && delivered.mod_time == mod_time { return false }
			break
		}
	}
	body, status, _ := read_agents_file(candidate, context.temp_allocator)
	defer delete(body, context.temp_allocator)
	if status != .Present { return false }
	path, clone_error := strings.clone(candidate, chat.allocator)
	if clone_error != nil { return false }
	entry := Delivered_Instruction {
		path     = path,
		size     = size,
		mod_time = mod_time,
	}
	replaced := false
	for &delivered in chat.delivered_instructions {
		if delivered.path == candidate {
			delete(delivered.path, chat.allocator)
			delivered = entry
			replaced = true
			break
		}
	}
	if !replaced && append(&chat.delivered_instructions, entry) != 1 {
		delete(path, chat.allocator)
		return false
	}
	if builder_len := strings.builder_len(builder^); builder_len == 0 {
		if !instruction_write_string(
			builder,
			"Package instructions from directories the agent's tools reached. Follow them for work under those directories:\n\n",
		) { return false }
	} else if !instruction_write_string(builder, "\n\n") {
		return false
	}
	if !instruction_write_string(builder, "Source: ") ||
	   !instruction_write_string(builder, candidate) ||
	   !instruction_write_string(builder, " (package)\n") ||
	   !instruction_write_string(builder, body) {
		instructions_forget_delivered(chat, candidate)
		return false
	}
	return true
}

// instructions_forget_delivered drops candidate from what this session has
// seen, so a later recreation delivers it again. Owner thread only.
@(private)
instructions_forget_delivered :: proc(chat: ^Chat_Session, candidate: string) {
	for index in 0 ..< len(chat.delivered_instructions) {
		if chat.delivered_instructions[index].path == candidate {
			delete(chat.delivered_instructions[index].path, chat.allocator)
			ordered_remove(&chat.delivered_instructions, index)
			return
		}
	}
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
			"\n\nSkills provide specialized task instructions. When the task matches a skill description, find it with the skills tool and load it with the skill tool before work that depends on it. Catalog metadata is not the complete instructions. If only a summary remains, load the skill again before relying on details.",
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
		} else if !instruction_write_string(&builder, "\n\nAvailable skills are listed through skills.") {
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
