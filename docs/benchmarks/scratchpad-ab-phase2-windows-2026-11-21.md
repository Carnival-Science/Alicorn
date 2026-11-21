# Matched Scratchpad A/B — phase 2 description reuse, Windows, 2026-11-21

Date: 2026-11-21

## Finding

This capture reruns the matched real-Scratchpad A/B with the issue #229 phase 2
exact retained-description reuse fast path (`26be891`) in the candidate, and
adds one bounded text-editing scenario that the nine-action command sequence
does not contain.

1. **Phase 2 is active on real Scratchpad, and the counters are not zero.**
   Across the nine command steps the candidate reports **3,052 of 3,706**
   described nodes (82.4%) as exact retained matches, i.e. the copy path,
   dirty marking, measure observation, layout propagation, paint queueing, and
   text-run decision were skipped for those nodes. In the new typing burst,
   **855 of 858** nodes per character (99.65%) are exact matches. The phase-2
   gate is therefore exercised by both scenarios; the previous capture's
   question ("does the fast path do anything on real Scratchpad?") is answered
   yes.

2. **The nine-action command sequence still shows no reliable improvement.**
   The fresh 13-pair combined medians are **+3.28%** for cumulative application
   build (33.24 → 33.65 ms) and **+8.31%** for sequence build (19.22 → 20.43
   ms). The seven primary pairs gave +3.3% / +8.3%, the three confirmation
   pairs +9.8% / +16.8%, and the three supplementary pairs **−6.1% / −1.9%**.
   The sign is not stable across segments, and the copy bucket is simply too
   small: the candidate's remaining copy work totals 0.59 ms across all nine
   steps, and even the whole skipped bucket can only be a couple of
   milliseconds of a 19–20 ms sequence. Within that band the exact-comparison
   cost on changed passes and the run-to-run noise dominate.

3. **The new typing burst does show a consistent cumulative application-build
   reduction.** Ten matched pairs (7 primary + 3 confirmation) of a 24-character
   insert burst on the 5,002-line fixture document give a paired median
   **−10.21%** in cumulative application build (76.67 → 66.68 ms), with all
   ten pairs negative (−0.3% to −59.1%, the latter including a baseline stall).
   The per-character application-**describe** windows are flat (+0.5% on the
   burst total; per-step medians 0.91 vs 0.90 ms), and startup, setup, and tail
   are flat too. The saving is in the part of the frame outside
   `scratchpad_build_describe` — the host's `begin_frame`/`end_frame` runtime
   reconcile, layout, and paint work — which is exactly where the phase-2 gate
   runs. The baseline revision has no phase-1 stage timers, so the saving cannot
   be split further per stage from this capture; the candidate counters show
   the copy stage is 0.006 ms per 858-node character pass.

4. **Tail stalls are real and unattributed.** Two of thirteen candidate
   sequence processes recorded a single 32 ms and 76 ms build in the
   close-Quick-Open step; none of thirteen baseline sequence processes did. A
   separate diagnostic run caught a 15.5 ms stall with
   `stage_description_ns` 16.9 ms and `stage_reconcile_ns` 1.3 ms, and one
   baseline typing process stalled for 104 ms. The stalls are in the
   application/host portion of the frame, not phase-2 reconcile, and they occur
   in both arms. They inflate the candidate p95 in this capture and are reported
   as a tail risk, not as a phase-2 effect.

The short answer to "is phase 2 application-visible on real Scratchpad?" is:
**yes, in cumulative application-build CPU during text editing (about
−10%); no, not in the open/close/switch command sequence, where the copy
bucket is too small and the segment medians disagree in sign.** The per-character
describe time and process wall time do not move.

## Revisions and environment

| Item | Value |
| --- | --- |
| Baseline | `68d3aff6da14bba44110bcded7631e213d8fd6a0` — last revision before #227 on the same first-parent line |
| Candidate | `78695d1ae5a861259c2fec37d407b3b6b53009c0` — finish-229-phase2-ab tip (#227, #228, #229 phase 1+2, #230) |
| Previous-run reference | `576f1fd3919f4954e66a07e6943687e3fa985565` — finish-230 tip, no phase 2 |
| Phase-2 change | `26be891` `perf(runtime): reuse exact retained descriptions (issue #229 phase 2)` |
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

The requested baseline `0beff9d` cannot build the current Scratchpad frontend:
it predates the hosted WebGPU host and the `renderer/cpu` package, and
`odin build` stops at `Path does not exist: alicorn:ui/webgpu`. The previous
capture recorded the failed build; this capture reuses the same substitution.
`68d3aff` is the immediate parent of the #227 commit and the last revision
before #227 that carries the hosted WebGPU host.

### What changed since the previous capture

- Candidate is now `78695d1` instead of `576f1fd`; the only runtime change in
  the measured interval is phase 2 plus the phase-2 tests/docs. The #227,
  #228, #229 phase-1, and #230 code is unchanged.
- A fresh baseline (`68d3aff`) was built and run in the same session, so every
  pair in this capture is matched; the previous baseline numbers are shown for
  context only.
- The nine-action protocol — fixture, cadence, metrics, warmup/confirmation
  structure, runner, and hook patch — is reused from the previous capture; the
  hook patch is byte-for-byte identical (SHA-256 `D35C7016…`).
- A bounded 24-character typing burst was added as a separate, env-gated
  scenario; it did not exist in the previous capture.
- Three supplementary nine-action pairs were run after the required 7 + 3
  because the confirmation segment disagreed with the primary segment in sign.
  They are reported as a separate segment and in the 13-pair combined table.

## Workload and method

### Nine-action command sequence

The generated workspace is the previous fixture: eight directories, 192 small
files, a README, and a 5,002-line `application/sample_00.go` (193 files). Each
fresh process runs:

1. Open `README.md`.
2. Open `application/sample_00.go`.
3. Switch back to `README.md`.
4. Open Quick Open.
5. Wait until Quick Open's index is ready, then close it.
6. Open Settings.
7. Close Settings.
8. Close `README.md`.
9. Close the remaining Go document.

The benchmark-only hook invokes the same application/backend command paths a
user action reaches; it does not synthesize native keyboard or pointer input.
The first step starts 500 ms after application start; later steps advance after
the previous step's description, with a 30 ms floor. The hook credits every
description built between a step and the next to that step.

Protocol: one unmeasured warmup per revision, seven measured fresh-process
pairs with order alternating each round; because the primary spread exceeded
25%, three further confirmation pairs; then three supplementary pairs after the
confirmation sign disagreed with the primary. All 26 measured processes (plus
two warmups) passed the smoke and nine-step acceptance checks.

### Bounded typing burst

A separate env-gated scenario opens `application/sample_00.go`, waits for the
bounded source window and the editor scroll owner, then delivers 24 committed
single-character `Application_Text_Input_Event{kind=.Commit}` events through
`editor_text_input` — the same application path platform text input reaches.
No native key events are synthesized. Each character advances only after the
previous character's description was built, with the same 30 ms floor. The
setup phase (open plus settling) and the post-burst tail are attributed
separately; the 24 character windows are the measured steps.

Protocol: one unmeasured warmup, seven primary pairs, three confirmation pairs,
all matched fresh processes (10 pairs total). Every process completed all 24
characters.

The typing scenario's hook is committed as
`scratchpad-perf-typing-hook.patch` (candidate variant with the phase-2
counter print) and `scratchpad-perf-typing-hook-common.patch` (baseline variant
without the fields that do not exist before phase 2). The two variants differ
only in the extra counter fields printed at step boundaries; the extra print is
outside the measured windows.

### Metrics

- **First application submission:** elapsed time from the native
  application-loop timing origin to the first GPU submission that consumed an
  application frame. This is startup-to-submit, not input latency. Absolute
  values shifted between sessions in this capture (~19 ms in the previous
  capture, ~11 ms here); only the paired change is meaningful.
- **Cumulative app build:** the host's sum of application build callback
  durations. This includes `begin_frame`, the application describe callback,
  `end_frame` (runtime reconcile/layout/paint), and after-frame work.
- **Per-step build (`build_ns`):** the time inside the application's
  `scratchpad_build_describe` only, credited to the step. It deliberately
  excludes `end_frame`, so it is not the whole runtime description window. This
  distinction is why the typing burst shows its win in cumulative app build but
  not in per-step build.
- **Sequence build / typing build:** the sum of the per-step `build_ns`
  windows. A command step can contain one to six description passes; `steps.csv`
  records the pass count.
- **Process CPU:** `Process.TotalProcessorTime` after exit; includes startup
  and the fixed smoke interval.
- **Peak working set:** Windows process peak working set, sampled every 10 ms.
- **Paired change:** median of the per-pair percentage changes, candidate
  relative to baseline. Positive means higher/slower.
- **Percentiles:** nearest-rank p50/p95 over the measured processes or the
  paired changes. For the three-pair segments p95 is not informative (nearest
  rank collapses to the sample maximum); use the 13-pair combined p95.

Both arms run the **SDL_GPU reference host**; no renderer override was set.
The build carries both renderers. The hosted WebGPU renderer was not
benchmarked.

## Results

Times are milliseconds. `B` is baseline `68d3aff`, `C` is candidate
`78695d1`. Primary/confirmation/supplementary rows are separate capture
segments; the combined rows are the 13 measured pairs.

### Nine-action cumulative process metrics

| Metric | Primary 7 pairs B → C | Confirmation 3 pairs B → C | Supplementary 3 pairs B → C | Combined 13 pairs B p50 (p95) → C p50 (p95) | Combined paired |
| --- | ---: | ---: | ---: | ---: | ---: |
| First application submission | 10.445 → 11.223 | 11.702 → 10.570 | 11.304 → 11.498 | 10.952 (60.68) → 11.223 (11.83) | −0.68% |
| Cumulative app build | 33.468 → 33.568 | 32.285 → 35.438 | 33.220 → 30.807 | 33.239 (37.94) → 33.652 (64.50) | **+3.28%** |
| Largest single app build | 8.651 → 10.157 | 8.807 → 11.071 | 8.793 → 8.545 | 8.793 (10.36) → 9.118 (32.14) | +7.51% |
| Sequence build | 19.349 → 20.429 | 18.088 → 21.128 | 19.223 → 18.171 | 19.223 (22.49) → 20.429 (50.42) | **+8.31%** |
| Process CPU | 796.875 → 765.625 | 765.625 → 750.000 | 859.375 → 765.625 | 796.875 (984.38) → 765.625 (812.50) | −5.45% |
| Process wall time | 4,505.18 → 4,324.99 | 4,382.72 → 4,164.46 | 4,085.58 → 4,031.81 | 4,464.38 (4,809.84) → 4,164.46 (5,352.33) | +2.06% |
| Native application-loop wall | 3,244.88 → 3,403.25 | 3,128.56 → 3,141.73 | 3,092.19 → 3,221.98 | 3,130.97 (3,386.25) → 3,208.88 (3,469.50) | +1.21% |
| Peak working set (MiB) | 325.96 → 325.55 | 325.90 → 325.91 | 327.07 → 327.37 | 325.96 (328.52) → 325.79 (327.64) | −0.07% |
| Primary GPU submissions | 17 (18) → 17 (17) | 17 (17) → 17 (17) | 17 (17) → 17 (17) | 17 (18) → 17 (17) | 0.00% |

The per-pair application-build changes over all thirteen pairs were
`−4.3, −1.8, +8.7, +192.2, +3.3, +9.2, −13.3, +8.3, +90.5, +9.8, −6.1, −7.6,
−2.9`; the sequence-build changes were
`−3.5, +1.2, +15.0, +332.9, +8.3, +15.9, −17.1, +16.8, +147.5, +16.5, +1.5,
−5.5, −1.9`. The two large positive pairs are the close-Quick-Open stalls
described below. The supplementary segment (the last three pairs) is the only
segment where the candidate is faster on average; the primary and confirmation
segments are both in the direction of a small regression. The sign is not
stable, so this capture does not establish a direction for the command
sequence.

The p95 inflation is entirely the two stalls: the candidate's combined app-build
p95 is 64.50 ms against 37.94 ms, and sequence-build p95 is 50.42 ms against
22.49 ms. The medians are the robust comparison; the tails are a separate
observation. The baseline first-submit p95 (60.68 ms) is likewise one startup
outlier, not a steady-state value; the paired median is the meaningful number.

### Sequence steps, thirteen pairs

Build time is the attributed application-describe window (`build_ns`); action
time is the wall time inside the command dispatch. Each column is a median over
thirteen processes. `builds` is the median number of descriptions in the step
window. The previous-run columns are the ten-pair medians from the previous
capture (`576f1fd`) for direct comparison; they are not paired with this
capture.

| Step | Build B (prev) | Build C (prev) | Build B (fresh) | Build C (fresh) | Paired fresh | Builds (fresh) | Action B (fresh) | Action C (fresh) | Paired action |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0. Open README | 0.574 | 0.620 | 0.575 | 0.581 | +10.94% | 3 / 3 | 1.149 | 1.225 | +4.54% |
| 1. Open 5,002-line Go document | 7.158 | 7.421 | 7.205 | 7.722 | −0.57% | 5 / 5 | 1.838 | 1.912 | +0.72% |
| 2. Switch back to README | 0.347 | 0.341 | 0.354 | 0.358 | +3.87% | 3 / 3 | 0.413 | 0.392 | −0.93% |
| 3. Open Quick Open | 0.223 | 0.219 | 0.221 | 0.219 | −1.26% | 2 / 2 | 0.006 | 0.006 | −5.88% |
| 4. Close Quick Open | 0.584 | 0.584 | 0.615 | 0.594 | +0.05% | 4 / 4 | 0.001 | 0.001 | −11.11% |
| 5. Open Settings | 0.983 | 0.872 | 0.949 | 0.979 | +9.84% | 2 / 2 | 0.009 | 0.009 | +7.50% |
| 6. Close Settings | 0.129 | 0.129 | 0.130 | 0.134 | −3.33% | 1 / 1 | 0.559 | 0.542 | −5.81% |
| 7. Close README | 8.518 | 8.446 | 8.404 | 8.298 | +0.40% | 4 / 4 | 0.431 | 0.498 | +0.76% |
| 8. Close remaining Go document | 0.120 | 0.066 | 0.110 | 0.072 | +6.82% | 1 / 1 | 0.503 | 0.459 | −10.56% |

Absolute per-step differences are at most 0.52 ms (opening the large document,
7.205 → 7.722 ms). The next largest is 0.106 ms on close-README (candidate
faster); every other step differs by less than 0.04 ms. The paired medians are
noisy because a 0.02–0.05 ms step moves by a large percentage on small
denominators; the absolute differences are the honest scale. The large-document
open is the only step with a positive absolute difference above 0.1 ms in this
capture, consistent with the gate paying its exact-comparison cost on a
changed-heavy pass, but it is also the step with the widest pair spread. No step
supports a phase-2 improvement claim.

### Typing burst, ten pairs

| Metric | Baseline p50 (p95) | Candidate p50 (p95) | Paired median |
| --- | ---: | ---: | ---: |
| Cumulative app build | 76.673 (80.81) | **66.681 (70.15)** | **−10.21%** |
| Largest single app build | 9.006 (12.13) | 8.978 (12.39) | +0.90% |
| Typing burst (24 char windows) | 22.347 (23.23) | 21.951 (23.68) | +0.53% |
| Startup (before the open) | 0.301 (0.35) | 0.305 (0.36) | +6.00% |
| Setup (open + settle) | 7.464 (10.32) | 7.585 (10.29) | +1.23% |
| Post-burst tail | 5.210 (7.62) | 5.517 (6.66) | +11.18% |
| First application submission | 11.597 (12.06) | 10.719 (33.04) | −2.17% |
| Process CPU | 1,968.75 (2,093.75) | 2,046.88 (2,296.88) | +2.39% |
| Process wall time | 4,118.997 (4,907.49) | 3,959.79 (5,454.35) | −2.74% |
| Peak working set (MiB) | 345.47 (346.12) | 345.17 (345.85) | 0.00% |
| Primary GPU submissions | 78 (78) | 78 (78) | 0.00% |

The ten paired application-build changes were
`−9.4, −16.8, −59.1, −0.3, −10.4, −7.4, −9.0, −20.7, −10.1, −13.4` — all
negative. The `−59.1` pair contains the 104 ms baseline typing stall; the
`−0.3` pair is the candidate's 33 ms burst stall. Excluding both stalls, the
median is still about −10%, so the direction is not created by the stalls.

The per-character describe windows are flat: median of the per-step medians
0.913 ms baseline versus 0.897 ms candidate (paired median −0.85%), range
0.74–1.06 ms in both arms. The burst total is +0.53%. The cumulative app-build
difference is therefore not in the application describe callback; it is in the
runtime `begin_frame`/`end_frame` work that the host's cumulative metric
includes and the hook's per-step window excludes.

Per-step typing detail is in `typing/combined/step-table.csv`; the 24 steps are
homogeneous, so the table is summarized here rather than reproduced row by row.

### Phase-2 work counters

The diagnostic variants print cumulative `Frame_Stats` deltas per step. The
candidate-only fields (`descriptions_retained_match`,
`structure_sequence_matches`, splice/sparse counters, and stage timings) do not
exist in `68d3aff`; the baseline diagnostic prints the common fields only. The
sequence counters are medians over three release diagnostic pairs per arm; the
typing counters are medians over the ten typing pairs (the typing A/B binaries
carry the env-gated counter print).

#### Sequence, candidate medians (three pairs)

| Step | Emitted | Reused | Exact match | Share | Structure matches | Copy ns | Hash ns | Describe ns | Reconcile ns |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 278 | 211 | 211 | 75.9% | 1 | 59,496 | 80,606 | 1,610,658 | 1,041,132 |
| 1 | 938 | 666 | 664 | 70.8% | 2 | 271,781 | 246,183 | 10,913,743 | 4,164,820 |
| 2 | 342 | 302 | 298 | 87.1% | 2 | 41,937 | 89,399 | 1,339,518 | 971,309 |
| 3 | 244 | 236 | 236 | 96.7% | 1 | 10,719 | 73,900 | 706,485 | 493,423 |
| 4 | 459 | 457 | 457 | 99.6% | 2 | 6,370 | 136,690 | 1,166,093 | 618,871 |
| 5 | 286 | 258 | 258 | 90.2% | 1 | 26,404 | 60,402 | 1,617,205 | 691,521 |
| 6 | 115 | 115 | 115 | 100% | 0 | 0 | 46,290 | 408,322 | 259,330 |
| 7 | 988 | 763 | 763 | 77.2% | 2 | 165,389 | 295,664 | 10,209,130 | 2,219,820 |
| 8 | 56 | 50 | 50 | 89.3% | 0 | 8,610 | 20,549 | 594,109 | 537,520 |

Totals (sum of step medians): 3,706 emitted, 3,052 exact (82.4%), 590,706 ns
remaining copy, 1,049,683 ns hash. The step-7 emitted count varies with the
number of description passes in the window (988 in this capture vs 1,274 in
the previous diagnostic capture, which had one extra pass); per-pass work is
unchanged.

The baseline's common counters (emitted, reused, reconcile/layout/paint nodes,
measure hits/misses, text shapes, node churn) are identical to the candidate's
at every step. The only common-counter differences are the candidate's single
global fallback on step 3 and the step-5 display finalization (94 vs 188
commands, one vs two full passes), both pre-existing #228 behavior also seen in
the previous capture. The phase-2 skip changes the copy path, not how many
nodes are described or reconciled.

#### Typing burst, candidate medians over characters 1–23 (ten pairs)

| Metric | Per character | Notes |
| --- | ---: | --- |
| Emitted | 858 | three description passes of 286 nodes |
| Exact retained matches | 855 | 99.65% |
| Structure-sequence matches | 3 | every pass skips the structure diff |
| Remaining reconcile copy | 6.48 µs | 0.34% of the description pass |
| Reconcile hash/comparison | 302.3 µs | includes the exact gate and changed-node hashing |
| Description stage | 1.884 ms | begin_frame through end_frame |
| Reconcile stage | 0.947 ms | 50.3% of the description stage |

Character 0 is 818/858 (95.3%) because the first pass still includes settling;
the setup window (open plus bounded-source-window wait) is 502/778 (64.5%) and
is dominated by the document load. The steady-state character pass changes only
about three nodes: the edited row and its immediate ancestors. This is the
shape phase 2 was designed for.

#### What the counters imply

- The sequence's copy bucket is sub-millisecond to about 2 ms across all nine
  steps. Even eliminating it entirely cannot produce a reliable 5–10% change in
  a 19–20 ms sequence; the measured segment medians land on both sides of zero.
- The typing burst's copy bucket is likewise small per pass (the candidate keeps
  only 6 µs of copy), but it is paid on every one of 80 application-build
  callbacks while only 3 of 858 nodes change. That is where the cumulative
  ~10 ms reduction comes from. The fixture's same-source phase-2 control
  measured the copy bucket at 0.122 ms → 0.009 ms p95 on the 156-node typing
  fixture; scaled to the real 286-node frame the order of magnitude is
  0.1–0.3 ms per pass, consistent with the measured app-build difference over
  24 character frames plus setup/tail frames.
- The gate's exact comparison/hash is visible: 302 µs per typing character and
  about 1.05 ms across the sequence. On changed-heavy command passes it is a
  cost; on the 99.65%-unchanged typing passes it is outweighed by the skipped
  copy.

### The tail stalls

| Capture | Run | Step | Single build | Window builds | Note |
| --- | --- | ---: | ---: | ---: | --- |
| Sequence primary | candidate run-04 | 4 (close Quick Open) | 76.416 ms | 3 | `application_build_ns` 110.85 ms |
| Sequence confirmation | candidate run-02 | 4 (close Quick Open) | 31.971 ms | 3 | `application_build_ns` 64.50 ms |
| Diagnostic stress loop | candidate c-1 | 0 (open README) | 15.548 ms | 3 | `stage_description_ns` 16.86 ms, `stage_reconcile_ns` 1.30 ms |
| Typing primary | baseline run-03 | character pass | 103.686 ms burst | — | `application_build_ns` 155.81 ms |
| Typing primary | candidate run-04 | character pass | 32.804 ms burst | — | `application_build_ns` 76.43 ms |

All thirteen baseline sequence runs, the other eleven candidate sequence runs,
and all other typing runs were free of stalls above ~13 ms. The diagnostic capture attributes the
caught sequence stall to the application describe portion (`stage_description`
10× normal) while reconcile stayed at 1.3 ms, and the typing stalls occur in
both arms. The honest reading is a host/application tail event — scheduler,
memory, driver, or antivirus — that is not caused by the phase-2 reconcile
path, but the sample is small enough that a phase-2 contribution cannot be
excluded for the two sequence stalls. The medians are unaffected; the combined
p95 is inflated and is reported as such.

## Three-way comparison

The previous capture measured `68d3aff` versus `576f1fd` (no phase 2). This
capture measures the same baseline fresh versus `78695d1` (phase 2). The
previous candidate numbers are session medians and are not paired with the
fresh baseline; use them as context, not as a direct paired comparison.

| Metric, nine-action sequence | 68d3aff (prev, 10 pairs) | 576f1fd (prev, 10 pairs) | 68d3aff (fresh, 13 pairs) | 78695d1 (fresh, 13 pairs) | Fresh paired |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cumulative app build p50 | 34.223 | 33.509 | 33.239 | 33.652 | +3.28% |
| Largest single app build p50 | 8.35 | 8.94 | 8.793 | 9.118 | +7.51% |
| Sequence build p50 | 19.395 | 19.317 | 19.223 | 20.429 | +8.31% |
| First application submission p50 | 18.91 | 18.86 | 10.952 | 11.223 | −0.68% |
| Process CPU p50 | 781.25 | 750.00 | 796.875 | 765.625 | −5.45% |
| Peak working set p50 (MiB) | 312.54 | 313.02 | 325.96 | 325.79 | −0.07% |
| Primary GPU submissions p50 | 17 | 17 | 17 | 17 | 0.00% |

The absolute p50 levels for application build and sequence build are stable
across sessions (baseline 33.2–34.2 ms and 19.2–19.4 ms). The fresh baseline
sits at the low end of that band, which is why the fresh paired candidate
change is positive even though the previous candidate sat slightly below the
previous baseline. First submission and peak working set are not comparable
across sessions (a ~7 ms startup shift and ~13 MiB working-set shift between
captures); only their paired changes are meaningful.

| Typing burst (new scenario) | Baseline | Phase-2 candidate | Paired |
| --- | ---: | ---: | ---: |
| Cumulative app build p50 | 76.673 | 66.681 | −10.21% |
| Typing burst describe windows p50 | 22.347 | 21.951 | +0.53% |
| Setup + startup + tail p50 | 12.975 | 13.407 | +3.58% |
| Exact retained matches | not instrumented | 855/858 per char | — |

## Interpretation

### #229 phase 2 — active and useful in text editing, not in command switching

The phase-2 gate is not a no-op on real Scratchpad. It short-circuits 82% of
described nodes across the command sequence and 99.65% per typing character.
The reason the command sequence does not improve is not that the path is
dormant; it is that the copy bucket it removes is small relative to reconcile,
layout, text shaping, and application work in those steps. The sequence's
candidate copy total is 0.59 ms over nine steps, and the gate's own comparison
sits at about 1.05 ms. On the large-document open and close steps the changed
fraction is high enough that the gate mostly rejects and pays the comparison
prefix, which is consistent with the small positive step-1 difference.

The typing burst changes the ratio: 855 of 858 nodes are unchanged on every
character, so the gate removes nearly all copy and structure work while paying
the comparison on a frame that is dominated by the edited row's measure and
shape work. The host's cumulative application build falls ~10 ms over the
burst, consistently across ten pairs. This is the application-visible result
the previous capture did not have.

### Relation to the previous #227/#228/#230 result

Nothing in this capture changes the previous negative result for #227, #228,
and #230 on the command sequence. `regions_skipped` is still 0 at every step;
the sparse layout counters are still 0; the splice counters remain at most one
per process. The candidate adds phase 2 on top of that runtime; the command
sequence still does not exercise a large enough copy bucket to move.

### Relation to the #229 frame budget

The typing burst's per-character application describe window is ~0.9 ms, and
the whole description stage is ~1.9 ms. Phase 2 removes ~0.12–0.14 ms per
286-node pass from the runtime portion (the 10 ms app-build difference over 80
callbacks is ~0.125 ms per callback, and the 24 character frames account for
most of it). That is a meaningful share of the runtime work, but the
application's build and the GPU submission remain the larger terms. The largest single build is still
~9 ms in both arms, above an 8.33 ms 120 Hz frame; phase 2 does not change
that.

## Limitations

- The hook invokes application/backend command paths and committed text-input
  events on a schedule. It is not native keyboard or pointer input, so it does
  not measure input latency or input-to-display delivery. The typing burst uses
  the application's text-input path but a fixed caret position and a single
  document.
- Timings are CPU wall time, not GPU execution or scanout.
- One Windows host (Ryzen 5 7600X, RTX 2080 SUPER), one Odin build, display
  scale 1.0. Do not compare these numbers across machines.
- The measured path is the SDL_GPU reference host; the hosted WebGPU renderer
  was not benchmarked.
- The generated workspace is a fixture: eight directories, 192 small files,
  one 5,002-line file. It does not model Scratchpad's full document set, worker
  activity, session restoration, or every after-frame callback.
- The per-step `build_ns` is the application describe callback only, not the
  whole runtime description stage. Runtime changes such as phase 2 show in the
  host's cumulative `application_build_ns`, which includes `end_frame`; the
  per-step table is not the place to look for them. This distinction was
  implicit in the previous report and is made explicit here.
- The baseline revision has no phase-2 counters (by definition) and no phase-1
  stage timers, so the copy/hash split of the typing saving is measured on the
  candidate side and scaled from the fixture's same-source control, not paired
  per stage against the baseline.
- The first command step waits 500 ms and later steps advance on the previous
  description; the typing burst uses the same cadence. Absolute process wall
  time is therefore not comparable to the 2026-11-04 report.
- The sequence capture spans three sessions (primary, confirmation,
  supplementary), and the sign differs between segments. Segment medians are
  reported separately; the 13-pair median should not be read as a stable
  effect.
- Intermittent 30–100 ms single-build stalls occurred in both arms across the
  two scenarios. They are not attributable to phase 2 from this sample, but
  they inflate the candidate sequence p95 and one typing baseline p95.
- The typing setup window sometimes collapses into character 0 (two of ten
  candidate runs in an earlier pass); `steps.csv` records the per-step counts,
  and the burst total is the robust metric.

## Reproduction artifacts

- [Capture manifest and SHA-256 hashes](raw/scratchpad-ab-phase2-windows-2026-11-21/manifest.json)
- [Nine-action runner (reused byte-for-byte)](raw/scratchpad-ab-phase2-windows-2026-11-21/run_windows_ab.ps1)
- [Typing-burst runner](raw/scratchpad-ab-phase2-windows-2026-11-21/run_windows_typing.ps1)
- [Nine-action hook patch (reused byte-for-byte)](raw/scratchpad-ab-phase2-windows-2026-11-21/scratchpad-perf-sequence-hook.patch)
- [Typing hook patch, candidate variant](raw/scratchpad-ab-phase2-windows-2026-11-21/scratchpad-perf-typing-hook.patch)
- [Typing hook patch, baseline-compatible variant](raw/scratchpad-ab-phase2-windows-2026-11-21/scratchpad-perf-typing-hook-common.patch)
- [Sequence diagnostic counter patch, common fields](raw/scratchpad-ab-phase2-windows-2026-11-21/scratchpad-perf-sequence-counters.patch)
- [Sequence diagnostic counter patch, candidate fields](raw/scratchpad-ab-phase2-windows-2026-11-21/scratchpad-perf-sequence-counters-candidate.patch)
- [Combination script](raw/scratchpad-ab-phase2-windows-2026-11-21/analyze.py) and [counter extraction script](raw/scratchpad-ab-phase2-windows-2026-11-21/extract_counters.py)
- [Sequence primary, confirmation, supplementary, and combined CSVs](raw/scratchpad-ab-phase2-windows-2026-11-21/sequence/)
- [Sequence per-step phase-2 counters](raw/scratchpad-ab-phase2-windows-2026-11-21/diagnostics/counters/)
- [Typing primary, confirmation, and combined CSVs](raw/scratchpad-ab-phase2-windows-2026-11-21/typing/)
- [Typing per-character phase-2 counters](raw/scratchpad-ab-phase2-windows-2026-11-21/typing/counters/)
- [All build logs](raw/scratchpad-ab-phase2-windows-2026-11-21/build-logs/)
