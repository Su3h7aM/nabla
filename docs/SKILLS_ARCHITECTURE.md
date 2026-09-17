# Skills architecture

Status: implementation design. None of the skills behavior described here is
implemented yet. This document specifies the first implementation, including
its deliberate limits. Existing code remains authoritative for the baseline.

## 1. Purpose and reference basis

Nabla discovers reusable task instructions through generic Agent Skills
conventions. It reads `AGENTS.md`, discovers skill directories under `.agents`,
and allows user-owned Nabla configuration skills to override generic skills.
There is no `Nabla.md`, proprietary skill format, or automatic import of another
harness's instruction files.

The reference basis is the complete 435-line study at
`/home/su3h7am/.opencode/plan/nabla-skills-reference-study.md`, including its
appendix and documented discrepancies. That path identifies the local research
artifact; implementation does not depend on the file being installed. The
contracts below are self-contained and are Nabla decisions, not claims about
what every reference harness implements.

Useful reference patterns:

| Reference | Pattern retained | Pattern not retained |
| --- | --- | --- |
| Goose, study sections 5.1 and 6.1 | A dedicated loading tool returns instructions into the ordinary tool loop | Repeated full discovery and reading every body during discovery |
| Pi, sections 3.4 and 6.4 | Metadata before instructions; explicit skill-relative resource paths | Package machinery, loose Markdown variants, and harness compatibility roots |
| fx, sections 5.3 and 6.3 | Bounded discovery, complete instruction loads, validation of selected identity | Location namespaces, capability ranking, installation, and ambiguity as the default collision policy |
| OpenCode V2, sections 5.2 and 6.2 | Loaded instructions become durable conversation content | Plugin services, watchers, event buses, and implicit source-order precedence |

The study distinguishes code from documentation and records disagreements in
section 12. Nabla must test its stated contracts rather than inherit undocumented
behavior from those implementations.

### Decisions

1. `AGENTS.md` supplies scoped, always-applicable instructions. It is not a skill.
2. Discovery produces metadata and selected paths, not loaded instruction bodies.
3. Exactly one valid definition wins for each skill name.
4. The session freezes its effective catalog and initial instruction prefix.
5. The model calls `list_skills` when needed and `load_skill` to obtain instructions.
6. A successful load returns the complete body in one ordinary tool result.
7. Loading appends conversation content. It never edits the stable prefix.
8. There is no permanent `loaded` flag, new chat state, script execution on load,
   or skill-specific permission language.

## 2. Current integration points

The current implementation already provides the required execution protocol:

- `agent/tool.odin` defines `Tool_Context`, `Tool_Definition`, `Tool_Execute`,
  `Tool_Result`, the JSON result envelope, and the sorted native registry.
- `agent/chat_tools.odin` prepares arguments, records dispatch before execution,
  records results afterward, and reports observer events.
- `agent/agent.odin` advances the existing state machine and validates response
  batches. `chat_session_tools_done` returns execution to `.Preparing`.
- `agent/chat_request.odin` projects committed context into provider messages.
  Normal instructions currently come from `AGENT_SYSTEM_PROMPT`.
- `agent/chat_record.odin` records request inputs. Its instruction selection must
  change together with the request builder, rather than keep a hardcoded prompt.
- `agent/compact.odin` appends checkpoints and retains coherent call/result runs.
- `agent/session/context.odin` reads the newest checkpoint plus uncovered history
  and recovers unanswered calls without rerunning tools.
- `agent/chat_session.odin` owns session-lifetime state and the frozen tool registry.
- `agent/xdg.odin` resolves configuration directories according to XDG.
- `agent/config.odin` currently loads provider configuration, not general harness
  settings. Extending it must preserve that behavior for existing callers.

[The tool architecture](TOOLS_MCP_ARCHITECTURE.md) describes the general tool
boundary. This design uses the current concrete code, not unimplemented MCP or
permission features from that document. In particular, a future general output
preview limit must not silently truncate a successful skill load.

## 3. Terms and lifetimes

A **source root** is a directory scanned for skills, with provenance and an
explicit position in the precedence list.

A **candidate** is a directory containing a literal `SKILL.md`. It can be invalid,
shadowed, or selected.

A **catalog** contains the selected valid skills, sorted by name, and diagnostics.
It contains no skill bodies. A **session snapshot** persists that catalog and the
exact initial instructions used for normal model requests.

A **load** reads the primary file of a selected catalog entry. Its output is an
observation of that file at that execution, not a registration or permission
change. A **resource** is any supporting file under the selected skill directory.

There are three independent lifetimes:

| Data | Lifetime | Owner |
| --- | --- | --- |
| Catalog and initial instructions | Session, including resume | Durable snapshot; `Chat_Session` owns a decoded copy |
| Loaded body before recording | One tool execution | Loader result, then serialized `Tool_Result` |
| Recorded skill text | Durable history; active until covered by compaction | Existing `Tool_Result_Entry` |

The snapshot freezes metadata, selected locations, and initial instructions. It
does not claim to snapshot the contents of every unread skill or supporting file.

## 4. Default paths and scope

### User roots

Resolve the Nabla root with the existing `xdg_directory(.Config)` and append
`skills`:

```text
$XDG_CONFIG_HOME/nabla/skills
```

If `XDG_CONFIG_HOME` is absent, empty, or relative, the existing resolver falls
back to:

```text
~/.config/nabla/skills
```

The generic user root is always:

```text
~/.agents/skills
```

Do not also search `~/.config/nabla/skills` when a valid nondefault
`XDG_CONFIG_HOME` is set. Resolve home through the existing OS helper. If home
cannot be resolved, report the missing user source; do not invent a relative
path. A valid XDG configuration root can still be used without home.

Discovery does not create missing roots. Installing and managing skills is out
of scope.

### Local scope

The session workspace is the directory Nabla was launched from, resolved
canonical: never process-global cwd changes or the cwd of a shell command.

The only local source is:

```text
<workspace>/.agents/skills
```

Nothing walks ancestor directories, and nothing consults version-control
state. Whether the workspace is a Git worktree, a Jujutsu workspace, or a
plain directory has no effect on discovery. A session that needs different
local skills starts in a different directory. The skills system and
`AGENTS.md` carry no repository concept at all; only programming-specific
skill content may refer to version control, as ordinary text.

If the workspace is the home directory itself, the local root and the generic
user root are the same directory. The canonical-root deduplication keeps the
higher-priority provenance and diagnoses the alias.

Discovery does not create missing roots. Installing and managing skills is out
of scope.

### Priority, highest first

1. Local `<workspace>/.agents/skills`.
2. Nabla user configuration skills.
3. Generic user `~/.agents/skills`.

The launch directory wins over everything else. This is deliberate: the
closest instruction source to the work at hand is the one the user can see
and edit.

There are no default `.nabla/skills`, `.claude`, `.opencode`, `.pi`, singular
`skill/`, URL, package, or builtin sources. Explicit arbitrary roots can be
added later without changing the ordered-root loader, but are not part of the
initial configuration contract.

### Selection and overriding

The validated, case-sensitive name is the identity. For each name, select the
first valid definition in source-priority order. A selected definition replaces
the whole skill: no merging of descriptions, bodies, metadata, or resources.
Every resource belongs to the selected directory.

Example:

| Root | Contents |
| --- | --- |
| `~/.agents/skills` | `pdf`, `git` |
| `<workspace>/.agents/skills` | `pdf`, `review` |
| `~/.config/nabla/skills` | `pdf`, `database` |

The final names are `database`, `git`, `pdf`, and `review`. `pdf` comes from
the workspace, `git` from generic user configuration, `database` from Nabla
configuration, and `review` from the workspace. With just generic `pdf` and
`git` plus Nabla `database`, all three remain.

Resolve candidates within each root before cross-root selection:

- Canonical aliases of the same candidate are deduplicated before name collision
  handling, after validating the logical name of each alias. Keep the
  highest-priority valid provenance; within one root keep the first valid
  logical path in bytewise sorted order. A discarded root or invalid alias
  never suppresses a valid candidate from another root.
- Two distinct valid candidates with the same name in one root make that name
  ambiguous in that root. Exclude both from selection there and diagnose both.
  A valid definition in a lower root can still win.
- Invalid candidates do not reserve names. If an invalid higher-priority
  candidate has the same directory basename as a selected lower candidate,
  report that the intended override failed and identify the fallback.
- Shadowed valid definitions produce structured diagnostics with winner and
  loser paths. They never appear twice in the model catalog.
- Canonical aliases of whole roots are checked against each source's authority
  before deduplication. Keep the highest-priority accepted root. Rejected
  project aliases cannot suppress a permitted user root.
- After selection, load errors never trigger fallback to a shadowed definition.

Missing directories are empty sources. An incomplete directory enumeration must
not produce a winner from the incomplete portion of that root: discard that
root's collected candidates and diagnose the scan failure. This prevents an
unseen same-root duplicate from changing an apparently deterministic result.

## 5. Directory structure and traversal

Canonical structure:

```text
skills/
  pdf/
    SKILL.md
    references/
      forms.md
    scripts/
      inspect.py
    assets/
      template.pdf
```

Grouping directories are allowed:

```text
skills/documents/pdf/SKILL.md
```

The name is still `pdf`; `documents` introduces no namespace.

Walk each root in bytewise pathname order. A directory containing `SKILL.md` is a
skill boundary. Stop recursion there, even when the primary file is malformed,
unreadable, or not regular. Its children are resources, not additional skills.
Loose Markdown files are ignored.

Skip `.git`, `.jj`, `.hg`, `.svn`, and `node_modules` during grouping traversal:
these are noise filters that keep the walk out of tool internals that happen to
sit inside a skills root, and discovery reads no version-control state. Other
dot directories are allowed. No ignore-file parser is needed for this
explicit skills tree. Bound depth and visited directories, detect canonical
cycles, and report exclusions caused by limits or link policy.

Discovery reads a bounded metadata prefix, ending at the closing frontmatter
line. It does not read the entire body or enumerate supporting files. Buffered
read-ahead is acceptable; requiring a body read or retaining body bytes is not.

## 6. Metadata and frontmatter

```yaml
---
name: pdf
description: >-
  Inspect, create, and modify PDF documents, including forms and page extraction.
---

# PDF work

Read references/forms.md before changing a form.
```

### Required fields

`name` is required, is at most 64 ASCII bytes, matches
`^[a-z0-9]+(-[a-z0-9]+)*$`, and equals the logical skill directory's basename.
There are no implicit aliases, case folding, path separators, consecutive
hyphens, or directory-name fallback for missing metadata.

`description` is required and nonempty. Decode its scalar, trim surrounding
whitespace, and collapse internal whitespace runs to one ASCII space for
catalog use. The normalized result must be valid UTF-8, contain no C0 or DEL
controls, and contain at most 1024 Unicode scalar values. Newline, carriage
return, and tab may occur in the decoded scalar only as whitespace to normalize;
other controls are invalid before normalization.

Unknown fields have no runtime meaning. This includes `license`, `compatibility`,
`metadata`, `allowed-tools`, and harness-specific activation flags. Their
syntactically supported values are skipped, not copied into a property bag.
`allowed-tools` neither grants access nor restricts the registered tools.

An empty or invalid UTF-8 body can pass metadata-only discovery but fails a load.
This distinction is intentional. Discovery promises usable metadata, not a
complete-file validation it did not perform.

### Parser contract

Use an Odin-native, bounded frontmatter parser with a documented YAML subset.
Do not claim full YAML support or parse recognized values by splitting on colons.
The installed compiler tree did not provide an identified YAML parser during
this design review. Adding a YAML dependency is not assumed by this design.

The first line must be exactly `---`; accept LF or CRLF and an optional UTF-8 BOM
before that line. The closing delimiter is an unindented line exactly `---`.
A missing close within `SKILL_MAX_FRONTMATTER_BYTES` is an error. Indented
`---` inside a block scalar is content, not a delimiter.

Supported syntax:

- Top-level unquoted keys with scalar values; spaces around the colon are
  accepted. Tabs are not indentation. Recognized values are text scalars with
  no implicit boolean, numeric, date, or null conversion. An empty value for a
  recognized field is invalid.
- Single-line plain strings. A comment starts at an unquoted `#` preceded by
  whitespace, not at every `#` or colon inside a value.
- Single-quoted strings with doubled apostrophes as escapes.
- Double-quoted strings with `\"`, `\\`, `\/`, `\n`, `\r`, `\t`, `\b`, `\f`, and
  `\uXXXX` escapes. Validate Unicode and paired surrogate escapes. Unsupported
  escapes fail rather than silently change text.
- Literal and folded block scalars using `|`, `|-`, `|+`, `>`, `>-`, or `>+`.
  Infer indentation from the first nonempty content line. Preserve more-indented
  text and blank-line paragraph breaks; fold only ordinary adjacent lines in
  folded scalars. Apply the stated trailing-newline chomping before description
  normalization. Explicit indentation indicators are unsupported.
- Blank lines and comments outside scalars.
- Unknown top-level fields with scalar values or indented block mapping/sequence
  values. Skip their full extent by indentation; nested `name` or `description`
  must never become a recognized top-level field. Require well-formed scalar
  delimiters while skipping, but do not implement the semantics of unknown maps.

Reject duplicate top-level keys, multiline quoted strings, implicit plain-scalar
continuations, flow collections, anchors, aliases, tags, merge keys, complex
keys, and unsupported syntax. A primary file using these forms is diagnosed as
unsupported metadata, not misinterpreted. A bounded parser is a compatibility
subset of the generic format, not a new Nabla frontmatter convention.

Record line and field information for errors. Tests must distinguish supported
unknown metadata from malformed recognized fields and unsupported YAML forms.

Metadata identity is SHA-256 over a versioned, length-prefixed encoding of the
validated name and normalized description. Do not hash ambiguous concatenation
or raw YAML formatting. The same decoded metadata has the same identity despite
comments, line endings, or unknown-field changes.

## 7. Data structures and package contracts

The following declarations describe required data, not a compiled patch. Use
ordinary structs, slices, enums, and explicit allocator ownership. Keep wire
encoding separate from filesystem logic.

In `agent/skills`:

```odin
Source_Kind :: enum {
    Unknown,
    Nabla_User,
    Project,
    Generic_User,
}

Root :: struct {
    source:       Source_Kind,
    logical_path: string,
    path:         string, // canonical absolute path when present
    authority:    string, // canonical workspace scope for local roots; empty for user roots
}

Skill :: struct {
    name:            string,
    description:     string,
    logical_path:    string, // logical SKILL.md path for provenance
    directory:       string, // canonical selected directory
    root_index:      int,
    metadata_digest: [32]u8,
}

Catalog :: struct {
    roots:       []Root,
    skills:      []Skill, // unique names, sorted bytewise
    diagnostics: []Diagnostic,
}

Loaded :: struct {
    body:           string,
    content_digest: [32]u8,
}

Error_Kind :: enum {
    None,
    Missing,
    Unreadable,
    Not_Regular,
    Invalid_Metadata,
    Unsupported_Metadata,
    Stale_Metadata,
    Invalid_Text,
    Too_Large,
    Outside_Authority,
    Changed_During_Read,
    Cancelled,
    Timed_Out,
    Allocation,
}

Load_Error :: struct {
    kind:   Error_Kind,
    line:   int,    // 0 when not applicable
    field:  string,
    detail: string,
}
```

`Diagnostic` holds a typed cause, root index, candidate path, optional field and
line, and optional winner/loser paths. Add diagnostic-only causes for missing
home, root enumeration failure, traversal limits, aliases, and shadowing. Error
formatting belongs to the caller. The package never prints directly.

Procedure contracts:

| Procedure | Contract |
| --- | --- |
| `discover(roots, allocator)` | Takes borrowed roots in highest-first order; returns an owned catalog and fatal error. Candidate errors live in diagnostics. No model or session access. |
| `find(skills, name)` | Binary search over the sorted slice; returns index and presence. No allocation. |
| `load(skill, root, control, allocator)` | Reads only the selected primary file; returns owned complete body or an error, never partial success. |
| `catalog_destroy` | Releases all nested owned strings and slices, including partial construction. |
| `loaded_destroy`, `load_error_destroy` | Release execution-owned data. Zero values are safe to destroy. |

`Read_Control` in this package contains an optional cancellation predicate of
type `proc() -> bool` and an optional absolute `core:time` monotonic deadline.
The agent supplies `chat_cancel_requested` and copies the active deadline from
`Tool_Control`. A zero control value has no cancellation or deadline. This one
predicate is an actual substitution boundary: it avoids importing `ai` or
reinterpreting its generation-bearing atomic interrupt token as a boolean flag.
The synchronous loader never retains the predicate. No callback registry or
filesystem interface is required for testing: tests use temporary directories.

Use a temporary name map during selection if helpful, then keep just the sorted
skill slice for lookup and rendering. Store indices rather than pointers into
arrays that can grow. The final catalog is immutable.

The caller allocator owns returned strings and containers. Parsing may borrow
prefix buffers only until discovery clones accepted fields. No temporary string
escapes into session state. No `any`, generic metadata map, arena, string
interning, `#soa`, reference count, or process-global catalog is needed.

## 8. Discovery and session initialization

The agent constructs source policy; `agent/skills` processes the ordered roots.

```text
canonical workspace and XDG/home resolution
  -> ordered roots
  -> root deduplication and bounded traversal
  -> metadata parsing and candidate diagnostics
  -> per-root duplicate resolution
  -> cross-root winner selection
  -> name-sorted catalog
  -> complete applicable AGENTS.md reads
  -> deterministic instruction rendering
  -> durable instruction snapshot
  -> first provider request
```

Do not install a partially built snapshot into `Chat_Session`. Build it in
caller-owned staging storage, persist it, then transfer ownership. The writer
claim already required by the session store serializes initialization.

Session rows are currently created when the first prompt is accepted. Initialize
the snapshot after that row exists and before recording the first normal model
request. A startup listing may use an ephemeral discovery, but that result is
not the session catalog until the snapshot commits. Prefer not to introduce a
second startup scan in the first implementation.

On resume, decode the existing snapshot instead of scanning. A session with an
intentionally empty catalog still has a snapshot. Missing snapshot and empty
catalog must not be confused.

Fatal filesystem initialization errors for required instructions, allocation
errors, and persistence failures prevent a provider request. Missing default
roots and invalid skill candidates do not prevent an otherwise usable catalog.

## 9. AGENTS.md and source policy

Read these complete files when building the snapshot:

```text
<workspace>/AGENTS.md
~/.agents/AGENTS.md
```

Nothing above the workspace is read. Deduplicate identical canonical-path and
scope pairs. A file reached at two different scopes remains two scoped
instruction records; deduplicating by path alone would lose its broader scope.
Render local guidance first, then personal guidance, with explicit source paths
and scopes. Apply the same UTF-8 and control-character validation as primary
skill bodies.

Instruction files accumulate; they are not same-name skill overrides. Local
guidance refines personal defaults. None can grant tools or override harness
restrictions, and explicit user task instructions take precedence over
conflicting file guidance.

Do not read `Nabla.md`, `CLAUDE.md`, `SYSTEM.md`, or
`~/.config/nabla/AGENTS.md`. The Nabla-specific path in this design overrides
skills, not personal instruction files.

Missing `AGENTS.md` files are normal. An existing applicable file that cannot be
read completely, exceeds the byte limit, or contains invalid text blocks
snapshot initialization with a source-specific error. Silently ignoring known
project instructions is not equivalent to having none.

Do not recursively inject every descendant `AGENTS.md`. Static guidance tells
the model to check for and read applicable nested files before working in a
descendant directory. Those reads use ordinary tools and append ordinary results.
An instruction found in one subtree does not govern unrelated subtrees.

The first implementation reads the two fixed startup files. Nested discovery is
model-directed, not a claimed security guarantee. Checking file-tool paths alone
could not enforce arbitrary shell behavior, so do not build a misleading
instruction-enforcement layer around `write` and `edit`.

### Configuration

Add one harness configuration value:

```lua
return {
  instructions = {
    project = false,
  },
  providers = {
    -- Existing provider configuration remains unchanged.
  },
}
```

Absent `instructions.project` means true. It must be a boolean when present.
Internally prefer `disable_project_instructions: bool`, so a zero-initialized
options value preserves default local discovery.

False disables both local skills and the local `AGENTS.md` from the launch
directory. Personal instruction and user skill roots remain available. This is
instruction source selection, not a filesystem sandbox; user-requested ordinary
reads still work. Snapshot the effective value so configuration edits do not
silently change an existing session. To apply a different value, create a new
session.

Extend the shared Lua decoding path to read harness options and provider sources
from one evaluation. Do not execute the config twice or make model catalog code
responsible for instruction discovery. Pass the decoded options explicitly into
session setup. No project Lua configuration is introduced.

## 10. Durable instruction snapshot

Add `Instruction_Snapshot_Entry` to `agent/session`:

```odin
Instruction_Snapshot_Entry :: struct {
    format_version: u32,
    instructions:   string,
    manifest_json:  string,
}
```

The `instructions` field holds the exact normal-request prefix. `manifest_json`
is a versioned, typed agent-owned document, not an arbitrary plugin dictionary.
It records:

- Workspace and effective local-source option.
- Effective project-instruction option and initial tool-enabled mode.
- Renderer and metadata-parser format versions. Version 1 describes this
  document's contracts; future semantic changes need an explicit compatibility
  path rather than silently reinterpreting a resumed catalog.
- Ordered roots, selected skills, normalized metadata, and metadata digests.
- AGENTS.md provenance, scope, content digests, and offsets into `instructions`.
- Catalog exposure mode, either inline or tool-only.
- Discovery diagnostics and selected-fallback provenance.

Do not duplicate complete AGENTS.md bodies inside the manifest. Their exact text
is already in `instructions`; byte offsets refer to the original inserted text,
not to source paths that would have to be reread. Validate offsets on decode.
The renderer rejects text controls and preserves body bytes, so offsets need no
lossy decoding convention.

`agent/session` validates the entry's version and required fields and owns its
storage. `agent` validates the typed manifest, index ranges, canonical path
shapes, unique sorted names, metadata constraints, digests, and byte offsets.
Unknown versions or corrupt manifests fail resume instead of triggering a fresh
scan that silently changes session meaning.

Storage work is explicit:

- Add the entry kind, union variant, name conversion, codec, validation, and
  destructor cases. Extend the existing snapshot read/destroy ownership path in
  `Context` and every history-kind switch or explicit skip list, including root
  conversation rendering, so bookkeeping cannot leak into displayed dialogue.
- Migrate the entries-kind CHECK constraint using the existing table-rebuild
  pattern without changing old rows.
- Add a partial unique index on session ID for `instruction_snapshot`.
- The entry has no related sequence or request number. It may be appended after
  the opening user entry, but is never projected as a conversation message.
- Add `instruction_snapshot_read` and an append operation requiring the existing
  writer claim. Reject a second snapshot.
- Exclude snapshots from the ordinary context-entry query and compaction seam.
  Return snapshot data and its sequence independently in `session.Context`.
- A checkpoint never replaces or hides the snapshot. Historical entry listing
  still includes it as initialization bookkeeping.

Read the decoded catalog once into `Chat_Session`. A nil `skills` borrow in a
tool context means unavailable, not an instruction to rescan. Request preparation
owns its loaded `session.Context`; do not retain a borrow into a destroyed prep.
The cached session catalog must come from the committed snapshot and is not a
second mutable source of conversation truth.

### Legacy sessions

An old session with no snapshot receives one at the next normal-request boundary
after recovery. Append it, report that instruction sources were initialized, and
record its sequence in subsequent request inputs. Earlier request records and
messages stay unchanged. This one-time feature migration changes the new request
prefix; loading individual skills afterward does not.

Manual compaction of an old session does not need to initialize skills. It uses
the existing summarization instructions and history.

## 11. Model catalog and tools

Register `list_skills` and `load_skill` as ordinary native tools. Keep them
registered even when the catalog is empty. Their schemas and descriptions are
static; do not put skill names in schema enums or generate one tool per skill.
They are not advertised when the session disables tools.

For a tool-enabled session, the stable guidance says:

- Skills provide specialized task instructions, not tool output or permissions.
- Load a clearly relevant skill, or one the user asks to use, before performing
  work that depends on it.
- Catalog metadata is not the complete instructions.
- If only a summary of a skill remains, load it again before relying on details.
- Resolve relative references from the returned skill directory.
- Read required references completely through ordinary tools.
- Wait for the load result before proposing dependent actions.
- When no catalog entry clearly matches, use `list_skills` or proceed without
  pretending a skill exists.

For tool-disabled sessions, include applicable AGENTS.md but no skill catalog
or guidance directing unavailable tools. Freeze this mode with the snapshot;
changing the tool-enabled mode requires a new session for this implementation.
Switching between tool-capable models need not change catalog bytes.

### Catalog rendering

Render normal instructions once in this order: the harness's base instructions,
static instruction-source and skill guidance, scoped AGENTS.md records from
section 9, then the catalog section. Tool-disabled sessions omit skill guidance
and the catalog but keep the base and applicable file instructions. Label each
AGENTS.md record with a JSON-escaped path and scope, followed by its exact body.
Use fixed separators and record body byte offsets during rendering. Source text
is instruction content, not a template or a source of replacement variables.

Render deterministic JSON name/description records in a clearly labeled catalog
section. The JSON serializer handles quotes, newlines, and structural escaping;
never interpolate unescaped metadata into XML attributes.

If the complete encoded list fits `SKILL_INLINE_CATALOG_BYTES`, include it. If
not, include only the count and directions to `list_skills`. Do not show an
arbitrary alphabetical prefix or silently shorten descriptions. An empty catalog
explicitly says no skills are available.

No skill body, supporting-file list, timestamp, mtime, or generated random
identifier belongs in the stable prefix. Diagnostics are reported to the caller
and retained in the manifest, not repeated as noisy instructions every turn.

### list_skills

Input fields, with `additionalProperties: false`:

| Field | Type | Default and constraint |
| --- | --- | --- |
| `query` | string or null | Empty means all; at most 4096 UTF-8 bytes |
| `offset` | integer or null | 0; nonnegative |
| `limit` | integer or null | 20; range 1 through 100 |

Normalize query whitespace and ASCII-fold case. Split into whitespace-delimited
terms. Every term must occur in the similarly folded name or description. An
exact full-name match ranks first; all remaining matches are in name order.
Non-ASCII text is matched byte-exact after whitespace normalization. State this
simple search contract rather than imply semantic retrieval.

Return `skills` records with full `name`, `description`, and source label, plus
`total_matches` and nullable `next_offset`. Offset beyond the end returns an
empty page. Do not overflow offset arithmetic. No-match says this query found
nothing, not that every possible query would fail.

The catalog is immutable, so offset pagination remains stable. Listing never
reads primary bodies, enumerates resources, or refreshes sources. A requested
valid name can be loaded without first appearing in a listing result. An empty
initialized catalog returns zero matches; a nil catalog binding is an internal
availability error and returns `Unavailable`, not a fresh scan. The same nil
binding rule applies to `load_skill`.

### load_skill

Input has one required string field, `name`, and `additionalProperties: false`.
Validate the canonical name syntax, then perform exact case-sensitive lookup in
the selected catalog. No path arguments, slash resource suffixes, substitutions,
arguments, or hidden legacy inputs are accepted.

A successful result uses the existing JSON envelope:

```json
{
  "status": "success",
  "message": "",
  "data": {
    "name": "pdf",
    "path": "/home/user/.config/nabla/skills/pdf/SKILL.md",
    "directory": "/home/user/.config/nabla/skills/pdf",
    "content_digest": "sha256-of-exact-returned-body",
    "complete": true,
    "instructions": "...complete Markdown body..."
  }
}
```

The actual digest is 64 lowercase hexadecimal digits, not the illustrative text
above. Strip only frontmatter and its closing line terminator. Preserve the
remaining body bytes, including leading blank lines and line endings. Reject a
whitespace-only body. Hash those exact returned bytes.

The JSON envelope, not its decoded object or a separately reformatted copy, is
what the driver persists and later projects. A successful result must fit the
encoded skill-result limit and pass serialization. Serialization or allocation
failure cannot become `Success` with an empty envelope.

The current `tool_content_json` can return an empty string on encoding failure.
Before integrating these tools, make the driver treat empty result content as
an internal execution failure, not valid model output. Best-effort record a
fixed, valid `Tool_Failed` JSON literal for that call, settle remaining committed
calls as `Not_Executed`, and finalize the turn as failed without another model
request. The fixed fallback is borrowed directly by the record append, never
placed in an owned string field whose destructor would free the literal. Any
failed append uses the existing storage-failure latch. If memory exhaustion
prevents even this settlement, terminate execution and let normal recovery close
unanswered calls after restart. Do not add a second persistence path inside the
tool or a new chat state.

## 12. Selected-file loading and resources

For `load_skill(name)`:

1. Resolve the selected catalog record. Never run discovery here.
2. Check cancellation and deadline; cancellation wins if both apply.
3. Open the catalog's canonical directory under its recorded authority policy.
4. Open `SKILL.md` relative to the directory descriptor, require a regular file,
   and perform bounded reads to EOF rather than trust only a prior size stat.
5. Check file identity/size/mtime on the opened descriptor before and after the
   read. Detect ordinary in-place edits and fail with `Changed_During_Read`.
   Atomic pathname replacement may leave the old descriptor stable; returning
   that complete old version is valid. Do not claim protection from a malicious
   writer restoring file metadata.
6. Reparse metadata from the same read buffer. Require the validated name and
   normalized description digest to match discovery. Directory-name validation
   still uses the recorded logical basename, not a symlink target's potentially
   different basename.
7. Validate the entire body as UTF-8 with no NUL, ESC, or other C0/DEL controls
   except tab, LF, and CR. Return an error rather than sanitize instructions.
8. Return the complete body and digest. Free buffers on every failure path.

A changed description or name reports stale metadata and asks for a new session.
A body-only edit is allowed on a later explicit load; the digest and stored
result identify that version. Unknown-field edits and YAML formatting changes
that preserve normalized metadata are allowed. No failed load selects another
root. No prior result is rewritten to match current disk content.

Do not cache loaded bodies separately. Repeated explicit loads read and return
the selected file again. This keeps ownership and invalidation simple and
provides complete text when the model explicitly requests it.

### Supporting files

Use existing tools rather than add another resource API:

- `read` loads referenced text using an absolute path under the returned directory.
- Continue paginated reads until required references are complete.
- `shell` can inspect resources or execute a script when the task requires it.
- Script execution uses existing execution controls and is never a load side effect.

Do not recursively list or inline resources. A skill should name what is needed;
the model may inspect its directory when necessary. The generic read tool's
workspace-relative semantics do not change globally. The skill guidance requires
using the reported directory explicitly.

Resource contents are live filesystem observations, not part of the metadata
snapshot. An external read named by a skill is an ordinary read under existing
tool policy, not an expansion of skill-loader authority.

## 13. State machine and persistence flow

Suppose the model has inspected code and decides it needs `pdf`.

1. It knows the name from the inline catalog, or issues `list_skills` and receives
   metadata through the normal tool loop.
2. It emits `load_skill({"name":"pdf"})`.
3. `chat_session_feed_tool_calls` validates the response batch and stages calls.
   The driver commits the response and calls before running effects.
4. `.Executing_Tools` produces the existing `.Run_Tools` effect.
5. `chat_prepare_call` admits arguments and records `Tool_Dispatch_Entry`.
6. The loader returns a complete body or ordinary failure result.
7. `chat_record_tool_result` records the exact JSON envelope linked to the call.
8. The observer receives the result only after it is recorded.
9. `chat_session_tools_done` checks the result count and returns to `.Preparing`.
10. `chat_prepare` reloads committed context. The result becomes a `.Tool`
    provider message alongside the call it answers.
11. The next request sees complete skill instructions and can follow them.

```text
Preparing -> Requesting -> Streaming -> Executing_Tools
                                         |
                                  committed result
                                         |
                                         v
                                     Preparing
```

There is no `Loading_Skill` state, separate activation message, new provider
message role, or backend callback that edits conversation. `Chat_State` and
`Chat_Effect_Kind` do not need additional members.

Add a typed borrowed catalog pointer to `Tool_Context`; both context construction
sites in `chat_run_tools` and `chat_prepare_call` must initialize it consistently.
It lives for the synchronous execution and must not be retained by a tool. Do
not pass `Chat_Session`, the session store, a service registry, or `rawptr` into
the loader. Tools still do not write durable history.

A batch can contain multiple independent skill loads. If a model batches a skill
load with a shell command that depends on the instructions, the command was
already proposed without seeing them. Sequential execution cannot fix that.
Guidance requires waiting for results; the harness does not attempt semantic
analysis of dependence or invent a second scheduling mechanism.

Skill listing and loading consume the normal tool-call and request budgets.
There is no exemption that allows an unbounded activation loop.

### Cancellation and recovery

- Cancellation before execution uses the existing `Not_Executed` result.
- A bounded read checks the cancellation predicate and deadline between
  operations and returns `Cancelled` or `Timed_Out` when observed.
- A completed read can legitimately be recorded as success if cancellation
  arrives afterward. The turn then follows the existing cancellation path.
- Cancelled turns still settle committed calls with results and do not launch
  another model request.
- A dispatch write failure prevents execution.
- A result write failure latches `storage_failed` and stops the turn. Never
  continue using instructions available only in memory.
- Recovery does not rerun loads. A dispatched call without a recorded result is
  `Unknown`; an undispatched call is `Not_Executed`, just as for other tools.

Reads are synchronous like current native file tools. Cancellation cannot
interrupt a kernel filesystem operation stuck on an unresponsive mount. A worker
or asynchronous I/O boundary would be needed for that guarantee; this design
makes no stronger promise than the existing local file tools.

## 14. Context, replay, and prompt caching

Normal request assembly uses the exact committed `instructions` snapshot bytes.
Request records include `instruction_snapshot_seq` and record the actual prepared
instruction string, rather than independently reconstructing it in
`chat_request_input_json`. Preserve old request decoding when that reference is
absent. Recorded context boundaries remain the ones actually projected.

For summarization request construction and cache policy, follow
[Context management and non-blocking compaction](CONTEXT_COMPACTION_ARCHITECTURE.md)
§7. A compaction request keeps the normal instruction snapshot, the tool inventory,
the effort, and the prompt-cache key, and appends the directive as the last message,
so the summarizer reads the conversation's warm prefix. It never reloads skills from
disk. A model change may alter provider configuration but must not rerender skills.

A skill load leaves all of these unchanged:

- Initial instruction bytes and catalog exposure mode.
- Tool definition bytes and deterministic advertisement order.
- Session prompt-cache key.
- Earlier user, assistant, call, and result content.
- Recorded Responses output and its verbatim replay where projection is faithful.

Only the normal response/call/result suffix grows. A stable cache key is not a
substitute for preserving bytes; it is the existing routing identity. Do not put
a mutable list of activated skills at the start of the request.

Within the same build and model/tool configuration, a resumed session uses the
same instruction bytes even if installed AGENTS.md files or metadata changed.
Cross-version tool-schema changes can naturally invalidate a tool prefix; this
feature does not promise byte-identical executors across program upgrades.

### Compaction

A successful skill load is ordinary conversation content. While its result is
in active context, the full instructions are available. If a checkpoint covers
it, only the summary remains unless the skill is loaded again.

Do not maintain `loaded[name] = true` as a session-lifetime state. Historical
loading and present complete instructions are different facts. The model decides
to reload based on the active conversation and the static guidance.

Extend summarization guidance to retain skill names, relevant decisions and
paths, and a reminder to reload complete instructions when details are needed.
A summary must not imply it retained an entire skill verbatim. Do not rely solely
on the summary obeying this instruction; the static normal prompt also says
summarized skill content requires a reload before relying on details.

Keep the existing coherent seam for tool call/result runs. Do not pin every
loaded skill forever or reinsert old results ahead of retained conversation.
No separate active-skill ledger or automatic replay of covered tool results is
needed.

Normal admission includes the full serialized tool result. If it exceeds the
remaining context budget, use the existing admission/compaction behavior or
fail with its actionable context error. Never silently truncate a successful
skill result to make a request fit. The complete file-size cap alone does not
guarantee model-context fit.

## 15. Filesystem authority and trust

A discovered skill can instruct the model to execute commands. Metadata validity
is not a trust decision, and loading cannot grant tools or bypass future general
approval policy. Nabla's current tools can access absolute paths; this feature
is not a sandbox.

User configuration roots are user-selected. Allow symlinked user roots and skill
directories, resolving them at discovery and retaining the selected canonical
location. A retargeted logical symlink does not redirect an existing session.
The canonical selected location is pinned, not its inode forever; ordinary
atomic file replacement is allowed subject to read-time validation.

workspace. A local symlink pointing outside the workspace is rejected. The same
skill can instead be discovered through a user root. Apply the workspace-scope
check to automatic AGENTS.md reads too.

After canonical selection, use directory-descriptor-relative opens. Reject new
symlinks along the selected canonical directory chain. A primary `SKILL.md`
symlink is allowed only if its target remains inside the selected skill
directory; use descriptor-relative containment enforcement for that read.
Disallow magic links and nonregular files. Open primary candidates nonblocking
and inspect the opened descriptor before reading so a FIFO cannot stall the
loader before its file-type check. Linux `openat2` with `RESOLVE_BENEATH` and
`RESOLVE_NO_MAGICLINKS` can enforce the contained primary read. If unavailable,
use a component-wise no-follow walk and reject primary links with a diagnostic
rather than silently weaken confinement. Apply the same opening policy during
metadata discovery so unsupported links are not advertised as loadable. Keep
this Linux-specific helper narrow.

Canonical root equality is not a raw string prefix test. Check actual path
components and opened locations. Grouping walks need canonical visited-directory
tracking so cycles cannot consume the whole scan budget.

A malicious writer controlling permitted files can replace their contents. Name
and description validation prevent accidental identity drift; they do not
authenticate instructions. No signatures, sandbox, remote fetching, installation,
or unattended script execution are part of this design.

## 16. Bounds and error policy

Initial named limits:

| Constant | Value | Meaning |
| --- | --- | --- |
| `SKILL_MAX_FRONTMATTER_BYTES` | 64 KiB | Prefix through closing delimiter |
| `SKILL_MAX_NAME_BYTES` | 64 | Validated ASCII identity |
| `SKILL_MAX_DESCRIPTION_RUNES` | 1024 | Normalized description |
| `SKILL_MAX_FILE_BYTES` | 256 KiB | Entire primary file |
| `SKILL_MAX_RESULT_BYTES` | 2 MiB | Encoded complete result, including JSON escaping |
| `SKILL_INLINE_CATALOG_BYTES` | 16 KiB | Complete encoded metadata list |
| `SKILL_MAX_DEPTH` | 32 | Descents below one source root |
| `SKILL_MAX_DIRECTORIES` | 16,384 | Visited directories per root |
| `SKILL_MAX_CATALOG_ENTRIES` | 4096 | Selected skills per session |
| `SKILL_MAX_MANIFEST_BYTES` | 32 MiB | Encoded snapshot manifest |
| `AGENTS_MAX_FILE_BYTES` | 256 KiB | One complete automatic instruction file |
| `AGENTS_MAX_TOTAL_BYTES` | 1 MiB | Aggregate raw automatic instruction text |
| `INSTRUCTIONS_MAX_BYTES` | 2 MiB | Final rendered initial instructions |

These are explicit refusals or diagnostics, never unmarked truncation. A
per-root traversal-budget failure discards that root as specified in section 4.
Exceeding selected-catalog, manifest, or aggregate instruction bounds aborts
initialization rather than persist an arbitrarily incomplete session snapshot.

The encoded result limit is separate from raw file size because JSON escaping
can expand content. `load_skill` must bypass any future generic preview/spill
policy that would replace a body with a partial preview. This is a complete-text
contract for this native tool, not a new general-purpose output framework. Its
maximum still bounds memory and context admission. `list_skills` can emit a
smaller page if an encoded result reaches its bound, with an accurate next offset;
it must always fit at least one valid full description or fail explicitly.

`list_skills` uses the same 2 MiB encoded result bound. No candidate or
metadata cache may grow without bound before these final-size checks: cap
candidate count at `SKILL_MAX_DIRECTORIES` per root, cap accumulated discovery
text at `SKILL_MAX_MANIFEST_BYTES`, and abort initialization on exhaustion.
Cap stored diagnostics at 4096, retaining a typed omitted count rather than
allocating one record for every later failure. Path errors and limit failures
are aggregated after the cap; selected metadata is never silently omitted.

Map errors into existing `Tool_Outcome` values:

| Condition | Outcome and behavior |
| --- | --- |
| Malformed tool fields or invalid name syntax | `Invalid_Arguments`; no file I/O |
| Valid but unknown name | `Tool_Failed`; a few deterministic suggestions |
| Selected file missing, unreadable, nonregular, or outside authority | `Tool_Failed`; no lower-root fallback |
| Metadata changed | `Tool_Failed`; explain stale catalog and new-session remedy |
| Oversized/invalid body or unstable read | `Tool_Failed`; no partial instructions |
| Observed execution cancellation/deadline | `Cancelled` / `Timed_Out` |
| Fatal allocation/serialization failure | Stop safely; never fabricate an empty success or continue without a durable result |

Diagnostic rendering is outside `agent/skills`. Escape terminal control bytes in
paths and messages before display. Bound frontend summaries and report the
number of omitted diagnostics; retain full bounded structured diagnostics in
the snapshot. Errors should identify paths without echoing whole file contents.

## 17. Refresh, explicit invocation, and exclusions

There is no live refresh in the first implementation. New sessions discover new
metadata and AGENTS.md. Resume restores the original snapshot. Explicit loads
observe body-only changes at selected locations and record the observed bytes.

A future refresh must occur at an idle/request boundary, persist a new version,
and tell the model what changed through append-only content. It cannot silently
mutate current instructions or redefine identities while calls are in flight.
That work is not needed to implement this contract now.

An explicit user request such as "use the pdf skill" goes through the same model
loading path. Do not parse natural language, `$name`, or shell-like arguments in
the harness. No slash command or deterministic skill attachment is required for
the first implementation. Such a UI can later call a harness operation that
records complete text; it must not inject unrecorded frontend state.

Also excluded: skill CRUD, installation, URLs, packages, builtins, dependency
graphs, argument expansion, executable hooks, automatic resource recursion,
per-skill tool registration, embeddings, and a plugin/service abstraction.

## 18. Implementation boundaries and sequence

### Package ownership

| Location | Responsibility |
| --- | --- |
| `agent/skills` | Format, traversal, identity, ordered-root resolution, complete primary reads, diagnostics |
| `agent` | XDG/project policy, AGENTS.md, Lua harness options, snapshot manifest/rendering, native tool adapters, compaction guidance |
| `agent/session` | Snapshot persistence and retrieval, schema/codec work, request references, unchanged ordinary result history and recovery |
| Root executable | Pass configuration and workspace into setup; render notices and failures through existing observer/UI paths |
| `ai` | Existing provider transport and message projection contracts only |
| Foundation packages | No skills or harness dependencies |

The storage package does not scan disk. The loader does not call models. Tools
do not access the store. Presentation does not resolve precedence or read skill
files independently. Future ACP integration must expose harness-owned data and
operations, not move the filesystem implementation into the TUI.

Suggested files, not new abstraction layers:

```text
agent/skills/skills.odin        types, errors, ownership
agent/skills/frontmatter.odin   bounded metadata parser
agent/skills/discovery.odin     traversal and precedence
agent/skills/load.odin          selected primary read
agent/instructions.odin         paths, AGENTS.md, manifest, rendering
agent/tool_skills.odin          list_skills and load_skill adapters
agent/session/                  snapshot schema, codec, history/context changes
```

Split policy/rendering files further only when size or distinct responsibility
justifies it. Keep tests beside the behavior they validate.

### Delivery order

1. Implement parser and loader package with fixture tests, then discovery and
   precedence. No model integration yet.
2. Add typed harness options, instruction rendering, snapshot persistence,
   resume handling, and request provenance. Test legacy migration and checkpoint
   retrieval before exposing resources.
3. Add native tools and borrowed catalog access. Verify exact provider-visible
   tool results through both supported API projections.
4. Add compaction guidance and full lifecycle tests, then document the actual
   user-facing format and path rules without claiming unsupported syntax.

Each change must be buildable and testable on its own. Do not ship an intermediate
state that advertises a catalog without a functioning loading mechanism.

## 19. Acceptance tests and review checklist

Use temporary filesystem fixtures and fake provider responses; no network or
real model is needed to prove the loader and state-machine contracts.

### Format and discovery

- LF/CRLF, optional BOM, quoted values, comments, block folding/chomping,
  Unicode escapes, supported nested unknown metadata, and exact body boundary.
- Missing/duplicate fields, bad names, directory mismatch, invalid UTF-8,
  unsupported YAML forms, prefix overflow, and missing delimiter diagnostics.
- Discovery succeeds with valid metadata even when the unread body is invalid;
  loading then fails rather than claiming discovery validated it.
- Grouping recursion, boundary short-circuit even for invalid skills, loose-file
  exclusion, traversal limits, cycles, canonical aliases, and incomplete scans.
- XDG absolute override and fallback, unresolved home, and user-root
  classification.

### Priority and identity

- Generic `pdf`/`git` plus Nabla `database` yields all three.
- Local `pdf` replaces generic and Nabla `pdf`, with resources from the local
  directory only.
- Nabla configuration wins below local; same-root distinct duplicates are
  excluded.
- Invalid higher-priority candidates permit a diagnosed fallback.
- Deletion, metadata changes, retargeted aliases, and read failure never select
  a shadowed candidate after initialization.
- Body-only replacement returns a new digest without modifying prior history.
- Project escapes, allowed user aliases, primary-link policy, and concurrent
  replacement checks exercise real filesystem behavior. Here "escapes" means a
  local root resolving outside the workspace, not anything about repositories.

### Instructions, storage, and context

- Applicable AGENTS.md order and scope, complete-read failures, aggregate limits,
  local-source-disable mode, and no proprietary instruction-file discovery.
- Empty catalog still persists a snapshot. Second snapshot is rejected.
- Legacy migration preserves old rows; snapshot decoding rejects corruption.
- Resume and checkpoint context restore identical instruction bytes after disk
  changes. Snapshot bookkeeping never becomes a user or assistant message.
- Inline/tool-only catalog boundary, search matching, deterministic pagination,
  full descriptions, no-match, and out-of-range offsets.

### Execution and cache invariants

- Scripted model first lists metadata, then calls `load_skill`, then receives
  the full body only in the next request's tool result.
- No body appears in initial instructions or listing results.
- Successful loads preserve exact JSON result bytes in storage and replay.
- Instructions, tool schema/order, cache key, and earlier messages are identical
  before and after the appended skill call/result suffix.
- Responses verbatim output remains replayable and is not duplicated; Chat
  Completions preserves valid assistant-call/tool-result grouping.
- Multiple loads, invalid arguments, budget refusal, cancellation, persistence
  failure, crash recovery, and result-count settlement use existing semantics.
- Compaction keeps coherent call/result runs and permits explicit reload when
  earlier complete instructions were summarized.
- Oversized result/context paths fail or compact explicitly, never deliver
  partial instructions as a successful load.
- Leak-tracking tests cover discovery failure, load failure, snapshot decode
  failure, partial allocation, and normal destruction.

Implementation verification uses the repository tasks:

```sh
mise run check
mise run test agent/skills
mise run test agent/session
mise run test agent
mise run test
```

Run supported sanitizer configurations for the filesystem and ownership changes.
These are implementation gates; writing this design document does not constitute
passing the future feature tests.

The design is ready for implementation when each of these facts remains true:
there is one selected definition per name, discovery never stands in for complete
loading, a tool result is the only model-driven activation record, the snapshot
survives compaction and resume, and no unrecorded filesystem refresh can alter a
request's stable prefix.
