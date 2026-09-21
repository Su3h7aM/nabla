# Configuration and future customization

Status: configuration principles are required. Lua hooks, durable inbox, feedback and
automatic improvement are future capabilities. This document reserves their boundaries;
it does not require hook registration APIs, event types or storage tables now.

## Where a behavior belongs

| Requirement | Home | Reason |
| --- | --- | --- |
| Identity, admission, ownership, commit order, recovery, cancellation and resource enforcement | Native Odin in `agent` | These guarantees must hold regardless of scripts or configuration |
| Protocol parsing, provider encoding and evidence | Owning protocol library or `ai` | Facts belong where they can be verified |
| Endpoint/model selection, limits, instruction sources, tool exposure | Validated configuration data | Choices do not need executable hooks |
| Combining reads/edits/searches and selecting a compact result | Lua Code Mode | Composition uses existing admitted capabilities |
| User-specific request guidance, additional restrictions, content filtering | Future named Lua hooks | Customize data at explicit boundaries without changing lifecycle |
| Service integration, foreign-language runtime, specialized external capability | MCP or an external process | Avoid native core growth and extra embedded runtimes |
| Rendering, menus, terminal interaction, export invocation | Root/frontend | Presentation cannot own harness policy |
| Ratings, analyses, evaluations | Read-only history/export consumers | They need facts, not a second execution system |

The immutable core means runtime safety invariants, not a promise that current Odin
APIs cannot be redesigned. Neither a config value nor a hook may permit execution
before intent, widen authority, raise a hard resource bound, bypass retry safety,
clear cancellation, rewrite committed history, or relabel an uncertain effect as
successful.

## Configuration and model metadata

Evaluate one user-owned Lua configuration into plain validated Odin data. Use one
source of truth for settings; avoid profile stacks, YAML patches, configuration
service objects or evaluating the file twice for different consumers. Repository
instruction files are data, not executable configuration. A failed reload preserves
the previous usable configuration and reports the rejected candidate.

Resolve provider/model metadata field by field in this order:

```text
explicit user configuration -> provider discovery -> shared catalog
```

First present value wins. Later sources only fill absent fields. Lists are replaced
as whole present values, not silently appended. Keep explicit presence for false,
zero and empty values. Reject invalid stated values rather than treating them as
missing. Exclusions are separate tombstones and cannot be undone by discovery.
Identity is the exact `(provider_id, model_id)` pair, never a parsed display string.

Runtime reads the resolved catalog, not parallel provider tables. Model capabilities
are metadata, not model-name heuristics. An unknown capability is not known false.
Unknown reasoning sends no invented setting; allowed opaque effort strings are
validated against configured capabilities. Named fallback capacity is runtime policy
and is visibly assumed, not fabricated catalog evidence.

API-family behavior belongs in `ai`, not catalog data. Adding a model on an existing
API normally needs no code; a new wire protocol does. Do not make the catalog a
property bag capable of scripting provider encoders. Credentials resolve at connection
creation from explicit references or configured secrets and remain out of durable
catalog records and ordinary logs.

Freeze effective settings for the current request chain. Selection changes use the
ordinary request boundary. Registry replacement waits until turn borrowers retire;
new instruction sources require an explicit new snapshot/session policy. Config
reload never mutates data an operation still borrows.

## Future Lua hooks

Start with one handler per supported hook in user configuration. Add a hook only for
an actual customization task. No arbitrary event subscription, wildcard matching,
waterfall dispatch modes, plugin discovery, dynamic module loading or compatibility
bridges to other harnesses.

A hook receives a bounded versioned value copy, returns a typed decision, and runs
on the owner in a separate restricted Lua execution. It receives no session pointer,
store, credentials, unrestricted OS libraries, tool dispatcher or mutable runtime
objects. Code Mode and hooks may share conversion/budget code, but not a live VM,
authority set or hidden global state.

Initial useful boundaries, when required:

| Point | Permitted result | Native checks afterward |
| --- | --- | --- |
| Before request freeze | Accept or replace a bounded guidance addition, or stop | Persist the effective addition with harness origin; rerun projection/capacity admission; keep it stable across retries, and treat a per-request change as an intentional prefix change rather than hidden churn |
| Before batch admission commits | Allow, deny, or replace eligible argument data | Validate entire batch again; preserve raw proposal and effective input separately |
| After observed tool output, before commit | Keep or replace bounded model-facing content | Preserve observed outcome/identity; validate envelope, retention and context budgets |

A pre-tool replacement cannot invent a provider call identity or silently switch to
a different capability. A content filter cannot hide that a side effect happened.
Keep observed outcome facts separate from transformed model-facing content, with
bounded provenance; raw sensitive bytes need not be retained to prove a transform ran.
Post-tool denial cannot roll back an effect. If the hook fails there, commit the known
outcome with safe bounded failure content and stop rather than pretending the tool
never ran.

Policy hooks fail closed: syntax/runtime/limit errors stop or refuse before effects.
Optional diagnostic observers may fail best-effort, but cannot inject data or make
policy decisions. Keep these contracts distinct. No hook catches cancellation and
continues forever. Validate conversion and all native invariants after every return.

Do not expose retry authorization as an arbitrary request-error script. Native policy
computes the maximum safe action. A later concrete need may allow a hook to stop or
narrow that action, never to authorize another send or a shorter provider delay.
Hooks run once at their named boundary, not again for identical frozen retries.

Record bounded invocation identity, configuration/version identity, decision, duration,
failure and effective transformation provenance alongside the operation. Any material
that changes model input must be durable before it is used. Restart uses committed
results, never reruns a hook against past effects. Observational hook logs alone are
not sufficient provenance for model-visible additions.

Hook I/O, asynchronous approval and tool-calling hooks are deliberately excluded from
this first shape. If later required, they become explicit owner-driven operations
with lifetimes and cancellation, not blocking calls hidden inside a hook. Broad
customization does not require allowing a script to replace the state machine.

## Future input persistence and evaluation

A durable input queue can preserve accepted but unapplied input across restart. Its
consumption and late-input rules belong to [execution](EXECUTION_ARCHITECTURE.md).
Do not create a generalized inbox or autonomous wake engine for a feature that only
needs a pending setting or one prompt.

History queries and bounded export are the first evaluation interface. Reuse SQLite
read-only access and existing diagnostic export before adding any analysis subsystem.
Record actual stage outcomes, attempt identities, tool refusals, unknown effects,
usage presence and instruction provenance where they occur. A future rating or note
is log-only data tied to a durable message/turn identity, not model context. If editable,
use an explicit version check rather than silent last-writer replacement.

Do not add feedback schemas before a feedback feature, event taxonomies solely for
imagined fine-tuning, or background prompt rewriting. Automatic self-modification,
scoring services, dashboards and telemetry backends are outside the core. Evaluate
changes offline and apply approved instructions/configuration through normal boundaries.
