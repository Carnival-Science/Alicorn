# Issue #193 — invalidation-frontier diagnostics

**Date:** 2026-11-21

**Platform:** Windows 10 Home 19045, Ryzen 5 7600X, NVIDIA RTX 2080 SUPER
(SDL_GPU D3D12/Vulkan reference backends)

**Odin:** `dev-2026-11-nightly:08539cd`

**Branch:** `codex/issue-193-invalidation-frontier`

**Status:** implementation, correctness corpus, capture-bundle evidence, and
paired release overhead proof complete.

## Decision

**GO.** All three issue gates are demonstrated:

| Gate | Result |
| --- | --- |
| A novice can locate the first incorrect or unexpectedly wide edge from a replayed trace | **Met.** The adversarial report names the invalidated region, its resolved subscribers/ancestors, the stage that produced no output, and explicitly reports the changed row as outside the declared frontier. See [Adversarial trace](#adversarial-trace). |
| Correct fixtures have unchanged counters and no continuing idle work | **Met.** The corrected run reports only the two nodes that changed, the unrelated peer is byte-identical, and the settled runtime takes zero further description passes. See [Correct fixture](#correct-fixture). |
| Release adds no per-frame work, subscriptions, scans, or diagnostic allocations | **Met.** Five paired release runs are identical field-for-field (Frame_Stats, `global_work_by_reason`, allocation counters/bytes, structure sizes). Real-GPU idle counters are identical on SDL_GPU, D3D12, and Vulkan; real-GPU D3D12/Vulkan active typing counters are identical. See [Release proof](#release-proof). |

The remaining limitation is intentional: a forgotten invalidation has no cause
to capture. The frontier answers "why did this declared work touch (or miss)
this panel?"; proving that an *omitted* request left output stale is the #106
fresh-runtime oracle's job. The adversarial fixture records both answers side
by side.

## What was added

### Capture (runtime, debug-gated)

`runtime/invalidation_frontier.odin` extends the existing cause trace with a
bounded sidecar. The trace ring remains the single source of truth for visits
and sampled nodes; the sidecar only records what the ring cannot express per
cause:

- **region request:** copied key bytes, key hash, revision; bounded
  `[8]Node_ID` subscribers and `[8]Node_ID` ancestors. Subscribers are the live
  nodes `invalidate_region` already resolved from `region_nodes`; ancestors
  walk only parent links. This adds no scan beyond the existing O(instances of
  key) resolution.
- **changed outputs:** per-stage counts (`description`, `measure`, `layout`,
  `paint`, `composite`) plus up to four changed node IDs. Hooks are placed
  where the runtime already writes a changed product: new/changed
  descriptions, changed measure outputs, `layout_updates`, `paint_updates`,
  and composite finalization/rebuilds. Visiting a stage is never counted as
  changing it.
- **fallbacks:** the `global_work_by_reason` delta observed while the cause is
  active, stored as a reason bitset plus the observed work total. The counters
  remain global; the capture only attributes their increase to the cause that
  was active when it happened.
- **root/region classification:** root requests and region requests are
  counted separately.
- All storage is fixed (`[24]` causes, `[48]` key bytes, `[8]` subscribers,
  `[8]` ancestors, `[8]` samples per trace kind). Capture allocates nothing,
  records no extra trace events, and never owns domain strings.

The gate follows the application-mutation diagnostic style:

```odin
INVALIDATION_FRONTIER_ENABLED :: ODIN_DEBUG && #config(ALICORN_INVALIDATION_FRONTIER, true)
```

Debug builds capture by default; `-define:ALICORN_INVALIDATION_FRONTIER=false`
disables it. Release builds short-circuit the gate to false, compile
`Frontier_Store` to an empty struct, and leave the hook bodies empty. The
Runtime size is byte-identical between the two release arms (37,736 bytes).

### Inspector query

`frontier_inspect(rt, cause_id)` is the novice-facing report.
`frontier_why_touched(rt, cause_id, node)` answers one node's relationship to
the declared edge. `inspect(rt)` now ends with a bounded `frontiers:` inventory,
so existing capture bundles (native `--diagnostics`, testui replay diagnostics,
and any host that stores `inspect`) include frontiers without a new artifact
format. The visual inspector Causes tab shows the same capture fields for each
recent cause.

Reports print IDs, counts, stage names, fallback reasons, and the copied
region key. They never copy ring reason strings; the local trace ring remains
the place for full local reason text.

### Test helper

`testui/frontier_checks.odin` mirrors `pattern_checks`:

```odin
report := testui.frontier_check(&handle, testui.Frontier_Expectation{
    use_turn_cause=true,
    stages=[]testui.Frontier_Stage_Expectation{
        {stage=.Paint, check_changed=true, changed=2},
        {stage=.Description, check_visits=true, visits=6},
    },
    check_subscriber=true,
    expected_subscriber=panel_id,
    expect_no_fallbacks=true,
})
if !report.ok { t_error(testui.frontier_failure_diagnostic(&report.failure)) }
```

`Frontier_Expectation` selects the turn's `Turn_Report.cause_id` (or an
explicit cause), checks per-stage visit counts, changed-output counts, sampled
nodes, changed-vs-unchanged, fallback presence/absence, and resolved
subscribers. `Frontier_Report` carries `{ok, failure: step/stage/cause/node/
expected/actual/turn}`; `frontier_failure_diagnostic` renders the first-failing
step like `pattern_failure_diagnostic`. In a release or explicitly disabled
build the helper returns a clean `.Capture_Available` failure instead of
passing silently.

## Adversarial trace

Fixture: `benchmarks/diagnostics/issue193_invalidation_frontier.odin`. The
scene is a keyed parent with three row regions and an unrelated peer region.
Every step is compared against a fresh runtime through the public paint display
list (including text-run content). Raw output:
[`raw/issue193-invalidation-frontier-2026-11-21/adversarial-and-correct.txt`](raw/issue193-invalidation-frontier-2026-11-21/adversarial-and-correct.txt).

The first mistake changes row Bravo but invalidates the unrelated peer. The
fresh comparison reports stale output. The frontier report then locates the
edge:

```text
Alicorn invalidation frontier
cause #2 (Application, action=0)
  trace window: #103..#106, events=4, invalidations=1
  invalidated region: key=fixture-peer revision=1 key-hash=3128907628967514715 requests=1
  subscribers (1): [1164651297357844810]
  ancestors (1): [2232316383130427725]
  stage visits: description/reconcile=2 measure=0 layout=0 paint=0 composite=0
  changed outputs: description=0 measure=0 layout=0 paint=0 composite=0
  description ran without a changed output: this cause visited stages but no retained output changed
  fallbacks: none (observed work=0)
  sampled nodes: reconcile=[4871491486126281863] measure=[] layout=[] paint=[] composite=[]
  where work stopped: before description output (the invalidation scheduled a description but nothing changed)
  why node #1164651297357844810 was touched: cause #2 invalidated region key fixture-peer at revision 1; node #1164651297357844810 is subscribed instance 0
why changed row region: cause #2 invalidated region key fixture-peer but node #7324292764110344671 is neither a subscriber nor an ancestor; it is outside the declared frontier
```

This is the first incorrect edge in one line: the only declared subscriber is
the peer, the changed row is outside the frontier, and no stage changed output.
The beginner-facing metric is not "the description ran"; it is "the declared
edge reached the wrong node and produced no output there."

The same fixture also records:

- **Forgotten revision:** row Alpha changes with no invalidation request. The
  description is idle (`idle passes=0`), there is no cause to inspect, and the
  fresh comparison reports stale output. This is the explicit boundary where
  the #106 oracle, not the frontier, answers the question.
- **Broad ancestor:** row Charlie changes under a parent-region target. The
  report shows one subscriber (the parent container), one ancestor (the root),
  eight stage visits and six changed nodes at description/paint/composite, and
  "where work stopped: composite." The width of the update is visible as visit
  count vs changed count, not inferred.

## Correct fixture

The same three mutations are replayed with their true dependencies. The
Bravo update report:

```text
Alicorn invalidation frontier
cause #2 (Application, action=0)
  trace window: #103..#116, events=14, invalidations=1
  invalidated region: key=fixture-bravo revision=2 key-hash=8691698079053643653 requests=1
  subscribers (1): [7324292764110344671]
  ancestors (2): [4871491486126281863,2232316383130427725]
  stage visits: description/reconcile=6 measure=2 layout=0 paint=2 composite=2
  changed outputs: description=2 measure=0 layout=0 paint=2 composite=2
  fallbacks: none (observed work=0)
  sampled nodes: reconcile=[7495192643631381114,4871491486126281863,1164651297357844810,10667907854639380641,9882743912853715911] measure=[7495192643631381114] layout=[] paint=[7495192643631381114,4871491486126281863] composite=[7495192643631381114,4871491486126281863]
  where work stopped: composite (last stage that produced a changed output)
  why node #7324292764110344671 was touched: cause #2 invalidated region key fixture-bravo at revision 2; node #7324292764110344671 is subscribed instance 0
  changed description nodes: [4871491486126281863,7495192643631381114]
  changed paint nodes: [4871491486126281863,7495192643631381114]
  changed composite nodes: [4871491486126281863,7495192643631381114]
[correct] bravo change fresh-parity= true peer unchanged= true
```

The stage counters show only the parent/text pair that changed. The unrelated
peer is unchanged (`peer unchanged= true`), final fresh parity is true, and the
final settled runtime still takes `idle passes= 0`.

## Release proof

Raw data: [`overhead-off-run1..5.txt`](raw/issue193-invalidation-frontier-2026-11-21/overhead-off-run1.txt)
and [`overhead-on-run1..5.txt`](raw/issue193-invalidation-frontier-2026-11-21/overhead-on-run1.txt),
plus real-GPU CSVs
[`off`](raw/issue193-invalidation-frontier-2026-11-21/scratchpad-off-counters.csv) /
[`on`](raw/issue193-invalidation-frontier-2026-11-21/scratchpad-on-counters.csv).

### Deterministic release A/B (active + idle)

`benchmarks/diagnostics/issue193_frontier_overhead.odin` builds 256 keyed rows,
runs 8 warmups, 64 active row updates, and 512 idle `begin_frame` calls. Both
arms are `-o:speed` with only `-define:ALICORN_INVALIDATION_FRONTIER=false/true`.
All counter lines are identical in all five paired runs:

```text
size_of_runtime= 37736  size_of_frame_stats= 744  size_of_trace_event= 104  size_of_inspector_cause= 1672  gate_enabled= false
frames_built= 73  idle_frames= 585  observed_idle= 512
descriptions_emitted= 658  reused= 144  retained_match= 144  structure_sequence_matches= 71
reconcile= 658  layout= 1027  paint= 514  composite= 514
measure_requests= 256  hits= 0  misses= 256  executed= 256
layout_updates= 513  paint_updates= 514  composite_updates= 1  text_shapes= 256
created= 514  retired= 0  regions_skipped= 72  subtrees_reused= 72  adjacency_rebuilds= 1
global_fallbacks= 0  semantic_changes= 0
global_work_by_reason=measure-font-generation : 1,display-structure-rebuild : 1,display-scale-change : 0,display-transient-update : 0,display-incremental-fallback : 0,semantic-order-rebuild : 1
persistent_requested_bytes_live= 5139192  peak= 5139246  alloc_calls= 8683  free_calls= 3035
scratch_requested_bytes_epoch= 8  peak= 1075236  alloc_calls= 26516  resets= 73
idle_persistent_alloc_call_delta= 0  idle_scratch_alloc_call_delta= 0  idle_persistent_byte_delta= 0
```

Active-update p50 (five runs, `-o:speed`): off `1800, 1900, 1900, 1900, 1800`
ns; on `1900, 1900, 1900, 1900, 1800` ns. Median 1,900 ns in both arms; the
difference is run noise, not a gate effect. The release gate state is reported
as `false` in both arms.

### Real-GPU scratchpad A/B

`tools/bench_scratchpad_workload.ps1` now accepts `-InvalidationFrontier 0|1`
and forwards it to the same workload build. Two runs per scenario and backend,
idle and typing, on SDL_GPU, hosted D3D12, and hosted Vulkan.

- **Idle (all three backends):** zero counter differences. For example
  SDL_GPU idle is `descriptions_emitted=156, reused=156, reconcile=156,
  measure=0, paint=0` in every off/on run; D3D12/Vulkan are `153` each.
- **Active typing, D3D12 and Vulkan:** identical counters and allocation
  calls in every run: `samples=23, descriptions=3519, reused=3497,
  reconcile=3519, measure=22, paint=22`.
- **Active typing, SDL_GPU:** the harness recorded 22 samples in both off runs
  and 23 in both on runs. Its totals scale with that extra description
  (`3432→3588` emitted, `3411→3566` reused), which is the known smoke-run
  timing cadence, not frontier work: release code is identical (`gate_enabled
  = false`, Runtime size unchanged), idle is bit-for-bit identical on the same
  backend, and the deterministic active/idle fixture above is exact.

The paired command and raw CSV/`scratchpad-summary.md` files are committed
under `docs/validation/raw/issue193-invalidation-frontier-2026-11-21/`.

## #106 corpus extensions

All additions live in `runtime/invalidation_coherence_test.odin` and reuse the
existing fresh-runtime oracle, fixed seeds, first-failing-prefix replay, and
action-deletion shrinking.

| Corpus case | What it proves |
| --- | --- |
| `test_invalidation_coherence_adaptive_branch_change_matches_fresh` | A dynamic adaptive subscription branch changes selection (`Compact`→`Wide`) through a declared update; the selected branch's text refresh matches a fresh runtime, an omitted change stays stale, and repair recovers. Inactive-branch geometry is excluded because it is presentation state. |
| `test_invalidation_coherence_keyed_owner_retirement_and_reopen` | Omitting a keyed owner retires it from public queries and paint; reopening the same key creates a fresh owner with finalized geometry, both at fresh parity. |
| `test_invalidation_coherence_same_value_write_changes_nothing` | A legal same-revision invalidation schedules exactly one description, matches fresh output, and (frontier on) records zero changed outputs — the Query-1 "visited vs changed" distinction. |
| `test_invalidation_coherence_cross_window_consumers_independent` | Two runtimes consuming the same app model reach fresh parity independently; invalidating one leaves the other observably stale until its own dependency is invalidated. |
| `test_invalidation_coherence_wrong_but_valid_ancestor_and_sibling` | A valid ancestor target with a stale descendant revision and a valid sibling target both leave stale output; repairing the true dependency restores fresh parity. |
| `test_invalidation_coherence_structural_condition_change` | Adding/removing a conditional branch retires and recreates its nodes while matching fresh output and returning to zero idle work. |

Runtime frontier tests (`runtime/invalidation_frontier_test.odin`) additionally
cover resolved subscribers/ancestors, changed vs visited counts, root
classification, bounded capacity, same-value zero-change capture, the
why-touched query, reason-string redaction, and the clean disabled/release
message.

Testui coverage (`testui/frontier_checks_test.odin`) covers the turn-cause
path, subscriber expectations, changed-output expectations, the first-failing
negative control, the same-value unchanged assertion, and clean release
unavailability.

## Validation and suites

See `docs/validation/issue-106-invalidation-oracle.md` for the base oracle and
`docs/validation/README.md` for the current acceptance index.

Commands used:

```powershell
odin test runtime -debug
odin test runtime -debug -define:ALICORN_INVALIDATION_FRONTIER=false
odin test testui -debug -collection:alicorn=. @accesskit
odin test testui -debug -define:ALICORN_INVALIDATION_FRONTIER=false -collection:alicorn=. @accesskit
.\tools\test.ps1 -Odin C:\odin\odin.exe
```

The repository suite result is recorded below. `tools/test.ps1` builds the
default (release-gate-off) configuration; the two debug gate states were run
explicitly for the packages that exercise capture.

Direct suite results on this branch:

| Suite | Gate | Result |
| --- | --- | --- |
| `odin test runtime` (release/default) | off | 497 tests, all successful |
| `odin test runtime -debug` | on | 497 tests, all successful |
| `odin test runtime -debug -define:ALICORN_INVALIDATION_FRONTIER=false` | explicitly off | 497 tests, all successful |
| `odin test testui -collection:alicorn=. @accesskit` | off | 33 tests, all successful |
| `odin test testui -debug ...` | on | 33 tests, all successful |
| `odin test testui -debug -define:...=false ...` | explicitly off | 33 tests, all successful |
| `odin test ui` | off | 57 tests, all successful |
| `odin test ui -debug` | on | 57 tests, all successful |
| `odin test theme` | off | 37 tests, all successful |
| `odin test renderer\cpu` | off | 23 tests, all successful |
| `odin test native\sdl_gpu` | off | 171 tests, all successful |
| `odin test native\sdl_gpu -debug` | on | 171 tests, all successful |
| `odin test host\fonts` | off | 5 tests, all successful |
| `odin test host\diagnostics` | off | 9 tests, all successful |
| `odin test host\diagnostics -debug` | on | 9 tests, all successful |
| `odin build tests` + `out\alicorn_tests.exe` (foundation integration) | off | `Alicorn foundation tests: PASS` |
| `examples\09_retained_motion` | off | builds |
| `examples\16_native_webgpu_ui` (`WGPU_SHARED=true`) | off | builds |

`tools/test.ps1` did not complete in this session: the pinned AccessKit
dependency's native UIA contract (`verify-uia.ps1`) stopped at "Accessible
Button missing" before the repository suites ran. The same AccessKit ABI and
runtime contract passed its earlier stages, and every suite listed above —
including the inspector overlay (`host/diagnostics`) and all three renderer
surfaces — was run directly and passed. The failure is in the dependency's
interactive Windows UIA probe, not in runtime or testui code touched here.

## Limits

- The runtime cannot detect arbitrary application-memory changes. The frontier
  explains declared causes and the work they reached; it does not infer a
  missing cause.
- Region keys are copied into the capture for the report. Fixtures and
  published reports should use non-sensitive keys; full free-form reason
  strings stay in the local trace ring and are never copied into a frontier
  report.
- Capture is bounded. More than 24 causes, 8 subscribers/ancestors, or 8
  samples per stage after the ring has moved on are deliberately truncated;
  the trace ring itself remains the detailed source.
- The capture is debug-only. Release builds expose the query but report
  "capture unavailable" and add no per-frame work.
- The scratchpad workload's SDL_GPU typing smoke run can record one extra
  sample because its description cadence is wall-clock driven; D3D12/Vulkan
  and the deterministic fixture are used for exact field comparisons.
