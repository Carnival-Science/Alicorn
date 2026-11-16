# Alicorn #201 — Dense retained point markers

**Status:** Dense marker readback and cost validation passed on hosted Metal and D3D12 at `979e64b`. #201 remains open for native wxWidgets bitmap comparisons and isolated GPU execution timings.

Issue: [#201 — Support dense retained point markers within the geometry budget](https://github.com/samanshaiza004/alicorn/issues/201)

## Scope and architecture

Audacity's [`WaveformView.cpp` at `449db4f`](https://github.com/audacity/audacity/blob/449db4f9772d46ab6e4b791d8d0350434ab74679/src/tracks/playabletrack/wavetrack/ui/WaveformView.cpp#L644-L663) draws a 3×3 or 4×4 logical-pixel ellipse per visible sample, with connected waveform segments. It positions each `wxRect` at `sample - tickSize/2` using integer division. `wxRect` uses inclusive integer pixel endpoints (`right = x + width - 1`); the corresponding raster-space center is therefore on the sample coordinate for 3×3 and half a logical pixel up and left for 4×4. The GPU fixture uses these centers at every tested scale. wxMSW adjusts the right and bottom extents for GDI, another reason exact pixel parity remains platform-specific; see the [wxRect definition](https://github.com/wxWidgets/wxWidgets/blob/v3.2.6/include/wx/gdicmn.h), [`wxDC::DrawEllipse(wxRect)`](https://github.com/wxWidgets/wxWidgets/blob/v3.2.6/include/wx/dc.h), and [wxMSW ellipse implementation](https://github.com/wxWidgets/wxWidgets/blob/v3.2.6/src/msw/dc.cpp).

At three logical pixels per sample, a 1,280px viewport needs 427 markers and 426 line segments; a 1,920px viewport needs 640 markers and 639 segments. Alicorn's retained `GPU_Surface_Point_Marker` and line segment each expand to six vertices. The production payloads therefore use 5,118 and 7,674 vertices under the existing 8,192-vertex limit. Ordinary `GPU_Surface_Filled_Circle` remains a 16-triangle fan (48 vertices).

The readback fixture adds two out-of-bounds marker probes to check both surface edges. Its totals are 5,130 and 7,686 vertices, still below the same limit. Candidate geometry is validated before replacing the retained payload, so an invalid or over-budget update leaves the previous payload and revision intact.

The SDL GPU renderer draws markers as UV-mapped quads using a shared 32×32 antialiased circle mask. Audacity continues to own sample identity, hit testing, edits, audio/DSP state, and undo.

## Validation method

- Runtime and mesh tests build the dense 1,280px and 1,920px batches, verify their expanded vertex counts, and check that a rejected replacement preserves the accepted payload.
- The production-renderer GPU fixture reads back 3×3 and 4×4 markers at 1×, 1.25×, 1.5×, and 2× for both viewport widths. Three-pixel spacing exercises overlap. The fixture checks pixels at both surface edges for the out-of-bounds probes.
- An independent 8×8 supersampled analytic ellipse oracle compares blended RGB coverage over the sampled opaque root backdrop. Alpha cannot be used because the root surface makes the offscreen target opaque. This is a geometry and coverage check, not a wxWidgets pixel-parity claim.
- Every combination must match the analytic coverage tolerance and contain visible marker coverage. Edge antialiasing is required except for a 4×4 marker at 1×: at that scale the sampled output pixel centers can all land fully inside or outside the circle, so no partially covered output pixel is expected. Fractional-DPI cases and 3×3 markers still require visible edge coverage. The fixture also verifies overlap and both edge probes.
- A 64-update 1,920px/4×4 run records CPU update and render-encode p95, submit-to-fence wall time, uploaded bytes, upload count, persistent allocation calls, and idle-work flags. SDL's current Odin binding does not expose GPU timestamp queries, so submit-to-fence is not reported as GPU execution time.

## Validation evidence

### Local

| Check | Result |
| --- | --- |
| `odin test runtime` | 352 passed |
| `odin test native/sdl_gpu` | 181 passed before the corrected-center fixture change; the latest local rerun could not link because `.deps/accesskit/libaccesskit.a` is absent |
| `odin check native/point_marker_validation_entry` | Passed at `979e64b` using the pinned AccessKit dependency |
| GPU validation executable | Could not run locally because SDL reported no available video display; hosted D3D12 and Metal readbacks passed |
| Full `tools/test.sh` | Stopped when Clang could not write its module cache under the protected user cache path; the targeted Runtime and native test suites passed separately |

### Hosted readback and cost

The corrected-center run passed all 16 size/scale/viewport combinations on each backend (32 readback cases total). Mean RGB delta against the 8×8 analytic ellipse oracle ranged from 1 to 5 on both backends; the maximum per-pixel delta was 22. At 4×4 and 1×, the readback had no partially covered pixels on either backend, which is allowed for this pixel-center alignment. All other cases reported visible antialiased pixels.

| Backend | Update p95 (CPU) | Encode p95 (CPU) | Submit-to-fence p95 (wall) | Bytes/upload | Uploads | Persistent allocation calls | Idle submissions / surface work |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| D3D12 | 14.4 µs | 180.1 µs | 2.690 ms | 276,264 | 64 | 128 across 64 updates | none |
| Metal | 19.0 µs | 104.0 µs | 1.492 ms | 276,264 | 64 | 128 across 64 updates | none |

The workflow printed that GPU timestamps are unavailable in the current SDL3 Odin binding. The submit-to-fence values include CPU-side waiting and are not isolated GPU p95 timings.

Hosted evidence for `979e64b`:

- [Windows/D3D12 foundation run](https://github.com/samanshaiza004/alicorn/actions/runs/43823505914) — foundation tests and dense-marker readback step passed.
- [macOS/Metal foundation run](https://github.com/samanshaiza004/alicorn/actions/runs/43823506123) — foundation checks and dense-marker readback step passed.
- [Windows/macOS packaging](https://github.com/samanshaiza004/alicorn/actions/runs/43823506060) — passed.
- [Icon reproducibility](https://github.com/samanshaiza004/alicorn/actions/runs/43823505956) — passed.

## Remaining acceptance

The native readback is compared to an analytic ellipse, not a bitmap captured from the same Audacity wxWidgets build. wx rasterization can vary by platform; Audacity also disables graphics-context antialiasing for waveform drawing on macOS. Exact parity still needs reference captures from the matching native wx build at all four scales.

The cost report contains CPU update/encode p95 and submit-to-fence wall-time p95, but no isolated GPU execution p95 because the current SDL3 Odin binding does not expose timestamp queries. Keep #201 open until the wx reference comparison and a supported GPU timing measurement are recorded.

## Ownership boundary

The marker primitive is presentation-only. It does not add arbitrary paths, unbounded geometry, sample-edit policy, audio/DSP state, hit testing, or undo behavior to Alicorn. Audacity supplies marker positions and resolves pointer edits and undo through its own source model.
