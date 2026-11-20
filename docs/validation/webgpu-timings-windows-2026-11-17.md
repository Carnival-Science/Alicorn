# Native WebGPU presenter timing probe — Windows

Captured 2026-11-17 from the Phase 0 migration worktree. The probe adds
opt-in, fixed-capacity CPU wall-time samples to the shared
`Hosted_Surface_Presenter`; timing is off by default. It records Runtime step,
surface acquisition, renderer encode, queue-submit call, surface-present call,
step-to-present, and input-to-submit durations. It retains the latest 256
samples and reports how many older samples were overwritten.

These are host-side CPU durations. They do not measure GPU execution, queue
completion, scanout, or photon-visible latency. The input marker is written
after a handled SDL keyboard, text, pointer, or wheel event. It is retained
only if the next Runtime step advances the retained presentation revision;
otherwise unrelated animation/maintenance frames are excluded. The timed
interval then ends after WebGPU queue submission. The interactive report
currently covers the primary SDL3 WebGPU window.

## Build and headless smoke

The Windows build used the installed Odin SDK, shared wgpu-native library, and
the pinned AccessKit compiler arguments:

```powershell
. .\tools\common.ps1
$AccessKit = Get-AlicornAccessKit
New-Item -ItemType Directory -Force out\webgpu-phase0 | Out-Null
& C:\odin\odin.exe build examples\16_native_webgpu_ui `
  -collection:alicorn=. -define:WGPU_SHARED=true -o:speed `
  -out:out\webgpu-phase0\native_webgpu_ui.exe @($AccessKit.CompilerArguments)

$OdinRoot = (& C:\odin\odin.exe root | Out-String).Trim()
Copy-Item (Join-Path $OdinRoot 'vendor\sdl3\SDL3.dll') out\webgpu-phase0\SDL3.dll -Force
Copy-Item (Join-Path $OdinRoot 'vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\wgpu_native.dll') `
  out\webgpu-phase0\wgpu_native.dll -Force
& .\out\webgpu-phase0\native_webgpu_ui.exe --smoke --timings --backend=d3d12
```

The executable built and ran on an NVIDIA GeForce RTX 2080 SUPER using the
D3D12 adapter. The single cold smoke frame reported:

| CPU metric | p50 | p95 | p99 |
| --- | ---: | ---: | ---: |
| Runtime step | 4.609 ms | 4.609 ms | 4.609 ms |
| Surface acquire | 18.7 µs | 18.7 µs | 18.7 µs |
| Renderer encode | 1.104 ms | 1.104 ms | 1.104 ms |
| Queue submit path | 1.545 ms | 1.545 ms | 1.545 ms |
| Surface present call | 272.1 µs | 272.1 µs | 272.1 µs |
| Runtime-step-to-present | 7.573 ms | 7.573 ms | 7.573 ms |

The smoke had no input sample. One cold frame is only an instrumentation
sanity check and is not a performance baseline.

## Interactive capture

Run the same executable without `--smoke`, keeping `--timings` enabled. Use the
window normally and close it to print percentiles for the latest 256 frames.
The fixture's same `render` callback can also use the SDL_GPU reference path:

```powershell
& .\out\webgpu-phase0\native_webgpu_ui.exe --smoke --backend=sdl-gpu
```

This provides the exact same UI description for a basic native smoke
comparison. It does not yet provide equivalent stage timing, pixel capture, or
a production Scratchpad/Punks workload. A comparable application A/B still
needs equivalent instrumentation and workload selection on both paths.
Visible latency still requires a display-level measurement method.

The one-frame SDL_GPU reference smoke also passed on the RTX 2080 SUPER / D3D12
adapter. It reported one primary submission, `application_build_ns=4.050 ms`,
`gpu_encode_ns=3.086 ms`, `gpu_submit_ns=553.4 µs`, `frame_p95_ns=3.723 ms`,
and `first_application_submit_ns=10.353 ms`. These fields do not have exactly
the same boundaries as the new WebGPU timings; the one-frame values are
recorded to verify the shared consumer and diagnostic path, not to claim a
backend performance win. Neither smoke produced an input-latency sample.

The automated desktop capture helper timed out twice while trying to inspect
the interactive test window (`FrameArrived timed out` / `window capture timed
out`), so this record deliberately contains no claimed click latency sample.

## Exact-head recheck (`184292b`, Windows, 2026-11-17)

The optimized native fixture was rebuilt from `184292b` on an NVIDIA GeForce
RTX 2080 SUPER and selected D3D12. Both the WebGPU `--smoke --timings`
invocation and the fixture-only SDL_GPU reference `--smoke` invocation exited
successfully. The WebGPU smoke again produced one cold frame:

| CPU metric | sample |
| --- | ---: |
| Runtime step | 5.248 ms |
| Surface acquire | 17.4 µs |
| Renderer encode | 1.008 ms |
| Queue submit path | 1.444 ms |
| Surface present call | 355.3 µs |
| Runtime-step-to-present | 8.091 ms |

It produced no input samples. The SDL_GPU reference smoke also passed through
the exact same Odin `render` callback and reported one submission. Its native
diagnostics included a 4.323 ms frame p95, 2.988 ms encode, and 1.237 ms submit
path. The timing boundaries differ, and one cold frame per backend is not a
performance comparison.

The following checks passed on the same source revision:

- `odin test renderer/webgpu`: 6 tests.
- `odin test host/presentation`: 5 tests.
- `odin test host/web`: 13 tests.
- `odin test host/sdl3`: 10 tests with the repository-pinned AccessKit
  compiler arguments and the fixture DLL directory on `PATH`.
- `odin check host/presentation -target:js_wasm32 -no-entry-point`.
- `odin check ui -target:js_wasm32 -no-entry-point`.

This recheck strengthens build and smoke evidence for the timing/fixture
change only. Physical input-to-submit samples, application-workload parity,
and display-level visible-latency measurement remain open.

### Retained-motion multi-frame probe (Windows, 2026-11-17)

The native UI fixture now has an opt-in `--timing-motion` workload. It adds a
small retained marker with a one-shot `.Reveal` target; normal fixture runs do
not add it. Both smoke commands used the same Odin `render` callback on the RTX
2080 SUPER / D3D12 system. WebGPU smoke exits after a successful presentation
and the retained work and queue drain; the SDL_GPU reference uses its own
bounded smoke duration:

```powershell
& .\out\webgpu-phase0\native_webgpu_ui.exe --smoke --timings --timing-motion --backend=d3d12
& .\out\webgpu-phase0\native_webgpu_ui.exe --smoke --timing-motion --backend=sdl-gpu
```

WebGPU recorded 48 submitted-frame samples, with these CPU wall-time
percentiles:

| Metric | p50 | p95 | p99 |
| --- | ---: | ---: | ---: |
| Runtime step | 5.8 µs | 8.6 µs | 13.7 µs |
| Surface acquire | 6.9 µs | 1.976 ms | 5.039 ms |
| Renderer encode | 92.2 µs | 168.6 µs | 691.8 µs |
| Queue submit path | 56.1 µs | 79.8 µs | 97.3 µs |
| Surface present call | 76.3 µs | 179.7 µs | 269.6 µs |
| Runtime-step-to-present | 243.1 µs | 3.580 ms | 6.681 ms |

The SDL_GPU reference recorded 37 submissions and 36 motion samples. Its
existing aggregate diagnostics reported a 17.959 ms frame p95, one text mesh
rebuild and 36 cache hits. SDL_GPU encode/submit values are accumulated totals,
so they are not directly comparable to WebGPU's per-frame percentiles. These
results demonstrate a warm, repeated same-callback retained-motion run; they
do not establish renderer performance parity, production-application behavior,
input-to-present latency, or physical display visibility. No input events were
part of this workload.
