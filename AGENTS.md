# Nabla

A minimal, simple, and robust coding-agent harness written in Odin. The monorepo has three layers, and dependencies point inward from the harness toward the foundation:

- **Foundation**: `text`, `markdown`, `input`, `term`, `layout`, `tui` (with `tui/widgets` and `tui/markdown_view`). A terminal, layout, text, and Markdown stack that knows nothing about models, agents, or HTTP. `layout` imports nothing else from the repo.
- **Libraries**: `dns`, `tls`, `http` (with `http/client`), `sse`, `websocket`, `subprocess`, `ai`, `mcp`, `acp`, `db` (with `db/sqlite`). Each is a standalone library another Odin project could use.
- **Harness**: `agent` and the root `nabla` executable. Only the root package imports both the foundation and `agent`.

A foundation or library package must be describable without naming Nabla, so it carries no turn, session, tool-policy, catalog, or presentation concept. Code only the harness uses belongs in `agent` or the root package. Prefer extending the package that owns a subject over adding a package.

Read `docs/ARCHITECTURE.md` before changing package boundaries, adding a subsystem, adding a limit, or handling a failure. It is the single architecture document: invariants, limits, failure feedback, Odin rules, and one section per subsystem. Edit a rule in the section that owns it rather than copying it here.

## Principles

- **Simplicity.** Choose the simple, explicit, data-oriented solution. Structs hold data, procedures process it, and indirection exists only at a real substitution boundary. Build only what the task needs. When you touch code that can be simpler, simplify it.
- **Simple means easy to understand and maintain.** It does not mean fewer features or fewer lines. Code that is longer but plainer is simpler. Simplifying or unifying keeps every feature and implements it more clearly.
- **Standalone packages.** Every foundation and library package is reusable outside Nabla, so its features are judged by its own protocol, specification, or purpose. Never delete or trim a feature because the harness does not use it.
- **Small is robust.** Every line, state, and branch is one more place something can go wrong, so the smallest code that meets the requirement is the most robust. Weigh a change by what it removes as much as by what it adds.
- **Resilience.** The harness keeps running as long as it reasonably can, and a non-critical failure never stops the agent or blocks it permanently. Prevent failures first with simple, idiomatic code. A failure that still happens stays inside the work it touched: a stuck worker is abandoned, its call reports `Unknown`, its memory leaks, and new work takes over its claims. Threads are never killed, and a lock never spans I/O, a wait, or a callback. Recovery must cost less than the failure it handles; for a rare failure that would need a complex mechanism, let the turn or process end with a clear message and rely on journal recovery. Section 2.4 of `docs/ARCHITECTURE.md` has the rules.
- **Root causes.** For a bug, inspect every caller of the procedure you change and fix the shared cause.
- **No compatibility.** Nabla is a prototype, and nothing outside this repository depends on it. Replace an old implementation outright and delete what it leaves behind: no fallback for older journal records or configuration, no deprecated alias, no shim that keeps an old signature working.
- **No harness limits.** The harness gets out of the model's way. A limit exists only when a protocol, an API, a provider, the model, or the operating system imposes it. A constant that caps model-driven work (argument size, output size, call counts, execution time) is a defect. A timeout is a default the model can override. The resend schedule of a failed provider request is the one bound the harness sets, because it is not model work.
- **Feedback goes to whoever can act.** A failed tool or a malformed call becomes actionable feedback to the model, and the turn continues; the feedback names the call, the cause, and what did not run. A failed request is never the model's to fix: the harness retries it, repairs what it added, or stops, deciding from the API's documented error codes alone, and tells the user. The turn ends only when nothing is left to try without the user.
- **Repairs are reported.** When the harness repairs a malformed tool call, the result still tells the model what it sent wrong and what was repaired, so it corrects future calls. A silent repair teaches the model that the mistake was correct.
- **Provider-neutral.** Code never branches on a model, and branches on a provider only as a last resort. Handle a difference through one shared mechanism: the API family, a catalog fact the user can also set in configuration, or a classification of what the provider returned. Data takes effect without a rebuild or a new session; a hardcoded branch needs both. Section 12 of `docs/ARCHITECTURE.md` has the rules.

## Odin

Write every package to the standard of Odin's own `core:` packages, as an Odin maintainer would: zero is inert, errors are values, conversions and costs are explicit, and memory has a clear owner and allocator. Before writing a type or procedure, find the nearest `core:` package that solves a similar problem and copy its shape. Prefer `core:`, `base:` and `vendor:` packages; a new foreign dependency needs a decision.

Handle every error that can occur, the Odin way: trailing error return values, `or_return`, `or_else`, `or_break`, `or_continue`, or an explicit check. Section 3 of `docs/ARCHITECTURE.md` covers errors, allocators, context, threads, and platform code.

Memory is managed by hand, and every allocation has an owner and a release point you can name. Choose the release that fits each case; no single pattern fits all of them. The best choice is the simplest one that allocates the least and makes the owner obvious. Odin offers several, and `core:` uses each where it fits:

- Borrow a view (a slice or string into existing memory) instead of allocating at all.
- `defer delete(value)` or `defer destroy(&value)` directly after one owned allocation.
- An arena released with one `free_all` or destroy when many allocations die together.
- `free_all(context.temp_allocator)` in the loop that owns the thread, once per unit of work.
- `runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()` for scratch inside a procedure below that loop, which must never reset temp memory its caller may hold.

Section 3.3 of `docs/ARCHITECTURE.md` has the lifetimes and their allocators.

Use JSON only where an external interface requires it: provider requests and responses, MCP, ACP, journal payloads, logs, and exports. Everything internal uses native data: typed structs, enums, tagged unions, and slices. Parse JSON once at the boundary into those types and encode only when writing back out, so JSON text and `json.Value` stay inside the boundary code. Section 3.6 of `docs/ARCHITECTURE.md` has the details.

Treat your Odin knowledge as unverified. When unsure about a signature, a language rule, or an idiom, check before writing: read the standard library under `$(odin root)` (the fork when `ODIN_ROOT` is set) (`core/`, `base/`, `vendor/`) to see how Odin's own code does it, consult the official documentation, or run a small experiment against the compiler.

Validate every refactor the same way before making it: find the `core:` or `base:` code that models the same shape and copy it. A change with no such precedent is not made. Shapes already confirmed that way:

- A value with presence is `Maybe(T)`, not a `T` beside a `present` bool.
- Cases that share no field are a plain `union` of structs (`json.Value`, `net.Address`).
- Cases that share fields are a struct with the shared fields and a `variant: union {...}` (`runtime.Type_Info`, `ast.Node`), never a union whose variants repeat the same field.
- A `rawptr` plus procedure pair is right for a stored callback, as in `runtime.Allocator`, `thread.Task`, and `container/avl`. A directly called procedure takes a typed or polymorphic parameter instead.
- `transmute` between a `bit_set` and its integer, and `uintptr` arithmetic on data pointers, are what `core:` itself does and need no replacement.

## Naming and comments

Code describes itself through clear names and simple structure. Names are full words that say what the thing is or does: `snake_case` procedures and variables, `Ada_Case` types, `SCREAMING_SNAKE_CASE` constants. Name a procedure for its package-qualified call site (`journal.commit`, not `journal.journal_commit`); inside a package with several subjects, prefix by subject (`chain_send`). Name any literal whose meaning is not obvious at the call site.

A name's length follows its scope. Never use a single-letter name, except a loop index or a generic parameter (`i`, `j`, `$T`) in a scope of a few lines. Otherwise names are words the reader recognizes at once: full words (`journal`, `session`) or an abbreviation every programmer reads without thinking (`conn`, `stmt`, `args`, `ctx`, `err`, `ok`, `fd`, `id`). An invented or ambiguous shortening gets the full word. Names fixed by an external interface, such as a JSON field or a foreign API, keep their form.

Comments document contracts the code cannot express. Each package has a `doc.odin` overview. An exported declaration whose contract is not obvious from its signature gets a doc comment directly above it, in the `core:os` style: it starts with the name and states what the procedure returns, which errors it can return, who owns the result and with which allocator, and any thread or lifetime rule. It is as long as that contract and no longer. Inside a procedure, a comment explains why, never what. Delete a comment that restates the code. Long rationale belongs in `docs/`, and a comment never points at a document, task, or discussion.

## Tests

Keep tests few and meaningful. Write a test only when its failure would show something is broken, and test the final behavior through the highest-level procedure that exercises it rather than each helper beneath it. Leave out assertions on styling, colors, or internal structure.

Delete a test that validates nothing real or only re-checks what a higher-level test already covers.

Tests live in the package they validate: `<source>_test.odin` beside the source, broader suites under `<package>/test/`, all run by `odin test` with no custom runner. Suites run on every thread, so tests share no process-global state: no environment variables, no package-level state, no stdout or stderr writes, and per-test temporary directories. A test that sets the cancel token or signal dispositions runs in a child process through `test_isolate_process` (`agent/isolate_test.odin`).

## Tools

Use **mise** for everything: it installs Odin and runs the tasks `build`, `check`, `fmt`, and `test` (`mise run <task>`). Each task is a standalone Bash script under `scripts/` that also runs directly; read it before changing it.

The tasks run the `odin` on `PATH`, which is the version mise installs. With `ODIN_ROOT` set they run `$ODIN_ROOT/odin` and that tree's `core`, `base`, and `vendor` instead, for example `ODIN_ROOT=/home/su3h7am/Projects/Odin mise run check` for the maintainer's fork. The fork has compiler checks the mise version lacks, so run `check` and `test` with it before committing a change that touches ownership or pointers.

Before committing a code change, run `mise run fmt`, `mise run check`, and the tests covering what you touched. `mise run test` is the full gate. Documentation-only changes need no run.

Run tests only through `mise run test [package] [--debug-only | --release-only] [--sanitize <kind>] [--test <names>] [--log-state]`, never through `odin test` directly. The task runs each suite in its own PID namespace, so every process a test starts ends with the suite, whether it passed, failed, or timed out. After a timeout, rerun with `--log-state` to log each test state change and `--test <name,...>` to run only the named tests.

Read, search, and edit through the dedicated tools; use the shell for builds, tests, version control, and pipelines.

For computation, file processing, and multi-tool workflows, use Code Mode (Lua) instead of Python, Perl, or another scripting language run through the shell. When Code Mode or another harness tool cannot do what you need and you fall back, add a report to `docs/HARNESS_FEEDBACK.md`: what you tried to do, why the tool fell short, and how you did it instead.

Before adding a Code Mode helper or a tool feature for a report, check whether Lua's standard library or an existing tool already does it. Then the fix is to expose the library or to state it in a tool description or a skill, not new code.

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
