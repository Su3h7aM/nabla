# Nabla

A monorepo in three layers that share one philosophy:

- **Foundation** — `text`, `input`, `term`, `layout`, `tui`, `widgets`. Reusable by any Odin
  program: the terminal, layout, and text stack knows nothing about models, agents, or HTTP.
- **Libraries** — `http` (with its `client` subpackage), `sse`, `ai`, `acp`. Each stands on its
  own: HTTP and SSE know nothing about agents, and the model client knows nothing about the
  turn loop that drives it.
- **Harness** — `agent` and the `cmd/nabla` executable. A coding agent built on top of both.

The harness is one consumer of the layers beneath it, not their owner.

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
- Only `cmd/nabla`, `examples/`, `tests/`, and `demo/` may import both the foundation and
  `agent`. A foundation package that needs something from the harness has the dependency
  backwards.

Keep each package buildable, testable, and green on its own. That property is what makes the
foundation reusable and the harness replaceable.

Some suites are written against a package-local assertion harness rather than `core:testing`'s
`@(test)` declarations, so `odin test` on those packages would compile them and report success
while running nothing. They run as external executables under `tests/` instead, which is why
`scripts/_lib.sh` names them in `NABLA_HARNESS_TEST_PACKAGES`.

The harness stays presentation-free: `agent` produces data and writes to a caller-supplied
`io.Writer`. The presentation stack stays agent-free. Long term the TUI should reach the
harness through ACP and nothing else, so it can be pointed at another ACP-compatible harness.

## Working in this repo

`mise run <task>` drives the work; `scripts/` holds the tasks and each one runs as plain Bash
too. Read a script before changing what it does.

Verification is part of the work, not a step after it: run `./scripts/check` and whichever tests
cover what you touched, and leave them green before committing. `./scripts/test` is the full
gate — every in-package suite in release and `-debug`, then the external harnesses.

Linux is the only target. Do not write Windows or macOS branches for platforms this project
does not build.

## Commits and history

Version control is **Jujutsu only**; the Git repository underneath is an implementation detail.
Work in one coherent change at a time and close it as a commit, rather than letting unrelated
edits pile up in the working copy:

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
the walkthrough — the files touched, the commands run, and how you got there are visible in the
diff and belong in the pull request.

Keep the diff scoped to its change. A bug you notice on the way is its own commit or its own
later change rather than a passenger here, and code arrives when a need exists rather than in
anticipation of one.

## Comments and naming

Names carry the meaning: `snake_case` procedures and variables, `Ada_Case` types,
`SCREAMING_SNAKE_CASE` constants.

Document the contract a declaration cannot express on its own — ownership, lifetime,
preconditions, error behavior — and delete a comment that restates the code or compensates
for a poor name. Keep long rationale in `docs/`, not inline, so the reasoning has one home
that can be kept current.
