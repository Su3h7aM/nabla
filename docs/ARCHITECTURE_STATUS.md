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
- Context logger integration, typed JSONL diagnostics, capture, retention and the
  read-only `diagnostics` reader/export.
- Native HTTP/1.1, TLS 1.3, SSE, DNS and Responses WebSocket with provider delivery
  evidence on the WebSocket path.

## Gaps against the target

Each is required work, not a design choice. Do not treat current behavior as correct.

| Gap | Target |
| --- | --- |
| `chat_perform_request` is one blocking procedure covering preparation, compaction, admission, transport setup, retry and commit | Extract prepared artifacts, validators and recovery decisions; make request stages owner-observable per [execution](EXECUTION_ARCHITECTURE.md) |
| `chat_session_advance` increments turn accounting while selecting an effect | Selector becomes side-effect free; the driver advances counters on the accepted transition |
| Streaming state changes arrive through callbacks, so tests cannot drive the request path through the machine | Route request/stream facts through the shared owner mailbox |
| Tool selection (`tool_jobs_next`) collects completions and emits stop logs | Split observation/application from selection; keep selection pure |
| A worker that ignores its stop is answered Unknown and marked `Stuck`, while the batch releases borrowed session/backend/skill data | Retain producer-owned data and borrowed generations until actual retirement; mark the runtime unusable and let root shut down when a worker does not stop |
| Batch admission validates each call at dispatch rather than the whole root batch before effects | Add the pre-effect batch gate; keep all-or-nothing staging |
| No aggregate retained-byte budget or session retention quota; child results are exempt from the model budget but not from a storage bound | Add measured byte limits for root, child and session retention with an explicit settlement reserve |
| Retry waits, tool waits and idle compaction use separate fixed 50 ms slices | One owner wake mechanism with nearest real deadline; no ordinary polling |
| WebSocket transport defaults to HTTP and `auto` fallback is partial | Complete the correctness/cache gates, then adopt the target default |
| Provider prompt-cache parity and complete provider-error classification are not fully verified | Close the [network](NETWORK_STACK_ARCHITECTURE.md) corrections and measure |
| Skills 2 MiB result exception described by the former design does not exist; code already uses the shared 64 KiB bound | Documented as shared; no code change needed |

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
