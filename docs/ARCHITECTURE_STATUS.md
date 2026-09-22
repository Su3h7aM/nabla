# Implementation status

Status: verified against the tree at the time of writing, not an architectural
contract. Read it to avoid mistaking a prototype behavior for a requirement or
reimplementing something that exists. Update it when the gap it names closes.

## Implemented and aligned with the target

- One owner thread, one session writer, SQLite history with turns, requests, entries,
  checkpoints, dispatches, results and parent call relationships; recovery closes
  interrupted work without replay.
- Resolved catalog with first-present-wins field merge, presence flags, tombstones,
  provider discovery and models.dev ingestion; per-model API routing.
- Instruction snapshot, skill discovery/loading with a bounded frontmatter parser, and
  `list_skills` / `load_skill` as ordinary tools under the shared result bound.
- Model request preparation with frozen encoded bytes, per-attempt request rows,
  classification, bounded retries, one checkpoint repair, no harness deadline.
- Background compaction on a frozen prefix installed at a request boundary, with a
  claim-checked install transaction and paired cache-usage accounting plus coverage.
- Batch tool budget with retained results, derived handles and `context_read_result`.
- Sequential Lua Code Mode with fresh restricted states, child calls through the shared
  job table, hidden children, bounded limits and a shared result envelope.
- Tool admission with argument repair, durable dispatch, all-or-nothing call staging,
  worker/owner/Lua placement, lanes, worker bounds and answer completeness on cancel.
- One owner thread with one wake primitive for every wait and every producer: provider facts
  queue in the bounded mailbox, a tool completion and a finished compaction publish through the
  same wake, and the owner collects them by observing instead of polling.
- Context logger integration, typed JSONL diagnostics, capture, retention and the
  read-only `diagnostics` reader/export.
- Native HTTP/1.1, TLS 1.3, SSE, DNS and Responses WebSocket with provider delivery
  evidence on the WebSocket path.

## Gaps against the target

Each is required work, not a design choice. Do not treat current behavior as correct.

| Gap | Target |
| --- | --- |
| The owner mailbox queues provider facts; a tool worker publishes into the shared wake and its own job table rather than into the mailbox, which the tool lifecycle section allows where synchronization requires a handoff record, and a compaction worker publishes its completion through the same wake | One bounded owner mailbox and wake primitive for input/control, provider facts, tool completions and compaction completion |
| No aggregate retained-byte budget or session retention quota; child results are exempt from the model budget but not from a storage bound | Add measured byte limits for root, child and session retention with an explicit settlement reserve |
| WebSocket transport defaults to HTTP and `auto` fallback is partial, and the persistent WebSocket is session-owned and borrowed by each attempt's worker rather than owned by one worker across operations | Complete the correctness/cache gates, then adopt the target default and connection ownership |
| Provider prompt-cache parity and complete provider-error classification are not fully verified | Close the [network](NETWORK_STACK_ARCHITECTURE.md) corrections and measure |

Closed since this document was written:

- One owner wake serves every wait: the request mailbox, the tool table, the retry backoff, and
a requested stop all signal or wait on one condition variable, and each wait is bounded by its
own real deadline (the retry delay, a stopped call's patience) or by nothing at all. The three
50 ms checks and the retry policy's slice are gone.
- Provider facts reach the owner through one bounded mailbox instead of through the send
that produced them: one attempt is one worker thread, it owns the blocking send, and it
publishes owned `Chat_Event`s and a terminal outcome. The owner applies them and awaits the
outcome as the `Await_Provider` effect, and it joins the worker before the frozen bytes are
reused or released, so the request path is driven from collected facts.
- Retry and backoff are request state: `Chat_Request_Chain` carries the prepared request,
the frozen bytes, and the recovery decision across attempts, and the driver performs
`Send_Attempt`, `Wait_Retry`, `Repair_Context`, and `Commit_Response` one at a time, so a
retry wait is a stage the turn can stop rather than a nested loop.
- `chat_session_advance` is a read: the driver claims the request before it counts, and
claims the turn finish before it records the terminal outcome; a claim, never selection,
applies the transition.
- Tool observation is separate from selection: `tool_jobs_observe` applies external facts,
and `tool_jobs_next` reads the table.
- A tool worker that ignores its stop latches the session; no further turn is admitted and
teardown leaves what the worker can reach to process exit.
- The test-only tool driver lives in the test support file, so production has one tool
driver.
- `Chat_Effect` owns nothing; the session owns the terminal error.
- Duplicate operation id, the no-op `Streaming` state, and `Chat_Operation.turn_id` are gone.
- Batch validation is split by meaning: defective call identity refuses the response,
per-call admission refuses that call. See [tools](TOOLS_MCP_ARCHITECTURE.md).
- Steering is a request-boundary stage: the driver applies queued input between the
proposal of a request and the claim that counts it, and the claim refuses a turn its
boundary stopped. See [execution](EXECUTION_ARCHITECTURE.md).
- Steering input keeps its turn running: a line recorded for a turn that had finished
answering returns that turn to preparing, so the next request is the one that answers it and
the user submits nothing to deliver it. A turn that failed or was cancelled keeps its
outcome, and the line is in the record for the next request from that history. See
[execution](EXECUTION_ARCHITECTURE.md).
- Skills use the shared 64 KiB result bound; no separate exception exists.

## Future capabilities with no implementation

Do not build these without a task that requires them:

- Lua configuration hooks and any hook registration, payload or provenance schema.
- Durable input inbox or restart-surviving steering.
- Public Lua task handles (`tasks.start/await/cancel`) and Code Mode discovery helpers.
- Subagent tool, process protocol and supervision.
- ACP as the frontend path into the harness.
- Feedback, rating, evaluation or auto-improvement storage and services.

## Known non-goals

Follow mode for diagnostics; OTLP/metrics backends; HTTP/2, HTTP/3, TLS resumption,
redirects, cookies, proxy CONNECT, compression; incremental provider continuation;
detached background tool jobs; PTY, LSP, browser or computer-use services; a generic
plugin framework, service registry, event bus, workflow engine or scheduler package.
