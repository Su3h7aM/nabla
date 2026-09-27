package agent

import "core:encoding/json"
import "core:time"

// Tool_Kind names what a tool's arguments are, which is what tells the one reader in
// tool_args_decode how to read the document a call arrived as. Custom is the zero value: a
// definition whose arguments the harness does not read itself, such as an MCP tool, whose
// arguments the server validates.
Tool_Kind :: enum {
	Custom,
	Read,
	Write,
	Patch,
	Shell,
	List_Skills,
	Load_Skill,
	Compact,
	Codemode,
	MCP,
}

// Tool_Args is one call's arguments, typed by the tool that will run it. A tool sees these
// fields; the document they were read from stays with the call's record.
//
// Strings borrow the admitted document, so they live exactly as long as the job that owns it;
// a patch's files, hunks, and lines are allocated beside it and released by tool_args_destroy.
Tool_Args :: union {
	Read_Args,
	Write_Args,
	Patch_Args,
	Shell_Args,
	List_Skills_Args,
	Load_Skill_Args,
	Codemode_Args,
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

Patch_Args :: struct {
	files: []Patch_File,
	hunks: []Patch_Hunk,
	lines: []Patch_Line,
}

Shell_Args :: struct {
	command:           string,
	working_directory: string, // "" means the workspace root
	timeout:           time.Duration,
}

List_Skills_Args :: struct {
	query:  string,
	offset: int,
	limit:  int,
}

Load_Skill_Args :: struct {
	name: string,
}

// Codemode_Args is one Lua program. A zero timeout means none.
Codemode_Args :: struct {
	code:    string,
	timeout: time.Duration,
}

// tool_args_decode reads one admitted document as the tool's own arguments, refusing a call
// whose fields do not match what the tool declares. It is the only place a document becomes
// arguments, so a tool, a Lua child call, and a repaired call all read the same way.
tool_args_decode :: proc(ctx: ^Tool_Context, definition: Tool_Definition, object: json.Object) -> (Tool_Args, Tool_Argument_Error) {
	switch definition.kind {
	case .Read:
		return tool_read_args(ctx, object)
	case .Write:
		return tool_write_args(ctx, object)
	case .Patch:
		return tool_patch_args(ctx, object)
	case .Shell:
		return tool_shell_args(ctx, object)
	case .List_Skills:
		return tool_list_skills_args(ctx, object)
	case .Load_Skill:
		return tool_load_skill_args(ctx, object)
	case .Compact:
		return nil, tool_fields_known(object, nil, allocator = ctx.allocator)
	case .Codemode:
		return tool_codemode_args(ctx, object)
	case .Custom, .MCP:
		// The tool validates its own arguments, so none are handed over and the document
		// travels as admitted, with only its integer fields repaired from the schema.
		tool_fields_repair_integers(object, definition.integer_fields, &ctx.repairs, ctx.allocator)
		return nil, nil
	}
	return nil, nil
}

// tool_args_destroy releases what one typed call owns: the patch arrays, which are the only
// part of the union that is not borrowed.
tool_args_destroy :: proc(args: ^Tool_Args, allocator := context.allocator) {
	if patch, is_patch := &args.(Patch_Args); is_patch { patch_args_destroy(patch, allocator) }
	args^ = nil
}
