# SDL_GPU reference baseline — Windows

Captured before renderer changes from Alicorn commit
`d0c273fc00769412018ef871e407a1d45882ffbf` on 2026-11-15.

## Environment

- Windows x64, build `10.0.19045` (Windows 10 22H2).
- Odin `dev-2026-11-nightly:08539cd`.
- GPU: NVIDIA GeForce RTX 2080 SUPER, 8192 MiB; driver `595.97`.
- SDL_GPU selected driver: Direct3D 12.
- Display scale: 1.0.
- Baseline machine was not idle-exclusive; timings are comparison anchors, not
  general performance claims.

## Regression suite

`tools/test.ps1 -Odin C:\odin\odin.exe` passed:

- Core runtime: 343 tests.
- Native SDL_GPU frontend: 193 tests.
- AccessKit ABI/smoke, UI, test UI, theme, foundation and consumer checks all
  passed (the script's additional package checks reported 39, 13, 37 and 6
  tests respectively, plus 8 AccessKit smoke cases).
- Native text-input/navigation/paint-span/host-ownership contract checks passed.

The runner printed a pre-existing warning that a 290,616-byte
`Native_Secondary_Window` local may exceed stack limits. It did not fail tests.

## Retained-work and idle baseline

Raw command output is retained locally under ignored
`out/webgpu-phase0/baseline-bench.txt`.
Run: `tools/bench.ps1 -Odin C:\odin\odin.exe`.

- 10,000 unchanged runtime frames: zero description/reconcile/layout/paint/
  composition work and zero GPU submissions.
- 1,000,000 logical virtual items across 100 frames retained 23 nodes.
- 1,200 GPU-surface-local updates caused zero ordinary description,
  reconciliation, layout, paint, composition, or allocation.
- 10,000-node cold tree: 93.206 ms total; description 16.584 ms; end-frame
  76.621 ms. A single value update: 26.920 ms. Full keyed reorder: 57.913 ms.
- These are runtime benchmark samples; they are not GPU presented-frame latency.

## GPU readback reference

The following native Direct3D 12 tools passed. Raw logs and PPM captures are in
ignored `out/webgpu-phase0/` for this machine:

- Blend/paint path: 348/348 cases, including surfaces, per-corner surfaces,
  geometry, icons, images, text and mixed paint; scales 1.0, 1.25, 1.5 and 2.0.
  Gradient, rounded/stroke geometry, clipping and source-over checks passed.
- Image readbacks passed across four scales and SDR/linear SDR cases.
- Icon path passed; atlas uploads 2 (1,572,864 bytes), mesh cache hits 8.
- Retained effects readback passed; unchanged 100-attempt check produced no
  render passes, allocations or submissions; retired live bytes reached zero.
- Offscreen timing includes submission, fence/wait and readback. It is not
  presented-frame latency or representative idle CPU.

The benchmark log includes offscreen surface p50/p95 302.7/427.2 microseconds
and gradient p50/p95 334.7/557.3 microseconds, for the recorded readback
configuration only.

## Supplemental retained-effects profile after CPU policy extraction

Captured on 2026-11-15 local from migration commit `b0fa0706ced2e6247a9354dc86d2fbb1f76536a9`, with the SDL_GPU renderer still the reference. The effects fixture's percentile reporter was extended to emit p50/p95/p99; rendering and validation behavior were unchanged. Command: `tools/validate_effects.ps1 -Odin C:\odin\odin.exe -Driver direct3d12`; the fixture builds optimized (`-o:speed`).

All nine Gaussian pixel cases passed at scales 1.0, 1.5 and 2.0, with worst error 1 RGBA8 level and painter order preserved. Source capture is RGBA8_UNORM, filter targets are RGBA16_FLOAT, and blur operates on encoded SDR values rather than linear-light color. The 100-attempt unchanged check added zero render passes, allocations or submissions; retirement returned live bytes to zero.

Warm measurements used 40 samples per mode and nearest-rank percentiles. `encode` is CPU command encoding. `submit/wait` includes queue submission and completion waiting; it is not a GPU execution timestamp or presented-frame latency.

| Mode | Encode p50/p95/p99 (µs) | Submit/wait p50/p95/p99 (µs) | Passes per warm frame | Allocations | Live/peak bytes | Filter passes | Filter vertex upload bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Flat | 57.5 / 94.3 / 105.1 | 95.8 / 147.4 / 501.5 | 15 | 0 | 0 / 0 | 0 | 0 |
| Analytic shadow | 65.4 / 73.8 / 93.1 | 101.8 / 126.2 / 530.3 | 16 | 0 | 0 / 0 | 0 | 0 |
| Blur, source generation changed each frame | 108.1 / 181.6 / 233.7 | 157.4 / 412.6 / 582.8 | 29 | 8 | 810,000 / 810,000 | 82 | 42,120 |
| Blur, retained cache | 58.4 / 75.6 / 99.5 | 102.0 / 412.5 / 574.1 | 16 | 8 | 810,000 / 810,000 | 2 | 42,120 |

First-frame cold encode/submit-wait times were 886.9/596.3 µs (flat),
72.1/161.0 µs (analytic shadow), 2,898.4/346.1 µs (blur with changing source),
and 1,163.9/472.0 µs (retained blur). Treat the high submit/wait tails as noisy
driver/queue wall time. The retained blur run made eight initial GPU allocations,
then reused its filter result on unchanged frames.

The fixture wrote four 384×256 PPM captures under ignored
`out/retained-effects/` (`flat`, `analytic-shadow`, `blur-cold`, and
`blur-retained`). The `blur-cold` and `blur-retained` captures were byte-identical
in this run. The captures are local artifacts, not committed reference images.

This supplement fills in a reproducible effects-specific cold/warm timing and
cache reference. It does not fill the application-level gaps below: full
description/layout/paint/renderer timing attribution, process working-set peak,
or comparative production measurements on the same workload.

## Limits of this baseline

The interactive native smoke runner did not complete its text-input check:
the automated session failed to deliver window focus within its 5-second retry
window. The runner also logged that `WinPixEventRuntime.dll` was unavailable.
Treat this as blocked automation/runtime instrumentation, not a renderer test
failure. Secondary-window, minimize/restore and live Scratchpad/Punks workloads
were not measured in this baseline. Pixel/readback evidence is available, but
there is no browser comparison yet.

Raw outputs in `out/` are intentionally ignored; this report preserves the
measurements and commands without committing machine-specific executables or
large captures.
