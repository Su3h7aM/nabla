# To do

Open work found in reviews. Each item names where the problem lives and the simplest fix known so far. Remove an item when its change lands; move a decision into `docs/ARCHITECTURE.md` once it is made.

## Limits and provider errors

Each limit stays only if a protocol, API, provider, model, or the OS imposes it, and then its comment names the source.

- If strict tool mode is added, apply OpenAI's strict-mode schema limits only when `strict` is sent.
- The same unbounded recursion is unguarded where provider and ACP input is parsed: `acp/protocol.odin`, `ai/anthropic.odin`, `ai/openai_chat.odin`, `ai/openai_responses.odin`, `ai/classify.odin`, `ai/encode.odin` (tool schemas), `mcp/tools.odin`. `mcp/json_admit.odin` already guards MCP messages with `MAX_MESSAGE_DEPTH`. One shared guard, or an iterative parse, would cover all of them.

Provider error classification mostly matches the Anthropic and OpenAI documentation. Open points:

- After a `model_context_window_exceeded` stop the summary runs in the background; if admission refuses the next request while it runs, the turn fails instead of waiting for it. `chat_request_begin` (`agent/chat_chain.odin`) should wait on the running summary, as `chat_chain_repair` does for `Summary_Running`.
- `chat_compact_reason` (`agent/compact.odin`) reports a summarizer that filled the window as "produced no summary".
- OpenRouter can turn a Responses API context overflow into a successful `finish_reason: "length"`, which is not classified as overflow.

## Subagents

A subagent is a session like any other: the orchestrator can bring it back, inspect it, compact it, switch its model, and continue it.

- Remaining recovery steps: `compact` on `agent_send` (step 5), `agent_status` and status acknowledgements (step 6), ACP status and resume through `session/resume` (step 7). Effort on resume has no test yet.
- Liveness: the journal already records `request.sent`, `retry.scheduled`, and `provider.observed` per child. An `agent_send` acknowledgement can report the age and kind of the child's last record, so a stalled child is distinguishable from a slow one.
- An interrupted tool call can carry the output it produced so far. Writing shell streams to their kept file as they arrive would let recovery name that file in the `Unknown` result.

## Tool descriptions

- The read and write descriptions state the 32 KiB preview as a literal; build them from `TOOL_RESULT_PREVIEW_BYTES` as the shell description does.
- Patch parsing: a mistyped header such as `*** Updat File:` inside a section becomes hunk content instead of an error naming the line.
- A literal replace with an expected match count is reported three times (Lua patterns need escaping, the patch tool matches whole lines). Decide where it belongs: a Code Mode helper or a substring form of the patch tool.

## Simplifications

- Process spawning is written three times: `mcp/stdio_process*`, `agent/tool_process*`, and `agent/subagent_acp_linux.odin`. A small `process` library package would remove about 350 lines. Needs a decision because it adds a package.
- Clone-and-check ladders (`x, clone_error = strings.clone(...)`, then `if clone_error != nil`) repeat in `subagent.odin`, `model_selection.odin`, `subagent_acp.odin`, `chat_instructions.odin`, `instructions.odin`, `config_mcp.odin`, `tool_skills.odin`. Return `mem.Allocator_Error` and use `or_return`; clone multi-field values into an owning arena so destroy is one call.
- `tool_drain_pipes` (`agent/tool_process.odin`) has six copies of the same exit sequence. Break out of the loop and clean up once.
- `tool_spawn_shell_flags` always returns a nil second flag and reimplements `os.base`.
- `tool_shell_finish` only forwards to `tool_result_of`. The background-terminated message is built three times.
- `agent_team_make` unwinds two dynamic arrays that could grow lazily.
- `agent/tool_agent.odin`: `fmt.tprintf("%s", x)` used as a clone; the same `member` and `agents` checks in three executors; one literal error repeated three times.
- `tool_line_count` reimplements `strings.count`. `tool_write_atomic` repeats `os.close` on every error path. `patch_apply` repeats the update-and-count step in two cases.
- A spool open failure in `tool_stream_write` falls back to memory on purpose; add a comment saying why.

## Naming

- Acronyms in type names: `Acp_Server`, `Mcp_Server`, `Mcp_Environment` beside `ACP_Agent_Config`, `MCP_Runtime`. Use the uppercase form, as `core:net` does with `TCP_Socket`.
- `acp_serve.odin` and `acp_server.odin` differ by one letter; name them for their subjects.
- Name the repeated `max(int) / 2` literal.
- Use `sync.mutex_guard` where a lock covers a scoped block in `subagent.odin`.

## Architecture document drift

- §14.1 lists tool kinds, placements, `Tool_Definition` fields, and tool names that no longer match `agent/tool_args.odin` and `agent/tool.odin` (`agent_send`, `agent_stop`, `builtin_list_skills`, `builtin_load_skill`; no `Task_Run`).
- §27 constant names differ from the code (`TOOL_KILL_GRACE`, `CHAT_COMPACT_KEEP_MESSAGES`), about ten listed constants do not exist yet without saying so, and several code constants are missing.
