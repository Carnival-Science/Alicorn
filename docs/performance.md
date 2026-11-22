# Performance evidence

These are author-run, workload-specific measurements. They are intended to
be reproducible and falsifiable, not to claim that Alicorn is faster than
another GUI framework. Read the machine, compiler, build mode, workload, and
limitations before using a number.

## Reports

- [v0.3.0 measured performance ledger — Windows (2026-11-21)](benchmarks/v030-performance-ledger.md):
  one consolidated stage ledger for the #227/#228/#229/#230/#231 work, with
  measured results, report and raw links, per-stage limits, the #231
  localization map, the Scratchpad A/B headline, and which issues remain open.
- [Issue #229 Phase 2 description reuse — Windows
  (2026-11-21)](validation/issue-229-phase2-description-reuse-2026-11-21.md):
  exact retained-description and structure-sequence gates, field-coverage
  audit and hash extensions, paired before/after across SDL_GPU, D3D12, and
  Vulkan with a high-churn control, and the scaled real-Scratchpad
  expectation.
- [Issue #229 Phase 1 performance harness and baseline — Windows
  (2026-11-21)](validation/issue-229-phase1-baseline-2026-11-21.md):
  Scratchpad-shaped workload matrix across SDL_GPU, D3D12, and Vulkan;
  per-stage `Frame_Stats` attribution; per-interaction percentiles, allocation
  and visit counters; real-Scratchpad `--timings` cross-check; measured
  instrumentation cost.
- [v0.2.1 candidate performance scorecard — Windows
  (2026-11-04)](benchmarks/performance-scorecard-v0.2.1-windows-2026-11-04.md):
  matched construction, retained-locality, text, motion, and Scratchpad
  measurements with explicit platform and workload limits.
- [Matched Scratchpad A/B — Windows
  (2026-11-04)](benchmarks/scratchpad-ab-windows-2026-11-04.md):
  application-build callbacks, first submission, CPU, working set, and resize
  acceptance boundaries.
- [Issue #157 construction CPU attribution — macOS
  (2026-11-04)](benchmarks/issue-157-construction-cpu-macos-2026-11-04.md):
  deferred trace formatting results and the accepted retained-construction
  cost.
- [Wrapped text/layout](benchmarks/text-layout.md): the same 20,000-logical-row
  headless scroll/reflow workload, measured separately on Windows and macOS,
  with raw per-run output for both platforms.
- [Native material flat-path benchmark](benchmarks/native-material-windows.md):
  compares CPU expansion for direct solid quads and canonical flat materials.
- [Retained-work suite on macOS](benchmarks/retained-work-macos.md): tree
  sizes, retained-region reuse, keyed churn, true-idle counters, custom-surface
  locality, and million-item virtualization. One Mac run; raw output included.
- [Retained-work suite on Windows](benchmarks/retained-work-windows.md): the
  same headless workloads repeated in three fresh processes, with raw output.
- [Native hello on macOS](benchmarks/native-hello-macos.md): Metal host,
  one controlled no-input idle observation, process RSS/CPU sampling, binary
  size, and qualified startup markers.
- [Native and dogfood apps on Windows](benchmarks/native-dogfood-windows.md):
  Direct3D 12 idle/submission, process-memory and qualified startup samples,
  plus bounded Monitor, History, and fixed-fixture Scope smoke runs.
- [Windows performance audit (2026-10-27)](benchmarks/performance-audit-windows-2026-10-27.md):
  matched retained-runtime baseline/candidate samples, current text/material
  benchmarks, and measured release-size/buffer-capacity experiments.
- [Final Windows refresh (2026-10-28)](benchmarks/performance-final-windows-2026-10-28.md):
  final release-candidate rerun and same-machine comparison with the
  post-merge optimized baseline.
- [Windows runtime performance audit (2026-10-28)](benchmarks/performance-audit-windows-2026-10-28.md):
  unchanged-root allocation reduction, initial-construction attribution, and
  current retained/text/material workload evidence.

## WebGPU and hosted-path measurements

These are validation records, not cross-renderer guarantees. Each uses one
executable, scene, theme, and event loop with only the renderer or host changed.

- [WebGPU vs SDL_GPU matched-description workload matrix (2026-11-19)](validation/webgpu-vs-sdlgpu-workload-matrix-windows-2026-11-19.md)
  — 131 asserted expectations across identical, transform, color, localized
  layout, 1k/10k scroll, multi-window, and settled idle, with CPU percentiles and
  retained-work counters.
- [WebGPU vs SDL_GPU app-level performance (2026-11-19)](validation/webgpu-vs-sdlgpu-perf-windows-2026-11-19.md)
  — one application scene through both renderers, with explicit idle limits.
- [Hosted live-resize presentation latency (2026-11-20)](validation/issue-211-live-resize-performance-windows-2026-11-20.md)
  — per-frame inter-present latency, message-to-present stretch, reconfiguration
  cost, and the geometry-dispatch change that cut D3D12's p50 stretch window
  from 7.3 ms to 2.6 ms.
- [Native WebGPU presenter timing probe (2026-11-17)](validation/webgpu-timings-windows-2026-11-17.md)
  — host-side CPU stages only; no GPU execution or scanout claim.

## Reproduce

From a fresh checkout with the documented Odin toolchain:

```sh
./tools/bench.sh
./tools/bench_text_layout.sh
./tools/bench_material.sh
```

The equivalent PowerShell entry points are `tools/bench.ps1` and
`tools/bench_text_layout.ps1`; the material benchmark uses
`tools/bench_material.ps1`. The scripts accept an explicit Odin path.
Native-host measurements require a supported desktop session; commands,
environment, raw captures, and workload limitations are in the platform
reports above.

## Coverage boundary

The evidence contains Windows/macOS focused text-layout results, retained-work
results on both platforms, native-host idle/startup samples, and bounded Windows
dogfood runs for Monitor, History, and Scope. Monitor observes
the live machine; History uses a 27-commit local repository; Scope uses the
published deterministic 100,000-event fixture. Only native hello is used for
the controlled idle CPU/submission claim. The dogfood smoke captures are short
startup/load samples, not steady-state idle or long-term memory tests. These
are author-run, workload-specific baselines. Never compare results from
different machines as if they were the same experiment.
