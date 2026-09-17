package agent

import "core:encoding/json"
import "core:fmt"
import "core:unicode/utf8"

import "nabla:agent/session"

// context.read_result reads back a tool result the model was shown only a handle
// for. A result is kept when the turn's results as a whole did not fit the room the
// context had left, and it stays in the record in full, so this is the only way the
// model sees that output. It never changes the record, and it answers the same bytes
// every time.
//
// The window into the output is a byte range rather than a line range: a stored
// result is not a file and the model is given its size, so an offset is the one thing
// both sides can agree on.

TOOL_RESULT_READ_DESCRIPTION :: "Read a tool result that was kept in the session instead of being shown in full. Use the call_seq from the handle that replaced the output. Returns at most 4096 bytes from the given offset, with the next offset and whether the end was reached."

TOOL_RESULT_READ_MAX_BYTES :: 4096

TOOL_RESULT_READ_SCHEMA :: `{"type":"object","properties":{"call_seq":{"type":"integer","description":"the call_seq named by the handle that replaced the output"},"offset":{"type":"integer","description":"byte offset into the kept output, starting at 0"},"limit":{"type":"integer","description":"how many bytes to return, at most 4096"}},"required":["call_seq"],"additionalProperties":false}`

TOOL_RESULT_READ_DEFINITION :: Tool_Definition {
	name = TOOL_RESULT_READ_NAME,
	description = TOOL_RESULT_READ_DESCRIPTION,
	input_schema = TOOL_RESULT_READ_SCHEMA,
	hints = {read_only = .Yes, destructive = .No, idempotent = .Yes, open_world = .No},
	execute = tool_result_read_execute,
}

@(private)
TOOL_RESULT_READ_FIELDS := []string{"call_seq", "offset", "limit"}

// Tool_Result_Read_Args is the read tool's own view of a call. The defaults live here
// rather than at the call site, so the schema and the executor agree.
Tool_Result_Read_Args :: struct {
	call_seq: int,
	offset:   int,
	limit:    int,
}

// Tool_Result_Read_Page is what one read returns: the bytes, where the next read
// starts, and whether this read reached the end. bytes is the whole kept result, so
// the model can tell how much there is without reading it all.
Tool_Result_Read_Page :: struct {
	text:        string `json:"text"`,
	next_offset: int `json:"next_offset"`,
	eof:         bool `json:"eof"`,
	bytes:       int `json:"bytes"`,
}

@(private)
tool_result_read_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (Tool_Result_Read_Args, Tool_Argument_Error) {
	if known_error := tool_fields_known(arguments, TOOL_RESULT_READ_FIELDS, allocator = ctx.allocator); known_error.kind != .None { return {}, known_error }
	call_seq, call_seq_error := tool_field_int(arguments, "call_seq", 1, max(int), allocator = ctx.allocator)
	if call_seq_error.kind != .None { return {}, call_seq_error }
	offset, offset_error := tool_field_optional_int(arguments, "offset", 0, 0, max(int), allocator = ctx.allocator)
	if offset_error.kind != .None { return {}, offset_error }
	limit, limit_error := tool_field_optional_int(arguments, "limit", TOOL_RESULT_READ_MAX_BYTES, 1, TOOL_RESULT_READ_MAX_BYTES, allocator = ctx.allocator)
	if limit_error.kind != .None { return {}, limit_error }
	return Tool_Result_Read_Args{call_seq = call_seq, offset = offset, limit = limit}, {}
}

// tool_result_read_page slices one page out of a kept result. It walks the end back to
// a character boundary, because half a character is not a string the encoder can send.
tool_result_read_page :: proc(content: string, offset, limit: int) -> Tool_Result_Read_Page {
	total := len(content)
	if offset >= total { return {next_offset = total, eof = true, bytes = total} }
	end := min(offset + limit, total)
	for end > offset && end < total && !utf8.rune_start(content[end]) { end -= 1 }
	return {text = content[offset:end], next_offset = end, eof = end >= total, bytes = total}
}

tool_result_read_execute :: proc(ctx: ^Tool_Context, arguments: json.Object) -> Tool_Result {
	args, args_error := tool_result_read_args(ctx, arguments)
	defer if args_error.kind != .None { tool_argument_error_destroy(&args_error, ctx.allocator) }
	if args_error.kind != .None { return tool_result_refused(ctx, &args_error) }
	if ctx.results == nil { return tool_result_failure(ctx, .Unavailable, "tool results cannot be read in this session", "unavailable") }

	entry, found, read_err := session.tool_result_read(ctx.results.store, ctx.results.session_id, session.Seq(args.call_seq), ctx.allocator)
	if read_err != nil {
		local := read_err
		return tool_result_failure(ctx, .Tool_Failed, fmt.tprintf("the stored result could not be read: %s", session.error_detail(&local)), "read failed")
	}
	defer {
		local := entry
		session.entry_destroy(&local, ctx.allocator)
	}
	if !found {
		return tool_result_failure(ctx, .Invalid_Arguments, fmt.tprintf("no tool result is stored for call %d", args.call_seq), "no such result")
	}
	payload, is_result := entry.payload.(session.Tool_Result_Entry)
	if !is_result { return tool_result_failure(ctx, .Tool_Failed, "the stored entry is not a tool result", "malformed") }
	if args.offset > len(payload.content) {
		return tool_result_failure(
			ctx,
			.Invalid_Arguments,
			fmt.tprintf("offset %d is past the end of the %d-byte result", args.offset, len(payload.content)),
			"offset past end",
		)
	}

	page := tool_result_read_page(payload.content, args.offset, args.limit)
	return tool_result_success(ctx, page, fmt.tprintf("%d bytes at offset %d", len(page.text), args.offset))
}

// tool_result_cost estimates what one result puts into the model's context, whether
// that is the content or the handle that replaces it. One estimate serves both, so a
// batch is charged the same way it was reserved.
tool_result_cost :: proc(text: string) -> int {
	return len(text) / CHAT_CHARS_PER_TOKEN + CHAT_MESSAGE_OVERHEAD_TOKENS
}

// Tool_Budget is what one turn's tool results may add to the model's context.
//
// The batch is bounded as a whole, because one large result must not crowd out the
// rest and because the sum is what makes the next request unsendable. The budget is
// opened before the first result is recorded and never revised: each result is offered
// the room left after a handle is set aside for every result still to come, so a result
// that fits keeps its content and one that does not is spilled. Deciding once is what
// keeps the projection stable, because a request built from these entries sends the
// same bytes however much the context grows afterwards.
Tool_Budget :: struct {
	remaining: int, // tokens the batch may still add
	pending:   int, // results not yet recorded
}

// chat_tool_budget opens the budget for the batch the current response asked for. The
// projection is the request that produced the calls plus the response itself, because both
// are committed by the time the tools run.
//
// The wall is the hard ceiling rather than the compaction trigger: the trigger exists to
// start background work, not to stop the agent from using the window it has.
chat_tool_budget_open :: proc(chat: ^Chat_Session, count: int) -> Tool_Budget {
	remaining := chat_capacity_input_ceiling(chat.capacity) - (chat.last_estimate + chat.response_cost)
	if remaining < 0 { remaining = 0 }
	return {remaining = remaining, pending = count}
}

// tool_budget_take offers one result its share and reports whether it may keep its
// content. A spilled result still costs a handle, so the budget is charged either way.
// It can go negative when even handles do not fit, and the next request then fails
// admission, which is the honest report that the context is full.
tool_budget_take :: proc(budget: ^Tool_Budget, content: string) -> bool {
	if budget.pending > 0 { budget.pending -= 1 }
	allowance := budget.remaining - budget.pending * TOOL_RESULT_HANDLE_TOKENS
	if cost := tool_result_cost(content); cost <= allowance {
		budget.remaining -= cost
		return true
	}
	budget.remaining -= TOOL_RESULT_HANDLE_TOKENS
	return false
}

// Result_Reader is what a tool needs to read a stored result back. It is the store and
// the session and nothing else, because a kept result stays where it was recorded. It
// is borrowed by one execution and lives as long as the session.
Result_Reader :: struct {
	store:      ^session.Store,
	session_id: session.Session_Id,
}
