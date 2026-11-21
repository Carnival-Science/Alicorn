# Matched-description workload matrix

One Odin scene drives both native host paths:

- `--backend=sdl-gpu` uses SDL_GPU through `ui.run`.
- `--backend=d3d12` or `--backend=vulkan` uses the shared WebGPU presenter.

The default harness is `tools/bench_webgpu_vs_sdlgpu.ps1 -Matrix`, which builds
this directory once, stages `SDL3.dll`/`wgpu_native.dll`, runs every scenario
five times per renderer, and writes `matrix-runs.csv`, `matrix-expectations.csv`,
and `matrix-summary.md`.

```powershell
.\tools\bench_webgpu_vs_sdlgpu.ps1 -Odin C:\odin\odin.exe -Matrix `
  -MatrixRuns 5 -Frames 32 -IdleHoldMs 1200 `
  -OutputDir .\out\webgpu-phase0\matrix-2026-11-19
```

Scenarios: `identical`, `transform`, `color`, `layout`, `scroll` (with
`--items`), `multiwindow`, `settled`, and `scratchpad`.

`--workload=scratchpad` selects the issue #229 Scratchpad-shaped scene
(`benchmarks/scratchpad_scene`): a 10,000-line virtualized editor, a 1,000-node
expandable workspace tree, closable document tabs, a pinned rounded panel with a
gradient accent, a focused command field with selection, a minimap, and a
status strip. It accepts `--interaction=typing|scroll|selection|resize|tabs|idle`
and runs on the same SDL_GPU and hosted WebGPU paths as the other scenarios.
The scene is also exercised headlessly by `testui/scratchpad_scene_test.odin`.

Dedicated baseline runner:

```powershell
.\tools\bench_scratchpad_workload.ps1 -Odin C:\odin\odin.exe `
  -Runs 5 -Frames 24 -OutputDir out\scratchpad-perf
```

It writes per-run stage and counter CSVs plus a Markdown summary with
p50/p95/p99 stage attribution. Every scenario accepts `--workload=<name>`,
`--frames=<n>`, `--items=<n>`, `--smoke`, and `--smoke-hold-ms=<n>`. The WebGPU
paths additionally accept `--timings`; the harness always passes it.

Baseline record:
[`docs/validation/issue-229-phase1-baseline-2026-11-21.md`](../../docs/validation/issue-229-phase1-baseline-2026-11-21.md).

Description scenarios use one worker wake per planned frame. The driver waits
for the previous description to finish, pauses 25 ms so the host can submit it,
then posts one wake. Motion scenarios (`transform`, `multiwindow`) do not have a
driver: they declare one retained `ui.motion` reveal and let each host present
retained frames. `multiwindow` opens one auxiliary window, animates both, then
closes the auxiliary window through a scheduled owner-thread wake so primary
shutdown does not span two GPU windows.

The matrix measures host CPU wall time and retained-work counters only. It does
not measure GPU execution, scanout, or visible latency.

Validation record:
[`docs/validation/webgpu-vs-sdlgpu-workload-matrix-windows-2026-11-19.md`](../../docs/validation/webgpu-vs-sdlgpu-workload-matrix-windows-2026-11-19.md).
