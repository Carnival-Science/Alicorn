# Issue #200: bounded filled-rectangle batches

Windows x64, NVIDIA GeForce RTX 2080 SUPER, Windows 10 22H2, 2026-11-20.
Alicorn `codex/issue-200-201-acceptance` @ `67b31b8` (v0.2.2) plus this slice's
fixtures. Drivers: `direct3d12` and `vulkan` through SDL_GPU.

The feature itself landed earlier: `runtime/gpu_surface.odin` accepts bounded
`GPU_Surface_Filled_Rectangle` payloads, and the shared surface mesh builder
expands each rectangle to one six-vertex quad. This record covers the two
acceptance gates the Acetate dogfood note left open — native readback and
repaint cost compared with the wx path.

## Method

`native/rectangle_validation_entry` drives the production SDL_GPU surface
renderer against an offscreen target and reads the result back:

- **Payload.** 1,026 surface-local rectangles on a 1,280x160 geometry surface:
  640 two-pixel envelope columns, 320 wider coalesced fills, 32 selection-like
  spans, 32 rects clipped by each of the four surface edges, one uniquely
  colored channel-order key, and one final opaque rect for painter order.
  Colors vary across a ten-entry palette; the alpha scene lowers the fill
  groups to 0.45-0.55 so stacking is exercised. Vertex total: 6,156 of 8,192.
- **Batching assertion.** The retained mesh must contain exactly
  `rectangles * 6` vertices and the display list must hold one geometry command
  for the whole batch. The other display command is the root container's
  backdrop, which is outside the payload.
- **CPU reference.** An independent compositor uses the pipeline's pixel-center
  coverage rule for quads and source-over blending in UNORM space, seeded with
  the runtime's observed root backdrop (`199,209,229`). It compares both RGBA
  and BGRA readback orders and detects the order from the color key.
- **wx reference.** `tools/wx_reference.ps1` builds `tools/wx_reference/main.cpp`
  against wxWidgets 3.2.11 (MSW/UCRT64, the MSW wxWidgets the Audacity
  application uses) and draws the same scene with `wxDC::DrawRectangle(wxRect)`
  — the call Audacity's `DrawWaveformBackground` uses for its envelope and
  selection fills. Each shape's logical rect is scaled by the DPI factor and
  rounded to integers before it reaches wx, which is what a wx host does: a
  `wxDC` is always in device pixels.
- **Repaint cost.** Two retained paths describe the same 1,026-column band:
  one geometry payload versus one `Surface_Paint` container node per column.
  Full repaint changes every color; partial repaint changes 32 of 1,026.
- **Idle and overflow.** A repeated payload commit must not re-enter
  description, layout, paint, or text shaping, must request exactly one frame,
  and must settle to no pending work. 1,366 rectangles (8,196 vertices) must be
  rejected atomically while 1,365 (8,190) is accepted.

Reproduce:

```powershell
.\tools\validate_rectangles.ps1 -Odin C:\odin\odin.exe -Driver direct3d12 `
  -EmitScenes .\out\wx-scenes-rects
.\tools\wx_reference.ps1 -Scenes .\out\wx-scenes-rects -OutDir .\out\wx-reference
.\tools\validate_rectangles.ps1 -Odin C:\odin\odin.exe -Driver direct3d12 `
  -WxReference .\out\wx-reference
```

`tools/wx_reference.ps1` needs an MSYS2 UCRT64 installation with
`mingw-w64-ucrt-x86_64-wxwidgets3.2`; `-Msys2Root` selects a non-default tree.

## Readback

Both backends produce the same verdicts. `mismatched` counts pixels whose
per-channel mean delta exceeds 1; `edge_only` counts pixels that match the
reference within one pixel, which is the expected consequence of wx rounding a
fractional logical rect edge into integer device pixels.

| case | CPU mismatched | CPU max delta | wx mismatched | wx edge-only | wx max delta | status |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 1,280x160 @1.00x opaque | 0 / 204,800 | 0 | 5 | 594 | 92 | PASS |
| 1,280x160 @1.50x opaque | 0 / 460,800 | 0 | 6 | 6,785 | 60 | PASS |
| 1,280x160 @1.00x alpha | 0 / 204,800 | 0 | not compared | — | — | PASS |

Painter order: the last opaque rectangle is `255,255,255` at its center on both
backends, so later rectangles cover earlier fills. The alpha scene matches the
CPU source-over model within one level everywhere (mean delta 0.018), including
the two translucent fill groups stacked over the opaque columns.

wx cannot be used for the alpha case: `wxDC` has no source-over alpha, so the
translucent scene is validated against the CPU compositor only.

## Repaint cost

CPU wall time, 32 samples per mode. `batched` is one geometry payload; `retained`
is one `Surface_Paint` container per rectangle in a row. All values are p95
microseconds.

| backend | mode | describe p95 | payload update p95 | display commands |
| --- | --- | ---: | ---: | ---: |
| D3D12 | batched, full | 1.9 | 2.3 | 2 |
| D3D12 | retained nodes, full | 1,332.1 | — | 1,027 |
| D3D12 | retained nodes, 32/1,026 changed | 717.0 | — | 1,027 |
| Vulkan | batched, full | 1.9 | 2.3 | 2 |
| Vulkan | retained nodes, full | 918.1 | — | 1,027 |
| Vulkan | retained nodes, 32/1,026 changed | 596.8 | — | 1,027 |

For the wx path, the same 1,026 `wxDC::DrawRectangle` calls cost 2,349.9 µs p50
and 2,610.2 µs p95 per draw pass at 1.0x, and 2,650.6/2,892.7 µs at 1.5x
(64 timed passes on a 24-bit memory DC, including `SetBrush` per rectangle).

The batched describe path is unchanged by the payload size: the geometry
surface re-declares one node, and the payload commit only bumps its revision.
The retained-node path pays description and paint for every rectangle, and the
display list grows from 2 commands to 1,027.

Isolated payload cost, 64 payload revisions, one frame each:

| backend | update p95 | encode p95 | submit-to-fence p95 (wall) | bytes/upload | uploads | persistent allocs (updates) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| D3D12 | 3.3 µs | 44.7 µs | 431.8 µs | 221,616 | 64 | 1 |
| Vulkan | 3.6 µs | 40.6 µs | 361.7 µs | 221,616 | 64 | 1 |

`submit-to-fence` includes CPU waiting and is not GPU execution time; the
current SDL3 Odin binding exposes no timestamp queries. The single persistent
allocation is the first payload's capacity growth; subsequent updates reuse it,
which the new `test_gpu_surface_rectangle_updates_do_not_grow_persistent_allocations`
regression asserts. Per-update marker replacement no longer allocates an empty
container for rect-only payloads, so a rect update performs no allocator calls
after warm-up.

## Bounds and idle

| check | result |
| --- | --- |
| 1,365 rectangles (8,190 vertices) | accepted |
| 1,366 rectangles (8,196 vertices) | rejected, payload revision and retained rects unchanged, rejection counter incremented |
| repeated identical payload commit | 0 layout visits, 0 paint visits, 0 text-shape requests, 0 finalized display commands |
| after one consumed frame | no submission pending, no surface frame pending |
| uploads per changed revision | exactly one complete retained mesh |

## Acceptance mapping

| issue #200 criterion | evidence |
| --- | --- |
| Acetate sends coalesced envelope/selection rectangles as bounded paint data; selection/envelope stay authoritative in Audacity | Acetate commits `5aa72a9` and `6ecb2f2` drive filled rectangles through the payload; this record validates the payload itself, and the host retains all editing state. |
| Selection and waveform background colors match the wx reference at multiple zoom levels and DPI scales | 1,026-rect scene at 1.0x and 1.5x against wxWidgets 3.2.11 GDI captures: 0 exact mismatches beyond the 5/6 focused pixels; 594/6,785 one-pixel edge matches; max delta 92/60 at clipped 1-px corners. |
| Updating rectangle payloads does not require description, layout, or text reshaping and returns to idle when unchanged | `issue_200_idle`: 0 layout/paint/text/display work across two commits; no pending submission or surface frame after one consumed frame; batched describe p95 1.9 µs versus 1,332.1 µs (D3D12) / 918.1 µs (Vulkan) for retained nodes. |
| Native readback and p95 cost compared with the wx path on supported render backends | Native readback on D3D12 and Vulkan against CPU and wx references, plus isolated update/encode/submit p95 and the wx draw-cost table above. |

## Limits

- This machine runs D3D12 and Vulkan. Metal was not executed; no macOS hardware
  was available in this session.
- The wx comparison uses wxWidgets 3.2.11 (MSW) rasterization generated by
  `tools/wx_reference`, not a capture from a built Audacity/Acetate binary. The
  drawing call (`wxDC::DrawRectangle(wxRect)`), rect construction, and DPI
  rounding match the Audacity path; the wx library version is recorded in each
  capture's `.meta`. The Acetate build attempt and its Conan blocker are
  recorded in the [issue #201 marker record](issue-201-markers-windows-2026-11-20.md#acetate-wx-host-attempt).
- GPU execution time is unavailable: SDL's Odin binding does not expose
  timestamp queries. `submit-to-fence` is wall time.
- Rect edge pixels at fractional logical coordinates differ by one pixel between
  wx's integer device rects and the GPU's pixel-center rule. They are counted
  and bounded separately (1 px match radius); the CPU reference, which uses the
  same rule as the pipeline, is exact.

Raw logs: [`raw/issue-200-rectangles-2026-11-20.txt`](raw/issue-200-rectangles-2026-11-20.txt),
[`raw/issue-200-rectangles-vulkan-2026-11-20.txt`](raw/issue-200-rectangles-vulkan-2026-11-20.txt),
[`raw/issue-200-wx-draw-cost-2026-11-20.txt`](raw/issue-200-wx-draw-cost-2026-11-20.txt).

## Files

- `native/sdl_gpu/rectangle_validation.odin`, `native/rectangle_validation_entry/main.odin`
- `native/sdl_gpu/wx_reference.odin` (shared capture loader and comparators)
- `tools/wx_reference/main.cpp`, `tools/wx_reference.ps1`, `tools/validate_rectangles.ps1`
- `runtime/gpu_surface.odin` (rect-only updates no longer allocate an empty marker container)
- `runtime/gpu_surface_test.odin` (allocation-growth regression)
