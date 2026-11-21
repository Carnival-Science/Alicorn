# Issue #119: two-stop gradients — Windows native acceptance

Updated 2026-11-20. This record closes the native pixel and performance
measurements that were outstanding for
[#119](https://github.com/Carnival-Science/Alicorn/issues/119). The bounded
two-stop implementation itself landed before the v0.2.2 release; this run adds
real D3D12 readbacks, an independent CPU-reference frame comparison, replay
equality, and separated CPU-stage timings.

## Environment

| Item | Value |
| --- | --- |
| Machine | NVIDIA GeForce RTX 2080 SUPER, 8192 MiB, driver 595.97 |
| OS | Windows 10 Home 10.0.19045 (22H2) |
| Renderer | SDL_GPU `direct3d12`, offscreen `R8G8B8A8_UNORM` target |
| Odin | `dev-2026-11-nightly:08539cd` (`C:\odin\odin.exe`) |
| Base revision | `67b31b8` (v0.2.2 release), branch `codex/issue-119-110-acceptance` |

The surface contract is the one documented in
[`docs/themes.md`](../themes.md#static-two-stop-gradients): horizontal or
vertical axis, two theme color roles, linear-sRGB channel interpolation, equal
stop alpha, command opacity multiplied once, and a gradient field measured from
the translated unclipped bounds. The SDL_GPU target is non-sRGB UNORM and the
renderer interpolates the authored linear channel values directly. No shader
variant, texture, render target, extra pass, or motion schedule is involved.

## Harness

```powershell
. .\tools\common.ps1
$ak = Get-AlicornAccessKit
$root = (Resolve-Path .).Path
C:\odin\odin.exe build native\blend_validation_entry "-collection:alicorn=$root" `
  @($ak.CompilerArguments) -out:out\alicorn_blend_validation.exe
Copy-Item C:\odin\vendor\sdl3\SDL3.dll out\SDL3.dll -Force
.\out\alicorn_blend_validation.exe

.\tools\bench_material.ps1 -Odin C:\odin\odin.exe   # CPU mesh expansion
```

The native harness now contains three gradient-specific stages:

1. the existing four-scale point probes (`surface_gradient_gpu_readback`);
2. a new full-frame comparison against `tests/paint_reference`, which
   rasterizes the two-stop field independently per pixel
   (`surface_gradient_cpu_reference`);
3. a new staged benchmark that measures `native_solid_build` (mesh build),
   vertex upload, command encode, `SubmitGPUCommandBufferAndAcquireFence`, and
   fence wait separately (`surface_stage_benchmark`).

Raw output: [issue-119-gradients-windows-2026-11-20.txt](raw/issue-119-gradients-windows-2026-11-20.txt).

## Acceptance mapping

| Issue requirement | Evidence | Result |
| --- | --- | --- |
| Pixel readback for clipping | Clipped horizontal/vertical probes at 1, 1.25, 1.5, 2; clipped pixels remain background; translated field does not restart at the clip edge | PASS |
| Semi-transparent overlap | Stops with `α=0.5` and `α=0.6`, command opacity `0.8`/`0.75`, source-over on an opaque background; exact CPU/GPU frame match | PASS |
| Shape edges | Rounded two-stop gradient with per-corner radii at four scales; corner probes and anti-aliased fringe | PASS |
| Theme changes | `runtime/style_surface_test.odin`: `test_surface_gradient_resolves_theme_stops_and_invalidates_paint_only` replaces an endpoint token, advances Paint only, and re-resolves without layout/metrics/typography work | PASS |
| 1/1.25/1.5/2 DPI | All point probes and rounded/clipped cases run at all four scales | PASS |
| Replay equality | Full 128x128 frame rendered twice; `replay_equal true` | PASS |
| Resource cleanup | The runtime gradient test retires the surface and asserts the semantic style, computed cache, and node are released; renderer teardown completes without a pending GPU resource | PASS |
| Vertex count / upload bytes / draw calls | 6 vertices per rectangular surface, 55,296 bytes per 256-surface batch, 256 draw slots, 1 pass, 0 additional passes | PASS |
| CPU/GPU p95 | Staged CPU table plus offscreen submit-to-fence/readback distribution below | Recorded |
| sRGB/linear contract | Non-sRGB `R8G8B8A8_UNORM`; CPU reference uses the same linear channel interpolation and matched with 0 mismatched pixels / 0 channel error | PASS |
| GO decision | The gradient reuses the solid quad/vertex path, adds no pass/draw/texture, and adds ~46 µs p50 mesh build per 256 surfaces at 2x; application paint is materially simpler (example 13) | GO retained |

### Pixel results

The independent CPU reference evaluates `t=(x+0.5-bounds.x)/bounds.w` (or the
vertical equivalent) and composites with the same straight-alpha equation. It
is compared with the GPU readback over every channel of every pixel in a
128x128 frame containing horizontal, vertical, translated, and clipped
gradients.

| Check | Result |
| --- | --- |
| Full-frame CPU/GPU mismatch | 0 pixels, 0 bytes max channel error, tolerance 2/255 |
| Replay equality | Byte-identical |
| Horizontal/vertical stops and midpoints | Pass at 1, 1.25, 1.5, 2 |
| Rounded corner and anti-aliased edge | Pass at 1, 1.25, 1.5, 2 |
| Clipped surface | Pass at 1, 1.25, 1.5, 2 |
| Independent solid stroke over gradient | Pass at 1, 1.25, 1.5, 2 |
| Source-over with translucent stops | Pass at 1, 1.25, 1.5, 2 |

Because the CPU oracle uses authored linear channels and the UNORM target has
no sRGB transfer, the exact match also guards against an accidental
sRGB-encode/decode step: a gamma-encoded midpoint would differ by far more
than the 2/255 tolerance.

## Performance

### CPU stages, 256 surfaces per batch, scale 2

31 samples per workload, separate processes; p50/p95 in nanoseconds. "Wait" is
the CPU blocking fence wait for the offscreen readback, not a presented frame.

| Workload | Vertices | Upload bytes | Draws | Passes | Build p50/p95 | Upload p50/p95 | Encode p50/p95 | Submit p50/p95 | Wait p50/p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Rectangle solid | 1,536 | 55,296 | 256 | 1 | 104.2 / 130.3 µs | 8.0 / 29.5 µs | 14.5 / 18.5 µs | 28.5 / 45.3 µs | 80.7 / 666.0 µs |
| Rectangle gradient | 1,536 | 55,296 | 256 | 1 | 150.5 / 197.0 µs | 8.0 / 10.5 µs | 14.4 / 21.6 µs | 28.8 / 73.9 µs | 77.1 / 362.3 µs |

The gradient adds 46.3 µs p50 (+44.4%) and 66.7 µs p95 to mesh expansion for
256 surfaces, or about 0.18 µs per surface p50. Upload bytes, draw calls, and
pass count are identical. The upload/encode/submit stages are statistically
indistinguishable from solid at this sample size.

### Offscreen completion round trip (51 alternating samples)

| Workload | p50 | p95 |
| --- | ---: | ---: |
| Rectangle solid | 307.4 µs | 895.0 µs |
| Rectangle gradient | 334.8 µs | 490.8 µs |

This is a synchronous `submit → fence → map` round trip for 256 surfaces,
including readback. It is not a presented-frame or GPU-execution timestamp
measurement. No GPU timestamp feature exists in this harness, so no GPU p95 is
claimed.

### CPU mesh benchmark (benchmarks/native_material)

| Shape | Vertices/surface | Upload bytes / 256 | Build p50 / p95 per surface |
| --- | ---: | ---: | ---: |
| Rectangle solid | 6 | 55,296 | 9.8 / 14.8 ns |
| Rectangle gradient | 6 | 55,296 | 21.5 / 28.5 ns |
| Uniform rounded solid | 324 | 2,985,984 | 2,795 / 4,683 ns |
| Uniform rounded gradient | 324 | 2,985,984 | 3,215 / 5,023 ns |
| Per-corner rounded solid | 324 | 2,985,984 | 2,873 / 4,507 ns |
| Per-corner rounded gradient | 324 | 2,985,984 | 3,298 / 5,088 ns |

## Residual limits

- This run covers Windows D3D12, the production SDL_GPU backend on this
  machine. macOS Metal pixel acceptance was not rerun because no macOS hardware
  is available in this environment; the earlier macOS record only compiled the
  target and measured CPU geometry. The shared SDL_GPU mesh path and the
  format/linear contract are backend-neutral, but Metal pixels are not claimed
  here.
- No integrated-GPU comparison was made.
- The timing tables are CPU stages plus a fence wait. They are not presented
  frame latency, GPU execution time, or power measurements.
- The generated geometry/mesh and paint caches are retained and bounded; idle
  surfaces do not schedule work. No new idle-work instrumentation was added for
  this acceptance because the gradient adds no scheduler, pass, or resource.

## Verdict

**Accepted for #119 on the Windows D3D12 native backend.** The two-stop fill is
pixel-correct against an independent CPU reference, preserves clipping and
rounded/source-over behavior at four DPI scales, replays identically, and adds
no renderer resource or pass. The only unrecorded platform is macOS Metal,
which requires hardware not present in this session; the issue's decision gate
is satisfied by the production backend evidence and the shared, backend-neutral
geometry path.
