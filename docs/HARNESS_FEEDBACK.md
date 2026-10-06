# Harness feedback

## 2026-10-06 Diagnosing a stalled test suite

- Goal: identify the tests still running when the progress bar stopped at 298 of 300.
- Attempt: the normal test task displayed only the last completed test. Exporting a Bash compiler function to add test-state logging did not work because the task launches the compiler through an external timeout. Attaching a debugger was denied by the operating system's ptrace restriction.
- Gap: the test task accepts neither test-name filters nor compiler logging defines, so the progress line cannot identify an outstanding test.
- Workaround: create a temporary compiler launcher under `/tmp` that forwards to `$ODIN_ROOT/odin` with `ODIN_TEST_LOG_STATE_CHANGES=true` and debug logging, put it first on PATH for one normal `mise run test agent --debug-only`, then compare Running and Successful records in Code Mode. Repository scripts and toolchain configuration were unchanged. The outstanding tests exposed a reversed deadline comparison, which was corrected before validation continued.

## 2026-10-06 Provider spelling when starting a subagent

- Goal: delegate a bounded investigation to the requested model.
- Attempt: `agent_spawn` with provider `openai` and model `gpt-6.1-sol` returned `provider not found: openai`.
- Gap: the tool schema does not list configured provider names or explain how model aliases resolve.
- Workaround: omit provider and pass the full model name `openai/gpt-6.1-sol`; the harness resolved it to the configured provider and started the agent.

## 2026-10-06 Oversized batched source inspection

- Goal: inspect compaction architecture and its owner-loop call sites together.
- Attempt: read the architecture document and several large source files in one Code Mode batch with a 2,000-line limit for each.
- Gap: the combined result was truncated, leaving relevant code out of the visible result.
- Workaround: search for the specific procedures and read their bounded line ranges. The initial batch was too broad.

## 2026-10-06 Recovering a subagent after provider quota exhaustion

- Goal: finish an ACP multi-session change started by a subagent after its provider quota was exhausted, using an available model instead.
- Attempt: sent the subagent a request to stop at a safe point and report its progress. The user observed no requests through the proxy, despite the harness listing the subagent as running. A stalled agent cannot produce the requested handoff.
- Gap: the tools cannot resume a subagent with a different model or export its current conversation and progress for a replacement. Running status does not establish that requests are progressing. File edits survive in the shared workspace, but unreported reasoning, investigation, and decisions may be lost.
- Workaround: stop the old subagent, preserve its existing edits, and start a replacement on an available model with the approved design and instructions to inspect and finish those edits. Add recover/resume with a model change and an accessible progress checkpoint, with explicit status when provider exhaustion prevents progress.

The replacement also failed after exhausting its request retries because its WebSocket response ended before a terminal event. Its last reported checkpoint and shared-file edits could be handed to another replacement, but its unreported progress could not. Recovery should support transport/provider failures as well as quota exhaustion, and preserve the conversation without requiring a manual reconstruction from earlier reports.

This file collects cases where Nabla's tools did not support what an agent or a person was trying to do. Each report becomes input for new features and fixes, and reports are consolidated and removed once their improvement lands.

Add a report whenever you fall back to something the harness should have handled, above all a script run through the shell (Python, Perl, awk, sed) where Code Mode should have served. Code Mode runs Lua and calls the harness tools directly; it is meant to remove the need for any other scripting language.

Each report has a dated heading with a short name, then four parts:

- Goal: what you were trying to do.
- Attempt: the tool you tried, or why you did not try it.
- Gap: why it did not work or was not enough.
- Workaround: how you did it instead, with the command or script shape.

## 2026-10-06 Literal multi-replace in a document

- Goal: apply about ten exact-text replacements to docs/ARCHITECTURE.md in one step, failing the whole edit if any old text did not occur exactly once.
- Attempt: Code Mode was not tried.
- Gap: Lua's `string.gsub` and `string.find` take patterns, so every old text full of backticks, brackets, and dashes needs escaping or `find` with `plain = true` plus manual splicing. There is no helper for "replace this literal text, expect exactly N matches", and the patch tool needs the surrounding lines of each hunk rather than a long single line.
- Workaround: a Python script with a `rep(old, new, count)` helper that asserted the match count, written to /tmp and run through the shell.

## 2026-10-06 Splitting a change by hunk

- Goal: split one working-copy change into several commits when one file held hunks for two commits.
- Attempt: `jj split` with paths, which moves whole files only. `jj-hunk-tool` is not installed.
- Gap: no tool selects hunks non-interactively.
- Workaround: a Python script wrote an intermediate version of the mixed file (the old text with only some hunks applied, and `jj file show -r @-` for the parent text), then `jj split <paths>`, then the full file was copied back.

## 2026-10-06 Heredocs in the shell tool

- Goal: write a short script inline in a shell command.
- Attempt: `python3 - <<EOF` in the shell tool.
- Gap: the shell tool runs fish, which has no heredoc, so the command failed to parse.
- Workaround: the file-write tool created the script under /tmp and the shell ran it.

## 2026-10-06 Operating-system experiments across processes

- Goal: measure whether an inotify event on a SQLite WAL commit can arrive before a reader sees the commit, and whether a SIGKILLed flock holder raises an inotify close event on its lock file.
- Attempt: Code Mode, rejected because its Lua calls only the harness tools.
- Gap: Code Mode has no inotify, SQLite, flock, or process control, and no timing control between two cooperating processes; the shell tool runs one command at a time and returns at exit.
- Workaround: Python scripts using `sqlite3`, `ctypes` inotify, `fcntl.flock`, and `subprocess` with SIGKILL, run once through the shell (kept in /tmp/walexp).

## 2026-10-06 Literal multi-replace again, after the Code Mode rule

- Goal: replace one section of docs/ARCHITECTURE.md and four single lines elsewhere, failing if any old text did not occur exactly once.
- Attempt: none; the earlier Python helper was reused out of habit.
- Gap: the same as the first report. Code Mode could do it with `string.find(text, old, 1, true)` and splicing, but there is no literal replace with an expected count, so each replacement takes several lines of Lua.
- Workaround: the Python `rep(old, new)` script through the shell.

## 2026-10-06 Reading a tool result inside Code Mode

- Goal: read one line of a document in Code Mode, splice a replacement, and pass it to the patch tool.
- Attempt: `tools.builtin_read(...)` followed by `r.output:match(...)`.
- Gap: the shape of `output` is not documented in the Code Mode tool description; it was not a string, so the script failed with "attempt to call a nil value (method 'match')". Each tool's result fields need a stated Lua shape, or a helper that returns a file's text.
- Workaround: the line was read with `sed -n` through the shell and the patch tool was called directly.
