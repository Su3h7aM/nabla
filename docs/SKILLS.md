# Skills

Nabla discovers reusable task instructions through generic Agent Skills
conventions. Skills are directories containing a `SKILL.md` file with `name`
and `description` frontmatter. Discovery records metadata and selected paths;
`load_skill` returns one complete body as an ordinary tool result.

## Sources

Highest priority first:

1. `$XDG_CONFIG_HOME/nabla/skills`, normally `~/.config/nabla/skills`.
2. Project `.agents/skills`, nearest workspace directory first, up to the
   repository boundary marked by `.git` or `.jj`.
3. `~/.agents/skills`.

Nabla configuration wins over all generic roots, including project roots.
Missing directories are empty sources. The validated, case-sensitive `name`
is the identity: one valid definition wins per name with no merging. A valid
definition in a lower root can still win when a higher root is invalid or
ambiguous. After selection, load errors never fall back to a shadowed
definition.

Configure project instruction sources in `config.lua`:

```lua
return {
  instructions = {
    project = false,
  },
  providers = {},
}
```

Absent `instructions.project` means true. False disables project skills and
automatic project `AGENTS.md` loading. Personal instructions and user skill
roots remain available.

## AGENTS.md

Scoped, always-applicable instructions accumulate separately from skills:

```text
~/.agents/AGENTS.md
<project-boundary>/AGENTS.md
...
<workspace>/AGENTS.md
```

Personal guidance renders first, then project guidance from outermost to
innermost. Missing files are normal. An existing applicable file that cannot
be read completely blocks session start rather than being silently ignored.

## Tools

`list_skills` pages metadata with stable name ordering. `load_skill` takes
one canonical `name` and returns the complete body, its directory, and the
SHA-256 of the exact returned bytes. Relative references resolve from the
returned skill directory through ordinary tools. If only a summary of a skill
remains in context, load it again before relying on details.

## Sessions

The first request freezes the effective catalog and exact instruction prefix
in an `instruction_snapshot` entry. Resume restores that snapshot instead of
rescanning, so installed files can change without altering a running session.
Loaded skill text is ordinary conversation content subject to compaction.
