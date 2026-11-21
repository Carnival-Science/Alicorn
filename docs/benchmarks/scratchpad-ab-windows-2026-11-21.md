# Matched Scratchpad A/B — Windows, 2026-11-21

Date: 2026-11-21

## Finding

On the same Scratchpad source, generated workspace, and host, the finish-230
Alicorn candidate (sparse region index #227, sparse display finalization #228,
sparse column layout #230, plus #229 phase-1 stage timers) did **not** produce a
reliable improvement in this nine-action command-path workload.

Across the primary seven measured fresh-process pairs, cumulative application
build callback time fell by a paired median **4.47%** (34.22 ms to 33.45 ms) and
the sequence-attributed build time fell **8.42%**. Because the pair spread was
larger than 25% (application build changed between −11.4% and +23.3% per pair),
three additional pairs were run as required. Including them, the ten-pair paired
medians are **−2.27%** for cumulative application build and **−6.29%** for
sequence build, both within the observed pair-to-pair spread. First application
submission was flat (−0.06%), peak working set was flat (−0.33%), and every
process made 17 primary GPU submissions at the median in both arms.

The instrumented work counters explain the result and are the more important
evidence:

- **#227** region keys: `regions_skipped` was **0 in both arms at every step**.
  Scratchpad declares no regions, so the index has no application-level keys to
  skip. Any effect is confined to runtime-internal key bookkeeping.
- **#228** count-changing display splices: the candidate recorded **at most one
  splice per process** (400 ns in the release run, 1 µs in the debug rehearsal),
  and the full display-finalization pass counts were **identical** to the
  baseline at every step (1–3 per step).
- **#230** sparse column layout: `layout_sparse_passes`,
  `layout_suffix_skips`, and `layout_unchanged_skips` were **0 at every step**.
  The editor is a virtual list with fixed row geometry; switching documents
  replaces realized rows but does not change a Column's main-axis child sizes,
  so the sparse column path is not applicable to this workload.

Per-description node visits (reconcile, layout, paint, composition) were
identical between the arms at every step. The only counter difference was the
number of description passes that happened to fall inside the step-7 window
(four versus five), not work per pass. Per-build times inside the sequence were
0.07–2.0 ms, and composition accounted for 0.01–0.08 ms per step in the release
diagnostic. The sparse finalization and layout paths target a small fraction of
a workload dominated by reconcile, measure/layout, and text shaping, and that
fraction did not move.

This is a negative result for the specific claim that #227/#228/#230 improve
ordinary Scratchpad interaction. It does not say the paths are wrong; it says
this workload does not exercise them, and the small total differences that
appeared in the first seven pairs did not reproduce in the confirmation pairs.

## Revisions and environment

| Item | Value |
| --- | --- |
| Baseline | `68d3aff6da14bba44110bcded7631e213d8fd6a0` — last revision before #227 on the same first-parent line |
| Candidate | `576f1fd3919f4954e66a07e6943687e3fa985565` — finish-230 tip (#227, #228, #229 phase 1, #230) |
| Scratchpad | `adb28fc220864e6809c9217e4437af5b92dae57b`, identical source for both arms |
| Caliber | `197cd964cc7265bc60df599a6b8562eac7c75f3a` |
| Host | Windows 10 Home 22H2, build 19045; Ryzen 5 7600X, 12 logical processors; 16 GiB RAM |
| GPU | NVIDIA GeForce RTX 2080 SUPER, driver 32.0.15.9597 (595.97) |
| Native backend | SDL_GPU reference host / Direct3D 12 |
| Toolchain | Odin `dev-2026-11-nightly:08539cd`; Go `go1.27.1` |
| Build profile | Release, Odin `-o:speed`; release backend |
| Display | Scale 1.0; logical size equals pixel size in this capture |
| Theme | Scratchpad default Warm theme; no appearance fixture or saved preference |

### Why the baseline is 68d3aff, not 0beff9d

The requested baseline `0beff9d29f6a1f8b32e0cde895fe4f9ce9f8238c` cannot build
the current Scratchpad frontend. That revision predates the hosted WebGPU host
and the `renderer/cpu` package that current Scratchpad imports; `odin build`
stops at `Path does not exist: alicorn:ui/webgpu`. The failed build log is
committed as
[`baseline-0beff9d-build-attempt.log`](raw/scratchpad-ab-windows-2026-11-21/baseline-0beff9d-build-attempt.log).

`68d3aff` is the immediate parent of the #227 commit on the same first-parent
line and the last revision before #227 that carries the hosted WebGPU host. It
therefore isolates the #227/#228/#230 set (plus the #229 measurement timers)
better than `0beff9d`, which is 326 commits and several platform refactors
earlier.

The build command in the task recipe omitted `--release`, which the driver
defaults to a debug frontend. The committed capture is a release build to match
the 2026-11-04 profile and the release frame-budget question in #229. A debug
rehearsal capture (not committed) showed the same path activation and no
reliable change.

## Workload and method

A generated workspace contained eight directories, 192 small files, a README,
and a 5,002-line `application/sample_00.go` file (193 files total). Each fresh
process ran the same nine actions:

1. Open `README.md`.
2. Open `application/sample_00.go`.
3. Switch back to `README.md`.
4. Open Quick Open.
5. Wait until Quick Open's index is ready, then close it.
6. Open Settings.
7. Close Settings.
8. Close `README.md`.
9. Close the remaining Go document.

A benchmark-only, environment-gated scheduled hook exercised Scratchpad's
existing application/backend command paths. It did not synthesize native
keyboard or pointer input. Each process also passed the existing smoke
publication, worker-wake, and ordered-shutdown checks.

The hook also attributes the application description time that follows each
command to that step, and records the number of description passes in the
window. The first step starts 500 ms after application start; later steps
advance only after the previous step has produced a description, with a 30 ms
floor. A step dispatched in the first 150 ms of startup blocked on backend lanes
that were still initializing (a 2 s command followed by a 4.7 s build), so the
startup wait and description gate are required for a representative sequence
inside the reference host's fixed 3 s smoke window.

There was one unmeasured warmup per revision and seven measured fresh-process
pairs, with order alternating each round. Because the primary pair spread
exceeded 25%, three further fresh pairs were run. All 22 processes passed the
smoke and nine-action sequence checks. The metrics mean:

- **First application submission:** elapsed time from the native application-loop timing origin to the first successful GPU submission that consumed an application frame. Startup-to-submit timing, not input latency.
- **Cumulative app build:** sum of measured application `build` callback durations during the process, including startup and every action.
- **Largest app build:** maximum single application `build` callback duration.
- **Sequence build:** the sum of the nine per-step attributed build windows. A window can contain four to six description passes; `steps.csv` records the pass count.
- **Process CPU:** `Process.TotalProcessorTime` after exit; includes startup and the fixed smoke interval.
- **Peak working set:** Windows process peak working set, sampled every 10 ms while active.
- **Paired change:** median of the per-pair percentage changes, candidate relative to baseline. Positive means higher/slower.
- **Percentiles:** nearest-rank p50/p95 over the measured processes or the paired changes.

Both arms run the **SDL_GPU reference host**. The build carries both renderers;
no renderer override was set, which reproduces the 2026-11-04 measurement path
and is the only path that publishes `application_build_ns`,
`first_application_submit_ns`, and `primary_gpu_submissions`. The hosted WebGPU
renderer was not benchmarked here.

## Results

Times are milliseconds. Each column shows median and observed min–max across
the measured processes. The primary capture is seven pairs; the combined set
adds the three confirmation pairs.

### Cumulative process metrics, primary seven pairs

Times are milliseconds; each revision cell is `p50 (p95)`. Ranges and the full
series are in `summary.json`.

| Metric | Baseline p50 (p95) | Candidate p50 (p95) | Paired median change |
| --- | ---: | ---: | ---: |
| First application submission | 18.930 (19.51) | 19.014 (19.34) | +0.52% |
| Cumulative app build | 34.223 (36.30) | 33.446 (34.47) | −4.47% |
| Largest single app build | 8.074 (9.66) | 8.941 (9.36) | +2.87% |
| Sequence build | 19.395 (21.24) | 18.535 (19.55) | −8.42% |
| Process CPU | 796.875 (812.50) | 750.000 (812.50) | −4.17% |
| Process wall time | 4,116.842 (4,261.02) | 4,042.597 (4,615.22) | −1.62% |
| Native application-loop wall | 3,193.08 (3,232.20) | 3,107.21 (3,170.64) | −2.26% |
| Peak working set (MiB) | 313.42 (316.52) | 313.31 (313.94) | −0.56% |
| Primary GPU submissions | 17 (19) | 17 (19) | 0.00% |

### Cumulative process metrics, primary seven plus three confirmation pairs

| Metric | Baseline p50 (p95) | Candidate p50 (p95) | Paired median change |
| --- | ---: | ---: | ---: |
| First application submission | 18.91 (19.56) | 18.86 (19.56) | −0.06% |
| Cumulative app build | 34.223 (37.30) | 33.509 (38.26) | −2.27% |
| Largest single app build | 8.35 (11.17) | 8.94 (10.41) | −4.25% |
| Sequence build | 19.395 (22.88) | 19.317 (22.50) | −6.29% |
| Process CPU | 781.25 (828.13) | 750.00 (921.88) | −5.88% |
| Process wall time | 4,088.98 (4,261.02) | 4,042.60 (4,689.54) | +2.16% |
| Native application-loop wall | 3,152.10 (3,232.20) | 3,109.72 (3,242.19) | −1.15% |
| Peak working set (MiB) | 312.54 (316.52) | 313.02 (314.31) | −0.33% |
| Primary GPU submissions | 17 (19) | 17 (19) | 0.00% |

The per-pair application-build changes were
`−2.3, −4.5, −11.4, +8.1, −6.1, −9.6, +23.3` in the primary capture and
`−0.3, +11.8, +9.3` in the confirmation pairs. Sequence-build changes were
`−0.4, −15.0, −13.1, +10.8, −8.4, −19.4, +30.7` and `−6.3, +15.2, +10.9`.
The confirmation pairs pull both medians toward zero; the sign of the effect is
not stable at this sample size.

### Sequence steps, ten pairs

Build time is the attributed description window for the step; action time is
the wall time inside the command dispatch. Each column is a median over ten
processes. `builds` is the median number of descriptions in the step window.

| Step | Build baseline | Build candidate | Paired build | Builds | Action baseline | Action candidate | Paired action |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0. Open README | 0.574 | 0.620 | +6.45% | 3 | 1.076 | 1.251 | +16.90% |
| 1. Open 5,002-line Go document | 7.158 | 7.421 | −0.82% | 5 | 1.829 | 1.765 | −7.03% |
| 2. Switch back to README | 0.347 | 0.341 | +0.67% | 3 | 0.394 | 0.407 | −0.57% |
| 3. Open Quick Open | 0.223 | 0.219 | −4.25% | 2 | 0.006 | 0.009 | +66.67% |
| 4. Close Quick Open | 0.584 | 0.584 | +1.41% | 4 | 0.004 | 0.001 | −80.56% |
| 5. Open Settings | 0.983 | 0.872 | −17.63% | 2 | 0.009 | 0.009 | −12.32% |
| 6. Close Settings | 0.129 | 0.129 | −9.07% | 1 | 0.525 | 0.585 | +3.28% |
| 7. Close README | 8.518 | 8.446 | +5.31% | 4 | 0.398 | 0.388 | +3.63% |
| 8. Close remaining Go document | 0.120 | 0.066 | −13.13% | 1 | 0.433 | 0.418 | −28.27% |

Only two steps move by more than 0.05 ms: Settings open (−0.111 ms) and the
final document close (−0.054 ms). Both are in the direction of the candidate,
but both are small relative to the pair spread. Step 7 appeared 14.7% faster in
the primary seven pairs and only 5.3% slower (paired) once the three
confirmation pairs were included, so it is not evidence of a stable gain.
Per-step p95 build values widen the picture: opening the large document is
9.49 ms baseline versus 8.00 ms candidate, while closing README is 10.50 ms
baseline versus 11.28 ms candidate; Settings open is 1.26 versus 0.99 ms and
every other step p95 is below 0.72 ms. Full p50/p95 and paired arrays are in
`summary.json`. The dominant costs are opening the large document (~7–7.4 ms
across five description passes) and closing README (~8.4–8.5 ms across four
passes). The largest single build in each process (8.4–8.9 ms) is at least as
large as any full step window and can fall in the initial mount or the first
large document rebuild; per-pass medians inside the sequence are 0.07–2.0 ms.

### Work counters

A matched diagnostic variant of the same hook printed cumulative `Frame_Stats`
deltas per step; the A/B binaries do not print or use them. Medians over three
release pairs per arm:

| Step | Described nodes B/C | Reconcile nodes B/C | Paint nodes B/C | Composition nodes B/C | Full display passes B/C | Regions skipped B/C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 278 / 278 | 278 / 278 | 65 / 65 | 140 / 140 | 3 / 3 | 0 / 0 |
| 1 | 938 / 938 | 938 / 938 | 299 / 299 | 277 / 277 | 3 / 3 | 0 / 0 |
| 2 | 342 / 342 | 342 / 342 | 60 / 60 | 110 / 110 | 2 / 2 | 0 / 0 |
| 3 | 244 / 244 | 244 / 244 | 9 / 9 | 139 / 139 | 2 / 2 | 0 / 0 |
| 4 | 459 / 459 | 459 / 459 | 4 / 4 | 120 / 120 | 2 / 2 | 0 / 0 |
| 5 | 286 / 286 | 286 / 286 | 30 / 30 | 184 / 184 | 2 / 2 | 0 / 0 |
| 6 | 115 / 115 | 115 / 115 | 1 / 1 | 60 / 60 | 1 / 1 | 0 / 0 |
| 7 | 988 / 1274 | 988 / 1274 | 253 / 286 | 214 / 247 | 2 / 2 | 0 / 0 |
| 8 | 56 / 56 | 56 / 56 | 7 / 7 | 39 / 39 | 1 / 1 | 0 / 0 |

The step-7 difference is one extra description pass inside the candidate's
window (988 = four passes of 247 nodes; 1274 = 988 + 286), not more work per
pass. The candidate also recorded one global fallback on step 3 in all three
diagnostic runs, where the baseline recorded none; step 3's build and action
times are essentially unchanged, so it is a path difference without a
measurable cost.

Candidate-only release diagnostics (three runs):

| Step | Splicing operations | Splice time | Sparse layout passes | Description | Reconcile | Layout | Paint | Composition |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 0 | 0 | 0 | 1.748 ms | 1.077 ms | 0.477 ms | 0.028 ms | 0.037 ms |
| 1 | 0 | 0 | 0 | 12.603 ms | 4.336 ms | 2.179 ms | 0.118 ms | 0.080 ms |
| 2 | 0 | 0 | 0 | 1.541 ms | 1.169 ms | 0.134 ms | 0.025 ms | 0.028 ms |
| 3 | 0 | 0 | 0 | 0.874 ms | 0.636 ms | 0.185 ms | 0.013 ms | 0.033 ms |
| 4 | 1 | 0.4 µs | 0 | 1.564 ms | 0.948 ms | 0.037 ms | 0.017 ms | 0.032 ms |
| 5 | 0 | 0 | 0 | 1.855 ms | 0.908 ms | 0.453 ms | 0.029 ms | 0.035 ms |
| 6 | 0 | 0 | 0 | 0.439 ms | 0.305 ms | 0.001 ms | 0.004 ms | 0.019 ms |
| 7 | 0 | 0 | 0 | 10.447 ms | 2.464 ms | 0.804 ms | 0.069 ms | 0.041 ms |
| 8 | 0 | 0 | 0 | 0.694 ms | 0.555 ms | 0.094 ms | 0.007 ms | 0.010 ms |

Composition is 0.6–4.3% of the description window, and sparse layout never
runs. Even a perfect finalization or column-placement pass cannot remove a
meaningful share of these steps.

## Interpretation

### #227 indexed region invalidation — no application effect

Scratchpad does not declare regions: both arms report `regions_skipped = 0` at
every step. The index can only change internal invalidation bookkeeping, and
the reconcile node counts are identical. The +0.17 ms step-0 command time is
below the action-time noise; there is no basis to claim an improvement from
#227 for this application.

### #228 sparse finalization — active but immaterial

The splice path did engage: one count-changing repaint per process, taking
0.4 µs (release) or 1 µs (debug). It did not reduce the full display pass
counts. The steps with the most display-list churn (switch back to README,
close README) show identical pass counts to the baseline and per-build times
within ±0.06 ms. The primary seven-pair improvement on close-README did not
survive the confirmation pairs. #228 is safe on this workload but does not
measurably improve it.

### #230 sparse column layout — not exercised

All three attribution counters (`layout_sparse_passes`,
`layout_suffix_skips`, `layout_unchanged_skips`) are zero for all nine steps.
The editor and tree are virtualized fixed-row lists; scrolling and document
switches change data and realized rows, not the main-axis sizes of a Column's
children. The only large layout costs are the initial mount and the document
open/close rebuilds, which are not suffix-placement cases. This workload can
not validate #230; a dedicated resize or expanding-row fixture is required.

### Relation to the #229 frame budget

This capture adds one negative data point to #229: the candidate does not
reduce the dominant 7–9 ms application-build steps, and the largest single
build remains above an 8.33 ms 120 Hz frame in both arms. The sparse paths
target 0.01–0.08 ms of composition work and are not on the critical path for
these command interactions. The next useful measurements are the resize/typing
scenarios in the Scratchpad-shaped fixture, where #230's main-axis size changes
and #228's count-changing repaints are actually exercised.

## Limitations

- The hook invokes application/backend command paths on a schedule. It is not native keyboard or pointer input, so it does not measure input latency or input-to-display delivery.
- Timings are CPU wall time, not GPU execution or scanout.
- One Windows host (Ryzen 5 7600X, RTX 2080 SUPER), one Odin build, display scale 1.0. Do not compare these numbers across machines.
- The measured path is the SDL_GPU reference host; the hosted WebGPU renderer was not benchmarked. The build command's `--renderer=webgpu` selects a renderer for launches, not for the built binary; no renderer override was set at run time.
- The generated workspace is a fixture: eight directories, 192 small files, one 5,002-line file. It does not model Scratchpad's full document set, worker activity, session restoration, or every after-frame callback.
- The per-step windows include four to six description passes. Use `builds` in `steps.csv` for per-pass normalization; whole-process `application_build_ns` is the robust cumulative metric.
- The first step waits 500 ms and later steps advance on the prior description; this differs from the fixed 150 ms cadence of the 2026-11-04 A/B. Absolute process wall time is therefore not comparable to that report.
- The baseline was substituted (`68d3aff` for the unbuildable `0beff9d`), and the frontend was built with `--release` because the driver defaults to debug. Both deviations are recorded in the manifest.
- The candidate includes the always-on #229 stage timers, which add per-node counter reads. The observed pair spread and the occasional multi-hundred-millisecond first-submit outlier are larger than any effect that instrumentation could explain here, but it is a real asymmetry between the arms.

## Reproduction artifacts

- [Capture manifest and SHA-256 hashes](raw/scratchpad-ab-windows-2026-11-21/manifest.json)
- [Per-process CSV, primary seven pairs](raw/scratchpad-ab-windows-2026-11-21/samples.csv)
- [Per-process per-step CSV](raw/scratchpad-ab-windows-2026-11-21/steps.csv)
- [PowerShell runner](raw/scratchpad-ab-windows-2026-11-21/run_windows_ab.ps1)
- [Scratchpad nine-action hook patch](raw/scratchpad-ab-windows-2026-11-21/scratchpad-perf-sequence-hook.patch)
- [All 16 primary process logs](raw/scratchpad-ab-windows-2026-11-21/logs/) — includes the two unmeasured warmups; `samples.csv` has the 14 measured rows
- [Confirmation pairs and logs](raw/scratchpad-ab-windows-2026-11-21/confirmation/)
- [Work-counter deltas](raw/scratchpad-ab-windows-2026-11-21/diagnostics/counter-deltas.csv)
- [Candidate sparse counters and stage timings](raw/scratchpad-ab-windows-2026-11-21/diagnostics/candidate-sparse-counters.csv)
- [Requested-baseline build failure](raw/scratchpad-ab-windows-2026-11-21/baseline-0beff9d-build-attempt.log)
