---
title: "C6b Baseline Benchmark — Report and Verdict (rev 2)"
tags: [nabla, layout, c6b, benchmark, grow-children, soa]
status: active
created: 2026-08-04
---

# C6b baseline benchmark — report and verdict (rev 2)

Revision 2 adds the adversarial saturation family from Orpheus's review of PR
`19c0f47` (tip `9d998831`), extends the size range to n = 8000, and documents a
scratch instrumentation of the real `_grow_children` loop that verifies the
saturation pass counts directly.

Harness: `layout/bench_test.odin` (gated behind `-define:BENCH=true`).
Measured at repo `main` = `b05c2ca2` (C5 merged), plus the benchmark commits.

## Machine / toolchain

| | |
|---|---|
| CPU | AMD Ryzen 7 5700X, 8 cores / 16 threads (scaling 80%) |
| OS | Linux 7.1.5-1-cachyos-gcc |
| Odin | `dev-2026-07-nightly:819fdc7` (mise-managed) |
| Build | `odin test ./layout -define:BENCH=true -o:speed -thread-count:1` |
| Runs | 5 datasets collected 2026-08-04 17:25-18:05 UTC; system load 1.8-2.0 (other workloads present) |

## Method

Each point: a fresh context sized for the workload, 24 warmup frames (steady
pool sizes, frame error checked), then 5-7 repeat runs of `frames` consecutive
frames each, timed with `time.tick_now`/`tick_diff` (monotonic ns). Reported
per-frame microseconds: mean over the repeat-run means, plus min/max/stddev of
those means. Large sizes use more frames (400/300/200 at n = 2000/4000/8000).

## Workloads

1. **ordinary** — root column (padding 8, gap 4): fixed header (h=24), body
   row (gap 4) of a fixed-width sidebar column (w=180, 24 fixed rows) + a grow
   main column of `rows` rows (h=28, padding 4), fixed footer (h=20).
   Viewport `{1200, rows*28+64}`. Fixed + single-pass grow distribution.
2. **grow-linear** — single row, width `4n`, of `n` children
   `grow(1, 0, max=1e6)` — no saturation, one `_grow_children` pass. Control.
3. **grow-saturating** — same row; each child's max from the constant-gap
   recurrence (gap `1/(2n)` below the running per-pass proposal).
4. **grow-adversarial** — the review's construction: first cap 3.5, then each
   remaining cap is the current equal-share proposal minus 1e-5, the proposal
   recomputed after each cap.

## Pass-count verification (instrumented real loop)

A scratch copy of `solve.odin` was instrumented (uncommitted, temporary) to
count `_grow_children` invocations and while-loop iterations per frame for the
adversarial construction:

| n | calls/frame | passes/frame (all) | passes with candidates | max passes in one call |
|---|---|---|---|---|
| 125 | 137 | 143 | 8 | **7** |
| 250 | 283 | 290 | 8 | **8** |
| 500 | 679 | 687 | 16 | **9** |
| 1000 | 1236 | 1245 | 82 | **10** |
| 2000 | 2659 | 2669 | 182 | **11** |
| 4000 | 4001 | 4011 | 10 | **11** |
| 8000 | 8001 | 8012 | 11 | **12** |

Key facts:

- **The saturation loop itself runs 7-12 passes per frame — logarithmic growth
  with n, not linear.** `max passes in one call` (the row's `_grow_children`)
  is 7, 8, 9, 10, 11, 11, 12. The harness's `sim_passes` column (a faithful
  simulation of the loop) predicts exactly these values: 7, 8, 9, 10, 11, 11,
  12 — verified against the real loop at every size.
- **The ~n "passes" in the review's numbers (n + 7..11) are per-node
  invocations, not saturation iterations.** `_resolve_axis` calls
  `_resolve_children_axis` per node, and every node with a main axis calls
  `_grow_children`; leaf parents have zero candidates and exit in one trivial
  iteration (0 children scanned). `calls/frame ≈ n`, `all_passes ≈ n +
  real_passes`. The review's observed counts of 132/258/509/1009/2011 equal
  n + 7/8/9/9/11 — n trivial invocations plus 7-11 real saturation passes.
- No equal-weight max arrangement reached more than ~12 passes; the O(n²)
  upper bound requires pass count ∝ n, which the loop's arithmetic makes
  unreachable (saturating children with caps below the current proposal
  cascade in bulk; one-per-pass arrangements require gaps that collapse).

## Results (canonical run, dataset 5; µs/frame)

| workload | n=125 | 250 | 500 | 1000 | 2000 | 4000 | 8000 |
|---|---|---|---|---|---|---|---|
| grow-linear | 26.94 | 53.17 | 114.17 | 240.17 | 683.63 | 1514.45 | 3096.54 |
| grow-saturating (sim 7-11) | 27.89 | 55.45 | 115.29 | 244.78 | 792.36 | 1602.05 | 3181.81 |
| grow-adversarial (sim 7-12) | 29.27 | 59.61 | 123.63 | 270.73 | 786.61 | 1789.08 | 3121.00 |

Full per-run output with min/max/stddev is captured below for the canonical
run; all five datasets' means are in the cross-run table.

### Cross-run medians (5 datasets; min-max spread)

| size | linear median (spread) | saturating median | adversarial median | adv/lin |
|---|---|---|---|---|
| 125 | 26.79 (26.32-27.07) | 27.62 | 29.38 | 1.097 |
| 250 | 53.50 (52.59-53.80) | 55.35 | 59.76 | 1.117 |
| 500 | 110.43 (104.54-115.70) | 117.52 | 123.66 | 1.120 |
| 1000 | 237.08 (215.63-240.44) | 245.94 | 270.64 | 1.142 |
| 2000 | 572.43 (478.18-683.63) | 602.26 | 693.84 | 1.231 |
| 4000 | 1334.78 (1313.12-1514.45) | 1371.67 | 1713.88 | 1.284 |
| 8000 | 2674.72 (2588.35-3096.54) | 2832.53 | 3145.13 | 1.180 |

Per-run adv/lin ratios: n=125: 1.09-1.12; n=250: 1.11-1.14; n=500: 1.11-1.19;
n=1000: 1.11-1.26; n=2000: 1.00-1.47; n=4000: 1.18-1.33; n=8000: 1.01-1.41.

## Analysis

- **Scaling is linear in every workload.** Doubling n doubles time: linear
  4000→8000 is 1.92-2.06× across runs; adversarial 4000→8000 is 1.74-2.13×.
  Quadratic behavior would show 4× per doubling; nothing approaches that, and
  the pass count (verified 7-12, flat) rules it out structurally.
- **The adversarial family adds a flat ~10-20% over the linear control**, not
  a growing factor. The ratio wobbles 1.09-1.28 across n with run-to-run noise
  of ±10-15% at n ≥ 2000 (system load 1.8-2.0); a quadratic term would grow
  the ratio ∝ n (≈2× at 2000, ≈8× at 8000) — clearly absent.
- **`_grow_children` is not the frame's cost driver.** The saturation loop is
  bounded at ~12 passes; the frame's ~200-340 ns/element is spread over
  declaration, measurement, solving, placement and command emission. Even the
  most adversarial reachable saturation adds only ~10-20% whole-frame.
- All workloads share a mild per-element cost drift (linear: ~215 ns/elem at
  n=125 to ~330 ns/elem at n=8000) — a cache/pool effect common to every
  workload, not specific to `_grow_children`.

## Verdict (per D9: measure first; no win, don't do it)

**C6b is recorded as a no-op.** With the review's adversarial family measured
over a 64× size range and the saturation pass counts verified directly against
the instrumented real loop (7-12 passes, logarithmic growth), there is no
super-linear cost to fix: the SoA split of `_Node_Input`/`_Context_State` and
any `_grow_children` rewrite are not justified by the measurements.

Scope boundaries: geometry only (no text measurement — separate cost center).
The debug-runner thread-count pin remains a separate CI/tooling follow-up.
D7 (`tui` rendering from the command stream) is unchanged, its own commit
later.

## Reproduce

```
cd <nabla checkout at main>
odin test ./layout -collection:nabla=$PWD -define:BENCH=true -o:speed -thread-count:1
```

## Canonical run raw output (dataset 5, µs/frame)

```
== grow-linear ==
workload	n	frames	sim_passes	mean_us/frame	min_us	max_us	stddev_us
grow-linear	125	3000	0	26.94	26.55	28.73	0.73
grow-linear	250	1500	0	53.17	52.92	53.31	0.13
grow-linear	500	800	0	114.17	109.69	122.80	3.80
grow-linear	1000	400	0	240.17	236.45	242.27	1.83
grow-linear	2000	400	0	683.63	547.99	829.05	89.47
grow-linear	4000	300	0	1514.45	1388.79	1669.24	99.45
grow-linear	8000	200	0	3096.54	2655.95	3475.29	287.09

== grow-saturating ==
grow-saturating	125	3000	7	27.89	27.28	30.08	0.91
grow-saturating	250	1500	7	55.45	54.83	55.96	0.53
grow-saturating	500	800	8	115.29	112.98	117.40	1.27
grow-saturating	1000	400	8	244.78	240.37	250.82	3.63
grow-saturating	2000	400	9	792.36	670.94	869.52	63.06
grow-saturating	4000	300	10	1602.05	1480.85	1739.85	90.93
grow-saturating	8000	200	11	3181.81	2962.77	3614.73	189.75

== grow-adversarial (review construction: cap 3.5, then proposal - 1e-5) ==
grow-adversarial	125	3000	7	29.27	28.94	29.94	0.31
grow-adversarial	250	1500	8	59.61	59.25	60.21	0.30
grow-adversarial	500	800	9	123.63	121.94	127.28	1.66
grow-adversarial	1000	400	10	270.73	265.57	278.98	4.14
grow-adversarial	2000	400	11	786.61	709.13	872.96	62.18
grow-adversarial	4000	300	11	1789.08	1653.62	1939.60	105.78
grow-adversarial	8000	200	12	3121.00	2971.25	3351.85	125.45
```
