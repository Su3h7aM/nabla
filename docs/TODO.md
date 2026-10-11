# To do

Open work found in reviews. Each item names where the problem lives and the simplest fix known so far. Remove an item when its change lands; move a decision into `docs/ARCHITECTURE.md` once it is made.

## Limits and provider errors

Each limit stays only if a protocol, API, provider, model, or the OS imposes it, and then its comment names the source.

- If strict tool mode is added, apply OpenAI's strict-mode schema limits only when `strict` is sent.
- `core:encoding/json` gains a nesting-depth limit in the Odin fork. Once it lands, delete `mcp/json_admit.odin`'s pre-scan and `MAX_MESSAGE_DEPTH`, and use the parser's limit at every peer and provider parse site.

## Subagents

A subagent is a session like any other: the orchestrator can bring it back, inspect it, compact it, switch its model, and continue it.


## Ownership

- `session_install` (`app_session.odin`) destroys `setup.session` and then initializes a new session in the same `Chat_Session` memory, even when `chat_session_workers_outstanding` says an abandoned worker may still read that session's stop tokens or catalog. Hold the session by pointer in `Run_Setup`, so a switch leaves a retained session allocated and installs a new one, as `subagent_run` already does for a child.

## MCP background calls

- MCP defines background tool calls as Tasks, in two incompatible shapes: an experimental core feature in 2025-11-25 (a `task` field on `tools/call`, per-tool `execution.taskSupport`, `tasks/get`, a blocking `tasks/result`, `tasks/cancel`) and the `io.modelcontextprotocol/tasks` extension in 2026-07-28 (the server decides per request, `tasks/get` polling with `pollIntervalMs`, `tasks/update` for input, no `tasks/result`). The `mcp` package is stdio only with one request in flight per client, declares no task capability, and would reject a task result. Supporting Tasks needs a client that can hold a task while other calls run, both shapes or a decision to support only the current one, and a ruling on whether waiting out a server's poll interval counts as a deadline rather than a polling timer. Few servers support Tasks yet; revisit when they do.
