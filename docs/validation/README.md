# Current validation

This folder keeps current acceptance summaries and reusable validation
runbooks. Dated investigation snapshots and superseded reports are in the
[archive](../archive/README.md); their historical status should not be read as
the current project status.

## Current acceptance and platform limits

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

## Physical-session WebGPU runbooks

- [macOS Apple Silicon hardware validation](hardware-validation-macos.md) —
  physical Metal adapter checks, Retina/mixed-scale steps, the shared-dylib
  link contract, and the evidence template.
- [Linux hardware validation](hardware-validation-linux.md) — physical Vulkan
  adapter checks, Wayland and X11 passes, fractional scaling, and the evidence
  template.
- [Windows high-DPI validation](hardware-validation-windows-highdpi.md) — the
  by-hand per-monitor scale and mixed-scale drag runbook for this machine.

