# Instructions and skills

Status: required target. Discovery, snapshots and loading already exist, but the source
is not a constraint on future implementation. This document owns instruction semantics;
[tools](TOOLS_MCP_ARCHITECTURE.md) owns execution/results and
[context](CONTEXT_COMPACTION_ARCHITECTURE.md) owns projection/compaction.
[SKILLS.md](SKILLS.md) is the shorter current user reference, not a second architecture.

## Minimal model

`AGENTS.md` supplies scoped instructions. A skill supplies metadata plus a body loaded
on demand. Neither is a tool permission, executable hook, subagent definition or package.
Discovery reads metadata, not all bodies and resources. One selected catalog and exact
initial instruction snapshot are frozen for the session and restored on resume.

A skill load is an ordinary recorded tool result. No activation event, permanent
`loaded` flag, skill state machine, file watcher, body cache, embedding service or
separate resource API. A historical load does not prove the complete body remains in
active context after compaction. The model explicitly reloads details when needed.

Keep format/traversal/loading in `agent/skills`, source policy and snapshot rendering
in `agent`, and persistence in `agent/session`. The loader knows no session or model.
Its allocating results name the caller allocator; its cancellation predicate is a
narrow synchronous borrow, not a hidden global turn token.

## Sources and selection

Canonicalize the launch workspace once, without process-wide cwd changes or VCS
inspection. Default skill roots, highest priority first:

1. `<workspace>/.agents/skills`.
2. `$XDG_CONFIG_HOME/nabla/skills`, falling back to `~/.config/nabla/skills` through
   the existing XDG resolver when appropriate.
3. `~/.agents/skills`.

Read startup instructions from `<workspace>/AGENTS.md` and `~/.agents/AGENTS.md`.
No ancestor walk, repository detection, proprietary instruction filename, remote
source or import from another harness's configuration. `instructions.project = false`
disables both local roots and local startup instructions, not personal guidance or
ordinary user-authorized file reads.

Missing roots/files are normal. An existing applicable instruction file that cannot
be read completely or safely is a fatal snapshot error, not an empty instruction.
Instructions accumulate with explicit scope/provenance; local guidance refines personal
defaults and explicit user instructions prevail over conflicting file guidance. These
are model instructions, not an OS security mechanism. Nested AGENTS files are read
through ordinary tools when relevant rather than recursively injected at startup.

Select by validated case-sensitive skill name. First valid definition by root priority
wins as a whole. Distinct same-name candidates within one root make that name ambiguous
there; diagnose them and permit a valid lower-root candidate. Invalid candidates do
not reserve names. Deduplicate canonical aliases only after authority checks, retaining
valid higher-priority provenance. A failed/incomplete root scan contributes no partial
winner. After selection, load failure never falls back to a shadowed skill.

Traverse grouping directories in stable bytewise order. A directory containing literal
`SKILL.md` is a boundary even if malformed; its children are resources, not nested
skills. Ignore loose Markdown and known VCS/dependency internals. Bound depth, visited
directories, candidate text, selected entries and diagnostics; report omitted diagnostics.
No ignore-file engine is needed for these explicit roots.

## Metadata and reads

A bounded frontmatter parser supports a documented YAML subset, not colon splitting
or a claim of full YAML. Read through the closing delimiter without retaining bodies.
Required fields:

- `name`: at most 64 ASCII bytes, lowercase alphanumeric groups joined by single
  hyphens, matching the logical skill directory basename.
- `description`: nonempty UTF-8, normalized whitespace, no remaining controls, at
  most 1024 Unicode scalar values.

Support LF/CRLF, optional BOM, top-level plain/single/double-quoted scalars, comments,
literal/folded blocks with chomping, and bounded skipping of unknown block metadata.
Validate escapes and Unicode. Reject duplicate keys, anchors, aliases, tags, merge keys,
flow collections, unsupported multiline forms and malformed delimiters explicitly.
Unknown fields, including allowed-tools, grant no runtime capability. Use an installed
suitable parser if one becomes available; do not add a foreign YAML dependency by habit.

Hash normalized identity with an unambiguous versioned encoding using core SHA-256.
On load, read the selected primary file completely under its recorded authority,
reparse metadata from that same buffer, and require matching identity. A body-only
change is a new observed version and may load; name/description drift requires a new
snapshot. Preserve body bytes after frontmatter and hash the exact returned body.
Reject whitespace-only or invalid/control-bearing text rather than sanitize instructions.

Use descriptor-relative regular-file reads with bounded growth, cancellation checks,
and before/after identity metadata for ordinary concurrent-edit detection. Atomic file
replacement can legitimately return the complete old opened file. This does not
authenticate a malicious writer.

User roots may resolve through user-chosen symlinks at discovery. Local sources must
remain within workspace authority. Pin the selected canonical location, not a mutable
logical alias. Contained primary links need Linux descriptor-relative enforcement;
otherwise reject them explicitly. No magic links, FIFO blocking before type checks,
raw string-prefix containment checks or silent weakening of confinement. Reuse core
filesystem facilities and isolate necessary Linux calls in a narrow helper.

Supporting files are ordinary tool reads relative to the returned skill directory.
Loading never recursively includes them or executes scripts. Model-directed ordinary
reads remain subject to ordinary tool authority, not a skill-specific permission system.

## Snapshot and request stability

Collect sources, discover metadata, render instructions and encode the manifest in
separate helpers with typed failure results. Build a complete candidate, persist it,
then publish the decoded session copy. Resume decodes the stored snapshot; an empty
catalog is distinct from no snapshot. Corrupt or unsupported snapshots fail explicitly
rather than silently rescan.

Store exact instruction bytes once and a typed versioned manifest containing ordered
retained roots, selected canonical locations, metadata digests, source/scopes, effective
options and catalog exposure. Indices refer to the roots actually retained, not the
original configured list. Validate indices, uniqueness, paths and offsets on decode.
Do not duplicate full instruction bodies in the manifest or create a dynamic metadata
property bag. Legacy handling is an explicit migration decision, not a growing chain
of guessed root-rebinding rules.

Render base instructions, source/skill guidance, scoped startup files, then metadata in
fixed order. Include the complete catalog only when it fits the inline allowance;
otherwise provide count and listing guidance, never an arbitrary prefix. Skill bodies,
mtimes, mutable loaded lists and per-request IDs stay out of the stable prefix.
Tool-disabled requests must not instruct the model to call unavailable skill tools.
Snapshot tooling mode must agree with effective request capability; do not silently
preserve stale directions after a capability change.

A checkpoint cannot hide or replace the snapshot. Loading a body appends a normal
result suffix and does not rerender instructions, change schemas or rotate cache identity.
Instruction refresh is future explicit boundary work, not an automatic scan on retry.

## Listing and loading

`list_skills` pages immutable name/description records with deterministic simple text
matching, exact-name preference and an accurate cursor. It never reads bodies or
refreshes sources. `load_skill` takes one exact name, returns the complete body,
canonical directory and content digest, and has no path/argument-expansion variants.
A missing catalog binding is Unavailable, not an instruction to rescan.

Successful complete loads obey the same encoded result limit as every tool. If a body
does not fit, fail explicitly before claiming complete delivery. There is no 2 MiB
skill-only exception to the shared 64 KiB envelope limit. Listing can reduce its page
size to fit while retaining complete descriptions. Generic context spill may replace
a complete retained load with a handle; guidance must require retrieving all pages
before relying on the instructions. A preview or summary is not a complete skill.

When loaded inside Code Mode, the body is initially visible to Lua only. The model
must receive or retrieve it before authoring dependent actions. Serializing a skill
load and an already-authored shell command does not establish semantic dependence.
Do not add a generic dependency graph to attempt that inference.

## Acceptance and exclusions

Test precedence, aliases, incomplete scans, metadata-only discovery, strict loading,
body-only changes, no fallback on stale identity, containment and concurrent replacement.
Snapshot/resume must preserve bytes despite disk changes. Test complete result sizing,
context handles, child projection and reload after compaction. Allocation failure must
unwind partial catalogs and must never return an empty successful instruction.

Out of scope: skill installation/CRUD, package sources, URLs, per-skill tool registration,
activation ledgers, semantic routing votes, automatic resource expansion, executable
hooks on load, and static subagent roles. Config hooks belong to
[customization](CUSTOMIZATION_ARCHITECTURE.md), not skill metadata.
