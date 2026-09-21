# Nabla architecture

Status: target architecture for implementation agents. The implementation is a
prototype, not a compatibility constraint. This document defines what belongs in
Nabla and why. Required invariants apply to new work; they are not claims that the
prototype already satisfies them. [Implementation status](ARCHITECTURE_STATUS.md)
records verified gaps separately. Sections marked future authorize no implementation
until a task requires that capability.

## Read by responsibility

Read this document before changing harness boundaries or adding a subsystem.
Then read the contract for the behavior being changed:

| Work | Authoritative contract |
| --- | --- |
| Transitions, requests, async work, cancellation, retirement | [Execution state machine](EXECUTION_ARCHITECTURE.md) |
| Admission, tool jobs, result bounds, MCP | [Tools](TOOLS_MCP_ARCHITECTURE.md) |
| Lua execution and child calls | [Code Mode](CODE_MODE_ARCHITECTURE.md) |
| Failure classification, retries, recovery | [Errors](ERROR_RETRY_ARCHITECTURE.md) |
| Projection, persistence, compaction, cache accounting | [Context](CONTEXT_COMPACTION_ARCHITECTURE.md) |
| Instruction sources and skill loading | [Instructions and skills](SKILLS_ARCHITECTURE.md) |
| Configuration, future Lua hooks, placement decisions | [Customization](CUSTOMIZATION_ARCHITECTURE.md) |
| Future dynamic delegation | [Subagents](SUBAGENT_ARCHITECTURE.md) |
| Transport and provider boundaries | [Network](NETWORK_STACK_ARCHITECTURE.md) |
| Context logger, diagnostics, capture | [Diagnostics](LOGGING_ARCHITECTURE.md) |

Each contract owns its subject. Link to it instead of copying its rules into another
plan. Change conflicting contracts together; do not add a paragraph that supersedes
an earlier paragraph while leaving both as instructions.

## Architectural principles

Nabla is a small native harness with one owner-driven execution machine. It turns
committed input into model requests and admitted tool effects. Lua composes those
tools. SQLite records what happened. Presentation consumes data, not internal state.

Use the simplest idiomatic Odin solution that meets a demonstrated requirement.
The default design is a concrete struct, a bounded collection, and a procedure with
explicit inputs and error results. Add indirection only at a real external or
substitution boundary, such as a provider adapter, tool executor, or caller writer.
A library-shaped name does not justify a package or interface.

The important decomposition is by validated artifacts, not by object hierarchy:

```text
committed input -> prepared request -> admitted frozen request
               -> observed response -> validated response and calls
               -> committed calls -> observed tools -> committed results
```

Every arrow has a named owner, validator, failure outcome, and release point. A stage
that waits owns its continuation as data. A short synchronous stage is a procedure,
not automatically a new machine state. This gives tests useful boundaries without
turning every helper into a command object.

### Why staged execution

SynapseFlow's workflow decomposition is the main case-study basis for this design.
Its four-stage fuzz-harness generation separates documentation, snippets, assembly,
and final validation, with bounded regeneration from earlier artifacts. The supplied
review reports a larger coverage loss from collapsing those stages than from replacing
its dataflow grouping. That supports narrow stages and local validators, not a claim
that Nabla inherits its benchmark results. Its probability argument assumes sufficiently
independent stages; tool side effects and interactive model requests are not independent.
See [SynapseFlow](https://arxiv.org/abs/2607.07007) for the source identified by that review.
The supplied analysis, not an independently reproduced experiment, is the evidence here.

For Nabla, the reusable lesson is to retry only the failed, repeatable work from a
validated input. Do not translate staged rollback into rerunning shell commands,
rewinding files, or asking a model to repair an uncertain effect. Deterministic checks
handle identity, JSON, budgets, and ownership. Semantic task quality remains a model
and evaluation concern. No function-role taxonomy, structural flow graph, voting
prompts, universal compile gate, or generic workflow engine belongs in the harness.

DeepSeek's useful precedent is narrower: durable facts distinct from model history,
stable request bytes, nested calls outside the model projection, and explicit
interception boundaries. Nabla does not need its plugin lifecycle, service registry,
event waterfalls, profiles, or background-job platform. Adopt an invariant without
adopting the machinery that another runtime uses to enforce it.

## Required invariants

1. One owner mutates a live session and writes its store. Workers return observations.
2. A tool cannot start before durable intent. A continuation cannot consume an
   uncommitted result. Storage failure stops admission, not cleanup.
3. Every committed call has one terminal result before normal turn completion or the
   next model request. Storage loss may prevent settlement; recovery closes the gap.
4. Cancellation is intent, completion is an observation, commit is durability, and
   retirement is proof that resource borrows ended. None substitutes for another.
5. The durable record is authoritative. Runtime tables hold in-flight work, not a
   second conversation. Provider requests are disposable projections.
6. Failed or partial responses release no executable calls. Automatic retry never
   repeats a tool or a model send whose execution may already have happened.
7. All retained work has an owner and a bound, including hidden Lua children, pending
   output, input queues, and diagnostic capture. Hiding data from the model is not a
   storage or memory bound.
8. Native core checks apply equally to direct calls, Lua calls, future hooks, and
   future subagents. Customization cannot weaken them.
9. The zero value is inert or explicitly unknown. Absence, false, zero, empty success,
   allocation failure, and unobserved outcome are distinct where behavior differs.
10. Linux is the target. No speculative platform layer or new runtime dependency.

## Package boundaries

| Layer | Owns | Excludes |
| --- | --- | --- |
| `text`, `input`, `term`, `layout`, `tui` | Reusable text, terminal, layout and UI facilities | Agents, providers, session policy |
| `dns`, `tls`, `http`, `http/client`, `sse`, `websocket` | Their protocols, resource ownership, protocol facts | Model names, retries of model work, harness logging policy |
| `ai` | API encoding/decoding, normalized provider evidence, one-send operations | Turn control, model catalog policy, session storage, presentation |
| `mcp` | MCP protocol and transport facts | Nabla tool policy and conversation |
| `db`, `db/sqlite` | Database facilities | Harness record semantics |
| `agent/session` | Durable identities, records, transactions, claims, recovery queries | Model execution, filesystem instruction discovery, UI |
| `agent/skills` | Bounded skill format, discovery and loading | Turns, model selection, permissions |
| `agent` | Execution policy, catalog resolution, tools, Lua, context, diagnostics | Terminal, rendering, process-global UI state |
| root `nabla` | Process lifetime, configuration wiring, signals, frontends, ACP adaptation | Duplicate retry, admission or projection policy |

`acp` is a protocol boundary, not an agent dependency. Only root combines foundation
and harness. Moving the frontend behind ACP is future integration work, not a reason
to build an RPC layer inside `agent` now. Headless and interactive callers drive the
same machine. The caller-supplied writer and semantic observer carry presentation
output; neither is a policy hook or a substitute for the session record.

Prefer extending the package that owns a subject. A new subpackage needs a distinct
contract and consumer, not a folder for a large struct. Foundational and protocol
packages must remain independently buildable and useful outside Nabla.

## Odin data, memory, and context

Use `snake_case` procedures and fields, `Ada_Case` types and enum members, and
`SCREAMING_SNAKE_CASE` constants. Prefer enums, tagged unions, `Maybe`, distinct
identities, slices, and small contiguous tables. Use exhaustive switches for closed
control domains. Do not erase internal types into strings, `any`, `rawptr`, or
property maps. Confine unavoidable erased pointers to validated FFI/executor bindings.

Keep data and procedures separate. No class emulation, service locator, dependency
container, generic reducer framework, or allocator wrapper per component. A procedure
pointer is appropriate for an actual executor boundary, not for every private helper.

### Context is scoped infrastructure

Use `context.allocator`, `context.temp_allocator`, `context.logger`, and the standard
random generator where their contracts fit. The implicit context is not a place to
hide session state, cancellation, authority, or a collection of services. Those are
explicit typed inputs and owned records. In particular, do not store an execution
container in `context.user_ptr` to bypass package boundaries.

Allocating APIs normally take a trailing `allocator := context.allocator`. An owner
that outlives the call retains the allocator needed to release its memory. Scope-wide
allocator overrides are useful for a deliberate common lifetime, not for concealing
which allocator owns an escaping result. Copying strings, slices, maps, and dynamic
arrays copies headers, not ownership.

| Lifetime | Allocation and release rule |
| --- | --- |
| One observation/effect | Owner-local scratch; reset only after all borrowed output is consumed |
| Prepared request and retry chain | Owned bytes/settings until every attempt retires |
| Worker execution | Stable owned input and result, thread-safe allocator, release after producer retirement |
| Lua execution | Private Lua state plus bounded host allocations; release after children retire |
| Session | Decoded snapshot, registry and control data; release after all borrowers retire |
| Durable history | SQLite and explicitly bounded artifacts, loaded by range rather than retained forever |

A temporary allocator reset belongs to its owner. A library must not reset a caller's
shared scratch. A long turn needs reset points within the turn, not only after the
whole prompt. Use arenas only for an actual shared lifetime; ordinary heap allocation
is the baseline for independently retiring jobs. Avoid a custom allocator, reference
count, free-list, or structure-of-arrays layout until its workload justifies it.

Threads and C callbacks do not capture the calling scope's context. Establish the
needed allocator and logger at entry. Do not copy the owner's whole context into a
worker: that can share scratch and a non-thread-safe allocator. A mutex wrapper is
insufficient if another thread accesses its backing allocator without that mutex.
Verify `core:thread` temporary-allocator cleanup when setting `init_context`.

Use `defer` for scope-owned cleanup. Suspended work needs explicit persistent owners;
Lua yield/error paths must not depend on unwinding Odin defers. Check allocation and
size arithmetic wherever failure could lose intent, publish empty success, or break
ownership. Use typed trailing errors and propagate them to the policy owner. Panics
are not normal input, transport, tool, or storage error handling.

## Minimal core and resource policy

The essential tools are Read, Write, Edit, and Lua Code Mode. Keep existing shell,
result lookup, compaction intent and skill tools only where they provide a distinct
capability. Names and the precise inventory are not immutable architecture. Compose
multi-operation work in Lua; use MCP for external integrations instead of adding a
native tool for each service.

Keep one foreground model operation per session. Bounded worker threads are justified
for blocking I/O and useful independent external work. A waiting Lua parent consumes
no worker slot. Use one owner wake mechanism rather than separate polling loops for
tools, retries, and compaction. No idle scanning, periodic inference, speculative
prewarming, or permanent pool solely because multiple cores exist.

Resource improvements need evidence. Measure peak live bytes, allocation count,
idle wakeups/CPU, executable plus runtime dependency size, owner stop latency, and
completed-task cost. Measure Lua by saved model round trips and intermediate tokens,
not just interpreter speed. Keep the simple design when a more complex one has no
meaningful end-to-end gain. Never disable validation to improve a microbenchmark.

The native implementation should use installed `core:`, `base:`, and `vendor:`
facilities before adding code or dependencies. Lua and SQLite are deliberate existing
foreign boundaries, not permission to add Node, Python, a web server, or a plugin
runtime. Replacing a foreign component requires measured value, not a new home-grown
interpreter, database, or cryptographic implementation for language purity.

## Making implementation decisions

Before adding a field or subsystem, answer:

1. What behavior needs it now, and which package owns that behavior?
2. Which existing data or Odin facility already answers the question?
3. Is this a distinct fact, or a cache/counter duplicating another fact?
4. Who owns it across waiting, cancellation, failure and shutdown?
5. What validates it before effects, what bounds it, and what survives restart?
6. Which test would detect a broken contract rather than a harmless rearrangement?

If the answer is only a future consumer, defer the machinery. Future hooks and
subagents need stable boundaries, not unused fields, placeholder effects, public task
handles, event buses, or schema migrations now. Prototype formats may change with an
explicit migration or diagnosed incompatibility; never silently reinterpret records.

Verify transitions without threads or a provider. Verify effect boundaries with
small real fixtures, including storage failure and cancellation races. Use ablations
on representative tasks to evaluate optional mechanisms, but never ship an ablation
that removes a safety invariant. Report task success, tokens/cost per successful task,
latency and resource use. Fuzz coverage from another system is not Nabla's metric.
