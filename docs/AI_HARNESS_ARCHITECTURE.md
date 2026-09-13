# AI Harness Architecture

Internal engineering reference. Decisions, invariants, boundaries, and open product questions for
the `ai` / `agent` stack. Not a tutorial; no rationale beyond what keeps a rule from looking
arbitrary.

Status: **specification only — not implemented.** Section 13 maps the current code onto these
boundaries and is the starting point for implementation.

---

## 1. Invariants

1. **First defined value wins.** Enrichment is additive and never overwrites a resolved field.
2. **One resolved catalog is the sole source of truth** for provider/model metadata. No second
   lookup table, no provider-local capability constants, no model-name heuristics.
3. **Absent is not zero.** Every optional catalog field carries an explicit presence flag. A
   configured `0`, `false`, or `""` is a resolved value; an omitted field is unknown.
4. **Durable conversation state is not the provider request.** The request is a derived
   projection rebuilt each time from conversation + catalog + config.
5. **The core never knows a provider or model by name.** Provider behaviour differences live in
   the provider implementation; model differences live in the catalog.
6. **Nothing in the core owns presentation, terminal, or ACP.**
7. **History is never deleted by budget management.** Compaction moves a window; it does not
   destroy the record.

---

## 2. Enrichment pipeline

```
user configuration          (Lua config, authoritative for anything it states)
        ↓  fill missing fields only
provider /models discovery  (live, per provider)
        ↓  fill still-missing fields only
models.dev catalog          (vendored/remote shared catalog)
        ↓
Resolved Catalog            ← the only thing the runtime reads
```

Per-field, per-entity merge. Later stages fill gaps; they never replace.

Worked example (the rule, not a special case):

| field | user | /models | models.dev | resolved |
|---|---|---|---|---|
| `context_window` | 500000 | 1000000 | 1000000 | **500000** |
| `max_output` | — | 32000 | 32768 | **32000** |
| `reasoning` | — | — | present | from models.dev |

Rules:

- **Granularity is the field**, not the entity. A source that supplies only `max_output` for a
  model still allows models.dev to supply `reasoning` for the same model.
- **Presence flags drive the merge.** Merging checks `field_present`, never `field == 0`.
  Zero-value checks are forbidden; they cannot express "explicitly disabled" and are the bug this
  design exists to prevent.
- **A composite field merges recursively** (`provider.authentication.*`, `model.reasoning.*`,
  each modality list). Lists are all-or-nothing per field: a present list is not appended to.
- **Merge is order-dependent only in the sense of stage order.** Within a stage, one source is
  authoritative for each entity.

### 2.1 Model list enrichment

The user configuration does **not** define a closed model list.

- Configuring one model adds that model; `/models` and models.dev may add others.
- The union of all three origins forms the resolved model set, minus explicit exclusions.
- A model origin is recorded (for diagnostics and for "where did this value come from"), but is
  not part of identity.

### 2.2 Model identity

Canonical identity is the pair `(provider_id, model_id)` — two separate strings, matched
exactly. A presentation string such as `"provider/model"` is never parsed, split, or used as a
key. Provider and model ids come from the source that introduced the entity and are not
rewritten by a later stage.

### 2.3 Unknown models: the runtime defaults

When the three sources leave a model without metadata, the runtime supplies exactly two defaults
and invents nothing else. This is not a fourth source: it applies only after every source has been
consulted, and it can only fill what nothing stated.

**Context window: 128K.** A model no source described runs with `CHAT_DEFAULT_CONTEXT_WINDOW`
(128 * 1024), applied where the resolved model becomes a session, so a window is always present and
admission has something to bound a request against. An explicit window is used as stated, including
an explicit zero -- presence decides, not the value -- and a stated zero refuses every request
through the existing admission check rather than silently becoming 128K. Whether the window was
assumed is reported to the observer, so running on a default is visible rather than
indistinguishable from a fact.

**Reasoning: nothing is sent.** Reasoning stays unspecified and the provider applies its own
default. `chat_build_request_into` puts `reasoning_effort` on the wire only when an effort was chosen,
and `chat_session_set_effort` accepts a level only if it appears in the model's level list. A model
no source described has an empty level list, so no effort can be set and no effort, level, budget,
or equivalent parameter reaches the provider. The defaults deliberately do not fabricate reasoning
capability: a "safe lowest level" would have to be asserted *into* the level list, which is a claim
the harness has no evidence for and the provider may not understand.

**Where an override belongs.** User configuration, in the per-model fields that already exist
(`context_window`, `max_output_tokens`, `tools`, `thinking.levels`). Earlier sources win, so a
stated value is never replaced by a default.

---

## 3. Explicit model disabling

An entry may be **tombstoned**:

```lua
models = {
    ["gpt-4"] = { enabled = false },   -- semantic exclusion, not metadata
}
```

- `enabled` is not a normal metadata field. It is an exclusion marker, resolved during or before
  enrichment, and no later stage may fill it.
- A tombstoned model is removed **before** `/models` and models.dev are merged, so a later
  discovery cannot reintroduce it.
- A tombstoned model appears in the resolved catalog only as absent from the active set. Whether
  it is retained as a visible "disabled" entry is a presentation concern, not a catalog one.
- **Omitted is unspecified; `false` is explicit.** Absent `enabled` must never be treated as
  disabled.

Implementation note: the existing config key is `disabled` with a matching `disabled_present`
flag (`agent/catalog.odin`, `agent/config.odin:80`). It already has the required semantics and is
checked first, short-circuiting the rest of that model's fields. The written form
`enabled = false` in this document maps onto that mechanism; renaming the key is cosmetic and not
required.

---

## 4. Resolved Catalog

The single runtime-facing structure.

```
Resolved_Catalog
    providers: []Resolved_Provider
        id
        display_name
        auth:      endpoint, api_kind, api_key_env | api_key, models_url
        models:    []Resolved_Model
            id, display_name
            context_window, max_output_tokens
            input_modalities, output_modalities
            tools: bool
            reasoning: { supported, toggle, levels[] }
            origin: user | discovery | catalog
```

Rules:

- Every optional field is `(present: bool, value)`. Absent fields stay absent after enrichment;
  the catalog does not invent defaults.
- **No defaults are applied at merge time.** A missing `context_window` stays missing and the
  runtime decides what an unconfigured window means (today: refuse admission with an explicit
  message — `chat_admission_check`, `agent/chat.odin`).
- The catalog is **read-only** to everything downstream. The runtime copies the values it needs
  (into a frozen session view, or reads them per request); it never mutates the catalog.
- Adding a provider or model is a discovery/catalog problem, never a code change. If a new model
  needs a code change to work, the enrichment is incomplete.

### 4.1 What the catalog must be able to answer

| question | catalog field |
|---|---|
| context window | `model.context_window` |
| max output | `model.max_output_tokens` |
| supported modalities | `model.input_modalities`, `output_modalities` |
| reasoning support and levels | `model.reasoning.*` |
| tool calling | `model.tools` |
| provider endpoint | `provider.auth.endpoint` |
| API family | `provider.auth.api_kind` |
| credential environment variable | `provider.auth.api_key_env` |
| available models | `provider.models` |

If a runtime question is not answerable from this table, the catalog is missing a field — not the
runtime a special case.

---

## 5. Capabilities and reasoning

**Reasoning is capability metadata, never a model-name heuristic.** No regexes, no
provider-specific model lists, no `if model starts with ...` anywhere.

The representation must express, without loss:

- simple on/off → `supported: bool`
- discrete levels → `levels: [](string)` (verbatim)
- budget-based → a budget field, added when a provider needs it
- unknown → `supported` absent

Rules:

- **Levels are opaque strings.** The runtime validates a requested level against `levels` by exact
  match and forwards it verbatim. It never translates `"high"` into a number or into another
  provider's vocabulary. (Already the behaviour: `Provider_Request.Reasoning_Effort` is documented
  as "a verbatim level validated against the model's configured levels, never translated".)
- **Unknown capability is not unsupported.** Absent `supported` means "not established"; an
  explicit `false` means "cannot". These drive different behaviour and must not collapse.
- The runtime constructs the provider request from declared capabilities. Providers do not
  discover or require capabilities themselves; they receive a resolved request.

---

## 6. Durable conversation vs provider projection

Two distinct things. Do not conflate them.

**Durable conversation state** — what actually happened. Provider-neutral. Monotonic append plus a
budget window. Carries:
user turns, assistant text, tool calls, tool results, and opaque provider replay items in wire
order.

**Provider projection** — a temporary, per-request derivation. Rebuilt from the conversation, the
resolved model, the catalog, the tool set, and runtime config. Never stored.

Rules:

- The projection is rebuilt for every request, including tool continuations
  (`chat_build_request_into`, `agent/chat.odin`).
- After compaction, rebuild from committed history, never from a pre-compaction view
  (`chat_rebuild_prep`; the stale-view case is a tested failure mode).
- The projection is *repairable*: it must not emit a tool call without its result, must not emit a
  result without its call, and must keep call/result runs contiguous. Recovery enforces the first
  two at open: a call that was dispatched and never came back is closed as an unknown outcome, and
  a call that was never dispatched is closed as not executed.
- **Tool results enter durable state before the next model request.** Never send a projection that
  contains a tool result the conversation does not have.
- The durable model must not gain provider-shaped fields beyond an opaque replay slot (§8).

### Where the durable conversation lives

The store is a SQLite database in the XDG state directory, owned by `agent/session`. Four tables:
a `sessions` header (identity, directory, title, provider, model), `turns`, `requests` (one row per
model request, carrying the settings it was sent with and the usage it reported), and `entries` (an
append-only transcript ordered by a per-session sequence). Content is typed JSON in one column;
identity, order, ownership, and correlation are columns the database enforces.

A `Store` owns one connection and one caller drives it from one thread: the worker. History is read
back only through `context_load`, which is the newest checkpoint's summary followed by the entries
the summary does not cover, minus bookkeeping a model is never shown. Memory holds the work in
flight and nothing else.

One session is claimed for writing at a time through an advisory file lock, so two processes cannot
run the same session. A claim is also what a mutation requires, which is why opening a session and
recording anything in it are separate steps.

A launch opens exactly what it asks for: no flag starts a new session in the current directory,
`--resume` opens the newest session that recorded work in that directory, and `--resume SESSION`
opens that session by id wherever it ran. A session that was created and then abandoned holds no
work, so a resume passes over it. Resolving the target is separate from claiming it, so a refused
resume costs nothing and never falls back to a different session. Opening an interrupted session
settles it before anything new is admitted.

---

## 7. Agent lifecycle

Minimal state machine. Cancellation, compaction, steering, and subagents fit inside it; none of
them gets a competing loop.

```
Idle
  ↓ accept user
Preparing ──(steering boundary: drain queue)──┐
  ↓                                           │
Requesting → Streaming                        │
  ↓                                           │
tool calls? ── no ──→ Finalizing → Idle       │
  │                                           │
 yes                                          │
  ↓                                           │
Executing_Tools ──────→ Preparing ────────────┘
  ↑
Cancelling → (operation retires) → Finalizing
```

Rules:

- One turn = one user prompt and everything it causes until terminal. `requests_made` bounds the
  tool loop.
- **The loop is a step function, not a callback graph.** `advance(state) -> Effect`; the caller
  executes the effect (start a request, run tools, finish). This keeps the turn decision pure and
  testable without transport.
- Terminal status is exactly `Completed | Failed | Cancelled`. A turn reaches a terminal state
  once, and reports it once.
- Every in-flight request is an **operation** with its own id and deadline. Events carry their
  source `(turn_id, operation_id)` and are rejected unless they match the running operation, so a
  superseded or cancelled operation can never mutate a newer turn.
- The turn deadline and the operation deadline are separate facts. The operation deadline is
  clamped to what remains of the turn deadline so the turn bound preempts a running request
  (`agent/operation.odin`).
- Use Goose's step/effect separation where it simplifies this. **Do not reproduce Goose's
  operation catalogue for architectural similarity** — add a step only when a requirement needs
  one.

---

## 8. Provider replay state

Reasoning content is **not** merely display text. Some providers require faithful replay of
provider-generated structures, particularly adjacent to tool use.

Rules:

- The conversation carries provider-specific replay items as **opaque blobs in wire order**,
  attached at the position they occurred. The generic model does not interpret them.
- Replay items are tagged with the provider/model that produced them. A projection targeting a
  different provider/model **drops** them rather than guessing a translation.
- The generic conversation stays provider-neutral. Only the replay slot is provider-specific.
- Do not force every provider's reasoning representation into one lossy universal form; do not
  make the conversation itself provider-specific.
- Current shape: `Chat_Message.reasoning_id` + `reasoning_encrypted`, projected to
  `Provider_Message.Role = .Reasoning`. This is Responses-shaped (id + encrypted content).
  Generalising it for Anthropic signed thinking blocks is an open question (§14).

---

## 9. Steering

Follow the Goose model. Steering is **queued**, never mid-request.

```
model request → streaming → request completes
                                   ↓
                         apply queued steering
                                   ↓
                         build next request
```

Rules:

- Steering arrives at any time; it is appended to a bounded FIFO
  (`STEER_MAX_ITEMS`, `STEER_MAX_BYTES`) and read by the loop. The front-end owns reading input and
  pushes lines into the queue; the agent does not read stdin, and there is no second input path.
- **Injection happens only at a request boundary** — after tool calls settle, before the request
  view is frozen. Never mutates an in-flight request or an in-flight projection.
- A steering line that arrives after the turn's last boundary is reported and dropped when the turn
  settles; it is never applied to a later turn, where it would no longer mean what the user typed.
- Commands that must take effect before the next request (`/effort`, `/compact`) run at the
  boundary, ahead of the request build. The interactive front-end sends only text through the
  queue and keeps commands on its own path, which decides what may happen mid-turn.
- Steering is bounded. **No arbitrary mid-request mutation. No scheduler.** One execution thread is
  the only session writer.

---

## 10. Compaction and context budget

Inputs: durable conversation, resolved `context_window`, resolved `max_output_tokens`, and a local
estimate.

Budget arithmetic:

```
usable_input = context_window − (max_output_tokens or DEFAULT_OUTPUT_RESERVE) − safety_margin
admit(request) = estimate(input) + reserved_output + margin ≤ context_window
```

Rules:

- **The catalog supplies the limits.** No hardcoded windows or reserves beyond an explicitly named
  fallback used only when a limit is unconfigured.
- **Local pre-send estimate is mandatory.** Provider-reported usage arrives after the request and
  cannot prevent an oversized one. The estimate is approximate and says so; measured usage is
  evidence, never the estimate. (Current: chars/4 + per-message overhead + margin.)
- **Compact at complete turn/execution boundaries. Never truncate an individual payload**, tool
  result, or message body to fit. Cutting a serialized payload produces malformed history.
- **Preserve the newest exchange.** The most recent turn must survive compaction intact.
- **Keep call/result runs together.** A seam may back up over a tool call and its result so the
  retained tail is coherent.
- **Compaction commits only when the summary request succeeds.** A failed summary leaves history
  and the active window untouched.
- **Never delete history.** Compaction advances a window over an append-only record.
- **Compact only when a request would not be admitted.** Compaction is not eager: it rewrites
  the active context, which discards the provider's cached prefix and pays for a summarization
  request. A request that still does not fit after one compaction fails explicitly rather than
  looping, and a seam that covers nothing cannot make progress, so repeated attempts terminate.
- Provider-specific compaction belongs behind a **provider/decorator boundary** if it is needed at
  all. The core loop must not accumulate per-provider compaction rules.

---

## 11. Tools

- Tool calls are **structured state**, not embedded in text: `{id, item_id, name, arguments,
  result, status}`.
- **Arguments are buffered and validated before dispatch.** Partial argument fragments never reach
  the executor; only a validated, complete call does. Non-object JSON is not a valid call.
- A call is bounded (count and argument bytes) and rejected with a typed error when it exceeds the
  bound, rather than truncated.
- Every dispatched call produces exactly one result, including synthetic results for calls that
  did not run because the turn was cancelled. History stays well-formed in every path.
- Results enter durable conversation state before the next request (§6).
- **Large output ordering is fixed:**
  ```
  redact → cap → spill to a result store → hand back a re-readable handle
  ```
  Never place arbitrarily large tool output into model context. Redaction happens **before** the
  cap, so a cap cannot split a secret in half.
- Tool definitions come from the harness's tool registry; `model.tools` from the catalog decides
  whether they are advertised at all.
- Tool availability is a capability of the *model*, resolved from the catalog — not a per-provider
  branch in the loop.

---

## 12. Subagents

A subagent is a **tool** the orchestrating agent invokes. It is not a configured persona.

- **No Markdown-defined agents.** No `reviewer.md` / `coder.md` / `planner.md`. No fixed taxonomy
  of roles.
- The orchestrator decides the specialisation and expresses it in the instruction. Roles are a
  prompt-authoring concern, not a harness concept.
- An invocation specifies at least: `provider`, `model`, `reasoning`, `instruction`.
- **Process isolation is required.** A subagent runs in a separate OS process. Threads are not
  sufficient isolation: if a subagent crashes, hangs, or is killed, the harness must survive.
  ```
  harness process
      └── subagent subprocess
  ```
- The lifecycle must expose `completed | failed | cancelled`, and internally distinguish normal
  failure, abnormal termination, cancellation, and timeout.
- **Design for `spawn → handle → await`** even though the first tool-facing interface is
  synchronous. Concurrency later must not require redesigning the lifecycle.
- Do not over-specify the public result shape before the lifecycle requirements are understood.
- Subagent results re-enter the parent as an ordinary tool result, subject to §11.

---

## 13. Cancellation and lifecycle boundaries

- Cancellation is a **request**, never a force. The turn settles only once the in-flight operation
  has retired and confirmed it stopped. Nothing is released on the strength of the request alone
  (`Chat_Operation_State`, `agent/operation.odin`).
- Cancellation wins over whatever error the transport also reported.
- A cancelled turn still resolves its committed tool calls with synthetic "not executed" results,
  so history stays valid.
- Deadlines and cancellation are separate mechanisms: deadline = elapsed-time bound, cancellation =
  external intent. Both are carried into the transport.
- Signals are recorded by the handler and interpreted by the loop; a handler never mutates turn
  state.
- A turn begins uncancelled, so a signal that arrived after the previous turn finished is never
  inherited.

---

## 14. Core versus edge

**Core (`agent`, `ai`) owns:** conversation, model interaction, tools, context/budget, streaming,
cancellation, steering, compaction, subagents.

**Edge owns:** ACP, CLI/TUI, presentation, rendering, command menus, which session a launch opens,
telemetry export.

Rules:

- The core emits **semantic** events through a caller-supplied observer and writes to a
  caller-supplied writer. It never renders.
- The provider abstraction stays narrow: translate a provider-neutral request into the provider's
  API, and translate the provider's stream/result back. Discovery and metadata come from the
  catalog, not from provider code.
- Streaming vocabulary stays small: `content delta`, `reasoning delta`, `tool started`,
  `tool input delta`, plus a typed terminal result. Provider wire events do not leak into the core.
- Finish reasons normalise into a small closed set. Usage distinguishes **exact / deferred /
  unavailable** rather than assuming every provider always reports it.
- **ACP must not appear in the core**, and the core must not depend on a front-end's existence.
- Do not reproduce FX's dependency interface. It is a catalogue of the host's concerns (diff
  blocks, permission targets, credential refresh, HTTP statuses) leaked into the runtime.

---

## 15. Current state and gaps

Verified against the code at the time of writing.

### Already matching

| Area | Evidence |
|---|---|
| Presence-flag convention | `Provider_Request` (`ai/contract.odin`), `Catalog_*_Source` (`agent/catalog.odin`) |
| Step-function loop | `chat_session_advance` → `Chat_Effect_Kind{Start_Request, Run_Tools, Turn_Finished}` |
| Steering at a boundary | `chat_drain_steering` runs when state is `.Preparing` |
| Operation lifecycle | `Chat_Operation_State{None, Running, Retired}`, event-source gating |
| Local pre-send estimate | `chat_estimate_input_tokens` + `chat_admission_check` |
| Opaque reasoning replay | `is_reasoning` / `reasoning_id` / `reasoning_encrypted`, projected as `.Reasoning` |
| Tool argument buffering + validation | `Provider_Tool_Fragment`, `provider_tool_finalize` |
| Cancellation is a request | `chat_session_request_cancel` never finalizes |
| No hardcoded provider/model knowledge | grep over `ai/` and `agent/` returns nothing |
| Provider-neutral conversation | `Chat_Message` has no provider-shaped fields beyond the replay slot |

### Needs work

1. **Provider metadata is only partly discoverable.** models.dev supplies the endpoint, the API
   family, and the credential's environment variable for the providers it knows, but a provider
   without an endpoint field — including `anthropic` and `openai`, which rely on their SDK's
   built-in default — still needs `base_url` stated in configuration.
2. **Catalog fields parsed but never consumed:** `input_modalities`, `output_modalities`,
   `display_name`.
3. **Subagents absent.** No spawn, no process isolation, no lifecycle.
4. **No redact/cap/spill path for tool output.**
5. **System prompt is a message, not a lane**, and is hardcoded (`AGENT_SYSTEM_PROMPT`,
   `CHAT_COMPACT_INSTRUCTIONS`).
6. **Anthropic unimplemented.** `API_Kind.Anthropic_Messages` exists; `Provider_Validate_Request`
   rejects it and there is no encoder.
7. **Prompt-cache fields unused** by the chat path.

### Settled since this document was written

- **Compaction keeps the tail.** The active window is `[summary] + kept tail`, and the seam stays
  out of a call/result run.
- **One resolved catalog.** `resolve_catalog(user, provider, models_dev)` merges the sources,
  first defined value wins, into the `Catalog` the runtime reads.
- **Provider `/models` discovery.** Each configured provider's own listing is read live at
  startup (`agent/discovery.odin`) and merged as the middle source, so the catalog holds every
  model the provider reports while the user's configuration keeps every field it states.
- **models.dev ingestion.** The API representation is fetched and cached under the XDG state
  directory, parsed into provider source records, and supplied to the resolver as its third
  source. A document that cannot become source records never replaces a usable cache.
- **One provider credential field.** `api_key` is resolved when a connection is built: a value that
  names an existing environment variable is that variable's value (the `${NAME}` reference form
  included); anything else is the secret itself. A name that exists but is empty fails rather than
  sending the name as a key.

### Must remain unchanged

- `http/client`, `sse`, and their conformance work. The provider layer sits above them.
- The observer seam's size and shape (`agent/observer.odin`). It is deliberately narrow; do not
  widen it toward FX's dependency interface.
- `agent` stays presentation-free.
- Everything currently green stays green.

---

## 16. Open product decisions

Only decisions that cannot be settled from the code, the provider specifications, or the
requirements. Everything else is an implementation detail to resolve during the work.

1. **System prompt lane.** Keep the system prompt inside `messages` (today), or split
   `Provider_Request` into `instructions` + `messages` as FX and Goose both do. Splitting is
   cleaner and enforces the invariant that conversation never contains a system message, but it
   changes the provider contract and both encoders.

2. **Anthropic reasoning replay representation.** The current replay slot is Responses-shaped
   (id + encrypted content). Anthropic needs signed thinking blocks, which are a different opaque
   payload, and the adjacency requirements around tool use differ. Decision: generalise the slot
   to a tagged opaque blob, or add a second provider-specific variant.

3. **Subagent result shape.** Deliberately unresolved. Decide after the process lifecycle —
   exit status, timeout, kill, partial output — is implemented and its real distinctions are
   known. Do not design the public type first.
