---
title: "Term Full-Frame Encode Benchmark — Baseline"
tags: [nabla, term, benchmark, encode]
status: active
created: 2026-08-12
---

# Term full-frame encode benchmark — baseline

Harness: `term/bench_tests.odin` (gated behind `-define:BENCH=true`).
Measured at Talos workspace stack (terminal batch 1, package surface
`encoded_size`/`encode`/`present` with caller-owned reusable output). This is
the step D24 baseline: full-frame output with reusable storage, measured
before any diffing.

## Machine / toolchain

| | |
|---|---|
| CPU | AMD Ryzen 7 5700X, 8 cores / 16 threads |
| OS | Linux 7.1.8-1-cachyos-gcc |
| Odin | `dev-2026-08-nightly:902106f` (mise-managed) |
| Build | `odin run ./tests/term_tests -collection:nabla=$PWD -define:BENCH=true -o:speed -thread-count:1` |
| Runs | 2026-08-12, one canonical run |

## Method

Each workload builds one `Frame_Buffer` (plain: every cell `"x"` default
style; styled: every cell carries a distinct truecolor foreground/background,
so the SGR-diff path emits per cell), then measures `encode` into one
reusable 4 MiB scratch: 24 warmup frames, then `frames` timed frames with
`time.tick_now`/`tick_diff`. `bytes/frame` is the exact `required` count.

## Results

| workload | cells | us/frame | bytes/frame |
|---|---|---|---|
| plain-80x24 | 1920 | 25.8 | 2087 |
| styled-80x24 | 1920 | 229.5 | 73359 |
| styled-200x50 | 10000 | 1216.5 | 389145 |
| styled-400x100 | 40000 | 4936.2 | 1578107 |
| plain-400x100 | 40000 | 538.0 | 40700 |

## Observations

- **The styled path is ~9-10x the plain path per cell**: every style change
  emits a reset plus two truecolor SGR groups (~38 bytes/cell vs ~1.1
  bytes/cell). Real TUI frames are overwhelmingly plain cells with sparse
  styling, so the styled workloads bound the worst case, not the typical one.
- **No per-frame allocation**: encode writes only into the caller's scratch
  (the benchmark reuses one buffer for all frames); the measured cost is
  pure serialization.
- **Diffing headroom**: a full 400x100 truecolor frame costs ~5 ms here. The
  complete-target `plan_presentation` changed-line path (step D25) will emit
  only changed spans; this baseline is the cost of the full redraw that
  remains the recovery path.
- The 4 MiB scratch comfortably holds every measured frame (worst case
  1.58 MiB for fully-styled 400x100).

## Reproduce

```
cd <nabla checkout>
odin run ./tests/term_tests -collection:nabla=$PWD -define:BENCH=true -o:speed -thread-count:1
```
