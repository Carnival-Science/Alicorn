# Sparse application updates and authoring cost (issue #190)

This report answers a narrow question: when one live control changes, which
stage pays, and how does that change with the number of live controls? It
measures three Alicorn authoring modes that produce the same final UI and the
same final retained geometry:

- **root** — every application change calls `invalidate_root`; the describe
  function re-emits every row.
- **region** — every row is a stable keyed `region_begin`/`region_end` with one
  application-owned revision. A row change bumps that revision and invalidates
  the row key.
- **app** — a purposefully hand-optimized path. Every row has a shell region
  plus label and action sub-regions, with separate shell, label, and action
  revisions.

The fixture is CPU/headless and source-visible:
[`benchmarks/diagnostics/issue190_sparse_updates.odin`](../../benchmarks/diagnostics/issue190_sparse_updates.odin).
It is deliberately separate from the native presentation work owned by #168 and
from startup attribution owned by #172.

## Environment and method

Measured on 2026-11-21 from the `finish-190` branch at
`c562a328215d63b8f9b6bf67c4053fb86df0b927` on:

| Pin | Value |
| --- | --- |
| OS | Microsoft Windows NT 10.0.19045.0 |
| CPU | AMD Ryzen 5 7600X 6-Core Processor |
| Compiler | `C:\odin\odin.exe` dev-2026-11-nightly:08539cd |
| Build | `-o:speed -collection:alicorn=.` |
| Viewport | 1280 x 900 logical |
| Theme | registered two-variant theme; colors only |
| Samples | 24 fresh runtimes per (mode, size, scenario) |
| Live controls | 100, 1,000, 3,000 rows (one label + one button each) |
| Virtual leg | 100,000 logical rows, 21 realized rows in a 400-unit viewport |
| Raw capture | [`raw/issue-190-sparse-updates-windows-2026-11-21.txt`](raw/issue-190-sparse-updates-windows-2026-11-21.txt) |

The SHA is the base revision of the working tree used for measurement; the
fixture, runner, report, and raw capture are committed together in the child
commit on the same branch.

Every sample creates a fresh runtime, mounts the fixture, settles retained work,
applies exactly one scenario, and destroys the runtime. Mode order alternates
forward/reverse between samples. Each scenario is compared against a fresh
runtime that describes the same final application state, using only public
queries: node identity/bounds, semantic snapshots and values, retained text line
geometry, focus, a paint-command summary (bounds, clip, colors, text-span
ranges) at every size, and the inspector's style/paint projection at the
smallest size. A separate cross-mode check mounts all three modes and compares
an identity-free semantic projection and owner-free paint summary, so equal
semantics and visual output are checked directly.

The first sample of each scene also polls 200 idle `begin_frame` calls and
requires zero stage visits, zero node creation/retirement, zero tracked
allocations, and zero GPU submissions.

Wall values are p50/p95 milliseconds (ms) unless a value is explicitly
microseconds (µs) or nanoseconds (ns). Stage columns are deterministic work
counters, not wall time.

Reproduce:

```powershell
.\benchmarks\diagnostics\issue190_sparse_updates.ps1 -Odin C:\odin\odin.exe -Samples 24
```

## Authoring edges

`authoring_edges` at 3,000 rows, from the raw capture:

| Mode | Revisions per row | Total revisions | Region keys | Invalidation call |
| --- | ---: | ---: | ---: | --- |
| root | 0 | 1 global | 0 | `invalidate_root` |
| region | 1 | 3,001 | 3,000 | per changed row |
| app | 3 | 9,001 | 9,000 | per changed sub-region |

The issue estimated "~2N+1" revisions for the app mode. The exact source-visible
model needs **3N+1**: a shell revision (row style/selection/width), a label
revision (label text), and an action revision (button selected state), plus one
application revision. They cannot be merged without losing update precision: a
width change must not rebuild the button, and a selection change must rebuild
the action region without rebuilding the label.

A nested-region reachability edge is also required. A child region is not
visited while its enclosing shell region is reused, so an app-mode label change
must **also** clear the shell cache. The fixture does that by calling
`invalidate_region(shell_key, current_shell_revision)`: a valid call at the
current revision, not a new revision edge. This is real authoring bookkeeping
that the three-revision table does not show.

All three modes retain the same **6N+4** nodes: row root, background surface,
label wrapper, label text, action wrapper, and button. In root/region mode the
label and action wrappers are plain containers; in app mode they are regions.
That keeps semantics, geometry, paint output, mount work, and memory directly
comparable instead of giving the region modes a structural advantage.

## Headline results at 1,000 live controls

### Wall time

| Scenario | root p50/p95 | region p50/p95 | app p50/p95 |
| --- | ---: | ---: | ---: |
| initial mount | 38.945 / 41.862 | 39.606 / 47.394 | 39.785 / 46.455 |
| one label change | 8.980 / 10.511 | **1.478 / 1.595** | 1.681 / 1.929 |
| identical-value write | 8.957 / 9.529 | **0.0002 / 0.0004** | **0.0002 / 0.0004** |
| hover move | 1.681 / 1.780 | 1.645 / 1.846 | 1.713 / 1.858 |
| two-row selection | 9.997 / 10.747 | **2.438 / 2.840** | 2.831 / 3.595 |
| one-row width change | 9.196 / 12.079 | **1.745 / 2.072** | 1.838 / 2.217 |
| reorder + insert + remove | 16.887 / 18.319 | **9.279 / 10.524** | 9.519 / 11.154 |
| broad theme change | 2.916 / 4.078 | 2.900 / 3.848 | 2.969 / 3.706 |
| destroy | 4.875 / 7.060 | 4.878 / 5.415 | 4.969 / 5.031 |

The virtualized leg (100,000 logical rows, 21 realized; scroll one page down and
back) measured 0.973 / 1.037 ms (root), 0.974 / 1.090 ms (region), and
0.985 / 1.165 ms (app).

### Deterministic stage counts at 1,000 rows

`emit` is application descriptions emitted in the measured update; `skip` is
regions skipped; `measure`, `layout`, `paint`, and `compose` are stage visits;
`display` is finalized commands / full passes.

| Scenario | mode | api µs | emit | skip | measure | layout | paint | compose | display |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| mount | root | 0.1 | 6,004 | 0 | 2,002 | 12,007 | 6,004 | 7,003 | 7,003 / 1 |
| mount | region | 0.1 | 6,004 | 0 | 2,002 | 12,007 | 6,004 | 7,003 | 7,003 / 1 |
| mount | app | 0.1 | 6,004 | 0 | 2,002 | 12,007 | 6,004 | 7,003 | 7,003 / 1 |
| label | root | 0.9 | 6,004 | 0 | 1 | 0 | 1 | 1 | 1 / 0 |
| label | region | 117.6 | 1,009 | 999 | 1 | 0 | 2 | 2 | 2 / 0 |
| label | app | 337.4 | 1,008 | 1,000 | 1 | 0 | 2 | 2 | 2 / 0 |
| no-op | root | 0.9 | 6,004 | 0 | 0 | 0 | 0 | 0 | 0 / 0 |
| no-op | region | 0.2 | 0 | 0 | 0 | 0 | 0 | 0 | 0 / 0 |
| no-op | app | 0.2 | 0 | 0 | 0 | 0 | 0 | 0 | 0 / 0 |
| hover | root | 1,053.1 | 0 | 0 | 0 | 0 | 2 | 7,003 | 7,003 / 1 |
| hover | region | 1,019.7 | 0 | 0 | 0 | 0 | 2 | 7,003 | 7,003 / 1 |
| hover | app | 1,072.7 | 0 | 0 | 0 | 0 | 2 | 7,003 | 7,003 / 1 |
| selection | root | 1.0 | 6,004 | 0 | 0 | 0 | 4 | 7,004 | 7,004 / 1 |
| selection | region | 205.0 | 1,014 | 998 | 0 | 0 | 6 | 7,005 | 7,005 / 1 |
| selection | app | 636.3 | 1,012 | 1,000 | 0 | 0 | 8 | 7,006 | 7,006 / 1 |
| width | root | 0.9 | 6,004 | 0 | 2 | 2,013 | 2 | 2 | 2 / 0 |
| width | region | 118.1 | 1,009 | 999 | 2 | 2,013 | 2 | 2 | 2 / 0 |
| width | app | 182.2 | 1,007 | 1,001 | 2 | 2,013 | 2 | 2 | 2 / 0 |
| reorder | root | 4.2 | 6,004 | 0 | 1,996 | 11,977 | 5,982 | 7,003 | 7,003 / 1 |
| reorder | region | 206.2 | 1,019 | 997 | 1,996 | 11,977 | 5,982 | 7,003 | 7,003 / 1 |
| reorder | app | 335.4 | 1,015 | 1,001 | 1,996 | 11,977 | 5,982 | 7,003 | 7,003 / 1 |
| theme | root | 363.1 | 0 | 0 | 0 | 0 | 6,003 | 7,006 | 7,006 / 1 |
| theme | region | 364.8 | 0 | 0 | 0 | 0 | 6,003 | 7,003 | 7,003 / 1 |
| theme | app | 362.9 | 0 | 0 | 0 | 0 | 6,003 | 7,003 | 7,003 / 1 |

Mount and destroy are node-count-dominated. At 3,000 rows all modes retain
18,004 nodes and track about 160 MB of requested runtime bytes; at 1,000 rows
they retain 6,004 nodes and track about 48.6 MB. These are runtime-tracked
requested bytes, not process RSS or GPU memory.

## Slopes: does a local update touch O(1), O(visible), or O(all live)?

This is the central result. The stage names below are the stage that actually
grows; a cheap retained stage is not the same as a cheap application
description.

| Scenario | root slope | region slope | app slope | What grows |
| --- | ---: | ---: | ---: | --- |
| initial mount | 41.9 µs/row | 41.8 µs/row | 41.7 µs/row | description + reconcile + layout + paint |
| one label change | 10.52 µs/row | 1.71 µs/row | 1.98 µs/row | application description headers + reconcile; region-key invalidation |
| identical-value write | 10.37 µs/row | ~0 | ~0 | root cannot know the write was identical |
| hover move | 2.46 µs/row | 2.43 µs/row | 2.46 µs/row | composition/display finalization (full pass) + input routing |
| two-row selection | 12.06 µs/row | 3.36 µs/row | 4.05 µs/row | description headers + reconcile + invalidation + composition |
| one-row width change | 10.89 µs/row | 2.04 µs/row | 2.10 µs/row | layout (all rows) + description headers |
| reorder/insert/remove | 20.43 µs/row | 12.41 µs/row | 12.64 µs/row | description + reconcile + layout + paint + compose |
| broad theme change | 4.78 µs/row | 4.78 µs/row | 4.81 µs/row | paint + composition; style scan |
| destroy | 6.49 µs/row | 6.44 µs/row | 6.61 µs/row | node teardown |
| virtual scroll (100k logical) | O(visible) | O(visible) | O(visible) | only realized rows |

Slopes are `(p50 at 3,000 - p50 at 100) / 2,900`.

### Per-scenario stage attribution

1. **Initial mount** — every stage is O(all live) and effectively identical in
   all three modes: 125.3 / 125.0 / 124.7 ms at 3,000 rows, with the same 18,004
   retained nodes and ~160 MB tracked live bytes. Region boundaries do not help
   when every body must run, and the app mode no longer pays a node-count
   penalty because the root/region wrappers match its sub-region containers.

2. **One changed label** — description and reconciliation are **O(all live) in
   all three modes**. Root emits 6N+4 descriptions; region and app still emit
   N+9/N+8 region headers because every unchanged row must be re-listed for the
   reconciler to know it still exists. Only the changed row's body is rebuilt:
   999/1,000 regions are skipped at 1,000 rows, and 2,999/3,000 at 3,000.
   Measure, layout, paint, composition, and display finalization are O(1) or
   O(visible) because the label box is fixed and only one text command changes.
   The region/app invalidation call itself is O(all retained nodes):
   `invalidate_region` resolves a key by scanning the retained-node map.
   Region pays one scan (0.55 ms at 3,000); app pays two (label key plus
   enclosing shell key, 1.42 ms). That makes app about 16% slower than region
   (5.87 ms vs 5.07 ms at 3,000), despite finer-grained bodies.

3. **Identical-value write** — region and app return to true idle in ~0.2 µs
   with zero descriptions, stage work, and allocations. Root pays the full 6N+4
   description (30.6 ms at 3,000) because `invalidate_root` cannot know the
   value was unchanged. The runtime genuinely cannot know; this is an
   application-model responsibility.

4. **Hover move** — description, reconcile, measure, and layout are exactly
   zero in every mode. Paint visits two nodes. **Composition pays O(all live):**
   the display list takes a full finalization pass (21,003 commands at 3,000
   rows, `display_full=1`) to repaint two targets. The measured input-routing
   API cost is also O(all live) (3.23-3.29 ms at 3,000). The paint stage is
   cheap; the composition stage is not.

5. **Two-row selection** — region and app skip 998/1,000 or 1,000/1,000
   regions, but still emit O(N) headers and reconcile O(N) headers. Paint visits
   4-8 nodes, yet composition again takes a full pass. API invalidation is
   O(all nodes) per key scan; app's four scans (two rows x shell+action) cost
   2.78 ms at 3,000, about 23% of its total update.

6. **One-row width change** — **layout pays O(all live)** in all modes (2,013
   visits at 1,000; 6,013 at 3,000). A width change in one row invalidates the
   column's cross-axis placement, so every row is re-laid out. Region and app
   avoid re-describing unchanged bodies and keep composition incremental
   (2 finalized commands); root re-emits everything but composition is still
   incremental because only one row's paint geometry changes. Region is the
   cheapest mode (6.05 ms at 3,000) but the layout stage still scales with all
   live rows.

7. **Reorder + insert + remove** — structure is a global change. Every mode
   pays O(all live) description, reconciliation, layout, paint, and
   composition. Region's header-only bodies still help (36.6 ms vs root's
   60.2 ms at 3,000); app is essentially tied with region (37.3 ms) because its
   extra invalidation scans are offset by rebuilding only 3 nodes per moved row
   instead of 5. Node creation/retirement is O(1) (6/6 nodes for every mode).

8. **Broad theme change** — description, reconcile, measure, and layout are
   zero; the mode is irrelevant to the update kind. `style_theme_replace` scans
   and queues every retained node, then paint visits every node and composition
   takes a full display pass: paint and composition are O(all live) (~14.1 ms
   at 3,000 for all modes).

9. **Destroy** — teardown is O(all live) for all modes (~19 ms at 3,000). All
   tracked runtime bytes return to zero; at 1,000 rows one destroy performed
   54,124 / 54,124 / 56,124 tracked frees and released 48.7 / 48.7 / 48.8 MB.
   `nodes_retired` stays zero because destroy frees the retained map directly
   instead of retiring subtrees through reconciliation.

10. **Virtualized scroll (100,000 logical rows)** — the only leg with a cheap
    application boundary: ~124-129 descriptions, ~124-129 reconcile visits, and
    257 layout visits for 21 visible rows, independent of the 100,000 logical
    count. The virtual list retires/creates only realized rows (120 nodes per
    page step) and returns to true idle after the round trip.

### Conclusion

No manual mode makes application description O(changed). Region and app reduce
the **constant** of the description/reconcile work and skip unchanged bodies,
but every unchanged row still needs a header. The stages that can still be
O(all live) for a one-row change are:

- the application description headers and retained reconciliation;
- the key-based invalidation scan;
- layout when intrinsic/cross-axis geometry changes;
- composition/display finalization when more than one paint command changes;
- paint and composition for a broad theme change;
- everything for a structural change.

The virtualized leg shows the shape a truly local authoring API would need:
the application emits only the visible/changed items, and all stages follow the
realized set.

## Correctness and the fresh-runtime oracle

All scenarios in the committed capture report `status=PASS` with
`gpu_submits=0`. The oracle compares the live runtime after the update against a
fresh runtime mounted from the same final application model:

- public node identity, bounds, and text line count/geometry for representative
  rows; semantic snapshot (role, label, value, state, bounds, tree order) for
  every row; focus; a paint-command summary including bounds, clip,
  surface/text/icon colors, and text-span ranges at every size; and the
  inspector's style/paint projection at the smallest size (100 rows).

Cross-mode parity also passes at every size:

```text
cross_mode_visual n=100 status=PASS paint_commands=703 semantic_nodes=200
cross_mode_visual n=1000 status=PASS paint_commands=7003 semantic_nodes=2000
cross_mode_visual n=3000 status=PASS paint_commands=21003 semantic_nodes=6000
```

The identical-value case is asserted structurally too: region and app build
zero frames and emit no descriptions; root builds a frame and emits 6N+4.

### Incidental theme-text finding

The fixture's theme scenario uses explicit text colors because the fresh-runtime
oracle exposed a real paint-only theme limitation: a plain `Text` node's paint
color is resolved from the style environment during description and stored on
the retained node. `style_theme_replace` recomputes recipes and semantic
surfaces but does not recompute that description-resolved color. The committed
probe records:

```text
theme_text_probe status=stale before=0.900,0.930,0.970 after=0.900,0.930,0.970
expected=0.980,0.920,0.860
note=description_resolved_text_color_is_not_recomputed_by_paint_only_replacement
```

This is a concrete wrong-but-valid case in the #106 class: the theme ID and
revision are valid, the replacement is accepted, and the retained tree is
"correct" by its own description, yet fresh output differs. A live theme editor
must re-describe text or use explicit/token-resolved text colors. It is recorded
as an observation, not as a benchmark failure, because the sparse-update fixture
isolates explicit text colors.

Fixed on master in issue #219: the per-node replacement walk now recomputes
description-resolved text ink, so this fixture's probe reports
`theme_text_probe status=updated`. The capture above remains pre-fix evidence.

## True idle

Every scenario that still had a runtime (all but destroy) polled 200
`begin_frame` calls after settling: `idle_frames=200`, zero descriptions, zero
stage visits, zero node creation/retirement, zero tracked allocations, and
`gpu_submits=0`. Region and app mode's identical-value scenario is the strongest
form of the same result: the first `begin_frame` already returns false.

## Real application symptom

The in-repo consumers show the bookkeeping this benchmark models:

- [`tests/fixtures/crucible/main.odin:11`](../../tests/fixtures/crucible/main.odin#L11)
  keeps a `revision: u64` per track and
  [`main.odin:29`](../../tests/fixtures/crucible/main.odin#L29) keys a meter
  region by `track.revision`, bumping it at
  [`main.odin:71`](../../tests/fixtures/crucible/main.odin#L71). The region key
  itself is the constant `"meter"` under a per-track key scope, so a targeted
  `invalidate_region("meter", ...)` would resolve every live meter instance;
  the fixture instead uses `invalidate_root` at
  [`main.odin:20`](../../tests/fixtures/crucible/main.odin#L20).
- [`tests/main.odin:387`](../../tests/main.odin#L387) keeps a
  `revisions: []u64` parallel to the item order and calls
  `region_begin(..., "item", revisions[key])` inside a stable key scope. The
  app owns the order/enabled/revision arrays and must keep all three aligned;
  the runtime observes none of them.
- [`runtime/invalidation_coherence_test.odin:58-83`](../../runtime/invalidation_coherence_test.odin#L58-L83)
  is the same shape with parent/child/peer regions and explicit revision
  fields, and is the fixture that drives the #106 oracle.

Two concrete failure modes follow directly from the measurements:

1. **Stale-but-valid revisions.** A revision that is monotonic and accepted but
   not advanced with the content silently retains stale output; the runtime has
   no way to know which app memory changed. The #106 oracle exists precisely to
   catch that in tests, and
   [`docs/architecture.md:193`](../architecture.md#L193) states the contract:
   "A stale region revision can produce stale content." The app-mode label case
   adds a second edge: even a correct child revision is unreachable while the
   enclosing shell is reused, so a valid revision alone is not sufficient
   bookkeeping.

2. **Paint-only changes that are not actually fresh.** The theme text probe
   above is the live-theme version of the same symptom: an accepted,
   revision-valid replacement can leave a fresh runtime and an incremental
   runtime disagreeing. The fixture had to use explicit text colors to keep
   the theme scenario a paint-work measurement.

## Input for #189 (reactive authoring)

On this machine and fixture, explicit regions already meet a plausible
interaction budget for content updates: 1.5 ms p50 (1,000 controls) and 5.1 ms
p50 (3,000 controls) for one changed label, versus 9.0 ms and 31.0 ms for a root
rebuild. That is **not** evidence that automatic reactivity would be slower; it
is evidence that the first-order cost of the manual model is the O(N)
description/reconcile header walk and the O(nodes) key-invalidation scan, not
the changed-row body.

Record this as **NO-GO input for a new reactive runtime based on latency
alone**: at the measured sizes the existing regions are within budget, and the
hand-optimized app mode is *slower* than region mode because its extra
invalidation/reachability scans cost more than its finer bodies save. A useful
follow-up is narrower than a reactive store:

- a region handle/node-ID invalidation path that avoids the all-node key scan;
- an explicit "ancestor rebuild required" edge, or sub-regions that remain
  reachable while an ancestor region is reused;
- an authoring helper that records stable key + monotonic revision + nested
  edges without changing the runtime's explicit ownership model.

The correctness/clarity argument for #189 remains: every manual mode requires
the application to remember to advance revisions, clear enclosing shells, keep
parallel arrays aligned, and re-describe after paint-only changes that the
runtime cannot refresh. That is a developer-correctness cost, not a measured
latency win.

## Limitations

- **CPU/headless only.** The fixture measures application description, retained
  reconciliation, measurement, layout, paint, and composition. It does not
  measure native mesh/upload, GPU encode/submit, input-to-present latency, or
  real window events. Native GPU presentation belongs to #168; startup
  attribution belongs to #172.
- **Windows only.** macOS Metal was not run because no Apple hardware was
  available. No cross-platform claim follows.
- **No external zgui comparison.** Parity prerequisites could not be met:
  matching construction and live-node count, font/text work, keying model,
  viewport, animation, compiler/release options, and input scripts. Per the
  issue, no speed ranking against zgui or GPUI is published. The numbers are
  machine-specific and are not comparable to their published timings.
- **Hover is synthesized.** Pointer moves are delivered through the public
  `process_pointer` API with synthetic coordinates, not through a native window
  event loop. The measured input-routing cost is therefore an API-level lower
  bound, not a platform event cost.
- **Fixed labels and explicit text colors.** Label boxes are fixed-width and
  text colors are explicit, isolating description/reconciliation from intrinsic
  text relayout and from the theme-text limitation above. That choice is
  documented in the fixture; it is not a claim that intrinsic reflow is cheap.
- **Theme composition counters are not a strict determinism contract.**
  Paint-only theme replacement queues retained repaint work in Runtime map
  order; the composer's incremental-vs-full choice can vary in composition
  visit counts between otherwise identical runs. The fixture records the
  minimum and prints a warning if it observes variation; visual correctness is
  still checked against the fresh runtime.
- **Retained bytes are runtime-tracked requested bytes**, not process RSS,
  allocator overhead, or GPU residency.
- **One machine, one compiler, one run.** The raw capture is the evidence for
  this host and revision, not a performance guarantee.

## Addendum: indexed region lookup (issue #227)

The original measurement above identified key resolution inside
`invalidate_region` as an O(all retained nodes) floor under an otherwise sparse
update: 0.55 ms per key scan at 3,000 rows in region mode and 1.42 ms for the
two scans of the hand-optimized app mode. Issue #227 replaces that scan with a
maintained key-to-live-region index that reconciliation and node retirement
maintain alongside the retained tree. Resolution is now O(changed keys and
their instances).
Diagnostics, the monotonic revision contract, and multi-instance keys are
unchanged; the #106 seeded oracle and the fixture's fresh-runtime comparisons
still pass.

Both captures below are from this host and compiler on `finish-227` at base
`68d3aff6da14bba44110bcded7631e213d8fd6a0`; the after capture was taken with
the #227 working-tree patch applied. Only the invalidation path changed.

| Raw capture | File |
| --- | --- |
| Before | [`raw/issue-227-region-index-before-windows-2026-11-21.txt`](raw/issue-227-region-index-before-windows-2026-11-21.txt) |
| After | [`raw/issue-227-region-index-after-windows-2026-11-21.txt`](raw/issue-227-region-index-after-windows-2026-11-21.txt) |

### Lookup improvement

`api_p50_ns` is the fixture's timed invalidation block; it excludes description,
reconciliation, and frame work. Ratios are before/after.

| Scenario | 1,000 rows before → after | 3,000 rows before → after | Improvement at 3,000 |
| --- | ---: | ---: | ---: |
| one label change, region | 130.1 → 2.7 µs | 595.2 → 3.4 µs | 175x |
| one label change, app (label + shell) | 345.5 → 4.3 µs | 1,471.6 → 5.2 µs | 283x |
| two-row selection, region | 223.3 → 4.2 µs | 968.9 → 5.6 µs | 173x |
| two-row selection, app (four keys) | 660.8 → 6.5 µs | 2,782.4 → 7.9 µs | 352x |
| reorder + insert + remove, region | 226.2 → 7.5 µs | 1,009.5 → 13.8 µs | 73x |
| reorder + insert + remove, app | 346.4 → 7.6 µs | 1,484.5 → 13.6 µs | 109x |

The reorder rows still show a small growth because the scenario invalidates the
moved rows one key at a time and also pays for creating/retiring those regions;
the cost is now per changed region, not per retained node.

End-to-end totals are dominated by the unchanged O(all live) description and
reconciliation header walk that #227 explicitly does not modify. At 3,000 rows
the one-label-change total p50 was 5.535 → 5.670 ms (region) and 6.191 → 5.719
ms (app); the app mode now no longer pays a scan premium for its finer bodies.
Two-row selection measured 10.450 → 10.328 ms (region) and 12.650 → 10.072 ms
(app). Single-run wall totals include normal machine variance and are not the
primary evidence; the invalidation stage is the measured change.

### Index memory overhead

The fixture reports runtime-tracked persistent requested bytes at mount
(`alloc_live_delta`). The index contributes one map entry and one small node
list per distinct live region key, plus one persistent copy of the key:

| Mount | Before bytes | After bytes | Index delta | Per live key | Index allocations |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1,000 rows, region (1,000 keys) | 48,567,470 | 48,819,886 | +252,416 | ~252 B | +2,009 |
| 1,000 rows, app (3,000 keys) | 48,600,470 | 49,190,110 | +589,640 | ~197 B | +6,010 |
| 3,000 rows, region (3,000 keys) | 159,823,054 | 160,399,694 | +576,640 | ~192 B | +6,010 |
| 3,000 rows, app (9,000 keys) | 159,922,054 | 162,051,038 | +2,128,984 | ~237 B | +18,012 |

The cost scales with live region keys, not with total retained nodes: at 3,000
rows every mode retains 18,004 nodes, while region mode adds ~0.58 MB (0.36% of
tracked live bytes) and app mode adds ~2.13 MB (1.33%) for its three keys per
row. The two allocations per key are the owned key string and the node list.
Entries are released when the last instance under a key retires; the fixture's
destroy leg still returns tracked live bytes to zero and the retirement test
asserts the same under a tracking allocator.

### Maintenance cost

Mount pays for creating the entries, and reorder pays for moving only the
changed regions:

| Scenario | Added index allocations | Live-byte change |
| --- | ---: | ---: |
| mount 3,000 lane, region | +6,010 (2 per key) | +0.58 MB |
| mount 3,000 lane, app | +18,012 (2 per key) | +2.13 MB |
| reorder + insert + remove 3,000, region | +2 | none |
| reorder + insert + remove 3,000, app | +10 | none |

Re-describing an existing region under an unchanged key only deduplicates its
index entry and does not allocate. Mount wall-time samples described the same
18,004-node retained tree and stayed within run variance (region 135.2 → 124.5
ms, app 140.8 → 128.1 ms at 3,000 rows).
Destroying the runtime additionally releases the index entries: the destroy leg
measured 19.246 → 19.784 ms (region) and 19.493 → 21.306 ms (app) at 3,000 rows
while still reporting zero tracked live bytes after teardown.

The maintained index is also cross-checked by a bounded consistency helper in
`runtime/region_index_test.odin`: seeded randomized sequences of describe,
invalidate, retire, and reorder actions assert that the index is consistent and
that index resolution returns exactly the node set of the old linear scan at
every step. An opt-in `ALICORN_REGION_INDEX_VALIDATION` debug define runs the
same check at the end of reconciliation for local diagnosis; it is compiled out
by default and is never on the invalidation hot path.

## Addendum: sparse display finalization milestone (issue #228)

This addendum records the first bounded step of
[issue #228](https://github.com/Carnival-Science/Alicorn/issues/228): a
per-subtree **display range splice** for repainted nodes that emit more than one
paint command. Before this change the sparse path only handled a node with
exactly one command, so a default button hover (surface, text, optional icon)
forced the entire display list to finalize.

The fixture, runner, and scenario definitions are unchanged from the #190
capture above. The before capture is base commit `49541f3`; the after capture is
the same tree with this change applied, committed together with this addendum.
Raw captures:

- [before](raw/issue-228-sparse-finalization-before-windows-2026-11-21.txt)
- [after](raw/issue-228-sparse-finalization-after-windows-2026-11-21.txt)

### Implemented splicing rules

The sparse path now finalizes a contiguous run instead of one slot:

1. `Node.display_index` identifies the first command the node's own paint
   contributes to `display_target`. A node's own commands are composed
   contiguously before its descendants and local scrollbar chrome, so the
   implementation scans that owner run to recover the old range length.
2. The repaint must produce **exactly the same command count**. Count-changing
   repaints fall back, which keeps every later node's `display_index` valid and
   avoids an O(tail) index fixup.
3. The node's inherited translation, opacity and clip are recomputed from its
   top-level root (O(depth)) and the node's current paint is composed with the
   same helper the full compositor uses.
4. Every recomposed command is validated against the slot it replaces:
   inherited opacity, translation and clip must match exactly. Bounds are the
   node's own painted geometry and may legitimately change (a slider fill, for
   example); a clipping node additionally validates its own bounds because
   descendants inherit that clip.
5. Only then are the target slots replaced and finalized in place. If any
   validation fails, the full path runs and the update is counted as an
   incremental fallback.
6. A node that contributed no display commands before or after the repaint (a
   non-painting layout container during a theme replacement) is skipped instead
   of forcing a rebuild.

### Results

Deterministic composition visits and display finalization deltas, from the raw
captures (root / region / app modes; all modes now agree):

| Scenario | Rows | Compose before | Compose after | Finalized before | Finalized after | Full passes before | Full passes after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| hover move | 1,000 | 7,003 / 7,003 / 7,003 | **2** | 7,003 | **4** | 1 | **0** |
| hover move | 3,000 | 21,003 | **2** | 21,003 | **4** | 1 | **0** |
| two-row selection | 1,000 | 7,004 / 7,005 / 7,006 | **4 / 6 / 8** | 7,004 / 7,005 / 7,006 | **6 / 8 / 10** | 1 | **0** |
| two-row selection | 3,000 | 21,004 / 21,005 / 21,006 | **4 / 6 / 8** | 21,004 / 21,005 / 21,006 | **6 / 8 / 10** | 1 | **0** |
| one-row width | 1,000 | 2 | 2 | 2 | 2 | 0 | 0 |
| reorder + insert + remove | 1,000 | 7,003 | 7,003 | 7,003 | 7,003 | 1 | 1 |
| broad theme | 1,000 | 7,008 / 7,004 / 7,004 | 7,003 | 7,008 / 7,004 / 7,004 | 7,003 | 1 | 1 |
| broad theme | 3,000 | 21,004 / 21,003 / 21,003 | 21,003 | 21,004 / 21,003 / 21,003 | 21,003 | 1 | 1 |

Hover and selection composition is now independent of live row count: two
paint visits finalize four and six-to-ten commands respectively at both 1,000
and 3,000 rows. The label, identical-write, width, virtual-scroll, mount, and
destroy legs are unchanged.

Wall time (p50 / p95 milliseconds, region mode unless noted):

| Scenario | Rows | Before | After |
| --- | ---: | ---: | ---: |
| hover move | 1,000 | 1.73 / 2.04 | **1.03 / 1.13** |
| hover move | 3,000 | 8.41 / 9.98 | **3.04 / 3.27** |
| two-row selection | 1,000 | 2.43 / 2.84 | **1.59 / 1.82** |
| two-row selection | 3,000 | 9.88 / 11.09 | **5.20 / 5.94** |
| broad theme | 1,000 | 2.91 / 3.51 | 3.07 / 4.35 |
| broad theme | 3,000 | 14.53 / 15.44 | 14.71 / 16.49 |

The virtual 100,000-row leg remains O(visible) and unchanged
(148 composition visits, one full pass for the scrolled structure).

### Remaining full-pass conditions

These update classes intentionally still call `rebuild_display` (or the full
`layout_finalize_display`):

- **Structure and order changes** — node creation/retirement, reorder, and
  overlay insertion/removal keep the existing `rebuild_order` /
  `composition_rebuild` path. The #190 reorder leg is unchanged.
- **Command-count changes** — a repaint whose command count differs from the
  retained range falls back. Examples: a focus outline appearing, a checkbox
  gaining its checkmark command, selection paint that adds/removes a product.
- **Changed ancestor presentation** — a clip, translation or opacity change
  detected by the per-command validation falls back instead of aliasing stale
  geometry.
- **Retained backdrop boundaries** — while any live node carries a
  `Backdrop_Effect_Paint` marker, the range splice is disabled because the
  effects compositor captures a prefix of the display list. The counter is
  released on retirement.
- **Transient overlays** — drag previews and tooltips present during the
  update, and any active drag, keep the full path.
- **Motion-owned nodes** — motion presentation frames set
  `composition_rebuild` as before; analytic motion is not yet range-spliced.
- **Scale changes** — `set_presentation_scale` re-finalizes the whole display
  from unsnapped targets.
- **Scroll-region nodes themselves** — their composed range includes
  scrollbar chrome, so the node is not spliced directly; descendants that are
  not themselves scroll regions still splice when their validated clip and
  translation are unchanged.
- **Bulk repaints covering most of the display** — the implementation forces
  one full pass when at least 64 nodes are queued and `queued * 8` is at least
  the display length. One linear pass is faster than per-node ancestor
  validation in that regime, and the work remains proportional to the changed
  content. Broad theme replacement is the canonical case at 1,000+ rows. Small
  windows with all nodes repainted still take the sparse path.

Correctness is pinned by `runtime/sparse_display_test.odin`, which compares
every sparse result byte-for-byte against a forced full
`layout_finalize_display` for hover, selection, same-length text edits, theme
replacement, a 120-operation seeded randomized sequence, and the fallback
classes above. `runtime/retained_locality_test.odin`'s former multi-command
slider assertion now asserts the same-count range splice instead of a full
rebuild. True idle (200 frames) remains free of paint, composition and
finalization work.

## Addendum: count-changing sparse splices (issue #228 milestone 2)

Milestone 1 spliced only **same-count** ranges: a focus ring, a checkbox
checkmark or another repaint that added or removed a command still called
`rebuild_display`. Milestone 2 splices those count changes while the work left
behind the changed range stays bounded, so the bottleneck does not move from
composition to memmove plus index fixup.

The fixture, runner, and scenarios are unchanged. The before capture is the
milestone-2 base commit `acb9555` (milestone 1 already merged); the after
capture is the same tree with this change applied, committed together with this
addendum. Raw captures:

- [before](raw/issue-228-sparse-finalization-m2-before-windows-2026-11-21.txt)
- [after](raw/issue-228-sparse-finalization-m2-after-windows-2026-11-21.txt)

### Tail policy

After a repaint the retained run is `[display_index, display_index + old_count)`
and `delta = new_count - old_count`. With

```text
tail_commands = len(display_target) - (display_index + old_count)
```

the update splices only while

```text
tail_commands <= max(256, 8 * abs(delta))
```

The absolute floor keeps small windows on the sparse path; the eight-command
slope keeps the moved tail proportional to the changed range. A larger tail
takes milestone 1's bulk shape: one linear full pass that composes every tree
and finalizes every command, recorded as an incremental fallback. This is the
same trade the milestone-1 bulk policy makes for broad repaints, applied to the
tail of one count-changing node.

### Index fixup

`display_index` is by definition the slot of a node's first owned display
command. The fixup therefore walks the **moved tail commands**, not the retained
tree: two passes over `[tail_start, len(display_target))` mark every owner whose
first command sits at that slot, then publish `index + delta`. Its cost is
O(tail commands), the same bound as the memmove and the policy above, and it
needs no ordered-tree or order-position sidecar. The two passes prevent a scroll
region's later scrollbar run from shifting its owner twice.

A DFS from `top_level` would also visit only the tail nodes, but it first has to
*locate* the splice node: for a late node in a flat list that means scanning the
preceding siblings, which is O(all live) exactly when the tail is empty and the
splice is cheapest. Scanning the moved commands is strictly bounded by the
policy and matches the memmove it already pays for.

The moved commands are copied verbatim and never re-finalized. Snapping is
per-command (`layout_finalize_paint_command` rounds bounds and clip only), so a
position shift cannot change their device geometry.

### What splices, what stays bulk

- **Splices**: count changes on a visible node whose inherited presentation is
  neutral (no ancestor clip/translation/opacity and no motion surface color) and
  that is not itself a clipping node. Covered examples: focus ring appearing or
  disappearing, checkbox checkmark added or removed, container background
  gained or lost.
- **Zero-count edges**: `N -> 0` removes the run and resets `display_index` to
  the `-1` zero-command sentinel; `0 -> N` anchors insertion at the first
  command anywhere in the node's subtree (the node's own commands precede its
  descendants). A node with no command-bearing descendant has no anchor and
  takes the full pass.
- **Still bulk**: transient overlays (drag preview/tooltip are appended after
  every top-level tree and re-appended by `rebuild_display`, so a splice must
  not move them), live backdrop boundaries, `Scroll_Region` nodes, clipping
  nodes with a count change, non-neutral inherited presentation, structure and
  order changes, and any tail over the policy.

### Measured cost

The #190 fixture has no focus/checkmark scenario, so its deterministic counters
and wall time are the no-regression check rather than the count-change evidence.
The scenarios that were sparse stay sparse and the bulk theme leg still takes
one full pass; counters are identical before and after:

| Scenario (region mode) | Rows | Compose visits | Finalized | Full passes | Wall p50 before → after |
| --- | ---: | ---: | ---: | ---: | ---: |
| hover move | 1,000 | 2 | 4 | 0 | 1.066 → 1.089 ms |
| hover move | 3,000 | 2 | 4 | 0 | 2.985 → 3.408 ms |
| two-row selection | 1,000 | 6 | 8 | 0 | 2.043 → 1.826 ms |
| two-row selection | 3,000 | 6 | 8 | 0 | 6.486 → 5.992 ms |
| broad theme change | 1,000 | 7,003 | 7,003 | 1 | 4.370 → 4.108 ms |
| broad theme change | 3,000 | 21,003 | 21,003 | 1 | 18.932 → 18.062 ms |

Single-run wall values move with normal machine variance (hover at 3,000 rides
on the unchanged input-routing cost); the deterministic stage counts are the
evidence that this change does not disturb the existing sparse classes.

The dedicated micro-benchmark lives in `runtime/sparse_display_test.odin` and
prints `SPARSE_M2_BENCH` / `SPARSE_M2_BENCH_LATE` counters (`odin test runtime`).
Counts are deterministic; wall values are one host/compiler run and are
machine-specific. Each update toggles focus, which is one shrink splice and one
grow splice; the 400-button leg toggles only the last node, whose tail is empty.

| Case | Splice update p50 | Full-rebuild p50 | Internal splice ns/update | Bytes moved/update | Tail nodes/update | Tail commands/update |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 8 rows, middle button focus toggle | 16.2 µs | 28.8 µs | 8,458 | 13,034 | 38 | 50 |
| 400 buttons, last button focus toggle | 10.0 µs | 528.0 µs | — | 0 | 0 | 0 |

Internal splice time is the new `display_splice_elapsed_ns` counter (validation
and paint recomposition excluded). In the 8-row case the two splices move about
13 KB and shift 38 node runs in 8.5 µs, roughly 29% of the same update's full
rebuild; the rest of the update is paint and finalization that both paths pay.
In the 400-button case the changed node is last, so the tail is empty:
`display_splice_tail_nodes` is exactly zero, the fixup does no work, and the
update costs 10.0 µs instead of 528.0 µs for the same change. The fixup is
therefore never the new bottleneck: its work is bounded by the same policy that
admits the splice, and it disappears when the tail does. (Repeat runs on the
same host varied by under 10%; the splice/full split was stable.)

The large-tail direction is also pinned: focusing the **first** of 400 buttons
adds a ring, computes a tail of roughly 1,200 commands, exceeds
`max(256, 8*4)`, increments `display_splice_tail_rejections`, and takes exactly
one full display pass instead.

### Correctness

The test oracle is now stronger than milestone 1's. `sparse_display_test.odin`
snapshots `display`, `display_target` and every node's `display_index`, forces a
complete `rebuild_display`, compares all three, and restores the incremental
state. Every randomized operation (now including focus toggles, checkbox
toggles, and zero-to-one background changes) is therefore checked against a true
full composition and index rebuild, not just a re-finalization. Focus
grow/shrink, checkbox grow/shrink, zero-count grow/shrink, late-node splice,
large-tail fallback, and overlay fallback have dedicated tests.

All suites are green on this tree: `odin test runtime` 465 tests (seven new over
the 458 pre-change suite on this branch), `odin test ui` 57, `odin test theme`
37, `odin test renderer/cpu` 23, and the `tests` executable passes.
