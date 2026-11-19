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
`--items`), `multiwindow`, and `settled`. Every scenario accepts
`--workload=<name>`, `--frames=<n>`, `--items=<n>`, `--smoke`, and
`--smoke-hold-ms=<n>`. The WebGPU paths additionally accept `--timings`; the
harness always passes it.

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
