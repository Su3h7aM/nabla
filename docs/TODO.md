# To do

Open work found in reviews. Each item names where the problem lives and the simplest fix known so far. Remove an item when its change lands; move a decision into `docs/ARCHITECTURE.md` once it is made.

## Limits and provider errors

Each limit stays only if a protocol, API, provider, model, or the OS imposes it, and then its comment names the source.

- If strict tool mode is added, apply OpenAI's strict-mode schema limits only when `strict` is sent.
- `core:encoding/json` gains a nesting-depth limit in the Odin fork. Once it lands, delete `mcp/json_admit.odin`'s pre-scan and `MAX_MESSAGE_DEPTH`, and use the parser's limit at every peer and provider parse site.

## Subagents

A subagent is a session like any other: the orchestrator can bring it back, inspect it, compact it, switch its model, and continue it.

- An interrupted tool call can carry the output it produced so far. Writing shell streams to their kept file as they arrive would let recovery name that file in the `Unknown` result.
