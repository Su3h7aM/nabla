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

## 2026-10-06 Splitting a change by hunk

- Goal: split one working-copy change into several commits when one file held hunks for two commits.
- Attempt: `jj split` with paths, which moves whole files only. `jj-hunk-tool` is not installed.
- Gap: no tool selects hunks non-interactively.
- Workaround: a Python script wrote an intermediate version of the mixed file (the old text with only some hunks applied, and `jj file show -r @-` for the parent text), then `jj split <paths>`, then the full file was copied back.

## 2026-10-06 Operating-system experiments across processes

- Goal: measure whether an inotify event on a SQLite WAL commit can arrive before a reader sees the commit, and whether a SIGKILLed flock holder raises an inotify close event on its lock file.
- Attempt: Code Mode, rejected because its Lua calls only the harness tools.
- Gap: Code Mode has no inotify, SQLite, flock, or process control, and no timing control between two cooperating processes; the shell tool runs one command at a time and returns at exit.
- Workaround: Python scripts using `sqlite3`, `ctypes` inotify, `fcntl.flock`, and `subprocess` with SIGKILL, run once through the shell (kept in /tmp/walexp).

## 2026-10-07 Overlapping context in grep results

- Goal: see a few lines around close matches with `fff_grep` and `context`.
- Attempt: `fff_grep` on `catalog_model_provider` and `MAX_MESSAGE_DEPTH` with context lines.
- Gap: overlapping context blocks were repeated for nearby matches, and leading indentation was lost in `content` output.
- Workaround: `read` of the line range.

## 2026-10-07 Sub-agents have no Code Mode

- Goal: let a sub-agent repair a file where `edit` applied a repeated identical hunk twice.
- Attempt: `edit` again, which refuses or mis-applies hunks whose unchanged lines occur several times in the file.
- Gap: the sub-agent had no Code Mode tool, so it could not replace by counted occurrence in Lua.
- Workaround: a Python one-liner through the shell. The orchestrator now tells sub-agents to avoid repeated-hunk edits and to ask when a patch cannot be applied.

## 2026-10-08 Action-specific agent arguments

- Goal: send subagent messages and list configured models through the native tools, without wrapping a single tool call in Code Mode.
- Attempt: call `agent` with `action="message"` and the generated schema's required common fields, including null-valued configuration fields. Call `agents` with `action="models"` and the required `agent` field.
- Gap: the message handler accepts only `action`, `agent`, and `message`. It rejects `wait`, `prompt`, `effort`, `acp_agent`, and `instruction`, even when null. The model-listing handler accepts only `action` and rejects `agent`. The generated schema requires fields that these actions do not accept.
- Workaround: call `tools.agent({action="message", agent=id, message=text})` and `tools.agents({action="models"})` from Code Mode with only action-specific arguments. Group these calls with independent work where possible. The native schemas need to match each action's accepted arguments.

## 2026-10-09 Subagent follow-up progress

I asked agent-9 to review the completed navigation change. The message tool accepted the follow-ups, but status continued to show running, a last record of turn.completed older than 40 minutes, and two unread messages. No new request record appeared during the checks. I stopped the child and reviewed the final diff directly instead of waiting longer.

Status should distinguish a queued follow-up, an active request, and a completed turn, and say why accepted messages are waiting. This would make it possible to decide whether to wait or replace the work without relying on an old assistant answer.
