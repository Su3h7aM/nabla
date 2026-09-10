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

Version control is **Jujutsu only**; the Git repository underneath is an implementation
detail. One logical change per commit, described in the imperative mood.

`mise run <task>` drives the work; `scripts/` holds the tasks and each one runs as plain Bash
too. `./scripts/check` must pass, and `./scripts/test` is the gate: it runs every in-package
suite in release and `-debug`, then the external harnesses. Read a script before changing
what it does.

Linux is the only target. Do not write Windows or macOS branches for platforms this project
does not build.

## Comments and naming

Names carry the meaning: `snake_case` procedures and variables, `Ada_Case` types,
`SCREAMING_SNAKE_CASE` constants.

Document the contract a declaration cannot express on its own — ownership, lifetime,
preconditions, error behavior — and delete a comment that restates the code or compensates
for a poor name. Keep long rationale in `docs/`, not inline, so the reasoning has one home
that can be kept current.
