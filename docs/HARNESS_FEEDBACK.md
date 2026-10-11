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
