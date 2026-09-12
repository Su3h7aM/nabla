# Nabla

A terminal layout and presentation stack, and a coding agent harness built on it — one Odin
monorepo.

The foundation (`text`, `input`, `term`, `layout`, and `tui` with its `widgets` subpackage) is
reusable by any Odin program and knows nothing about models or agents. Above it sit the libraries
(`http` with its `client` subpackage, `sse`, `ai`, `acp`) and then the harness (`agent`,
`cmd/nabla`). Each layer depends only on the ones below it. See [AGENTS.md](AGENTS.md) for the
philosophy and the package boundaries.

## Status

Under construction. The two source repositories are being moved in; see the current
milestone tracker in `docs/` once it lands.

## Tasks

```sh
mise run check     # type-check and vet every package
mise run test      # in-package suites (release + -debug) and the external harnesses
mise run fmt       # format owned sources (vendored code is never touched)
mise run build     # prove every package links
```

Each task is a plain Bash script under `scripts/` and runs without mise. `mise tasks` lists
them.
