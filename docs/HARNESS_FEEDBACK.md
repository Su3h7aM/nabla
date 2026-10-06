# Harness feedback

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

## 2026-10-07 Model spelling when starting a subagent

- Goal: start two subagents on Sonnet.
- Attempt: `agent_spawn` with model `claude-sonnet-5-5` and no provider.
- Gap: the bare model id did not resolve; only the catalog id with its vendor prefix did. The error listed the valid ids, so the fix was quick, but the schema does not say which form is expected. Related to the provider spelling report above.
- Workaround: `model = anthropic/claude-sonnet-5-5`, `provider = cliproxyapi`.

## 2026-10-07 Reading a long converted text file

- Goal: read a PDF converted to text with `pdftotext`, about 700 lines per read.
- Attempt: `builtin_read` with a 700-line limit.
- Gap: the result was cut at about 32 KB, so the requested range was not all visible, and the notice did not give the next offset to resume from.
- Workaround: smaller line ranges.

## 2026-10-07 Bash loop syntax in the fish shell tool

- Goal: grep several names across the repository in one shell command.
- Attempt: a bash `for ...; do ... done` loop and an unquoted `--include=*.odin` glob in `builtin_shell`.
- Gap: fish rejected both ("Unknown command: do", "No matches for wildcard"). The command ran until exit 124, and the parse error was echoed about 25 times in stderr. The tool description names the shell but not its common syntax differences.
- Workaround: Code Mode calling `tools.builtin_shell` once per name, with quoted globs.

## 2026-10-07 Overlapping context in grep results

- Goal: see a few lines around close matches with `fff_grep` and `context`.
- Attempt: `fff_grep` on `catalog_model_provider` and `MAX_MESSAGE_DEPTH` with context lines.
- Gap: overlapping context blocks were repeated for nearby matches, and leading indentation was lost in `content` output.
- Workaround: `builtin_read` of the line range.
