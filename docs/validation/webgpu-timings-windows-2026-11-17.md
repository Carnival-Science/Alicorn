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
| Runtime step | 4.528 ms | 4.528 ms | 4.528 ms |
| Surface acquire | 14.0 µs | 14.0 µs | 14.0 µs |
| Renderer encode | 990.4 µs | 990.4 µs | 990.4 µs |
| Queue submit path | 1.462 ms | 1.462 ms | 1.462 ms |
| Surface present call | 294.5 µs | 294.5 µs | 294.5 µs |
| Runtime-step-to-present | 7.303 ms | 7.303 ms | 7.303 ms |

The smoke had no input sample. One cold frame is only an instrumentation
sanity check and is not a performance baseline.

## Interactive capture

Run the same executable without `--smoke`, keeping `--timings` enabled. Use the
window normally and close it to print percentiles for the latest 256 frames.
The build and run above measure the fixture application, not Scratchpad or
Punks. A comparable application A/B still needs equivalent instrumentation
and workload selection on the SDL_GPU and WebGPU paths. Visible latency still
requires a display-level measurement method.

The automated desktop capture helper timed out twice while trying to inspect
the interactive test window (`FrameArrived timed out` / `window capture timed
out`), so this record deliberately contains no claimed click latency sample.
