package agent

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"

import "nabla:agent/journal"

// A tool result is always kept whole, but the model is shown at most a preview of it. A
// result larger than the preview, or larger than the room the batch has left in the
// context, is written to a file under the session's output directory, and the model sees
// its beginning followed by a notice naming that file, which it reads with builtin_read.

// TOOL_RESULT_PREVIEW_BYTES is how much of one result the model is shown at once.
TOOL_RESULT_PREVIEW_BYTES :: 32 * 1024

// TOOL_RESULT_NOTICE_TOKENS is what the notice that replaces the rest of a result costs
// the model's context. The budget reserves it for every result still to come.
TOOL_RESULT_NOTICE_TOKENS :: 128

// TOOL_OUTPUT_DIRECTORY_NAME is the directory, inside the XDG state directory, that holds
// one directory of kept outputs per session.
TOOL_OUTPUT_DIRECTORY_NAME :: "tool-output"

// tool_result_cost estimates what one result puts into the model's context.
tool_result_cost :: proc(text: string) -> int {
	return len(text) / CHAT_CHARS_PER_TOKEN + CHAT_MESSAGE_OVERHEAD_TOKENS
}

// Tool_Budget is what one turn's tool results may add to the model's context. It is
// opened before the first result is recorded and taken in call order, reserving a notice
// for every result still to come, so one large result cannot crowd out the rest.
Tool_Budget :: struct {
	remaining: int, // tokens the batch may still add
	pending:   int, // results not yet recorded
}

// chat_tool_budget_open opens the budget for the batch the current response asked for.
// The projection is the request that produced the calls plus the response itself,
// because both are committed by the time the tools run. A session whose window is not
// known yet charges nothing, so only the preview size applies.
chat_tool_budget_open :: proc(chat: ^Chat_Session, count: int) -> Tool_Budget {
	if chat.capacity.window <= 0 { return {remaining = max(int) / 2, pending = count} }
	remaining := chat_capacity_input_ceiling(chat.capacity) - (chat.last_estimate + chat.response_cost)
	if remaining < 0 { remaining = 0 }
	return {remaining = remaining, pending = count}
}

// tool_budget_preview_bytes takes one result's turn from the budget and returns how many
// bytes of it the model may be shown: the preview size, lowered to what the room left
// after reserving a notice for every later result can hold.
tool_budget_preview_bytes :: proc(budget: ^Tool_Budget) -> int {
	if budget.pending > 0 { budget.pending -= 1 }
	allowance := budget.remaining - budget.pending * TOOL_RESULT_NOTICE_TOKENS - TOOL_RESULT_NOTICE_TOKENS
	return clamp(allowance, 0, TOOL_RESULT_PREVIEW_BYTES / CHAT_CHARS_PER_TOKEN) * CHAT_CHARS_PER_TOKEN
}

// tool_result_keep decides what the model is shown of a result. A result that fits is
// left as it is. Otherwise its whole content is written to path and replaced by its
// beginning and a notice naming the file. When the file cannot be written the content is
// left whole, because a result is never discarded. The budget is charged what the model
// is finally shown.
tool_result_keep :: proc(result: ^Tool_Result, budget: ^Tool_Budget, path: string) {
	defer budget.remaining -= tool_result_cost(result.content)
	shown := tool_budget_preview_bytes(budget)
	if len(result.content) <= shown || path == "" { return }

	if write_error := tool_output_write(path, result.content); write_error != nil {
		fields := [2]Log_Field{{key = "path", value = path}, {key = "error", value = os.error_string(write_error)}}
		log_emit({level = .Warning, category = .Tool, event = "tool.output_not_kept", fields = fields[:]})
		return
	}
	preview := tool_preview_cut(result.content, shown)
	notice := fmt.tprintf(
		"\n[output truncated: showing the first %d of %d bytes. The complete output is in %s; read the rest with %s.]\n",
		len(preview),
		len(result.content),
		path,
		TOOL_READ_NAME,
	)
	shortened, join_error := strings.concatenate({preview, notice}, result.allocator)
	if join_error != nil { return }
	delete(result.content, result.allocator)
	result.content = shortened
}

// tool_preview_cut returns the longest beginning of text within limit bytes that ends on
// a line break when one falls in its second half, and on a character boundary otherwise.
@(private)
tool_preview_cut :: proc(text: string, limit: int) -> string {
	if len(text) <= limit { return text }
	end := limit
	for end > 0 && !utf8.rune_start(text[end]) { end -= 1 }
	if newline := strings.last_index_byte(text[:end], '\n'); newline >= end / 2 { end = newline + 1 }
	return text[:end]
}

// tool_output_write writes one kept output, creating its directory, readable by its owner only.
@(private, require_results)
tool_output_write :: proc(path: string, content: string) -> os.Error {
	file := tool_output_create(path) or_return
	// The write's own result is the answer; a close that fails after it changes nothing.
	defer _ = os.close(file)
	_, write_error := os.write_string(file, content)
	return write_error
}

// tool_output_create creates one kept output file for writing, and its directory, readable
// by its owner only.
@(require_results)
tool_output_create :: proc(path: string) -> (^os.File, os.Error) {
	directory, _ := filepath.split(path)
	if make_error := os.make_directory_all(directory, XDG_APP_PERMISSIONS); make_error != nil && make_error != .Exist { return nil, make_error }
	return os.open(path, {.Write, .Create, .Trunc}, os.Permissions{.Read_User, .Write_User})
}

// tool_output_directory is where a session keeps the outputs it did not show in full:
// $XDG_STATE_HOME/nabla/tool-output/<session>, which outlives the process so a resumed
// session can still read them. It returns "" when no state directory resolves.
@(require_results)
tool_output_directory :: proc(id: string, allocator := context.allocator) -> string {
	state, state_error := xdg_directory(.State, context.temp_allocator)
	if state_error != .None { return "" }
	directory, join_error := filepath.join({state, TOOL_OUTPUT_DIRECTORY_NAME, id}, allocator)
	if join_error != nil { return "" }
	return directory
}

// chat_tool_output_path is the temp-allocated path that names the kept output of the call
// call, followed by suffix, or "" when the session has no output directory.
@(require_results)
chat_tool_output_path :: proc(chat: ^Chat_Session, call: journal.Call_Id, suffix := ".txt", allocator := context.temp_allocator) -> string {
	if chat.tool_output_directory == "" { return "" }
	path, join_error := filepath.join({chat.tool_output_directory, fmt.tprintf("%d%s", call, suffix)}, allocator)
	if join_error != nil { return "" }
	return path
}
