# Matched Scratchpad A/B - keyed-region pilot, Windows, 2026-11-21

Date: 2026-11-21

## Finding

This capture measures issue #231 sequencing item 2: four keyed Alicorn regions
in a disposable Scratchpad clone, against the same Scratchpad source without
them and the same Alicorn master (`b1e7619`). Both arms carry the same
environment-gated benchmark hooks. The only source difference is the pilot
patch (7 files, 560 added / 31 removed lines).

1. **The typing burst shows the mechanism working.** Ten matched pairs of a
   24-character insert burst on the 5,002-line fixture document give a paired
   median **-6.24%** in cumulative application build (59.821 -> 56.920 ms),
   with eight of ten pairs negative. Per-character counters show **741 instead
   of 858 emitted nodes (-13.6%)**, **6 region bodies skipped per character**,
   and the whole runtime description stage at **1.546 vs 1.664 ms (-7.1%)**.
   The application describe callback alone (`typing_build_ns`) is flat
   (-0.66%) because it is dominated by non-region editor work and one noisy
   candidate pair.

2. **The nine-action command sequence still shows no benefit.** Ten matched
   pairs give **-0.73%** cumulative application build (30.397 -> 30.366 ms) and
   **+2.66%** sequence-attributed build (17.543 -> 18.427 ms). The close-README
   step is **+11.7%** because the pilot runs six description passes instead of
   five: the tab-strip revision must include the retained tab-bar viewport, so
   the first description after a layout change re-runs the strip. This is the
   measurable cost of a correctness fix, not noise.

3. **The node reduction is real but does not map 1:1 to the app callback.**
   In the typing burst the pilot removes 117 of 858 described nodes per
   character, but those nodes are cheap relative to the editor's row
   description and text shaping. The saving appears in the runtime description
   stage and cumulative host build, not in the application callback.

4. **The authoring burden is the main result.** Four regions require 560 added
   lines, five new app fields, a 67-line revision helper, and two tests. The
   pilot hit three non-obvious input classes: application-polled widget
   results, retained geometry from the previous frame, and virtualized scroll
   windows. The burden table and the full rule list are in the
   [research record](../research/description-locality-re-describable-subtrees.md).

Short answer: **regions are application-visible in a typing workload
(-6% cumulative app build, -7% runtime description) and inert-to-negative in
the command workload.** The pilot supports opt-in use on static projections,
not a broad conversion of Scratchpad's invalidation sites.

## Revisions and environment

| Item | Value |
| --- | --- |
| Alicorn | `b1e76191d4d5b19b1bb88744f80d80768e3f5f53` - master tip used for both arms |
| Scratchpad | `adb28fc220864e6809c9217e4437af5b92dae57b` - identical clone for both arms |
| Plain arm | clone without the pilot patch; same benchmark hooks |
| Pilot arm | clone with the four keyed regions; same benchmark hooks |
| Caliber | `197cd964cc7265bc60df599a6b8562eac7c75f3a` |
| Host | Windows 10 Home 22H2, build 19045; Ryzen 5 7600X, 12 logical processors; 15 GiB RAM |
| GPU | NVIDIA GeForce RTX 2080 SUPER, driver 32.0.15.9597 |
| Native backend | SDL_GPU reference host / Direct3D 12 |
| Toolchain | Odin `dev-2026-11-nightly:08539cd`; Go `go1.27.1` |
| Build profile | Release, Odin `-o:speed`; `--release` passed explicitly |
| Display | Scale 1.0; logical size equals pixel size in this capture |
| Theme | Scratchpad default Warm theme; no appearance fixture or saved preference |

### What the pilot contains

| Site | Region key | Revision source |
| --- | --- | --- |
| Document tab strip (compact titlebar) | `scratchpad-doc-tabs` | monotonic generation over prepared tab items + drag/find/theme/search/accessibility state + retained tab-bar viewport |
| Sidebar workspace tree | `scratchpad-workspace-tree` | monotonic generation over the projection revision, realized scroll window, aliKit focus/selection revision, session restore, theme/accessibility |
| Pinned references | `scratchpad-pinned` | monotonic generation over snapshot/pages/index/edit/selection/scroll/theme inputs; frame counter while editing |
| Quick Open result slot | `scratchpad-quick-open-results` | monotonic generation over query, index generation, path count, loading/error, selection, scroll window, theme/accessibility |

`quick_open_text_change` and `quick_open_move_selection` were converted from
`invalidate_root` to `invalidate_region` with the freshly advanced generation.
No other invalidation site was converted.

## Workload and method

### Nine-action command sequence

The generated workspace is the same fixture used by the 2026-11-21 captures:
eight directories, 192 small files, a README, and a 5,002-line
`application/sample_00.go` (193 files). Each fresh process runs:

1. Open `README.md`.
2. Open `application/sample_00.go`.
3. Switch back to `README.md`.
4. Open Quick Open.
5. Wait until Quick Open's index is ready, then close it.
6. Open Settings.
7. Close Settings.
8. Close `README.md`.
9. Close the remaining Go document.

The hook invokes the same application/backend command paths a user action
reaches; it does not synthesize native keyboard or pointer input. The first
step starts 500 ms after application start; later steps advance after the
previous step's description, with a 30 ms floor.

Protocol: one unmeasured warmup per arm in the primary capture, seven measured
fresh-process pairs with order alternating each round, then three fresh
confirmation pairs. All 20 measured processes plus two warmups passed smoke
and nine-step acceptance.

### Bounded typing burst

A separate env-gated scenario opens `application/sample_00.go`, waits for the
bounded source window and editor scroll owner, then delivers 24 committed
single-character text-input events through `editor_text_input`. Each character
advances only after the previous character's description was built, with the
same 30 ms floor. Setup and post-burst tail are attributed separately.

Protocol: one unmeasured warmup, seven primary pairs, three confirmation
pairs (10 matched fresh processes).

### Metrics

- **First application submission:** startup-to-submit, not input latency.
- **Cumulative app build:** host sum of application build callbacks, including
  `begin_frame`, the application describe callback, `end_frame`, and
  after-frame work.
- **Per-step build (`build_ns`):** time inside the application's
  `scratchpad_build_describe` only. It excludes `end_frame`.
- **Typing build:** the sum of the 24 per-character application describe
  windows.
- **Runtime description stage (`stage_description_ns`):** counters-only,
  begin_frame through end_frame. This is the window where the runtime
  reconcile over the smaller description appears.
- **Paired change:** median of per-pair percentage changes, pilot relative to
  plain. Positive means slower.
- **Percentiles:** nearest-rank p50/p95 over measured processes or paired
  changes.

Both arms run the SDL_GPU reference host; no renderer override was set.

## Results

Times are milliseconds. `B` is plain, `C` is pilot.

### Cumulative process metrics, ten pairs

| Metric | Primary 7 B -> C | Confirmation 3 B -> C | Combined B p50 (p95) -> C p50 (p95) | Combined paired |
| --- | ---: | ---: | ---: | ---: |
| First application submission | 16.93 -> 17.53 | 20.22 -> 17.11 | 17.633 (26.81) -> 17.655 (39.06) | +2.78% |
| Cumulative app build | 30.31 -> 30.35 | 29.12 -> 30.60 | 30.397 (31.75) -> 30.366 (33.27) | **-0.73%** |
| Largest single app build | 8.05 -> 7.72 | 7.88 -> 7.60 | 7.919 (9.37) -> 7.604 (9.32) | -1.17% |
| Sequence build | 17.55 -> 18.43 | 17.54 -> 18.43 | 17.543 (19.63) -> 18.427 (20.49) | **+2.66%** |
| Process CPU | 765.63 -> 781.25 | 734.38 -> 781.25 | 734.38 (781.25) -> 781.25 (906.25) | +9.57% |
| Process wall time | 4,540 -> 4,558 | 4,511 -> 4,365 | 4,531.65 (5,189.19) -> 4,371.72 (5,195.80) | -3.31% |
| Native application-loop wall | 3,225 -> 3,214 | 3,162 -> 3,190 | 3,202.85 (3,477.63) -> 3,203.72 (3,538.84) | +0.77% |
| Peak working set (MiB) | 310.70 -> 310.24 | 310.79 -> 310.72 | 310.70 (312.62) -> 310.39 (311.71) | -0.34% |
| Primary GPU submissions | 19 (20) -> 20 (20) | 19 -> 20 | 19 (20) -> 20 (20) | 0.00% |

The ten paired application-build changes were
`+0.3, +4.8, -1.8, -16.4, +20.7, -12.6, -2.3, +5.1, -6.6, +15.5`; the
sequence-build changes were
`-0.8, +2.7, +5.4, -18.2, +25.0, -15.2, +2.6, +5.0, -5.4, +18.5`. The
positive outliers are close-Quick-Open and close-README steps, where the
pilot's extra settle pass lands. The sign is not stable; this capture does not
establish a sequence improvement.

### Sequence steps, ten pairs

| Step | Build B | Build C | Paired build | Builds B/C | Action B | Action C | Paired action |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0. Open README | 0.509 | 0.524 | +3.9% | 3 / 3 | 2.029 | 2.141 | +5.9% |
| 1. Open 5,002-line Go document | 6.736 | 6.646 | +1.8% | 5 / 5 | 2.447 | 2.609 | +3.1% |
| 2. Switch back to README | 0.284 | 0.286 | -0.3% | 3 / 3 | 1.425 | 1.007 | -18.5% |
| 3. Open Quick Open | 0.231 | 0.195 | -29.3% | 2 / 2 | 0.006 | 0.010 | +78.3% |
| 4. Close Quick Open | 0.516 | 0.507 | -7.4% | 4 / 4 | 0.001 | 0.001 | +7.1% |
| 5. Open Settings | 0.944 | 0.887 | +1.9% | 2 / 2 | 0.009 | 0.007 | -16.7% |
| 6. Close Settings | 0.105 | 0.081 | -29.3% | 1 / 1 | 0.548 | 0.523 | -3.9% |
| 7. Close README | 7.954 | 8.822 | **+11.7%** | 5 / **6** | 0.935 | 1.016 | +9.7% |
| 8. Close remaining Go document | 0.116 | 0.134 | +6.9% | 1 / 1 | 9.547 | 10.068 | +1.1% |

Step 7 is the only step with a large absolute difference (0.87 ms) and it has
one extra description pass in the pilot. Every other step differs by less
than 0.11 ms; the percentage medians on 0.1-1 ms denominators are noisy.

### Typing burst, ten pairs

| Metric | Plain p50 (p95) | Pilot p50 (p95) | Paired median |
| --- | ---: | ---: | ---: |
| Cumulative app build | 59.821 (61.31) | **56.920 (58.81)** | **-6.24%** |
| Largest single app build | 8.058 (8.93) | 8.147 (9.47) | -2.14% |
| Typing burst (24 describe windows) | 19.296 (20.67) | 19.638 (25.58) | -0.66% |
| Setup (open + settle) | 6.891 (7.75) | 6.706 (7.31) | -2.74% |
| Post-burst tail | 4.975 (5.61) | 5.003 (5.63) | +0.87% |
| First application submission | 17.659 (17.95) | 17.419 (17.80) | -1.04% |
| Process CPU | 2,000.00 (2,156.25) | 1,937.50 (1,984.38) | -3.20% |
| Process wall time | 4,298.32 (5,331.72) | 4,213.22 (4,694.92) | -1.81% |
| Peak working set (MiB) | 323.69 (324.02) | 323.55 (323.76) | -0.02% |
| Primary GPU submissions | 78 (79) | 78 (79) | 0.00% |

The ten paired app-build changes were
`+15.8, -8.3, -3.8, -7.2, -3.9, -8.3, -7.2, -0.7, -9.3, -5.3`. Eight are
negative; the `+15.8` pair contains a candidate 29.5 ms first-character stall.
The typing-window change series is noisier (`+67.4` from a candidate
first-character outlier, then mostly negative); the counters below are the
robust per-character evidence.

### Work counters

Typing counters are medians over characters 1-23 and seven primary processes;
sequence counters are medians/sums over three release diagnostic pairs per
arm.

#### Typing burst, per character

| Counter | Plain | Pilot |
| --- | ---: | ---: |
| Emitted | 858 | **741 (-13.6%)** |
| Reused | 855 | 738 |
| `regions_skipped` | 0 | **6** |
| Retained exact matches (phase 2) | 855 | 738 |
| Structure-sequence matches | 3 | 3 |
| Runtime description stage | 1.664 ms | **1.546 ms (-7.1%)** |
| Reconcile stage | 0.867 ms | 0.748 ms (-13.7%) |
| Reconcile hash | 0.212 ms | 0.199 ms |
| Remaining reconcile copy | 6.5 us | 6.8 us |
| Layout visits | 94 | 94 |
| Composition visits | 142 | 144 |

The two extra composition visits are the two region containers per pass (the
pinned and Quick Open regions are absent during the burst). The six skips per
character are the tab strip and tree, three description passes each.

#### Sequence, nine steps

| Step | Emitted plain | Emitted pilot | `regions_skipped` pilot | Builds plain/pilot |
| --- | ---: | ---: | ---: | ---: |
| 0 | 278 | 213 | 3 | 3 / 3 |
| 1 | 938 | 790 | 6 | 5 / 5 |
| 2 | 342 | 250 | 4 | 3 / 3 |
| 3 | 244 | 199 | 2 | 2 / 2 |
| 4 | 230 | 320 | 6 | 2 / 4 |
| 5 | 286 | 241 | 2 | 2 / 2 |
| 6 | 115 | 68 | 2 | 1 / 1 |
| 7 | 1,274 | 1,378 | 9 | 5 / 6 |
| 8 | 56 | 57 | 0 | 1 / 1 |

`regions_skipped` totals 36 in the pilot and 0 in plain. Emitted totals
(3,763 plain, 3,516 pilot) are confounded by extra passes in steps 4 and 7;
in the three diagnostic pairs the pilot runs four passes in step 4 (plain
two) and six in step 7 (plain five). The step-4 difference is the large one:
closing Quick Open removes a region and settles the tab strip, and the small
diagnostic sample makes the pass count unstable. In the ten-pair A/B capture
both arms report four passes at step 4 and five/six at step 7, so the timing
table above is the better estimate of the cost.
over the nine steps: description 30.148 -> 28.180 ms (-6.5%), reconcile
11.172 -> 10.353 ms (-7.3%), layout 4.218 -> 4.060 ms, composition
0.284 -> 0.313 ms. The extra passes and region containers explain why the
A/B sequence medians do not improve despite the lower stage totals.

### Authoring burden

| Item | Value |
| --- | --- |
| Files touched | 7 (5 existing, 2 new) |
| Lines added / removed | **560 / 31** |
| New app state | 4 `Region_Generation` fields + 1 hoisted `Node_ID` cache |
| Revision helper | 67 lines |
| Tests | 2 new tests, 99 lines; Scratchpad frontend suite 259/259 green |
| Converted invalidations | 2 (`quick_open_text_change`, `quick_open_move_selection`) |
| Remaining `invalidate_root` sites | ~350, deliberately untouched |

Per-site cost: tab strip 135 lines, tree 68, pinned 91, Quick Open 89. The
full revision rules, side-effect inventory, and trap list are in the
[research record](../research/description-locality-re-describable-subtrees.md#authoring-burden).

## Interpretation

### Why typing improves and commands do not

The typing burst changes only the editor's caret/row state. The tab strip,
sidebar tree, and their subtrees are unchanged, so their bodies are skipped on
every one of the 72 description passes (three per character). That removes 117
of 858 node descriptions per character and 13.7% of the runtime reconcile
stage. The editor's own row description and text shaping remain, so the
application callback (which excludes `end_frame`) is flat; the whole runtime
description stage and cumulative app build fall.

The command sequence changes documents, the active view, and layout. The tab
strip and tree are themselves rebuilt repeatedly, and document open/close
describes the editor, document surface, and status/control chrome, which stay
outside the pilot regions. The pilot's layout-settle guard adds a description
pass on the close-README step, so the net effect is slightly negative.

### Relation to #229 phase 2

Phase 2 skipped the runtime reconcile copy for byte-identical re-emits
(~-10% cumulative app build on the same burst, flat application callback).
The pilot removes application emit work before phase 2 sees it. In the typing
burst, the pilot's 741 emitted nodes are 738 exact matches, so phase 2 still
skips almost all of the smaller description. The two compose; neither alone
moves the application callback much because it is dominated by non-reusable
editor work.

### Relation to #230 sparse layout and #228 finalization

The pilot's layout visits are unchanged (94 per character) and full display
passes remain 1. The sparse column and splice paths are still not exercised
by this workload. The pilot is orthogonal to those mechanisms.

## Limitations

- The hook invokes application/backend command paths and committed text-input
  events on a schedule. It is not native keyboard or pointer input and does
  not measure input latency or input-to-display delivery.
- Timings are CPU wall time, not GPU execution or scanout.
- One Windows host (Ryzen 5 7600X, RTX 2080 SUPER), one Odin build, display
  scale 1.0. Do not compare these numbers across machines.
- The measured path is the SDL_GPU reference host; the hosted WebGPU renderer
  was not benchmarked.
- The generated workspace is a fixture and does not model Scratchpad's full
  document set, worker activity, session restoration, or every after-frame
  callback.
- **Quick Open filter typing is not measured.** The reused hooks have no
  Quick Open query-typing step, so the result-slot region is exercised only by
  the open/close steps. A bounded filter burst is the next measurement.
- **The pinned region is not exercised by either measured scenario.** Pinned
  is closed during the sequence and the typing burst. Its region is included
  for completeness and is the pilot's most fragile site because of its
  variable-height virtual list, lazy page loads, and inline editor.
- An earlier pre-fix capture was discarded. It was built before the tab-bar
  layout-settle input was added to the signature; connected-titlebar tests
  showed tab widths stuck at provisional values. Its counters showed the same
  node reduction but the binaries were not correct.
- The diagnostic sequence capture has only three pairs per arm and is used for
  counters, not for a timing claim.
- Pair spread exceeded 25% in the sequence capture; the three confirmation
  pairs are retained and the combined ten-pair medians are reported. The
  sign of the command-sequence effect is not stable.
- Intermittent single-build stalls occurred in both arms (for example a
  candidate 29.5 ms first typing character and a plain 8.6 s diagnostic
  process). They are reported in the raw samples and inflate p95.
- Region revisions are application-declared. The pilot cannot prove input
  completeness mechanically; the two new tests and Alicorn's #106 coherence
  oracle cover the known failure modes, not every future edit.

## Reproduction artifacts

- [Capture manifest and SHA-256 pins](raw/scratchpad-region-pilot-windows-2026-11-21/manifest.json)
- [Nine-action runner (reused byte-for-byte)](raw/scratchpad-region-pilot-windows-2026-11-21/run_windows_ab.ps1)
- [Typing-burst runner (reused byte-for-byte)](raw/scratchpad-region-pilot-windows-2026-11-21/run_windows_typing.ps1)
- [Combination script](raw/scratchpad-region-pilot-windows-2026-11-21/analyze.py) and [counter extraction script](raw/scratchpad-region-pilot-windows-2026-11-21/extract_counters.py)
- [Pilot patch (the measured source diff)](raw/scratchpad-region-pilot-windows-2026-11-21/pilot-region-diff.patch)
- [Sequence primary, confirmation, and combined CSVs](raw/scratchpad-region-pilot-windows-2026-11-21/sequence/)
- [Typing primary, confirmation, and combined CSVs](raw/scratchpad-region-pilot-windows-2026-11-21/typing/)
- [Sequence diagnostic counters](raw/scratchpad-region-pilot-windows-2026-11-21/diagnostics/counters/)
- [Typing per-character counters](raw/scratchpad-region-pilot-windows-2026-11-21/typing/counters/)
- [Build and test logs](raw/scratchpad-region-pilot-windows-2026-11-21/logs/)
- [Research record](../research/description-locality-re-describable-subtrees.md)
