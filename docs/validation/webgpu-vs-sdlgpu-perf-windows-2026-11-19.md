# WebGPU vs SDL_GPU app-level performance — Windows

Captured 2026-11-19 from the Phase 0 migration worktree at commit `4d3643c`
(`codex/webgpu-phase0-feasibility`) on Windows x64 build `10.0.19045`, Odin
`dev-2026-11-nightly:08539cd`, Odin-pinned wgpu-native `v29.0.1.1`, and an
NVIDIA GeForce RTX 2080 SUPER (driver `595.97`). SDL_GPU selected Direct3D 12.
The desktop session was not idle-exclusive.

This comparison uses one executable that contains both renderer paths. The
application code, UI description, window size (720×480 logical, display scale
1.0), theme, and event loop are identical; only the renderer and its submission
path differ.

## Workloads

Both workloads come from `examples/16_native_webgpu_ui` and run through its
bounded `--smoke` exit:

- **Cold retained-control scene.** One presented frame of the fixture's
  heading, two-line body text, three buttons, two status lines, text field,
  and auxiliary-window button.
- **Retained-motion scene.** The same scene plus the 24×16 marker with a
  one-shot `.Reveal` translation. WebGPU and SDL_GPU both drive it from the
  same Odin `render` callback.

```powershell
.\tools\bench_webgpu_vs_sdlgpu.ps1 -Odin C:\odin\odin.exe -Runs 5 `
  -OutputDir .\out\webgpu-phase0\perf-2026-11-19
```

The harness builds the example once with `-define:WGPU_SHARED=true`, the
repository-pinned AccessKit arguments, and `-o:speed`, then runs five times per
configuration:

| Configuration | Arguments |
| --- | --- |
| SDL_GPU | `--smoke --backend=sdl-gpu` |
| WebGPU D3D12 | `--smoke --timings --backend=d3d12` |
| WebGPU Vulkan | `--smoke --timings --backend=vulkan` |
| SDL_GPU motion | `--smoke --timing-motion --backend=sdl-gpu` |
| WebGPU D3D12 motion | `--smoke --timings --timing-motion --backend=d3d12` |
| WebGPU Vulkan motion | `--smoke --timings --timing-motion --backend=vulkan` |

## Metrics and boundaries

All values are host CPU wall time. Neither path reports GPU execution,
queue-completion, scanout, or photon latency here.

- **App build.** SDL_GPU: `application_build_ns` accumulated over primary
  submissions. WebGPU: `runtime_step_ns_p50`, the hosted Runtime step that
  includes the application description when the Runtime is invalidated.
  Boundaries are close but not identical.
- **Renderer encode.** SDL_GPU: `gpu_encode_ns` accumulated over primary
  submissions, including hidden HUD/inspector draw attempts. WebGPU:
  `renderer_encode_ns`, the shared presenter's display-list encode.
- **Submit call.** SDL_GPU: `gpu_submit_ns`, the
  `SDL_SubmitGPUCommandBufferAndAcquireFence` call, including fence acquisition.
  WebGPU: `queue_submit_ns`, the `wgpu.QueueSubmit` call only.
- **Present call.** WebGPU only (`surface_present_call_ns`). SDL_GPU has no
  equivalent stage.
- **Whole frame.** WebGPU only (`step_to_present_ns`). SDL_GPU's
  `frame_p95_ns` includes the fixed 3-second smoke wait after the last frame,
  so it is omitted as non-comparable.
- **Counters.** SDL_GPU reports text mesh rebuilds, cache hits, and vertex
  upload counts. The shared WebGPU presenter does not expose an equivalent
  app-level text/vertex upload counter, so those numbers are recorded on the
  SDL_GPU side only and are not compared.

Each table cell is the median of five runs with the minimum in parentheses.
SDL_GPU totals were divided by the run's primary submission count.

## Cold retained-control scene

| Metric | SDL_GPU (D3D12) | WebGPU D3D12 | WebGPU Vulkan |
| --- | ---: | ---: | ---: |
| Submitted frames | 1 | 1 | 1 |
| App build (ms) | 3.858 (3.808) | 4.124 (3.687) | 3.903 (3.683) |
| Renderer encode (ms) | 2.052 (1.929) | 1.222 (1.184) | 1.110 (1.061) |
| Submit call (ms) | 0.575 (0.546) | 1.533 (1.495) | 0.101 (0.095) |
| Present call (ms) | — | 0.245 (0.239) | 0.085 (0.061) |
| Runtime step to presented (ms) | — | 7.098 (6.951) | 5.551 (5.033) |
| First submission from loop start (ms) | 11.484 (11.443) | — | — |

The SDL_GPU first-submission value includes window/device/swapchain setup. The
WebGPU value starts inside the presenter, so the row is not a backend
comparison and is included only to identify the boundary.

## Retained-motion scene

| Metric | SDL_GPU (D3D12) | WebGPU D3D12 | WebGPU Vulkan |
| --- | ---: | ---: | ---: |
| Submitted frames | 37 (36) | 45 (45) | 42 (42) |
| App build per frame (µs) | 110.6 (103.6) | 7.6 (6.4) | 7.5 (6.6) |
| Renderer encode per frame (µs) | 124.5 (114.1) | 113.3 (96.3) | 60.5 (56.5) |
| Submit call per frame (µs) | 170.5 (153.7) | 72.0 (56.8) | 48.4 (42.0) |
| Present call per frame (µs) | — | 89.7 (80.7) | 22.8 (19.6) |
| Runtime step to presented p50 (µs) | — | 305.7 (255.8) | 167.3 (144.7) |
| Text mesh rebuilds / cache hits / vertex uploads | 1 / 36 / 1 | — | — |

The app-build row is **not** an equivalent measurement: the WebGPU hosted
motion path presented retained frames without re-running the application
description on every motion frame (Runtime step p50 7.6 µs across 45 samples),
while the SDL_GPU loop rebuilt the application description for every submitted
motion frame (accumulated build time divided by 37 submissions). Renderer
encode and submit are directly normalized per frame, but see the boundary
differences above.

## Confounders

- SDL_GPU runs through SDL's native Direct3D 12 backend; WebGPU runs through
  wgpu-native's D3D12 or Vulkan backend. Queue construction, submission
  flushing, and fence ownership differ.
- The WebGPU D3D12 submit-call path was consistently slower than the Vulkan
  path for the same scene. This record does not attribute the difference to a
  cause.
- SDL_GPU's encode total includes hidden DevTools/inspector draw attempts that
  the WebGPU presenter does not run. The WebGPU numbers are the app display
  list only.
- The two paths produced different motion-frame counts (45/42 vs 37), and the
  WebGPU path did not rebuild the description per motion frame. Per-frame
  values are normalized, but the work behind each frame was not identical.
- Five runs per configuration on an interactive, non-idle desktop cannot
  characterize variance. The cold SDL_GPU app-build maximum (5.152 ms) shows
  startup variance.
- No GPU timestamps, queue-completion intervals, display-level frame pacing,
  or visible latency were measured. The fixture is deliberately small and is
  not a production Scratchpad/Punks workload.

## Artifacts

- `docs/validation/raw/webgpu-vs-sdlgpu-perf-2026-11-19.txt`: per-configuration
  median/min/max summary.
- The harness also writes `perf-runs.csv` and one raw log per run under its
  `OutputDir`; those machine-local files are intentionally ignored.

## Limits

This fills the missing same-workload, same-machine app-level CPU comparison
for one fixture. It does not establish performance parity or a WebGPU win, and
it does not close the production-application or GPU-execution parts of the
Phase 0 performance gap.
