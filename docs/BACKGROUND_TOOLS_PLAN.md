# Background tool calls: implementation plan

Any tool call may run in the background: the call is answered at once with a job id, the work keeps running under the session, and its final result reaches the model later. When the session is idle at that moment, the result starts a new turn. This is the mechanism a background `agent` start already uses, extended to every worker tool. Web search, long builds, test suites, and dev servers are the first users.

## 1. What exists and what we reuse

A background `agent` start already does everything except run a tool:

- The call commits `tool.admitted` and `subagent.started{background}` in one barrier, then answers at once with `agent-<call id>`.
- The child runs on its own thread, owned by the session's `Agent_Team`, not by the turn. Its completion sets a `done` flag and signals the owner wake.
- The owner reaps it in `agent_team_reap` and commits `subagent.completed` with the answer in the body.
- `journal.read_inbox` returns that record. `chat_inbox_stage` turns it into a `User` node with origin `Agent`, delivered at a settled boundary (`chat_session_input_point`), exactly once through the `last_delivered_message` cursor.
- An idle session starts a turn for it: the TUI through `app_agent_report_turn`, ACP V2 through `acp_report_turn`, headless through `chat_agents_wait` after the prompt turn. ACP V1 delivers it with the next prompt.
- Recovery settles a `subagent.started` without completion as `Unknown`, which the inbox then delivers.

The inbox, the settled-boundary delivery, the per-frontend idle turns, and the recovery shape are already generic. What is specific to subagents is the record kinds, the team, and the reap. Background tool calls add their own record kind and their own session-owned table, and plug into the same inbox.

OpenCode `v2` confirms the model-facing shape: `shell` and `subagent` take `background?: boolean`, a background call returns `Command moved to the background (shell ID: …). Output is streaming to: <file>`, completion arrives as an injected message that wakes an idle session, and the description tells the model not to poll and to end its response when it has nothing else to do. It has no companion output, wait, or kill tools. Codex instead returns a session id after a yield time and polls through `write_stdin`.

## 2. Model interface

### 2.1 The `wait` field

Every worker-placed tool accepts one harness field, `wait` (boolean). `wait: false` runs the call in the background. The name and meaning are the ones `agent` start already has, so the harness has one word for one idea.

A completion enters the session's inbox, the queue steering lines already use, and is delivered at the next settled boundary as a `User` node: when the agent's current step ends and the next request is prepared, the result goes in with it. A background call therefore costs no request of its own while the agent keeps working; only an agent that ends its response with nothing left to do is woken by a new turn.

The default is `true` for every tool except `agent` start, which keeps `false`, and it is a field of the tool definition (`Tool_Definition.wait`), so changing it for a tool is one line of data. Blocking stays the default because the next request is prepared as soon as the batch commits: a background `read` answers with its receipt, the request goes out at once, and the file's content usually arrives one request later, after the model has already had to decide without it. The model chooses `wait: false` for work it expects to be long: a build, a test suite, a server, a slow search. The description of `wait` says exactly that.

Native tools declare `wait` in their schema constants and argument structs. An MCP tool's schema gets the field added once at registration, and the field is removed from the arguments before they are forwarded, so the server never sees it. Owner-placed tools (`agents`, `compact`, `agent` message, configure, and stop) and `codemode` do not take it: they are session control or already orchestrate concurrency.

### 2.2 The receipt

A background call's result is committed at dispatch, in the same barrier as `tool.admitted`:

```text
ok
job: job-42
status: running
stdout_file: /home/…/tool-output/<session>/42.stdout.txt
stderr_file: /home/…/tool-output/<session>/42.stderr.txt

The result arrives as a message when the job ends. Keep working on what does not depend on it; if nothing is left, end your response and you will be resumed. Do not poll.
```

The id is `job-<call id>`, stable across restarts like `agent-<call id>`. The stream files are named only for tools that write them (shell); `read` on them shows progress without waiting.

### 2.3 The completion

The completion is delivered like a subagent report, as a `User` node with origin `Job`:

```text
job-42 (shell) finished
ok
exit_code: 0
…
```

The heading is `finished`, `failed`, `stopped`, or `lost` (outcome `Unknown`), followed by the rendered result exactly as a blocking call would have returned it, through the same preview and kept-file rules.

### 2.4 The `jobs` tool

One owner-placed tool, `jobs`, with two actions:

- `list`: each background job of the session with its id, tool, status, age, and stream files.
- `stop`: requests the job's stop. The call answers `stopping`; the job's completion still arrives and reports what was observed: `Cancelled` when the stop is confirmed, `Unknown` when it cannot be, or the tool's own result if it finished first.

There is no `wait` action. Waiting is ending the response: the turn finishes, and the completion starts the next one. A call that must have its result before continuing is made with `wait: true` in the first place. This matches OpenCode and needs no new blocking state.

## 3. Runtime

### 3.1 Ownership

A background job is a `Tool_Job` that leaves its batch at dispatch. The session owns a `Background_Jobs` table beside `Agent_Team`, heap-allocated for the same reason: a stuck worker may outlive the session. The batch commits the receipt and treats the call as answered, so `tool_jobs_settled`, `chat_commit_results`, and `chat_session_tools_done` never wait for it, and the `Results` node names the call with its receipt.

- Stop: the job's `interrupt` chains to a session-level stop instead of the turn's `chat.stop`. Ending or cancelling a turn leaves it running. `jobs stop`, session close, and the process interrupt stop it.
- Wake: the job keeps its `Tool_Wake` open until it is retired, so a stop reaches a worker asleep in `poll`.
- Timeout: a background call runs with the timeout the model gave and with no timeout otherwise, since a dev server or a long test run should not be killed by a default meant for blocking calls.
- Slots and lanes: a background job holds no batch worker slot and no native lane, so it never delays foreground work. Each one is a thread asleep in its I/O. An MCP background call still holds its client's lane, because one stdio stream cannot serve two calls.

### 3.2 Completion

The worker publishes as today. The owner reaps published background jobs wherever it reaps the team (`chat_session_observe_at` and the idle paths), applies `tool_result_keep` to the result, and commits one `background.completed` record (barrier) with the outcome, the tool name, the call id, and the result text in the body. Then it retires the worker. A worker that ignores its stop for the stop patience is abandoned through the existing `job_abandon` path, and its completion is committed as `Unknown`.

### 3.3 Journal

- New record kind `background.completed`, appended to `Record_Kind`.
- `tool.admitted` carries `background: true` for a detached call.
- `INBOX_QUERY` adds the session's `background.completed` records; `inbox_text` renders the heading above. `User.origin` gains `Job`.
- Recovery: a `tool.admitted` with `background: true` and no `background.completed` gets `background.completed{Unknown, "it may have taken effect"}` naming the kept stream files, the same rule that already settles an open call. The inbox then delivers it. A crash before the receipt commits leaves the call to the existing `tool.admitted` rule, and no job id was ever shown.

### 3.4 Idle turns and headless

`chat_agents_pending` and `chat_agents_wait` become `chat_background_pending` and `chat_background_wait`, covering the team and the background table. Their callers in the TUI, ACP, and headless paths keep their shape. Headless waits for outstanding background jobs before it exits, as it already does for children.

### 3.5 Code Mode

A Lua child started with `wait: false` is detached like a root call: `job.wait` on it returns the receipt, and `codemode_job_stop_children` does not stop it at script end. That replaces the special case that skips a background `agent` start today.

## 4. Phases

Each phase is one jj change, with `mise run fmt`, `mise run check`, and the touched tests before it closes.

1. **Journal and inbox.** `background.completed`, the `background` field on `tool.admitted`, `User` origin `Job`, `INBOX_QUERY`, `inbox_text`, and the recovery rule, with a journal test that a recorded completion is delivered once and an open background call recovers as `Unknown`. Files: `agent/journal/*`, `agent/steer.odin`.
2. **Detach and reap.** `Background_Jobs`, detach at dispatch with the receipt, the session-level stop, reap and commit, teardown, and the `wait` field on native tools. One tool-loop test: a background shell call is answered with a receipt, the turn ends, the completion is committed and delivered. Files: `agent/tool_job.odin`, `agent/chat_tools.odin`, `agent/chat_session.odin`, a new `agent/background.odin`, the native tool files for `wait`.
3. **Idle turns.** `chat_background_pending` and `chat_background_wait` and their frontend callers (`app_worker.odin`, `acp_worker.odin`, `main.odin`).
4. **`jobs` tool.** `agent/tool_jobs.odin` and its registry entry.
5. **MCP and Code Mode.** The schema field for MCP tools and its removal before forwarding, and detached Lua children.
6. **Documentation.** `docs/ARCHITECTURE.md` sections 7, 8.4, 9, 14, 17.1, and 21.2, and the tool table.

Phase 1 can start now. Phase 2 needs phase 1. Phases 3 and 4 need phase 2 and touch disjoint files. Phase 5 needs phase 2.

## 5. Separate from this plan

Every native tool shares one lane, so even blocking calls in one response run one after another: four foreground shell calls run in sequence. Background calls avoid that. Letting foreground calls run in parallel by what they touch is section 7.3's access-class target, a separate change.
