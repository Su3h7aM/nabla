# Harness feedback

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
