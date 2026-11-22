# v0.3.0 measured performance ledger — Windows, 2026-11-21

This page consolidates the performance work in the v0.3.0 line into one stage
ledger. It is a reading aid over the dated reports and raw captures, not a new
experiment: every number below was measured on one Windows host, is linked to
its report, and keeps the report's limitations. No two rows were measured on
different machines and combined.

The questions it answers are narrow:

- which stage changed, by how much, and on which workload;
- whether the change is visible in a real application (Scratchpad) or only in
  the synthetic fixture;
- which classes of update still pay the old cost, and which issue owns them.

Alicorn remains experimental. These are workload-specific CPU observations, not
cross-machine or cross-platform promises.

## Status at a glance

| Issue | State | Landed in this line | What remains |
| --- | --- | --- | --- |
| [#219](https://github.com/Carnival-Science/Alicorn/issues/219) paint-only theme text | Closed | Theme replacement recomputes description-resolved text ink; regression test | Nothing for this issue |
| [#227](https://github.com/Carnival-Science/Alicorn/issues/227) indexed region lookup | Closed | Maintained key-to-live-region index; consistency test | Nothing for this issue |
| [#228](https://github.com/Carnival-Science/Alicorn/issues/228) sparse display finalization | **Open** | Milestone 1 same-count range splices; milestone 2 count-changing splices with a bounded tail | Full passes for structure/order, overlays, motion, backdrop, scroll regions, clipping/ancestor presentation changes, scale changes, and broad repaints |
| [#229](https://github.com/Carnival-Science/Alicorn/issues/229) 120 Hz interaction frame budget | **Open** | Phase 1 stage attribution and fixture; phase 2 exact-description reuse | The real-frame budget still depends on application build; changed-heavy passes pay the comparison prefix |
| [#230](https://github.com/Carnival-Science/Alicorn/issues/230) sparse layout propagation | **Open** | Milestone 1 single-child `Column` suffix placement and measure skips | Milestone 2 allocator-side sparsity (`resolve_main_sizes` still builds per-child arrays); other container classes |
| [#231](https://github.com/Carnival-Science/Alicorn/issues/231) description locality | **Open (research)** | Scratchpad pilot and adopted tab-strip/tree regions; GO/NO-GO record | No general authoring helper; no broad conversion; Quick Open results slot is NO-GO |
| [#190](https://github.com/Carnival-Science/Alicorn/issues/190) sparse-update benchmark | Closed | Source-visible fixture, runner, raw capture | Nothing for this issue |
| [#106](https://github.com/Carnival-Science/Alicorn/issues/106) invalidation oracle | Closed | Seeded incremental-vs-fresh oracle; #193 corpus extensions | Nothing for this issue |
| [#120](https://github.com/Carnival-Science/Alicorn/issues/120) connected-tab visual audit | Closed | Options A and C accepted; no general shoulder primitive | Nothing for this issue |
| [#111](https://github.com/Carnival-Science/Alicorn/issues/111) retained effects | Closed, out of milestone | Existing evidence unchanged | Not re-validated here |

## Environment

All captures in this ledger share the host and profile below unless the linked
report says otherwise.

| Pin | Value |
| --- | --- |
| OS | Windows 10 Home 22H2, build 19045 |
| CPU | AMD Ryzen 5 7600X, 12 logical processors |
| GPU | NVIDIA GeForce RTX 2080 SUPER, driver 32.0.15.9597 |
| Native backend | SDL_GPU reference host, Direct3D 12 |
| Toolchain | Odin `dev-2026-11-nightly:08539cd`; Go `go1.27.1` |
| Build | Release, `-o:speed`, `--release` passed by the Scratchpad driver |
| Display | Scale 1.0; logical size equals pixel size |
| Theme | Scratchpad default Warm theme; fixture uses explicit text colors |

CI pins the official Odin `dev-2026-11` release, not this nightly. The local
nightly is the compiler the captures were taken with; see
[the validation record](../validation/release-v0.3.0-validation.md) for the
harness difference.

## Stage ledger

Stage columns are deterministic work counters unless marked wall time. Wall
values are p50/p95 milliseconds on this host and are not comparable across
machines.

### Invalidation lookup (#227)

`api_p50_ns` is the fixture's timed invalidation block; it excludes description,
reconciliation, and frame work.

| Workload (3,000 rows) | Before | After | Improvement | Evidence |
| --- | ---: | ---: | ---: | --- |
| One label change, region mode | 595.2 µs | 3.4 µs | 175x | [#190 addendum](../benchmarks/issue190-sparse-updates-windows-2026-11-21.md#addendum-indexed-region-lookup-issue-227), [raw before](raw/issue-227-region-index-before-windows-2026-11-21.txt) / [raw after](raw/issue-227-region-index-after-windows-2026-11-21.txt) |
| One label change, app mode (label + shell) | 1,471.6 µs | 5.2 µs | 283x | same |
| Two-row selection, region mode | 968.9 µs | 5.6 µs | 173x | same |
| Two-row selection, app mode (four keys) | 2,782.4 µs | 7.9 µs | 352x | same |
| Reorder + insert + remove, region mode | 1,009.5 µs | 13.8 µs | 73x | same |
| Reorder + insert + remove, app mode | 1,484.5 µs | 13.6 µs | 109x | same |
| Index memory, 3,000 region keys | — | +576,640 B | ~192 B/key, 0.36% of tracked bytes | same |
| Index memory, 9,000 app keys | — | +2,128,984 B | ~237 B/key, 1.33% | same |

**Read it as:** the lookup floor is gone; the update is not. At 3,000 rows the
one-label total was 5.535 → 5.670 ms in region mode and 6.191 → 5.719 ms in app
mode — single-run totals that include the unchanged O(all live) description and
reconcile header walk. The app mode no longer pays a scan premium for its finer
bodies (two-row selection 12.650 → 10.072 ms app mode).

**Limits and open status.** Scratchpad declares no regions, so the real
application reports `regions_skipped = 0` at every step and cannot show this win
([A/B capture](../benchmarks/scratchpad-ab-windows-2026-11-21.md#227-indexed-region-invalidation--no-application-effect)).
The index costs two allocations and one owned key copy per distinct live key and
is released when the last instance retires. #227 is closed; no follow-up is
owned by it.

### Measurement

| Observation | Result | Evidence |
| --- | ---: | --- |
| Typing fixture, measure stage p95 | 0.048 ms of a 0.477 ms pass (SDL_GPU) | [phase 1 baseline](../validation/issue-229-phase1-baseline-2026-11-21.md#typing), [raw summary](../validation/raw/issue-229-scratchpad-baseline-2026-11-21/fixture-stage-summary.csv) |
| Typing, text shaping inside measure+layout | 0.044 ms p95 | same |
| #229 phase 2 change to measure | none (0.047 → 0.042 ms p95, within noise) | [phase 2 record](../validation/issue-229-phase2-description-reuse-2026-11-21.md#typing-stage-attribution-p95-before---after-ms) |
| Sparse column m1 measure skip | rigid fixed-size children skipped; text and `FIT_CONTENT` children still measure | [#190 #230 addendum](../benchmarks/issue190-sparse-updates-windows-2026-11-21.md#addendum-sparse-layout-propagation-milestone-1-issue-230) |
| Instrumentation overhead (phase 1) | +0.0294 ms on typing p95 (+6.6% of the fixture pass; ~0.35% of a 120 Hz frame) | [phase 1 overhead](../validation/issue-229-phase1-baseline-2026-11-21.md#instrumentation-cost), [paired CSV](../validation/raw/issue-229-scratchpad-baseline-2026-11-21/instrumentation-overhead-paired-ab.csv) |

**Read it as:** measurement was never the bottleneck; it is cheap and its
instrumentation is bounded. Phase 2 deliberately leaves measure alone.

**Limits and open status.** Measure still runs for every dirty text/intrinsic
child and for typography/theme-metric changes that dirty broad sets. The
per-child allocation arrays inside `resolve_main_sizes` are #230 milestone 2,
not this stage.

### Layout (#230 milestone 1)

| Workload | Before | After | Evidence |
| --- | ---: | ---: | --- |
| #190 one-row width, 100 rows | 213 visits | 11 | [#190 #230 addendum](../benchmarks/issue190-sparse-updates-windows-2026-11-21.md#issue-190-one-row-width-change), [raw before](raw/issue-230-sparse-layout-m1-before-windows-2026-11-21.txt) / [raw after](raw/issue-230-sparse-layout-m1-after-windows-2026-11-21.txt) |
| #190 one-row width, 1,000 rows | 2,013 visits | 11 | same |
| #190 one-row width, 3,000 rows | 6,013 visits | 11 | same |
| Layout stage, 3,000 rows, middle-row height | 4.19 ms full | 2.42 ms sparse | same (`SPARSE_M1_BENCH`) |
| Layout stage, 3,000 rows, one-row width | 3.28 ms full | 2.45 ms sparse | same |
| 100,000-row virtual leg | 257 visits for 21 realized rows | unchanged | same |

**Read it as:** visits became proportional to the changed suffix in the modeled
class, and the layout stage dropped roughly a third to a half. The frame p50 did
not move because description, reconciliation, and measurement dominate.

**Limits and open status.** Eligible only for a non-scrolling `Root`/`Container`
Column with `.Start` justify, unchanged parent geometry/gap/padding/alignment,
an identical child identity list, and no `grow`, `compress_weight`, or
positioned child. Root viewport resizes, grid/split/adaptive, scroll and virtual
parents, typography-wide changes, and free-space distribution keep the reference
path, which is also the randomized oracle. On Scratchpad all
`layout_sparse_passes`/`layout_suffix_skips`/`layout_unchanged_skips` counters
were zero at every step, so this is a fixture-only result for that workload
([A/B capture](../benchmarks/scratchpad-ab-windows-2026-11-21.md#230-sparse-column-layout--not-exercised)).
#230 stays open for allocator-side sparsity and other container classes.

### Paint

| Observation | Result | Evidence |
| --- | ---: | --- |
| Hover move paint visits, 1,000/3,000 rows | 2 (already localized) | [#190 stage counts](../benchmarks/issue190-sparse-updates-windows-2026-11-21.md#deterministic-stage-counts-at-1000-rows) |
| Two-row selection paint visits | 4-8 | same |
| Broad theme change paint visits, 1,000 rows | 6,003 | same |
| Typing paint stage p95 | 0.007 ms | [phase 1 typing](../validation/issue-229-phase1-baseline-2026-11-21.md#typing) |
| Resize paint stage p95 | 0.022 ms | [phase 1 resize](../validation/issue-229-phase1-baseline-2026-11-21.md#resize) |

**Read it as:** retained paint was already sparse before this line. What was not
sparse was what happened after paint — display finalization — which is the next
row. A broad theme replacement legitimately repaints every node.

**Limits and open status.** Paint locality is bounded by the repaint target; a
changed ancestor clip/translation/opacity is detected by finalization and falls
back. No issue owns a paint-visit rewrite; #228 owns the post-paint stage.

### Display finalization (#228 milestones 1 and 2)

Milestone 1 splices a repainted node's own contiguous command range when the
command count is unchanged. Milestone 2 also splices count changes while the
moved tail is at most `max(256, 8 × |delta|)` commands.

| Scenario | Rows | Compose visits before | Compose visits after | Full passes before → after | Wall p50 before → after | Evidence |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Hover move | 1,000 | 7,003 | 2 | 1 → 0 | 1.73 → 1.03 ms | [#190 m1 addendum](../benchmarks/issue190-sparse-updates-windows-2026-11-21.md#addendum-sparse-display-finalization-milestone-issue-228), [raw before](raw/issue-228-sparse-finalization-before-windows-2026-11-21.txt) / [raw after](raw/issue-228-sparse-finalization-after-windows-2026-11-21.txt) |
| Hover move | 3,000 | 21,003 | 2 | 1 → 0 | 8.41 → 3.04 ms | same |
| Two-row selection | 1,000 | 7,004 / 7,005 / 7,006 | 4 / 6 / 8 | 1 → 0 | 2.43 → 1.59 ms | same |
| Two-row selection | 3,000 | 21,004 / 21,005 / 21,006 | 4 / 6 / 8 | 1 → 0 | 9.88 → 5.20 ms | same |
| Count-changing focus toggle, 8 rows | 8 | full rebuild 28.8 µs | splice 16.2 µs | — | splice internal 8.5 µs, 13 KB moved | [#228 m2 addendum](../benchmarks/issue190-sparse-updates-windows-2026-11-21.md#addendum-count-changing-sparse-splices-issue-228-milestone-2), [raw m2 before](raw/issue-228-sparse-finalization-m2-before-windows-2026-11-21.txt) / [raw m2 after](raw/issue-228-sparse-finalization-m2-after-windows-2026-11-21.txt) |
| Count-changing focus toggle, last of 400 | 400 | full rebuild 528.0 µs | splice 10.0 µs | tail = 0 | same |
| Broad theme change | 1,000/3,000 | 7,003 / 21,003 | unchanged | 1 → 1 | — | same m1 addendum |

**Read it as:** for the sparse classes, composition is now proportional to the
changed content rather than the live tree. The internal splice and index fixup
are bounded by the same tail policy; when the tail is empty the fixup does no
work.

**Limits and open status.** These classes intentionally still call the full path:
structure/order changes, overlays (drag preview/tooltip), live backdrop
boundaries, `Scroll_Region` nodes themselves, clipping nodes with a count change,
non-neutral inherited presentation, motion presentation frames, scale changes,
and repaints covering most of the display (≥64 queued nodes and `queued × 8 ≥`
display length). The #190 reorder leg is unchanged at 7,003/21,003 compose
visits. On Scratchpad the path engaged at most once per process (0.4 µs in
release, 1 µs in debug) and full-pass counts were identical to the baseline at
every step, so there is no application-visible win there
([A/B capture](../benchmarks/scratchpad-ab-windows-2026-11-21.md#228-sparse-finalization--active-but-immaterial)).
#228 stays open for the remaining full-pass classes.

### Description and reconcile (#229 phases 1 and 2)

Phase 2 compares every field `copy_node_description` reads, plus the derived
retained values, against the pending description. An exact match skips the
description/layout/measure/paint hashes, the copy, dirty marking, measure
observation, layout propagation, paint queueing, the text-run decision, and —
when the emitted `(kind, id, parent)` sequence also matches — the structure
bucket maps, retirement scan, and order rebuild.

| Workload | Metric | Before | After | Change | Evidence |
| --- | --- | ---: | ---: | ---: | --- |
| Fixture typing, SDL_GPU | description p95 | 0.504 ms | 0.401 ms | -20.3% | [phase 2](../validation/issue-229-phase2-description-reuse-2026-11-21.md#description-p50p95p99-median-of-five-runs-ms), [raw after summary](../validation/raw/issue-229-phase2-description-reuse-2026-11-21/after-scratchpad-summary.csv) |
| Fixture typing, D3D12 | description p95 | 0.519 ms | 0.363 ms | -30.1% | same |
| Fixture typing, Vulkan | description p95 | 0.500 ms | 0.380 ms | -24.0% | same |
| Fixture typing, SDL_GPU | `reconcile_copy` p95 | 0.122 ms | 0.009 ms | -93% | same |
| Fixture typing, SDL_GPU | `structure_diff` p95 | 0.018 ms | 0.000 ms | -100% | same |
| Fixture typing, SDL_GPU | copy + hash + structure p95 | 0.176 ms | 0.090 ms | -49% | same |
| Fixture scroll / selection / tabs | description p95 | — | — | -12% to -33% | same |
| Fixture resize | description p95 | — | — | -3% to -9% | same (layout-dominated) |
| Fixture churn (43% changed per pass) | description p95 | 0.699 ms | 0.680 ms (SDL_GPU; other backends -6% to -17%) | no regression | [high-churn control](../validation/issue-229-phase2-description-reuse-2026-11-21.md#high-churn-control) |
| Fixture idle startup pass | description p95 | 0.201 ms | 0.128 ms | -36.1% | [phase 2 table](../validation/issue-229-phase2-description-reuse-2026-11-21.md#description-p50p95p99-median-of-five-runs-ms) |
| Real Scratchpad typing | cumulative application build | 76.673 ms | 66.681 ms | **-10.21%** | [Scratchpad phase 2 A/B](../benchmarks/scratchpad-ab-phase2-windows-2026-11-21.md#typing-burst-ten-pairs), [raw](../benchmarks/raw/scratchpad-ab-phase2-windows-2026-11-21/typing/) |
| Real Scratchpad typing | exact retained matches | — | 855 / 858 per character | 99.65% | same, [counters](../benchmarks/scratchpad-ab-phase2-windows-2026-11-21.md#typing-burst-candidate-medians-over-characters-123-ten-pairs) |
| Real Scratchpad sequence | cumulative application build | 33.239 ms | 33.652 ms | +3.28% (not claimed) | same, [sequence table](../benchmarks/scratchpad-ab-phase2-windows-2026-11-21.md#nine-action-cumulative-process-metrics) |
| Real Scratchpad sequence | sequence-attributed build | 19.223 ms | 20.429 ms | +8.31% (not claimed) | same |

The phase-1 baseline that the after arm reproduces exactly is in the
[phase 1 record](../validation/issue-229-phase1-baseline-2026-11-21.md) with
[fixture stage runs](../validation/raw/issue-229-scratchpad-baseline-2026-11-21/fixture-stage-runs.csv)
and the [paired phase-2 runs](../validation/raw/issue-229-phase2-description-reuse-2026-11-21/before-scratchpad-runs.csv).

**Read it as:** the fixture win is real, and the real application win exists but
only in text editing. The command sequence is a changed-heavy workload where the
gate pays its comparison prefix and the copy bucket it removes is small: the
candidate's remaining copy across all nine steps is 0.59 ms while the
comparison is about 1.05 ms. The sign of the sequence difference is not stable
across capture segments.

**Scaling and limits.** The fixture describes ~156 nodes per pass; Scratchpad
describes ~393 across two passes and its whole runtime step is 8.4-9.1 ms p95.
Scaling the measured per-node saving gives **~0.25-0.40 ms per description pass,
about 3-4.5% of the real step** — not the fixture's 20%. Application build is
~39% of the fixture pass and is not removable by the runtime. Persistent
allocation counts are unchanged; scratch allocation calls fall because the
structure-diff maps are no longer built (typing fixture 2,809 → 1,383).
#229 stays open because the 120 Hz frame budget still depends on
application-side work.

### Application description and keyed regions (#231)

Regions are the only mechanism here that removes application work: a cached
region returns at `region_begin` and the body does not execute. Phase 2 runs
after the application has already emitted, so the two compose rather than
substitute.

| Workload | Metric | Plain | Regions | Change | Evidence |
| --- | --- | ---: | ---: | ---: | --- |
| Scratchpad pilot, typing | emitted nodes per character | 858 | 741 | -13.6% | [#231 research record](../research/description-locality-re-describable-subtrees.md#finding), [pilot patch](raw/scratchpad-region-pilot-windows-2026-11-21/pilot-region-diff.patch) |
| Scratchpad pilot, typing | region skips per character | 0 | 6 | — | same |
| Scratchpad pilot, typing | runtime description stage | 1.664 ms | 1.546 ms | -7.1% | same |
| Scratchpad pilot, typing | reconcile stage | 0.867 ms | 0.748 ms | -13.7% | same |
| Scratchpad pilot, typing | cumulative application build | 59.821 ms | 56.920 ms | -6.24% | same |
| Scratchpad pilot, sequence | cumulative application build | 30.397 ms | 30.366 ms | -0.73% | same (not a claim) |
| Scratchpad pilot, sequence | sequence-attributed build | 17.543 ms | 18.427 ms | +2.66% | same (not a claim) |
| Adopted tab strip + tree, typing | emitted nodes per character | 858 | 741 | -13.6% | [adoption capture](../benchmarks/scratchpad-region-adoption-windows-2026-11-21.md#typing-burst-per-character), [raw](../benchmarks/raw/scratchpad-region-adoption-windows-2026-11-21/typing/combined/combined.json) |
| Adopted tab strip + tree, typing | region skips per character | 0 | 6 | — | same |
| Adopted tab strip + tree, typing | reconcile stage | 0.832 ms | 0.774 ms | -7.0% | same |
| Adopted tab strip + tree, typing | cumulative application build | 58.849 ms | 56.367 ms | -4.41% | same |
| Quick Open results slot, filter burst | skips / emitted per character | 1 / 47 (tree only) | 1 / 47 | no saving | same, [Quick Open result](../benchmarks/scratchpad-region-adoption-windows-2026-11-21.md#quick-open-filter-burst-per-character) |

**Read it as:** regions move the metric they own (emitted nodes and the
reconcile that consumes them), and the app-visible effect is a few percent of
typing build, not the 13.6% node reduction. The pilot's 6.24% and phase 2's
10.21% were measured on different sessions and remove work at different layers;
multiplying them gives an indicative **~15.8%** combined typing-build ceiling,
not a measured A/B. The later adopted-region session measured -4.41% for its two
regions alone.

**Limits and open status.** The pilot cost 560 added / 31 removed lines across
seven files for four regions, five new state fields, a 67-line revision helper,
and 99 lines of tests. Three input classes are easy to miss and must be in the
revision: application-polled widget results, retained geometry from the previous
frame, and realized virtual-scroll windows. The adopted two sites cost 213
product lines plus 168 helper/test lines. Quick Open's results slot never skips
while filtering (180/180 characters), because the query is a revision input; it
is NO-GO as a per-keystroke optimization. No broadcast conversion of the ~350
remaining `invalidate_root` sites is proposed. #231 remains open research.

## Stage localization map (#231)

This is the mechanism table from the research record, reproduced here because
it is the best one-page answer to "which stage scales with what".

| Stage | Locality before regions | What a keyed region changes |
| --- | --- | --- |
| Invalidation lookup | O(changed keys) after #227 | unchanged |
| Measurement | Partial | skipped descendants keep their measurement cache entries |
| Layout | Partial (#230 milestone 1) | the region container is laid out; descendants keep prior geometry |
| Paint | Localized | descendants are not repainted unless retained state changed |
| Display finalization | Partial (#228 milestones 1+2) | fewer described nodes reach the display list |
| GPU resources | Localized | unchanged |
| **Application description** | **O(all live)** | **the body procedure does not run; control returns at `region_begin`** |

Two reuse mechanisms now exist and they are not substitutes:

1. **Region reuse** removes application emission before reconcile sees it.
2. **Phase-2 description reuse** removes runtime copy/hash/structure work after
   the application has emitted everything. On the pilot's smaller description,
   738 of 741 emitted nodes were still exact matches, so phase 2 continued to
   skip nearly all of the runtime work.

## Scratchpad A/B headline

| Capture | Workload | Result | Is it a win? |
| --- | --- | --- | --- |
| [#227/#228/#230 A/B](../benchmarks/scratchpad-ab-windows-2026-11-21.md) | Nine-action command sequence | cumulative build -2.27% (10 pairs); sequence -6.29%; pair spread > 25% | **No reliable effect.** `regions_skipped` = 0, sparse layout counters = 0, at most one splice per process |
| [Phase 2 A/B, sequence](../benchmarks/scratchpad-ab-phase2-windows-2026-11-21.md) | Nine-action command sequence | cumulative build +3.28%, sequence +8.31% (13 pairs); segment signs disagree | **No direction.** 82.4% exact matches, but the copy bucket is too small and two stalls inflate p95 |
| [Phase 2 A/B, typing](../benchmarks/scratchpad-ab-phase2-windows-2026-11-21.md) | 24-character editor burst | cumulative build **-10.21%** (10/10 pairs negative); describe windows flat | **Yes, in text editing.** 855/858 exact matches per character |
| [#231 pilot](../benchmarks/scratchpad-region-pilot-windows-2026-11-21.md) | 24-character editor burst | cumulative build -6.24%; emitted -13.6%; description stage -7.1% | **Yes, at the region layer.** Input coverage is the cost |
| [#231 adopted regions](../benchmarks/scratchpad-region-adoption-windows-2026-11-21.md) | 24-character editor burst | cumulative build -4.41%; emitted -13.6%; reconcile -7.0% | **Yes, smaller point estimate, same mechanism** |
| [#231 adopted regions, Quick Open](../benchmarks/scratchpad-region-adoption-windows-2026-11-21.md) | 19-character filter burst | no node saving; 0/180 results-slot skips | **No.** Query is a revision input, so the slot must rebuild |

The command sequence is the null result that keeps this ledger honest. It is the
workload a user performs most often in Scratchpad (open, switch, close, settings),
and none of #227, #228, #230, phase 2, or the adopted regions moved it reliably.
Composition is 0.6-4.3% of those steps, sparse layout never ran, and the copy
bucket is sub-millisecond to about 2 ms across nine steps. The next useful
measurement target is the resize/typing class in the fixture, not another
command-sequence rerun.

## What these numbers do not cover

- **One machine, one compiler, one display scale.** All captures are Windows 10,
  Ryzen 5 7600X, RTX 2080 SUPER, Odin nightly `08539cd`, scale 1.0. CI pins the
  official `dev-2026-11` release. Do not compare these values with another host.
- **CPU wall time only.** No GPU execution, scanout, presentation latency,
  input-to-display latency, or compositor timing. The sparse work is CPU-side.
- **Synthetic input.** The benchmark hooks invoke application/backend command
  paths and committed text-input events on a schedule. They are not native
  keyboard or pointer input, so they do not measure input latency.
- **Fixture-versus-application scaling.** The attribution fixture describes ~156
  nodes and models Scratchpad's composition; it is not Scratchpad's state or
  worker activity. Real-application rows are the authority for user-visible
  claims; fixture rows are the authority for per-stage mechanism.
- **Host DPI gap.** All captures are at display scale 1.0. The native host's
  fractional-DPI density path was not part of these measurements; the
  [#120 audit](../validation/issue-120-connected-tabs-visual-audit.md) records
  the separate native-host DPI-density gap for visual captures. No sparse-stage
  claim is made at other scales.
- **Unmeasured update classes.** Motion presentation frames, retained backdrop
  boundaries, transient overlays, scroll-region chrome, clipping/ancestor
  presentation changes, broad theme repaints, and structural reorder still take
  full finalization by design and were not optimized here. Layout sparsity still
  allocates per-child arrays. Changed-heavy description passes still pay the
  exact-comparison prefix.
- **Instrumentation asymmetry.** The phase-2 candidate carries the always-on
  stage timers; phase 1 measured their cost at +6.6% of the fixture's typing p95
  and below noise on the real step. The A/B arms therefore differ by that
  instrumentation as well as the gate.
- **Region correctness is application-declared.** The runtime cannot observe
  arbitrary app memory. A monotonic but stale revision still produces stale
  output; the #106 oracle and Scratchpad's stale-output guard make that failure
  detectable in tests, not in production.
- **No cross-machine or cross-issue aggregate.** Runs from different sessions
  are reported separately. The one multiplied figure (~15.8%) is labeled as an
  indicative composition, not a measurement.

## Reproduction

```powershell
# #190 fixture: sparse updates, #227 index, #228 splices, #230 layout.
.\benchmarks\diagnostics\issue190_sparse_updates.ps1 -Odin C:\odin\odin.exe -Samples 24

# #229 fixture: stage attribution and sparse-versus-full composition.
.\tools\bench_scratchpad_workload.ps1 -Odin C:\odin\odin.exe -Runs 5 -Frames 24
.\tools\bench_scratchpad_workload.ps1 -Odin C:\odin\odin.exe -Runs 5 -Frames 24 -DescriptionReuse 0 -OutputDir out\phase2-before
.\tools\bench_scratchpad_workload.ps1 -Odin C:\odin\odin.exe -Runs 5 -Frames 24 -DescriptionReuse 1 -OutputDir out\phase2-after

# Sparse-path oracles (deterministic counters and byte-for-byte comparisons).
C:\odin\odin.exe test runtime
```

The Scratchpad captures require the external Scratchpad checkout, the generated
workspace fixture, and the harness patches listed in each benchmark report's
reproduction artifacts. They are not reproducible from this repository alone.

## Evidence index

- [Sparse updates and authoring cost, #190 (2026-11-21)](issue190-sparse-updates-windows-2026-11-21.md)
  — #227 lookup, #228 milestone 1 and 2, #230 milestone 1 addenda and all raw
  captures.
- [Issue #229 phase 1 baseline (2026-11-21)](../validation/issue-229-phase1-baseline-2026-11-21.md)
  — harness, attribution, overhead, fixture baseline.
- [Issue #229 phase 2 description reuse (2026-11-21)](../validation/issue-229-phase2-description-reuse-2026-11-21.md)
  — gate audit, correctness, paired before/after, scaled expectation.
- [Matched Scratchpad A/B (2026-11-21)](scratchpad-ab-windows-2026-11-21.md)
  — the negative command-sequence result for #227/#228/#230.
- [Matched Scratchpad A/B, phase 2 (2026-11-21)](scratchpad-ab-phase2-windows-2026-11-21.md)
  — typing win, sequence non-result, tail stalls.
- [Description locality research record, #231](../research/description-locality-re-describable-subtrees.md)
  — mechanism map, burden, invariants, GO/NO-GO.
- [Scratchpad keyed-region pilot (2026-11-21)](scratchpad-region-pilot-windows-2026-11-21.md)
  and [adoption + Quick Open (2026-11-21)](scratchpad-region-adoption-windows-2026-11-21.md).
- [v0.3.0 release validation](../validation/release-v0.3.0-validation.md) — the
  local suite, examples, smoke, harness deviations, and remaining release gates.
