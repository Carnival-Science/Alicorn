# Issue #211 Stage D slice 5: live-resize presentation latency

Windows x64, NVIDIA GeForce RTX 2080 SUPER, Windows 10 22H2, 2026-11-20.
Alicorn `codex/issue-211-scratchpad-webgpu` (this branch), example 16 and
Scratchpad `codex/issue-211-webgpu-frontend` @ `adb28fc` built against it.

The founder accepted that live resizing works (79 mid-drag frames on the first
C1 run) but reported that it "isn't the fastest" and that screenshots still show
momentary stretching. This slice measures the gesture instead of guessing, fixes
the one cost the data indicted, and records the remaining floor.

## What was measured and how

`tools/validate_native_webgpu_resize.ps1` already drives the same real
`SendInput` resize gesture on every backend: grab the right edge of a 1100x700
window, move +140 px in 24 steps at 25 ms, release. It now records one line per
live frame (both hosts) with these fields:

| field | meaning |
| --- | --- |
| `presented_ns` | host clock (`SDL_GetTicksNS`) immediately after the present call returns |
| `interval_ns` | `presented_ns` minus the previous presented frame, same drag |
| `geometry_to_present_ns` | from the `WM_WINDOWPOSCHANGED` that changed the outer size to the frame that first presented at that size: **the interval the desktop compositor holds (and stretches) the old frame** |
| `reconfigure_ns` | CPU time in `wgpu.SurfaceConfigure` accumulated since the previous presented frame (hosted only) |
| `adopt_ns` | whole geometry adoption (`hosted_runtime_resize` + invalidate + chrome sync + configure) |
| `description_ns`, `description_passes` | application description passes (reconcile, measure, layout, paint, compose) and how many stabilization passes |
| `reconcile_nodes`, `layout_nodes`, `paint_nodes` | Runtime counter deltas for that step |
| `pre_present_ns` | host chrome pre-present hook (caption/menu/hit regions) |
| `runtime_step_ns`, `acquire_ns`, `encode_ns`, `submit_ns`, `present_ns`, `step_to_present_ns` | the existing B3 presenter stages |
| `post_present_ns` | host work after present (text-input sync + accessibility projection) |
| `poll_ns` | `wgpu.DevicePoll` retirement at live-frame entry |
| `frame_ns` | live-frame wall time, entry to present |
| `solid/text/surface_mesh_rebuilds` (hosted), `text_mesh_rebuilds` (reference) | retained mesh rebuild counters carried on the trace |

All values are CPU wall time. They do not measure GPU execution or scanout;
`geometry_to_present_ns` is the best host-side proxy for the visible stretch
window. The reference host prints the same vocabulary (`build_ns` instead of
`description_ns`; SDL performs its swapchain resize inside
`SDL_AcquireGPUSwapchainTexture`, so `acquire_ns` is its comparable surface cost
and there is no explicit `reconfigure_ns`).

The harness parses both trace prefixes, writes a per-frame CSV, and prints
median/p95/p99/max for every metric plus the count of intervals above one and
two 60 Hz frame budgets. It records these metrics without a pass/fail threshold:
the only hard invariants remain C1's (frames mid-drag, drawable tracks the client,
aspect delta 0 %, fixture accounting). Both hosts also report the same counters
at shutdown (`webgpu_live_resize` / `SDL application PASS`).

Raw logs and CSVs:
[`raw/live-resize-latency-2026-11-20/`](raw/live-resize-latency-2026-11-20/).

## Matched A/B before the fix

Hosted D3D12 before and after the opt-in geometry dispatch, and the unchanged
SDL_GPU reference, on the same fixture and scripted resize gesture. Values are
ms; the metric is the resize gesture unless marked "move".

| metric | hosted D3D12 before | hosted D3D12 after | SDL_GPU reference |
| --- | ---: | ---: | ---: |
| mid-drag frames | 45 | 75 | 58 |
| inter-present p50 / p95 | 18.22 / 31.04 | 8.07 / 25.24 | 15.77 / 23.99 |
| intervals > 16.7 ms | 26 / 44 | 20 / 74 | 23 / 57 |
| **geometry-to-present p50 / p95** | **7.34 / 16.46** | **2.58 / 7.34** | **2.30 / 15.96** |
| description/layout p50 / p95 | 0.26 / 0.37 | 0.00 / 0.36 | 0.00 / 0.39 |
| surface reconfigure p50 / p95 | 1.56 / 2.23 | 1.70 / 1.89 | n/a (acquire p95 1.19) |
| surface acquire p50 / p95 | 0.01 / 0.02 | 0.01 / 0.02 | 0.01 / 1.19 |
| renderer encode p50 / p95 | 0.24 / 0.33 | 0.18 / 0.30 | 0.08 / 0.60 |
| whole live frame p50 / p95 | 2.12 / 2.98 | 0.49 / 4.44 | 0.28 / 2.29 |
| mesh rebuilds during gesture | 46 | 46 | 24 (text only; reference solid has no mesh fingerprint) |

The "before" build is this branch with only the geometry dispatch disabled, so
the timestamping, frame policy, and harness are identical.

The hosted path spent 7.3 ms at p50 and 16.5 ms at p95 between the size message
and the frame that presented the new size, while that frame itself cost
2.1-3.0 ms. The wait, not the encode, was the stretch window: the hosted host
adopted geometry from the compositor's next `WINDOW_EXPOSED` (or the 17 ms move
timer). The reference still follows the same exposure path; on this run half its
size changes happened to paint immediately (p50 2.30) and half waited a frame
(p95 15.96).

The 1.7-2 ms `SurfaceConfigure` per pixel-size change is real but not dominant,
and it is irreducible on this API surface: D3D12 `ResizeBuffers`/Vulkan swapchain
recreation is what `wgpu.SurfaceConfigure` performs when the extent changes.
Skipping it would present at a stale extent, i.e. exactly the stretching the
slice is fixing.

## Change: adopt geometry at the message, not at the exposure

`host/sdl3/live_resize` gained an opt-in dispatch. When a host enables it,
SDL's queued `WINDOW_RESIZED` / `WINDOW_PIXEL_SIZE_CHANGED` event - which SDL
derives from `WM_WINDOWPOSCHANGED`, after it has updated the cached window size -
drives the same guarded render callback with `Cause.Geometry`. It only fires
while `WM_ENTERSIZEMOVE` has marked that slot's modal move active, so ordinary
windows and idle behavior are untouched.

The hosted host enables it in `sdl3_webgpu_live_resize_install`; the reference
host does not, so its behavior is unchanged and remains the control.

A geometry timestamp is recorded in the Windows message hook when
`WM_WINDOWPOSCHANGED` reports a different outer size. The first frame that adopts
that size reports the interval and retires the stamp. Pure moves do not change
the size and therefore do not stamp.

Files: `host/sdl3/live_resize/live_resize.odin` (`Cause.Geometry`,
`Core.geometry_dispatch`, `live_resize_set_geometry_dispatch`, event watch,
geometry timestamp accessors), `host/sdl3/live_resize/live_resize_windows.odin`
(`WM_WINDOWPOSCHANGED` size-gated timestamp, drag-start reset),
`host/sdl3/live_resize_host.odin` (opt-in install and per-frame trace).
Instrumentation: `runtime/hosted.odin`, `host/presentation/surface_presenter.odin`,
`host/sdl3/application.odin`, `host/sdl3/run.odin`,
`native/sdl_gpu/window_host.odin`, `native/sdl_gpu/window_move.odin`.

## Matched A/B after the fix

Same binary, same gesture, all three backends. ms, resize gesture.

| metric | hosted D3D12 | hosted Vulkan | SDL_GPU reference |
| --- | ---: | ---: | ---: |
| mid-drag frames | 75 | 74 | 58 |
| inter-present p50 / p95 | 8.07 / 25.24 | 9.88 / 19.84 | 15.77 / 23.99 |
| intervals > 16.7 ms | 20 / 74 | 8 / 73 | 23 / 57 |
| intervals > 33.3 ms | 0 | 0 | 0 |
| **geometry-to-present p50 / p95** | **2.58 / 7.34** | **4.67 / 5.61** | **2.30 / 15.96** |
| description/layout p50 / p95 | 0.00 / 0.36 | 0.00 / 0.38 | 0.00 / 0.39 |
| surface reconfigure p50 / p95 | 1.70 / 1.89 | 4.03 / 4.69 | n/a (acquire p95 1.19) |
| surface acquire p50 / p95 | 0.01 / 0.02 | 0.02 / 0.03 | 0.01 / 1.19 |
| renderer encode p50 / p95 | 0.18 / 0.30 | 0.10 / 0.20 | 0.08 / 0.60 |
| chrome pre-present p50 / p95 | 0.02 / 0.04 | 0.03 / 0.05 | 0 (shared host chrome) |
| host post-present p50 / p95 | 0.00 / 0.00 | 0.00 / 0.00 | 0 (reference path) |
| whole live frame p50 / p95 | 0.49 / 4.44 | 0.27 / 5.45 | 0.28 / 2.29 |
| mesh rebuilds during gesture | 46 | 46 | 24 (text only; reference solid has no mesh fingerprint) |

D3D12 geometry-to-present fell from 7.34/16.46 to 2.58/7.34 ms (p50 -65 %,
p95 -55 %). Vulkan is 4.67/5.61: its swapchain recreation is ~2.4 ms dearer than
D3D12's `ResizeBuffers`, and that is the whole difference. The reference's p50
(2.30) is low because a `WM_PAINT` happened to arrive immediately on those steps,
but its p95 is 15.96 ms: it has no message-driven adoption, so its tail is the
exposure wait the hosted path no longer pays.

The 46 hosted mesh rebuilds are the expected two per size change (solid + text;
localized text runs keep their cache). The reference rebuilt 24 text meshes for
24 size changes. Neither path rebuilds meshes per exposure or per timer tick; the
drag does not turn retained rendering back into a full rebuild.

## Scratchpad, same gesture (`-Mode application`)

Scratchpad has no retained motion probe, so its timer does not spin. Same 24-step
+140 px drag, same harness, hosted D3D12/Vulkan against the SDL_GPU reference:

| metric (resize) | hosted D3D12 | hosted Vulkan | SDL_GPU reference |
| --- | ---: | ---: | ---: |
| mid-drag frames | 48 | 48 | 59 |
| geometry-to-present p50 / p95 | **12.15 / 13.11** | **15.32 / 16.21** | 22.78 / 24.82 |
| description/layout p50 / p95 | 0.00 / 8.64 | 0.00 / 8.98 | 0.00 / 8.42 |
| description passes per rebuild | 2 | 2 | 2 |
| layout nodes per rebuild | 393 | 393 | 393 |
| surface reconfigure p50 / p95 | 1.78 / 1.83 | 4.73 / 5.12 | n/a (acquire p95 1.28) |
| renderer encode p50 / p95 | 0.47 / 1.77 | 0.39 / 1.64 | 1.41 / 2.06 |
| whole live frame p50 / p95 | 0.72 / 12.75 | 0.59 / 16.06 | 1.58 / 11.87 |
| mesh rebuilds during gesture | 0 | 0 | 0 |

Here the hosted `geometry_to_present` equals its own frame time (12.2 ms on
D3D12): the message-driven frame starts immediately and spends the time in the
real application's description. The reference still waits for the exposure
before that 12 ms frame, so its p50 is 22.8 ms and its p95 24.8 ms. Hosted is
ahead by ~10 ms p50 on D3D12 and ~7.5 ms on Vulkan, and both hosted backends beat
the reference's p95. Scratchpad rebuilt no solid/text/surface meshes during the
drag, and its encode is cheaper than the reference's because retained meshes and
transforms are reused.

The Scratchpad `-Mode application` run still reports the C1 caption-band move
probe as FAIL on validator `adb28fc`: at y = window+16 that revision's integrated
titlebar classifies the probed point as `HTCLIENT` on the first synthetic
`WM_NCHITTEST` and `HTCAPTION` during the band scan, so the harness cannot find a
stable caption point. This is the validator's chrome layout, not the hosted live
path; the fixture build (same binary, fixture chrome) passes the caption move on
all three backends. The resize gesture - the subject of this slice - passes on
every backend, and the hosted `webgpu_live_resize` telemetry reports
`geometry_events 48`, `geometry_frames 24`, `deferred_geometry_events 0`,
`step_failures 0`.

## What remains

- **Application description cost is now the floor for a real app.** Scratchpad's
  two-pass, 393-node rebuild is 8.2-9.0 ms on every backend and dominates the
  12-16 ms hosted frame. It is shared work, not a hosted-path cost: the reference
  records the same 8.4-8.5 ms p95.
- **Swapchain extent change is irreducible here.** `wgpu.SurfaceConfigure` at a
  new extent is D3D12 `ResizeBuffers` (1.7 ms p50) or Vulkan swapchain recreation
  (4.0-4.7 ms p50). Avoiding it means presenting at the old extent, i.e. leaving
  the stretch in place.
- **The reference's exposure wait is still the OS cadence.** None of these
  numbers measure scanout or DWM composition; a window that changes size and
  receives no present for a full compositor interval will still be stretched for
  that interval. The hosted path now responds to the size message in ~0.1 ms and
  presents 2.6-5.6 ms later on the fixture; that is below one 60 Hz frame and
  below the reference's tail.
- **Render-thread headroom.** A 120 Hz drag gives 8.3 ms per step. The fixture
  fits easily; Scratchpad's 12 ms frame does not, on either renderer. Reducing
  that needs application/runtime layout work, not presenter work.

## Suites

Runtime 421 (including the new description-cost assertions), host/fonts 5,
host/sdl3 8, host/sdl3/live_resize 11 (including the geometry-dispatch opt-in and
the Windows size-gated timestamp), host/sdl3/window_frame 1, input 8, clipboard
3, file_drag 3, dialogs 5, host/menus 9, host/web 14, host/diagnostics 9,
host/presentation 7, renderer/webgpu 9, renderer/cpu 23, ui 50, testui 13,
theme 37, native/sdl_gpu 169, native/scroll_capture 6, accessibility contract 1,
AccessKit binding 8, `odin build tests` + `out/alicorn_tests.exe`, and
`tools/test_restoration.ps1` all pass. Example 16 passes its seven smokes on
D3D12, Vulkan, and SDL_GPU (21/21); `--smoke --timings` still presents exactly
one settled frame with no motion frames. Scratchpad `adb28fc` smoke legs pass on
hosted D3D12, hosted Vulkan, and SDL_GPU (clean and recovery).

`tools/check_web_ui_package.ps1` still fails on this Odin installation with
`DevicePoll is not declared by wgpu` in `host/presentation`, the same failure
recorded for earlier slices at base `b79ef57`; only its line number moved.

The suite runner in `tools/test.ps1` could not be used end to end from this
non-interactive PowerShell host: AccessKit's `check.ps1` treats the native test
runner's stderr INFO line as a terminating `NativeCommandError` under
`$ErrorActionPreference = 'Stop'`. The same commands were run individually with
the pinned AccessKit arguments and the AccessKit binding suite was run directly
(8 tests, pass).
