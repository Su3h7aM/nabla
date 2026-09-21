# Failures and recovery

Status: required target. The bounded classification, retry, per-attempt record and
one-repair path exist; the request-stage split that makes them owner-observable does not.
This document alone owns automatic retry policy. Transport
adapters report evidence under [network](NETWORK_STACK_ARCHITECTURE.md); the
[execution machine](EXECUTION_ARCHITECTURE.md) applies decisions. No retry loop in
`ai`, SSE, HTTP, WebSocket, a Lua hook, or a tool executor may multiply harness sends.

## Failure boundaries

Return typed errors as trailing values. Preserve the facts the policy owner needs:
stage, local cause, provider classification, status, delivery evidence and its presence,
recognized rejection evidence, Retry-After, and bounded diagnostic detail. Unknown
is a valid fact, not a reason to infer success or parse display prose.

| Failure | Owner action |
| --- | --- |
| Configuration, instructions, local encoding or admission | Refuse before sending; identify the part to change |
| Transient provider/transport failure with safe replay evidence | Bounded same-input retry |
| Confirmed context overflow with safe rejection evidence | One changed-context repair from an already-ready checkpoint |
| Invalid complete model output or root batch | Execute nothing; bounded recorded feedback under the turn-step budget |
| Tool failure | Record the observed outcome; the model chooses subsequent work |
| Storage failure | Latch session failure, stop launches/continuations, drain producers |
| Allocation/serialization failure | Explicit local failure; no empty success or guessed result |
| Diagnostics failure | Report sink health once; do not change execution policy |
| Worker that does not retire | Runtime unusable; bounded process shutdown, not normal continuation |

Cancellation wins user-facing stop classification when it caused the stop, but never
erases a storage failure or rewrites a completed tool effect. Keep contributing
failure evidence even when there is only one terminal status.

## Model retry decision

An attempt is one provider operation with at most one model send. Setup-only failures
consume the same chain bound. Defaults remain three foreground attempts and two
compaction attempts. A turn has a separate logical-request bound so repeated invalid
responses cannot create an unbounded model-correction loop.

Evaluate in this order:

1. Stop for cancellation, storage failure or local harness failure.
2. Accept only a successful operation with a validated completion.
3. Stop if output was exposed or completion was already accepted.
4. Stop if execution is possible and no documented pre-execution rejection proves
   replay safe. Missing delivery evidence is unknown, not not-sent.
5. For confirmed input overflow, consider the single checkpoint repair below.
6. Stop for authentication, quota, trust/configuration errors, invalid request,
   content policy, malformed output, unknown classification, or explicit retry denial.
7. Retry an eligible transient failure only if an attempt remains and its requested
   delay fits policy.

Safe replay evidence is either proof the model-send path was never entered or an
API-specific pre-execution refusal. HTTP status, a received response head, a valid
terminal event, socket acceptance, and lack of text are not independently such proof.
In particular, a truncated HTTP 200 stream after request delivery is not safer to
repeat than a lost WebSocket reply. This rule accepts some terminal uncertainty to
avoid duplicate inference or remote effects.

The API adapter classifies recognized codes and narrow documented message shapes.
Do not classify by provider hostname or an arbitrary mention of tokens/limits. Quota
inside 429 is not throttling; ordinary 413 is not proven context overflow. Permanent
TLS verification failures never become retryable I/O failures. Never weaken trust.

Every visible content kind passes one exhaustive exposure decision before publication.
Include visible reasoning if enabled. Usage and keepalive are not exposure. Partial
text may be retained/displayed as partial, but is not replayed as a complete assistant
answer and releases no tool calls. Do not inject a synthetic continuation prompt.

## Frozen input and attempt records

Prepare and encode once. An identical retry keeps endpoint, credential, model, effort,
instructions, inventory, cache key and body bytes. Do not rerun instruction discovery,
request hooks, steering drain, or tool execution during retry. A transport-envelope
change requires explicit safe fallback authorization and preserves the frozen semantic
request. A context repair is a new payload within the same bounded chain.

Each attempted operation gets a durable request row and fresh runtime operation ID
before network work, including setup. Record attempt number, predecessor, recovery
kind, prepared-input provenance, encoded-body digest, and observed usage. Finish the
failed row and record the decision before waiting or sending again. Failed persistence
cancels recovery. No transaction spans a network operation or wait.

A begun row proves intent, not delivery or billing. A crash closes it as interrupted
without replay. Reset provisional output, usage, completion and error ownership per
attempt. Do not use one counter for logical turn steps and actual attempts. Counters
advance on accepted transitions, never on a pure query for the next effect.

## Backoff

Use checked duration arithmetic and standard randomness. For retry number `n`:

```text
ceiling = min(8 seconds, 500 milliseconds * 2^(n - 1))
backoff = uniform(ceiling / 2, ceiling)
delay   = max(backoff, provider_retry_after)
```

A provider delay above the default 30-second permitted wait stops the chain with the
requested delay reported; it is never shortened into an early send. Parse the entire
Retry-After field, preserving valid overflow as present-but-unrepresentable. Convert
HTTP dates to durations once, then wait using a monotonic deadline.

Use the shared owner wait with cancellation wakeup, not a retry-specific 50 ms sleep
loop. Check stop and storage health again immediately before the next start. There
is no automatic model deliberation timeout, turn deadline, or hidden recovery wall
clock. Tool execution bounds and process shutdown patience are different policies.

## Context repair

For local admission refusal or a safely rejected provider overflow, install only a
finished, validated compaction candidate at a safe boundary. Require matching base
and coverage, a meaningful reduction, a rebuilt projection, and successful admission.
Record the changed checkpoint and link the new attempt to the failed one. The same
chain can repair once; changing payload does not reset its attempt count.

No candidate, a running summary, stale coverage, insufficient reduction or a second
overflow ends with a typed Context_Exhausted reason. Do not wait for compaction,
delete history, strip opaque reasoning, silently shrink model metadata, or send the
same overflowing body again. Session pressure may schedule useful compaction for a
later user prompt. That completion never automatically restarts the failed turn.

Compaction retries use the same evidence rule and attempt accounting. Not exposing
a partial summary is necessary but not sufficient for safe replay of a delivered
request. Retain its frozen snapshot across a permitted backoff. After failure, use
cooldown plus new context progress; suppress automatic auth/quota/configuration
failures until configuration or explicit user intent changes. No idle retry storm.

## Tool and restart recovery

Tool calls are never in the model retry loop. A dispatch without a result stays
Unknown after restart even if diagnostics claim the tool succeeded. An undispatched
call is Not_Executed. Recover hidden children as well as roots. Do not replay tools,
Lua stacks or scheduled retries, and do not guess that a read-only hint makes it safe.
An actual tool precondition or explicit user decision can justify a new call later.

A storage failure prevents normal use of that session until it is reopened and
recovered successfully. Resource cleanup must remain possible without the database.
On disk-full or OOM, a minimal reserved settlement may help, but do not promise
that a result committed when the store refused it.

## Acceptance

Table-test classification and policy with supplied clock/jitter. Integration fixtures
count actual received requests and executed tools for failure before write, partial
write, received head then truncation, visible output, malformed completion, cancellation
during backoff, checkpoint repair and failed persistence. Test with diagnostics off.
Recovery fixtures reopen the store after each durable boundary and prove no automatic
reexecution. Live delay economics and provider rejection contracts require separate
evidence; a local fixture establishes neither.
