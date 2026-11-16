# Alicorn #201 — Dense retained point markers

**Status:** bounded implementation and acceptance instrumentation added; issue
remains open for actual wxWidgets pixel parity and hosted Metal/D3D12 results.

Issue: [#201 — Support dense retained point markers within the geometry budget](https://github.com/samanshaiza004/alicorn/issues/201)

## Scope and architecture

Audacity's `WaveformView::Draw` sample editor draws one 3×3 or 4×4 logical-pixel
ellipse per visible sample, with connected waveform segments. The audited
read-only checkout was at `449db4f977`; `src/tracks/playabletrack/wavetrack/ui/WaveformView.cpp`
sets `tickSize = bigPoints ? 4 : 3`, then passes the square rect to
`wxDC::DrawEllipse`. At 3 logical pixels per sample, a
1,280px view needs 427 markers and 426 segments; a 1,920px view needs 640
markers and 639 segments.

Alicorn already has a presentation-only `GPU_Surface_Point_Marker`. Each marker
and each line segment expands to six vertices, so the batches cost 5,118 and
7,674 vertices respectively under the shared 8,192-vertex budget. The larger
case leaves 518 vertices. Ordinary `GPU_Surface_Filled_Circle` remains the
existing 16-triangle fan (48 vertices).

Marker data is copied into Runtime-owned storage, validated before replacement,
and released on clear, surface retyping, and node retirement. Candidate
geometry is rejected before mutating the old payload or its revision. The SDL
GPU renderer emits UV-mapped quads and samples a shared 32×32 antialiased circle
mask. Audacity remains responsible for sample identity, hit testing, edits,
audio state, and undo.

## Work added for this acceptance pass

- Extended Runtime and native mesh regressions to exercise both viewport sizes
  with their real 3px sample spacing. The 1,920px regression verifies all 7,674
  vertices and fractional 1.25× scaling. Rejected invalid/over-budget
  replacements must preserve the previously accepted 640-marker payload.
- Added a production-renderer SDL_GPU readback fixture at 1×, 1.25×, 1.5×, and
  2× for 3px and 4px markers, at both viewport widths. Its repeated 3px spacing
  exercises overlap; two out-of-bounds samples exercise surface clipping.
- The fixture compares GPU alpha coverage against an independent 8×8
  supersampled analytic ellipse reference. It records pixel error, marker and
  line counts, expanded vertices, and the GPU driver.
- Added a 64-update cost run for the 1,920px/4px case. It reports Runtime update
  p95, render-encode p95, submit-to-fence wall-time p95, uploaded vertex bytes,
  upload count, persistent allocation calls, and settled Runtime/surface work.
  The current SDL3 Odin binding does not expose portable GPU timestamp queries;
  submit-to-fence is therefore reported as a wall-time measurement, not GPU
  execution time.
- Added `tools/validate_point_markers.sh` and `.ps1`, with Metal and D3D12 runs
  wired into their respective foundation workflows. Each run uploads its text
  measurements as a CI artifact.

## Validation evidence

Local on Odin `dev-2026-11:9a6991685`:

| Check | Result |
| --- | --- |
| `odin test runtime` | 352 passed |
| `odin test native/sdl_gpu` | 181 passed |
| Point-marker GPU validation executable | Compiled; could not start locally because SDL reports no available video displays |
| Full `tools/test.sh` | Stopped in the AccessKit macOS example when Clang tried to write its module cache under the protected user cache path; the targeted Runtime and native test suites were run separately and passed |

The new hosted Metal and D3D12 measurements must be checked on the commit that
contains this work. The Alicorn-only readback uses an analytic reference rather
than a captured wxWidgets `DrawEllipse` bitmap. It verifies marker size,
antialiasing, overlap, clipping, and fractional scale against the requested
ellipse geometry, but does **not** prove pixel parity with wxWidgets' native
rasterizer. Keep #201 open until a wx reference capture is compared at all four
scales and both hosted GPU runs produce acceptable measurements.

## Ownership boundary

The compact point-marker API is intentionally narrow. It does not add path
rendering, unbounded geometry, sample-edit policy, audio or DSP state, or
application hit testing to Alicorn. Audacity supplies the marker positions and
uses its own source model to resolve pointer edits and undo.
