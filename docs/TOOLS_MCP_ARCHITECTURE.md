# Tools and MCP

Status: required target. The shared [execution machine](EXECUTION_ARCHITECTURE.md)
owns scheduling, cancellation, result commit and retirement. This document owns
admission, tool authority, result representation and MCP adaptation. No separate
Lua, MCP, or future subagent dispatcher is permitted.

## Minimal tool contract

A definition is data plus a concrete execution choice: canonical name, description,
input schema, eligibility, limits, executor and backend binding. Worker execution
handles blocking native/MCP work; short owner operations handle session result reads
and compaction intent; Lua execution runs bounded slices. Add a placement only for a
real backend, not a universal start/poll/cancel/destroy interface.

Native tools retain typed field readers and one executor. Where preflight needs
field validation, reuse a side-effect-free validator with execution rather than
inventing an erased prepared-argument object. A whole JSON Schema engine is not
required. Advertised schema constraints and actual native validation must agree.
For MCP, validate shared structure locally and leave remote semantic validation to
the server. Do not claim arbitrary external schemas have been fully validated.

Read, Write, Edit and Code Mode are the essential capability set. Shell is a bounded
process invocation, not a terminal service. Skill loading, result paging and
compaction intent reuse the ordinary tool lifecycle. Service-specific integrations
belong behind MCP; repeated workflows belong in Lua rather than a proliferation of
native tools.

## Registry and identity

Build, validate and sort one registry before publication. Reject collisions, malformed
schema documents, inconsistent limits and missing executors. A failed replacement
leaves the installed registry intact. Freeze it for a turn, including all child work,
and retain borrowed backend generations until every producer retires.

Direct advertisement and Lua discovery are views of this registry, not independent
inventories. Check eligibility again at admission. Omitting a tool from a prompt is
not an authority check. Disabling tools must also disable indirect Lua invocation.

Canonical names use the flat ASCII identifier subset
`[A-Za-z_][A-Za-z0-9_]{0,63}`, excluding Lua reserved words when used as field names.
Native names such as `builtin_read` and MCP names such as `github_create_issue` pass
unchanged through advertisement and dispatch. Never split a name to reconstruct its
backend. An MCP binding retains the exact remote name separately. Remote punctuation
requires an explicit configured alias; do not silently normalize names into collisions.
Stored names describe what ran and are not rewritten when a registry changes.

Hints such as read-only or idempotent are tri-state metadata with unknown as zero.
They are neither proof of thread safety nor permission to retry an uncertain effect.
Descriptions carry model guidance. Do not synthesize a tool dependency manifest from
hints or require a read-before-edit history ledger. Real preconditions, such as an
edit's exact-match requirement, belong to that tool's deterministic validator.

## Batch admission before effects

A response is an untrusted proposal. Validate the entire root batch before any call
runs or any executable call record commits:

1. Require a complete accepted provider response, unique nonempty identities, valid
   names, and bounded call count and argument bytes.
2. Resolve every name against the frozen registry and check invocation eligibility.
3. Parse complete JSON objects with duplicate-key and depth checks. Apply only an
   exact documented syntactic repair, currently escaping raw control bytes inside
   otherwise unambiguous string literals. Revalidate the whole repaired document.
4. Validate native field types, ranges and known names without external effects.
   Preserve the server-validation boundary for MCP.
5. Reserve job/input capacity and terminal-result allowance for the whole batch.
6. Commit the accepted response and raw calls atomically, then transfer admitted jobs
   to the machine. Dispatch records retain the exact effective argument bytes.

An invalid name, malformed argument document, oversized batch or local validation
failure refuses the entire proposal. Execute none of its valid siblings. Record a
typed rejection and bounded model feedback instead of half an executable batch.
Do not invent arguments, choose one duplicate key, drop unknown fields or ask another
model to guess a repair. This gate prevents avoidable partial effects; it is not a
transaction around tool execution. Files and remote services can change after
admission, and a later runtime failure does not undo earlier calls.

Child calls enter the same admission checks one at a time. Their parent may already
have performed effects, so a rejected child is an ordinary refusal, not rollback of
the script. If a call has already committed, it owes a result even when cancellation,
launch failure or a later resource check prevents execution.

Structural inability to stage the response, such as allocation failure, stops the
turn rather than manufacturing a model error. Reserve settlement capacity before
launch. If persistence fails, latch session failure and drain resources without
another model request.

## Results and execution knowledge

The common envelope remains:

```json
{"status":"success","message":"","data":{}}
```

Outcome is authoritative typed data. Envelope status must agree with it. Validate
strict JSON and UTF-8, not merely a permissive parser's acceptance. Finalization can
replace malformed/oversized content with bounded feedback, but cannot turn an unknown
or failed effect into success. Empty valid output and missing/failed serialization
have distinct representations.

| Outcome | Evidence required |
| --- | --- |
| Success | Executor observed successful completion |
| Tool_Failed | Executor or peer reported failure; partial effects may exist |
| Invalid_Arguments | Local refusal before any effect |
| Unavailable | No execution began because capability/backend was unavailable |
| Not_Executed | Harness knows launch never occurred |
| Transport_Failed | Adapter proves the operation was not delivered for execution |
| Cancelled / Timed_Out | Work actually stopped under that control cause; not a promise to undo effects |
| Unknown | Execution or effects may have occurred but no conclusive outcome is available |

A remote JSON-RPC error is not local Invalid_Arguments. A cancellation notification,
partial pipe write, lost reply, or timeout alone cannot prove a remote effect stopped.
Preserve delivery evidence and use Unknown when necessary. No automatic retry of a
tool call, including reads, based only on hints. The model can decide its next action
from the recorded result.

Result commit precedes Lua delivery, observer terminal output, and the next request.
Progress is explicitly provisional. A producer's late result cannot overwrite an
already committed Unknown outcome or resurrect a cancelled continuation.

## Bounds, storage and projection

Use separate limits for different resources. One number cannot represent all of them:

- Per-call argument and finalized result bytes. The existing 64 KiB JSON result bound
  is the baseline for every tool, including skills and Code Mode.
- Live jobs, workers, Lua states, pending completion bytes and total admissions.
- Aggregate retained bytes per batch, including root and child arguments, results,
  parent summaries and artifact data.
- Model-visible root-result allowance derived from context capacity.
- Session retained-data quota and a small settlement reserve.

The existing count times per-result cap gives a finite worst-case child volume, but
it is not a separately controlled storage budget and does not bound sessions across
turns. Set named byte limits from measured workloads before claiming aggregate
retention is bounded. There is no exemption for hidden children, failed attempts or
spill files. Budget enforcement belongs to the owner, not Lua bookkeeping.

Reserve a small result for each admitted call. Charge remaining root results in model
call order, leaving space for a handle for every later root. When full retained content
fits storage but not model context, store it once and project a small derived handle
naming its session-local call identity and byte length. Persist that representation
decision; later requests must not silently resize old results and invalidate prefixes.
Child results do not individually charge the model-context budget, but do charge the
retention budget. The parent's selected output charges both.

Storage spill is not infinite retention. If retained output exceeds its allowance,
keep a valid bounded preview with explicit incomplete/omitted-byte facts where the
tool contract permits it, otherwise a bounded diagnostic. Structured output must
remain valid JSON; never cut an arbitrary JSON byte prefix and call it a result.
Preserve the observed outcome even when content cannot be retained. Refuse new
admissions when the session quota is exhausted; never delete active history to keep
working. Reserve settlement space as policy, while treating actual disk-full errors
as storage failures. Automatic archival and deletion are not implied.

`context_read_result` reads bounded UTF-8-safe byte pages from the existing retained
result. It is session-scoped, reports next offset/eof/completeness, cannot follow
arbitrary paths, and never recursively spills its own page. A handle cannot recover
bytes the producer never retained. Prefer this existing identity over a second blob
store or backend-agnostic locator framework.

Sensitive-field filtering happens before ordinary diagnostic retention. Exact tool
results may contain user secrets and need private storage; do not claim a generic
redactor can recognize every secret. If an explicit output filter exists, apply it
before preview/cap decisions and record that the content was transformed.

## Native effects

Read refuses nontext bytes rather than emitting invalid JSON. Shell may decode invalid
UTF-8 with explicit replacement because its output is a stream, not an exact file read.
Write/Edit validate first, use an explicit workspace path, and never change process-wide
cwd. Atomic file replacement is one tool effect, not a transaction over a script. Once
rename succeeds, a later cancellation cannot truthfully report that nothing changed.

Shell launches argv in a fresh process group, closes stdin, drains stdout/stderr even
after retained-output limits, and reaps the child. Distinguish exec failure from a
command that exits 127. Cancellation may escalate TERM to KILL with bounded pipe drain.
Keep the post-fork child path allocation-free. No implicit PTY, detached job or sandbox.
Absolute paths and inherited process authority remain powerful; a workspace name is
not confinement.

## MCP boundary

`mcp` is an independent protocol library. `agent` maps discovered definitions and
results through one adapter into ordinary tools. Root owns configured client lifetimes.
User configuration is the authority to start a server; repository text and model output
cannot install servers or obtain credentials.

The initial transport is stdio with explicit executable/argv, private process group,
bounded stderr draining and one request at a time per client. Each client has a typed
serialization identity; native tools share a conservative serial lane. Derive occupancy
from live jobs. A queued call holds no worker. Discovery, refresh and shutdown cannot
race a call on the same stream.

Protocol negotiation and version strings belong in `mcp` and its tests, not duplicated
architecture tables. Parse supported input-required/server-request shapes honestly and
report unsupported interactions; never fabricate sampling or approval responses.
Discovery/listing may use a bounded retry because they are metadata operations. Tool
calls never inherit that retry. A complete local write still does not prove completion;
a partial operation write cannot be assumed harmless without protocol-specific proof.

Refresh builds a new generation between turns. Unavailable servers contribute no stale
callable definitions; report their absence. Whole-registry construction failure leaves
the old registry intact. Keep exact descriptions/schema bytes stable when nothing
changed. MCP text and structured output pass through the shared result bounds; omitted
image/audio/resource payloads are described, not dumped as unbounded base64.

OAuth, Streamable HTTP, resources, prompts, subscriptions, Apps, Tasks, approval services
and multiplexing are separate requirements, not prerequisites for a useful MCP tool.

## Acceptance

Fixtures must prove that a malformed batch executes nothing, valid effects have durable
intent, children use the same checks, and failed writes prevent launch/continuation.
Cover runtime failure after successful admission, global and child byte exhaustion,
spilled paging after reopen, same-client serialization, cancellation with ambiguous MCP
delivery, and registry lifetime through the final producer access. Tests assert outcomes
and actual execution counts, not internal job layouts or exact prose.
