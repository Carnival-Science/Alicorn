# Current validation

This folder keeps current acceptance summaries and reusable validation
runbooks. Dated investigation snapshots and superseded reports are in the
[archive](../archive/README.md); their historical status should not be read as
the current project status.

## Current acceptance and platform limits

- [Bounded filled-rectangle batches — Windows (2026-11-20)](issue-200-rectangles-windows-2026-11-20.md)
  — 1,026-rectangle native readback on D3D12 and Vulkan against an independent
  CPU compositor and wxWidgets 3.2.11 GDI captures, the batched-versus-retained
  repaint comparison, per-update allocation and idle checks, and the 1,365-rect
  vertex-budget cap.
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
- [Issue #106 incremental-vs-fresh-runtime invalidation oracle](issue-106-invalidation-oracle.md) — bounded deterministic test oracle for retained invalidation misuse; follow-up corpus remains open.
- [Issue #146 motion diagnostics and Punks dogfood progress (2026-10-30)](issue-146-progress-2026-10-30.md) — closed-inspector headless overhead and application integration evidence; native scheduler acceptance remains open.
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
  — the supported `backdrop_blur` capability, cache retry, and Scratchpad Quick
  Open.

## Physical-session WebGPU runbooks

- [macOS Apple Silicon hardware validation](hardware-validation-macos.md) —
  physical Metal adapter checks, Retina/mixed-scale steps, the shared-dylib
  link contract, and the evidence template.
- [Linux hardware validation](hardware-validation-linux.md) — physical Vulkan
  adapter checks, Wayland and X11 passes, fractional scaling, and the evidence
  template.
- [Windows high-DPI validation](hardware-validation-windows-highdpi.md) — the
  by-hand per-monitor scale and mixed-scale drag runbook for this machine.

