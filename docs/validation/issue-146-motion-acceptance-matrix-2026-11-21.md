# Issue #146 motion release gate: consolidated acceptance matrix

Date: 2026-11-21

**Status:** Core release-gate evidence is complete on the local Windows/D3D12
candidate. Platform/dogfood acceptance items remain and issue
[#146](https://github.com/Carnival-Science/Alicorn/issues/146) stays open.

**Release statement:** the issue's core criterion is *"Core must pass before
v0.3 animation ships."* Every core invariant group below passes on the
evidence cited here. No core blocker was found in this slice. The remaining
items are platform acceptance follow-ups (GPU loss mid-transition, macOS/Linux
motion runs, physical 60/120/144 Hz capture, and the Scratchpad #60 native
capture), not core motion-contract failures. The close decision belongs to the
founder; this record does not close #146.

## Candidate and environment

| Item | Value |
| --- | --- |
| Branch | `codex/issue-146-motion-acceptance` |
| Base | `78695d1` (merge of #229 phase 2) |
| Slice commits | `4e1dbcd` (G3), `121352b` (G1), `c3badfd` (G5), `bff6856` (G8), `c91044e` (G7), `cae2613` (G4), `f651761` (G2) |
| OS | Windows 10 Home, build 19045 |
| CPU | AMD Ryzen 5 7600X, 6 cores / 12 logical processors |
| GPU path | SDL 3.4.20, Direct3D 12, real GPU; adapter name not exposed by the captured diagnostics |
| Odin | `dev-2026-11-nightly:08539cd` |
| Build | `-o:speed` for native example runs; default test builds for suites |

The runtime acceptance tests are headless and renderer-independent. The two
native runs used the real window, SDL event loop, D3D12 swapchain, motion
scheduler, and diagnostics capture.

## Consolidated acceptance matrix (issue's 9 rows)

Status vocabulary:

- **Covered** - a regression test or recorded native run proves the row.
- **Covered + rejection** - the core behavior is proved; one optional or
  unsupported sub-item is explicitly rejected and recorded.
- **Covered + follow-up** - the core behavior is proved; a platform-specific
  run remains for the named follow-up.

| # | Required edge case | Status | Evidence |
| ---: | --- | --- | --- |
| 1 | Target jump compensation, residual, position/velocity continuity, repeated assignment no-op | Covered | `motion_math_test.odin`: `test_motion_scalar_matches_closed_form_and_retargets_continuously`, `test_motion_mode_transitions_and_same_target_rules`, `test_motion_one_thousand_unchanged_targets_do_not_rebase_or_drift`; retained: `test_retained_motion_retarget_is_continuous_and_mode_change_is_not_ignored`; replay: `test_motion_virtual_replay_is_sampling_history_independent_and_traces_lifecycle`; record [#137](../research/issue-137-analytic-residual-motion.md). |
| 2 | Direct manipulation presents exactly at the pointer with zero residual; velocity handoff only at release | Covered | New `motion_acceptance_direct_test.odin`: five splitter drag samples, exact presented target, zero residual/velocity, `.Direct` -> `.Settle` at release preserves position and velocity, settles on the certified bound, no later wake. |
| 3 | Settlement uses position **and** velocity tolerances, conservative bound, explicit zero residual on retirement, no wake after settle | Covered | `test_motion_does_not_retire_small_position_with_large_velocity`, `test_motion_certified_deadline_is_independent_of_sample_history`, `test_retained_motion_samples_and_retires_without_history_dependent_work`; new G1 post-release loop asserts four idle opportunities with no presentation; native settled/idle checkpoints in [#146 progress](issue-146-progress-2026-10-30.md) and [#144 diagnostics](issue-144-motion-diagnostics.md). |
| 4 | Predicted-present timestamp only when supported; monotonic fallback; frame-in-flight/visible latency; 200 ms and suspend gaps analytic; hidden window has no idle wakes | Covered + rejection | Injected virtual clock and `Native_Monotonic` host source in [#144](issue-144-motion-diagnostics.md); `test_motion_sampling_cadence_and_long_stall_are_invariant` and uneven-cadence replay prove 200 ms/stall sampling is analytic; hidden/minimize/restore suspension and one restore sample in [#146 progress](issue-146-progress-2026-10-30.md). Predicted-present timestamps are **documented rejection** D1 below; the host does not claim compositor present timestamps. Frame-in-flight counters exist in diagnostics; physical visible-latency capture remains G10. |
| 5 | Parent-local residual, ancestor composition, FLIP, nested scroll/clip without double application; no text scaling/reflow; opacity clamp; color space/gamut | Covered + rejection | Two-level composition `test_retained_motion_composes_parent_and_child_without_description_or_layout`; new three-level `test_motion_composition_applies_three_ancestor_levels_exactly_once`; `test_motion_follow_visual_clips_translate_local_bounds_and_keep_viewport_fixed`; new virtualized scroll clip `test_motion_follow_visual_inside_scrolled_clip_translates_clip_once`; clamp test `test_motion_diagnostics_report_opacity_clamp_once_per_excursion`; linear-sRGB color `test_retained_motion_surface_color_is_linear_static_and_paint_only`. FLIP is **documented rejection** D2. |
| 6 | Pointer-down latch stays with moving control; no invisible click targets; hit-index maintenance bounded; tab close/native caption areas correct; semantic state immediate; accessible bounds policy tested | Covered | `test_retained_motion_static_interaction_policy_preserves_capture_and_semantic_bounds`; new hit-maintenance classification `test_motion_only_frames_perform_no_hit_index_maintenance_and_classify_lookup_work`; new tab close `test_tab_bar_motion_reorder_preserves_close_hit_geometry_without_invisible_targets`; Reveal semantics `test_motion_reveal_is_paint_only_and_rejects_interactive_subtrees`; native caption/frame hit tests in `native/sdl_gpu/frame_hit_test_windows_test.odin` and [#211 topmost re-entry](issue-211-topmost-reentry-windows-2026-11-20.md). |
| 7 | Reparent changes scoped identity -> documented snap; Reveal works without optional ghost/Exit | Covered + rejection | `test_retained_motion_reparenting_does_not_transfer_parent_local_presentation` and `test_retained_motion_generation_changes_when_node_identity_is_recreated`; `test_motion_reveal_is_paint_only_and_rejects_interactive_subtrees`; example 09's settings-panel Reveal. Ghost/exit is **documented rejection** D3. |
| 8 | Cross-platform libm differences through numeric tolerance; no assumed bit-identical replay; unsupported underdamped physics rejected | Covered + follow-up | Toleranced `f64` math and explicit absolute tolerances in [#137](../research/issue-137-analytic-residual-motion.md); `test_motion_virtual_replay_is_sampling_history_independent_and_traces_lifecycle`; the motion model is critically damped only and underdamped response is rejected by the typed API. macOS/Linux physical runs remain follow-up G9. |
| 9 | Tests quantify stage counters for motion-only and settle+idle; classify hit-index and paint uploads accurately | Covered | Motion-only zero description/reconcile/measure/layout/test-shape assertions in `test_retained_motion_composes_parent_and_child_without_description_or_layout` and hosted `test_hosted_motion_runs_to_settlement_without_description_changes`; new `hit_test_queries`, `hit_test_nodes_examined`, `hit_geometry_updates`, `hit_index_updates` counters are separate from `paint_updates`/`composition_updates`; [#144 diagnostics](issue-144-motion-diagnostics.md) and [#229 phase 1](issue-229-phase1-baseline-2026-11-21.md) define the work-counter vocabulary. |

**Coverage tally:** 9 of 9 rows have core evidence. Five rows (1, 2, 3, 6, 9)
are fully covered with no outstanding item. Four rows carry either a documented
rejection for an optional/unsupported sub-item (4, 5, 7) or a platform follow-up
(8). Zero rows are uncovered.

## Core invariant groups

The issue names seven invariant bullets. For the release decision this record
treats six as core gates and Native as platform acceptance (G6/G9/G10/G11).

| Invariant group | Status | Evidence |
| --- | --- | --- |
| Correctness: logical/target state independent of presentation; replay; retarget continuity; no stale generations; typed validation | **Pass** | Rows 1, 2, 3, 7 above; `test_retained_motion_handles_are_isolated_between_runtimes`, `test_motion_invalid_inputs_leave_response_unchanged`, `test_motion_diagnostic_velocity_matches_last_presented_sample_time`. |
| Stage locality: opacity/translation motion adds no app builds, reconcile, shaping, measuring, or layout; paint/GPU work attributed | **Pass** | Existing motion-only assertions plus new hit-maintenance classification; [#229 phase 2](issue-229-phase2-description-reuse-2026-11-21.md) shows motion-only turns are cheaper through exact description reuse; [#211 scheduling](issue-211-motion-scheduling-windows-2026-11-20.md) reduced a storm-paced run from 200 to 23 frames with descriptor delta 0. |
| Lifecycle: remove/reuse, disabled/hidden, reduced motion, theme change, high contrast, scale change, secondary windows, background/minimize/restore, GPU loss, shutdown | **Pass (core); G6 follow-up** | Reparent/retire/reveal, reduced motion, theme retarget, high-contrast + 1.25/1.5/1.75 scale test (new G5), secondary-window and minimize/restore records in [#146 progress](issue-146-progress-2026-10-30.md), new shutdown-during-motion test and example mode (G7). GPU loss mid-transition is G6. |
| Idle: zero motion-owned deadlines, wakes, paint/composition, GPU submissions over a quiet interval | **Pass** | `test_retained_motion_samples_and_retires_without_history_dependent_work`; example 09 settled/idle checkpoints; native quiet intervals after settlement in [#146 progress](issue-146-progress-2026-10-30.md); [#211 scheduling](issue-211-motion-scheduling-windows-2026-11-20.md) records settled idle 0 wakes; #229 phase 2 settled-idle arms. |
| Boundedness: churn, 1/100/1000 owners, ghost limits, invalid inputs, starvation, near-u64, allocations/queues | **Pass** | `test_retained_motion_activity_and_sampling_scale_to_one_thousand_owners`, `test_retained_motion_sidecar_enforces_global_owner_bound`, `test_uncertified_motion_can_be_bounded_to_an_exact_target`, `test_motion_handles_large_timestamps_and_unestablished_slow_deadline`, `test_motion_short_circuits_large_transient_without_intermediate_overflow`; native lateness samples are a bounded 256-entry ring. |
| Product dogfood: tab indicator + settings/palette reveal in Scratchpad with captured source/workflow | **Partial** | Punks playback regression and Example 09 tab/reveal are recorded in [#146 progress](issue-146-progress-2026-10-30.md); the required Scratchpad #60 native capture/source workflow is G11. |
| Native: Windows and macOS smoke; Linux as available; 1x/1.25x/1.5x/2x DPI; 60/120/144 Hz sampling scenarios | **Platform follow-up** | Windows/D3D12 runs are recorded here and in [#146 progress](issue-146-progress-2026-10-30.md). macOS/Linux physical runs (G9), physical refresh capture (G10), and high-DPI physical presentation remain platform acceptance, not core-contract failures. |

## Gap closures in this slice

### G1 - Direct-manipulation end to end (new)

`runtime/motion_acceptance_direct_test.odin` drives a retained split divider
through `process_pointer` down/move/up. At each of five move samples the
presented translation equals the pointer delta exactly and the residual and
residual velocity are zero; the split position tracks the same delta. At
release the test switches to `.Settle`, then asserts the existing response and
the new response sample the same position and velocity at the switch. The
response retires on its certified bound and four additional opportunities
produce no changed owner and no pending presentation.

Limit: this is the headless retained pointer path with an injected clock. It is
not a physical input-to-presentation measurement (G10).

### G2 - Latency distribution in the validation harness (new)

`Native_Motion_Scheduler_Stats` now keeps a bounded 256-entry lateness ring and
`native_motion_lateness_percentile` reports nearest-rank p50/p95/p99. The
`SDL application PASS` summary adds `motion_lateness_samples`,
`motion_lateness_p50_ns`, `motion_lateness_p95_ns`, and
`motion_lateness_p99_ns` next to the existing maximum.

Native Windows/D3D12 runs on this candidate:

| Run | Samples | p50 | p95 | p99 | Max |
| --- | ---: | ---: | ---: | ---: | ---: |
| Example 09 `--motion-validation` | 49 | 0.845 ms | 1.342 ms | 25.345 ms | 152.878 ms |
| Example 09 `--shutdown-during-motion` | 18 | 0.802 ms | 29.385 ms | 29.385 ms | 181.369 ms |

These are scheduler deadline-to-sample lateness values and include startup
outliers; they are not compositor present timestamps, input-to-photon latency,
or a refresh-rate claim. The shutdown run's larger p95 reflects its short
sample window.

### G3 - Hit-index maintenance bounded and classified (new)

Alicorn has **no maintained spatial hit index**: `hit_test` scans the retained
order newest-first, and custom circular hit shapes are a sparse map maintained
only when a description changes. This record therefore classifies the real
work instead of inventing an index.

New `Frame_Stats` counters:

- `hit_test_queries` - public hit-test calls.
- `hit_test_nodes_examined` - retained nodes scanned by those calls.
- `hit_geometry_updates` - device-space hit rectangle finalization during
  layout/DPI changes.
- `hit_index_updates` - actual writes/removals in the sparse
  `pointer_hit_shapes` map.

`test_motion_only_frames_perform_no_hit_index_maintenance_and_classify_lookup_work`
builds a custom circular button, commits a motion pose, and asserts a
motion-only frame performs zero hit-index and zero hit-geometry maintenance
while composition visits advance and paint updates stay separate. An explicit
query then costs one query, stays within the bounded split/interactive/drag
scans (6 examined nodes for a 4-node order), and performs no maintenance.
O(changed) for maintenance is therefore zero during motion; query lookup remains
a retained-order traversal and is documented as such.

### G4 - Tab close affordance under motion (new)

`test_tab_bar_motion_reorder_preserves_close_hit_geometry_without_invisible_targets`
animates a tab root by 40 logical units during an `animate_drag_reorder` build.
The tab and its close affordance both compose the translation, but the close
remains clickable at its logical position, has unchanged retained/accessibility
bounds, and is **not** clickable at its moved paint position. A logical
pointer down/up still activates the close control.

### G5 - High contrast and DPI presentation (new)

`test_motion_high_contrast_and_presentation_scales_preserve_logical_presentation`
compares a normal and `increased_contrast=true` environment: translation
`[28, -6]` and opacity `0.55` are identical, and logical hit geometry is
unchanged. It then applies presentation scales 1.25, 1.5, and 1.75: logical
translation/opacity and hit testing stay invariant, while finalized device
geometry snaps to the device grid (`30` logical height presents as `30.4`,
`30.0`, and `30.2857` at those scales respectively). This is the same
logical-presentation/device-pixel policy recorded for the #211/#207 DPI
fixtures.

Limit: this is runtime geometry/presentation acceptance, not a physical
monitor transition capture. Physical mixed-DPI motion remains a platform
follow-up under G9/G10.

### G7 - Shutdown during an active transition (new)

- Headless: `test_runtime_destroy_with_active_motion_releases_owners_and_sidecars`
  starts a slow `.Settle`, ticks once (one active owner, allocated diagnostics
  and motion sidecars), destroys the runtime, and asserts every tracked
  persistent byte is released and frees increased. No crash or stale owner.
- Native: example 09 gains `--shutdown-during-motion`. It starts the long
  response, then requests a clean host quit mid-flight. The 2026-11-21 run
  recorded `shutdown_requested active_owners 1 active_properties 1
  unestablished_deadlines 0`, exited 0 with `SDL application PASS`, 20
  submissions, and no crash. Capture:
  `out/issue-146/g7-shutdown-2026-11-21/` (ignored local artifact).

Limit: clean application-requested shutdown, not forced process termination,
GPU loss, or OS session end. GPU loss is G6.

### G8 - Multi-level composition and nested scroll/clip (new)

- `test_motion_composition_applies_three_ancestor_levels_exactly_once` puts a
  leaf surface under three motion ancestors: translations `(10,5)`, `(2,3)`,
  `(5,-1)` produce exactly `(17,7)` and opacities `0.9 * 0.8 * 0.5 = 0.36`.
  The test explicitly rejects a doubled per-level result.
- `test_motion_follow_visual_inside_scrolled_clip_translates_clip_once` places
  a clipped moving row inside a virtualized scroll list with offset 40. The
  row's logical bounds already include the offset; `Follow_Visual` translation
  `(24,8)` moves the leaf clip to `y + 8`, not `y + 16`, and the stationary
  scroll viewport remains authoritative. Retained logical clips and hit
  geometry stay fixed.

## Documented rejections

**D1 - Predicted-present timestamps.** `Motion_Clock_Source` distinguishes
`Unknown`, `Injected`, and `Native_Monotonic`; the host injects monotonic
nanoseconds and explicitly does not claim compositor present timestamps. A
predicted-present timestamp is not implemented because no supported/validated
host contract exists. This follows the issue's qualification ("only when
supported/validated"). Record: [#144](issue-144-motion-diagnostics.md) and
`docs/reference.md` motion scheduling text.

**D2 - FLIP nested motion.** The base issue lists FLIP as an optional
conditional experiment ("conditional experiments ... contribute fixtures only
if accepted") and this slice does not add a FLIP prototype. Ancestor transform
composition and nested scroll/clip correctness are covered directly instead.

**D3 - Ghost/exit prototype.** #142/#143 are optional gates; birth/Reveal is
implemented without ghost or exit tombstones. Reveal is paint-only, limited to
noninteractive subtrees, and exposes semantics immediately. Record:
[#138](../research/issue-138-motion-ownership.md) and reference docs.

## Platform acceptance follow-ups (not core failures)

| ID | Item | Current state |
| --- | --- | --- |
| G6 | GPU loss mid-transition | Not exercised in this slice. Device-loss recovery exists separately; motion teardown on device loss still needs a native capture. |
| G9 | macOS/Linux motion runs | Not run here. Windows/D3D12 only. macOS/Linux CI evidence exists for other slices but not physical motion acceptance. |
| G10 | Physical 60/120/144 Hz capture | Not captured. The scheduler requests a display-like cadence; no panel-refresh or compositor-present claim is made. |
| G11 | Scratchpad #60 native capture | Punks dogfood is recorded; the Scratchpad motion/indicator capture and repeatable workflow remain pending. |

## Strengthening evidence cited

- **#211 scheduling (2026-11-20):** storm-paced frames 200 -> 23 over the same
  400 ms response with descriptor delta 0; settled idle 0 wakes; per-window
  deadline and suspension behavior. This is the scheduling/idle backbone for
  rows 3, 4, and the Idle group.
- **#229 Phase 2 (2026-11-21):** exact description reuse makes motion-only
  turns cheaper while keeping stage locality; paired SDL_GPU/D3D12/Vulkan
  measurements and settled-idle control arms.
- **#228 sparse finalization (recorded in #229 Phase 1):** count-changing
  display splices finalize only the changed range, which keeps motion-driven
  paint/mesh updates bounded.
- **#144 diagnostics and replay:** virtual-clock replay, passive motion
  inspector, bounded transition ring, and separate presentation request /
  submission / host-wake counters.
- **#137/#138:** analytic residual math, typed property validation, owner
  generations, and the documented static interaction contract.

## Verification for this slice

| Suite | Result |
| --- | --- |
| `odin test runtime` | 488 tests, all pass (7 new acceptance tests: G1, G3, G5, G8 x2, G7, G4) |
| `odin test native\sdl_gpu` | 171 tests, all pass (2 new lateness summary tests) |
| `odin test testui` | 31 tests, all pass |
| `odin test ui` | 57 tests, all pass |
| `odin test theme` | 37 tests, all pass |
| `odin test renderer\cpu` | 23 tests, all pass |
| `odin test host\diagnostics` | 9 tests, all pass |
| `tests` foundation executable | PASS |
| `native\sdl_gpu_entry` | Builds |
| Example 09 | Builds with `-o:speed`; `--motion-validation` and `--shutdown-during-motion` both PASS |

Harness caveat: `tools/test.ps1` ran the AccessKit ABI check successfully, but
Windows PowerShell 5.1 treats the test runner's INFO lines on stderr as
terminating errors and stopped the aggregate script afterward. The remaining
stages were run individually with the pinned AccessKit collections; this is the
caveat already recorded in `docs/development.md`.

## Limits

This record proves the core motion contract and bounded teardown on one
Windows/D3D12 machine with a real GPU. It does not prove macOS/Metal or
Linux/Vulkan behavior, physical refresh-rate behavior, compositor present
timestamps, input-to-photon latency, GPU loss during an active transition, or
the Scratchpad #60 dogfood workflow. Those are the named follow-ups above.

## Final v0.3.0 validation (2026-11-22)

This section appends the v0.3.0 release-gate pass and supersedes the
"Platform acceptance follow-ups" table above for the release decision. It does
not rewrite the slice evidence. Source baseline: `ac469a4` plus the
documentation commit that carries this section. All CI workflows below ran
green against that baseline; the push-triggered workflows were re-run on the
documentation commit (the WebGPU legs are not path-triggered by docs and keep
the same code they validated at `ac469a4`).

### Final CI (all workflows green)

| Workflow | Run | Result |
| --- | --- | --- |
| Alicorn foundation (Windows) | [44999874732](https://github.com/Carnival-Science/Alicorn/actions/runs/44999874732) | success |
| Alicorn foundation (macOS) | [44999874786](https://github.com/Carnival-Science/Alicorn/actions/runs/44999874786) | success |
| Native packaging | [44999874891](https://github.com/Carnival-Science/Alicorn/actions/runs/44999874891) | success |
| Icon asset reproducibility | [44999874795](https://github.com/Carnival-Science/Alicorn/actions/runs/44999874795) | success |
| WebGPU feasibility (browser) | [44999874869](https://github.com/Carnival-Science/Alicorn/actions/runs/44999874869) | success |
| WebGPU feasibility (Linux) | [44999874809](https://github.com/Carnival-Science/Alicorn/actions/runs/44999874809) | success |
| WebGPU feasibility (macOS arm64) | [44999874741](https://github.com/Carnival-Science/Alicorn/actions/runs/44999874741) | success |

Three pre-existing CI failures were found and fixed in this gate, all in
harnesses rather than runtime behavior:

1. **js/wasm closure.** The official `dev-2026-11` compiler compiles
   `*_test.odin` during a plain `odin build`, so `tests/fixtures/web_ui_package`
   pulled `core:os` and `core:testing` into the WASM closure through
   `runtime/bindings_test.odin`, `key_event_test.odin`, and `roving_test.odin`.
   Those three files now carry the `#+build !js` guard the other 86 runtime test
   files already had.
2. **Unix AccessKit arguments.** `tools/check.sh` and `tools/test.sh` invoked
   `odin test testui` without the AccessKit collection and linker flags, so the
   package could not compile its transitive native accessibility import on
   macOS/Linux. They now match the already-fixed `tools/test.ps1` invocation.
3. **Platform primary modifier in fixtures.** `testui/command_bindings_test.odin`
   and `host/sdl3/input/bindings_mapping_test.odin` sent Control while asserting
   the platform-neutral `Primary` modifier. Primary is Command on macOS and
   Control on Windows/Linux; both fixtures now send the platform primary, which
   is what the host normalizes.

`odin test testui` is 37/37 on macOS and Windows; `odin test host/sdl3/input` is
10/10; `odin test runtime` is 511/511 on Windows and Linux.

### G6 - GPU loss during an active motion (Windows/D3D12, closed)

Re-ran the induced backend-removal harness with a live motion owner. The
patched `wgpu-native` v29.0.1.1 library carries the callback, error-routing, and
test-removal patches; it was rebuilt with Rust 1.98.1 and bindgen against the
Python `libclang` 18.1.1 wheel (the prior record used LLVM 23.1.5; the artifact
proves the same API path, and the DLL hash is not compared across builds).

`examples/16_native_webgpu_ui` gains `--removal-motion-probe`, built only with
`-define:ALICORN_WEBGPU_TEST_D3D12_REMOVE_DEVICE=true`. It drives a bounded
settle ping-pong on the retained marker, logs `motion_probe tick N
active_owners M` every host turn, and quits itself after settlement.
`tools/validate_wgpu_native_backend_removal.ps1` adds a
`removal-during-motion` case that requires motion at loss, motion at
reattachment, motion after the post-recovery frame, and a settled PASS.

Run on 2026-11-22 (RTX 2080 SUPER, D3D12):

```text
removal-during-motion: PASS (exit=0 removal=True callback=True recovered=True
  post_frame=True motion_at_loss=True motion_after_recovery=True
  motion_after_post_frame=True motion_smoke=True)

test removal trace: motion before-removal active_owners=1 active_properties=1
test removal: ID3D12Device5::RemoveDevice issued=true
test removal trace: device-lost callback fired reason=Unknown
test removal trace: motion after-recovery-reattach active_owners=1 active_properties=1
WebGPU device recovered; retained application state preserved
test removal trace: post-recovery frame presented
motion_removal_smoke PASS ticks 200 active_ticks 114 settled_after_stop true quit_owners 0
```

All eight harness cases pass (`ordinary-smoke`, `synthetic-callback`,
`primary-removal`, three removal repetitions, `primary-plus-child-removal`,
`removal-during-motion`). Logs: `out/webgpu-phase0/backend-removal/` (ignored
local artifact). This is harness-induced `ID3D12Device5::RemoveDevice`, not a
TDR, OS reset, or driver-initiated loss, and not macOS/Linux GPU-loss evidence.

### G9 - macOS/Linux motion (CI tier, closed at CI tier)

**Linux / Vulkan (lavapipe).** The WebGPU Linux job now runs
`odin test runtime` (511/511) and then builds and runs example 09 with
`--motion-validation` under Xvfb using the Mesa lavapipe ICD. Run
[44999874809](https://github.com/Carnival-Science/Alicorn/actions/runs/44999874809),
step `Validate retained motion on Vulkan (lavapipe, SDL_GPU native host)`:

```text
sdl_video_driver x11
gpu_driver_selected vulkan
motion_validation settled_checkpoint active_owners 0
motion_validation idle_checkpoint active_owners 0
SDL application PASS submissions 53 retired 53
motion_samples 49 motion_timer_wakes 49 motion_missed_intervals 0
motion_lateness_p50_ns 637987 motion_lateness_p95_ns 1062614 motion_lateness_p99_ns 1069129
```

This is a real sampled motion run on a native SDL_GPU host: retargets,
settlement, an idle interval, zero missed intervals, and 49 motion samples. The
adapter is software Vulkan (Mesa llvmpipe via lavapipe) on a CI runner, not
physical hardware.

**macOS / Metal.** The foundation macOS job builds and runs the same example
with `--motion-validation`. Run
[44999874786](https://github.com/Carnival-Science/Alicorn/actions/runs/44999874786),
step `Validate retained motion on Metal (SDL_GPU native host)`:

```text
gpu_driver_selected metal
motion_validation settled_checkpoint active_owners 0
SDL application PASS submissions 3 retired 3
motion_samples 0 motion_missed_intervals 0
```

Honest limit: the macOS runner is a paravirtual Metal device and the window was
not sampled on this leg, so the run proves the native host, scheduler wiring,
corrective retarget sequence, settlement checkpoints, and clean bounded exit on
macOS/Metal, but it does **not** prove a sampled macOS animation. Sampled motion
evidence for this cycle is Linux/Vulkan above and the Windows/D3D12 runs earlier
in this record.

Artifacts: `motion-validation-lavapipe` and `motion-validation-metal` on the run
pages.

### G10 - Physical 60/120/144 Hz (explicitly scoped to founder-run)

This remains a physical-hardware acceptance item and is not claimed by any run
above. The release gate accepts the analytic cadence evidence on file plus the
existing operator runbook:

- Analytic sampling: `motion_math_test.odin`
  `test_motion_sampling_cadence_and_long_stall_are_invariant` compares 30/60/144
  Hz sampling paths and a 200 ms stall against the closed-form response.
- Operator runbook: [Windows high-DPI validation](hardware-validation-windows-highdpi.md)
  (three passes, coordinate reminder, evidence template). The 60/120/144 Hz
  presentation capture runs on the founder's physical panel and is appended
  there, not inferred from CI.
- No compositor-present timestamp, panel-refresh, or input-to-photon claim is
  made by this record.

### G11 - Scratchpad #60 native capture (explicitly scoped to founder-hands-on)

The Scratchpad motion dogfood capture was not produced in this pass. The
Scratchpad checkout used for dogfood is on
`codex/issue-211-webgpu-frontend` with uncommitted generated theme files, and
the earlier scripted-pointer route failed to drive the real Scratchpad window
reliably, so a scripted capture here would not be trustworthy evidence.

Source-workflow coverage that does exist: Scratchpad's `command_palette_test`
palette-motion fixture and `connected_titlebar_test` tab cases exercise the
reveal/selection contract headlessly and assert that tab selection requires no
motion owner. That is source-level evidence, not a native capture.

Founder-hands-on steps (record result in the Scratchpad validation folder and
link it from #146):

1. Build the Alicorn frontend in the Scratchpad checkout
   (`out/alicorn/scratchpad-alicorn.exe`) using its documented build script,
   with the desired appearance fixture.
2. Launch it on the physical Windows desktop and open the command palette
   (Primary+Shift+P). Let the palette reveal run; press `F12` during the reveal
   to write an Alicorn diagnostics bundle (it includes the motion transition
   ring and stage counters).
3. Switch document tabs to capture the tab indicator/selection behavior; press
   `F12` again after the indicator settles.
4. Record the bundle paths, the Scratchpad commit, and the observed reveal
   frames in the Scratchpad validation record; link that record from #146.

### Final tally and release-gate statement

| Item | Final state |
| --- | --- |
| Core motion contract (9 rows, 6 invariant groups) | **Complete**; no core failure found in this cycle. |
| G6 GPU loss during motion | **Complete** on the Windows/D3D12 native tier via harness-induced backend removal. |
| G9 macOS/Linux motion | **Complete at CI tier**: Linux/Vulkan sampled motion; macOS/Metal host+scheduler+settlement. Physical-hardware runs remain out of scope for CI. |
| G10 physical 60/120/144 Hz | **Explicitly scoped** to founder-run with the runbook above and analytic cadence tests. |
| G11 Scratchpad #60 native capture | **Explicitly scoped** to founder-hands-on with the steps above; source-level fixtures exist. |

Release statement: the core motion invariants pass, and every platform record is
at the tier achievable for this cycle (Windows/D3D12 native with a real GPU,
Linux/Vulkan and macOS/Metal CI tier, physical-Hz and the Scratchpad capture
explicitly scoped to the founder). No core blocker was found. The close
decision remains the founder's; this record does not close #146.

