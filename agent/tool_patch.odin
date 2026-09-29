package agent

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"

TOOL_PATCH_NAME :: "builtin_patch"

TOOL_PATCH_DESCRIPTION :: `Apply a patch that adds, deletes, moves, or changes text files. Relative paths start at the session workspace, and absolute paths are used as given. The whole patch is checked before any file is written, so a patch that does not apply changes nothing.

*** Begin Patch
*** Add File: <path>
+<every line of the new file>
*** Delete File: <path>
*** Update File: <path>
*** Move to: <new path, optional>
@@ <optional: a line above the change, such as a function signature>
 <unchanged line>
-<removed line>
+<added line>
*** End of File <optional: the hunk ends at the end of the file>
*** End Patch

Each @@ starts a hunk. A hunk's unchanged and removed lines must match one place in the file, so include about three unchanged lines around each change. A hunk with only added lines goes after its @@ line, or at the end of the file. A unified diff is accepted too.`

TOOL_PATCH_SCHEMA :: `{"type":"object","properties":{"patch":{"type":"string","description":"The whole patch, from *** Begin Patch to *** End Patch."}},"required":["patch"],"additionalProperties":false}`

TOOL_PATCH_FIELDS :: []string{"patch"}

TOOL_PATCH_DEFINITION :: Tool_Definition {
	name = TOOL_PATCH_NAME,
	description = TOOL_PATCH_DESCRIPTION,
	input_schema = TOOL_PATCH_SCHEMA,
	hints = {read_only = .No, destructive = .Yes, idempotent = .No, open_world = .No},
	kind = .Patch,
	execute = tool_patch_execute,
}

Patch_Failure_Kind :: enum u8 {
	Invalid_Path,
	Repeated_Path,
	File_Missing,
	File_Exists,
	Not_Writable,
	Unreadable,
	Not_Found,
	Ambiguous,
	Overlap,
}

@(rodata, private = "file")
PATCH_FAILURE_NAMES := [Patch_Failure_Kind]string {
	.Invalid_Path  = "invalid_path",
	.Repeated_Path = "repeated_path",
	.File_Missing  = "file_missing",
	.File_Exists   = "file_exists",
	.Not_Writable  = "not_writable",
	.Unreadable    = "unreadable",
	.Not_Found     = "not_found",
	.Ambiguous     = "ambiguous",
	.Overlap       = "overlap",
}

// Patch_Failure is why a patch does not apply. message names the file and, for a hunk, its
// number and the nearest lines, so the model can correct the patch without rereading the file.
Patch_Failure :: struct {
	kind:    Patch_Failure_Kind,
	message: string,
}

Patch_Error :: union {
	Patch_Failure,
	mem.Allocator_Error,
}

@(require_results)
tool_patch_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Patch_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_PATCH_FIELDS, allocator = ctx.allocator) or_return
	patch := tool_field_string(arguments, "patch", allocator = ctx.allocator) or_return
	parsed, problem, allocation_error := patch_parse(patch, ctx.allocator)
	if allocation_error != nil { return {}, tool_argument_error(.Too_Large, "patch", "a patch that fits in memory", ctx.allocator) }
	if problem != "" { return {}, tool_argument_error(.Invalid_Value, "patch", problem, ctx.allocator) }
	return parsed, nil
}

@(require_results)
tool_patch_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(Patch_Args)
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { return patch_failure_result(ctx, arena_error) }
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)

	changes, summary, repaired_hunks, prepare_error := patch_prepare(ctx.workspace, args, scratch)
	if prepare_error != nil { return patch_failure_result(ctx, prepare_error) }

	for change, index in changes {
		write_error, cancelled, target_written := patch_write(change, ctx.control, scratch)
		if !cancelled && write_error == nil { continue }
		applied_files := index
		if target_written { applied_files += 1 }
		applied := Patch_Output {
			files   = applied_files,
			summary = summary[:changes[applied_files - 1].summary_end] if applied_files > 0 else "",
		}
		applied_note := "; the files listed were already changed" if index > 0 else ""
		if cancelled { return tool_result_of(ctx, .Cancelled, fmt.tprintf("the patch was cancelled%s", applied_note), applied, "cancelled") }
		if target_written {
			prior_summary := summary[:changes[index - 1].summary_end] if index > 0 else ""
			applied.summary = fmt.aprintf("%swrote %s; could not remove source %s\n", prior_summary, change.target, change.source, allocator = scratch)
			message := fmt.tprintf(
				"wrote destination %s but could not remove source %s: %s%s",
				change.target,
				change.source,
				os.error_string(write_error),
				applied_note,
			)
			return tool_result_of(ctx, .Tool_Failed, message, applied, "write failed")
		}
		message := fmt.tprintf("could not write %s: %s%s", args.files[index].path, os.error_string(write_error), applied_note)
		return tool_result_of(ctx, .Tool_Failed, message, applied, "write failed")
	}
	output := Patch_Output {
		files                     = len(changes),
		whitespace_repaired_hunks = repaired_hunks,
		summary                   = summary,
	}
	return tool_result_success(ctx, output, fmt.tprintf("%d files", len(changes)))
}

@(private = "file", require_results)
patch_failure_result :: proc(ctx: ^Tool_Context, err: Patch_Error) -> Tool_Result {
	switch failure in err {
	case Patch_Failure:
		return tool_result_failure(ctx, .Tool_Failed, failure.message, PATCH_FAILURE_NAMES[failure.kind])
	case mem.Allocator_Error:
	}
	return tool_result_failure(ctx, .Tool_Failed, "there was not enough memory to prepare the patch", "out of memory")
}

// patch_write applies one prepared change. A moved file is written at its new path before the
// old one is removed, so a failure between the two leaves both rather than neither.
@(private = "file", require_results)
patch_write :: proc(change: Patch_Change, control: Tool_Control, allocator: mem.Allocator) -> (write_error: os.Error, cancelled: bool, target_written: bool) {
	if tool_control_cancelled(control) { return nil, true, false }
	if change.operation == .Delete { return os.remove(change.source), false, false }

	directory, _ := os.split_path(change.target)
	if directory != "" {
		if directory_error := os.make_directory_all(directory);
		   directory_error != nil && directory_error != os.General_Error.Exist { return directory_error, false, false }
	}
	write_error, cancelled = tool_write_atomic(change.target, change.content, change.mode, allocator, control)
	if write_error != nil || cancelled { return }
	target_written = true
	if change.target == change.source { return }
	return os.remove(change.source), false, true
}
