# Issue #229 Phase 1 — performance measurement harness and trustworthy baseline

**Date:** 2026-11-21

**Platform:** Windows 10 Home 19045, Ryzen 5 7600X, NVIDIA RTX 2080 SUPER

**Odin:** `dev-2026-11-nightly:08539cd`

**Branch:** `codex/issue-229-perf-phase1`

**Base:** `ce040b4` (`perf(runtime): sparse range finalization for multi-command repaints`, issue #228; includes #227 region-key indexing)

**Status:** harness and instrumentation PASS; baseline recorded. No runtime optimization is part of this phase.

## What this records

Issue #229 needs a trustworthy ledger before any optimization. This record
provides:

1. One Scratchpad-shaped scene that runs through the SDL_GPU reference host,
   hosted WebGPU on D3D12 and Vulkan, and the headless `testui` harness.
2. Six scripted interaction families: typing bursts, tree/editor scrolling,
   text-selection drag, live logical resize sweeps, tab switching, and a
   settled idle hold.
3. Per-stage CPU attribution inside `reconcile` and `update_paint`, exposed
   through `Frame_Stats.stage_timings_ns` and `testui.Turn_Work`.
4. A 5-run × 3-backend baseline with p50/p95/p99, allocation counts, stage
   visitation counts, and the sparse-versus-full composition split.
5. A real-Scratchpad `--timings` cross-check on live resize.

The hard constraint for this phase held: there are no runtime optimizations
here. The only runtime change is measurement. `reconcile` and `update_paint`
execute the same branches, visit the same nodes, and provide the same results;
they additionally read a cycle counter at section boundaries.

## Measurement and behavior verification

### Instrumentation cost

The stage marks use `intrinsics.read_cycle_counter()`, calibrated once per
process against `core:time` (200 µs, outside any measured description). Each
mark stores one counter value and each stage accumulates one `u64`. There is no
allocation, no map lookup, and no formatting on the hot path. `Perf_Mark` falls
back to `time.tick_now` when a platform does not expose a usable cycle counter.

Paired A/B, 15 alternating process runs per arm, SDL_GPU, 24 description
passes, median of per-run description p95
([raw CSV](raw/issue-229-scratchpad-baseline-2026-11-21/instrumentation-overhead-paired-ab.csv)):

| Workload | Instrumented p95 | Uninstrumented p95 | Difference |
|---|---:|---:|---:|
| typing | 0.4745 ms | 0.4451 ms | **+0.0294 ms (+6.6%)** |
| resize | 0.5126 ms | 0.5676 ms | −0.0550 ms (within run-to-run noise) |

That is about 0.35% of a whole 8.33 ms 120 Hz frame in the worst measured case.
On the real application's 8.4–9.1 ms step it is below the noise floor. The
fixture is deliberately small (~156 described nodes), so the relative share is
larger than it will be on Scratchpad's 393-node build.

### Counters do not change

The instrumented and uninstrumented builds were compared over the full
5-run × 3-backend suite. Every pre-existing counter median is identical for
every scenario/backend pair: descriptions emitted and reused, reconcile,
measure/hit/miss, layout, paint, composition, text shapes, semantic
resolutions/structure/property changes, nodes created/retired, persistent and
scratch allocation calls. The only differences are the two new counters
(`display_finalization_full_passes`, `global_fallbacks`) that do not exist in
the uninstrumented build. See
[`uninstrumented-summary.md`](raw/issue-229-scratchpad-baseline-2026-11-21/uninstrumented-summary.md)
and
[`fixture-counter-runs.csv`](raw/issue-229-scratchpad-baseline-2026-11-21/fixture-counter-runs.csv).

### Suites

Runtime 448, ui 57, testui 27, host/fonts 5, host/sdl3 9, host/diagnostics 37,
theme 23, renderer/cpu 23, `odin build tests`, and `native/sdl_gpu_entry`
all pass. The repository `tools/test.ps1` wrapper stops earlier in this
environment at the external AccessKit native UIA contract check
(`Accessible Button missing`), before any Alicorn suite runs; the suites were
therefore executed individually with the same AccessKit compiler arguments.

## Harness design

### Scene

[`benchmarks/scratchpad_scene/scene.odin`](../../benchmarks/scratchpad_scene/scene.odin)
is a backend-neutral package shared by the workload matrix and `testui`.

| Region | Shape |
|---|---|
| Document tabs | 8 closable, dirty-capable tabs; active index is application-owned |
| Pinned side panel | Rounded relief panel with a two-stop gradient header from the gallery surface pattern |
| Workspace tree | 1,000 nodes (20 roots × 49 children); roots expandable; virtualized visible rows |
| Editor | 10,000 logical lines, fixed 18 px rows, virtualized; line-number gutter, syntax paint spans, per-row temporary shaping |
| Command field | One focused controlled text field carrying a live selection |
| Editor chrome | Breadcrumb row, six toolbar buttons, rounded minimap of 56 retained surface bars |
| Status strip | Four muted text cells |

The scene describes roughly **156 nodes per pass** at 960×640. The editor and
tree virtualize; only realized rows are described. The scene preallocates row
and tree labels at init so per-frame allocation counters stay focused on
runtime work. To remain representative of Scratchpad's editor, each realized
row also calls `runtime_text_run_build` and destroys the temporary run, the
same app-side shaping Scratchpad performs to resolve display ranges.

### Interactions

| Scenario | Per-wake mutation |
|---|---|
| `typing` | Appends one character to the application-owned command buffer and the edited editor row; requests a fresh description |
| `scroll` | Sets retained offsets on the editor and tree virtual lists |
| `selection` | Moves the command field's selection across its text |
| `resize` | Changes the logical viewport width in 40 px steps across 720–960 px |
| `tabs` | Advances the application-owned active tab |
| `idle` | No mutation; one cold mount, then a 1.2 s host smoke hold |

The driver posts one wake per planned description. `typing`, `scroll`,
`selection`, `resize`, and `tabs` each run 24 description passes after a
two-sample warmup. `idle` records 3 startup description passes and then
`describe_calls` stays at 3: the hold adds no description, allocation, or
retained stage visit.

The same scene is compiled into:

- `--backend=sdl-gpu` — SDL_GPU reference host (`ui.run`).
- `--backend=d3d12` / `--backend=vulkan` — hosted WebGPU (`webgpu.run`).
- `testui` — headless `open`, pointer, text-selection, and virtual-time steps.

## Attribution implementation

`Runtime_Timing_Stage` and the marks live in
[`runtime/perf_timing.odin`](../../runtime/perf_timing.odin). Cumulative
nanoseconds are published as `Frame_Stats.stage_timings_ns`.

| Stage | Timer boundary |
|---|---|
| `Description` | `begin_frame`/`begin_presentation_frame` through the end of `end_frame`/`end_presentation_frame`, including application build |
| `Reconcile` | Whole `reconcile` procedure |
| `Reconcile_Hash` | Per described node: style-domain diff plus description/layout/measure/paint hash computation and observation |
| `Reconcile_Copy` | Per described node: label scratch, `copy_node_description`, region-index update, pointer-hit record, grid tracks, selection-dependency invalidation |
| `Structure_Diff` | Percent-width prune/update, top-level and child-list reconciliation, retirement, order rebuild |
| `Measure` | `layout_measure_retained_dirty_nodes` |
| `Measure_Text` | `prepare_text_run_node` calls reached from measure **and** layout; a shared bucket, not a strict subset of `Measure` |
| `Layout` | `layout_tree` plus restore resolution |
| `Semantic_Sync` | Focus realization, adaptive semantic publication, collection pruning, semantic commit |
| `Paint` | Retained paint-queue visit, including localized range finalization |
| `Composition` | Full `rebuild_display` |
| `Finalize` | Presentation-output pruning and revision advance |

`Reconcile` contains measure/layout/semantic/paint/composition/finalize. The
summary also reports `application_build = description − reconcile` and
`reconcile_other = reconcile − the named sub-stages` so the buckets can be
read either as a nested tree or as a non-overlapping split.

Timer sites:

- `runtime/reconcile.odin` — node-loop hash/copy marks, structure, focus,
  measure, layout, semantic, finalize, and the outer reconcile total.
- `runtime/paint.odin` — paint-queue loop and full display rebuild.
- `runtime/layout_measure.odin` — text-shaping subsection.
- `runtime/runtime_state.odin` + `runtime/reconcile.odin` — `Description`
  bracket for description and presentation frames.
- `testui/testui.odin` — the same per-stage deltas in `Turn_Work`.

## Baseline

### Description, per-run p50/p95/p99 medians (ms)

Complete data:
[`fixture-stage-runs.csv`](raw/issue-229-scratchpad-baseline-2026-11-21/fixture-stage-runs.csv),
[`fixture-stage-summary.csv`](raw/issue-229-scratchpad-baseline-2026-11-21/fixture-stage-summary.csv).

| Scenario | Backend | p50 | p95 | p99 |
|---|---|---:|---:|---:|
| typing | SDL_GPU | 0.374 | 0.477 | 0.509 |
| typing | D3D12 | 0.388 | 0.482 | 0.529 |
| typing | Vulkan | 0.338 | 0.470 | 0.513 |
| scroll | SDL_GPU | 0.336 | 0.469 | 0.545 |
| scroll | D3D12 | 0.344 | 0.438 | 0.442 |
| scroll | Vulkan | 0.346 | 0.441 | 0.465 |
| selection | SDL_GPU | 0.337 | 0.434 | 0.456 |
| selection | D3D12 | 0.346 | 0.448 | 0.506 |
| selection | Vulkan | 0.345 | 0.454 | 0.497 |
| resize | SDL_GPU | 0.356 | 0.588 | 0.707 |
| resize | D3D12 | 0.364 | 0.550 | 0.602 |
| resize | Vulkan | 0.362 | 0.584 | 0.651 |
| tabs | SDL_GPU | 0.346 | 0.423 | 0.462 |
| tabs | D3D12 | 0.356 | 0.428 | 0.450 |
| tabs | Vulkan | 0.339 | 0.443 | 0.463 |
| idle (startup pass) | SDL_GPU | 0.175 | 0.175 | 0.175 |
| idle (startup pass) | D3D12 | 0.194 | 0.194 | 0.194 |
| idle (startup pass) | Vulkan | 0.190 | 0.190 | 0.190 |

Backend differences are small and inside run-to-run noise. The scene, not the
renderer, sets the description cost; encode and present costs are separate and
are not measured by this table.

### Stage p95 by scenario and backend (ms)

Median of the five per-run p95 values. `measure_text` is a shared
measure+layout shaping bucket.

#### typing

| Stage | SDL_GPU | D3D12 | Vulkan |
|---|---:|---:|---:|
| description | 0.477 | 0.482 | 0.470 |
| reconcile | 0.308 | 0.286 | 0.292 |
| reconcile_hash | 0.037 | 0.032 | 0.033 |
| reconcile_copy | 0.115 | 0.112 | 0.109 |
| structure_diff | 0.017 | 0.018 | 0.016 |
| measure | 0.048 | 0.048 | 0.041 |
| measure_text | 0.044 | 0.045 | 0.039 |
| layout | 0.001 | 0.001 | 0.001 |
| semantic_sync | 0.020 | 0.021 | 0.018 |
| paint | 0.007 | 0.007 | 0.007 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.185 | 0.197 | 0.188 |
| reconcile_other | 0.063 | 0.060 | 0.060 |

#### scroll

| Stage | SDL_GPU | D3D12 | Vulkan |
|---|---:|---:|---:|
| description | 0.469 | 0.438 | 0.441 |
| reconcile | 0.282 | 0.249 | 0.249 |
| reconcile_hash | 0.041 | 0.036 | 0.036 |
| reconcile_copy | 0.124 | 0.112 | 0.112 |
| structure_diff | 0.017 | 0.018 | 0.018 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.002 | 0.001 | 0.001 |
| semantic_sync | 0.020 | 0.020 | 0.021 |
| paint | 0.000 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.204 | 0.192 | 0.194 |
| reconcile_other | 0.082 | 0.063 | 0.065 |

#### selection

| Stage | SDL_GPU | D3D12 | Vulkan |
|---|---:|---:|---:|
| description | 0.434 | 0.448 | 0.454 |
| reconcile | 0.253 | 0.255 | 0.277 |
| reconcile_hash | 0.036 | 0.035 | 0.036 |
| reconcile_copy | 0.113 | 0.110 | 0.112 |
| structure_diff | 0.017 | 0.018 | 0.019 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.001 | 0.001 | 0.001 |
| semantic_sync | 0.020 | 0.020 | 0.020 |
| paint | 0.000 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.001 | 0.000 |
| application_build | 0.187 | 0.195 | 0.193 |
| reconcile_other | 0.064 | 0.061 | 0.064 |

#### resize

| Stage | SDL_GPU | D3D12 | Vulkan |
|---|---:|---:|---:|
| description | 0.588 | 0.550 | 0.584 |
| reconcile | 0.438 | 0.406 | 0.382 |
| reconcile_hash | 0.038 | 0.033 | 0.038 |
| reconcile_copy | 0.128 | 0.119 | 0.120 |
| structure_diff | 0.019 | 0.019 | 0.021 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.014 | 0.014 | 0.011 |
| layout | 0.165 | 0.144 | 0.137 |
| semantic_sync | 0.020 | 0.019 | 0.021 |
| paint | 0.022 | 0.021 | 0.020 |
| composition | 0.019 | 0.017 | 0.016 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.198 | 0.185 | 0.201 |
| reconcile_other | 0.069 | 0.063 | 0.064 |

#### tabs

| Stage | SDL_GPU | D3D12 | Vulkan |
|---|---:|---:|---:|
| description | 0.423 | 0.428 | 0.443 |
| reconcile | 0.256 | 0.248 | 0.249 |
| reconcile_hash | 0.036 | 0.036 | 0.037 |
| reconcile_copy | 0.118 | 0.114 | 0.112 |
| structure_diff | 0.017 | 0.018 | 0.018 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.001 | 0.002 | 0.001 |
| semantic_sync | 0.018 | 0.019 | 0.020 |
| paint | 0.000 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.187 | 0.183 | 0.191 |
| reconcile_other | 0.064 | 0.063 | 0.063 |

#### idle (final startup pass)

| Stage | SDL_GPU | D3D12 | Vulkan |
|---|---:|---:|---:|
| description | 0.175 | 0.194 | 0.190 |
| reconcile | 0.098 | 0.104 | 0.102 |
| reconcile_hash | 0.016 | 0.017 | 0.017 |
| reconcile_copy | 0.034 | 0.036 | 0.036 |
| structure_diff | 0.009 | 0.010 | 0.009 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.000 | 0.000 | 0.000 |
| semantic_sync | 0.010 | 0.010 | 0.010 |
| paint | 0.000 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.077 | 0.082 | 0.088 |
| reconcile_other | 0.029 | 0.030 | 0.029 |

### Retained-work counters

Median across five runs. Counts cover the measured window (warmup excluded).

| Scenario | Backend | emitted | reused | reconcile | measure | text shapes | layout | paint | compose | full finalize passes | semantic changes | persistent alloc calls | scratch alloc calls |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| typing | SDL_GPU | 3,588 | 3,566 | 3,588 | 22 | 22 | 0 | 22 | 22 | 0 | 45 | 564 | 2,809 |
| typing | D3D12 | 3,519 | 3,497 | 3,519 | 22 | 22 | 0 | 22 | 22 | 0 | 45 | 655 | 2,763 |
| typing | Vulkan | 3,519 | 3,497 | 3,519 | 22 | 22 | 0 | 22 | 22 | 0 | 45 | 655 | 2,763 |
| scroll | SDL_GPU | 3,588 | 3,588 | 3,588 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 189 | 1,863 |
| scroll | D3D12 | 3,519 | 3,519 | 3,519 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 280 | 1,817 |
| scroll | Vulkan | 3,519 | 3,519 | 3,519 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 280 | 1,817 |
| selection | SDL_GPU | 3,588 | 3,588 | 3,588 | 0 | 0 | 0 | 1 | 115 | 1 | 23 | 195 | 1,865 |
| selection | D3D12 | 3,519 | 3,519 | 3,519 | 0 | 0 | 0 | 1 | 112 | 1 | 23 | 286 | 1,819 |
| selection | Vulkan | 3,519 | 3,519 | 3,519 | 0 | 0 | 0 | 1 | 112 | 1 | 23 | 286 | 1,819 |
| resize | SDL_GPU | 3,672 | 3,657 | 3,672 | 482 | 54 | 420 | 180 | 232 | 2 | 51 | 875 | 2,697 |
| resize | D3D12 | 3,603 | 3,588 | 3,603 | 467 | 54 | 412 | 177 | 226 | 2 | 50 | 950 | 2,642 |
| resize | Vulkan | 3,603 | 3,588 | 3,603 | 467 | 54 | 412 | 177 | 226 | 2 | 50 | 950 | 2,642 |
| tabs | SDL_GPU | 3,588 | 3,588 | 3,588 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 189 | 1,863 |
| tabs | D3D12 | 3,519 | 3,519 | 3,519 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 280 | 1,817 |
| tabs | Vulkan | 3,519 | 3,519 | 3,519 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 280 | 1,817 |
| idle | SDL_GPU | 156 | 156 | 156 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 4 | 81 |
| idle | D3D12 | 153 | 153 | 153 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 8 | 79 |
| idle | Vulkan | 153 | 153 | 153 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 8 | 79 |

The per-pass description count is about 156 nodes. Typing produces one
measure/shape/paint/compose update per pass because only the edited field
changes. Scroll and tab switching reuse every description after the first pass.
Selection changes retained interaction paint, but the changed command count
forces one full display rebuild.

## Measured cost split

Reference backend, SDL_GPU, p95 per pass. Percentages are of `description`.

### Typing (the per-keystroke turn)

| Bucket | ms | share |
|---|---:|---:|
| application build | 0.185 | 39% |
| reconcile copy | 0.115 | 24% |
| reconcile hash | 0.037 | 8% |
| structure diff | 0.017 | 4% |
| measure (of which text shaping 0.044) | 0.048 | 10% |
| layout | 0.001 | <1% |
| semantic sync | 0.020 | 4% |
| paint | 0.007 | 1% |
| composition / finalize | 0.000 | 0% |
| other reconcile bookkeeping | 0.063 | 13% |
| **description** | **0.477** | 100% |

### Resize sweep (full measure/layout path)

| Bucket | ms | share |
|---|---:|---:|
| application build | 0.198 | 34% |
| reconcile copy | 0.128 | 22% |
| reconcile hash | 0.038 | 6% |
| structure diff | 0.019 | 3% |
| measure (text share 0.014 in layout) | 0.000 | 0% |
| layout | 0.165 | 28% |
| semantic sync | 0.020 | 3% |
| paint | 0.022 | 4% |
| composition | 0.019 | 3% |
| finalize | 0.000 | 0% |
| other reconcile bookkeeping | 0.069 | 12% |
| **description** | **0.588** | 100% |

### What the split says

- **Description reuse is the largest runtime opportunity on unchanged-node
  turns.** Copy + hash + structure is 0.169 ms of the 0.477 ms typing pass
  (35%), more than measure, layout, paint, composition, and finalize combined.
  This is exactly the Phase 2 target in the issue.
- **Layout only dominates a real resize.** It is 28% of the resize pass and
  effectively free in typing, scrolling, tab switching, and selection.
- **Text shaping is a minority of this fixture.** The runtime measure-text
  bucket is 0.044 ms on typing (9%). A further share of shaping is the
  explicit app-side temporary run in `application_build`, matching
  Scratchpad's editor display-range work; a runtime-only shape cache cannot
  remove that part.
- **Paint/composition is already sparse for ordinary interactions.** Scroll,
  tab switching, and typing record zero full display rebuilds. Selection and
  resize are the remaining full-path cases.

## Real Scratchpad `--timings` cross-check

The checked-in Scratchpad validator at
`C:\Users\saman\dev\scratchpad` (branch `codex/issue-211-webgpu-frontend`) was
run with `--renderer=webgpu --timings`, with 30 `MoveWindow` live-resize steps.
It is built against Alicorn `0beff9d`, an ancestor of this branch's base and
therefore **before #227/#228**; this is a scale reference, not a same-revision
A/B. Each run presented 33 frames.

| Backend | runtime step p50 | p95 | p99 | renderer encode p50/p95 | step-to-present p50/p95 |
|---|---:|---:|---:|---:|---:|
| D3D12 | 8.431 ms | 9.091 ms | 11.269 ms | 1.562 / 2.021 ms | 10.236 / 10.978 ms |
| Vulkan | 8.484 ms | 9.080 ms | 10.243 ms | 1.480 / 1.746 ms | 10.133 / 10.926 ms |

Raw:
[D3D12](raw/issue-229-scratchpad-baseline-2026-11-21/real-scratchpad-live-resize-d3d12.txt),
[Vulkan](raw/issue-229-scratchpad-baseline-2026-11-21/real-scratchpad-live-resize-vulkan.txt).

This reproduces the #211 finding (8.2–9.0 ms p95 for the real two-pass,
393-node rebuild). The fixture's hosted resize step, measured with the same
host `--timings` path, is 0.366 ms p50 / 1.206 ms p95 runtime step and
0.763 / 2.554 ms step-to-present on D3D12
([raw](raw/issue-229-scratchpad-baseline-2026-11-21/fixture-host-timings-d3d12.txt)).
The fixture is therefore a runtime-attribution fixture, not a replacement for
the real application baseline.

## Budget ledger against the founder targets

| Line | Target | Measured |
|---|---:|---:|
| Whole 120 Hz frame | 8.33 ms | — |
| Scratchpad p50 runtime step, live resize | ≤ 8.33 ms | **8.43–8.48 ms** (101–102%) |
| Scratchpad p95 runtime step, live resize | ≤ 8.33 ms | **9.08–9.09 ms** (109%) |
| Founder p95 CPU frame-build target | 4–5 ms | **8.4–9.1 ms**; needs 3.4–5.1 ms removed |
| Fixture description p95, resize | — | 0.55–0.59 ms |
| Fixture description p95, typing | — | 0.47–0.48 ms |
| Fixture application build p95, typing | — | 0.185–0.197 ms |
| Fixture runtime reconcile p95, typing | — | 0.286–0.308 ms |
| Text shaping p95, typing | — | 0.039–0.045 ms |

The fixture is ~15–18× cheaper than the real application step. Scaling the
fixture's 156-node runtime buckets to Scratchpad's 393 nodes gives roughly
0.4–0.9 ms of runtime reconcile per turn, i.e. 5–10% of the real 8.4–9.1 ms
step. That is a useful warning for Phase 2: description reuse should be
measurable and safe on the fixture, but the real 4–5 ms target also depends on
Scratchpad's application build and after-frame work, which this fixture only
models partially. The issue already states that even perfect runtime skips
cannot avoid calling the app's build; this baseline makes the size of that
remainder explicit.

## Landed work visible in this baseline

### #227 — region-key indexing

The scene deliberately declares no `ui.region`, so this baseline does not
exercise region-key invalidation: `regions_skipped=0`,
`retained_subtrees_reused=0`. No measured effect is claimed for #227 here.
A region-shaped follow-up scene is a Phase 2 addition, not a Phase 1 claim.

### #228 — sparse range finalization

The split is visible in the new counters:

| Scenario | composition visits | full finalize passes | global fallbacks |
|---|---:|---:|---:|
| typing | 22 | 0 | 0 |
| scroll | 0 | 0 | 0 |
| tabs | 0 | 0 | 0 |
| selection | 112–115 | 1 | 1 |
| resize | 226–232 | 2 | 0 |

Ordinary typing, scrolling, and tab switching stay on the sparse path; a
multi-command selection update still falls back once, and the resize sweep
takes two full rebuilds. That fallback is a concrete Phase 5 target: selection
paint changes command counts, which the current sparse splice cannot express.

## Reproduction

```powershell
# Full fixture baseline (5 runs × 6 scenarios × 3 backends)
.\tools\bench_scratchpad_workload.ps1 -Odin C:\odin\odin.exe `
  -Runs 5 -Frames 24 -OutputDir out\scratchpad-perf

# One scenario
.\out\scratchpad-perf\workload_matrix.exe --smoke --smoke-hold-ms=800 `
  --backend=sdl-gpu --workload=scratchpad --interaction=typing --frames=24

# Headless coverage
& C:\odin\odin.exe test testui "-collection:alicorn=$PWD" `
  "-collection:accesskit=$PWD\.deps\odin-accesskit" `
  "-collection:accesskit_c=$PWD\.deps\accesskit\accesskit-c-0.23.1\lib\windows\x86_64\msvc\static"
```

## Limits

- CPU wall time only. These numbers are not GPU execution time, scanout, or
  visible latency.
- One Windows machine, one Odin build, one scene shape. Backend differences
  are small here; do not compare across machines.
- The fixture preallocates labels and models Scratchpad's composition, not its
  full application state, worker activity, session restoration, or every
  after-frame callback.
- The real-Scratchpad cross-check uses a binary built before #227/#228 and is
  a scale reference only.
- The instrumented build's description cost is 0.03 ms higher on the typing
  p95 than the uninstrumented build in the paired A/B; this is below the
  frame-budget noise floor but is recorded rather than hidden.
