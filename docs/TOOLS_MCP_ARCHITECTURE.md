# Tool and MCP architecture

This records why the harness tool system is shaped the way it is. It is the
design record for `agent/tool*.odin`, `agent/session`, and `mcp`. Read the code
first; this document only carries the reasoning that the code cannot.

## Why

Nabla originally shipped one tool, `shell`, and the tool system was the shell
tool. Argument reading, result encoding, error taxonomy, dispatch, and the
system prompt all named shell fields directly. Adding a second tool meant
editing dispatch, the request builder, result rendering, and the storage
vocabulary.

The goal is one tool system with four exposed tools (`shell`, `read`, `write`,
`edit`) and MCP servers as a second source of the same kind of tool. Adding a
tool should mean writing one declaration and one procedure.

## What we keep

Nabla already had the parts that are hard to retrofit:

- Durable intent before execution. The harness records a dispatch entry before
  a tool runs, so an interrupted call is legible as an unknown outcome rather
  than a guess.
- A single state machine (`Chat_State`) with the driver owning every durable
  write. Tools never touch the store.
- Faithful replay. Raw model arguments stay in the call entry; the arguments a
  call actually ran with live in the dispatch entry; results are stored as the
  exact text later sent to the model.
- A controlled `shell`: fresh process group, closed stdin, fixed environment,
  concurrent pipe draining, group termination, no allocation in the forked
  child.

None of that changes. The work generalizes the shell-shaped parts around it.

## What we do not build

Code Mode, an embedded interpreter, plugin loading, parallel tool execution,
background jobs, PTYs, a permission language, and MCP resources, prompts,
subscriptions, Apps, or Tasks. If a later need appears, it appears with a real
case attached.

## The tool contract

A tool is data plus one procedure.

`Tool_Definition` carries the provider-visible name, description, and input
schema bytes; behavior hints; a default and maximum timeout; the execute
procedure; and a borrowed backend binding.

`Tool_Execute` has one signature for every tool:

```odin
Tool_Execute :: #type proc(ctx: ^Tool_Context, arguments: json.Object) -> Tool_Result
```

There is no separate prepare step and no erased per-tool argument state. The
procedure reads its own fields with the shared helpers, which validate types and
ranges and produce deterministic diagnostics. A tool that returns
`Invalid_Arguments` has performed no effect; that is the contract dispatch
relies on when it decides a call did not run.

This deliberately avoids the crate of hooks, typed codecs, and adapter traits
the reference harnesses carry. Four tools do not need a plugin boundary.

## Registry and lifetime

`Tool_Registry` owns a flat array of definitions, built before the first turn.
It is not mutated while a turn runs, so a turn borrows it. A collision between
two definitions is a configuration error, never a last-wins resolution.

MCP tools enter the same registry through an adapter. A refresh happens between
turns, so a running response always dispatches against the definitions it was
advertised with.

## Dispatch

The pipeline is fixed and lives in `chat_run_tools`:

1. Admit the response batch (identities, duplicate call ids, budget).
2. Commit the assistant response and the raw calls.
3. Resolve the call name against the registry.
4. Prepare the argument bytes: size, syntax, object root, duplicate keys, then
   one deterministic repair for raw control bytes inside string literals.
5. Write the dispatch entry with the effective arguments.
6. Execute once, unless cancellation already landed.
7. Normalize and bound the result.
8. Write the result entry.
9. Report to the observer and continue in assistant source order.

A durable write failure stops the turn. Nothing runs after a dispatch record
failed to land, and no result is continued from memory.

## Results

One envelope shape for every tool:

```json
{"status": "success", "message": "", "data": {...}}
```

`data` is the tool's own shape, so `shell` carries stdout, stderr, exit code,
and truncation flags, while `edit` carries the paths it rewrote. A refusal
carries the argument diagnostic in `data` and explains itself in `message`.

The outcome vocabulary is persisted, so it is the contract:

| Outcome | Meaning |
| --- | --- |
| `Success` | The tool ran and reported success. |
| `Tool_Failed` | The tool ran and reported failure. A nonzero exit is this. |
| `Invalid_Arguments` | Refused before any effect. |
| `Unavailable` | Not registered for this request, or its backend is down. |
| `Timed_Out` | Bounded and stopped locally. |
| `Cancelled` | Stopped because the turn was. |
| `Not_Executed` | Recorded, never started. |
| `Unknown` | It may have run; the harness could not observe the end. |
| `Transport_Failed` | The link failed before the request was delivered. |

There is no separate "execution knowledge" field. The outcome already carries
the distinction: `Invalid_Arguments`, `Unavailable`, `Not_Executed`, and
`Transport_Failed` mean nothing ran, and `Unknown` means the harness does not
know. A second field would restate the first.

## Arguments

Structural admission is shared: byte budget, complete JSON, object root,
duplicate keys at every depth, and a nesting bound. Duplicate keys are refused
rather than resolved because the harness will not choose which of two values the
model meant.

One repair exists: raw control bytes inside otherwise unambiguous JSON string
literals become their escape sequences. The repaired document is re-read in
full. Nothing else is rewritten and no value is invented. In particular the
harness does not guess tool names, drop unknown fields, coerce strings into
numbers, or unwrap argument wrappers.

Field reading is per tool through shared helpers (`tool_args_string`,
`tool_args_int`, `tool_args_optional_int`, `tool_args_array`), each of which
checks presence, type, and range and names the constraint it enforced. Known
field names are declared next to the reader, so an unknown field is reported
with the accepted set.

Schema documents are advertised as bytes, not interpreted by a general JSON
Schema engine. MCP schemas come from outside, so the MCP adapter validates what
it can and refuses a tool whose schema it cannot bound rather than admitting it
unchecked.

## Output

Model-visible content is bounded to 64 KiB of valid JSON. Shell output is
previewed from the tail, spilled to a private file under the session directory,
and reports when even the spill was incomplete, so a long build is recoverable
instead of lost. Draining continues after the preview limit so the child never
blocks on a full pipe.

## Shell

`shell` is not a terminal, a background-job service, or a sandbox.

- `/bin/sh -c` in a fresh process group, stdin closed.
- The launch environment is captured once, with configured secrets removed, and
  frozen. It is not the process environment and it is not mutated per call.
- A close-on-exec setup pipe distinguishes a spawn failure from a command that
  genuinely exited 127.
- Cancellation and timeout are distinct, and cancel wins when both apply.
- Group termination escalates from `SIGTERM` to `SIGKILL`.
- Descendants holding output pipes get a bounded drain before cleanup.

Relative paths start at the session workspace. Absolute paths are used as given,
and relative paths may walk outside the workspace. The tool system is not a
sandbox. A permission system is a separate project.

## MCP

MCP is an independent client library. It imports nothing from `agent`, `ai`, or
the presentation stack, and the adapter in `agent` maps its definitions and
results into the same tool contract.

Only protocol version `2026-07-28` is implemented. It has no handshake and no
protocol session:

- Every request declares its version and client capabilities in `params._meta`.
- `server/discover` reports supported versions, capabilities, and identity.
- Streamable HTTP is one POST per request, answered with JSON or a
  request-scoped SSE stream. `MCP-Protocol-Version`, `Mcp-Method`, and
  `Mcp-Name` headers are required, and `x-mcp-header` parameters are mirrored.
- `resultType: "input_required"` carries server-to-client input requests.

Stateless describes request routing, not effects. A `tools/call` is never
automatically retried, including after a lost connection, because the server may
have performed the action before the reply was lost. That case is `Unknown`.

Server configuration is explicit user configuration in `config.lua`: a stable
server id, a trust decision, a transport, credentials, a tool allowlist, and
timeouts. Nothing auto-executes repository-provided MCP configuration.

Supported at first: stdio, and Streamable HTTP with explicitly supplied
endpoint-bound credentials. No OAuth flow, no legacy transport, no fallback
handshake. A `2026-07-28` server that is not understood gets an actionable
diagnostic.

## Prompt stability

Tool definitions are sorted and serialized deterministically so the cacheable
prefix does not churn. Descriptions and schemas are frozen within a response.
Connection state, request ids, timestamps, and credentials never enter a
description. Request records store the actual prepared inventory rather than
reconstructing it. Session tips are not taken from a server: MCP instructions
are untrusted external text.

## Packages

| Package | Responsibility |
| --- | --- |
| `agent` | Tool contract, registry, dispatch, native tools, MCP adapter |
| `agent/session` | Durable call, dispatch, result, and recovery records |
| `mcp` | MCP messages, discovery, tools, transports, errors |
| `http/client`, `sse` | HTTP and event-stream transport |
| `ai` | Provider tool definitions and response assembly |
| root `nabla` | Configuration, runtime ownership, presentation |
