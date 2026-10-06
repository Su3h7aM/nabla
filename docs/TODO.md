# To do

Open work found in reviews. Each item names where the problem lives and the simplest fix known so far. Remove an item when its change lands; move a decision into `docs/ARCHITECTURE.md` once it is made.

## Limits and provider errors

Each limit stays only if a protocol, API, provider, model, or the OS imposes it, and then its comment names the source.

- If strict tool mode is added, apply OpenAI's strict-mode schema limits only when `strict` is sent.
- `core:encoding/json` gains a nesting-depth limit in the Odin fork. Once it lands, delete `mcp/json_admit.odin`'s pre-scan and `MAX_MESSAGE_DEPTH`, and use the parser's limit at every peer and provider parse site.

Provider error classification mostly matches the Anthropic and OpenAI documentation. Open points:

- OpenRouter can turn a Responses API context overflow into a successful `finish_reason: "length"`, which is not classified as overflow.

## Subagents

A subagent is a session like any other: the orchestrator can bring it back, inspect it, compact it, switch its model, and continue it.

- The live compaction test installs the summary only if the child makes more requests after compaction starts.
- An interrupted tool call can carry the output it produced so far. Writing shell streams to their kept file as they arrive would let recovery name that file in the `Unknown` result.

## Simplifications

- Process spawning is written three times: `mcp/stdio_process*`, `agent/tool_process*`, and `agent/subagent_acp_linux.odin`. A small `process` library package would remove about 350 lines. Needs a decision because it adds a package.

## Architecture document drift

- §14.1 lists tool kinds, placements, `Tool_Definition` fields, and tool names that no longer match `agent/tool_args.odin` and `agent/tool.odin` (`agent_send`, `agent_stop`, `builtin_list_skills`, `builtin_load_skill`; no `Task_Run`).
