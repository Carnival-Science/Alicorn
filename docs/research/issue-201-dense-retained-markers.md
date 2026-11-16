# Alicorn #201 — Dense retained point markers

**Status:** Hosted Metal and D3D12 readback passes for the dense marker workload. #201 remains open for a native wxWidgets reference comparison and actual GPU execution timings.

Issue: [#201 — Support dense retained point markers within the geometry budget](https://github.com/samanshaiza004/alicorn/issues/201)

## Scope and architecture

Audacity's [`WaveformView.cpp` at `449db4f`](https://github.com/audacity/audacity/blob/449db4f9772d46ab6e4b791d8d0350434ab74679/src/tracks/playabletrack/wavetrack/ui/WaveformView.cpp#L644-L663) draws a 3×3 or 4×4 logical-pixel ellipse per visible sample, with connected waveform segments. It positions each rectangle at `sample - tickSize/2` using integer division. The corresponding ellipse center is therefore half a logical pixel after the sample coordinate for a 3×3 marker, and unchanged for a 4×4 marker. The GPU fixture uses those centers at every tested scale.

At three logical pixels per sample, a 1,280px viewport needs 427 markers and 426 line segments; a 1,920px viewport needs 640 markers and 639 segments. Alicorn's retained `GPU_Surface_Point_Marker` and line segment each expand to six vertices. The production payloads therefore use 5,118 and 7,674 vertices under the existing 8,192-vertex limit. Ordinary `GPU_Surface_Filled_Circle` remains a 16-triangle fan (48 vertices).

The readback fixture adds two out-of-bounds marker probes to check both surface edges. Its totals are 5,130 and 7,686 vertices, still below the same limit. Candidate geometry is validated before replacing the retained payload, so an invalid or over-budget update leaves the previous payload and revision intact.

The SDL GPU renderer draws markers as UV-mapped quads using a shared 32×32 antialiased circle mask. Audacity continues to own sample identity, hit testing, edits, audio/DSP state, and undo.

## Validation method

- Runtime and mesh tests build the dense 1,280px and 1,920px batches, verify their expanded vertex counts, and check that a rejected replacement preserves the accepted payload.
- The production-renderer GPU fixture reads back 3×3 and 4×4 markers at 1×, 1.25×, 1.5×, and 2× for both viewport widths. Three-pixel spacing exercises overlap. The fixture checks pixels at both surface edges for the out-of-bounds probes.
- An independent 8×8 supersampled analytic ellipse oracle compares blended RGB coverage over the sampled opaque root backdrop. Alpha cannot be used because the root surface makes the offscreen target opaque. This is a geometry and coverage check, not a wxWidgets pixel-parity claim.
- At 3×3 and 1×, the Audacity-aligned half-pixel center places each pixel center inside the small ellipse. The center-sampled mask can therefore produce no partial-color pixels in that exact alignment. The fixture allows that one case; the other sizes and scales must show antialiasing.
- A 64-update 1,920px/4×4 run records CPU update and render-encode p95, submit-to-fence wall time, uploaded bytes, upload count, persistent allocation calls, and idle-work flags. SDL's current Odin binding does not expose GPU timestamp queries, so submit-to-fence is not reported as GPU execution time.

## Validation evidence

### Local

| Check | Result |
| --- | --- |
| `odin test runtime` | 352 passed |
| `odin test native/sdl_gpu` | 181 passed |
| `odin check native/point_marker_validation_entry` | Passed at `ba371a0` using the pinned AccessKit dependency |
| GPU validation executable | Built; could not start locally because SDL reported no available video display |
| Full `tools/test.sh` | Stopped when Clang could not write its module cache under the protected user cache path; the targeted Runtime and native test suites passed separately |

### Hosted readback and cost

At [`ba371a0`](https://github.com/samanshaiza004/alicorn/commit/ba371a03ccabe52b5d3f2054602f04b5d2fa5dbf), all 16 readback combinations passed on each backend: both viewport widths, both marker sizes, and all four scales. Across both backends, mean RGB error ranged from 1–5 and maximum per-pixel error from 8–22. Both edge probes passed. The only cases with zero partial-color samples were 3×3 markers at 1×, as described above.

| Backend | Update p95 (CPU) | Encode p95 (CPU) | Submit-to-fence p95 (wall) | Bytes/upload | Uploads | Persistent allocation calls | Idle submissions / surface work |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| D3D12 | 29.7 µs | 182.4 µs | 2.866 ms | 276,264 | 64 | 128 | none / none |
| Metal | 26 µs | 274 µs | 3.053 ms | 276,264 | 64 | 128 | none / none |

The workflow printed that GPU timestamps are unavailable in the current SDL3 Odin binding. The submit-to-fence values include CPU-side waiting and are not isolated GPU p95 timings.

Hosted checks passed for the current implementation:

- [Windows/D3D12 foundation](https://github.com/samanshaiza004/alicorn/actions/runs/43820917546)
- [macOS/Metal foundation](https://github.com/samanshaiza004/alicorn/actions/runs/43820917770)
- [Windows and macOS native packaging](https://github.com/samanshaiza004/alicorn/actions/runs/43820917553)
- [Icon asset reproducibility](https://github.com/samanshaiza004/alicorn/actions/runs/43820919025)

## Remaining acceptance

The native readback is compared to an analytic ellipse, not a bitmap captured from the same Audacity wxWidgets build. wx rasterization can vary by platform; Audacity also disables graphics-context antialiasing for waveform drawing on macOS. Exact parity still needs reference captures from the matching native wx build at all four scales.

The cost report contains CPU update/encode p95 and submit-to-fence wall-time p95, but no isolated GPU execution p95 because the current SDL3 Odin binding does not expose timestamp queries. Keep #201 open until the wx reference comparison and a supported GPU timing measurement are recorded.

## Ownership boundary

The marker primitive is presentation-only. It does not add arbitrary paths, unbounded geometry, sample-edit policy, audio/DSP state, hit testing, or undo behavior to Alicorn. Audacity supplies marker positions and resolves pointer edits and undo through its own source model.
