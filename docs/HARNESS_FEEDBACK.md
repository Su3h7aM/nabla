# Harness feedback

## 2026-10-06 Oversized batched source inspection

- Goal: inspect compaction architecture and its owner-loop call sites together.
- Attempt: read the architecture document and several large source files in one Code Mode batch with a 2,000-line limit for each.
- Gap: the combined result was truncated, leaving relevant code out of the visible result.
- Workaround: search for the specific procedures and read their bounded line ranges. The initial batch was too broad.

This file collects cases where Nabla's tools did not support what an agent or a person was trying to do. Each report becomes input for new features and fixes, and reports are consolidated and removed once their improvement lands.

Add a report whenever you fall back to something the harness should have handled, above all a script run through the shell (Python, Perl, awk, sed) where Code Mode should have served. Code Mode runs Lua and calls the harness tools directly; it is meant to remove the need for any other scripting language.

Each report has a dated heading with a short name, then four parts:

- Goal: what you were trying to do.
- Attempt: the tool you tried, or why you did not try it.
- Gap: why it did not work or was not enough.
- Workaround: how you did it instead, with the command or script shape.

## 2026-10-08 Action-specific agent arguments

- Goal: send subagent messages and list configured models through the native tools, without wrapping a single tool call in Code Mode.
- Attempt: call `agent` with `action="message"` and the generated schema's required common fields, including null-valued configuration fields. Call `agents` with `action="models"` and the required `agent` field.
- Gap: the message handler accepts only `action`, `agent`, and `message`. It rejects `wait`, `prompt`, `effort`, `acp_agent`, and `instruction`, even when null. The model-listing handler accepts only `action` and rejects `agent`. The generated schema requires fields that these actions do not accept.
- Workaround: call `tools.agent({action="message", agent=id, message=text})` and `tools.agents({action="models"})` from Code Mode with only action-specific arguments. Group these calls with independent work where possible. The native schemas need to match each action's accepted arguments.

## 2026-10-09 Subagent follow-up progress

I asked agent-9 to review the completed navigation change. The message tool accepted the follow-ups, but status continued to show running, a last record of turn.completed older than 40 minutes, and two unread messages. No new request record appeared during the checks. I stopped the child and reviewed the final diff directly instead of waiting longer.

Status should distinguish a queued follow-up, an active request, and a completed turn, and say why accepted messages are waiting. This would make it possible to decide whether to wait or replace the work without relying on an old assistant answer.

## 2026-10-11 Subagent model id format

- Goal: start a subagent on `muse-spark-1.3-contributor` served by provider `opencode-go`.
- Attempt: call `agent` start with `model="opencode-go/muse-spark-1.3-contributor"`, the form the `agents` models listing prints, with and without `provider="opencode-go"`.
- Gap: without a provider the call failed with "no configured provider serves model". With the provider it failed with "model not found for provider". The start description says to pass "exact catalog model id with its vendor prefix", and the models listing prints the provider prefix in front of each id, so both suggest the prefixed form.
- Workaround: pass `model="muse-spark-1.3-contributor"` with `provider="opencode-go"`. The listing should print the id exactly as `start` accepts it, or `start` should accept the printed form.

## 2026-10-11 Subagent idle after compaction

agent-45 finished a turn, its context was compacted, and `agents status` then showed it as running with `last record: compaction.completed` for more than 18 minutes while two follow-up messages stayed unread. No request record appeared. I stopped it and started a new child with the same task. This matches the 2026-10-09 report: a follow-up accepted after a finished turn and a compaction is not delivered, and status cannot tell a waiting message from an active request.


# Harness feedback

This report records failures observed during the Linux syscall migration in this Odin fork. Evidence comes from tool responses and agent messages in the session. It does not establish the internal cause of a provider or scheduler failure. Problems caused by the assistant are identified separately.

## Review agents stayed running without making progress

Review agents `agent-812`, `agent-813`, and `agent-814` stopped making progress after provider failures. The status tool continued to report `running` for all three.

Later status responses showed `last record: response.rejected`, no assistant output, and record ages of approximately 24,300 seconds. That is more than six hours without reported progress. The status response did not explain that a retry timer was preventing further requests.

When the sessions were stopped, their final messages exposed the delay:

```text
the provider is rate limiting this session; retrying in 183898s (attempt 2)
the provider is rate limiting this session; retrying in 183902s (attempt 2)
the provider is rate limiting this session; retrying in 183931s (attempt 3)
```

These delays are about 51 hours. An agent waiting that long should not appear indistinguishable from an agent doing useful work.

Requested improvements:

- Report a distinct state for provider backoff, including the next retry time, attempt count, and last error.
- Bound automatic retry delays for interactive sessions. If a provider requests a delay measured in hours, report the blockage and let the orchestrator decide what to do.
- Notify the orchestrator when progress stops instead of leaving it to discover the stall through status inspection.

## Model switches waited behind stalled provider requests

The orchestrator requested a switch back to `openai/gpt-6.1-sol` for the three reviewers. The configure calls succeeded but returned notices saying the switch would take effect at the child's next request.

The stalled sessions did not reach that request boundary. Subsequent status responses still showed `anthropic/claude-sonnet-5-5`. Repeating the configure request did not make the switch immediate.

The orchestrator eventually stopped the stalled sessions and configured them again. Only then did the tool return `model: cliproxyapi/openai/gpt-6.1-sol` and `status: running` for each session.

Requested improvements:

- Interrupt provider backoff when the orchestrator changes the model or provider. A queued switch should not wait behind a 51-hour retry timer.
- Show the active selection and pending selection separately in status responses.
- Provide an explicit restart operation that preserves agent context while cancelling an in-flight request or retry delay.
- Distinguish acceptance of a configuration request from application of that configuration.

The assistant also made a reporting mistake here. It initially told the user the reviewers had switched after the configuration requests were accepted, before checking the active selection. That claim was later corrected. Tool success alone was not enough evidence that the new model was active.

## Notifications arrived after the corresponding recovery steps

After the stop-and-reconfigure sequence, messages arrived saying that earlier model-switch requests had been replaced by a newer selection. Stop notifications describing the old provider retry delays also arrived after the configure tools had reported the sessions running on Sol.

Those notifications may accurately describe earlier events, but their delivery order makes them easy to mistake for the current state.

Requested improvements:

- Include an event timestamp, request identifier, and configuration generation in lifecycle notifications.
- Identify the model and provider associated with a failure or stop event.
- Mark notifications about superseded requests as historical.

## Repeated provider failures and unsuccessful recovery

Earlier, `agent-750` repeatedly failed with:

```text
the WebSocket response ended before a terminal event
```

The tool reported retries with delays of 1, 2, 4, 8, and 16 seconds, then failed the session. Resuming the same session failed again. Requesting compaction also failed, with a message that the summary had not completed.

A replacement session, `agent-784`, failed on the same model and provider before it made progress. It later completed work after a model change. This establishes repeated request failures, not their underlying cause or a provider-wide outage.

Requested improvements:

- Report whether failures are transport failures, rate limits, context-limit failures, or provider errors.
- Make clear whether a failed request produced partial tool calls or file changes before retrying it.
- Allow recovery from a failed compaction without requiring another successful request to the same failing model.
- Preserve resumable context and report the last completed step after a session fails.

## Advertised agent schema disagreed with runtime validation

The exposed `functions.agent` schema included fields such as `agent`, `message`, and `compact` alongside the start fields. Direct start calls containing these irrelevant fields with null or false values were rejected by runtime validation.

Examples of the errors:

```text
unknown field "agent(start)/message"
unknown field "agent(start)/agent"
expected action, instruction, prompt, model, provider, effort, wait, or acp_agent
```

Calling the same operation through Code Mode with only start-specific fields succeeded and created `agent-834`.

Requested improvement: expose action-specific argument schemas, or consistently allow irrelevant optional fields when they are null. Tool definitions and runtime validation should agree. The assistant wasted several calls repeating the incompatible form before using Code Mode.

## Subagent background jobs did not survive the agent turn

Earlier in the migration, a subagent reported that validation was running in the background, but the command no longer ran after the agent ended its turn. The session adopted a workaround: subagents run long commands as foreground calls with a large timeout, while the orchestrator delegates those calls asynchronously.

The exact process-lifetime mechanism was not established. The observed behaviour was that the advertised background workflow did not reliably survive the subagent turn.

Requested improvement: document the lifetime of background jobs in child sessions. Either keep them alive until completion or cancellation, or reject background calls whose lifetime cannot be supported. Do not let an agent report work as running after the process has disappeared.

## Working-directory confusion allowed edits in the wrong workspace

An implementation agent was assigned the separate Jujutsu workspace `/home/su3h7am/Projects/Odin-ws2`, but its relative edits landed in `/home/su3h7am/Projects/Odin`. Another agent noticed the unexpected changes in its own working copy.

The orchestrator stopped the misplaced writer, saved its diff, restored the two affected files in the main workspace, and resumed the task with absolute paths in the assigned workspace. No permanent loss was observed.

This was an agent path-selection error. The editing tools resolved relative paths against the session workspace as documented, not against a previous shell command's working directory. Stronger workspace isolation would have prevented the error from affecting another writer.

Requested improvement: allow a child to have an explicit workspace root that applies to reads, searches, edits, writes, and shell calls. Consider enforcing an allowed write scope for each agent. Until then, agents assigned a sibling workspace must use absolute paths for file operations.

## Validation reports omitted the evidence needed to investigate failures

Some validation agents reported all target checks passing after running `odin check` without `-no-entry-point`. In this session, that command stopped at the entry-point diagnostic instead of performing the intended package check. Re-running with the correct flags exposed a real arm64 constant mismatch.

Agents also discarded test output while counting successes. One report contained two failed runs whose failing test names could no longer be recovered. A later stress run retained every log and identified a shared-memory test race.

These were assistant and validation-script mistakes, not demonstrated tool execution bugs. The harness correctly returned the failures that were retained.

Requested improvements:

- Retain failed command output automatically, including the command, working directory, environment overrides, exit code, and output-file path.
- Give agents a structured way to associate each claimed validation result with its actual tool call.
- Do not treat a successful shell pipeline as proof that its build or test command succeeded. Validation must preserve the relevant command's exit status.

## Reporting and control lessons

The assistant repeatedly sent waiting messages even though the user had requested no interim reports. It also described reviews as running without checking whether their provider requests were progressing. These are assistant failures, not scheduler failures.

Future work should report confirmed state, distinguish pending requests from applied changes, preserve failure logs, and avoid treating a `running` label as evidence of progress. Review completion must mean a returned review with evidence, not merely an agent-start or configuration receipt.

## Further occurrence: implementation agent scheduled a 44-hour retry

The same excessive-backoff problem later affected the implementation agent, `agent-784`. Its status reported `running`, model `anthropic/claude-sonnet-5-5`, and `last record: response.rejected` with an age of 2,334 seconds. The last assistant text was an earlier completed task report, not progress on the newly assigned fixes. A pending switch to Sol had not taken effect.

After the orchestrator stopped the stalled request, the stop notification revealed:

```text
the provider is rate limiting this session; retrying in 159129s (attempt 2)
```

That delay is 44 hours, 12 minutes and 9 seconds. The regular status response did not expose the retry deadline. The list's `running` label therefore hid a blocked implementation task as well as the earlier blocked reviews.

The orchestrator stopped the session and reopened it with `openai/gpt-6.1-sol`. The configure tool confirmed that active selection. The agent subsequently reported a clean preflight and resumed implementation. The old stop notification arrived after the reopening receipt, again requiring the orchestrator to distinguish a historical event from the current state.

This further occurrence supports the earlier requests to expose provider-backoff state and retry deadlines, bound interactive retry delays, and apply model changes without waiting for a long backoff timer. It does not establish whether the provider supplied the 159,129-second delay or the harness calculated it; the tool output did not identify that source.

## 2026-10-16 Conjunctive multi-word search

- Goal: find the lines that contain two separate terms, for example a line that writes `free_all` and also mentions `temp_allocator`.
- Attempt: `grep` with both words in one plain pattern, in each word order, and regex alternatives such as `term_a.*term_b`. Lookahead as an AND, `(?=.*term_a)(?=.*term_b)`, was tried too.
- Gap: `grep` matches line by line, so a regex can only require both terms on one line in the order written, and lookahead is refused as an invalid expression. Plain mode has no conjunction either. A two-word pattern that finds no exact phrase triggers the documented recovery: it retries without the leading word, so `free_all temp_allocator` returns the 1552 lines holding `temp_allocator`, and `temp_allocator free_all` returns the 61 lines holding `free_all`. The notice says the fallback ran, but the answer to the question asked, the lines with both, is not in the result. On a large tree this is 1552 rows where the true answer may be a handful.
- Workaround: intersect file lists by hand. Grep each term with `output_mode="files_with_matches"`, intersect in Code Mode, then grep inside the intersection and confirm the second term in each row. Three or more calls per query, and the row set cannot be paged with a cursor.

Requested improvement: a conjunction over plain terms, or a `patterns` list in which every element must match the line, each element keeping the case, regex, and glob behavior it already has. Nothing else is needed: an AND of independent terms covers the question, and lookahead stays out.
