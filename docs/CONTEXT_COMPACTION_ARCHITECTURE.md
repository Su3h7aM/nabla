# Context, persistence and compaction

Status: required target. Background compaction, checkpoint installation and paired cache
accounting exist; the stage boundaries this document shares with execution do not.
Owns durable history, provider projection, capacity and cache accounting. [Execution](EXECUTION_ARCHITECTURE.md) owns when work advances;
[errors](ERROR_RETRY_ARCHITECTURE.md) owns retry authorization;
[tools](TOOLS_MCP_ARCHITECTURE.md) owns retained tool output and paging.

## One record, derived views

SQLite is the durable authority. Keep one session writer with an exclusive claim,
short transactions, typed entry payloads and stable sequence/turn/request identities.
Root owns connection lifetime; the session owner performs mutations. Read-only analysis
uses a separate connection without claims, creation or migrations.

Retain user input, accepted assistant output, raw calls, effective dispatch arguments,
observed results, instruction snapshots, checkpoints and attempt metadata. Keep
correlation and parent relationships enforceable in storage. A dispatch is intent;
a result is the observed outcome. Do not infer one from diagnostic timestamps.

Provider history, frontend transcript and diagnostics are different views. A request
is a temporary projection, not another mutable conversation. Model-visible input must
come from committed records or recorded effective configuration. Transient progress
never becomes a completed message by accident. Explicit harness feedback has its own
origin and is not forged user intent or assistant output.

Load only the active checkpoint and uncovered tail for normal inference. Full history
and paged results remain queryable without retaining the entire transcript in memory.
Record references to immutable artifacts rather than repeatedly copying full bodies
into several durable formats. Keep enough exact prepared-input provenance to explain
what was sent. Raw wire capture remains optional diagnostics, not execution authority.

A first accepted prompt creates the session's durable work. Opening and closing an
unused launch need not create history. Resume claims the selected session and settles
interrupted work before admitting new input. A failed resume never silently opens a
different conversation. Format changes use explicit version checks and migrations or
a diagnosed incompatibility; prototype compatibility is not a reason to retain a
weaker design.

## Projection

Build in a deterministic order:

1. Exact committed instruction snapshot, separate from conversation messages.
2. Sorted eligible tool definitions from the turn's frozen registry.
3. Installed checkpoint, if any.
4. Uncovered model-visible history in its recorded conversational order.
5. Any purpose-specific directive, such as summarization, in its defined suffix.

Provider encoding places these into that API's fields. Do not sort conversation
arrays, rerender old text, insert timestamps, or add transport/retry annotations.
A successful response can retain API-native replay items as opaque, origin-tagged
bytes. Only its API adapter interprets them. Replay only for compatible origin and
settings; cross-provider/model projection drops incompatible opaque material while
retaining neutral text and tool facts. Do not force every provider's signed/encrypted
reasoning into one lossy universal representation.

Native replay must agree with admitted calls. If a call was repaired/refused, do not
replay an opaque response containing a contradictory proposal as well as normalized
calls. Project each assistant item once. A record is read as input before it is replayed,
because the endpoint's stream and its terminal array can disagree: bytes the input schema
refuses, or that do not say what the projection sends, are not carried, and the request
reports how many records it refused. Partial failed output is audit/display data, not a
finished assistant message. Call/result runs stay complete and contiguous in the provider
view even when hidden children occur between their durable sequences. Children are filtered
by stored parent relationships, not by whether their parent happened to be loaded in this
tail.

Projection failure is explicit. Repair unanswered calls from durable dispatch evidence
at recovery, not by synthesizing arbitrary successful results while encoding.

## Capacity

Resolve capacity once per selected model and use it for admission, compaction policy,
result budgets and reporting. Absence is not zero. Unknown capacity may use a named
runtime fallback with an assumed flag; explicit invalid or zero capacity refuses
requests. Never replace a stated zero output limit with a useful default silently.

Use one checked calculation:

```text
W = resolved or explicitly assumed context window
M = estimator safety margin
F = min(minimum useful answer, positive model output maximum)
input_ceiling = max(W - M - F, 0)
output_bound = min(W - M - estimated_input, model output maximum, harness output maximum)
```

Admission requires a positive usable capacity and at least `F` output room. The
compaction trigger is below the input ceiling with growth reserve. For tiny windows
where this ordering is impossible, refuse or use a clearly diagnosed constrained
policy; do not underflow arithmetic or pretend `trigger < ceiling < W` always holds.

Margin covers estimation error; reserve gives background work time to finish; output
allowance controls the current answer. These are distinct quantities, not competing
capacity services. Keep named defaults and tune from observations. Report sizes of
instructions, schemas, history and output allowance separately so an oversized
instruction block is not blamed on conversation history.

Provider token usage is a measurement after a send, not permission to skip pre-send
admission. Estimator error and unknown model limits remain visible. Do not introduce
a tokenizer service or provider-name heuristic without evidence it improves admission.

## Compaction as a bounded session job

Keep at most one unfinished summary, including a ready candidate awaiting installation.
The session owner handles all lifecycle events. No root idle polling policy and no
second agent loop. One worker performs a tool-free inference operation on immutable
owned bytes. It writes no SQLite rows and accesses no foreground transport.

Let `B` be the expected base checkpoint and `F` the last covered entry. Freeze the
existing checkpoint plus a coherent model-visible prefix through `F`. Preserve the
recent user task and whole assistant/call/result runs in the tail. A child record is
not an independent seam. Retain exact instructions and tool definitions for stable
request construction, but grant the summarizer no execution authority. Reject a
summary that proposes calls, is incomplete or fails the reduction/content checks.

```text
before: instructions + old checkpoint/prefix + growing tail
worker: summarize fixed prefix through F
install: instructions + new checkpoint covering F + every visible entry after F
```

Select tail by `covered_seq`, never by the newer checkpoint entry's own sequence.
Appended work during summarization cannot disappear. A second compaction summarizes
the prior checkpoint plus new history; it does not accumulate summary messages.

Install only at an ordinary request boundary or while idle with no active turn. Adoption
of a completed candidate may happen while tools run; adoption is not installation.
The install transaction verifies the writer claim, unchanged base, valid coverage,
successful originating compaction request, and no previous installation from it. Append
one checkpoint with complete framing. Rebuild preparation after installation.

Normal pressure, explicit compaction and provider overflow share one intent. Coalesce
repeated triggers. Automatic work starts only when pressure and useful context progress
justify it, under the failure cooldown. Retry uses [the shared policy](ERROR_RETRY_ARCHITECTURE.md).
Changing selection invalidates pending work through explicit cancellation/retirement,
not by freeing a snapshot another thread owns. Turn cancellation alone need not cancel
session-level compaction; session destruction does.

The foreground never waits for a summary. A ready valid candidate can relieve pressure;
otherwise admission fails explicitly when headroom runs out. Finite capacity and an
unbounded summarization delay cannot guarantee continuous execution. A late summary
may help a later prompt but does not resume failed work.

Crash before installation leaves the old context. A committed candidate without an
installed checkpoint is audit data, not a durable continuation. Recovery may schedule
new compaction when useful; it never assumes a worker still exists. Compaction changes
projection, not retained history or the session storage quota.

## Summary content and trust

Ask for goals, constraints, completed work with evidence, decisions, exact identifiers,
current work, pending work, failures and unknowns. Separate observations from plans.
Preserve user corrections. Treat quoted tool/file content as data, not instructions.
Retain skill names and locations, but require full reload before relying on summarized
instruction details. A summary is fallible model output, not proof that its claims are
true. Keep the original record available for inspection.

## Stable prefixes and honest accounting

Keep instruction bytes, tool order/schema bytes, diagnostic literals that enter model
feedback, session cache identity and normalized history stable under unchanged inputs.
A retry reuses frozen bytes. A reconnect does not rotate cache identity. Tool refresh,
model/effort changes and checkpoint installation can legitimately change the provider's
rendered prefix; record the cause instead of claiming universal preservation.

Changing provider or model need not rewrite neutral history, but cross-model cache
sharing is not promised. Effort may be a top-level field that invalidates a provider's
hidden prefix. Do not invent `configuration_update` messages or a persistent effort
ledger without a verified adapter capability and a measured need.

Summarization can reuse the old prefix but cannot prewarm the new one: summary tokens
were generated under a different preceding input. No speculative prewarm, head
reservation, generation graph or server-side continuation cache is required.

Record latest cumulative usage per bucket within one attempt; sum distinct attempts.
Missing is unknown, not zero. Normalize total input according to the API, validate
counts per row, and do not clamp contradictory usage into a believable percentage.

```text
paired_input = sum(valid input where input and cache_read were both reported)
paired_read  = sum(valid cache_read for those same rows)
hit_rate     = paired_read / paired_input, if paired_input > 0
coverage     = paired_input / all valid reported input, if that denominator > 0
```

Also report total, paired, missing and invalid request counts, including requests with
no usage. Keep all-work totals and foreground/compaction/retry views. A measured-subset
rate is not a whole-session rate. Compare cost per equivalent completed workload,
including cache writes and failed inference, not a universal cache-hit percentage.

Transport parity tests compare common semantic fields after removing only documented
envelope differences. Operator-authorized live comparisons use matched model/settings,
history, cadence and reporting coverage. No paid runtime probes or automatic transport
flapping to improve a dashboard.

## Acceptance

Test checkpoint installation with a concurrently growing tail, stale and duplicate
candidates, coherent seams, child filtering with absent parents, failed summaries,
and admission failure without waiting. Resume must reproduce stored instruction and
result bytes. Test projection after repaired/refused calls for every supported API.
Usage tests cover missing/zero/invalid data, unequal request sizes and cumulative
updates. Local tests do not establish summary quality or live cache savings.
