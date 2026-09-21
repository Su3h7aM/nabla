# Nabla

A monorepo in three layers that share one philosophy:

- **Foundation**: `text`, `input`, `term`, `layout`, `tui` (with its `widgets`
  subpackage). Reusable by any Odin program: the terminal, layout, and text stack knows
  nothing about models, agents, or HTTP.
- **Libraries**: `dns`, `tls`, `http` (with its `client` subpackage), `sse`, `websocket`,
  `ai`, `mcp`, `acp`, and `db` (with its `sqlite` subpackage). Each stands on its own: the
  protocol libraries know nothing about agents, and the model client knows nothing about the
  turn loop that drives it.
- **Harness**: `agent` and the `nabla` executable at the repository root. A coding agent built on
  top of both.

The harness is one consumer of the layers beneath it, not their owner.

## Architecture documents

Before changing harness boundaries or adding a subsystem, read
`docs/AI_HARNESS_ARCHITECTURE.md`. It is the entry point: principles, required
invariants, package boundaries, and pointers to the contract that owns each subject
(execution, tools, Code Mode, errors, context, instructions, customization, subagents,
network, diagnostics). `docs/ARCHITECTURE_STATUS.md` separates what exists from what the
target requires, so current prototype behavior is never mistaken for a rule. Keep each
subject in its one owning document and link instead of copying.

## Philosophy

Less is more. Prefer the simple, explicit, data-oriented solution over the abstraction:
structs hold data, procedures process it, and indirection appears only at a real substitution
boundary. A simple approach that reaches ~90% is worth more than a complex one that reaches
100%. Write code that is easy to delete, because most code eventually is.

Take Odin seriously: zero is initialization, errors are values, conversion is explicit, and
nothing happens that you did not write. Prefer `core:` and `vendor:` packages over new
dependencies; a foreign dependency needs a decision, not a habit.

`odin` moves. Verify a signature or a language rule against the compiler or the docs rather
than assuming; a quick experiment is cheaper than a wrong implementation.

## Package boundaries

Dependencies point inward, from the harness toward the foundation.

- Foundation packages never import `http`, `sse`, `ai`, `agent`, or `acp`.
- `layout` depends on nothing else in the repo. It is the renderer-neutral solver; every
  other package adapts to it.
- Only the root `nabla` package may import both the foundation and `agent`. A foundation package
  that needs something from the harness has the dependency backwards.

### When a package exists

A package here is a standalone library, and it must be describable without naming this
harness: `http` is the HTTP protocol, `term` is terminal control, `layout` solves layout,
`tui` is a terminal UI toolkit, `ai` is a model-provider client, `mcp` is the MCP protocol.
Another Odin project can take any of them and use it, so none of them carries Nabla's
business rules. No turn, session, request, tool-policy, model-catalog, or presentation
concept belongs in `http`, `sse`, `layout`, `term`, or `tui`, and no provider-specific
behaviour belongs in `http`. Code that only this harness uses, and that cannot be described
in a lower package's own vocabulary, belongs in `agent` or the root package.

Create a package when the subject is separable and reusable on its own, which is why the
foundation and library layers exist: Odin has no suitable library for layout, a terminal UI,
or HTTP, so each was written once and kept standalone. Adding a package or subpackage is a
decision, not the default move; prefer extending the package that already owns the subject.
A subpackage is justified when it has its own boundaries and consumers (`http/client`,
`agent/session`), never as a folder for code that fits badly. A name that sounds like a
library does not make a harness component reusable, and a package usable only by this
harness is worse than code placed in `agent` where its callers already live.

Facts belong to the layer that observes them; decisions belong to the layer that owns them.
A lower layer exposes its own protocol facts in its own vocabulary, and the harness decides
what is recorded, where, at which level, and for how long. Concretely: the transport reports
bytes, phases, and status; `ai` reports provider request and response facts; `agent` holds
the policy and the sink; the root package owns the process lifetime that frames them.

Keep each package buildable, testable, and green on its own. That property is what makes the
foundation reusable and the harness replaceable.

Tests live inside the package whose behavior they validate: focused unit tests in colocated
`<source>_test.odin` files, and broader package-level or end-to-end tests under `<package>/test/`.
A suite that cannot run under `odin test`, such as `term/test/lifecycle`, which forks a child
process, ships as an in-package executable harness instead, which `scripts/_lib.sh` discovers
through `nabla_harnesses`.

The harness stays presentation-free: `agent` produces data and writes to a caller-supplied
`io.Writer`. The presentation stack stays agent-free. Long term the TUI should reach the
harness through ACP and nothing else, so it can be pointed at another ACP-compatible harness.

## Working in this repo

Repository tasks go through **mise**: `mise tasks` lists them (`check`, `test`, `fmt`,
`build`). Each is a plain Bash script under `scripts/` that stays directly executable, so a
contributor without mise can run `./scripts/check` and get identical behavior; mise discovers the
task from the annotations at the top of the script. Read a script before changing it.

Prefer the native tools over the shell. Read, search, and edit through the dedicated tools rather
than `cat`, `grep`, `find`, `ls`, or `sed`, and reach for the shell only for what those cannot
express: running a build, a test, or a script, or a genuine pipeline.

Verification is part of the work, not a step after it: run `mise run check` and whichever tests
cover what you touched, and leave them green before committing. `mise run test` is the full
gate: every in-package suite in release and `-debug`, then the external harnesses.

Linux is the only target. Do not write Windows or macOS branches for platforms this project
does not build.

## Writing code

Prefer the smallest clear, correct change that fully solves the task. Understand the flow you are
changing before you edit it, and check whether existing code, the standard library, a native
platform feature, or an installed dependency already solves it.

Build only what the task requires: no speculative abstraction, flexibility, or boilerplate, and no
new dependency without a decision. Prefer deletion and reuse, and never trade correctness or
readability for a smaller diff.

Avoid magic values. Name any literal whose meaning is not obvious at the call site.

For a bug, inspect every caller of the procedure being changed, fix the shared root cause, and
check the sibling paths that reach it.

When a simpler approach meets the same requirements, say so and use it. Routine implementation
decisions are yours to make without stopping for approval.

Keep a hand-written source file to roughly 2000 lines or fewer and split it before going past
that. Generated files, lockfiles, and fixtures do not count. This is a hint rather than a hard
limit.

## Writing tests

Add a test only when its failure would tell you something is actually broken. An assertion on a
styling value, a color, or internal structure fails on harmless changes and passes on real bugs,
so leave it out.

## Commits and history

Version control is **Jujutsu (`jj`) only**; the Git repository underneath is an implementation
detail. Work in one coherent change at a time and close it as a commit, rather than letting
unrelated edits pile up in the working copy:

```sh
jj describe -m "<message>"   # name the change
jj new                       # close it; the next edit starts a fresh change
```

Titles are Conventional Commits, concise, and about the diff rather than the session:

```
feat(sse): write events in the event-stream format
fix(agent): keep the last event id when the id field is rejected
refactor(http): move the client into an http/client subpackage
```

Use `chore`, `feat`, `fix`, `refactor`, `test`, `docs`, or `build`. A body is optional: one or two
short paragraphs on intent and behaviour, or nothing when the title already carries it. Leave out
the walkthrough: the files touched, the commands run, and how you got there are visible in the
diff and belong in the pull request.

Keep the diff scoped to its change. A bug you notice on the way is its own commit or its own
later change rather than a passenger here, and code arrives when a need exists rather than in
anticipation of one.

## Comments and naming

Names carry the meaning: `snake_case` procedures and variables, `Ada_Case` types,
`SCREAMING_SNAKE_CASE` constants.

Document the contract a declaration cannot express on its own, such as ownership, lifetime,
preconditions, and error behavior, and delete a comment that restates the code or compensates
for a poor name. Comment only on non-obvious intent or constraints. Mark a deliberate shortcut
with a `ponytail` comment that names the limit and the upgrade path. Keep long rationale in
`docs/`, not inline, so the reasoning has one home that can be kept current.

## Writing style

No em-dashes. No mannered prose. Mannered prose substitutes metaphor and flourish for direct
statement: "a dial worth turning" instead of "a parameter worth varying", "earns its keep" instead
of "still matters". It exists to display the writer, makes the reader work harder, and drags in
connotations you did not choose. Say what you mean. When a literal phrase is available, use it.
