# To do

Open work found in reviews. Each item names where the problem lives and the simplest fix known so far. Remove an item when its change lands; move a decision into `docs/ARCHITECTURE.md` once it is made.

## Bugs

- Patch can partly apply. `tool_write_mode` (`agent/tool_files.odin`) maps a missing path to `.None`, and `patch_existing_mode` (`agent/tool_patch_apply.odin`) only treats `.Missing` as missing. A `Delete File` of a missing path passes preparation and fails during the write phase, after earlier files were written. Report `file_missing` during preparation for Delete and Update.
- Dropped allocation errors. `agent/tool_shell.odin` returns `strings.clone(...), nil`, discarding the allocator error. `agent/tool_patch.odin` reports an allocation failure as `.Too_Large`, blaming the model for a harness failure.

## Limits to verify or remove

Each limit stays only if a protocol, API, provider, model, or the OS imposes it, and then its comment names the source.

- `OPENAI_TOOL_SCHEMA_DEPTH = 16` (`ai/openai.odin`). Check against the OpenAI documentation; strict structured outputs document a nesting limit, which applies only when strict mode is used.
- `MAX_MESSAGE_DEPTH = 64` (`mcp/protocol.odin`), with the number repeated in its error text. Neither MCP nor JSON-RPC sets a depth; if the guard protects the recursive JSON parser from hostile input, say so in the comment.
- `db/error.odin` truncates backend messages to 128 bytes, against "report in full".
- `SUBAGENTS_MAX_RUNNING = 4` (`agent/subagent.odin`). Keep a cap, but make it a Lua configuration option with 4 as the default.
- Check that the provider error codes treated as retryable, repairable, or fatal match the providers' documentation.

## Subagents

A subagent is a session like any other: the orchestrator can bring it back, inspect it, compact it, switch its model, and continue it.

- Today a child closes when its inbox is empty and refuses later sends (`agent/subagent_test.odin` asserts the refusal). A failed child reports only `chat.last_error`; its partial answer and session id are lost.
- A finished subagent can stay usable as an ordinary conversation. We could let `agent_send` to a closed or failed child reopen its session through the existing claim and recovery path, with an optional `model` argument resolved like `agent_spawn`'s.
- A failure report should carry the cause, the last answer text, and the child session id.
- Liveness: the journal already records `request.sent`, `retry.scheduled`, and `provider.observed` per child. An `agent_send` acknowledgement can report the age and kind of the child's last record, so a stalled child is distinguishable from a slow one.
- An interrupted tool call can carry the output it produced so far. Writing shell streams to their kept file as they arrive would let recovery name that file in the `Unknown` result.

## Tool descriptions

Each description states what the tool does, why it exists, and how to use it, precisely.

- Code Mode: state the result shape. `output` is a table of the tool's fields: `output.content` for `builtin_read`, `output.stdout` and `output.stderr` for `builtin_shell`.
- Shell: say to create files with `builtin_write` instead of heredocs, and name common fish syntax differences. Replace "bounded stdout and stderr" with the kept output file, since output is never discarded.
- Patch: a hunk of only `-old` and `+new` lines is enough when the line is unique.
- Read: when a result is cut to the preview, the notice gives the shown line count and the next `offset`. The 2000-line default can exceed the preview size.
- `agent_spawn`: "provider not found" lists the configured providers, and the schema says which model id form is expected.

## Tests

- `scripts/test` has no test-name filter and no state logging. Add `--test <names>` (`ODIN_TEST_NAMES`) and `--log-state` (`ODIN_TEST_LOG_STATE_CHANGES`), and print a hint on timeout.
- Remove the duplicate flag parsing in `scripts/test` and the empty harness-package code in `scripts/_lib.sh`.

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
