# Tool and MCP architecture

This records why the harness tool system is shaped the way it is. It is the
design record for `agent/tool*.odin`, `agent/session`, and `mcp`. Read the code
first; this document only carries the reasoning that the code cannot.

The implemented tool path described here is synchronous. The proposed
[Lua Code Mode and asynchronous tool execution](CODE_MODE_ARCHITECTURE.md) design
supersedes that execution constraint. It specifies shared tool-job state machines,
Lua suspension, explicit concurrency, and nested call recording. Those changes are
not implemented; the result, admission, and delivery contracts below remain the
starting point, not a prohibition on refactoring their current interfaces.

## Why

Nabla originally shipped one tool, `shell`, and the tool system was the shell
tool. Argument reading, result encoding, error taxonomy, dispatch, and the
system prompt all named shell fields directly. Adding a second tool meant
editing dispatch, the request builder, result rendering, and the storage
vocabulary.

The goal is one tool system with a fixed set of native tools (`shell`,
`read`, `write`, `edit`, the skill tools, and the conversation tools
`context.compact` and `context.read_result`) and MCP servers
as a second source of the same kind of tool. Adding a tool should mean writing one
declaration and one procedure.

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

## Scope and planned extensions

The implemented tool system has no Code Mode, parallel tool execution, background
jobs, PTYs, permission language, or MCP resources, prompts, subscriptions, Apps, or
Tasks. Lua is already embedded for configuration, but not for tool orchestration.

[Code Mode architecture](CODE_MODE_ARCHITECTURE.md) now proposes a Lua execution
tool and asynchronous, bounded tool jobs. It replaces the synchronous orchestration
assumption rather than wrapping it in a second tool system. Detached background
jobs, plugin loading, and the other capabilities above remain outside that work.

## The tool contract

A tool is data plus one procedure.

`Tool_Definition` carries the provider-visible name, description, and input
schema bytes; static behavior hints; a timeout policy; the execute
procedure; and a borrowed backend binding.

`Tool_Behavior_Hints` states read-only, destructive, idempotent, and
open-world as tri-state values. Unknown is the zero value, so absence of
knowledge reads as unknown rather than as a claim. The hints are for the
harness, policy code, and diagnostics, not for the model: provider
function-tool formats have no portable hint fields, so descriptions stay
responsible for model-facing guidance and no generated prose is appended to
them.

`Tool_Timeout_Policy` states a default and a maximum as durations. Zero means
no tool-specific bound, not a forgotten configuration. Milliseconds live only at the JSON argument boundary.

The backend binding is a borrowed pointer, nil for native tools. The registry
copies it but never frees it: the adapter that registered the definition owns
the state and keeps it alive until no registry and no in-flight turn can use
it. Dispatch copies it into `Tool_Context`, and only the execute procedure
paired with the definition may interpret it.

Registration validates every definition and refuses malformed ones with a
concrete error: names fit the provider-compatible subset, descriptions are
non-empty and bounded, schemas are bounded JSON with an object root, timeouts
are consistent, an executor is present, and collisions are refused rather than
resolved last-wins. A bad definition never reaches request encoding, where it
would fail after the request was already recorded.

`Tool_Execute` has one signature for every tool:

```odin
Tool_Execute :: #type proc(ctx: ^Tool_Context, arguments: json.Object) -> Tool_Result
```

There is no separate prepare step and no erased per-tool argument state. The
procedure reads its own fields with the shared helpers, which validate types and
ranges and produce deterministic diagnostics. A tool that returns
`Invalid_Arguments` has performed no effect; that is the contract dispatch
relies on when it decides a call did not run.

For the asynchronous target, this signature remains useful as a blocking worker
adapter, not as the orchestration interface for every tool. Execution placement
becomes explicit: worker procedures, short owner-side session operations, and
resumable Lua executions. Context and allocator ownership extend through job
retirement; a call-scoped borrowed stack frame is no longer sufficient.

This deliberately avoids the crate of hooks, typed codecs, and adapter traits
the reference harnesses carry. Four tools do not need a plugin boundary.

## Registry and lifetime

`Tool_Registry` owns a flat array of definitions. It is built separately,
validated, and sorted before it is installed, so a failed build never leaves
half of the new inventory behind. It is replaceable while the chat is idle
and frozen for the entire user turn: all model requests and tool executions
in a turn borrow the same definitions, and replacement is refused while a
turn is in flight. The registry is never mutated in place, because
dynamic-array growth could invalidate borrowed definition pointers.

MCP tools will enter the same registry through an adapter. A refresh happens
between turns, so a running response always dispatches against the definitions
it was advertised with.

## Dispatch

The pipeline is fixed and lives in `chat_run_tools`:

1. Admit the response batch (identities, duplicate call ids, budget).
2. Commit the assistant response and the raw calls.
3. Resolve the call name against the registry.
4. Prepare the argument bytes: size, syntax, object root, duplicate keys, then
   one deterministic repair for raw control bytes inside string literals.
5. Write the dispatch entry with the effective arguments.
6. Check cancellation again: a turn that ended after the dispatch was recorded
   reports Not_Executed, because the call never started.
7. Execute once through the definition's procedure.
8. Finalize the result against the result contract: verify the envelope
   shape, the status match, and the global budget, replacing a violation
   with bounded feedback that preserves the observed outcome.
9. Write the result entry.
10. Report to the observer and continue in assistant source order.

A durable write failure stops the turn. Nothing runs after a dispatch record
failed to land, and no result is continued from memory.

The proposed asynchronous path splits this procedure into state transitions and
effects for admission, dispatch recording, launch, completion, result recording,
and retirement. Worker completions are events; only the session owner commits
them. Direct and Lua-originated calls share that path. A nested call records its
parent and is excluded from provider replay, while remaining available for
inspection and recovery. See [Code Mode architecture, sections 6 through 9](CODE_MODE_ARCHITECTURE.md#6-state-machine-model).

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

Model-visible content is bounded to 64 KiB of valid JSON for every tool alike.
`TOOL_MAX_RESULT_BYTES` lives in `agent/tool.odin` and finalization enforces
it, so no single call can consume a large part of the model context. Shell
output is previewed from the tail, spilled to a private file under the session
directory, and reports when even the spill was incomplete, so a long build is
recoverable instead of lost. Draining continues after the preview limit so the
child never blocks on a full pipe. A skill listing that does not fit returns
fewer records with the usual paging cursor; an oversized single skill body is
an explicit bounded failure until pagination or another deliberate design
exists.

## Shell

`shell` is not a terminal, a background-job service, or a sandbox. Its
timeout policy lives in its definition: 30 seconds by default, 120 seconds
maximum. A model-requested timeout above the maximum is refused, never
silently clamped. Cancellation wins over the timeout when both are observed.

- The shell this process was started from, the one `SHELL` names, runs the
  command as `<shell> -c` in a fresh process group with stdin closed. A shell
  that cannot be started, and an environment that names none, fall back to
  `/bin/sh`, so the tool stays usable when the user's shell does not.
- The command inherits the environment this process was started with, so the
  agent works with the same variables, the same tools, and the same versions the
  user does. Nothing is added, removed, or rewritten.
- A close-on-exec setup pipe distinguishes a shell that never started from a
  command that genuinely exited 127, and is what lets the fallback run a command
  that never ran without ever running one twice.
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

The client supports two protocol eras. It first probes with the stateless
`2026-07-28` request shape. A discovery result selects that revision. If the
server does not return a discovery result, the client restarts it when needed
and performs the handshake used by `2025-11-25` and `2025-06-18`.

Under `2026-07-28`:

- Every request declares its version and client capabilities in `params._meta`.
- `server/discover` reports supported versions, capabilities, and identity.
- `resultType: "input_required"` carries server-to-client input requests.

Under the handshake revisions, `initialize` negotiates the version and is
followed by `notifications/initialized`. Requests omit the stateless `_meta`
envelope and results do not require `resultType`. Server requests are answered
with method-not-found because Nabla advertises no client-side MCP capabilities.

Stateless describes request routing, not effects. A `tools/call` is never
automatically retried, including after a lost connection, because the server may
have performed the action before the reply was lost. That case is `Unknown`.

Only stdio transport is implemented. There is no Streamable HTTP or OAuth flow.
A server that selects or advertises an unsupported revision gets an actionable
diagnostic naming the revisions involved.

The transport states whether a complete request was written, not whether the
server ran it. That one fact is what the adapter needs to choose between
`Transport_Failed` and `Unknown`, so the MCP package reports delivery rather than
collapsing it into a single failure.

### Tool names

Every tool has an explicit namespace. Native tools use `builtin`, such as
`builtin.read` and `builtin.write`, except the conversation tools, which use their
own subject: `context.compact` and `context.read_result`. MCP tools use the
configured server id, so a `grep` tool from the `fff` server is `fff.grep`. This
prevents native and remote tools, or tools from two servers, from colliding
without requiring user aliases.

The harness exposes every tool returned by `tools/list`. It keeps the remote
name exactly, including dots. Optional per-tool configuration uses the exact
case-sensitive remote name as its key:

```lua
tools = {
  ["issues.create"] = {name = "create_issue"},
  ["issues.delete"] = {enabled = false},
}
```

`name` replaces only the local part, producing `github.create_issue` in this
example. `enabled` defaults to true. A tool needs an entry only when the user
wants to rename or disable it.

### Retry policy

Retry is a property of the method, not of the transport failure.

| Method | Policy |
| --- | --- |
| `server/discover` | Restart the server and retry once. |
| `tools/list` | Restart the server and retry once. |
| `tools/call` | Never automatically retry. |
| `notifications/cancelled` | Best effort, never retried. |

A `tools/call` that fails before its request was written reports
`Transport_Failed`. One that fails after the request was written reports
`Unknown`, because the harness cannot tell whether the effect happened. A remote
JSON-RPC error response is an observation and is reported as `Tool_Failed`.
Restarting a stdio server after it exits is fine; reissuing an ambiguous call is
not.

### Input required

Nabla declares no sampling, elicitation, roots, or subscription capability, so it
cannot answer a server-initiated input request. A `tools/call` answered with
`resultType: "input_required"` is parsed, never retried, and reported as
`Tool_Failed` with the requested interaction described for diagnostics. The
protocol shape is understood; the interaction is not implemented.

### Tool mapping

Every MCP tool enters the registry through one executor, so a definition carries
a backend binding instead of a procedure of its own. The binding names the
server and the remote tool; the definition carries the remote description, the
remote input schema bytes, the annotations as behavior hints, and the configured
timeout policy.

Annotated behavior maps one to one, and absence stays unknown rather than
becoming a claim:

| Remote annotation | Hint |
| --- | --- |
| absent | Unknown |
| `readOnlyHint` | read-only |
| `destructiveHint` | destructive |
| `idempotentHint` | idempotent |
| `openWorldHint` | open-world |

Observations map onto the outcome vocabulary the session already persists:

| Observation | Outcome |
| --- | --- |
| completed, `isError` false | `Success` |
| completed, `isError` true | `Tool_Failed` |
| input required | `Tool_Failed` |
| cancelled with the turn | `Cancelled` |
| the call's own deadline passed | `Timed_Out` |
| the server is not running | `Unavailable` |
| the request was never written | `Transport_Failed` |
| written, reply lost or unreadable | `Unknown` |
| remote JSON-RPC error | `Tool_Failed` |

A remote error is never `Invalid_Arguments`. That outcome promises the call was
refused before any effect, and a remote peer is not in a position to establish
that promise. `Invalid_Arguments` stays what the harness itself decided before
the call ran.

Only text and structured content reach the model. An image, audio, or embedded
resource is reported by type and omitted, because a base64 payload would consume
the result budget to no purpose. The adapter bounds the result below the 64 KiB
budget rather than relying on finalization to replace it.

### Server configuration

Server configuration lives in `config.lua` under `mcp.servers`. The minimal
stdio configuration is the server id and executable:

```lua
return {
  mcp = {
    servers = {
      fff = {executable = "/absolute/path/to/fff-mcp"},
    },
  },
}
```

Add `arguments` only when the program needs flags or other arguments. The act of
placing the server in the user's configuration is the trust decision. Nabla does
not load MCP configuration from a repository or start a server that the user did
not configure.

The transport is chosen by which endpoint field is present rather than by a
`transport` field. Only stdio exists, so an `executable` is what selects it; a
later transport brings its own field, and setting two is the error.

A stdio server is launched by executable and argv, never through a shell, in its
own process group, with an absolute executable path. The server inherits the
environment that launched Nabla. `environment` is an optional map that replaces
or adds variables for that server. It is needed only when the server expects
configuration such as an API token, a database URL, or a cache path that is not
already present. Most local servers need no entries. The resulting environment
is frozen when the process starts.

The server's stderr is drained by a thread that keeps a bounded tail, so a chatty
server cannot block on a full pipe. Stderr is diagnostic only and never decides a
request outcome. One request is currently in flight at a time because the harness
runs tools serially. The asynchronous design preserves a capacity-one execution
lane per MCP client until multiplexing is implemented and tested. Independent
clients may run concurrently; queued calls must not occupy worker slots or read
the same client's stream from multiple threads.

The runtime keeps one stable client slot per configured server. Discovered tool
bindings are allocated individually and replaced as one generation after the
session accepts a refreshed registry. The previous generation stays alive while
the old registry can still borrow it.

### Refresh

Tools are refreshed between turns, while the session is idle. A server that
cannot be discovered or listed contributes no tools for that turn and is
reported once; its stale definitions are not kept, because a definition whose
schema or backend no longer matches is worse than absent. Other servers still
contribute. A registry that cannot be built at all leaves the installed registry
untouched.

Configuration problems fail startup. Runtime connectivity problems degrade one
server for one turn. Discovery defaults to 5 seconds, a call defaults to 30
seconds, and the configurable call ceiling defaults to 120 seconds. These values
need no configuration for normal local servers. The millisecond fields remain
available for slow startup or long-running tools.

A call can carry several bounds: the definition
maximum, the definition default, and a model-requested timeout where the tool
exposes one. The effective bound is the earliest applicable deadline. The
file and skill tools state no tool-specific bound and check cancellation
cooperatively instead: before expensive reads, before the temporary
write, while it grows, and before the atomic rename. A cancellation before
the rename deletes the temporary file and reports Cancelled; once the rename
succeeds the observed result stands. A hard deadline for synchronous
filesystem calls would need process isolation or nonblocking I/O, which is
outside this design.

## Prompt stability

Tool definitions are sorted and serialized deterministically so the cacheable
prefix does not churn. Descriptions and schemas are frozen within a response.
Connection state, request ids, timestamps, and credentials never enter a
description. Request records store the actual prepared inventory, name,
description, and exact schema bytes taken from the prepared request rather
than reconstructed from the session, so the record stays true even if the
registry changes before the write lands. Session tips are not taken from a
server: MCP instructions are untrusted external text.

## Packages

| Package | Responsibility |
| --- | --- |
| `agent` | Tool contract, registry, dispatch, native tools, MCP adapter |
| `agent/session` | Durable call, dispatch, result, and recovery records |
| `mcp` | MCP messages, discovery, tools, transports, errors |
| `http/client`, `sse` | HTTP and event-stream transport |
| `ai` | Provider tool definitions and response assembly |
| root `nabla` | Configuration, runtime ownership, presentation |
