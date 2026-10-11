package agent

import "core:encoding/json"
import "core:time"

import "nabla:web"

// TOOL_PAGE_MAX_VALUE keeps the sum of a page offset and limit representable as int.
TOOL_PAGE_MAX_VALUE :: max(int) / 2

// Tool_Kind names what a tool's arguments are; it tells tool_args_decode how to read
// the document a call arrived as. Custom is the zero value for arguments the harness
// does not read itself, which the server validates.
Tool_Kind :: enum {
	Custom,
	Read,
	Write,
	Edit,
	Shell,
	Skills,
	Skill,
	Find,
	Grep,
	Compact,
	Codemode,
	MCP,
	Agent,
	Agents,
	Jobs,
	Web_Search,
	Web_Fetch,
}

// Tool_Args is one call's arguments, typed by the tool that will run it. Strings borrow
// the admitted document; an edit's files, hunks, and lines are allocated beside it and
// released by tool_args_destroy.
Tool_Args :: union {
	Read_Args,
	Write_Args,
	Edit_Args,
	Shell_Args,
	Skills_Args,
	Skill_Args,
	Find_Args,
	Grep_Args,
	Codemode_Args,
	Agent_Start_Args,
	Agent_Message_Args,
	Agent_Stop_Args,
	Agents_Args,
	Jobs_Args,
	Web_Search_Args,
	Web_Fetch_Args,
}

Read_Args :: struct {
	path:   string,
	offset: int,
	limit:  int,
}

Write_Args :: struct {
	path:    string,
	content: string,
}

Edit_Args :: struct {
	files: []Patch_File,
	hunks: []Patch_Hunk,
	lines: []Patch_Line,
}

Shell_Args :: struct {
	command:           string,
	working_directory: string, // "" means the workspace root
	timeout:           time.Duration,
	wait:              bool, // false runs the command in the background
}

Skills_Args :: struct {
	query:  string,
	offset: int,
	limit:  int,
}

Skill_Args :: struct {
	name: string,
}

// Codemode_Args is one Lua program. A zero timeout means none.
Codemode_Args :: struct {
	code:    string,
	timeout: time.Duration,
}

// Web_Search_Args is one search. query borrows the admitted document; the two domain
// lists are allocated beside it and released by tool_args_destroy.
Web_Search_Args :: struct {
	query:           string,
	provider:        Maybe(web.Provider),
	count:           int,
	freshness:       web.Freshness,
	include_domains: []string,
	exclude_domains: []string,
	timeout:         time.Duration,
}

// Web_Fetch_Args borrows url from the admitted document.
Web_Fetch_Args :: struct {
	url:     string,
	format:  web.Format,
	timeout: time.Duration,
}

// tool_args_decode reads one admitted document as the tool's own arguments. It is the
// only place a document becomes arguments, so tools, Lua child calls, and repaired
// calls all read the same way.
@(require_results)
tool_args_decode :: proc(ctx: ^Tool_Context, definition: Tool_Definition, object: json.Object) -> (Tool_Args, Tool_Argument_Error) {
	switch definition.kind {
	case .Read:
		return tool_read_args(ctx, object)
	case .Write:
		return tool_write_args(ctx, object)
	case .Edit:
		return tool_edit_args(ctx, object)
	case .Shell:
		return tool_shell_args(ctx, object)
	case .Skills:
		return tool_skills_args(ctx, object)
	case .Skill:
		return tool_skill_args(ctx, object)
	case .Find:
		return tool_find_args(ctx, object)
	case .Grep:
		return tool_grep_args(ctx, object)
	case .Compact:
		return nil, tool_fields_known(object, nil, allocator = ctx.allocator)
	case .Codemode:
		return tool_codemode_args(ctx, object)
	case .Agent:
		return tool_agent_args(ctx, object)
	case .Agents:
		return tool_agents_args(ctx, object)
	case .Jobs:
		return tool_jobs_args(ctx, object)
	case .Web_Fetch:
		return tool_web_fetch_args(ctx, object)
	case .Web_Search:
		return tool_web_search_args(ctx, object, (^Web_Search_Config)(definition.backend))
	case .Custom, .MCP:
		// The tool validates its own arguments, so none are handed over and the document
		// travels as admitted, with only its integer fields repaired from the schema.
		tool_fields_repair_integers(object, definition.integer_fields, &ctx.repairs, ctx.allocator)
		return nil, nil
	}
	return nil, nil
}

// tool_args_destroy releases what one typed call owns: the edit arrays, the search
// domain lists, and the find/grep root keys, which are the only parts of the union
// that are not borrowed.
tool_args_destroy :: proc(args: ^Tool_Args, allocator := context.allocator) {
	if edit, is_edit := &args.(Edit_Args); is_edit { patch_args_destroy(edit, allocator) }
	if search, is_search := &args.(Web_Search_Args); is_search {
		delete(search.include_domains, allocator)
		delete(search.exclude_domains, allocator)
	}
	if find, is_find := &args.(Find_Args); is_find { delete(find.root_key, allocator) }
	if grep, is_grep := &args.(Grep_Args); is_grep { delete(grep.root_key, allocator) }
	args^ = nil
}
