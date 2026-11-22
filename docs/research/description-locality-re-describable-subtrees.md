# Description locality: re-describable subtrees (issue #231)

Date: 2026-11-21

Status: research record for sequencing item 2 (pilot keyed regions in
Scratchpad) and item 3's option evaluation. Measured A/B:
[scratchpad-region-pilot-windows-2026-11-21](../benchmarks/scratchpad-region-pilot-windows-2026-11-21.md).
Pilot patch:
[raw/scratchpad-region-pilot-windows-2026-11-21/pilot-region-diff.patch](../benchmarks/raw/scratchpad-region-pilot-windows-2026-11-21/pilot-region-diff.patch).

## Finding

Alicorn's keyed regions work as specified on real Scratchpad, and they move
the metric they are supposed to move: during a 24-character editor burst the
pilot describes **741 instead of 858 nodes per character (-13.6%)**, skips
**six region bodies per character** (two regions times three description
passes), and reduces the whole runtime description stage from **1.664 ms to
1.546 ms per character (-7.1%)**. Cumulative host application build falls
**-6.24%** over ten matched pairs.

They do **not** improve the nine-action command sequence: application build is
**-0.73%**, sequence-attributed build **+2.66%**, and the pilot adds one extra
description pass on the close-README step. The command workload is dominated
by document open/close and editor description, and the pilot's settle guard
pays an extra pass when layout changes.

The authoring burden is real and larger than the API shape suggests:
**560 added / 31 removed lines across seven files** for four regions, five new
app fields, and a new 67-line revision helper. The hard part is not
`region_begin`; it is proving the revision covers every input the body reads,
including three classes that are easy to miss: **application-polled widget
results**, **retained geometry from the previous frame**, and **virtualized
scroll windows**. Each class is a correctness trap, not a performance
trade-off.

Recommendation: **GO for opt-in regions on expensive, relatively static
subtrees whose inputs can be enumerated and whose bodies are pure**; **NO-GO
for treating regions as the general answer to description locality in
Scratchpad's command workload**, and no-go for converting the remaining ~350
`invalidate_root` sites without per-region measurement and review.

## Mechanism map

The runtime never calls application procedures. `begin_frame` returns
`(ui, should_build)`, and the host calls the application's describe entry.
Emission is an incremental pending list, then `end_frame` reconciles it
against the retained tree.

| Stage | Locality before #231 | What a region changes |
| --- | --- | --- |
| Invalidation lookup | O(changed keys) after #227 | unchanged |
| Measurement | Partial | skipped descendants keep measurement cache entries |
| Layout | Partial (#230 m1) | region container is laid out; descendants keep prior geometry |
| Paint | Localized | descendants are not repainted unless retained state changed |
| Display finalization | Partial (#228 m1+m2) | fewer described nodes reach the display list |
| GPU resources | Localized | unchanged |
| **Application description** | **O(all live)** | **the region body procedure does not run; control returns at `region_begin`** |

Two distinct reuse mechanisms now exist:

1. **Region reuse (this issue).** `region_begin(key, revision)` emits one
   container. If the retained region node is cached and its revision equals
   the supplied revision, it appends a single `Reuse_Subtree` marker and
   returns `reused = true`; `region_ex` calls `body()` only when not reused.
   The application pays one container emit per region and everything outside
   regions. Work inside the body is not merely cheapened: it does not execute.
2. **Phase 2 exact-description reuse (#229).** After the application has
   emitted a node, reconcile compares it to the retained description and can
   skip the copy/hash/structure work for byte-identical re-emits. The
   application still emits everything. On the same Scratchpad typing burst
   phase 2 reported 855/858 exact matches and about -10% cumulative app build;
   the pilot removes the emits that phase 2 then had to re-check.

The two compose: the pilot's 741 emitted nodes are 738 exact retained matches
(99.6%), so phase 2 still skips the runtime copy for nearly all of the smaller
description. Region reuse is strictly earlier: it removes application work
before phase 2 can see it.

### What "skips the application subtree procedure" means precisely

- The body's **emissions** are skipped, including all widget calls, text
  shaping requests, `drop_target` registrations, and per-frame node-id cache
  assignments.
- The body's **side effects are skipped**, including state mutations, lazy
  page loads, focus restoration, and action polling.
- Retained nodes keep their IDs, geometry, interaction state, and paint. The
  region container itself is re-emitted every frame.
- `invalidate_region` does not re-enter the application. It marks the live
  region instances uncached at a monotonic revision and calls
  `invalidate_root`; the next `begin_frame` runs the full describe callback,
  and regions whose revision did not change are skipped at their
  `region_begin` calls.

## Scratchpad candidate map and side-effect inventory

Verified against Scratchpad `adb28fc220864e6809c9217e4437af5b92dae57b`.
The pilot patch is in the benchmark raw directory.

| # | Site | Revision chosen | Why this revision | Side-effect inventory |
| --- | --- | --- | --- | --- |
| 1 | Document tab strip (`scratchpad_workbench_group_tabs_build`, compact titlebar path only) | Monotonic generation over the prepared tab items plus non-item inputs: view ids/order, labels, tooltips, selected/dirty/preview, semantic ids, width/height, find/floating/theme/search state, tab drag state, reduced-motion, activation/focus, retained tab-bar viewport width/offset | `backend.state.revision` is too broad: it changes on editor text and would rebuild the strip on every keystroke. The prepared item projection plus retained geometry is the narrowest correct input set. | `app.document_connected_tab_node` was written per frame; hoisted to `document_connected_tab_node_region_cache` and restored outside the region. `scratchpad_document_tabs_reorder_motion` and `tab_bar` action returns are application-polled; drag/motion and activation state are in the revision. |
| 2 | Sidebar workspace tree (`build_workspace_tree`) | Generation over `workspace_tree_projection_revision` (already monotonic), aliKit `model.revision`, realized scroll offset and viewport height, active document path/highlight, truncation, session restore token, themes, accessibility, activation/focus | The projection hash is the data identity, but the virtual list only describes visible rows, so the realized window is also an input. | `app.tree_scroll_owner` was written per frame; restored from `workspace_tree_state.scroll_node` on reuse. `drop_target` stays retained. Session focus restore and `workspace_tree_apply_event` are skipped on reuse and their inputs are in the revision. Row flattening and the projection hash still run outside the region every frame. |
| 3 | Pinned references (`pinned_surface_build`) | Generation over snapshot epoch/revision/generation/total rows/range identities and statuses, backend pinned epoch/revision, loaded page windows, height-index shape, editing/selection/focus/restore state, width/scale/scroll viewport, theme/material, DPI, accessibility; the frame counter is mixed while a pin is edited | The pinned surface is a variable-height virtual list with bounded page loads and an inline editor. While editing, per-keystroke editor state is not cheaply digestible, so the region intentionally rebuilds every frame. | All bookkeeping (`clear` of controls/targets, `owner`, `focus_target`, width/scale, index reset, page loads, text-input target registration, anchor nodes) is inside the body; on reuse the retained registrations remain. This is the most fragile candidate. |
| 4 | Quick Open result slot (`quick_open_build`, results section only) | Generation over query, index generation, loading/ready/error/truncated, retained path count, selected index, result-scroll offset/viewport, theme/accessibility, activation/focus | The query field is outside the region. The result list depends on the filter output identity and the virtualized window. | `app.quick_open_results_scroll_node` persists across reuse. `quick_open_text_change` and `quick_open_move_selection` now call `invalidate_region("scratchpad-quick-open-results", generation)` instead of `invalidate_root`; the generation is advanced before invalidation so the next describe computes the same value. `quick_open_filter` and the footer count still run outside. |

### Conditional existence

Every pilot region is created only when its surface exists:

- tab strip: only when the compact titlebar has at least one visible tab;
- tree: only after `has_workspace` and a root directory index exist;
- pinned: only when the pinned pane is built (it may be absent or a side
  pane);
- Quick Open results: only inside the open modal.

Conditional existence is handled outside the region. The region key appears
and disappears with the surface; on the first description of a new instance
the body runs. No body decides whether the region exists.

### Interaction and motion are the hidden input class

`tab_bar`, aliKit tree rows, Quick Open result rows, and pinned buttons report
interaction through return values or events consumed **inside the describe
body**. A reused body never observes them. The pilot therefore includes:

- `rt.activation_node` and `rt.activation_sequence` (pointer/keyboard
  activation pending consumption),
- `rt.focused` and `rt.focus_visible`,
- app drag state (`workspace_drag_kind/target/position/source` and motion-reset
  flags),
- aliKit `model.revision` for tree focus/selection,
- reduced-motion and accessibility preferences.

This is conservative: any pending activation anywhere rebuilds the strip, so a
click elsewhere can cost one extra strip description. It is the minimal
correct input without adding a new runtime dependency-tracking API.

## Option evaluation for sequencing item 3

### (a) Today's regions used properly

Residual after region reuse: top-level control flow, one container emit per
region, signature computation, non-region code, reconcile/layout/paint of the
region container and its retained descendants, and the application's own
non-region description.

Measured residual on the pilot typing burst:

- application describe window (`build_ns`, app callback only): flat
  (19.296 -> 19.638 ms over 24 characters; pair changes are noisy and one
  candidate pair contains a 29.5 ms first-character stall);
- whole runtime description stage (counters, begin_frame to end_frame):
  1.664 -> 1.546 ms per character (-7.1%);
- known residual outside regions: the editor row/window description and the
  app describe prologue, which dominate the callback; in the command
  sequence, document open/close work dominates.

Verdict: (a) is a real, measurable win for the workload it targets, but the
residual is dominated by non-region code in the command sequence. The
signature computation itself is small (hashing tens of items/rows per frame),
but the layout-settle guard can add a whole extra description pass on
structure changes, which is visible in the sequence result.

### (b) Per-region describe re-entry

The runtime would invoke a registered body procedure only for invalidated
regions, with identity/parent/scope context. This would remove the top-level
control flow and the non-region code between regions, but it conflicts with
ordinary Odin composition:

- top-level conditionals decide whether a region exists at all;
- dynamic membership and ordering are expressed by the surrounding code;
- shared state and local variables are not addressable from a separately
  registered procedure;
- the body would need a parallel registration path and a way to reconstruct
  parent/identity/scope context without the surrounding call stack.

It also does not address the harder problems found by the pilot: revision
completeness, interaction polling, and last-frame geometry. Verdict: not
justified by this evidence. The residual control flow is small compared with
the body and runtime work.

### (c) Generalize phase 2 toward generation-verified emitted snapshots

Skipping the emit itself by comparing app-declared inputs would require the
framework to know the inputs of arbitrary ordinary Odin code. That is a
reactive system: observation of arbitrary memory or mandatory dependency
declarations, with conflicts against conditional composition, dynamic
membership, and predictable execution. This remains out of scope, and the
pilot does not create evidence that would justify reopening it.

## Pilot design

### Revision pattern: monotonic generation over a signature

Region revisions must be monotonic. Natural Scratchpad inputs are hashes,
node ids, counts, and scroll offsets: equal means "same output", but the
values can go down. The pilot adds one small app-side helper
(`frontends/alicorn/region_revisions.odin`):

```odin
Region_Generation :: struct {
    signature:  u64,
    generation: u64,
    seeded:     bool,
}

region_generation_next :: proc(state: ^Region_Generation, signature: u64) -> u64
region_generation_peek :: proc(state: ^Region_Generation) -> u64
```

`region_generation_next` advances the generation exactly when the signature
changes and returns the stable generation otherwise. `region_generation_peek`
is used only by tests to model a forgotten bump. Hashing helpers mix strings,
bools, and f32 bit patterns.

This is the reusable pattern for any non-monotonic revision source. It does
not replace the discipline of listing inputs; it only makes the revision
monotonic.

### Side-effect hoisting

Two values were written from inside region bodies and read outside them:

- `app.document_connected_tab_node`: reset to 0 at the top of the frame and
  consumed by the connected-titlebar open-edge link and tests. The body now
  writes `document_connected_tab_node_region_cache`; the wrapper restores it
  on both the reused and rebuilt paths. The retained selected-tab node id is
  stable while the strip is cached because the revision covers every
  structure/selection input.
- `app.tree_scroll_owner`: consumed by keyboard and pointer handlers. The
  wrapper restores it from `workspace_tree_state.scroll_node` on reuse.

The Quick Open result scroll node and pinned owner remain valid for the same
reason (structure and window inputs are in their revisions).

### Stale-output guard (#106 failure mode)

The pilot adds two tests to Scratchpad's frontend suite:

- `test_region_generation_is_monotonic_and_changes_only_with_the_signature`
  pins the generation contract, including zero signatures.
- `test_forgotten_region_bump_leaves_stale_output_detectable_via_public_queries`
  describes a keyed region whose text depends on app state, mutates the state
  **without bumping**, and proves via `regions_skipped` and
  `text_node_line_count` that the old text is retained. Bumping the revision
  then re-measures. This is the Scratchpad-side stale-output guard.

All 259 Scratchpad frontend tests pass on the pilot source. Alicorn's #106
coherence oracle (`runtime/invalidation_coherence_test.odin`) remains the
runtime-level guard for wrong-region invalidation.

## Measured results

Full protocol, environment, and CSVs are in the benchmark report and raw
directory. Both arms are the same Scratchpad source and the same Alicorn
master; only the pilot diff differs.

### Typing burst, ten matched pairs

| Metric | Plain p50 (p95) | Pilot p50 (p95) | Paired median |
| --- | ---: | ---: | ---: |
| Cumulative app build | 59.821 (61.31) | 56.920 (58.81) | **-6.24%** |
| App describe window (`typing_build_ns`) | 19.296 (20.67) | 19.638 (25.58) | -0.66% |
| Setup (open + settle) | 6.891 (7.75) | 6.706 (7.31) | -2.74% |
| Post-burst tail | 4.975 (5.61) | 5.003 (5.63) | +0.87% |
| Process CPU | 2,000.00 (2,156.25) | 1,937.50 (1,984.38) | -3.20% |
| Peak working set (MiB) | 323.69 (324.02) | 323.55 (323.76) | -0.02% |

Pair changes for cumulative app build: `+15.8, -8.3, -3.8, -7.2, -3.9, -8.3,
-7.2, -0.7, -9.3, -5.3` (eight of ten negative; the positive pair contains a
candidate 29.5 ms first-character stall).

Per-character counters (medians over characters 1-23, seven primary
processes):

| Counter | Plain | Pilot |
| --- | ---: | ---: |
| Emitted nodes per character | 858 | **741 (-13.6%)** |
| Reused (exact phase-2 matches) | 855 | 738 |
| `regions_skipped` per character | 0 | **6** |
| Runtime description stage | 1.664 ms | **1.546 ms (-7.1%)** |
| Reconcile stage | 0.867 ms | 0.748 ms (-13.7%) |

The app describe callback (`build_ns`) is flat because most of its time is the
application's own prologue and editor-row description, not the skipped tab
strip/tree emit. The runtime description stage, which includes reconcile and
layout over the smaller description, shows the node reduction. This is the
opposite decomposition from phase 2's result and is why both windows are
reported.

### Nine-action sequence, ten matched pairs

| Metric | Plain p50 (p95) | Pilot p50 (p95) | Paired median |
| --- | ---: | ---: | ---: |
| Cumulative app build | 30.397 (31.75) | 30.366 (33.27) | -0.73% |
| Sequence-attributed build | 17.543 (19.63) | 18.427 (20.49) | **+2.66%** |
| Largest single app build | 7.919 (9.37) | 7.604 (9.32) | -1.17% |
| First application submission | 17.633 (26.81) | 17.655 (39.06) | +2.78% |
| Process CPU | 734.38 (781.25) | 781.25 (906.25) | +9.57% |
| Peak working set (MiB) | 310.70 (312.62) | 310.39 (311.71) | -0.34% |

Per-step build (p50, ms): step 0 +3.9%, 1 +1.8%, 2 -0.3%, 3 -29.3%,
4 -7.4%, 5 +1.9%, 6 -29.3%, 7 **+11.7%**, 8 +6.9%. Step 7 (close README)
shows the settle cost directly: the pilot runs six description passes versus
five. The diagnostic capture also showed four versus two passes when closing
Quick Open (step 4), because removing a region and settling the strip can
trigger more than one extra pass; the ten-pair A/B capture reports four passes
in both arms there, so that pass count is unstable at this sample size. The
command sequence still does not produce a reliable improvement, as in the
#229 phase-2 capture, but now the reason includes a pilot-specific extra pass
rather than only "the copy bucket is small".

### Sequence counters (three diagnostic pairs)

`regions_skipped` is 0 in the plain arm at every step and **36 total across
the nine pilot steps** (2-9 per step). Emitted totals are 3,763 plain versus
3,516 pilot, but they are confounded by extra passes in steps 4 and 7.
Description-stage totals are 30.148 ms plain versus 28.180 ms pilot (-6.5%),
and reconcile 11.172 versus 10.353 ms. Composition visits rise 0.284 -> 0.313
ms because the four region containers are additional composed nodes.

## Authoring burden

The pilot is intentionally small and complete; it is the unit of burden to
extrapolate from.

| Item | Value |
| --- | --- |
| Files touched | 7 (5 existing, 2 new) |
| Lines added / removed | **560 / 31** |
| New app state | 4 `Region_Generation` fields + 1 hoisted `Node_ID` cache |
| New helper code | 67 lines (`region_revisions.odin`) |
| New tests | 99 lines, 2 tests |
| Converted invalidations | 2 (`quick_open_text_change`, `quick_open_move_selection`); the other converted sites invalidate through their revision change at describe time |
| Untouched `invalidate_root` sites | ~350 remain; no blanket conversion |
| Per-region cost | 68-135 lines including signature, comments, and side-effect handling |

### Revision discipline rules a developer must follow

1. **List every input the body reads, including indirect reads.** The
   signature is the proof obligation. If a reader relies on a field, the
   field must change the revision.
2. **Never use a broad app revision when a narrower one exists.**
   `backend.state.revision` includes editor text; using it would rebuild the
   tab strip on every keystroke and erase the benefit.
3. **Fold non-monotonic inputs into a generation.** Hashes, ids, counts,
   offsets, and selected indices are equal/not-equal values, not revisions.
4. **Never reset a generation while its region node is retained.** A lower
   revision is rejected, and a reset can violate the monotonic contract.
5. **Advance the generation before `invalidate_region`.** The next describe
   must compute the same revision the invalidation used; otherwise the region
   rebuilds again (harmless but wasteful) or the invalidation is rejected.
6. **Move required per-frame side effects out of the body or make them
   cacheable.** Node-id caches, owner fields, and registrations must remain
   valid across reuse.
7. **Handle existence outside the region.** Do not decide inside the body
   whether the region exists; wrap the `region_begin` call.
8. **Include layout-derived inputs.** If the body reads last frame's measured
   size/scroll window (tab bars, virtual lists), include the retained geometry
   and expect one settle pass after structure changes.
9. **Include interaction state for polled widgets.** Return-value widgets
   (`tab_bar`, tree events, result rows) only report through the body. Include
   pending activation/focus/selection revision, or route the interaction
   through callbacks that bump the revision.
10. **Include presentation preferences that resolve during description**
    (theme, reduced motion, differentiate-without-color) when the body's
    output depends on them.
11. **Test the stale case.** A change without a bump must be observable
    through public queries; keep that test next to the region.

### Traps hit during the pilot

- **Widget results are consumed in the body.** The first design forgot pending
  activation; tab clicks and motion would be dropped on cached frames. The
  signature now includes activation/focus and drag state.
- **Tab-bar widths come from retained geometry.** The first A/B binaries were
  built before this was fixed; connected-titlebar tests caught tab widths stuck
  at their provisional first-frame values (136 instead of 180 logical px).
  The signature now includes the retained tab-bar viewport width and offset.
  The fix costs one extra description pass when the strip first settles, which
  is visible on the close-README step.
- **A virtual list's realized window is an input.** Scrolling a cached tree or
  result list would otherwise leave blank/stale rows. Scroll offset and
  viewport height are in the tree and Quick Open signatures.
- **Tests mutate state directly.** Scratchpad's Quick Open test replaces
  `quick_open_paths` without changing the index generation; the signature now
  includes the retained path count, which is also correct for same-generation
  path-set changes.
- **Cached node-id fields are read outside the body.** `tree_scroll_owner`,
  `document_connected_tab_node`, and the Quick Open result scroll node all
  needed cache/restore handling.
- **Editing is not a stable region input.** The pinned surface mixes the frame
  counter while editing; it is a deliberate no-cache mode, not an optimization.
- **The revision contract is enforced, not advisory.** A regression or a
  stale `invalidate_region` produces a diagnostic; the pilot's tests exercise
  both the correct and forgotten-bump paths.

## Invariants

A keyed region is correct only when all of these hold:

1. **Pure bodies.** No required side effect: no state mutation that another
   part of the frame reads, no lazy loading, no focus restore, no action
   dispatch that is not also an input. Cache assignments are allowed only if
   their values are restored outside on reuse.
2. **Monotonic revisions.** A revision never decreases while the region node
   is live. Non-monotonic inputs are folded into a generation.
3. **Complete input coverage.** Every direct and indirect read is represented
   in the revision, including retained geometry, scroll windows, interaction
   state, and presentation preferences.
4. **Conditional existence outside.** The region is created or omitted by the
   surrounding ordinary Odin control flow; the body does not decide.
5. **Interaction ownership.** Polled widget results need an input that changes
   when the interaction is pending, or a callback path that invalidates the
   region.
6. **No hidden ordering.** The body must not rely on running after/before a
   sibling within the same frame in a way that a skipped frame would break.

Violating (1)-(3) produces stale output; violating (4) miscounts the retained
identity; violating (5) silently drops input. The #106 coherence oracle covers
wrong-region invalidation, and the new Scratchpad test covers forgotten bumps.

## Residual cost analysis

After the four regions, what remains on a typing frame:

- application describe prologue (state capture, action/menu sync, style
  ensure, editor/scroll bookkeeping);
- editor window/row description, text shaping and measurement;
- one container emit per region and the region signature computation;
- non-region siblings: titlebar controls, sidebar header, status bar,
  connected-titlebar chrome, scrollbars, and their containers;
- runtime reconcile/layout/paint/composition for the smaller description,
  including the four region containers;
- host frame work outside the description stage.

The typing counters put this at 741 emitted nodes per character versus 858,
with the whole description stage at 1.546 ms. The command sequence's dominant
work is not in these regions: opening/closing the 5,002-line document
describes the editor and document surfaces, which remain outside every pilot
region. The pilot also adds a settle pass on structure changes because the
tab strip depends on retained geometry.

## Go / no-go criteria for broader adoption

Adopt a region when all of the following are true:

- the subtree is expensive to describe (many nodes, text shaping, or row
  projection) relative to the surrounding control flow;
- its inputs are enumerable and stable (a projection hash, a snapshot
  revision, a small set of app fields), not "most of app state";
- its body is pure or its side effects are cacheable and restored outside;
- it does not own polled interaction without an interaction input;
- it is not the dominant cost of the measured workload merely because it is
  easy to wrap.

Do not adopt when:

- the region would wrap document/editor content whose description is the real
  workload (the pilot's command-sequence result);
- the revision would need to be broad app state (editor text, whole backend
  revision);
- the body is an editor, a lazy pager, or a focus/action router with
  per-frame side effects (the pinned surface is a warning example);
- the expected saving is smaller than the cost of the signature and the extra
  settle pass.

### Recommendation

- **Keep regions opt-in and author-facing.** The mechanism works and is
  measurable; the default authoring model is unchanged.
- **Do not scale the conversion yet.** Four regions cost 560 lines and found
  three non-obvious input classes. A broader sweep should wait for an
  authoring helper that makes the input set explicit and for per-region
  instrumentation (skips plus body-time saved) so a reviewer can see the win
  per site.
- **Target static projections, not editors.** The sidebar tree and tab strip
  are reasonable candidates; the document/editor surface and the pinned
  editor-like surface are not (or need redesign: keep only the read-only projection
  inside a region and split editing/focus/action state outside).
- **Treat option (b) as unjustified and option (c) as out of scope.** The
  pilot's residual is not top-level control flow; it is the non-region
  application work and the correctness burden.
- **Measure Quick Open filtering before converting it further.** The result
  slot is converted, but the reused hooks have no query-typing step, so this
  pilot only exercises open/close. A bounded Quick Open filter burst is the
  next measurement.

## Reproduction

- [Benchmark report](../benchmarks/scratchpad-region-pilot-windows-2026-11-21.md)
- [Manifest, runners, CSVs, counters, logs, and the pilot patch](../benchmarks/raw/scratchpad-region-pilot-windows-2026-11-21/)
- [Pilot patch](../benchmarks/raw/scratchpad-region-pilot-windows-2026-11-21/pilot-region-diff.patch)
- [Issue #229 phase-2 A/B](../benchmarks/scratchpad-ab-phase2-windows-2026-11-21.md)
