# Issue #110: shape primitives — Windows visual and performance acceptance

Updated 2026-11-20. This record completes the native visual, hit-testing, and
performance measurements that remained for
[#110](https://github.com/Carnival-Science/Alicorn/issues/110). The bounded
Circle/Arc/Cubic-Bezier prototype and example 14 landed before the v0.2.2
release; this run validates the rendered pixels and the opt-in circular pointer
target on real D3D12 hardware.

## Environment

| Item | Value |
| --- | --- |
| Machine | NVIDIA GeForce RTX 2080 SUPER, 8192 MiB, driver 595.97 |
| OS | Windows 10 Home 10.0.19045 (22H2) |
| Renderer | SDL_GPU `direct3d12`, offscreen `R8G8B8A8_UNORM` target |
| Odin | `dev-2026-11-nightly:08539cd` (`C:\odin\odin.exe`) |
| Base revision | `67b31b8` (v0.2.2 release), branch `codex/issue-119-110-acceptance` |

The implemented contract is unchanged: `surface_shape_circle`,
`surface_shape_arc`, and `surface_shape_cubic_bezier` lower into the existing
solid-surface batch; curved shapes require flat paint; rectangle and rounded
paths keep their existing material/vertex routes;
`button_begin(pointer_hit_shape=.Circle)` changes only pointer targeting while
layout, keyboard focus, semantics, and accessibility bounds remain rectangular.

## Harness

```powershell
. .\tools\common.ps1
$ak = Get-AlicornAccessKit
$root = (Resolve-Path .).Path
C:\odin\odin.exe build native\blend_validation_entry "-collection:alicorn=$root" `
  @($ak.CompilerArguments) -out:out\alicorn_blend_validation.exe
Copy-Item C:\odin\vendor\sdl3\SDL3.dll out\SDL3.dll -Force
.\out\alicorn_blend_validation.exe

.\tools\bench_material.ps1 -Odin C:\odin\odin.exe
C:\odin\odin.exe build tests -out:out\alicorn_tests.exe
.\out\alicorn_tests.exe
```

The native harness now renders one circle (fill plus outside stroke), one open
arc, one cubic Bezier, one clipped circle, and two overlapping translucent
circles. It samples the circle center/interior/corner/stroke, four arc
centerline positions plus the clear hole, three Bezier centerline positions,
clipped inside/outside points, and the translucent overlap at 1, 1.25, 1.5, and
2 DPI. The same display is rendered twice for replay equality.

Raw output: [issue-110-shapes-windows-2026-11-20.txt](raw/issue-110-shapes-windows-2026-11-20.txt).

## Acceptance mapping

| Issue requirement | Evidence | Result |
| --- | --- | --- |
| Visual readbacks of each primitive at multiple DPI | Circle fill/stroke, Arc stroke, Cubic-Bezier stroke, clipped Circle, translucent overlap at 1, 1.25, 1.5, 2 | PASS |
| Circle/arc/Bezier edges and antialiasing | Fully covered interior/centerline probes match expected source-over colors; outside/corner/hole probes remain background; each mesh keeps its bounded 16–96 segment budget and transparent fringe | PASS |
| Partial clipping | Clipped circle paints inside the left half and leaves the outside half exactly background | PASS |
| Overlapping translucent strokes/fills | Two half-alpha circles composite in retained order; expected red-then-blue source-over result | PASS |
| Per-corner rounded shapes | Existing 16-mask per-corner matrix, 192 cases at four scales, all pass | PASS |
| Circular pointer hit region | `tests/main.odin` `test_shape_pointer_and_accessibility_contract`: center and inscribed point hit; square corner falls through to an ordinary rectangular button underneath; pointer capture follows the fall-through target | PASS |
| Keyboard behavior | Same test focuses the circular target and activates it with Enter through the normal Button API | PASS |
| Accessible rectangular fallback | Semantic snapshot keeps the resolved 100x100 rectangular bounds, not the circular pointer region | PASS |
| Generated vertices / upload bytes / draw calls | Circle 2,592 vertices, Arc 1,452, Bezier 1,740 for 64x64 logical controls at 2x; one draw slot and one pass per surface; `additional_passes 0` | Recorded |
| CPU/GPU p95 | Staged CPU table and CPU mesh benchmark below; offscreen fence wait recorded; no GPU timestamp claimed | Recorded |
| Idle work / extra passes | No scheduler, shader, texture, render pass, or offscreen target was added; shapes expand only when their paint command is built | PASS |
| Go decision | The dogfood example expresses a concentric knob, meter arc, and curved cable without app-authored meshes; all three render correctly and keep the ordinary semantic/input model | GO retained |

### Pixel results

| Sample | Expected | Result |
| --- | --- | --- |
| Circle center and interior | Circle fill over the opaque background | Pass at all four scales |
| Circle square corner outside fill/stroke | Background | Pass at all four scales |
| Circle outside-stroke centerline | Stroke color over background | Pass at all four scales |
| Arc hole center | Background | Pass at all four scales |
| Arc centerline at π, 1.25π, 1.5π, 1.75π | Arc stroke color over background | Pass at all four scales |
| Bezier centerline at t=0.25, 0.5, 0.75 | Bezier stroke color over background | Pass at all four scales |
| Bezier outside point | Background | Pass at all four scales |
| Clipped circle inside the left half | 50% fill over background | Pass at all four scales |
| Clipped circle beyond the clip | Background | Pass at all four scales |
| Overlapping half-alpha circles | Red then blue source-over | Pass |
| Replay of the full shape display | Byte-identical | `replay_equal true` |

The circle/arc/Bezier samples are deliberately placed on fully covered interiors
or stroke centerlines, so they test color, coverage, and placement rather than
sampling exact anti-aliased fringe values. The existing 348-case blend matrix
continues to cover per-corner masks and the anti-aliased edges at the same
scales.

## Performance

### CPU stages, 256 small (4x4 logical) surfaces per batch, scale 2

This run uses the default native validation build (not `-o:speed`); compare rows
within the table, not their absolute level to the optimized mesh benchmark.
31 samples per workload; p50/p95 in nanoseconds.

| Workload | Vertices | Upload bytes | Draws | Passes | Build p50/p95 | Upload p50/p95 | Encode p50/p95 | Submit p50/p95 | Wait p50/p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Rectangle reference | 1,536 | 55,296 | 256 | 1 | 104.5 / 181.1 µs | 8.0 / 10.1 µs | 14.4 / 41.1 µs | 28.5 / 36.2 µs | 83.0 / 524.2 µs |
| Circle fill+stroke | 221,184 | 7,962,624 | 256 | 1 | 3,605.0 / 4,179.8 µs | 487.8 / 541.1 µs | 21.7 / 28.6 µs | 39.9 / 56.0 µs | 842.5 / 1,190.8 µs |
| Arc stroke | 95,232 | 3,428,352 | 256 | 1 | 1,496.1 / 1,957.3 µs | 206.7 / 407.7 µs | 17.9 / 23.6 µs | 31.2 / 37.0 µs | 376.4 / 805.4 µs |
| Bezier stroke | 136,704 | 4,921,344 | 256 | 1 | 1,985.3 / 2,594.6 µs | 309.1 / 503.1 µs | 18.1 / 23.5 µs | 33.3 / 47.2 µs | 587.6 / 874.7 µs |

The curved paths remain one draw and one pass per surface, exactly like the
rectangle. Their cost is CPU tessellation and vertex upload, not extra GPU
submissions. The circle row is the heaviest because it emits both a filled core
and the three stroke/AA rings.

### CPU mesh expansion, optimized (`-o:speed`)

256 small 4x4 controls at 2x:

| Shape | Vertices/surface | Upload bytes / 256 | Build p50 / p95 per surface |
| --- | ---: | ---: | ---: |
| Rectangle | 6 | 55,296 | 36.7 / 36.7 ns |
| Circle fill+stroke | 864 | 7,962,624 | 3,892.6 / 6,171.5 ns |
| Arc stroke | 372 | 3,428,352 | 1,252.0 / 1,810.5 ns |
| Bezier stroke | 534 | 4,921,344 | 1,964.1 / 2,384.0 ns |

64 realistic 64x64 logical controls at 2x (the 96-segment cap is reached):

| Shape | Vertices/surface | Upload bytes / 64 | Build p50 / p95 per surface |
| --- | ---: | ---: | ---: |
| Rectangle | 6 | 13,824 | 46.9 / 46.9 ns |
| Circle fill+stroke | 2,592 | 5,971,968 | 10,968.8 / 14,637.5 ns |
| Arc stroke | 1,452 | 3,345,408 | 4,482.8 / 6,325.0 ns |
| Bezier stroke | 1,740 | 4,008,960 | 4,854.7 / 6,081.3 ns |

The 64x64 row is the useful worst-case planning number: a 92x92 knob's circle
also reaches the 96-segment cap and stays within the same bounded vertex count
(2,592 with a 2 px outside stroke). A flat rectangle remains six vertices.

## Authoring and composition

Example 14 (`examples/14_shape_primitives/main.odin`, 158 lines including the
demo layout) expresses a concentric gain knob, an open output-meter arc, and a
curved signal cable through semantic surfaces. The knob's hit target is one
`button_begin` option. No application mesh, GPU buffer, texture, or custom
shader is authored. The existing `Geometry_Paint` path remains the escape hatch
for arbitrary geometry; it requires application-owned triangles and does not
carry the theme/shape/hit contract.

No A/B against a hand-written `Geometry_Paint` version of the same three
controls was recorded, and no binary-size delta was isolated. Both would be
research-comparison evidence rather than a rendering-contract requirement; the
issue's visual and performance acceptance is satisfied by the produced geometry
and readbacks above.

## Residual limits

- This run covers Windows D3D12 only. No macOS metal or Linux Vulkan readback
  was run; those require hardware not present in this session.
- The staged GPU table is a CPU build/upload/encode/submit/fence measurement,
  not presented-frame latency or GPU execution time. No GPU timestamp feature
  exists in this harness.
- Touch behavior was not exercised on touch hardware. The pointer test covers
  the same hit-test seam used by touch events; keyboard and accessibility paths
  are automated.
- No integrated-GPU comparison, prior custom-geometry A/B, or binary-size
  isolation was recorded. The implementation adds no shader, texture, pass, or
  scheduler; that is asserted structurally by the renderer and the 348-case
  matrix rather than by a binary-size measurement.

## Verdict

**Accepted for #110 on the Windows D3D12 native backend.** Circle, Arc, and
Cubic-Bezier paint are visually correct at four DPI scales, including clipping,
translucent overlap, and replay. Circular pointer targeting passes through its
square corners, keeps keyboard activation, and retains rectangular
accessibility bounds. Geometry is bounded, adds no pass or draw slot beyond the
existing per-surface slot, and remains cheap for ordinary flat controls. macOS
Metal and Linux remain unrecorded hardware limitations, not implementation
gaps.
