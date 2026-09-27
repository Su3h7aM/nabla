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
	Result_Read,
	Compact,
	Code,
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
	Result_Read_Args,
	Code_Args,
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

Result_Read_Args :: struct {
	call_seq: int,
	offset:   int,
	limit:    int,
}

Code_Args :: struct {
	code: string,
}

// tool_args_decode reads one admitted document as the tool's own arguments, refusing a call
// whose fields do not match what the tool declares. It is the only place a document becomes
// arguments, so a tool, a Lua child call, and a repaired call all read the same way.
tool_args_decode :: proc(ctx: ^Tool_Context, kind: Tool_Kind, object: json.Object) -> (Tool_Args, Tool_Argument_Error) {
	switch kind {
	case .Read:
		args, err := tool_read_args(ctx, object)
		return args, err
	case .Write:
		args, err := tool_write_args(ctx, object)
		return args, err
	case .Patch:
		args, err := tool_patch_args(ctx, object)
		return args, err
	case .Shell:
		args, err := tool_shell_args(ctx, object)
		return args, err
	case .List_Skills:
		args, err := tool_list_skills_args(ctx, object)
		return args, err
	case .Load_Skill:
		args, err := tool_load_skill_args(ctx, object)
		return args, err
	case .Result_Read:
		args, err := tool_result_read_args(ctx, object)
		return args, err
	case .Compact:
		return nil, tool_fields_known(object, nil, allocator = ctx.allocator)
	case .Code:
		if error := tool_fields_known(object, TOOL_CODE_FIELDS, allocator = ctx.allocator); error.kind != .None { return nil, error }
		code, code_error := tool_field_string(object, "code", allocator = ctx.allocator)
		return Code_Args{code = code}, code_error
	case .Custom:
		// The harness does not know what this tool's arguments are, so it hands none over.
		return nil, {}
	case .MCP:
		// An MCP server validates its own tool's arguments, so their document travels to the
		// server as it arrived rather than through a reader here.
		return nil, {}
	}
	return nil, {}
}

// tool_args_destroy releases what one typed call owns: the patch arrays, which are the only
// part of the union that is not borrowed.
tool_args_destroy :: proc(args: ^Tool_Args, allocator := context.allocator) {
	if patch, is_patch := &args.(Patch_Args); is_patch { patch_args_destroy(patch, allocator) }
	args^ = nil
}
