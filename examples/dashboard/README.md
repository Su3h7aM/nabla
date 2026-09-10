# TUI Dashboard Example

A TUI example demonstrating the current **layout** and **terminal**
packages end to end. It renders a dashboard scene (sidebar + main list +
status bar — see `panels.odin`) into a terminal session with full-frame
presentation, environment-based color depth, keyboard navigation, and
clean teardown.

## Run

```
./scripts/example          # or: mise run example
```

Requires a real terminal (a PTY); outside one, `term.open` reports
`No_Controlling_Tty`.

## What it demonstrates

### Terminal (`main.odin`)

- **Session lifecycle**: `open` with options (alternate screen), clean
  `close` with full restoration (raw mode, alternate screen).
- **Automatic resize re-render**: the input read blocks up to 100 ms and
  the viewport is re-read on every wake — a terminal resize re-solves and
  re-renders the layout within that window, with no keypress needed. An
  idle terminal does not redraw.
- **Cursor intent**: `Cursor_Intent.Position` — the terminal cursor is
  visible and follows the selected row.
- **Environment-based color depth**: `term.profile_default()` reads
  `NO_COLOR` / `COLORTERM` / `TERM`. Emission is depth-aware: TrueColor
  as authored, 256 via the xterm cube, 16/8 via the nearest ANSI entry,
  `None` drops colors. Try `TERM=xterm-256color`, `TERM=xterm`, or
  `NO_COLOR=1` to see the reduction.
- **Full-frame `present`**: presentation baseline, per-row cursor
  positioning, run-gated SGR style diff, bottom-right cell reservation,
  frame-end restore.
- **Styles**: RGB and indexed colors; modifiers (bold, dim, italic,
  underline, reverse, strikethrough).

### Layout (`panels.odin`)

- Container flows (row/column), sizing modes (fixed / grow / percent /
  fit), padding and gap, justify modes.
- A **feature showcase pane**: each row is labeled with the feature it
  demonstrates — weighted grow (1:2), percent (25/50/25), justify
  Space_Between, justify Space_Evenly, cross-axis align End.
- Text nodes with measurement and wrapping (`measure_text` /
  `break_text`).
- Result queries (lookup by id) and overflow diagnostics.
- Caller-owned fixed storage (`layout.init_from_buffer`).

### Input

- Keyboard navigation via the `input` package: Up/Down move the
  selection, `q` / Escape quit.
