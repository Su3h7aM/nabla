# Nabla

A minimal, simple, and robust coding-agent harness written in Odin. The monorepo has three layers, and dependencies point inward from the harness toward the foundation:

- **Foundation**: `text`, `input`, `term`, `layout`, `tui` (with `tui/widgets`). A terminal, layout, and text stack that knows nothing about models, agents, or HTTP. `layout` imports nothing else from the repo.
- **Libraries**: `dns`, `tls`, `http` (with `http/client`), `sse`, `websocket`, `ai`, `mcp`, `acp`, `db` (with `db/sqlite`). Each is a standalone library another Odin project could use.
- **Harness**: `agent` and the root `nabla` executable. Only the root package imports both the foundation and `agent`.

A foundation or library package must be describable without naming Nabla, so it carries no turn, session, tool-policy, catalog, or presentation concept. Code only the harness uses belongs in `agent` or the root package. Prefer extending the package that owns a subject over adding a package.

Read `docs/ARCHITECTURE.md` before changing package boundaries, adding a subsystem, adding a limit, or handling a failure. It is the single architecture document: invariants, limits, failure feedback, Odin rules, and one section per subsystem. Edit a rule in the section that owns it rather than copying it here.

## Principles

- **Simplicity.** Choose the simple, explicit, data-oriented solution. Structs hold data, procedures process it, and indirection exists only at a real substitution boundary. Build only what the task needs. When you touch code that can be simpler, simplify it.
- **Small is robust.** Every line, state, and branch is one more place something can go wrong, so the smallest code that meets the requirement is the most robust. Weigh a change by what it removes as much as by what it adds.
- **Resilience.** The harness keeps running as long as it reasonably can, and a non-critical failure never stops the agent or blocks it permanently. Prevent failures first with simple, idiomatic code. A failure that still happens stays inside the work it touched: a stuck worker is abandoned, its call reports `Unknown`, its memory leaks, and new work takes over its claims. Threads are never killed, and a lock never spans I/O, a wait, or a callback. Recovery must cost less than the failure it handles; for a rare failure that would need a complex mechanism, let the turn or process end with a clear message and rely on journal recovery. Section 2.4 of `docs/ARCHITECTURE.md` has the rules.
- **Root causes.** For a bug, inspect every caller of the procedure you change and fix the shared cause.
- **No harness limits.** The harness gets out of the model's way. A limit exists only when a protocol, an API, a provider, the model, or the operating system imposes it. A constant that caps model-driven work (argument size, output size, retries, call counts, execution time) is a defect. A timeout is a default the model can override.
- **Failures are feedback.** A failed tool, a malformed call, or a rejected request becomes actionable feedback to the model, and the turn continues. The feedback names the call, the cause, and what did not run. Only the user, the model, or an unreachable model ends a turn.
- **Repairs are reported.** When the harness repairs a malformed tool call, the result still tells the model what it sent wrong and what was repaired, so it corrects future calls. A silent repair teaches the model that the mistake was correct.
- **Provider-neutral.** Code never branches on a model, and branches on a provider only as a last resort. Handle a difference through one shared mechanism: the API family, a catalog fact the user can also set in configuration, or a classification of what the provider returned. Data takes effect without a rebuild or a new session; a hardcoded branch needs both. Section 12 of `docs/ARCHITECTURE.md` has the rules.

## Odin

Write idiomatic Odin that follows the language's philosophy: zero is initialization, errors are values, conversions are explicit, and memory has a clear owner and allocator. Prefer `core:` and `vendor:` packages; a new foreign dependency needs a decision.

Handle every error that can occur, the Odin way: trailing error return values, `or_return`, `or_else`, `or_break`, `or_continue`, or an explicit check. Section 3 of `docs/ARCHITECTURE.md` covers errors, allocators, context, threads, and platform code.

Use JSON only where an external interface requires it: provider requests and responses, MCP, ACP, journal payloads, logs, and exports. Everything internal uses native data: typed structs, enums, tagged unions, and slices. Parse JSON once at the boundary into those types and encode only when writing back out, so JSON text and `json.Value` stay inside the boundary code. Section 3.6 of `docs/ARCHITECTURE.md` has the details.

Treat your Odin knowledge as unverified. When unsure about a signature, a language rule, or an idiom, check before writing: read the standard library under `$(mise exec -- odin root)` (`core/`, `base/`, `vendor/`) to see how Odin's own code does it, consult the official documentation, or run a small experiment against the compiler.

## Naming and comments

Code describes itself through clear names and simple structure. Names are full words that say what the thing is or does: `snake_case` procedures and variables, `Ada_Case` types, `SCREAMING_SNAKE_CASE` constants. Name any literal whose meaning is not obvious at the call site.

Never use a single-letter name, for anything: a procedure, parameter, variable, field, loop index, receiver, or generic parameter. Write `journal`, `index`, `test`, and `session`, never `j`, `i`, `t`, or `s`. Avoid abbreviations as well: `error` over `err`, `connection` over `conn`, `arguments` over `args`. The only exceptions are names fixed by an external interface, such as a JSON field or a foreign API.

Comments are minimal documentation: one or two lines stating a contract the code cannot express, such as ownership, lifetime, thread, or failure behavior. Delete a comment that restates the code. Long rationale belongs in `docs/`, and a comment never points at a document, task, or discussion.

## Tests

Keep tests few and meaningful. Write a test only when its failure would show something is broken, and test the final behavior through the highest-level procedure that exercises it rather than each helper beneath it. Leave out assertions on styling, colors, or internal structure.

Tests live in the package they validate: `<source>_test.odin` beside the source, broader suites under `<package>/test/`, all run by `odin test` with no custom runner. Suites run on every thread, so tests share no process-global state: no environment variables, no package-level state, no stdout or stderr writes, and per-test temporary directories. A test that sets the cancel token or signal dispositions runs in a child process through `test_isolate_process` (`agent/isolate_test.odin`).

## Tools

Use **mise** for everything: it installs Odin and runs the tasks `build`, `check`, `fmt`, and `test` (`mise run <task>`). Each task is a standalone Bash script under `scripts/` that also runs directly; read it before changing it.

Before committing a code change, run `mise run fmt`, `mise run check`, and the tests covering what you touched. `mise run test` is the full gate. Documentation-only changes need no run.

Read, search, and edit through the dedicated tools; use the shell for builds, tests, scripts, and pipelines.

## Version control

Use **Jujutsu (`jj`)** for all version control, following the Jujutsu model: the working copy is a change, and `jj describe`, `jj new`, `jj squash`, `jj split`, and the operation log replace Git workflows. The Git repository underneath is never touched directly.

Keep one coherent change at a time and close it with `jj describe -m "<message>"` then `jj new`. An unrelated bug found on the way gets its own change.

Commit titles are Conventional Commits (`chore`, `feat`, `fix`, `refactor`, `test`, `docs`, `build`) describing the diff:

```
fix(agent): keep the last event id when the id field is rejected
```

A body is optional: one or two short paragraphs on intent and behavior, without a walkthrough of files or commands.

## Writing style

Write plain, direct prose with no em-dashes and no metaphor where a literal phrase exists. Break prose lines only between paragraphs, in Markdown and commit messages alike; the 160-column `odinfmt.json` width applies to source files only.
