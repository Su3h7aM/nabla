# Nabla

A terminal layout and presentation stack, and a coding agent harness built on it — one Odin
monorepo.

The foundation (`text`, `input`, `term`, `layout`, and `tui` with its `widgets` subpackage) is
reusable by any Odin program and knows nothing about models or agents. Above it sit the libraries
(`http` with its `client` subpackage, `sse`, `ai`, `acp`) and then the harness (`agent` and the
root `nabla` package). Each layer depends only on the ones below it. See [AGENTS.md](AGENTS.md)
for the philosophy and the package boundaries.

## Status

Under construction. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) describes the target harness.

## Tasks

```sh
mise run check     # type-check and vet every package
mise run test      # in-package suites in debug mode
mise run fmt       # format owned sources (vendored code is never touched)
mise run build     # build the executable
mise run build --release  # optimize with thin LTO
mise run build --debug    # include debug information
mise run build web        # build one library as a shared object
```

Each task is a plain Bash script under `scripts/` and runs without mise. `mise tasks` lists
them.
