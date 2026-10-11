# Background tool calls

A `shell` call or an `agent` start may run in the background: the call is answered at once with a job id, the work keeps running under the session, and its final result reaches the model later. When the session is idle at that moment, the result starts a new turn. This document records the finished design; `docs/ARCHITECTURE.md` sections 6.5, 7, 9, 14, 17.1, and 21 own the rules.

## 1. Model interface

- Only `shell` and `agent` start take `wait`. `Shell_Args.wait` defaults to true; `agent` start keeps its own `wait`, default false. `read`, `write`, `edit`, `skills`, `skill`, owner tools, `codemode`, and MCP tools are synchronous and take no `wait`. There is no generic `Tool_Definition.wait` or shared wait schema.
- Admission sets `job.background` in `agent/tool_job.odin` through one `#partial switch` over `Shell_Args` and `Agent_Start_Args`. A background shell has no default timeout unless the model gives `timeout_ms`, and it clears `exec.stream`; progress lives in the kept stdout and stderr files.
- Receipt, committed with `tool.admitted` in one barrier: `ok`, `job: job-<call id>`, `status: running`, and for shell `stdout_file` and `stderr_file`, then text telling the model not to poll and to end its response when nothing else is left. The id is stable across restarts.
- Completion: a `User` node with origin `Job`, headed `job-<n> (<tool>) finished`, `failed`, `stopped` (`Cancelled`), or `lost` (`Unknown`), followed by the result rendered as a blocking call would render it.
- `jobs` tool (`agent/tool_jobs.odin`, owner placed): `list` and `stop`. `stop` answers `stopping`; the completion still arrives. There is no wait action: waiting is ending the response, and the completion starts the next turn.

## 2. Runtime

- A background job leaves its batch at dispatch (`background_detach` in `agent/background.odin`). The session owns it in `chat.background` (`Background_Jobs`); the batch keeps a committed receipt, so `tool_jobs_settled` and the turn never wait for it.
- Its stop token chains to `chat.background_stop`, not the turn's stop. Ending or cancelling a turn leaves it running; `jobs stop`, session close, and the process interrupt stop it. It holds no batch worker slot or lane.
- `background_reap` commits `background.completed` for a published worker. A worker that ignores its stop for `TOOL_JOBS_STOP_PATIENCE` is abandoned and answered `Unknown`. `background_destroy` stops, waits the patience, and abandons the rest; recovery settles what stayed open.
- Every receipt is answered. When a result cannot be rendered or staged, or a worker is overdue on its stop, `background_record` commits a fixed-text `Unknown` `background.completed` that needs no allocation.
- Journal: `background.completed` record kind, `Tool_Admitted.background`, `User_Origin.Job`, and the inbox query that delivers the completion once at a settled boundary. Recovery gives a `tool.admitted{background: true}` without a completion a `background.completed{Unknown, "it may have taken effect"}`; a live recovery skips that rule because the owner still holds its jobs.
- Idle turns: `chat_background_pending`, `chat_background_wait`, and `chat_background_report_failure` cover the team and the background table. The TUI and ACP V2 start a report turn, ACP V1 delivers with the next prompt, and headless and native subagent sessions wait for outstanding jobs before they end.
- Code Mode: a child started with `wait: false` goes through the same dispatch. `Tool_Job.background` means the work outlives the call, `job.wait` returns the receipt, and `codemode_job_stop_children` (`agent/codemode_job.odin`) skips a background child when the script ends.

## 3. Phases

1. Completion record and inbox delivery: done.
2. Detaching to the session-owned table, `chat.background_stop`, receipt output, and the `wait` field of `shell`: done.
3. Idle turns for every frontend: done.
4. Subagents on the shared `Job` worker record: done.
5. `jobs` tool: done.
6. Code Mode child calls in the background: done.
7. Always-answered receipts (`background_record`): done.
8. MCP background calls: deferred. The reasons are in `docs/TODO.md` under "MCP background calls". An MCP tool's schema is forwarded unchanged and its call always blocks.

The `session_install` address-reuse gap, which concerns abandoned workers that outlive a session switch, is open and listed in `docs/TODO.md`.

## 4. Dropped

- `wait` on `read`, `write`, and `edit`, and the generic `Tool_Definition.wait` with `TOOL_WAIT_SCHEMA`. Only the two tools that run long take `wait`.
- A `jobs` wait action. Ending the response replaces it.

## 5. Separate from this design

Every native tool shares one lane, so blocking calls in one response run one after another. Background calls avoid that. Running foreground calls in parallel by what they touch is the access-class target of `docs/ARCHITECTURE.md` section 7.3, a separate change.
