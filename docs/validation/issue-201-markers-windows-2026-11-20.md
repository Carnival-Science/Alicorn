# Issue #201: dense retained point markers

Windows x64, NVIDIA GeForce RTX 2080 SUPER, Windows 10 22H2, 2026-11-20.
Alicorn `codex/issue-200-201-acceptance` @ `67b31b8` (v0.2.2) plus this slice's
fixtures. Drivers: `direct3d12` and `vulkan` through SDL_GPU.

The compact six-vertex `GPU_Surface_Point_Marker` (one masked quad, 32x32
supersampled circle mask) already fit 427/640 markers plus connected waveform
lines in the 8,192-vertex budget, and the hosted readback of 32 size/scale/
viewport cases had passed. This record closes the two remaining acceptance
items in the research note: an actual wxWidgets comparison and isolated marker
GPU-path timing.

## wxWidgets comparison

`tools/wx_reference.ps1` builds `tools/wx_reference/main.cpp` against
**wxWidgets 3.2.11 (MSW/UCRT64)** — the wxWidgets family and GDI backend the
Audacity application draws waveform markers with. The Odin fixture emits the
marker scene in Audacity's own vocabulary, then wx draws it:

```text
ellipse <x> <y> 3 3 255 255 255   # dc.DrawEllipse(wxRect) per visible sample
```

`x = sample*3 - tickSize/2`, `y = 16 - tickSize/2`, exactly as
`WaveformView.cpp` at `449db4f` builds `pr` before calling
`dc.DrawEllipse(pr)`. The 4px (`bigPoints`) variant is emitted the same way.
Both out-of-bounds probes (one sample left of column 0, one right of the last
column) are included, so clipping is compared, not just the interior. GDI's
small-rect rasterization matches the previously assumed geometry: a 3px wxRect
fills a 3x3 plus (5 pixels) and a 4px wxRect fills a 12-pixel 4x4 blob, both
hard-edged. The scene is written by `--emit-wx-scenes=<dir>`; captures and
their `.meta` headers are produced once and consumed by both backends.

The fixture compares coverage (each image normalized against its own background
luminance and white ink) over six anchors per case: first sample, second sample,
one-sixth, one-third, one-third plus one, and the last visible sample. Edge
probes are presence/clipping checks; their visible footprint depends on how each
rasterizer rounds a rect that starts outside the surface.

| case | area ratio min/max | centroid delta max (px) | mean coverage delta max | wx AA px | GPU AA px | overlap coverage | status |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| 1280px 3x3 @1.00x | 0.80 / 0.92 | 0.75 | 0.133 | 0 | 50 | — | PASS |
| 1280px 4x4 @1.00x | 0.91 / 1.00 | 0.86 | 0.159 | 0 | 0 | 1.00 | PASS |
| 1280px 3x3 @1.25x | 0.95 / 1.08 | 1.11 | 0.259 | 0 | 34 | — | PASS |
| 1280px 4x4 @1.25x | 1.16 / 1.47 | 1.15 | 0.247 | 0 | 27 | 1.00 | PASS |
| 1280px 3x3 @1.50x | 1.08 / 1.28 | 1.63 | 0.300 | 0 | 22 | — | PASS |
| 1280px 4x4 @1.50x | 1.03 / 1.22 | 0.91 | 0.194 | 0 | 42 | 1.00 | PASS |
| 1280px 3x3 @2.00x | 1.10 / 1.29 | 1.11 | 0.232 | 0 | 84 | — | PASS |
| 1280px 4x4 @2.00x | 0.99 / 1.11 | 1.04 | 0.168 | 0 | 44 | 1.00 | PASS |
| 1920px 3x3 @1.00x | 0.80 / 0.92 | 0.75 | 0.133 | 0 | 50 | — | PASS |
| 1920px 4x4 @1.00x | 0.91 / 1.00 | 0.86 | 0.148 | 0 | 0 | 1.00 | PASS |
| 1920px 3x3 @1.25x | 0.88 / 1.08 | 1.10 | 0.258 | 0 | 36 | — | PASS |
| 1920px 4x4 @1.25x | 1.16 / 1.47 | 1.12 | 0.246 | 0 | 29 | 1.00 | PASS |
| 1920px 3x3 @1.50x | 1.00 / 1.28 | 1.63 | 0.300 | 0 | 20 | — | PASS |
| 1920px 4x4 @1.50x | 1.05 / 1.22 | 1.02 | 0.194 | 0 | 43 | 1.00 | PASS |
| 1920px 3x3 @2.00x | 1.10 / 1.29 | 1.11 | 0.232 | 0 | 84 | — | PASS |
| 1920px 4x4 @2.00x | 0.99 / 1.11 | 1.04 | 0.167 | 0 | 44 | 1.00 | PASS |

Both backends produced byte-identical comparison lines. What the dimensions
show:

- **Size.** Marker footprint area is within 0.80-1.47x of wx across every
  size/scale. The 3px marker is a 5-pixel GDI plus; the GPU renders a 3px
  antialiased disc whose coverage sums to about 0.8-1.3 of that.
- **Antialiasing.** wx/GDI produces no partially covered pixels (`wx AA px = 0`
  in all 16 cases). Alicorn produces 20-84 partially covered edge pixels per
  case, except 4px markers at 1x where sampled pixel centers land fully inside
  or outside; that exception is the same one the hosted analytic fixture
  documents. This is a deliberate quality difference, not a coverage error:
  max per-pixel coverage delta is 1.0 where an antialiased edge meets a
  hard-edged GDI row, mean delta is 0.13-0.30.
- **Overlap.** 4px markers on the 3px sample grid share one column. Both wx and
  the GPU cover the shared boundary pixel (`overlap coverage = 1.00`) at every
  scale; 3px markers do not overlap, so the probe is reported as not
  applicable.
- **Clipping.** Both edge probes render visible ink in both images at every
  scale (probe areas 2-17.6 coverage units), and no coverage appears outside the
  surface. The clipped visible area differs at fractional scales (wx 2 vs GPU 6
  units at 1.25x/1.5x) because wx rounds the outside-origin rect to integers
  before GDI clips, while the GPU clips the scaled quad. That is reported rather
  than asserted equal.
- **Fractional DPI.** Centroid alignment is 0.75-0.86 px at integer scale and up
  to 1.63 px at 1.5x. The residual comes from wx's device-space rect rounding:
  a host that wants byte-level wx alignment must round the marker rect in device
  space and derive center/diameter from the rounded rect, instead of scaling the
  logical center and diameter. Alicorn already takes a center and diameter, so
  this is a host mapping choice, not a renderer change.

**A related finding for the Audacity bridge:** Audacity's `tickSize` (3 or 4) is
a device-pixel value and is not DPI-scaled, while Alicorn applies
`surface_dpi_scale` to logical marker geometry. A host that intends to keep
Audacity's exact 3-device-pixel marker at 200% DPI must send
`diameter = tickSize / dpi_scale`. The fixture instead compares the DPI-scaled
marker (the payload contract), which is what a DIP-sized marker should look
like.

## Isolated marker timing

`native/point_marker_validation_entry` now sweeps retained marker counts with no
connected lines, 64 payload revisions per count, one frame and fence wait each.
All values are CPU wall time.

| backend | markers | vertices | update p95 | encode p95 | submit-to-fence p95 (wall) | bytes/upload | allocs (updates) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| D3D12 | 128 | 768 | 2.2 µs | 25.2 µs | 365.6 µs | 27,648 | 64 |
| D3D12 | 512 | 3,072 | 3.5 µs | 37.9 µs | 262.5 µs | 110,592 | 64 |
| D3D12 | 1,024 | 6,144 | 6.5 µs | 69.9 µs | 511.6 µs | 221,184 | 64 |
| D3D12 | 1,365 | 8,190 | 6.8 µs | 62.7 µs | 406.4 µs | 294,840 | 64 |
| Vulkan | 128 | 768 | 2.3 µs | 23.0 µs | 258.9 µs | 27,648 | 64 |
| Vulkan | 512 | 3,072 | 3.7 µs | 31.6 µs | 248.2 µs | 110,592 | 64 |
| Vulkan | 1,024 | 6,144 | 6.0 µs | 50.0 µs | 256.8 µs | 221,184 | 64 |
| Vulkan | 1,365 | 8,190 | 7.7 µs | 47.1 µs | 268.8 µs | 294,840 | 64 |

The dense production case (640 markers plus 639 connected segments) stays at
8.0 µs update / 56.2 µs encode / 603.3 µs submit-to-fence p95 on D3D12, and
6.3 µs / 54.5 µs / 262.6 µs on Vulkan. Every case reports no pending submission
and no pending surface frame after settling; each changed revision uploads
exactly one complete retained mesh; marker payload replacement costs one
persistent allocation per update (the retained copy), with no growth in live
bytes across the 64 revisions.

## Budget cap and atomic overflow

`GPU_SURFACE_MAX_VERTICES` is 8,192 and a marker is 6 vertices, so the hard cap
is **1,365 markers** in one payload — enough for 640 markers plus 639 connected
lines at 1,920 px, and for 1,365 markers with no lines. The sweep stops at the
cap by design; 10k/100k markers cannot fit in one bounded batch and are not
claimed. All of 1,366, 10,000, and 100,000 markers are rejected atomically:
the payload revision and retained markers are unchanged and the overflow
counter increments, so a host can fall back to wx without a visual gap.

## Acceptance mapping

| issue #201 criterion | evidence |
| --- | --- |
| A bounded batch draws the 1,280 and 1,920 px viewport sample markers with connected waveform lines under the surface budget, or documents a justified lower cap | 427 markers + 426 segments = 5,130 vertices; 640 + 639 = 7,674; 1,365 markers alone = 8,190 of 8,192. The documented cap is 1,365. |
| Native readback compares marker size, antialiasing, overlap, clipping, and fractional DPI against the 3x3/4x4 wx ellipses at 1x/1.25x/1.5x/2x | 16 wxWidgets 3.2.11 captures compared on both backends (table above): area 0.80-1.47x, centroid 0.75-1.63 px, wx hard-edged vs 20-84 GPU AA pixels, shared-column overlap, both edge probes, all 16 PASS. |
| CPU/GPU p95, vertex/upload bytes, allocations, and idle work reported on Metal and D3D12 | D3D12 and Vulkan tables above (CPU stages, bytes, allocations, idle). Metal not available on this machine; GPU execution p95 remains unavailable because the SDL3 Odin binding exposes no timestamp queries. |
| Geometry overflow is atomic and bounded; the old payload is retained | 1,366 / 10,000 / 100,000 rejected; revision and retained markers preserved; counter incremented. |
| The visual marker remains presentation only; Audacity keeps hit testing, edits, audio state, undo | Unchanged: the marker primitive carries only center, diameter, and color; the host owns all sample-edit behavior. |

## Acetate wx host attempt

The strongest possible reference would be a bitmap captured from the Acetate
build of Audacity itself. That build was attempted and blocked on the
dependency bootstrap, not on wx:

- CMake 4.4.4 is installed (`C:\Program Files\CMake\bin`, not on `PATH`).
  `cmake -S C:\Users\saman\dev\Acetate -B <temp> -Daudacity_host_spike=ON`
  detected MSVC 19.51 and reached the project's Conan step.
- Conan 2.34.0 bootstrapped into the build tree and tried to install the
  Audacity dependency graph. The `audacity-binaries-conan2` remote is not
  configured in a fresh Conan home, so packages were built from source;
  `expat/2.5.0@audacity/stable` failed in its `cmake.configure()`, aborting the
  configure before wxWidgets or `acetate-host-backend` existed.
- `host-spike/app` is an Odin host that links the resulting
  `acetate-host-backend` shared library, so no Acetate binary could be produced
  without that full dependency build.

The comparison therefore uses wxWidgets 3.2.11 (MSW) directly — the same
`wxDC`/GDI code path and the same `WaveformView.cpp` rect arithmetic — and
records the wx library and scene in each capture's `.meta`. A capture from a
built Audacity binary, and a macOS capture with Audacity's disabled
graphics-context antialiasing, remain outside this session.

## Remaining acceptance

- Metal: not run here. The wx comparison and sweep are backend-independent at
  the readback/CPU level (both tested backends are byte-identical), but the
  issue names Metal and D3D12, so a macOS run is still outstanding.
- GPU execution p95: still unavailable. `submit-to-fence` includes CPU waiting
  and is labeled as wall time; the sweep is isolated from other scene work and
  reports CPU update/encode stages separately.
- The wx comparison is wxWidgets' own rasterization, not a bitmap captured from
  a built Audacity/Acetate binary. The drawing call, rect construction, and
  integer device rounding match `WaveformView.cpp`; captures record the wx
  version and scene in their `.meta` files.

Because the Metal run and a supported GPU timing source are still missing,
#201 stays open with these results recorded.

Raw logs: [`raw/issue-201-markers-2026-11-20.txt`](raw/issue-201-markers-2026-11-20.txt),
[`raw/issue-201-markers-vulkan-2026-11-20.txt`](raw/issue-201-markers-vulkan-2026-11-20.txt),
[`raw/issue-201-wx-draw-cost-2026-11-20.txt`](raw/issue-201-wx-draw-cost-2026-11-20.txt).

## Files

- `native/sdl_gpu/point_marker_validation.odin` (wx comparison, budget probes, isolated sweep)
- `native/sdl_gpu/wx_reference.odin`
- `tools/wx_reference/main.cpp`, `tools/wx_reference.ps1`, `tools/validate_point_markers.ps1`
