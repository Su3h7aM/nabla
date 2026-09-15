# Skills

Nabla discovers reusable task instructions through generic Agent Skills
conventions. Skills are directories containing a `SKILL.md` file with `name`
and `description` frontmatter. Discovery records metadata and selected paths;
`load_skill` returns one complete body as an ordinary tool result.

The skills system has no relationship with source repositories. Nothing in
discovery, loading, `AGENTS.md`, or the system prompt looks at Git, Jujutsu, or
any other version-control state. The only inputs are the directory Nabla was
launched from, the user's home, and Nabla's configuration directory.

## Sources

Highest priority first:

1. `<launch-directory>/.agents/skills`, the skills of the directory Nabla was
   launched from.
2. `$XDG_CONFIG_HOME/nabla/skills`, normally `~/.config/nabla/skills`.
3. `~/.agents/skills`.

Local skills win over all other sources. Missing directories are empty
sources. The validated, case-sensitive `name` is the identity: one valid
definition wins per name with no merging. A valid definition in a lower
source can still win when a higher source is invalid or ambiguous. After
selection, load errors never fall back to a shadowed definition.

Configure local instruction sources in `config.lua`:

```lua
return {
  instructions = {
    project = false,
  },
  providers = {},
}
```

Absent `instructions.project` means true. False disables the launch
directory's skills and its `AGENTS.md`. Personal instructions and the Nabla
configuration root remain available.

## AGENTS.md

Scoped, always-applicable instructions accumulate separately from skills:

```text
<launch-directory>/AGENTS.md
~/.agents/AGENTS.md
```

Local guidance renders first, then personal guidance. Missing files are
normal. An existing applicable file that cannot be read completely blocks
session start rather than being silently ignored. Nothing walks ancestor
directories: only the launch directory and the home directory contribute.

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
