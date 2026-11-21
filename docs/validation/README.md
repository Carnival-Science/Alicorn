# Current validation

This folder keeps current acceptance summaries and reusable validation
runbooks. Dated investigation snapshots and superseded reports are in the
[archive](../archive/README.md); their historical status should not be read as
the current project status.

## Current acceptance and platform limits

- [Issue #193 invalidation-frontier diagnostics (2026-11-21)](issue-193-invalidation-frontier-2026-11-21.md)
  — GO: debug-only per-cause capture of the invalidation target, resolved
  subscribers and ancestors, changed outputs vs visits, sampled ring nodes, and
  fallback attribution; `frontier_inspect`/`frontier_why_touched` queries and a
  `testui` `frontier_check` helper; six #106 corpus extensions; an adversarial
  wrong-region trace that locates the first incorrect edge; and a paired
  release A/B with identical Frame_Stats, global work, allocation counters,
  and structure sizes.
- [Issue #146 motion release gate: consolidated acceptance matrix (2026-11-21)](issue-146-motion-acceptance-matrix-2026-11-21.md)
  - all 9 issue matrix rows and 6 core invariant groups mapped to evidence;
  - local gap closures for Direct manipulation, hit-maintenance classification,
  high-contrast/DPI presentation, three-level and scrolled composition, tab
  close under reorder motion, shutdown during an active transition, and native
  lateness p50/p95/p99; core passes, platform items G6/G9/G10/G11 remain.
- [Generic roving focus model and list/grid pattern checks (2026-11-21)](issue-225-roving-focus-2026-11-21.md)
  — pure `alicorn:runtime` `Roving_View`/`roving_propose` index model, `testui`
  `Roving_List`/`Roving_Grid` patterns, the `select_parts` and AliKit icon-picker
  adoptions, the justified `tree_view` skip, and positive/negative coverage
  including disabled-focusable, no-tab-stop, and focus-escape faults.
- [Issue #229 Phase 2 description reuse (2026-11-21)](issue-229-phase2-description-reuse-2026-11-21.md)
  — exact retained-description and structure-sequence gates in `reconcile`;
  field-by-field gate audit, `description_hash` coverage extensions, skip list,
  ten new runtime tests including per-field fresh-runtime equivalence, paired
  before/after across SDL_GPU/D3D12/Vulkan plus a high-churn scenario, and the
  scaled expectation for the real 393-node Scratchpad frame.
- [Issue #229 Phase 1 performance harness and baseline (2026-11-21)](issue-229-phase1-baseline-2026-11-21.md)
  — Scratchpad-shaped workload matrix (dense virtual editor, 1k-node tree, tabs,
  pinned gradient panel, focused field) across SDL_GPU, hosted D3D12, and hosted
  Vulkan; six interaction families; per-stage CPU attribution in
  `Frame_Stats.stage_timings_ns`; p50/p95/p99, allocation and visit counters;
  real-Scratchpad `--timings` cross-check; measured instrumentation overhead.
- [Reusable accessibility and interaction pattern checks (2026-11-21)](issue-217-pattern-checks-2026-11-21.md)
  — test-only `alicorn:testui` conformance checks for a single-select
  list/combobox and a composed modal dialog; stock Select, custom userland
  combobox, app-owned modal, six must-fail negative controls, semantic
  relationship snapshots on `Element`, and explicit published-semantics /
  synthetic-input limits.
- [Collection parent parameter (2026-11-21)](issue-223-collection-parent-2026-11-21.md)
  — optional `parent` on `semantic_collection_begin`; stock Select, the #218
  pilot package, and the testui custom-combobox fixture now publish their popup
  list parent directly, with pending/unrealized-record, grouped-option,
  stock-versus-parts parity, and zero-default regression coverage.
- [Issue #218 composable Select parts pilot (2026-11-21)](issue-218-parts-pilot-2026-11-21.md)
  — GO for a copyable userland Select package with zero new runtime APIs and
  NO-GO for shared-behavior/framework extraction in this issue; stock-versus-
  parts semantic parity, turn-work/allocation/latency comparisons, two
  appearances with stable identity, an application-owned Recent extension, and
  the recorded collection-parent, generic popup keyboard, reveal, pointer,
  roving-focus, type-ahead, focus-timing, and 2D-value core candidates.
- [Shape primitives — Windows (2026-11-20)](issue-110-shapes-windows-2026-11-20.md)
  — circle/arc/Bezier pixel probes at four DPI scales, clipping and
  translucent overlap, circular pointer pass-through, keyboard activation,
  rectangular accessibility bounds, and CPU build/upload/encode/submit/fence
  costs against rectangles.
- [Two-stop gradients — Windows (2026-11-20)](issue-119-gradients-windows-2026-11-20.md)
  — native D3D12 readback probes for stops, midpoints, clipping, rounded
  edges, source-over and four DPI scales; an independent CPU-reference
  full-frame comparison; replay equality; and separated CPU-stage timings
  against solid fills.
- [Bounded filled-rectangle batches — Windows (2026-11-20)](issue-200-rectangles-windows-2026-11-20.md)
  — 1,026-rectangle native readback on D3D12 and Vulkan against an independent
  CPU compositor and wxWidgets 3.2.11 GDI captures, the batched-versus-retained
  repaint comparison, per-update allocation and idle checks, and the 1,365-rect
  vertex-budget cap.
- [Dense retained point markers — Windows (2026-11-20)](issue-201-markers-windows-2026-11-20.md)
  — 16 wxWidgets 3.2 MSW ellipse captures compared on D3D12 and Vulkan across
  size, antialiasing, overlap, clipping, and 1x-2x DPI, plus the isolated
  128-1,365 marker cost sweep and the atomic overflow cap. Metal and GPU
  execution timestamps remain outstanding.
- [Issue #205 multi-surface acknowledgements — Acetate native Windows (2026-11-20)](issue-205-multisurface-acetate-windows-2026-11-20.md)
  — one retained Runtime across two real SDL_GPU Direct3D 12 windows in
  Acetate's native fixture: independent ruler/waveform submission and
  exact-revision acknowledgement, shared invalidation and resize, stale-ack
  rejection, hidden/restored and removed/recreated targets, and a settled idle
  window with zero submissions (37/37 checks); includes captures, counters, and
  the clarified per-target scale rule.
- [Percentage-width production validation — Windows (2026-11-21)](issue-158-percentage-width-windows-2026-11-21.md)
  — nested, cached-region, row/panel/scroll, positioned-child, theme, text-scale,
  and zero-percentage coverage; parent-first retained resolution; the
  consumer-shaped percentage-vs-manual A/B and its explicit native/graphics
  limits.
- [Connected-tab visual acceptance audit (2026-11-21)](issue-120-connected-tabs-visual-audit.md)
  — Scratchpad warm, cool-light, and workbench-relief captures at
  1/1.25/1.5/2 display scales; option A (editor-paper fill + open seam) and
  option C (bounded curved shoulders) accepted; options B/D not pursued and a
  general shoulder/path primitive explicitly NO-GO. Records the Standard-tab
  control, the constraint checks, and the native-host DPI-density gap.
- [Live-resize presentation latency — Windows (2026-11-20)](issue-211-live-resize-performance-windows-2026-11-20.md)
  — per-frame inter-present latency, `WM_WINDOWPOSCHANGED`-to-present stretch
  window, `wgpu.SurfaceConfigure` cost, description/layout cost, and
  encode/submit on the identical scripted drag for hosted D3D12, hosted Vulkan,
  and SDL_GPU; the opt-in geometry dispatch that cut D3D12's stretch window from
  7.3 ms to 2.6 ms p50, and the Scratchpad comparison.
- [Hosted font parity and the Pinned U+22EF control (2026-11-20)](issue-211-hosted-font-parity-ellipsis-windows-2026-11-20.md)
  – shared desktop font seeding across the SDL_GPU reference and hosted WebGPU,
  the per-run face/glyph diagnostics, the semantic `More_Horizontal` icon
  provision, and the byte-identical post-fix Scratchpad pinned frame.
- [WebGPU branch integration review (2026-11-19)](webgpu-integration-review-2026-11-19.md)
  — master merge resolution, every shared runtime/host/renderer/tooling change
  with a blast-radius verdict, the two `js_wasm32` regressions found and fixed,
  and the dependency-patch/test-export audit.
- [WebGPU chrome physical interaction — Windows (2026-11-19)](webgpu-chrome-interactive-windows-2026-11-19.md)
  — hosted secondary-window parity, scripted drag/maximize/resize/caption
  checks on D3D12 and SDL_GPU, the chrome bugs found and fixed, and the
  hands-on items that remain for a human session.
- [Induced D3D12 backend device removal (2026-11-19)](webgpu-native-backend-removal-windows-2026-11-19.md)
  — rung 3 of the device-loss ladder: a test-only wgpu-native export calls
  `ID3D12Device5::RemoveDevice()` on the live device, the DeviceLost callback
  fires, and the normal recovery recreates the device and presents a
  replacement frame. Harness-induced, D3D12-only, not OS/driver loss or TDR.
- [Issue #165 headless UI replay and native capture](issue-165-2026-11-08.md) —
  public replay harness, History consumer regression, and Windows D3D12 capture;
  records backend-specific screenshot limits.
- [WebGPU feasibility CI matrix](webgpu-feasibility-ci-crossplatform-2026-11-19.md)
  — macOS arm64 Metal, Linux lavapipe, and headless Chromium SwiftShader runs
  of the shared fixture, with adapter identity, counter parity, and explicit
  software-adapter limits.
- [WebGPU vs SDL_GPU matched-description workload matrix](webgpu-vs-sdlgpu-workload-matrix-windows-2026-11-19.md)
  — one scene driven through both renderers with asserted description counts:
  identical, transform, color, localized layout, 1k/10k scroll, multi-window,
  and settled idle. Records 131 expectations (129 PASS, 2 FAIL), CPU
  p50/p95/p99, retained-work counters, and the SDL_GPU solid re-upload finding.
- [v0.2.1 release validation](release-v0.2.1.md) — complete v0.2.0-to-v0.2.1
  history, CI, local checks, release scope, and platform-validation boundaries.
- [Odin dev-2026-11 migration](odin-dev-2026-11.md) — Windows validation for
  the current compiler baseline; the record explicitly identifies checks that
  still require another platform or local CMake installation.
- [Issue #90 CPU paint reference](issue-90-cpu-paint-reference.md) — bounded
  CPU/GPU differential evidence for the supported test-only paint subset.
- [Issue #144 motion diagnostics and virtual-clock replay](issue-144-motion-diagnostics.md) — completed diagnostic and replay scope; broader native acceptance remains under #146.
- [Issue #106 incremental-vs-fresh-runtime invalidation oracle](issue-106-invalidation-oracle.md) — initial scope complete: two fixed-seed cases deterministically catch a mis-scoped and an omitted invalidation through public APIs at bounded cost; further corpus ideas are optional follow-ups.
- [Issue #146 motion diagnostics and Punks dogfood progress (2026-10-30)](issue-146-progress-2026-10-30.md) - closed-inspector headless overhead and application integration evidence; superseded for the release gate by the [consolidated acceptance matrix (2026-11-21)](issue-146-motion-acceptance-matrix-2026-11-21.md), which keeps platform items open.
- [macOS static/shared desktop launch matrix (2026-10-28)](macos-desktop-launch-2026-10-28.md) — current integrated-revision evidence for direct and Launch Services launches.
- [Final Windows/macOS acceptance matrix](issue-103-final.md) — maintainer
  confirmed physical input, IME, mixed-DPI, appearance, and screen-reader checks,
  alongside automated GPU and CI evidence.
- [Screen-reader validation summary](accessibility-screen-reader.md) — scope of
  the physical Narrator/NVDA and VoiceOver checks.
- [Linux native acceptance runbook](linux-native-acceptance.md) — separates
  deterministic checks from desktop-session evidence.
- [Linux NixOS/Mango validation](linux-nixos-mangowc-2026-10-23.md) — the
  recorded native Linux environment and its limitations.

## WebGPU and hosted-parity slice records

Dated evidence for the opt-in WebGPU renderer and hosted scratchpad parity.
The reports above are the current acceptance summaries; these record each
slice's method, fixtures, and limits.

- [WebGPU feasibility fixture: live browser execution (2026-11-19)](webgpu-feasibility-browser-windows-2026-11-19.md)
  — full core/compositor/effects/material readback on a hardware Chromium-family
  adapter, with the fallback flag and adapter identity.
- [Native WebGPU UI (2026-11-16)](native-webgpu-ui-windows-2026-11-16.md) —
  first native `webgpu.run` smoke, build pins, and the D3D12 window path.
- [Native WebGPU UI interactive (2026-11-19)](native-webgpu-ui-interactive-windows-2026-11-19.md)
  — real `SendInput`/`SendKeys` plus UIA: ASCII/Unicode text, focus order, UIA
  Invoke, and auxiliary-window interaction.
- [SDL_GPU reference baseline (2026-11-15)](sdl-gpu-reference-windows-2026-11-15.md)
  — pre-change capture of the reference renderer used by the matched
  comparisons.
- [Runtime construction comparison (2026-11-16)](runtime-construction-windows-2026-11-16.md)
  — Runtime-only construction, phase, allocator, and working-set samples; not a
  GPU or frame-latency result.
- [Native presenter timing probe (2026-11-17)](webgpu-timings-windows-2026-11-17.md)
  — opt-in CPU stage timings (step, acquire, encode, submit, present) and their
  explicit GPU/scanout limits.
- [Odin WebGPU one-shot callback correction (2026-11-16)](webgpu-one-shot-callbacks-windows-2026-11-16.md)
  — the eight rejected-Promise chains, the generated-build patch, and the
  exactly-once regression.
- [wgpu-native device-loss callback patch (2026-11-15)](webgpu-device-loss-callback-patch-windows-2026-11-15.md)
  — dependency-level callback delivery evidence.
- [wgpu-native post-destroy error routing (2026-11-17)](webgpu-native-error-routing-windows-2026-11-17.md)
  — C API error routing after destruction; not driver loss.
- [Native WebGPU synthetic recovery (2026-11-17)](webgpu-native-synthetic-recovery-windows-2026-11-17.md)
  — callback-injected recovery for primary and primary-plus-child windows.
- [Solid surface translation and clip retention (2026-11-17)](webgpu-solid-transform-cache-windows-2026-11-17.md)
  — retained local-coordinate solid meshes across translation and clipping.
- [WebGPU backdrop effects: Windows and browser (2026-11-15)](webgpu-backdrop-effects-windows-browser-2026-11-15.md)
  — prefix capture, Gaussian passes, and in-order composition for bounded
  markers.
- [WebGPU opt-in corrective pass (2026-11-19)](webgpu-opt-in-corrective-pass-2026-11-19.md)
  — build-time isolation, opaque `key_code`, workflow filters, and packaging
  relabelling before merge.
- [WebGPU vs SDL_GPU app-level performance (2026-11-19)](webgpu-vs-sdlgpu-perf-windows-2026-11-19.md)
  — one executable and scene, two renderers, with explicit idle and workload
  limits.
- [Hosted-WebGPU live resize and movement (2026-11-20)](webgpu-live-resize-windows-2026-11-20.md)
  — the original resize-only-on-release symptom and its fix; the latency
  follow-up is the report at the top of this page.
- [Tab drag preview fidelity (2026-11-20)](webgpu-tab-drag-preview-windows-2026-11-20.md)
  — the empty 96x28 drag card, the `Auto` preview policy, and command-for-command
  parity with the reference.
- [Scratchpad syntax-span and drag-selection parity (2026-11-20)](webgpu-scratchpad-span-selection-parity-windows-2026-11-20.md)
  — hosted paint spans and selection behavior against the reference capture.
- [Stage C slice 6: high-DPI monitor transitions (2026-11-20)](issue-211-dpi-transitions-windows-2026-11-20.md)
  — synthetic `WM_DPICHANGED`/`WM_DISPLAYCHANGE` halves, per-window scale
  independence, text re-rasterization, and hit testing.
- [Stage C slice 5: retained motion scheduling (2026-11-20)](issue-211-motion-scheduling-windows-2026-11-20.md)
  — display-deadline scheduling, the 1 ms turn-storm bound, and idle turns.
- [Theme color fidelity matrix (2026-11-20)](issue-211-theme-fidelity-windows-2026-11-20.md)
  — matched real-application themes and the byte-identical post-fix captures.
- [Stage D slice 1: topmost re-entry (2026-11-20)](issue-211-topmost-reentry-windows-2026-11-20.md)
  — the `(-8,-31)` drift, the shared Win32 guard, and the fixture.
- [Stage D slice 2: syntax highlighting across edits (2026-11-20)](issue-211-highlight-persistence-windows-2026-11-20.md)
  — span loss during typing, the retained edit path, and the edit-sequence
  regression.
- [Stage D slice 3: file and folder drag-and-drop (2026-11-20)](issue-211-drag-and-drop-windows-2026-11-20.md)
  — internal drag, native drag-out, and drop-in on D3D12, Vulkan, and SDL_GPU.
- [Per-corner surface validation (2026-11-12)](issue-118-corner-radii-2026-11-12.md)
  — Scratchpad Find/editor/status corners at four scales.
- [Live theme editing prototype (2026-11-08)](issue-166-windows-2026-11-08.md)
  — the opt-in watcher example and its Windows validation.
- [Bounded retained backdrop blur (2026-11-04)](issue-111-retained-effects.md)
  — the supported `backdrop_blur` capability, cache retry, Scratchpad Quick
  Open, and the 2026-11-20 reconciliation of SDL_GPU/WebGPU evidence against the
  research gate.

## Physical-session WebGPU runbooks

- [macOS Apple Silicon hardware validation](hardware-validation-macos.md) —
  physical Metal adapter checks, Retina/mixed-scale steps, the shared-dylib
  link contract, and the evidence template.
- [Linux hardware validation](hardware-validation-linux.md) — physical Vulkan
  adapter checks, Wayland and X11 passes, fractional scaling, and the evidence
  template.
- [Windows high-DPI validation](hardware-validation-windows-highdpi.md) — the
  by-hand per-monitor scale and mixed-scale drag runbook for this machine.

