# Issue #229 Phase 2 -- exact retained-description reuse

(Working title: "generation-stamped description reuse". The gate ended up
comparing retained state exactly instead of carrying an emit-time stamp; see
[Chosen mechanism](#chosen-mechanism) for why.)

**Date:** 2026-11-21

**Platform:** Windows 10 Home 19045, Ryzen 5 7600X, NVIDIA RTX 2080 SUPER

**Odin:** `dev-2026-11-nightly:08539cd`

**Branch:** `codex/issue-229-perf-phase2`

**Base:** `576f1fd` (`perf(runtime): sparse column suffix placement for main-axis
size changes`, issue #230; includes the Phase 1 attribution harness and the
#227/#228 work)

**Status:** runtime change, correctness suites, and paired before/after
measurement complete. Description reuse is the only behavior change; no
application API changed.

## What this records

Phase 1 measured the description-reuse bucket at ~35% of the synthetic typing
pass (copy 24%, hash 8%, structure 4%). Phase 2 removes that bucket for
unchanged descriptions while proving that a changed description can never
reuse a stale product. This record covers:

1. The chosen mechanism and why the alternatives were rejected.
2. The field-by-field audit of what the reuse gate compares, including the
   `description_hash` coverage gaps that the audit found and closed.
3. Exactly which work the reused path now skips and what it still does.
4. The correctness tests: per-field gate rejection, product refresh, theme
   and font generations, retirement, structure order, and a fresh-runtime
   equivalence oracle.
5. Paired before/after measurement from the same source with the gate compiled
   out (`-define:ALICORN_DESCRIPTION_REUSE=0`) across SDL_GPU, hosted D3D12,
   hosted Vulkan, and a new high-churn scenario.
6. The honest scaled expectation for the real 393-node Scratchpad frame.

## Chosen mechanism

The retained description is already the runtime's owned copy of everything the
last per-node copy wrote. Phase 2 asks one question before hashing anything:

> Does the retained node already hold exactly what this pending description
> asks for?

That question is answered by an **exact comparison** of every field
`copy_node_description` reads, plus every runtime-owned value that copy derives
(`focusable`, `selected`, `text_interaction`, drop position, surface
generations, and the style sidecars). The comparison
is exact and order-independent for a match, but its rejection order follows
mutation frequency: `kind`, the layout style, the paint inputs, and the label
and text are checked first, so a changed node fails within a few comparisons
and the gate never taxes a high-churn pass.

A match proves the copy path would have written identical values and raised no
side effect, so the whole hash/copy/dirty/measure/layout/paint/text tail is
skipped. A mismatch runs the ordinary path unchanged. The gate is not a hash,
so a collision cannot exist; and because it rejects on any doubt, a field the
gate forgets is a test failure (`runtime/description_reuse_test.odin` mutates
all 67 field families), not a silent stale reuse.

The same pass compares the emitted `(kind, id, parent)` sequence with the last
reconciled sequence. That sequence is exact state, not a fingerprint. A match
proves every desired child list and the top-level root list are unchanged, so
bucket construction, retirement, child-list reconciliation, and the order
rebuild are skipped. When the sequence differs, the previous code path runs
verbatim and rewrites the retained sequence.

### Alternatives evaluated and rejected

| Candidate | Verdict |
|---|---|
| (a) Per-node emit counter stamped at emit, compared across frames | Rejected. The emitter rebuilds a `Description` from application state every pass; it cannot prove the content is unchanged without comparing content. A counter alone would reuse stale products after any in-place mutation. |
| (b) Cheap rolling fingerprint at emit, full hash only on mismatch | Rejected as a primary gate. Any fingerprint that is sound over every copied field *is* the description hash (same reads, same bytes), so it does not remove the hash cost, and it adds a collision surface the exact comparison does not have. The gate reuses the retained node as the comparison target instead of carrying a second fingerprint. |
| (c) Make the reused path genuinely cheap by verifying the retained state | Chosen, extended with the exact structure-sequence gate. The audit below closes the `description_hash` gaps the same investigation found. |

There is no fingerprint accumulation at emit, so a changed node pays exactly
what it paid in Phase 1 for emission. The only new cost on a changed node is
the gate's rejection prefix: kind, layout style, paint inputs, and label/text,
in that order (measured below).

## What the reused path now skips

For an exact match on an existing node:

| Work | Phase 1 (on reuse) | Phase 2 |
|---|---|---|
| `description_hash` (strings, spans, sidecar styles, ~70 mixes) | every pass | skipped |
| `layout_hash` / `layout_percent_width_pending_hash` | every pass | skipped (retained hash stays valid) |
| `measure_input_hash` + `measure_input_observe` | every pass | skipped |
| `paint_hash` | every pass | skipped |
| `copy_node_description` (~60 field writes, 4 owned strings, site, spans, style sidecars, computed-style invalidation, text-run decision, composition clear, caret reset, disabled side effects) | every pass | skipped |
| `mark_dirty` + reason bookkeeping | every pass | skipped |
| `layout_measure_mark_dirty` | when measurement changed | skipped |
| `mark_layout_ancestors` | when layout changed | skipped |
| `queue_paint` / presentation output dirty | when paint changed | skipped |
| `semantic_sync_node` for a node with no role, no published entity, and no explicit semantic id | every pass | skipped |
| structure bucket maps (`desired`, `reused_roots`, `buckets`, `bucket_indices`, `processed_parents`), retirement scan, `same_children` per parent | every pass | skipped when the emitted sequence matches |

Still performed on the fast path, because they are descriptor- or
interaction-dependent and cheap:

- `style_environment_with_accessibility` (struct build) and the exact
  environment comparison; a changed theme, density, text scale, accent, or
  accessibility bundle always takes the copy path.
- Semantic publication/removal for nodes that have a role, have published an
  entity, or carry an explicit semantic id, using the same code copy runs.
- `restore_apply_description_request`, region-index membership, pointer-hit
  shape, retained grid tracks, `computed_styles` pruning, `node.active`,
  `node.present`, and `node.region_cached`.
- Scroll-focus presentation policy comparison and commit.

## Field audit: gate versus `copy_node_description`

The gate compares, in this order:

1. `kind`, `label`, `text`, `key`, `explicit_key`, `tooltip_text`,
   `tooltip_delay_ms`, `parent`, `icon_id`, `font`, `text_style`, `site`,
   `identity_key`, `identity_key_u64`, `identity_key_numeric`,
   `identity_key_kind`, `identity_key_pair`.
2. Effective `text_paint_spans` and `text_style_spans` (content, not hash).
3. `style`, `placement`, `style_scope_boundary`, `layout_boundary_axes`,
   `style_environment` (against the resolved next environment), `adaptive_*`,
   `button_content_style`, `button_variant`, `button_presentation`, `color`,
   `color_theme_resolved`, `paint_background`, `paint_value`, `control_*`,
   `region_revision`, `region`, `text_input_target`,
   `text_selection_background`, `visual_row_*`, `semantic_id`, `drag_*`,
   `drop_target_*`, grid fields, `context_menu_bounds`, `surface_*`,
   `scroll_*`, `layout_scroll_offset_*`, `split_*`.
4. Derived retained values: `focusable`, `disabled`, `selected`,
   `text_interaction`, `text_interaction_show_caret`, interaction anchors,
   cleared `text_input_area`, `surface_resource_generation` for
   `Custom_Surface`, retained text run reaching a non-text product, active text
   composition on a non-text product, expected `drop_position`, and the
   disabled-state runtime ownership clears.
5. Retained product/sidecar state: motion owner absence, semantic surface
   style, visual part style, and scroll-focus presentation.
6. `semantic_published`, `has_semantic_surface`, and `has_visual_part` node
   stamps so the descriptor tail and sidecar lookups are skipped only when they
   are provably empty. The measurement observation is intentionally *not*
   consulted: an unchanged description implies an unchanged input hash, and an
   uninitialized observation cannot make a retained product stale.

### `description_hash` coverage audit

The audit compared every field `copy_node_description` writes against the four
typed product hashes (`description_hash`, `layout_hash`, `paint_hash`,
`measure_input_hash`) and the grid configuration hash. Findings:

| Field | Covered before Phase 2 by | Action |
|---|---|---|
| `region` membership | nothing | **added to `description_hash`** (region index ownership and `region_cached` are description products) |
| `semantic_id` | nothing | **added to `description_hash`** (semantic publication identity is a description product) |
| `scroll_line_height`, `scroll_line_width` | nothing | **added to `description_hash`** (scrollbar geometry and line stepping; absent from `layout_hash`) |
| `grid_row/column/span`, `grid_item`, `grid_align_*`, `context_menu_bounds`, `split_position`, `split_min/handle/hit` | `layout_hash` | no change; layout invalidation is the product gate |
| `focusable`, `selected`, `disabled` | `paint_hash` | no change |
| `color`, `paint_background`, `paint_value`, `control_*`, `visual_row_*`, `text_interaction*`, `surface_*`, `scroll_*`, `icon_id`, `font`, `tooltip_*`, spans, `style_environment` | `description_hash` | no change |
| text metrics, overflow, weight, size, spans, `style.width/height/min/max`, button content | `measure_input_hash` | no change |
| `layout_scroll_offset_*`, `scroll_content/viewport_*`, `scroll_axes`, `scrollbar_policy`, `parent`, `placement`, `adaptive_*` | `layout_hash` | no change |
| `site`, `key`, `explicit_key`, `identity_key*`, `drag_source_*`, `drop_target_*` | nothing (and no visual/semantic product of their own) | compared exactly by the gate; deliberately not hashed to keep changed-node hashing cheap |

The three hash extensions cost five mixes on a changed description (a few
nanoseconds) and close the only gaps that had no other typed product gate. The
gate itself compares all of the above exactly, so the skip never depends on
hash coverage.

## Correctness coverage

`runtime/description_reuse_test.odin` adds ten tests (runtime suite 471 -> 481):

| Test | What it pins |
|---|---|
| `test_description_reuse_exact_match_skips_retained_work` | A third identical pass takes the gate for both nodes and leaves zero measure requests, layout visits, paint updates, semantic property changes, dirty stages, queued paint, or text-run destruction; the retained hash, text, and reason are unchanged. |
| `test_description_reuse_rejects_every_copied_field` | 67 field families (label, text, tooltip, icon, font, text style, spans, all layout style fields, placement, color, paint/control values, region, semantic id, surface, scroll, split, grid, context-menu bounds, text interaction, visual row, drag/drop, adaptive, identity, key, site, button style, style environment) each defeat the gate, and the node returns to exact reuse afterwards. |
| `test_description_reuse_changed_field_refreshes_products` | Changed text re-copies, re-measures, and repaints; a paint-only color change reaches the node and repaints. |
| `test_description_reuse_theme_change_refreshes_every_node` | A registered theme swap forces the themed nodes through the copy path, updates the retained environment, repaints, and returns to exact reuse on the next identical themed frame. |
| `test_description_reuse_font_change_refreshes_text_products` | Changing the font role defeats the gate and rebuilds the retained text product generation. |
| `test_description_reuse_retirement_clears_the_stamp` | Omitting a node retires it and frees its stamp; re-describing the identity creates a fresh node that reports no exact reuse and is measured. |
| `test_description_reuse_structure_sequence_is_exact` | An identical emitted sequence skips the structure diff; a keyed reorder reconciles child order; an insert reconciles membership. |
| `test_description_reuse_retained_matches_fresh_runtime` | Fresh-equivalence oracle: an eight-step churn sequence on the retained runtime is compared every step against a runtime rebuilt from scratch, by finalized paint display list (content, order, geometry, resources; text-run handles excluded), semantic snapshot, and public node info. |
| `test_description_reuse_mutations_match_fresh_runtime` | Every one of the 67 audited field mutations produces the same finalized paint display list and semantic snapshot as a runtime built from scratch with that mutation, catching both stale reuse and a dropped copy field. |
| `test_description_hash_covers_region_semantics_and_scroll_line_metrics` | The three hash extensions above stay sensitive to their fields. |

`testui/scratchpad_scene_test.odin` additionally asserts that a scroll turn
reports exact-match reuses through `Turn_Work`.

## Paired measurement

Both arms are the same source, same machine, same session, five runs per
scenario and backend, 24 description passes per run, warmup excluded. The
"before" arm is `-define:ALICORN_DESCRIPTION_REUSE=0`; the only code difference
is the gate (the retained sequence array is still maintained in both arms, so
the A/B cannot attribute its bookkeeping to the gate).

### Description p50/p95/p99, median of five runs (ms)

Raw data:
[`before`](raw/issue-229-phase2-description-reuse-2026-11-21/before-scratchpad-summary.csv)
and
[`after`](raw/issue-229-phase2-description-reuse-2026-11-21/after-scratchpad-summary.csv)
medians, plus the per-run
[`before`](raw/issue-229-phase2-description-reuse-2026-11-21/before-scratchpad-runs.csv)
and
[`after`](raw/issue-229-phase2-description-reuse-2026-11-21/after-scratchpad-runs.csv)
stage rows and counter rows. `scratchpad-summary.md` in each arm is the
harness's own complete render.

| Scenario | Backend | before p50 | before p95 | before p99 | after p50 | after p95 | after p99 | p95 delta |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| typing | SDL_GPU | 0.398 | 0.504 | 0.576 | 0.312 | 0.401 | 0.448 | **-20.3%** |
| typing | D3D12 | 0.402 | 0.519 | 0.576 | 0.292 | 0.363 | 0.400 | **-30.1%** |
| typing | Vulkan | 0.398 | 0.500 | 0.515 | 0.261 | 0.380 | 0.383 | **-24.0%** |
| scroll | SDL_GPU | 0.342 | 0.414 | 0.426 | 0.263 | 0.327 | 0.364 | **-20.9%** |
| scroll | D3D12 | 0.344 | 0.435 | 0.477 | 0.225 | 0.303 | 0.307 | **-30.4%** |
| scroll | Vulkan | 0.343 | 0.417 | 0.446 | 0.245 | 0.302 | 0.342 | **-27.7%** |
| selection | SDL_GPU | 0.334 | 0.386 | 0.407 | 0.263 | 0.338 | 0.371 | **-12.4%** |
| selection | D3D12 | 0.348 | 0.431 | 0.444 | 0.230 | 0.308 | 0.322 | **-28.5%** |
| selection | Vulkan | 0.284 | 0.429 | 0.443 | 0.237 | 0.289 | 0.324 | **-32.6%** |
| resize | SDL_GPU | 0.321 | 0.549 | 0.638 | 0.267 | 0.534 | 0.589 | -2.8% |
| resize | D3D12 | 0.351 | 0.573 | 0.603 | 0.183 | 0.521 | 0.627 | -9.1% |
| resize | Vulkan | 0.351 | 0.542 | 0.641 | 0.231 | 0.493 | 0.625 | -9.1% |
| tabs | SDL_GPU | 0.274 | 0.414 | 0.439 | 0.255 | 0.337 | 0.346 | **-18.5%** |
| tabs | D3D12 | 0.338 | 0.403 | 0.451 | 0.247 | 0.289 | 0.318 | **-28.3%** |
| tabs | Vulkan | 0.323 | 0.432 | 0.486 | 0.257 | 0.311 | 0.333 | **-27.9%** |
| churn | SDL_GPU | 0.699 | 0.919 | 0.968 | 0.680 | 0.862 | 0.915 | **-6.2%** |
| churn | D3D12 | 0.762 | 1.010 | 1.030 | 0.655 | 0.839 | 0.916 | **-16.9%** |
| churn | Vulkan | 0.714 | 0.976 | 1.050 | 0.693 | 0.916 | 0.985 | **-6.1%** |
| idle (startup pass) | SDL_GPU | 0.201 | 0.201 | 0.201 | 0.128 | 0.128 | 0.128 | **-36.1%** |
| idle (startup pass) | D3D12 | 0.196 | 0.196 | 0.196 | 0.136 | 0.136 | 0.136 | **-30.8%** |
| idle (startup pass) | Vulkan | 0.205 | 0.205 | 0.205 | 0.150 | 0.150 | 0.150 | **-26.6%** |

Every scenario and backend is neutral or faster. Resize is the weakest win
because its pass is dominated by layout (0.15 ms of a 0.55 ms pass), not by
description products.

### Typing stage attribution, p95 before -> after (ms)

| Stage | SDL_GPU | D3D12 | Vulkan |
|---|---:|---:|---:|
| description | 0.504 -> **0.401** | 0.519 -> **0.363** | 0.500 -> **0.380** |
| reconcile_hash | 0.036 -> 0.081 | 0.039 -> 0.064 | 0.037 -> 0.072 |
| reconcile_copy | 0.122 -> **0.009** | 0.127 -> **0.009** | 0.113 -> **0.009** |
| structure_diff | 0.018 -> **0.000** | 0.018 -> **0.000** | 0.018 -> **0.000** |
| measure | 0.047 -> 0.042 | 0.051 -> 0.049 | 0.051 -> 0.048 |
| layout | 0.001 -> 0.001 | 0.002 -> 0.001 | 0.001 -> 0.001 |
| semantic_sync | 0.020 -> 0.020 | 0.020 -> 0.019 | 0.021 -> 0.019 |
| paint | 0.009 -> 0.009 | 0.009 -> 0.008 | 0.008 -> 0.009 |
| application_build | 0.192 -> 0.191 | 0.200 -> 0.185 | 0.189 -> 0.182 |
| reconcile_other | 0.061 -> 0.053 | 0.067 -> 0.052 | 0.064 -> 0.049 |

`reconcile_hash` is the *replacement* cost: it now measures the exact
comparison for unchanged nodes plus the real hash for changed ones. For typing
that is 0.045 ms of comparison against 0.113 ms of removed copy and 0.018 ms of
removed structure work. The bucket the founder targeted (copy + hash +
structure) went from 0.176 ms to 0.090 ms p95 on SDL_GPU.

### Retained-work counters, median of five runs (after arm)

| Scenario | Backend | emitted | reused | exact-match | structure matches | measure misses | paint visits | persistent allocs | scratch allocs |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| typing | SDL_GPU | 3,588 | 3,566 | 3,566 | 23 | 22 | 22 | 564 | 1,383 |
| typing | D3D12 | 3,519 | 3,497 | 3,497 | 23 | 22 | 22 | 655 | 1,383 |
| scroll | SDL_GPU | 3,588 | 3,588 | 3,588 | 23 | 0 | 0 | 189 | 437 |
| scroll | D3D12 | 3,519 | 3,519 | 3,519 | 23 | 0 | 0 | 280 | 437 |
| resize | SDL_GPU | 3,672 | 3,658 | 3,650 | 22 | 46 | 179 | 862 | 1,284 |
| churn | SDL_GPU | 3,588 | 2,048 | 2,048 | 23 | 1,628 | 1,738 | 9,719 | 7,246 |

Scratchpad allocation counts did not grow with the gate: the comparison allocates
nothing, persistent allocation counts are unchanged (typing 564, scroll 189,
resize 862, churn 9,719 on SDL_GPU - identical before and after), and scratch
allocation calls *fall* because the structure-diff bucket maps and child lists
are no longer built (typing 2,809 -> 1,383, scroll 1,863 -> 437, churn 8,672 ->
7,246 over the measured window).


## High-churn control

The new `churn` scenario rewrites the content of every realized row in place,
mutates every minimap bar height, and advances the command field and active tab
on every step. The retained strings keep their address and length, so a
pointer-identity shortcut would miss the change. Median reuse over five runs is
2,048 of 3,588 descriptions (~57%), i.e. ~43% of described nodes change on every
pass, several times any other scenario.

| Stage (p95 ms) | SDL_GPU | D3D12 | Vulkan |
|---|---:|---:|---:|
| description | 0.919 -> 0.862 (-6.2%) | 1.010 -> 0.839 (-16.9%) | 0.976 -> 0.916 (-6.1%) |
| reconcile_hash | 0.035 -> 0.060 | 0.036 -> 0.057 | 0.037 -> 0.064 |
| reconcile_copy | 0.145 -> 0.064 | 0.137 -> 0.066 | 0.127 -> 0.069 |
| structure_diff | 0.016 -> 0.000 | 0.017 -> 0.000 | 0.018 -> 0.000 |
| measure | 0.192 -> 0.231 | 0.223 -> 0.210 | 0.200 -> 0.225 |
| layout | 0.174 -> 0.197 | 0.187 -> 0.176 | 0.191 -> 0.189 |
| paint | 0.045 -> 0.040 | 0.045 -> 0.041 | 0.052 -> 0.043 |

There is **no measurable regression**. The changed nodes pay the rejection
prefix (kind, style, paint inputs, label/text) and then the ordinary hash and
copy path; the unchanged 57% still skip copy, hash, and dirty work, and the
exact sequence still skips the structure diff. The hash bucket rises by
0.02-0.03 ms while copy and structure lose 0.07-0.10 ms. `measure` and `layout`
are unchanged by this work and moved in both directions between the arms
(+20% SDL_GPU, -6% D3D12, +13% Vulkan), which bounds this pair's session noise
at roughly that magnitude; the churn result should be read as "no regression",
not as a claimed speedup.


## Honest scaled expectation for Scratchpad

The fixture describes about 156 nodes at 960x640; the real Scratchpad frame
builds about 393 nodes across two passes. Phase 1 measured the fixture's
description-reuse bucket at 0.169 ms of a 0.477 ms typing pass (35%), while the
real application's whole runtime step is 8.4-9.1 ms p95.

Phase 2 removes 20.3% of the fixture's typing description p95 on the reference
backend (0.504 -> 0.401 ms, -0.103 ms absolute). Scaling the *runtime* saving
per described node to 393 nodes is proportionally ~0.26 ms per turn
(0.66 us/node), i.e. ~3.0% of the real 8.4-9.1 ms step. With the backend spread
(D3D12 -0.156 ms, Vulkan -0.120 ms at 156 nodes) the honest band is
**~0.25-0.40 ms per Scratchpad description pass, about 3-4.5% of the step**.
That is the whole honest claim:

- The Phase 1 ~35% figure is the *synthetic typing workload's* bucket, not 35%
  of a real Scratchpad frame.
- The real frame also pays application build (~39% of the fixture pass) and
  after-frame work that the runtime cannot skip; even a perfect runtime would
  not remove them.
- The founder's 4-5 ms p95 CPU frame-build target therefore still depends on
  application-side work; Phase 2 contributes the runtime share it owns.

## Suites

| Suite | Result |
|---|---|
| `odin test runtime` | 481/481 pass (471 before, 10 new) |
| `odin test testui` | 31/31 pass |
| `odin test ui` | 57/57 pass |
| `odin test theme` | 37/37 pass |
| `odin test native\sdl_gpu` | 169/169 pass |
| `odin test renderer\cpu` | 23/23 pass |
| `odin build tests` | pass |

The repository `tools\test.ps1` wrapper still stops earlier in this environment
at the external AccessKit native UIA contract check, exactly as recorded in the
Phase 1 baseline; the suites were executed individually with the same AccessKit
compiler arguments.

## Reproduction

```powershell
# Paired arms from one source tree.
.\tools\bench_scratchpad_workload.ps1 -Odin C:\odin\odin.exe `
  -Runs 5 -Frames 24 -DescriptionReuse 0 -OutputDir out\phase2-before
.\tools\bench_scratchpad_workload.ps1 -Odin C:\odin\odin.exe `
  -Runs 5 -Frames 24 -DescriptionReuse 1 -OutputDir out\phase2-after

# The new high-churn arm alone.
.\out\phase2-after\workload_matrix.exe --smoke --smoke-hold-ms=800 `
  --backend=sdl-gpu --workload=scratchpad --interaction=churn --frames=24
```

## Limits

- CPU wall time only; no GPU execution, scanout, or visible latency.
- One Windows machine, one Odin build, one scene shape. Backend differences are
  inside run-to-run noise; do not compare across machines.
- The fixture remains an attribution fixture: it models Scratchpad's
  composition, not its full application state or worker activity.
- The fixture's realized editor range collapses to two rows after the first
  layout pass in the smoke harness (pre-existing; identical in both arms), so
  the high-churn arm changes the minimap, tree, field, and tab nodes in
  addition to the realized editor rows rather than relying on a dense editor
  window.
- `ALICORN_DESCRIPTION_REUSE=0` keeps the retained sequence bookkeeping the
  gate needs; it is a control arm, not a byte-identical reconstruction of the
  Phase 1 binary. The committed Phase 1 baseline is the cross-revision anchor.
